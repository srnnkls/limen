;;; limen-herdr-tests.el --- Limen and Herdr bridge tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'herdr-agent)
(require 'limen-herdr)
(require 'limen-herdr-claude)

(defun limen-herdr-tests--session (kind root)
  (herdr-agent--make-session
   :kind kind :name "review" :server "/tmp/herdr.sock"
   :terminal (concat "term-" kind) :pane (concat "pane-" kind)
   :project root :state 'starting))

(ert-deftest limen-herdr-mode-registers-and-unregisters-three-adapters ()
  (let ((herdr-agent--adapters nil)
        (herdr-agent--adapter-sessions (make-hash-table :test #'eq :weakness 'key))
        (herdr-agent--sessions (make-hash-table :test #'equal))
        (herdr-send-context-functions nil)
        (limen-herdr-mode nil))
    (unwind-protect
        (progn
          (limen-herdr-mode 1)
          (dolist (kind '("claude" "codex" "pi"))
            (should (eq (cdr (assoc kind herdr-agent--adapters))
                        #'limen-herdr--adapter)))
          (should (memq #'limen-herdr-send-context
                        herdr-send-context-functions))
          (limen-herdr-mode -1)
          (should-not herdr-agent--adapters)
          (should-not (memq #'limen-herdr-send-context
                            herdr-send-context-functions)))
      (when limen-herdr-mode
        (limen-herdr-mode -1)))))

(ert-deftest limen-herdr-registration-rollback-preserves-existing-adapters ()
  (let ((herdr-agent--adapters
         `(("codex" . ,#'ignore)
           ("claude" . ,#'limen-herdr--adapter)))
        (herdr-agent--adapter-sessions (make-hash-table :test #'eq :weakness 'key))
        (herdr-agent--sessions (make-hash-table :test #'equal))
        (herdr-send-context-functions nil))
    (should-error (limen-herdr--register) :type 'herdr-error)
    (should (eq (cdr (assoc "claude" herdr-agent--adapters))
                #'limen-herdr--adapter))
    (should (eq (cdr (assoc "codex" herdr-agent--adapters)) #'ignore))
    (should-not (assoc "pi" herdr-agent--adapters))))

(ert-deftest limen-herdr-adapter-wires-launched-provider-phases ()
  (let* ((root (make-temp-file "limen-herdr" t))
         (route-id 0)
         closed attached)
    (unwind-protect
        (cl-letf (((symbol-function 'limen-mcp-register-session)
                   (lambda (session)
                     (make-limen-mcp-route
                      :id (format "route-%d" (cl-incf route-id))
                      :token "secret" :session session)))
                  ((symbol-function 'limen-mcp--listener-port) (lambda () 4100))
                  ((symbol-function 'limen-mcp-unregister-session)
                   (lambda (route)
                     (push route closed)
                     (limen-close-session (limen-mcp-route-session route))))
                  ((symbol-function 'limen-claude-open)
                   (lambda (session &rest _)
                     (make-limen-claude-state
                      :session session :state 'starting
                      :environment '((CLAUDE_CODE_SSE_PORT . "4200")))))
                  ((symbol-function 'limen-claude-attached)
                   (lambda (state &optional instance-id)
                     (push instance-id attached)
                     (setf (limen-claude-state-state state) 'waiting-for-client)))
                  ((symbol-function 'limen-claude-status)
                   (lambda (_state)
                     '((integration_status . "waiting-for-client"))))
                  ((symbol-function 'limen-claude-close)
                   (lambda (state)
                     (push state closed)
                     (limen-close-session (limen-claude-state-session state)))))
          (let ((claude (limen-herdr-tests--session "claude" root)))
            (should (equal (limen-herdr--adapter claude :prepare)
                           '((CLAUDE_CODE_SSE_PORT . "4200"))))
            (should (equal (limen-herdr--adapter claude :arguments '("--flag"))
                           '("--flag")))
            (limen-herdr--adapter claude :attached)
            (should (equal (car attached) "term-claude"))
            (should (equal (alist-get 'availability
                                      (limen-herdr--adapter claude :status))
                           'connected))
            (should (limen-herdr--adapter claude :detach))
            (should-not (herdr-agent-session-adapter-state claude)))
          (let ((codex (limen-herdr-tests--session "codex" root)))
            (should (equal (mapcar #'car (limen-herdr--adapter codex :prepare))
                           '(LIMEN_MCP_URL LIMEN_MCP_TOKEN LIMEN_MCP_SESSION)))
            (let ((arguments (limen-herdr--adapter codex :arguments '("resume"))))
              (should (equal (car arguments) "-c"))
              (should (string-match-p "mcp_servers\\.limen\\.url"
                                      (cadr arguments)))
              (should (member "resume" arguments)))
            (should (limen-herdr--adapter codex :detach)))
          (let ((pi (limen-herdr-tests--session "pi" root)))
            (limen-herdr--adapter pi :prepare)
            (let ((arguments (limen-herdr--adapter pi :arguments '("--continue"))))
              (should (equal (car arguments) "--extension"))
              (should (string-suffix-p "extensions/limen-pi/index.ts"
                                       (cadr arguments))))
            (should (limen-herdr--adapter pi :detach))))
      (delete-directory root t))))

(ert-deftest limen-herdr-adoption-keeps-codex-and-pi-cli-only ()
  (let ((root (make-temp-file "limen-herdr-adopt" t)))
    (unwind-protect
        (dolist (kind '("codex" "pi"))
          (let ((session (limen-herdr-tests--session kind root)))
            (limen-herdr--adapter session :adopted `((agent . ,kind)))
            (should (equal (alist-get 'availability
                                      (limen-herdr--adapter session :status))
                           'cli-only))
            (should-not (limen-herdr-state-session (limen-herdr-state session)))
            (should (limen-herdr--adapter session :detach))))
      (delete-directory root t))))

(ert-deftest limen-herdr-send-context-resolves-the-selected-agent ()
  (let* ((root (make-temp-file "limen-herdr-context" t))
         (file (expand-file-name "context.el" root))
         (agent-session (limen-herdr-tests--session "claude" root))
         (integration (limen-open-session :provider 'claude :project-root root))
         buffer resolved)
    (unwind-protect
        (progn
          (with-temp-file file (insert "alpha\nbeta\ngamma\n"))
          (setq buffer (find-file-noselect file))
          (limen-herdr--set-state
           agent-session
           (make-limen-herdr-state :provider 'claude :session integration))
          (cl-letf (((symbol-function 'herdr-agent-resolve-session)
                     (lambda (target)
                       (setq resolved target)
                       agent-session)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (let ((transient-mark-mode t))
                (set-mark (point-min))
                (forward-line 1)
                (end-of-line)
                (setq mark-active t)
                (should
                 (equal
                  (limen-herdr-send-context
                   '((server_key . "/tmp/herdr.sock")
                     (terminal_id . "term-claude")))
                  (concat "Emacs context\nfile: context.el:1:0-2:4"
                          "\nmode: emacs-lisp-mode\nlive: `limen context`"
                          "\n\n```\nalpha\nbeta\n```")))
                (deactivate-mark)
                (goto-char (point-min))
                (forward-line 2)
                (should
                 (equal
                  (limen-herdr-send-context
                   '((server_key . "/tmp/herdr.sock")
                     (terminal_id . "term-claude")))
                  (concat "Emacs context\nfile: context.el:3:0-3:5"
                          "\nmode: emacs-lisp-mode\nlive: `limen context`"
                          "\n\n```\ngamma\n```")))))
          (should (equal resolved '("/tmp/herdr.sock" . "term-claude")))
          (limen-herdr--set-state agent-session nil)
          (should-not
           (limen-herdr-send-context
            '((server_key . "/tmp/herdr.sock")
              (terminal_id . "term-claude"))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (unless (limen-session-closed-p integration)
        (limen-close-session integration))
      (delete-directory root t))))

(ert-deftest limen-herdr-send-context-describes-virtual-buffers-and-hints-the-cli ()
  (let* ((root (file-truename (make-temp-file "limen-herdr-virtual" t)))
         (outside (file-truename (make-temp-file "limen-herdr-outside" t)))
         (entry '((server_key . "/tmp/herdr.sock") (terminal_id . "term-codex")))
         (agent-session (limen-herdr-tests--session "codex" root))
         (integration (limen-open-session :provider 'codex :project-root root))
         (inside (generate-new-buffer "*limen virtual*"))
         (away (generate-new-buffer "*limen away*"))
         (internal (generate-new-buffer " limen internal")))
    (unwind-protect
        (progn
          (limen-herdr--set-state
           agent-session
           (make-limen-herdr-state :provider 'codex :session integration))
          (dolist (pair (list (cons inside root) (cons away outside)
                              (cons internal root)))
            (with-current-buffer (car pair)
              (setq default-directory (file-name-as-directory (cdr pair)))
              (insert "first line\nsecond line\n")))
          (cl-letf (((symbol-function 'herdr-agent-resolve-session)
                     (lambda (_target) agent-session)))
            (with-current-buffer inside
              (goto-char (point-min))
              (forward-line 1)
              (should
               (equal (limen-herdr-send-context entry)
                      (concat "Emacs context\nbuffer: *limen virtual*:2:0-2:11"
                              "\nmode: fundamental-mode\nlive: `limen context`"
                              "\n\n```\nsecond line\n```")))
              (let ((transient-mark-mode t))
                (goto-char (point-min))
                (set-mark (point))
                (forward-line 1)
                (end-of-line)
                (setq mark-active t)
                (should (string-prefix-p
                         "Emacs context\nbuffer: *limen virtual*:1:0-2:11\nmode: fundamental-mode\nlive: `limen context`\n\n```\nfirst line\nsecond line\n```"
                         (limen-herdr-send-context entry)))))
            (with-current-buffer away
              (should-not (limen-herdr-send-context entry)))
            (with-current-buffer internal
              (should-not (limen-herdr-send-context entry)))
            (setf (limen-herdr-state-provider (limen-herdr-state agent-session))
                  'claude)
            (with-current-buffer inside
              (should (string-match-p
                       "^live: `limen context`$"
                       (limen-herdr-send-context entry))))))
      (dolist (buffer (list inside away internal))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (unless (limen-session-closed-p integration)
        (limen-close-session integration))
      (delete-directory root t)
      (delete-directory outside t))))

(ert-deftest limen-herdr-context-fields-functions-extend-the-header ()
  (let* ((root (file-truename (make-temp-file "limen-herdr-fields" t)))
         (file (expand-file-name "noted.el" root))
         (entry '((server_key . "/tmp/herdr.sock") (terminal_id . "term-codex")))
         (agent-session (limen-herdr-tests--session "codex" root))
         (integration (limen-open-session :provider 'codex :project-root root))
         (limen-herdr-context-fields-functions
          (list (lambda (context fields-root)
                  (should (equal fields-root root))
                  (should (alist-get 'path context))
                  (list "annotations: review (1)"))))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file file (insert "alpha\n"))
          (setq buffer (find-file-noselect file))
          (limen-herdr--set-state
           agent-session
           (make-limen-herdr-state :provider 'codex :session integration))
          (cl-letf (((symbol-function 'herdr-agent-resolve-session)
                     (lambda (_target) agent-session)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (should (string-match-p
                       "\\`Emacs context\nfile: noted.el:1:0-1:5\nmode: [a-z-]+\nannotations: review (1)\nlive: `limen context`\n"
                       (limen-herdr-send-context entry))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (unless (limen-session-closed-p integration)
        (limen-close-session integration))
      (delete-directory root t))))

(ert-deftest limen-herdr-claude-auto-adoption-observes-herdr-events ()
  (let ((agent '((agent . "claude") (pane_id . "pane-1")
                 (terminal_id . "term-1") (cwd . "/tmp")
                 (agent_status . "idle")))
        adopted)
    (cl-letf (((symbol-function 'herdr-agent-list)
               (lambda (&optional server)
                 (should (equal server "/tmp/herdr.sock"))
                 (list agent)))
              ((symbol-function 'limen-herdr-claude-adopt)
               (lambda (actual server &optional display)
                 (setq adopted (list actual server display)))))
      (let ((limen-herdr-claude-auto-adopt-predicate (lambda (_agent) t)))
        (limen-herdr-claude--maybe-adopt
         "/tmp/herdr.sock" "pane.agent_detected"
         '((agent . "claude") (pane_id . "pane-1")))
        (should (equal adopted (list agent "/tmp/herdr.sock" nil)))))))

(provide 'limen-herdr-tests)
;;; limen-herdr-tests.el ends here
