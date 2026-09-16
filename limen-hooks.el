;;; limen-hooks.el --- Inject Emacs context through agent prompt hooks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Answers Claude Code and Codex prompt hooks with live Emacs context, so
;; every prompt typed into an agent pane carries the recent buffer trail
;; and a pending Herdr message context without altering the prompt text.
;; The hooks are installed into the providers' user settings on request.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'limen)
(require 'limen-provider)
(require 'limen-herdr)
(require 'limen-trail)

(declare-function herdr-agent-resolve-session "ext:herdr-agent" (&optional target))
(declare-function magit-diff-unstaged "ext:magit-diff" (&optional args files))
(declare-function magit-file-tracked-p "ext:magit-git" (file))
(declare-function magit-file-relative-name "ext:magit-git" (&optional file tracked))
(defvar magit-display-buffer-noselect)
(defvar magit-display-buffer-function)
(defvar herdr-message-compose-functions)

(defgroup limen-hooks nil
  "Inject Emacs context through agent prompt hooks."
  :group 'limen
  :prefix "limen-hooks-")

(defvar limen-hooks-mode)

(defcustom limen-hooks-command nil
  "Command the installed hooks run, without the `hook PROVIDER' arguments.
Nil resolves `limen' on variable `exec-path', then the package's bin/limen."
  :type '(choice (const nil) string)
  :group 'limen-hooks)

(defcustom limen-hooks-recent-limit 5
  "Maximum number of trail entries named in the injected context."
  :type '(integer 0)
  :group 'limen-hooks)

(defcustom limen-hooks-context-repeat 5
  "Shortened prompts a session takes before its context is repeated whole.
A prompt whose context has not changed carries a line saying so, and one
whose context differs carries the fields that differ.  Zero repeats
nothing on its own."
  :type 'natnum
  :group 'limen-hooks)

(defcustom limen-hooks-answer-unattached nil
  "Whether a prompt from a pane Emacs holds no session for still gets context.
A hook names the pane it ran in, and the context goes to the session
launched or adopted for that pane.  A pane Emacs never took up - a
harness running under Herdr on its own - gets nothing, unless this is
set, in which case its context is that of the project its working
directory lies in."
  :type 'boolean
  :group 'limen-hooks)

(defcustom limen-hooks-selection-limit 2000
  "Characters of the selected text a prompt carries.
A longer selection is cut there and the prompt says how much is left."
  :type '(integer 0)
  :group 'limen-hooks)

(defcustom limen-hooks-review-edits nil
  "Whether an agent's edit to a project file opens its diff in Emacs.
The diff opens once the edit has landed and holds nothing up; the agent
is never waiting on it.  Turning this on while `limen-hooks-mode' is
active requests the tool-use hook it needs."
  :type 'boolean
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and value (bound-and-true-p limen-hooks-mode))
           (limen-hooks-request-install "review")))
  :group 'limen-hooks)

(defcustom limen-hooks-review-attached-only t
  "Whether only an agent whose terminal Emacs shows has its edits reviewed.
An agent adopted quietly has a session, so its prompts carry context,
but a diff opening for an agent the user is not looking at is noise:
attach its terminal to review it.  Nil reviews every agent with a session."
  :type 'boolean
  :group 'limen-hooks)

(defcustom limen-hooks-review-function #'limen-hooks-review-with-magit
  "Function shown the absolute path of a project file an agent edited."
  :type 'function
  :group 'limen-hooks)

(defcustom limen-hooks-review-display-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . left) (window-width . 0.45) (inhibit-same-window . t))
  "How the diff of an agent's edit is shown, as a `display-buffer' action.
The window is never selected: the review appears beside what the user
is doing and does not interrupt it.  It opens on the left, since the
agent's own terminal takes the right."
  :type 'sexp
  :group 'limen-hooks)

(defun limen-hooks-providers ()
  "Return the providers whose prompt hooks Limen can answer."
  (mapcar #'limen-provider-name
          (limen-providers-with #'limen-provider-hook-settings)))

(defconst limen-hooks--base-events '(("UserPromptSubmit") ("SessionStart"))
  "Hook events context injection needs.")

(defun limen-hooks--edit-tools ()
  "Return every tool name that edits files, across providers."
  (mapcan (lambda (entry) (copy-sequence (limen-provider-edit-tools entry)))
          (limen-providers)))

(defun limen-hooks--review-events ()
  "Return the (EVENT . MATCHER) spec reviewing edits needs, if any."
  (when-let* ((tools (limen-hooks--edit-tools)))
    (list (cons "PostToolUse" (string-join tools "|")))))

(defvar limen-hooks-extra-events nil
  "Further (EVENT . MATCHER) specs consumers need installed.
MATCHER is nil or the provider's tool matcher string.")

(defun limen-hooks-events ()
  "Return every (EVENT . MATCHER) spec the installed hooks must cover."
  (append (and limen-hooks-mode limen-hooks--base-events)
          (and limen-hooks-mode limen-hooks-review-edits
               (limen-hooks--review-events))
          limen-hooks-extra-events))

(defconst limen-hooks--timeout 5
  "Seconds a provider waits for the hook before continuing without it.")

(defconst limen-hooks--session-end-timeout 1
  "Seconds a provider waits for the SessionEnd hook.
Claude shares 1.5 s among every SessionEnd hook and Codex clamps them to 3 s.")

(defconst limen-hooks--live-line
  "live: `limen context`; `limen --help` lists every command"
  "Header line pointing at the CLI.")

(defvar limen-hooks-event-functions nil
  "Functions run for every answered hook event.
Each receives the provider name, the decoded payload extended with the
`server' and `pane' of the Herdr pane, the resolved Limen session or nil,
and the request context.  A string one returns for a `UserPromptSubmit'
event is added to the context the prompt carries.")

(defvar limen-hooks--drafts (make-hash-table :test #'eq)
  "Rendered text and context of the latest Herdr context per session.")

(defvar limen-hooks--pending (make-hash-table :test #'eq)
  "Context alist waiting for the next prompt hook per session.")

(defvar limen-hooks--last (make-hash-table :test #'eq)
  "Block injected by the previous prompt hook per session.")

(defvar limen-hooks--shortened (make-hash-table :test #'eq)
  "Prompts a session has taken shortened context for since its last whole one.")

;;; Settings files

(defun limen-hooks-settings-file (provider)
  "Return the settings file holding PROVIDER's hooks."
  (if-let* ((entry (limen-provider provider))
            (settings (limen-provider-hook-settings entry)))
      (funcall settings)
    (signal 'limen-invalid-arguments
            (list (format "Unsupported hook provider %s" provider)))))

(defun limen-hooks--default-command ()
  "Return the absolute `limen' launcher for installed hooks."
  (shell-quote-argument
   (or (executable-find "limen")
       (expand-file-name
        "bin/limen"
        (file-name-directory (or (locate-library "limen-hooks") load-file-name))))))

(defun limen-hooks-command-line (provider)
  "Return the shell command installed for PROVIDER."
  (format "%s hook %s" (or limen-hooks-command (limen-hooks--default-command))
          provider))

(defun limen-hooks--handler (provider event)
  "Return the hook handler record installed for PROVIDER's EVENT."
  `((type . "command")
    (command . ,(limen-hooks-command-line provider))
    (timeout . ,(if (equal event "SessionEnd")
                    limen-hooks--session-end-timeout
                  limen-hooks--timeout))))

(defun limen-hooks--handler-p (handler provider)
  "Return non-nil when HANDLER is Limen's hook for PROVIDER."
  (let ((command (alist-get 'command handler)))
    (and (stringp command)
         (string-match-p (format "limen['\"]? hook %s\\'" provider) command))))

(defun limen-hooks--read-settings (file)
  "Return the parsed JSON object in FILE, or nil when it is missing or empty."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (skip-chars-forward " \t\n")
      (unless (eobp)
        (json-parse-buffer :object-type 'alist)))))

(defun limen-hooks--write-settings (file settings)
  "Write SETTINGS to FILE as pretty-printed JSON."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert (json-serialize settings))
    (json-pretty-print-buffer)
    (goto-char (point-max))
    (unless (bolp)
      (insert "\n"))))

(defun limen-hooks--event-groups (settings event)
  "Return the handler groups registered for EVENT in SETTINGS."
  (alist-get (intern event) (alist-get 'hooks settings)))

(defun limen-hooks--event-installed-p (settings event provider)
  "Return non-nil when Limen's PROVIDER hook is registered for EVENT in SETTINGS."
  (seq-some (lambda (group)
              (seq-some (lambda (handler)
                          (limen-hooks--handler-p handler provider))
                        (alist-get 'hooks group)))
            (limen-hooks--event-groups settings event)))

(defun limen-hooks--group-matcher (group)
  "Return the tool matcher of handler GROUP, or nil when it has none."
  (let ((matcher (alist-get 'matcher group)))
    (and (stringp matcher) (not (string-empty-p matcher)) matcher)))

(defun limen-hooks--spec-installed-p (settings spec provider)
  "Return non-nil when Limen's PROVIDER hook is registered for SPEC in SETTINGS.
SPEC is (EVENT . MATCHER); one event can carry a group per matcher."
  (seq-some (lambda (group)
              (and (equal (limen-hooks--group-matcher group) (cdr spec))
                   (seq-some (lambda (handler)
                               (limen-hooks--handler-p handler provider))
                             (alist-get 'hooks group))))
            (limen-hooks--event-groups settings (car spec))))

(defun limen-hooks-installed-p (provider)
  "Return non-nil when PROVIDER's settings run Limen's hooks for every spec."
  (let ((settings (limen-hooks--read-settings
                   (limen-hooks-settings-file provider))))
    (seq-every-p (lambda (spec)
                   (limen-hooks--spec-installed-p settings spec provider))
                 (limen-hooks-events))))

(defun limen-hooks--settings-events (settings)
  "Return the names of every event SETTINGS registers handlers for."
  (mapcar (lambda (entry) (symbol-name (car entry)))
          (alist-get 'hooks settings)))

(defun limen-hooks-any-installed-p (provider)
  "Return non-nil when PROVIDER's settings run Limen's hook for some event."
  (let ((settings (limen-hooks--read-settings
                   (limen-hooks-settings-file provider))))
    (seq-some (lambda (event)
                (limen-hooks--event-installed-p settings event provider))
              (limen-hooks--settings-events settings))))

(defun limen-hooks--read-provider ()
  "Read a hook provider from the minibuffer."
  (list (intern (completing-read "Provider: "
                                 (mapcar #'symbol-name (limen-hooks-providers))
                                 nil t))))

;;;###autoload
(defun limen-hooks-install (provider)
  "Install Limen's prompt hooks into PROVIDER's settings."
  (interactive (limen-hooks--read-provider))
  (let* ((file (limen-hooks-settings-file provider))
         (settings (limen-hooks--read-settings file))
         (hooks (alist-get 'hooks settings))
         changed)
    (pcase-dolist (`(,event . ,matcher) (limen-hooks-events))
      (unless (limen-hooks--spec-installed-p settings (cons event matcher) provider)
        (setf (alist-get (intern event) hooks)
              (vconcat (limen-hooks--event-groups settings event)
                       (vector
                        (append (and matcher `((matcher . ,matcher)))
                                `((hooks . ,(vector (limen-hooks--handler provider event)))))))
              changed t)
        (setf (alist-get 'hooks settings) hooks)))
    (when changed
      (limen-hooks--write-settings file settings))
    (when (called-interactively-p 'any)
      (message "Limen %s hooks %s in %s" provider
               (if changed "installed" "already present") file))
    changed))

(defun limen-hooks-remove-events (provider events)
  "Remove Limen's handlers for the EVENTS named from PROVIDER's settings.
Return non-nil when the settings changed."
  (let* ((file (limen-hooks-settings-file provider))
         (settings (limen-hooks--read-settings file))
         (hooks (alist-get 'hooks settings))
         changed)
    (dolist (event events)
      (when (limen-hooks--event-installed-p settings event provider)
        (let ((groups
               (seq-remove
                (lambda (group) (zerop (length (alist-get 'hooks group))))
                (mapcar (lambda (group)
                          (let ((kept (seq-remove
                                       (lambda (handler)
                                         (limen-hooks--handler-p handler provider))
                                       (alist-get 'hooks group))))
                            (mapcar (lambda (entry)
                                      (if (eq (car entry) 'hooks)
                                          (cons 'hooks (vconcat kept))
                                        entry))
                                    group)))
                        (limen-hooks--event-groups settings event)))))
          (if groups
              (setf (alist-get (intern event) hooks) (vconcat groups))
            (setq hooks (assq-delete-all (intern event) hooks)))
          (setq changed t))))
    (when changed
      (if hooks
          (setf (alist-get 'hooks settings) hooks)
        (setq settings (assq-delete-all 'hooks settings)))
      (limen-hooks--write-settings file settings))
    changed))

;;;###autoload
(defun limen-hooks-uninstall (provider)
  "Remove Limen's prompt hooks from PROVIDER's settings."
  (interactive (limen-hooks--read-provider))
  (let ((changed (limen-hooks-remove-events
                  provider
                  (limen-hooks--settings-events
                   (limen-hooks--read-settings
                    (limen-hooks-settings-file provider))))))
    (when (called-interactively-p 'any)
      (message "Limen %s hooks %s in %s" provider
               (if changed "removed" "not present")
               (limen-hooks-settings-file provider)))
    changed))

(defun limen-hooks-install-all (&optional ask features)
  "Install the missing events for every provider.
With ASK in an interactive session, confirm each provider first, naming
FEATURES in the question.  Return the providers whose settings changed; a
provider whose settings cannot be written is reported and skipped."
  (seq-filter (lambda (provider)
                (condition-case err
                    (and (not (limen-hooks-installed-p provider))
                         (or (not ask) noninteractive
                             (y-or-n-p (format "Install Limen %shooks into %s? "
                                               (if features
                                                   (concat (string-join features " and ") " ")
                                                 "")
                                               (limen-hooks-settings-file provider))))
                         (limen-hooks-install provider))
                  (error
                   (message "Limen hooks: %s" (error-message-string err))
                   nil)))
              (limen-hooks-providers)))

(defvar limen-hooks--requests nil
  "Features whose hooks wait for the next coalesced install.")

(defvar limen-hooks--request-timer nil
  "Timer running the coalesced install after the current command.")

(defun limen-hooks--run-requests ()
  "Install the hooks every pending feature asked for, prompting once per provider."
  (let ((features (nreverse limen-hooks--requests)))
    (setq limen-hooks--requests nil
          limen-hooks--request-timer nil)
    (when features
      (limen-hooks-install-all t features))))

(defun limen-hooks-request-install (feature)
  "Install the missing hooks FEATURE needs.
Requests made by the same command, or during startup, share one prompt
per provider; in batch they install at once."
  (cl-pushnew feature limen-hooks--requests :test #'equal)
  (cond
   (noninteractive (limen-hooks--run-requests))
   ((null limen-hooks--request-timer)
    (setq limen-hooks--request-timer
          (run-with-timer 0 nil #'limen-hooks--run-requests)))))

(defun limen-hooks-remove-events-everywhere (events)
  "Remove Limen's handlers for the EVENTS named from every provider's settings.
An event another consumer still lists in `limen-hooks-events' stays."
  (let* ((needed (mapcar #'car (limen-hooks-events)))
         (events (seq-remove (lambda (event) (member event needed)) events)))
    (when events
      (dolist (provider (limen-hooks-providers))
        (condition-case err
            (when (limen-hooks-any-installed-p provider)
              (limen-hooks-remove-events provider events))
          (error
           (message "Limen hooks: %s" (error-message-string err))))))))

;;; Herdr panes

(defun limen-hooks-agent-for (payload agents)
  "Return the Herdr agent entry among AGENTS whose hook sent PAYLOAD, or nil.
The pane and server the hook ran in identify it; failing those, the
harness session id Herdr reports for the agent."
  (let ((pane (alist-get 'pane payload))
        (server (limen-server-key (alist-get 'server payload)))
        (session (alist-get 'session_id payload)))
    (or (when (and (stringp pane) (not (string-empty-p pane)))
          (seq-find (lambda (agent)
                      (and (equal (alist-get 'pane_id agent) pane)
                           (equal (limen-server-key
                                   (alist-get 'server_key agent))
                                  server)))
                    agents))
        (when (and (stringp session) (not (string-empty-p session)))
          (seq-find (lambda (agent)
                      (equal (alist-get 'value (alist-get 'agent_session agent))
                             session))
                    agents)))))

;;; Prompt context

(defun limen-hooks--forget (session)
  "Drop every record kept for SESSION."
  (remhash session limen-hooks--drafts)
  (remhash session limen-hooks--pending)
  (remhash session limen-hooks--last)
  (remhash session limen-hooks--shortened))

(defun limen-hooks--draft (session context _root text)
  "Remember CONTEXT and its rendered TEXT as SESSION's latest draft."
  (puthash session (cons text context) limen-hooks--drafts))

(defun limen-hooks--compose (target text context)
  "Return TEXT alone when CONTEXT will reach TARGET through its prompt hook.
The hook carries the draft recorded for TARGET's session when CONTEXT is
its rendering, and a snapshot taken here when it is not.  Return nil,
letting Herdr append CONTEXT to the message, when TARGET's provider has
no hook installed, no session answers for its pane, or the buffer sent
from gives no snapshot."
  (when (and limen-hooks-mode context)
    (when-let* ((agent-session (condition-case nil
                                   (herdr-agent-resolve-session target)
                                 (error nil)))
                (session (limen-herdr-session-for agent-session))
                ((limen-hooks-installed-p (limen-session-provider session))))
      (let ((draft (gethash session limen-hooks--drafts)))
        (remhash session limen-hooks--drafts)
        (when-let* ((pending (if (equal (car draft) context)
                                 (cdr draft)
                               (condition-case nil
                                   (limen-herdr--send-context-snapshot session)
                                 (error nil)))))
          (puthash session pending limen-hooks--pending)
          text)))))

(defun limen-hooks--queue-push (session context _root)
  "Carry CONTEXT on SESSION's next prompt when its provider has hooks installed."
  (when (and limen-hooks-mode
             (not (limen-session-closed-p session))
             (limen-hooks-installed-p (limen-session-provider session)))
    (puthash session context limen-hooks--pending)
    t))

(defun limen-hooks--session (id server pane context)
  "Return the session the hook came from, or nil.
ID names it outright; failing that the SERVER and PANE the hook ran in
name the session launched or adopted there.  With
`limen-hooks-answer-unattached', an open session rooted at CONTEXT's
project answers for a pane Emacs never took up."
  (or (and (stringp id) (not (string-empty-p id)) (limen-find-session id))
      (and server pane
           (limen-find-session-at (cons (limen-server-key server) pane)))
      (when-let* ((limen-hooks-answer-unattached)
                  (root (limen-request-project-root context)))
        (catch 'found
          (maphash (lambda (session _)
                     (when (and (not (limen-session-closed-p session))
                                (equal (limen-session-project-root session)
                                       (directory-file-name root)))
                       (throw 'found session)))
                   limen--sessions)
          nil))))

(defun limen-hooks--recent-entry (record root)
  "Return RECORD's trail entry text relative to ROOT, or nil when redacted."
  (unless (alist-get 'redacted record)
    (let ((file (alist-get 'file record))
          (line (alist-get 'line (aref (or (alist-get 'points record) [])
                                       0))))
      (cond
       ((and file (integerp line))
        (format "%s:%d" (limen-herdr--context-path file root) line))
       (file (limen-herdr--context-path file root))
       (t (alist-get 'name record))))))

(defun limen-hooks--focus-position (focus)
  "Return FOCUS's selected range, or the line holding point, or nil."
  (or (when-let* ((selection (alist-get 'selection focus)))
        (limen-herdr--position-text selection))
      (when-let* ((line (alist-get 'line (alist-get 'point focus))))
        (number-to-string line))))

(defun limen-hooks--focus (root)
  "Return the focus record for a hook answered below ROOT, or nil."
  (limen--focus-get nil (limen-make-request :interface 'cli :source 'hook
                                            :project-root root
                                            :frame (selected-frame)
                                            :window (selected-window))))

(defun limen-hooks--focus-line (focus root)
  "Return the `focus:' header line for FOCUS below ROOT, or nil without one.
Where the cursor sits is what a prompt usually means and rarely says, and
a region says it more exactly still."
  (when-let* ((focus)
              (where (if-let* ((file (alist-get 'file focus)))
                         (limen-herdr--context-path file root)
                       (alist-get 'name focus))))
    (format "focus: %s%s" where
            (if-let* ((position (limen-hooks--focus-position focus)))
                (concat ":" position)
              ""))))

(defun limen-hooks--fence (text)
  "Return TEXT as a fenced block on its own paragraph."
  (format "\n\n```\n%s\n```" (string-trim-right text)))

(defun limen-hooks--selection-block (focus &optional sent)
  "Return the fenced text FOCUS has selected, or nil.
Nothing is returned when there is no selection or when SENT, the text
the prompt already carries, is that selection.  A selection longer than
`limen-hooks-selection-limit' is cut there."
  (when-let* ((text (alist-get 'text (alist-get 'selection focus)))
              ((not (string-empty-p text)))
              ((not (equal text sent))))
    (let ((rest (- (length text) limen-hooks-selection-limit)))
      (concat (limen-hooks--fence
               (if (> rest 0) (substring text 0 limen-hooks-selection-limit) text))
              (if (> rest 0)
                  (format "\n(%d more characters selected)" rest)
                "")))))

(defun limen-hooks--recent-line (root context)
  "Return the `recent:' header line for ROOT, omitting CONTEXT's own file."
  (when (and limen-trail-mode (> limen-hooks-recent-limit 0))
    (let* ((request (limen-make-request :interface 'cli :source 'hook
                                        :project-root root
                                        :frame (selected-frame)
                                        :window (selected-window)))
           (own (and (alist-get 'path context)
                     (limen-herdr--context-path (alist-get 'path context) root)))
           (entries
            (seq-take
             (seq-remove
              (lambda (entry)
                (and own (or (equal entry own)
                             (string-prefix-p (concat own ":") entry))))
              (delq nil
                    (mapcar (lambda (record)
                              (limen-hooks--recent-entry record root))
                            (append (limen-trail--list nil request) nil))))
             limen-hooks-recent-limit)))
      (when entries
        (format "recent: %s (visited before this prompt, newest first)"
                (string-join entries ", "))))))

(defun limen-hooks--render (context root)
  "Return the prompt context block for CONTEXT below ROOT."
  (let* ((items (alist-get 'items context))
         (fields (cond
                  ((and (vectorp items) (> (length items) 0))
                   (cons "files:"
                         (mapcar (lambda (item)
                                   (limen-herdr--context-item-text item root))
                                 items)))
                  (context (limen-herdr--context-fields context root))))
         (extra (mapcan (lambda (function)
                          (copy-sequence (funcall function context root)))
                        limen-herdr-context-fields-functions))
         (focus (limen-hooks--focus root))
         (focus-line (limen-hooks--focus-line focus root))
         (recent (limen-hooks--recent-line root context))
         (text (alist-get 'text context)))
    (concat
     "Emacs context\n"
     (string-join (append fields extra
                          (and focus-line (list focus-line))
                          (and recent (list recent))
                          (list limen-hooks--live-line))
                  "\n")
     (if (and text (not (string-empty-p text)))
         (limen-hooks--fence text)
       "")
     (or (limen-hooks--selection-block focus text) ""))))

(defun limen-hooks--block-parts (block)
  "Return BLOCK as its heading, its field lines, and the text below them."
  (let* ((fence (string-search "\n```" block))
         (head (if fence (substring block 0 fence) block))
         (body (if fence (substring block fence) ""))
         (lines (split-string head "\n")))
    (list (car lines) (cdr lines) body)))

(defun limen-hooks--field-name (line)
  "Return the name LINE gives its value, or LINE itself."
  (if (string-match "\\`\\([a-z_]+\\):" line)
      (match-string 1 line)
    line))

(defun limen-hooks--changed-fields (block last)
  "Return BLOCK with the fields LAST already carried left out, or nil.
Nothing comes back when a field the agent was told changed cannot be
told apart from one it was not: an unnamed line, or a changed body."
  (pcase-let ((`(,heading ,lines ,body) (limen-hooks--block-parts block))
              (`(,_ ,last-lines ,last-body) (limen-hooks--block-parts last)))
    (when (and (equal body last-body)
               (seq-every-p (lambda (line)
                              (not (equal line (limen-hooks--field-name line))))
                            (append lines last-lines)))
      (let ((changed (seq-remove (lambda (line) (member line last-lines)) lines))
            (kept (seq-filter (lambda (line) (member line last-lines)) lines)))
        (when changed
          (string-join
           (append (list (concat heading " — changed since the last prompt"))
                   changed
                   (when kept
                     (list (format "unchanged: %s"
                                   (string-join
                                    (mapcar #'limen-hooks--field-name kept)
                                    ", ")))))
           "\n"))))))

(defun limen-hooks--prompt-context (session root)
  "Return the context injected into SESSION's next prompt below ROOT.
An explicit send, and every `limen-hooks-context-repeat' prompt,
carries the whole block; in between a prompt carries the fields that
changed, or one line saying the context stands as it was."
  (let ((pending (and session (gethash session limen-hooks--pending))))
    (when session
      (remhash session limen-hooks--pending))
    (let* ((block (limen-hooks--render pending root))
           (last (and session (gethash session limen-hooks--last)))
           (shortened (and session (gethash session limen-hooks--shortened 0)))
           (whole (lambda ()
                    (puthash session block limen-hooks--last)
                    (puthash session 0 limen-hooks--shortened)
                    block))
           (short (lambda (text)
                    (puthash session block limen-hooks--last)
                    (puthash session (1+ shortened) limen-hooks--shortened)
                    text)))
      (cond
       ((null session) block)
       (pending (funcall whole))
       ((null last) (funcall whole))
       ((and (> limen-hooks-context-repeat 0)
             (>= shortened limen-hooks-context-repeat))
        (funcall whole))
       ((equal block last)
        (funcall short
                 "Emacs context: unchanged; `limen context` reads the live state."))
       ((limen-hooks--changed-fields block last)
        (funcall short (limen-hooks--changed-fields block last)))
       (t (funcall whole))))))

(defun limen-hooks--decode (value)
  "Decode the Base64 request field VALUE, or return nil."
  (when (and (stringp value) (not (string-empty-p value)))
    (condition-case nil
        (decode-coding-string (base64-decode-string value) 'utf-8)
      (error (signal 'limen-invalid-request '("Malformed hook request"))))))

(defun limen-hooks--display-review (buffer)
  "Show BUFFER per `limen-hooks-review-display-action' and return its window."
  (display-buffer buffer limen-hooks-review-display-action))

(defun limen-hooks--revert-visiting (file)
  "Bring an unmodified buffer visiting FILE up to date with the disk."
  (when-let* ((buffer (get-file-buffer file))
              ((not (buffer-modified-p buffer))))
    (with-current-buffer buffer
      (revert-buffer t t t))))

(defun limen-hooks-review-with-magit (file)
  "Show what changed in FILE's repository, without taking the window.
A Magit diff of the repository's unstaged changes, so an agent's edits
add up in one buffer per repository as they land.  A file git does not
track yet has no diff, so the file itself is shown instead.  Without
Magit, a VC diff of FILE.  An unmodified buffer visiting FILE is
reverted first, so the editor shows the edit too."
  (limen-hooks--revert-visiting file)
  (let ((default-directory (file-name-directory file)))
    (cond
     ((not (require 'magit nil t))
      (with-current-buffer (find-file-noselect file)
        (let ((display-buffer-overriding-action limen-hooks-review-display-action))
          (vc-diff))))
     ((magit-file-tracked-p (magit-file-relative-name file))
      (let ((magit-display-buffer-noselect t)
            (magit-display-buffer-function #'limen-hooks--display-review))
        (magit-diff-unstaged)))
     (t
      (limen-hooks--display-review (find-file-noselect file))))))

(defun limen-hooks--review-edit (provider payload session request)
  "Open the diff of the project file PROVIDER's edit tool changed, per PAYLOAD.
Only an agent Emacs holds a SESSION for is reviewed, within that
session's project, and with `limen-hooks-review-attached-only' one whose
terminal Emacs shows; with `limen-hooks-answer-unattached' the project of
REQUEST stands in.  Runs after the hook has answered, so the agent never
waits on it."
  (when (and limen-hooks-review-edits
             (or session limen-hooks-answer-unattached)
             (or (not limen-hooks-review-attached-only)
                 (and session (limen-herdr-attached-p session)))
             (equal (alist-get 'hook_event_name payload) "PostToolUse"))
    (when-let* ((entry (limen-provider provider))
                ((member (alist-get 'tool_name payload)
                         (limen-provider-edit-tools entry)))
                (file (alist-get 'file_path (alist-get 'tool_input payload)))
                ((stringp file))
                (root (if session
                          (limen-session-project-root session)
                        (limen-request-project-root request)))
                ((limen-project-file-p file root)))
      (run-at-time 0 nil limen-hooks-review-function (expand-file-name file))
      nil)))

(defun limen-hooks-output (request context)
  "Return the hook output for the CLI REQUEST in CONTEXT, or an empty string."
  (let ((provider (alist-get 'provider request)))
    (unless (and (stringp provider)
                 (memq (intern provider) (limen-hooks-providers)))
      (signal 'limen-invalid-request '("Unsupported hook provider")))
    (let* ((payload (when-let* ((text (limen-hooks--decode
                                       (alist-get 'payload_base64 request))))
                      (condition-case nil
                          (json-parse-string text :object-type 'alist)
                        (error (signal 'limen-invalid-request
                                       '("Malformed hook payload"))))))
           (event (alist-get 'hook_event_name payload))
           (server (limen-hooks--decode (alist-get 'server_base64 request)))
           (pane (limen-hooks--decode (alist-get 'pane_base64 request)))
           (session (limen-hooks--session
                     (limen-hooks--decode (alist-get 'session_base64 request))
                     server pane context))
           (root (if session
                     (limen-session-project-root session)
                   (limen-request-project-root context)))
           (payload (append payload `((server . ,server) (pane . ,pane))))
           (extra (delq nil
                        (mapcar (lambda (function)
                                  (let ((value (funcall function provider payload
                                                        session context)))
                                    (and (stringp value)
                                         (not (string-empty-p value))
                                         value)))
                                limen-hooks-event-functions)))
           (text (when (or session limen-hooks-answer-unattached)
                   (pcase event
                     ("SessionStart" (limen-skill context))
                     ("UserPromptSubmit"
                      (string-join
                       (cons (limen-hooks--prompt-context session root) extra)
                       "\n\n"))
                     (_ nil)))))
      (if (and text (not (string-empty-p text)))
          (json-serialize
           `((hookSpecificOutput . ((hookEventName . ,event)
                                    (additionalContext . ,text)))))
        ""))))

(add-hook 'limen-session-close-hook #'limen-hooks--forget)
(add-hook 'limen-hooks-event-functions #'limen-hooks--review-edit)
(add-hook 'limen-herdr-context-hook #'limen-hooks--draft)
(add-hook 'limen-herdr-push-functions #'limen-hooks--queue-push)
(add-hook 'herdr-message-compose-functions #'limen-hooks--compose)

;;;###autoload
(define-minor-mode limen-hooks-mode
  "Inject Emacs context through agent prompt hooks instead of the message body.
Enabling requests the context hook events for every provider, which
asks once per provider whose settings lack them after the current
command, and Herdr messages to a provider with installed hooks carry
only their text; disabling removes the context events again."
  :global t
  :group 'limen-hooks
  (if limen-hooks-mode
      (limen-hooks-request-install "context")
    (limen-hooks-remove-events-everywhere
     (mapcar #'car (append limen-hooks--base-events
                           (limen-hooks--review-events))))))

(provide 'limen-hooks)
;;; limen-hooks.el ends here
