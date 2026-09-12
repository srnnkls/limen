;;; limen-herdr.el --- Herdr lifecycle bridge for Limen -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Injects Limen provider adapters into Herdr's public agent lifecycle.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'limen-claude)
(require 'limen-compile)
(require 'limen-editor)
(require 'limen-mcp)
(require 'limen-trail)

(declare-function herdr-agent-adapter "ext:herdr-agent" (kind))
(declare-function herdr-agent-register-adapter "ext:herdr-agent" (kind adapter))
(declare-function herdr-agent-unregister-adapter "ext:herdr-agent" (kind adapter))
(declare-function herdr-agent-resolve-session "ext:herdr-agent" (&optional target))
(declare-function herdr-agent-send-text "ext:herdr-agent" (target text))
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
(defvar herdr-send-context-functions)

(defgroup limen-herdr nil
  "Connect Herdr agent sessions to Limen."
  :group 'limen
  :prefix "limen-herdr-")

(defcustom limen-herdr-context-item-limit 100
  "Maximum number of files in one explicit context push."
  :type '(integer 1)
  :group 'limen-herdr)

(cl-defstruct limen-herdr-state
  provider session route transport launched-p)

(defconst limen-herdr--capabilities
  '((claude :transport websocket :operations compatibility
            :passive-context native :explicit-context native :diffs t)
    (codex :transport streamable-http :operations registry
           :passive-context resource :explicit-context terminal :diffs t)
    (pi :transport extension :operations registry
        :passive-context next-turn :explicit-context message :diffs t))
  "Provider capabilities exposed by the Herdr bridge.")

(defun limen-herdr-provider-capabilities (provider)
  "Return canonical capabilities for PROVIDER."
  (cdr (assq provider limen-herdr--capabilities)))

(defun limen-herdr-state (session)
  "Return Limen bridge state captured by Herdr SESSION."
  (when-let* ((state (herdr-agent-session-adapter-state session))
              ((limen-herdr-state-p state)))
    state))

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
  (cond
   ((limen-herdr-state-route state)
    (limen-herdr--mcp-environment (limen-herdr-state-route state)))
   ((limen-herdr-state-transport state)
    (limen-claude-environment (limen-herdr-state-transport state)))))

(defun limen-herdr--instance-name (session)
  "Return a plain Claude instance name for Herdr SESSION."
  (format "%s/%s"
          (herdr-agent-session-server session)
          (herdr-agent-session-name session)))

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
             :capabilities (limen-herdr-provider-capabilities provider)))
           (state (make-limen-herdr-state
                   :provider provider :session integration :launched-p launched-p)))
      (limen-herdr--set-state session state)
      (condition-case err
          (progn
            (if mcp
                (setf (limen-herdr-state-route state)
                      (limen-mcp-register-session integration))
              (setf (limen-herdr-state-transport state)
                    (limen-claude-open
                     integration
                     :instance-id (or (herdr-agent-session-terminal session)
                                      (herdr-agent-session-name session))
                     :instance-name (limen-herdr--instance-name session))))
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
     ((limen-herdr-state-transport state)
      (limen-claude-close (limen-herdr-state-transport state)))
     ((limen-herdr-state-route state)
      (limen-mcp-unregister-session (limen-herdr-state-route state)))
     ((limen-herdr-state-session state)
      (limen-close-session (limen-herdr-state-session state))))
    (limen-herdr--set-state session nil)
    t))

(defun limen-herdr-pi-extension-file ()
  "Return the absolute packaged Pi extension path."
  (expand-file-name
   "extensions/limen-pi/index.ts"
   (file-name-directory (or (locate-library "limen-herdr") load-file-name))))

(defun limen-herdr--arguments (session arguments)
  "Return complete ARGUMENTS transformed for Herdr SESSION."
  (pcase (limen-herdr--provider session)
    ('codex
     (if-let* ((state (limen-herdr-state session))
               (route (limen-herdr-state-route state)))
         (append
          (list "-c"
                (format "mcp_servers.limen.url=\"%s\""
                        (limen-mcp-endpoint route))
                "-c"
                "mcp_servers.limen.bearer_token_env_var=\"LIMEN_MCP_TOKEN\"")
          arguments)
       arguments))
    ('pi (append (list "--extension" (limen-herdr-pi-extension-file)) arguments))
    (_ arguments)))

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
          `((endpoint . ,(limen-mcp-endpoint route))))
      ,@(when-let* ((transport (and state (limen-herdr-state-transport state))))
          (limen-claude-status transport)))))

(defun limen-herdr--context-item-text (item)
  "Return one model-visible context ITEM."
  (let ((path (alist-get 'path item))
        (line (alist-get 'line item))
        (column (alist-get 'column item))
        (text (alist-get 'text item)))
    (concat path
            (if (and (integerp line) (integerp column))
                (format ":%d:%d" line column)
              "")
            (if (and text (not (string-empty-p text)))
                (concat "\n\n" text)
              ""))))

(defun limen-herdr--context-text (context)
  "Return CONTEXT as a model-visible terminal message."
  (let ((items (alist-get 'items context)))
    (if (and (vectorp items) (> (length items) 0))
        (concat "Emacs context:\n\n"
                (mapconcat #'limen-herdr--context-item-text items "\n\n"))
      (concat "Emacs context: " (limen-herdr--context-item-text context)))))

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
  "Return explicit context for the current buffer and SESSION."
  (let ((root (limen-session-project-root session)))
    (if (derived-mode-p 'dired-mode)
        (limen-herdr--dired-context root)
      (let ((file (buffer-file-name)))
        (unless (and file (limen-project-file-p file root))
          (user-error "Current file has no matching Limen integration"))
        (limen-editor-context-snapshot)))))

(defun limen-herdr--send-context-snapshot (session)
  "Return point context for SESSION with a current-line fallback."
  (if (or (derived-mode-p 'dired-mode) (use-region-p))
      (limen-herdr--current-context session)
    (save-mark-and-excursion
      (let ((transient-mark-mode t))
        (set-mark (line-beginning-position))
        (goto-char (line-end-position))
        (setq mark-active t)
        (limen-herdr--current-context session)))))

(defun limen-herdr-send-context (entry)
  "Return rich context for the integrated Herdr agent ENTRY, or nil."
  (condition-case nil
      (when-let* ((server (alist-get 'server_key entry))
                  (terminal (alist-get 'terminal_id entry))
                  (agent-session
                   (herdr-agent-resolve-session (cons server terminal)))
                  (state (limen-herdr-state agent-session))
                  (session (limen-herdr-state-session state))
                  ((not (limen-session-closed-p session))))
        (limen-herdr--context-text
         (limen-herdr--send-context-snapshot session)))
    (user-error nil)))

;;;###autoload
(defun limen-herdr-push-context (&optional target)
  "Push current file context to integrated Herdr TARGET."
  (interactive)
  (let* ((agent-session (limen-herdr--session target))
         (state (limen-herdr-state agent-session))
         (session (and state (limen-herdr-state-session state))))
    (unless session
      (user-error "Current file has no matching Limen integration"))
    (let ((context (limen-herdr--current-context session)))
      (if (eq (limen-herdr-state-provider state) 'codex)
          (herdr-agent-prompt
           (cons (herdr-agent-session-server agent-session)
                 (herdr-agent-session-terminal agent-session))
           (limen-herdr--context-text context))
        (limen-session-publish session "context.push" context))
      t)))

;;;###autoload
(defun limen-herdr-reconnect (&optional target)
  "Reconnect Claude Code for Herdr TARGET."
  (interactive)
  (let* ((session (limen-herdr--session target))
         (state (limen-herdr-state session)))
    (unless (and state (eq (limen-herdr-state-provider state) 'claude))
      (user-error "Runtime reconnect is available only for Claude Code"))
    (herdr-agent-send-text
     (cons (herdr-agent-session-server session)
           (herdr-agent-session-terminal session))
     "/ide\n")))

(defun limen-herdr--adapter (session phase &optional context)
  "Apply Limen adapter PHASE to Herdr SESSION using CONTEXT."
  (let ((provider (limen-herdr--provider session)))
    (pcase phase
      (:prepare
       (limen-herdr--prepare session provider (memq provider '(codex pi)) t))
      (:arguments (limen-herdr--arguments session context))
      (:adopted
       (if (eq provider 'claude)
           (progn
             (limen-herdr--prepare session provider nil nil)
             (limen-claude-attached
              (limen-herdr-state-transport (limen-herdr-state session))
              (herdr-agent-session-terminal session)))
         (limen-herdr--adopt-cli-only session provider)))
      (:attached
       (when-let* ((state (limen-herdr-state session))
                   (transport (limen-herdr-state-transport state)))
         (limen-claude-attached transport (herdr-agent-session-terminal session))))
      (:status (limen-herdr-status session))
      (:detach (limen-herdr-detach session)))))

(defun limen-herdr--register ()
  "Register Limen's Herdr integration transactionally."
  (let ((context-registered
         (memq #'limen-herdr-send-context herdr-send-context-functions))
        registered)
    (condition-case err
        (progn
          (dolist (kind '("claude" "codex" "pi"))
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
          (dolist (kind '("claude" "codex" "pi"))
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
            (limen-herdr--register))
        (limen-herdr--unregister))
    (error
     (setq limen-herdr-mode (not limen-herdr-mode))
     (signal (car err) (cdr err)))))

(provide 'limen-herdr)
;;; limen-herdr.el ends here
