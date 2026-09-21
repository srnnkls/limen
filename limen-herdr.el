;;; limen-herdr.el --- Herdr lifecycle bridge for Limen -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Injects Limen provider adapters into Herdr's public agent lifecycle.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'limen-compile)
(require 'limen-editor)
(require 'limen-mcp)
(require 'limen-provider)
(require 'limen-trail)

(declare-function herdr-agent-adapter "ext:herdr-agent" (kind))
(declare-function herdr-agent-register-adapter "ext:herdr-agent" (kind adapter))
(declare-function herdr-agent-unregister-adapter "ext:herdr-agent" (kind adapter))
(declare-function herdr-agent-resolve-session "ext:herdr-agent" (&optional target))
(declare-function herdr-agent-prompt "ext:herdr-agent" (target text))
(declare-function herdr-agent-session-p "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-adapter-state "ext:herdr-agent" (session) t)
(declare-function herdr-agent-set-adapter-state "ext:herdr-agent" (session state))
(declare-function herdr-agent-session-kind "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-name "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-pane "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-project "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-server "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-terminal "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-buffer "ext:herdr-agent" (session) t)
(declare-function limen-message-enable "limen-message" ())
(declare-function limen-message-disable "limen-message" ())
(defvar herdr-agent--sessions)
(defvar herdr-send-context-functions)

(defgroup limen-herdr nil
  "Connect Herdr agent sessions to Limen."
  :group 'limen
  :prefix "limen-herdr-")

(defcustom limen-herdr-context-item-limit 100
  "Maximum number of files in one explicit context push."
  :type '(integer 1)
  :group 'limen-herdr)

(defcustom limen-herdr-context-point-marker "▏"
  "Text standing where the point does in a sent excerpt.
It is drawn between the characters the point sits between rather than
over one of them, so the line keeps every character it has and the mark
reads as the bar of an editor waiting for input.  An empty marker leaves
the line bare."
  :type 'string
  :group 'limen-herdr)

(defcustom limen-herdr-context-lines-before 4
  "Lines kept above the text an explicit send carries."
  :type 'natnum
  :group 'limen-herdr)

(defcustom limen-herdr-context-lines-after 4
  "Lines kept below the text an explicit send carries.
The lines are drawn with their numbers and the sent ones are marked down
the gutter.  With nothing kept on either side the text is sent alone."
  :type 'natnum
  :group 'limen-herdr)

(cl-defstruct limen-herdr-state
  provider session route launched-p)

(defun limen-herdr-provider-capabilities (provider)
  "Return canonical capabilities for PROVIDER."
  (when-let* ((entry (limen-provider provider)))
    (limen-provider-capabilities entry)))

(defun limen-herdr-state (session)
  "Return Limen bridge state captured by Herdr SESSION."
  (when-let* ((state (herdr-agent-session-adapter-state session))
              ((limen-herdr-state-p state)))
    state))

(defun limen-herdr-session-for (agent-session)
  "Return the open Limen session AGENT-SESSION runs in, or nil.
The bridge state Herdr keeps on AGENT-SESSION names it; failing that,
the pane the agent runs in does, the way a prompt hook finds it."
  (or (when-let* ((state (limen-herdr-state agent-session))
                  (session (limen-herdr-state-session state))
                  ((not (limen-session-closed-p session))))
        session)
      (limen-find-session-at
       (cons (limen-server-key (herdr-agent-session-server agent-session))
             (herdr-agent-session-pane agent-session)))))

(defun limen-herdr-agent-session (session)
  "Return the Herdr agent session integrated as Limen SESSION, or nil."
  (catch 'found
    (maphash (lambda (_key agent-session)
               (when-let* ((state (limen-herdr-state agent-session))
                           ((eq (limen-herdr-state-session state) session)))
                 (throw 'found agent-session)))
             herdr-agent--sessions)
    nil))

(defun limen-herdr-attached-p (session)
  "Return non-nil when Emacs shows a terminal for the agent SESSION integrates.
An agent adopted quietly has a session and no terminal until the user
opens one."
  (when-let* ((agent-session (limen-herdr-agent-session session)))
    (buffer-live-p (herdr-agent-session-buffer agent-session))))

(defun limen-herdr--set-state (session state)
  "Set Herdr SESSION's opaque adapter STATE."
  (herdr-agent-set-adapter-state session state))

(defun limen-herdr--provider (session)
  "Return SESSION's provider symbol."
  (intern (herdr-agent-session-kind session)))

(defun limen-herdr--mcp-environment (route)
  "Return launch environment entries for MCP ROUTE."
  `((LIMEN_MCP_URL . ,(limen-mcp-endpoint route))
    (LIMEN_MCP_TOKEN . ,(limen-mcp-route-token route))
    (LIMEN_MCP_SESSION . ,(limen-mcp-route-id route))))

(defun limen-herdr--environment (state)
  "Return launch environment for bridge STATE."
  (append
   (when-let* ((provider (limen-herdr-state-provider state)))
     `((LIMEN_PROVIDER . ,(symbol-name provider))))
   (when-let* ((route (limen-herdr-state-route state)))
     (limen-herdr--mcp-environment route))
   (when-let* ((session (limen-herdr-state-session state)))
     `((LIMEN_SESSION . ,(limen-session-id session))))))

(defun limen-herdr--prepare (session provider &optional mcp launched-p)
  "Prepare Herdr SESSION for PROVIDER.
MCP exposes the standard Limen route.  LAUNCHED-P records process ownership."
  (if-let* ((state (limen-herdr-state session)))
      (if-let* ((integration (limen-herdr-state-session state))
                ((not (limen-session-closed-p integration))))
          (limen-herdr--environment state)
        (limen-herdr-detach session)
        (limen-herdr--prepare session provider mcp launched-p))
    (let* ((integration
            (limen-open-session
             :provider provider
             :project-root (herdr-agent-session-project session)
             :capabilities (limen-herdr-provider-capabilities provider)
             :location (cons (limen-server-key (herdr-agent-session-server session))
                             (herdr-agent-session-pane session))))
           (state (make-limen-herdr-state
                   :provider provider :session integration :launched-p launched-p)))
      (limen-herdr--set-state session state)
      (condition-case err
          (progn
            (when mcp
              (setf (limen-herdr-state-route state)
                    (limen-mcp-register-session integration)))
            (limen-herdr--environment state))
        (error
         (condition-case nil
             (limen-herdr-detach session)
           (error nil))
         (signal (car err) (cdr err)))))))

(defun limen-herdr--adopt-cli-only (session provider)
  "Record externally adopted SESSION for PROVIDER as CLI-only."
  (or (limen-herdr-state session)
      (let ((state (make-limen-herdr-state
                    :provider provider :launched-p nil)))
        (limen-herdr--set-state session state)
        state)))

(defun limen-herdr-detach (session)
  "Detach Limen resources from Herdr SESSION without stopping its agent."
  (when-let* ((state (limen-herdr-state session)))
    (cond
     ((limen-herdr-state-route state)
      (limen-mcp-unregister-session (limen-herdr-state-route state)))
     ((limen-herdr-state-session state)
      (limen-close-session (limen-herdr-state-session state))))
    (limen-herdr--set-state session nil)
    t))

(defun limen-herdr--arguments (session arguments)
  "Return complete ARGUMENTS transformed for Herdr SESSION."
  (if-let* ((entry (limen-provider (limen-herdr--provider session))))
      (let* ((state (limen-herdr-state session))
             (route (and state (limen-herdr-state-route state))))
        (funcall (limen-provider-arguments entry)
                 (and route (limen-mcp-endpoint route))
                 arguments))
    arguments))

(defun limen-herdr--session (target)
  "Return Herdr session identified by TARGET."
  (if (herdr-agent-session-p target)
      target
    (herdr-agent-resolve-session target)))

(defun limen-herdr-status (&optional target)
  "Return Limen integration status for Herdr TARGET."
  (let* ((session (limen-herdr--session target))
         (state (limen-herdr-state session))
         (provider (and state (limen-herdr-state-provider state)))
         (capabilities (and provider
                            (limen-herdr-provider-capabilities provider))))
    `((provider . ,provider)
      (availability . ,(cond
                        ((null state) 'unavailable)
                        ((and (limen-herdr-state-session state)
                              (not (limen-session-closed-p
                                    (limen-herdr-state-session state))))
                         'connected)
                        ((limen-herdr-state-launched-p state) 'disconnected)
                        (t 'cli-only)))
      (transport . ,(plist-get capabilities :transport))
      (operations . ,(plist-get capabilities :operations))
      (passive_context . ,(plist-get capabilities :passive-context))
      (explicit_context . ,(plist-get capabilities :explicit-context))
      (diffs . ,(or (plist-get capabilities :diffs) :json-false))
      ,@(when-let* ((route (and state (limen-herdr-state-route state))))
          `((endpoint . ,(limen-mcp-endpoint route)))))))

(defun limen-herdr--context-path (path root)
  "Return PATH relative to ROOT, the agent's working directory.
Paths outside ROOT stay absolute."
  (let ((relative (and path root
                       (file-relative-name (file-truename path)
                                           (file-truename root)))))
    (if (and relative (not (string-prefix-p ".." relative)))
        relative
      path)))

(defun limen-herdr--position-text (item)
  "Return ITEM's point or selection as LINE:COLUMN or a range, or nil."
  (let ((line (alist-get 'line item))
        (column (alist-get 'column item))
        (end-line (alist-get 'end_line item))
        (end-column (alist-get 'end_column item)))
    (when (and (integerp line) (integerp column))
      (if (and (integerp end-line) (integerp end-column)
               (not (and (= line end-line) (= column end-column))))
          (format "%d:%d-%d:%d" line column end-line end-column)
        (format "%d:%d" line column)))))

(defun limen-herdr--context-item-text (item &optional root)
  "Return one file list entry for context ITEM with its path relative to ROOT."
  (let ((position (limen-herdr--position-text item)))
    (concat "- " (limen-herdr--context-path (alist-get 'path item) root)
            (if position (concat ":" position) ""))))

(defvar limen-herdr-context-fields-functions nil
  "Functions returning extra header lines for a sent context.
Each receives the context alist and the session root and returns a list
of \"key: value\" strings, or nil.")

(defun limen-herdr--diagnostics-text (context)
  "Return the line naming the diagnostics CONTEXT's lines carry, or nil."
  (when-let* ((diagnostics (append (alist-get 'diagnostics context) nil))
              ((> (length diagnostics) 0)))
    (format "diagnostics: %s"
            (mapconcat (lambda (record)
                         (format "%s at %d:%d %s"
                                 (alist-get 'severity record)
                                 (alist-get 'line record)
                                 (alist-get 'column record)
                                 (car (split-string
                                       (alist-get 'message record) "\n"))))
                       diagnostics "; "))))

(defun limen-herdr--context-fields (context root)
  "Return the key-value header lines for single-buffer CONTEXT below ROOT."
  (let ((path (limen-herdr--context-path (alist-get 'path context) root))
        (position (limen-herdr--position-text context))
        (mode (alist-get 'major_mode context))
        (definition (alist-get 'defun context))
        (symbol (alist-get 'symbol context)))
    (delq nil
          (list (format "%s: %s%s"
                        (if path "file" "buffer")
                        (or path (alist-get 'buffer context))
                        (if position (concat ":" position) ""))
                (and mode (format "mode: %s" mode))
                (and definition (format "defun: %s" definition))
                (and symbol (format "symbol: %s" symbol))
                (limen-herdr--diagnostics-text context)))))

(defun limen-herdr--context-text (context &optional root live)
  "Return CONTEXT as a structured message with paths relative to ROOT.
With LIVE, add the `limen context' pointer to the header block."
  (let ((items (alist-get 'items context))
        (text (alist-get 'text context))
        (live-line (and live "live: `limen context`")))
    (concat
     "Emacs context\n"
     (if (and (vectorp items) (> (length items) 0))
         (concat (if live-line (concat live-line "\n") "")
                 "files:\n"
                 (mapconcat (lambda (item)
                              (limen-herdr--context-item-text item root))
                            items "\n"))
       (concat
        (string-join (append (limen-herdr--context-fields context root)
                             (and live
                                  (mapcan (lambda (function)
                                            (copy-sequence
                                             (funcall function context root)))
                                          limen-herdr-context-fields-functions))
                             (and live-line (list live-line)))
                     "\n")
        (let ((excerpt (alist-get 'excerpt context)))
          (cond
           (excerpt (format "\n\n```\n%s\n```" excerpt))
           ((and text (not (string-empty-p text)))
            (format "\n\n```\n%s\n```" (string-trim-right text)))
           (t ""))))))))

(defun limen-herdr--dired-context (root)
  "Return an atomic explicit context snapshot for Dired files below ROOT."
  (let ((files (dired-get-marked-files nil 'marked)))
    (unless files
      (user-error "No Dired files are marked"))
    (when (> (length files) limen-herdr-context-item-limit)
      (user-error "Too many Dired files are marked"))
    (unless (seq-every-p
             (lambda (file)
               (and (stringp file)
                    (not (file-symlink-p file))
                    (not (file-directory-p file))
                    (file-regular-p file)
                    (file-readable-p file)
                    (limen-project-file-p file root)))
             files)
      (user-error "Marked files must be readable regular project files"))
    (let ((items
           (vconcat
            (mapcar (lambda (file)
                      `((type . "file") (path . ,file)
                        (line . 1) (column . 0)))
                    files))))
      `((path . ,(car files)) (line . 1) (column . 0) (end_line . 1)
        (items . ,items)))))

(defun limen-herdr--current-context (session)
  "Return explicit context for the current buffer and SESSION.
A file outside the project of SESSION is sent as well: sending from it
is the user's own choice, and its path stays absolute.  A file inside
it that the project's path policy denies is refused."
  (let ((root (limen-session-project-root session)))
    (if (derived-mode-p 'dired-mode)
        (limen-herdr--dired-context root)
      (let ((file (buffer-file-name)))
        (unless file
          (user-error "Current buffer visits no file"))
        (when (and (limen--project-file-confined-p file root)
                   (limen--project-path-denied-p file root))
          (user-error "Current file is denied by the project path policy"))
        (limen-editor-context-snapshot)))))

(defun limen-herdr--virtual-context ()
  "Return explicit context for the current project virtual buffer."
  (let ((selection (limen--selection-record
                    (or (limen--selection-bounds) (cons (point) (point))))))
    `((buffer . ,(buffer-name))
      (major_mode . ,(symbol-name major-mode))
      (line . ,(alist-get 'line selection))
      (column . ,(alist-get 'column selection))
      (end_line . ,(alist-get 'end_line selection))
      (end_column . ,(alist-get 'end_column selection))
      (text . ,(alist-get 'text selection)))))

(defun limen-herdr--marked (text column)
  "Return TEXT with `limen-herdr-context-point-marker' standing at COLUMN."
  (if (string-empty-p limen-herdr-context-point-marker)
      text
    (let ((column (min column (length text))))
      (concat (substring text 0 column)
              limen-herdr-context-point-marker
              (substring text column)))))

(defun limen-herdr--line-text (line)
  "Return the text of LINE in the current buffer, or nil past its end."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (zerop (forward-line (1- line)))
        (unless (and (eobp) (bolp) (> line 1))
          (buffer-substring-no-properties (point) (line-end-position)))))))

(defun limen-herdr--excerpt (context point-line point-column)
  "Return the lines around CONTEXT's range in the current buffer, drawn.
The sent lines carry a heavier gutter than their neighbours, and a block
stands where the point does, at POINT-COLUMN of POINT-LINE.  It is drawn
in front of the character it sits on, so the line keeps every character
it has."
  (let* ((before limen-herdr-context-lines-before)
         (after limen-herdr-context-lines-after)
         (line (alist-get 'line context))
         (column (alist-get 'column context))
         (end-line (or (alist-get 'end_line context) line)))
    (when (and (or (> before 0) (> after 0)) (integerp line) (integerp column))
      (let ((lines nil))
        (cl-loop for number from (max 1 (- line before)) to (+ end-line after)
                 for text = (limen-herdr--line-text number)
                 while (or text (<= number end-line))
                 do (push (cons number (or text "")) lines))
        (when lines
          (let* ((numbered (nreverse lines))
                 (width (length (number-to-string (caar (last numbered)))))
                 (gutter (make-string (1+ width) ?\s))
                 (row (format "%%%dd %%s %%s" width))
                 (rows nil))
            (pcase-dolist (`(,number . ,text) numbered)
              (push (format row number
                            (if (<= line number end-line) "┃" "│")
                            (if (eql number point-line)
                                (limen-herdr--marked text point-column)
                              text))
                    rows))
            (string-join
             (append (list (format "%s╭─ %s:%d:%d ─" gutter
                                   (if-let* ((path (alist-get 'path context)))
                                       (file-name-nondirectory path)
                                     (or (alist-get 'buffer context) ""))
                                   point-line point-column))
                     (nreverse rows)
                     (list (format "%s╰─" gutter)))
             "\n")))))))

(defun limen-herdr--point-diagnostics (context)
  "Return the diagnostics of CONTEXT's lines in the current buffer."
  (when (derived-mode-p 'prog-mode)
    (let ((beg (save-excursion (goto-char (point-min))
                               (forward-line (1- (alist-get 'line context)))
                               (line-beginning-position)))
          (end (save-excursion (goto-char (point-min))
                               (forward-line (1- (or (alist-get 'end_line context)
                                                     (alist-get 'line context))))
                               (line-end-position))))
      (delq nil (mapcar #'limen--diagnostic-record
                        (flymake-diagnostics beg end))))))

(defun limen-herdr--point-state (context)
  "Return what the editor alone knows about CONTEXT's place in this buffer."
  (let ((line (limen--absolute-line-number (point)))
        (column (limen-logical-column-at-position (point))))
    (delq nil
          (list (cons 'major_mode (symbol-name major-mode))
                (cons 'point_line line)
                (cons 'point_column column)
                (when-let* ((name (ignore-errors (add-log-current-defun))))
                  (cons 'defun name))
                (when-let* ((symbol (thing-at-point 'symbol t)))
                  (cons 'symbol symbol))
                (when-let* ((diagnostics (ignore-errors
                                           (limen-herdr--point-diagnostics context))))
                  (cons 'diagnostics (vconcat diagnostics)))
                (when-let* ((excerpt (limen-herdr--excerpt context line column)))
                  (cons 'excerpt excerpt))))))

(defun limen-herdr--with-point-state (context)
  "Return CONTEXT carrying the editor state around its place."
  (if (alist-get 'items context)
      context
    (append context (limen-herdr--point-state context))))

(defun limen-herdr--send-context-snapshot (session)
  "Return point context for SESSION with a current-line fallback.
File buffers and Dired report as explicit context; other buffers report
their name, mode, and text at point.  Sending is the user's own choice,
so a buffer outside the project of SESSION reports the same way."
  (let ((virtual (and (not (derived-mode-p 'dired-mode))
                      (not buffer-file-name)
                      (not (string-prefix-p " " (buffer-name))))))
    (limen-herdr--with-point-state
     (if (or (derived-mode-p 'dired-mode) (use-region-p))
         (if virtual
             (limen-herdr--virtual-context)
           (limen-herdr--current-context session))
       (save-mark-and-excursion
         (let ((transient-mark-mode t))
           (set-mark (line-beginning-position))
           (goto-char (line-end-position))
           (setq mark-active t)
           (if virtual
               (limen-herdr--virtual-context)
             (limen-herdr--current-context session))))))))

(defvar limen-herdr-context-hook nil
  "Functions run after a Herdr context is rendered for an integrated agent.
Each receives the Limen session, the context alist, the session root, and
the rendered text.")

(defvar limen-herdr-push-functions nil
  "Functions offered an explicit context push before it is typed into the pane.
Each receives the Limen session, the context alist and the session root.
The first returning non-nil has delivered it.")

(defun limen-herdr-send-context (entry)
  "Return rich context for the integrated Herdr agent ENTRY, or nil."
  (condition-case nil
      (when-let* ((server (alist-get 'server_key entry))
                  (terminal (alist-get 'terminal_id entry))
                  (agent-session
                   (herdr-agent-resolve-session (cons server terminal)))
                  (session (limen-herdr-session-for agent-session)))
        (let ((context (limen-herdr--send-context-snapshot session))
              (root (limen-session-project-root session)))
          (unless (or (alist-get 'items context) (alist-get 'buffer context))
            (push (cons 'major_mode (symbol-name major-mode)) context))
          (let ((text (limen-herdr--context-text context root t)))
            (run-hook-with-args 'limen-herdr-context-hook
                                session context root text)
            text)))
    (user-error nil)))

;;;###autoload
(defun limen-herdr-push-context (&optional target)
  "Push the current buffer's context to integrated Herdr TARGET.
A function on `limen-herdr-push-functions' may carry it; failing that a
session with an MCP route is sent the `context.push' event, and any
other has the rendered context typed into the agent's pane."
  (interactive)
  (let* ((agent-session (limen-herdr--session target))
         (state (limen-herdr-state agent-session))
         (session (and state (limen-herdr-state-session state))))
    (unless session
      (user-error "Current file has no matching Limen integration"))
    (let* ((root (limen-session-project-root session))
           (context (limen-herdr--send-context-snapshot session)))
      (unless (or (alist-get 'items context) (alist-get 'buffer context))
        (push (cons 'major_mode (symbol-name major-mode)) context))
      (cond
       ((run-hook-with-args-until-success
         'limen-herdr-push-functions session context root))
       ((limen-herdr-state-route state)
        (limen-session-publish session "context.push" context))
       (t
        (herdr-agent-prompt
         (cons (herdr-agent-session-server agent-session)
               (herdr-agent-session-terminal agent-session))
         (limen-herdr--context-text context root))))
      t)))

(declare-function herdr-agents "ext:herdr" ())
(declare-function herdr-all-sessions "ext:herdr" ())
(declare-function herdr-socket-file "ext:herdr-core" ())
(defvar herdr-session)
(defvar herdr-socket-path)

(defun limen-herdr-agents ()
  "Return every agent Herdr knows, each behind the socket of its session.
Herdr answers for one session at a time and Emacs may watch several, so
an agent is worth nothing without the server it was read from."
  (mapcan
   (lambda (session)
     (let* ((herdr-session session)
            (herdr-socket-path nil)
            (server (ignore-errors (herdr-socket-file))))
       (when server
         (mapcar (lambda (entry) (cons server entry))
                 (condition-case nil (herdr-agents) (error nil))))))
   (condition-case nil (herdr-all-sessions) (error nil))))

(defun limen-herdr--adapter (session phase &optional context)
  "Apply Limen adapter PHASE to Herdr SESSION using CONTEXT."
  (let ((provider (limen-herdr--provider session)))
    (pcase phase
      (:prepare
       (limen-herdr--prepare session provider
                             (limen-provider-route (limen-provider provider)) t))
      (:arguments (limen-herdr--arguments session context))
      (:adopted
       (if (limen-provider-hook-transport (limen-provider provider))
           (limen-herdr--prepare session provider nil nil)
         (limen-herdr--adopt-cli-only session provider)))
      (:attached nil)
      (:status (limen-herdr-status session))
      (:detach (limen-herdr-detach session)))))

(defun limen-herdr--register ()
  "Register Limen's Herdr integration transactionally."
  (let ((context-registered
         (memq #'limen-herdr-send-context herdr-send-context-functions))
        registered)
    (condition-case err
        (progn
          (dolist (kind '("claude" "codex" "pi" "omp"))
            (let ((existing (herdr-agent-adapter kind)))
              (herdr-agent-register-adapter kind #'limen-herdr--adapter)
              (unless existing
                (push kind registered))))
          (add-hook 'herdr-send-context-functions #'limen-herdr-send-context)
          t)
      (error
       (unless context-registered
         (remove-hook 'herdr-send-context-functions #'limen-herdr-send-context))
       (dolist (kind registered)
         (ignore-errors
           (herdr-agent-unregister-adapter kind #'limen-herdr--adapter)))
       (signal (car err) (cdr err))))))

(defun limen-herdr--unregister ()
  "Unregister Limen's Herdr integration transactionally."
  (let ((context-registered
         (memq #'limen-herdr-send-context herdr-send-context-functions))
        unregistered)
    (when context-registered
      (remove-hook 'herdr-send-context-functions #'limen-herdr-send-context))
    (condition-case err
        (progn
          (dolist (kind '("claude" "codex" "pi" "omp"))
            (when (herdr-agent-unregister-adapter kind #'limen-herdr--adapter)
              (push kind unregistered)))
          t)
      (error
       (dolist (kind unregistered)
         (herdr-agent-register-adapter kind #'limen-herdr--adapter))
       (when context-registered
         (add-hook 'herdr-send-context-functions #'limen-herdr-send-context))
       (signal (car err) (cdr err))))))

;;;###autoload
(define-minor-mode limen-herdr-mode
  "Inject Limen integrations into Herdr agent lifecycles."
  :global t
  :group 'limen-herdr
  (condition-case err
      (if limen-herdr-mode
          (progn
            (unless (require 'herdr-agent nil t)
              (error "Limen Herdr mode requires herdr-agent"))
            (limen-herdr--register)
            (when (require 'limen-message nil t)
              (limen-message-enable)))
        (limen-herdr--unregister)
        (when (featurep 'limen-message)
          (limen-message-disable)))
    (error
     (setq limen-herdr-mode (not limen-herdr-mode))
     (signal (car err) (cdr err)))))

(provide 'limen-herdr)
;;; limen-herdr.el ends here
