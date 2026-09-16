;;; limen-herdr-tests.el --- Limen and Herdr bridge tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'herdr-agent)
(require 'herdr-herd)
(require 'limen-herdr)
(require 'limen-herdr-claude)
(require 'limen-hooks)

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
         closed)
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
                     (limen-close-session (limen-mcp-route-session route)))))
          (let ((claude (limen-herdr-tests--session "claude" root)))
            (let ((environment (limen-herdr--adapter claude :prepare)))
              (should (equal (mapcar #'car environment) '(LIMEN_SESSION)))
              (should (equal (limen-session-location
                              (limen-herdr-state-session (limen-herdr-state claude)))
                             (cons (limen-server-key "/tmp/herdr.sock") "pane-claude")))
              (should (equal (alist-get 'LIMEN_SESSION environment)
                             (limen-session-id
                              (limen-herdr-state-session
                               (limen-herdr-state claude))))))
            (should (equal (limen-herdr--adapter claude :arguments '("--flag"))
                           '("--flag")))
            (should-not (limen-herdr--adapter claude :attached))
            (let ((status (limen-herdr--adapter claude :status)))
              (should (equal (alist-get 'availability status) 'connected))
              (should (equal (alist-get 'transport status) 'hooks))
              (should-not (assq 'endpoint status)))
            (should (limen-herdr--adapter claude :detach))
            (should-not (herdr-agent-session-adapter-state claude)))
          (let ((codex (limen-herdr-tests--session "codex" root)))
            (should (equal (mapcar #'car (limen-herdr--adapter codex :prepare))
                           '(LIMEN_MCP_URL LIMEN_MCP_TOKEN LIMEN_MCP_SESSION
                             LIMEN_SESSION)))
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

(ert-deftest limen-herdr-adoption-opens-a-session-where-hooks-exist ()
  (let ((root (make-temp-file "limen-herdr-adopt" t)))
    (unwind-protect
        (progn
          (dolist (kind '("claude" "codex"))
            (let ((session (limen-herdr-tests--session kind root)))
              (limen-herdr--adapter session :adopted `((agent . ,kind)))
              (should (equal (alist-get 'availability
                                        (limen-herdr--adapter session :status))
                             'connected))
              (let ((state (limen-herdr-state session)))
                (should (limen-herdr-state-session state))
                (should-not (limen-herdr-state-route state))
                (should-not (limen-herdr-state-launched-p state)))
              (should (limen-herdr--adapter session :detach))))
          (let ((session (limen-herdr-tests--session "pi" root)))
            (limen-herdr--adapter session :adopted '((agent . "pi")))
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
         (rendered nil)
         (limen-herdr-context-hook
          (list (lambda (&rest arguments) (push arguments rendered))))
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
          (should (= (length rendered) 2))
          (pcase-let ((`(,session ,context ,session-root ,text) (car rendered)))
            (should (eq session integration))
            (should (equal (alist-get 'text context) "gamma"))
            (should (equal session-root (limen-session-project-root integration)))
            (should (string-prefix-p "Emacs context\nfile: context.el:3:0-3:5" text)))
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
               (lambda (actual server &optional display &rest _)
                 (setq adopted (list actual server display)))))
      (let ((limen-herdr-claude-auto-adopt-predicate (lambda (_agent) t))
            (limen-herdr-claude-adopt-quietly nil))
        (limen-herdr-claude--maybe-adopt
         "/tmp/herdr.sock" "pane.agent_detected"
         '((agent . "claude") (pane_id . "pane-1")))
        (should (equal adopted (list agent "/tmp/herdr.sock" nil)))))))

(ert-deftest limen-herdr-claude-auto-adoption-seeds-the-agents-already-running ()
  (let ((claude '((agent . "claude") (pane_id . "%1") (terminal_id . "t1")
                  (server_key . "/tmp/herdr.sock") (cwd . "/tmp")))
        (codex '((agent . "codex") (pane_id . "%2") (terminal_id . "t2")
                 (server_key . "/tmp/herdr.sock") (cwd . "/tmp")))
        (limen-herdr-mode t)
        (limen-herdr-claude--adopt-queue nil)
        (limen-herdr-claude--adopt-timer nil)
        (limen-herdr-claude-auto-adopt-predicate (lambda (_agent) t))
        (herdr-agent-event-functions nil)
        adopted)
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-herd-live-agents)
                   (lambda (&optional _session) (list codex claude)))
                  ((symbol-function 'limen-herdr-claude-adopt)
                   (lambda (agent &optional server &rest _)
                     (push (cons (alist-get 'terminal_id agent) server) adopted))))
          (limen-herdr-claude-auto-adopt-mode 1)
          (should (equal (mapcar (lambda (queued) (alist-get 'terminal_id (car queued)))
                                 limen-herdr-claude--adopt-queue)
                         '("t1")))
          (should (timerp limen-herdr-claude--adopt-timer))
          (cancel-timer limen-herdr-claude--adopt-timer)
          (limen-herdr-claude--drain-adoptions)
          (should (equal adopted '(("t1" . "/tmp/herdr.sock")))))
      (when limen-herdr-claude--adopt-timer
        (cancel-timer limen-herdr-claude--adopt-timer))
      (limen-herdr-claude-auto-adopt-mode -1))))

(ert-deftest limen-herdr-claude-adopts-only-agents-on-sessions-emacs-is-attached-to ()
  (let ((root (make-temp-file "limen-herdr-own" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-known-sessions) (lambda () '(shared)))
                  ((symbol-function 'project-current)
                   (lambda (&optional _maybe directory) (and directory t))))
          (should (limen-herdr-claude-adoptable-p `((session . shared) (cwd . ,root))))
          (should-not (limen-herdr-claude-adoptable-p `((session . "cmw") (cwd . ,root))))
          (should-not (limen-herdr-claude-adoptable-p '((session . shared) (cwd . "/nonexistent"))))
          (should-not (limen-herdr-claude-own-session-p '((cwd . "/tmp")))))
      (delete-directory root t))))

(provide 'limen-herdr-tests)
;;; limen-herdr-tests.el ends here


(ert-deftest limen-herdr-push-context-offers-the-hook-then-types-into-the-pane ()
  (let* ((root (file-truename (make-temp-file "limen-herdr-push" t)))
         (file (expand-file-name "push.el" root))
         (agent-session (limen-herdr-tests--session "codex" root))
         (integration (limen-open-session :provider 'codex :project-root root))
         (limen-hooks--pending (make-hash-table :test #'eq))
         (limen-hooks--last (make-hash-table :test #'eq))
         (limen-hooks-mode t)
         buffer typed offered)
    (unwind-protect
        (progn
          (with-temp-file file (insert "alpha\nbeta\ngamma\n"))
          (setq buffer (find-file-noselect file))
          (limen-herdr--set-state
           agent-session
           (make-limen-herdr-state :provider 'codex :session integration))
          (cl-letf (((symbol-function 'herdr-agent-resolve-session)
                     (lambda (_target) agent-session))
                    ((symbol-function 'herdr-agent-prompt)
                     (lambda (target text) (push (cons target text) typed))))
            (with-current-buffer buffer
              (goto-char (point-min))
              (forward-line 1)
              (cl-letf (((symbol-function 'limen-hooks-installed-p)
                         (lambda (provider) (push provider offered) t)))
                (should (limen-herdr-push-context))
                (should (equal offered '(codex)))
                (should-not typed)
                (let ((pending (gethash integration limen-hooks--pending)))
                  (should (equal (alist-get 'path pending) file))
                  (should (equal (alist-get 'text pending) "beta"))
                  (should (equal (alist-get 'major_mode pending) "emacs-lisp-mode")))
                (let ((block (limen-hooks--prompt-context integration root)))
                  (should (string-match-p "^file: push\\.el:2:0-2:4$" block))
                  (should (string-match-p "^mode: emacs-lisp-mode$" block))
                  (should (string-suffix-p "```\nbeta\n```" block)))
                (should (zerop (hash-table-count limen-hooks--pending))))
              (cl-letf (((symbol-function 'limen-hooks-installed-p)
                         (lambda (_provider) nil)))
                (should (limen-herdr-push-context))
                (should (zerop (hash-table-count limen-hooks--pending)))
                (should (equal (caar typed) (cons "/tmp/herdr.sock" "term-codex")))
                (should (string-match-p "^file: push\\.el:2:0-2:4$" (cdar typed)))
                (should (string-suffix-p "```\nbeta\n```" (cdar typed)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (limen-close-session integration)
      (delete-directory root t))))
