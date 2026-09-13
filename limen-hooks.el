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
(require 'limen-claude)
(require 'limen-herdr)
(require 'limen-trail)

(declare-function herdr-agent-resolve-session "ext:herdr-agent" (&optional target))
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

(defconst limen-hooks--providers '(claude codex)
  "Providers whose prompt hooks Limen can answer.")

(defconst limen-hooks--base-events '(("UserPromptSubmit") ("SessionStart"))
  "Hook events context injection needs.")

(defvar limen-hooks-extra-events nil
  "Further (EVENT . MATCHER) specs consumers need installed.
MATCHER is nil or the provider's tool matcher string.")

(defun limen-hooks-events ()
  "Return every (EVENT . MATCHER) spec the installed hooks must cover."
  (append (and limen-hooks-mode limen-hooks--base-events)
          limen-hooks-extra-events))

(defconst limen-hooks--timeout 5
  "Seconds a provider waits for the hook before continuing without it.")

(defconst limen-hooks--live-line
  "live: `limen context`; `limen --help` lists every command"
  "Header line pointing at the CLI.")

(defvar limen-hooks-event-functions nil
  "Functions run for every answered hook event.
Each receives the provider name, the decoded payload extended with the
`server' and `pane' of the Herdr pane, the resolved Limen session or nil,
and the request context.")

(defvar limen-hooks--drafts (make-hash-table :test #'eq)
  "Rendered text and context of the latest Herdr context per session.")

(defvar limen-hooks--pending (make-hash-table :test #'eq)
  "Context alist waiting for the next prompt hook per session.")

(defvar limen-hooks--last (make-hash-table :test #'eq)
  "Block injected by the previous prompt hook per session.")

;;; Settings files

(defun limen-hooks--codex-home ()
  "Return Codex's state directory."
  (let ((configured (getenv "CODEX_HOME")))
    (if (and configured (not (string= configured "")))
        configured
      (expand-file-name ".codex" (or (getenv "HOME") "~")))))

(defun limen-hooks-settings-file (provider)
  "Return the settings file holding PROVIDER's hooks."
  (pcase provider
    ('claude (expand-file-name "settings.json" (limen-claude-config-directory)))
    ('codex (expand-file-name "hooks.json" (limen-hooks--codex-home)))
    (_ (signal 'limen-invalid-arguments
               (list (format "Unsupported hook provider %s" provider))))))

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

(defun limen-hooks--handler (provider)
  "Return the hook handler record installed for PROVIDER."
  `((type . "command")
    (command . ,(limen-hooks-command-line provider))
    (timeout . ,limen-hooks--timeout)))

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

(defun limen-hooks-installed-p (provider)
  "Return non-nil when PROVIDER's settings run Limen's hooks for every event."
  (let ((settings (limen-hooks--read-settings
                   (limen-hooks-settings-file provider))))
    (seq-every-p (lambda (spec)
                   (limen-hooks--event-installed-p settings (car spec) provider))
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
                                 (mapcar #'symbol-name limen-hooks--providers)
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
      (unless (limen-hooks--event-installed-p settings event provider)
        (setf (alist-get (intern event) hooks)
              (vconcat (limen-hooks--event-groups settings event)
                       (vector
                        (append (and matcher `((matcher . ,matcher)))
                                `((hooks . ,(vector (limen-hooks--handler provider)))))))
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

(defun limen-hooks-install-all ()
  "Install the missing events for every provider.
Return the providers whose settings changed; a provider whose settings
cannot be written is reported and skipped."
  (seq-filter (lambda (provider)
                (condition-case err
                    (and (not (limen-hooks-installed-p provider))
                         (limen-hooks-install provider))
                  (error
                   (message "Limen hooks: %s" (error-message-string err))
                   nil)))
              limen-hooks--providers))

(defun limen-hooks-remove-events-everywhere (events)
  "Remove Limen's handlers for the EVENTS named from every provider's settings."
  (dolist (provider limen-hooks--providers)
    (condition-case err
        (when (limen-hooks-any-installed-p provider)
          (limen-hooks-remove-events provider events))
      (error
       (message "Limen hooks: %s" (error-message-string err))))))

;;; Prompt context

(defun limen-hooks--forget (session)
  "Drop every record kept for SESSION."
  (remhash session limen-hooks--drafts)
  (remhash session limen-hooks--pending)
  (remhash session limen-hooks--last))

(defun limen-hooks--draft (session context _root text)
  "Remember CONTEXT and its rendered TEXT as SESSION's latest draft."
  (puthash session (cons text context) limen-hooks--drafts))

(defun limen-hooks--compose (target text context)
  "Return TEXT alone when CONTEXT will reach TARGET through its prompt hook.
Return nil to let Herdr append CONTEXT to the message."
  (when (and limen-hooks-mode context)
    (when-let* ((agent-session (condition-case nil
                                   (herdr-agent-resolve-session target)
                                 (error nil)))
                (state (limen-herdr-state agent-session))
                (session (limen-herdr-state-session state))
                ((not (limen-session-closed-p session)))
                (draft (gethash session limen-hooks--drafts))
                ((equal (car draft) context))
                ((limen-hooks-installed-p (limen-session-provider session))))
      (remhash session limen-hooks--drafts)
      (puthash session (cdr draft) limen-hooks--pending)
      text)))

(defun limen-hooks--session (id context)
  "Return the open session named by ID, or one rooted at CONTEXT's project."
  (or (and (stringp id) (not (string-empty-p id)) (limen-find-session id))
      (let ((root (limen-request-project-root context)))
        (when root
          (catch 'found
            (maphash (lambda (session _)
                       (when (and (not (limen-session-closed-p session))
                                  (equal (limen-session-project-root session)
                                         (directory-file-name root)))
                         (throw 'found session)))
                     limen--sessions)
            nil)))))

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
         (recent (limen-hooks--recent-line root context))
         (text (alist-get 'text context)))
    (concat
     "Emacs context\n"
     (string-join (append fields extra (and recent (list recent))
                          (list limen-hooks--live-line))
                  "\n")
     (if (and text (not (string-empty-p text)))
         (format "\n\n```\n%s\n```" (string-trim-right text))
       ""))))

(defun limen-hooks--prompt-context (session root)
  "Return the context injected into SESSION's next prompt below ROOT."
  (let ((pending (and session (gethash session limen-hooks--pending))))
    (when session
      (remhash session limen-hooks--pending))
    (let ((block (limen-hooks--render pending root)))
      (cond
       ((null session) block)
       ((and (null pending) (equal block (gethash session limen-hooks--last)))
        "Emacs context: unchanged; `limen context` reads the live state.")
       (t
        (puthash session block limen-hooks--last)
        block)))))

(defun limen-hooks--decode (value)
  "Decode the Base64 request field VALUE, or return nil."
  (when (and (stringp value) (not (string-empty-p value)))
    (condition-case nil
        (decode-coding-string (base64-decode-string value) 'utf-8)
      (error (signal 'limen-invalid-request '("Malformed hook request"))))))

(defun limen-hooks-output (request context)
  "Return the hook output for the CLI REQUEST in CONTEXT, or an empty string."
  (let ((provider (alist-get 'provider request)))
    (unless (and (stringp provider)
                 (memq (intern provider) limen-hooks--providers))
      (signal 'limen-invalid-request '("Unsupported hook provider")))
    (let* ((payload (when-let* ((text (limen-hooks--decode
                                       (alist-get 'payload_base64 request))))
                      (condition-case nil
                          (json-parse-string text :object-type 'alist)
                        (error (signal 'limen-invalid-request
                                       '("Malformed hook payload"))))))
           (event (alist-get 'hook_event_name payload))
           (session (limen-hooks--session
                     (limen-hooks--decode (alist-get 'session_base64 request))
                     context))
           (root (if session
                     (limen-session-project-root session)
                   (limen-request-project-root context)))
           (payload (append
                     payload
                     `((server . ,(limen-hooks--decode
                                   (alist-get 'server_base64 request)))
                       (pane . ,(limen-hooks--decode
                                 (alist-get 'pane_base64 request))))))
           (_ (run-hook-with-args 'limen-hooks-event-functions
                                  provider payload session context))
           (text (pcase event
                   ("SessionStart" (limen-skill context))
                   ("UserPromptSubmit" (limen-hooks--prompt-context session root))
                   (_ nil))))
      (if (and text (not (string-empty-p text)))
          (json-serialize
           `((hookSpecificOutput . ((hookEventName . ,event)
                                    (additionalContext . ,text)))))
        ""))))

(add-hook 'limen-session-close-hook #'limen-hooks--forget)
(add-hook 'limen-herdr-context-hook #'limen-hooks--draft)
(add-hook 'herdr-message-compose-functions #'limen-hooks--compose)

;;;###autoload
(define-minor-mode limen-hooks-mode
  "Inject Emacs context through agent prompt hooks instead of the message body.
Enabling installs the context hook events for every provider, and Herdr
messages to a provider with installed hooks carry only their text;
disabling removes the context events again."
  :global t
  :group 'limen-hooks
  (if limen-hooks-mode
      (limen-hooks-install-all)
    (limen-hooks-remove-events-everywhere
     (mapcar #'car limen-hooks--base-events))))

(provide 'limen-hooks)
;;; limen-hooks.el ends here
