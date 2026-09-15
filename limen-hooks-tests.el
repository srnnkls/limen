;;; limen-hooks-tests.el --- Prompt hook tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen)
(require 'limen-hooks)

(defmacro limen-hooks-tests--with-settings (&rest body)
  "Run BODY with provider settings redirected into a temporary directory."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "limen-hooks-settings" t))
          (process-environment
           (append (list (concat "CLAUDE_CONFIG_DIR=" directory)
                         (concat "CODEX_HOME=" (expand-file-name "codex" directory)))
                   process-environment))
          (limen-hooks-command "limen")
          (limen-hooks-mode t)
          (limen-hooks-extra-events
           '(("PreToolUse" . "AskUserQuestion|request_user_input")
             ("PostToolUse" . "AskUserQuestion|request_user_input")
             ("Stop") ("SessionEnd"))))
     (unwind-protect
         (progn ,@body)
       (delete-directory directory t))))

(defmacro limen-hooks-tests--with-trail (&rest body)
  "Run BODY with an isolated, enabled trail."
  (declare (indent 0) (debug t))
  `(let ((limen-trail--entries nil)
         (limen-trail--timer nil)
         (limen-trail-buffer-limit 32)
         (limen-trail-point-limit 8)
         (limen-trail-point-distance 5)
         (window-selection-change-functions nil)
         (window-buffer-change-functions nil)
         (kill-buffer-hook nil))
     (unwind-protect
         (progn (limen-trail-mode 1) ,@body)
       (limen-trail-mode -1))))

(defun limen-hooks-tests--read (file)
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer :object-type 'alist)))

(defun limen-hooks-tests--commands (settings event)
  (mapcan (lambda (group)
            (mapcar (lambda (handler) (alist-get 'command handler))
                    (append (alist-get 'hooks group) nil)))
          (append (alist-get (intern event) (alist-get 'hooks settings)) nil)))

(defun limen-hooks-tests--request (root)
  (limen-make-request :interface 'cli :source 'cli :project-root root
                      :frame (selected-frame) :window (selected-window)))

(defun limen-hooks-tests--hook-request (provider event &optional session-id cwd)
  `((version . 1) (method . "hook") (provider . ,provider)
    (session_base64 . ,(base64-encode-string (or session-id "") t))
    (payload_base64
     . ,(base64-encode-string
         (encode-coding-string
          (json-serialize `((hook_event_name . ,event)
                            (session_id . "agent-1")
                            (cwd . ,(or cwd "/"))))
          'utf-8)
         t))))

(defun limen-hooks-tests--context (request root)
  (let ((output (limen-hooks-output request (limen-hooks-tests--request root))))
    (if (string-empty-p output)
        output
      (let ((parsed (json-parse-string output :object-type 'alist)))
        (cons (alist-get 'hookEventName (alist-get 'hookSpecificOutput parsed))
              (alist-get 'additionalContext
                         (alist-get 'hookSpecificOutput parsed)))))))

(defun limen-hooks-tests--visit (file line)
  (let ((buffer (find-file-noselect file)))
    (set-window-buffer (selected-window) buffer)
    (limen-trail--visit)
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line (1- line))
      (limen-trail--settle))
    buffer))

(ert-deftest limen-hooks-install-adds-handlers-and-preserves-settings ()
  (limen-hooks-tests--with-settings
    (let ((file (limen-hooks-settings-file 'claude)))
      (with-temp-file file
        (insert "{\n  \"model\": \"opus\",\n  \"env\": {\"A\": \"1\", \"B\": null},\n"
                "  \"flag\": false,\n"
                "  \"hooks\": {\n    \"UserPromptSubmit\": [\n      {\"matcher\": \"\", \"hooks\": [{\"type\": \"command\", \"command\": \"fas eval\"}]}\n    ]\n  }\n}\n"))
      (should-not (limen-hooks-installed-p 'claude))
      (should (limen-hooks-install 'claude))
      (should (limen-hooks-installed-p 'claude))
      (let ((settings (limen-hooks-tests--read file)))
        (should (equal (alist-get 'model settings) "opus"))
        (should (equal (alist-get 'env settings) '((A . "1") (B . :null))))
        (should (eq (alist-get 'flag settings) :false))
        (should (equal (limen-hooks-tests--commands settings "UserPromptSubmit")
                       '("fas eval" "limen hook claude")))
        (should (equal (limen-hooks-tests--commands settings "SessionStart")
                       '("limen hook claude")))
        (dolist (event '("PreToolUse" "PostToolUse"))
          (let ((groups (alist-get (intern event) (alist-get 'hooks settings))))
            (should (= (length groups) 1))
            (should (equal (alist-get 'matcher (aref groups 0))
                           "AskUserQuestion|request_user_input"))))
        (dolist (event '("Stop" "SessionEnd"))
          (should (equal (limen-hooks-tests--commands settings event)
                         '("limen hook claude"))))
        (cl-flet ((timeout (event)
                    (alist-get 'timeout
                               (aref (alist-get 'hooks
                                                (aref (alist-get event (alist-get 'hooks settings)) 0))
                                     0))))
          (should (= (timeout 'SessionEnd) 1))
          (should (= (timeout 'Stop) 5)))
        (should (equal (mapcar #'car settings) '(model env flag hooks))))
      (should-not (limen-hooks-install 'claude))
      (should (limen-hooks-uninstall 'claude))
      (should-not (limen-hooks-installed-p 'claude))
      (let ((settings (limen-hooks-tests--read file)))
        (should (equal (limen-hooks-tests--commands settings "UserPromptSubmit")
                       '("fas eval")))
        (should (equal (mapcar #'car (aref (alist-get 'UserPromptSubmit
                                                      (alist-get 'hooks settings))
                                           0))
                       '(matcher hooks)))
        (should (equal (mapcar #'car (alist-get 'hooks settings))
                       '(UserPromptSubmit))))
      (should-not (limen-hooks-uninstall 'claude))
      (with-temp-file file
        (insert "{\"hooks\":{\"UserPromptSubmit\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"limen hook claude\"}]}],"
                "\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"limen hook claude\"}]}]}}"))
      (should-not (limen-hooks-installed-p 'claude))
      (should (limen-hooks-install 'claude))
      (should (limen-hooks-installed-p 'claude))
      (should (= (length (limen-hooks-tests--commands (limen-hooks-tests--read file)
                                                      "UserPromptSubmit"))
                 1)))
    (let ((file (limen-hooks-settings-file 'codex)))
      (should-not (file-exists-p file))
      (should (limen-hooks-install 'codex))
      (should (limen-hooks-installed-p 'codex))
      (should (equal (limen-hooks-tests--commands (limen-hooks-tests--read file)
                                                  "SessionStart")
                     '("limen hook codex")))
      (should (equal (alist-get 'matcher
                                (aref (alist-get 'PreToolUse
                                                 (alist-get 'hooks (limen-hooks-tests--read file)))
                                      0))
                     "AskUserQuestion|request_user_input"))
      (should (limen-hooks-uninstall 'codex))
      (should-not (alist-get 'hooks (limen-hooks-tests--read file))))
    (should-error (limen-hooks-settings-file 'pi) :type 'limen-invalid-arguments)))

(ert-deftest limen-hooks-output-renders-pending-context-then-recent ()
  (limen-hooks-tests--with-trail
    (let* ((root (file-truename (make-temp-file "limen-hooks-root" t)))
           (files (mapcar (lambda (name)
                            (let ((file (expand-file-name name root)))
                              (with-temp-file file
                                (insert "line 1\nline 2\nline 3\n"))
                              file))
                          '("a.el" "b.el" "c.el")))
           (session (limen-open-session :provider 'claude :project-root root))
           (limen-herdr-context-fields-functions nil)
           (limen-hooks--pending (make-hash-table :test #'eq))
           (limen-hooks--last (make-hash-table :test #'eq))
           (request (limen-hooks-tests--hook-request
                     "claude" "UserPromptSubmit" (limen-session-id session) root))
           buffers)
      (unwind-protect
          (progn
            (setq buffers (cl-loop for file in files
                                   for line from 1
                                   collect (limen-hooks-tests--visit file line)))
            (puthash session
                     `((path . ,(nth 2 files)) (line . 3) (column . 0)
                       (end_line . 3) (end_column . 6) (text . "line 3")
                       (major_mode . "emacs-lisp-mode"))
                     limen-hooks--pending)
            (should (equal (limen-hooks-tests--context request root)
                           (cons "UserPromptSubmit"
                                 (concat "Emacs context\n"
                                         "file: c.el:3:0-3:6\n"
                                         "mode: emacs-lisp-mode\n"
                                         "focus: c.el:3\n"
                                         "recent: b.el:2, a.el:1 (visited before this prompt, newest first)\n"
                                         "live: `limen context`; `limen --help` lists every command"
                                         "\n\n```\nline 3\n```"))))
            (should (zerop (hash-table-count limen-hooks--pending)))
            (let ((plain (concat "Emacs context\n"
                                 "focus: c.el:3\n"
                                 "recent: c.el:3, b.el:2, a.el:1 (visited before this prompt, newest first)\n"
                                 "live: `limen context`; `limen --help` lists every command")))
              (should (equal (limen-hooks-tests--context request root)
                             (cons "UserPromptSubmit" plain)))
              (should (equal (limen-hooks-tests--context request root)
                             (cons "UserPromptSubmit"
                                   "Emacs context: unchanged; `limen context` reads the live state.")))
              (limen-hooks-tests--visit (nth 0 files) 1)
              (should (equal (limen-hooks-tests--context request root)
                             (cons "UserPromptSubmit"
                                   (concat "Emacs context\n"
                                           "focus: a.el:1\n"
                                           "recent: a.el:1, c.el:3, b.el:2 (visited before this prompt, newest first)\n"
                                           "live: `limen context`; `limen --help` lists every command")))))
            (let ((limit (let ((limen-hooks-recent-limit 1))
                           (limen-hooks-tests--context request root))))
              (should (string-match-p "recent: a\\.el:1 (" (cdr limit))))
            (let ((start (limen-hooks-tests--context
                          (limen-hooks-tests--hook-request
                           "codex" "SessionStart" (limen-session-id session) root)
                          root)))
              (should (equal (car start) "SessionStart"))
              (should (string-prefix-p "# limen\n" (cdr start)))
              (should (string-match-p "`trail.list`" (cdr start))))
            (should (equal (limen-hooks-tests--context
                            (limen-hooks-tests--hook-request
                             "claude" "PreToolUse" (limen-session-id session) root)
                            root)
                           ""))
            (should-error (limen-hooks-output
                           (limen-hooks-tests--hook-request "pi" "UserPromptSubmit" nil root)
                           (limen-hooks-tests--request root))
                          :type 'limen-invalid-request)
            (should-error (limen-hooks-output
                           `((method . "hook") (provider . "claude")
                             (payload_base64 . "not base64!"))
                           (limen-hooks-tests--request root))
                          :type 'limen-invalid-request))
        (dolist (buffer buffers)
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (limen-close-session session)
        (delete-directory root t)))))

(ert-deftest limen-hooks-output-runs-event-functions-with-pane-and-server ()
  (let* ((root (file-truename (make-temp-file "limen-hooks-events" t)))
         (limen-trail-mode nil)
         (limen-herdr-context-fields-functions nil)
         (limen-hooks--pending (make-hash-table :test #'eq))
         (limen-hooks--last (make-hash-table :test #'eq))
         seen)
    (unwind-protect
        (let ((limen-hooks-event-functions
               (list (lambda (provider payload session request)
                       (push (list provider
                                   (alist-get 'hook_event_name payload)
                                   (alist-get 'tool_name payload)
                                   (alist-get 'server payload)
                                   (alist-get 'pane payload)
                                   session
                                   (limen-request-project-root request))
                             seen)))))
          (should (equal (limen-hooks-output
                          (append (limen-hooks-tests--hook-request
                                   "claude" "PreToolUse" nil root)
                                  `((server_base64 . ,(base64-encode-string "/tmp/h.sock" t))
                                    (pane_base64 . ,(base64-encode-string "%7" t))))
                          (limen-hooks-tests--request root))
                         ""))
          (should (equal seen
                         `(("claude" "PreToolUse" nil "/tmp/h.sock" "%7" nil ,root))))
          (limen-hooks-output (limen-hooks-tests--hook-request "codex" "Stop" nil root)
                              (limen-hooks-tests--request root))
          (should (equal (car seen) `("codex" "Stop" nil nil nil nil ,root))))
      (delete-directory root t))))

(ert-deftest limen-hooks-output-adds-what-event-functions-return-to-a-prompt ()
  (let* ((root (file-truename (make-temp-file "limen-hooks-extra" t)))
         (limen-trail-mode nil)
         (limen-herdr-context-fields-functions nil)
         (limen-hooks--pending (make-hash-table :test #'eq))
         (limen-hooks--last (make-hash-table :test #'eq))
         (limen-hooks-event-functions
          (list (lambda (&rest _) "[herd limen] one finished. No reply needed.")
                (lambda (&rest _) nil)
                (lambda (&rest _) "")
                (lambda (&rest _) 42))))
    (unwind-protect
        (let ((context (alist-get
                        'additionalContext
                        (alist-get 'hookSpecificOutput
                                   (json-parse-string
                                    (limen-hooks-output
                                     (limen-hooks-tests--hook-request
                                      "claude" "UserPromptSubmit" nil root)
                                     (limen-hooks-tests--request root))
                                    :object-type 'alist)))))
          (should (string-suffix-p "\n\n[herd limen] one finished. No reply needed."
                                   context))
          (should (string-prefix-p "Emacs context" context))
          (should (equal (limen-hooks-output
                          (limen-hooks-tests--hook-request "claude" "Stop" nil root)
                          (limen-hooks-tests--request root))
                         "")))
      (delete-directory root t))))

(ert-deftest limen-hooks-agent-for-matches-pane-then-session ()
  (let* ((socket (make-temp-file "limen-hooks-socket"))
         (agents `(((pane_id . "%1") (server_key . ,socket)
                    (agent_session . ((value . "s1"))))
                   ((pane_id . "%2") (server_key . ,socket)
                    (agent_session . ((value . "s2")))))))
    (unwind-protect
        (progn
          (should (eq (limen-hooks-agent-for
                       `((pane . "%2") (server . ,socket) (session_id . "s1"))
                       agents)
                      (cadr agents)))
          (should (eq (limen-hooks-agent-for
                       `((pane . "") (server . "") (session_id . "s1")) agents)
                      (car agents)))
          (should (eq (limen-hooks-agent-for '((session_id . "s2")) agents)
                      (cadr agents)))
          (should-not (limen-hooks-agent-for
                       `((pane . "%9") (server . ,socket) (session_id . "s9"))
                       agents)))
      (delete-file socket))))

(ert-deftest limen-hooks-removing-events-keeps-what-others-still-list ()
  (limen-hooks-tests--with-settings
    (limen-hooks-install 'claude)
    (setq limen-hooks-extra-events '(("Stop")))
    (limen-hooks-remove-events-everywhere '("Stop" "SessionEnd"))
    (let ((settings (limen-hooks--read-settings (limen-hooks-settings-file 'claude))))
      (should (limen-hooks--event-installed-p settings "Stop" 'claude))
      (should-not (limen-hooks--event-installed-p settings "SessionEnd" 'claude))
      (should (limen-hooks--event-installed-p settings "UserPromptSubmit" 'claude)))))

(ert-deftest limen-hooks-output-resolves-session-by-id-then-root ()
  (let* ((root (file-truename (make-temp-file "limen-hooks-resolve" t)))
         (other (file-truename (make-temp-file "limen-hooks-other" t)))
         (session (limen-open-session :provider 'codex :project-root root))
         (limen-herdr-context-fields-functions nil)
         (limen-trail-mode nil)
         (limen-hooks--pending (make-hash-table :test #'eq))
         (limen-hooks--last (make-hash-table :test #'eq))
         (context '((buffer . "*scratch*") (major_mode . "lisp-interaction-mode")
                    (line . 1) (column . 0) (text . "hello"))))
    (unwind-protect
        (progn
          (puthash session context limen-hooks--pending)
          (should (string-match-p
                   "^buffer: \\*scratch\\*:1:0$"
                   (cdr (limen-hooks-tests--context
                         (limen-hooks-tests--hook-request
                          "codex" "UserPromptSubmit" (limen-session-id session) other)
                         other))))
          (puthash session context limen-hooks--pending)
          (should (string-match-p
                   "^buffer: \\*scratch\\*:1:0$"
                   (cdr (limen-hooks-tests--context
                         (limen-hooks-tests--hook-request
                          "codex" "UserPromptSubmit" nil root)
                         root))))
          (puthash session context limen-hooks--pending)
          (should (equal (cdr (limen-hooks-tests--context
                               (limen-hooks-tests--hook-request
                                "codex" "UserPromptSubmit" nil other)
                               other))
                         (concat "Emacs context\n"
                                 "live: `limen context`; `limen --help` lists every command")))
          (should (= (hash-table-count limen-hooks--pending) 1))
          (limen-close-session session)
          (should (zerop (hash-table-count limen-hooks--pending))))
      (unless (limen-session-closed-p session)
        (limen-close-session session))
      (delete-directory root t)
      (delete-directory other t))))

(ert-deftest limen-hooks-compose-promotes-matching-draft-only ()
  (let* ((root (file-truename (make-temp-file "limen-hooks-compose" t)))
         (session (limen-open-session :provider 'claude :project-root root))
         (state (make-limen-herdr-state :provider 'claude :session session))
         (context '((path . "/tmp/x.el") (line . 1) (column . 0)))
         (limen-hooks--drafts (make-hash-table :test #'eq))
         (limen-hooks--pending (make-hash-table :test #'eq))
         (installed t))
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-agent-resolve-session)
                   (lambda (_target) 'agent))
                  ((symbol-function 'limen-herdr-state)
                   (lambda (_agent) state))
                  ((symbol-function 'limen-hooks-installed-p)
                   (lambda (_provider) installed)))
          (let ((limen-hooks-mode nil))
            (limen-hooks--draft session context root "Emacs context\nfile: x.el:1:0")
            (should-not (limen-hooks--compose '("/s" . "t") "hi"
                                              "Emacs context\nfile: x.el:1:0")))
          (let ((limen-hooks-mode t))
            (should-not (limen-hooks--compose '("/s" . "t") "hi" "Emacs context\nother"))
            (should (zerop (hash-table-count limen-hooks--pending)))
            (setq installed nil)
            (should-not (limen-hooks--compose '("/s" . "t") "hi"
                                              "Emacs context\nfile: x.el:1:0"))
            (setq installed t)
            (should (equal (limen-hooks--compose '("/s" . "t") "hi"
                                                 "Emacs context\nfile: x.el:1:0")
                           "hi"))
            (should (equal (gethash session limen-hooks--pending) context))
            (should (zerop (hash-table-count limen-hooks--drafts)))
            (should-not (limen-hooks--compose '("/s" . "t") "again"
                                              "Emacs context\nfile: x.el:1:0"))
            (should-not (limen-hooks--compose '("/s" . "t") "plain" nil))))
      (limen-close-session session)
      (delete-directory root t))))

(ert-deftest limen-hooks-install-all-asks-per-provider-when-interactive ()
  (limen-hooks-tests--with-settings
    (let ((noninteractive nil)
          (answers (list nil t))
          prompts)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (push prompt prompts) (pop answers))))
        (should (equal (limen-hooks-install-all t '("context" "inbox")) '(codex)))
        (should-not (limen-hooks-installed-p 'claude))
        (should (limen-hooks-installed-p 'codex))
        (should (= (length prompts) 2))
        (should (string-match-p "Limen context and inbox hooks into .*settings\\.json"
                                (cadr prompts)))
        (should (string-match-p "Limen context and inbox hooks into .*hooks\\.json"
                                (car prompts)))
        (setq answers (list nil))
        (should-not (limen-hooks-install-all t))
        (should (= (length prompts) 3))
        (should (equal (limen-hooks-install-all) '(claude)))
        (should (= (length prompts) 3))
        (should-not (limen-hooks-install-all t))
        (should (= (length prompts) 3))))))

(ert-deftest limen-hooks-request-install-coalesces-into-one-prompt-round ()
  (limen-hooks-tests--with-settings
    (let ((noninteractive nil)
          (limen-hooks--requests nil)
          (limen-hooks--request-timer nil)
          prompts timers)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (push prompt prompts) t))
                ((symbol-function 'run-with-timer)
                 (lambda (&rest arguments) (push arguments timers) 'timer)))
        (limen-hooks-request-install "context")
        (limen-hooks-request-install "inbox")
        (limen-hooks-request-install "context")
        (should (= (length timers) 1))
        (should-not prompts)
        (limen-hooks--run-requests)
        (should (= (length prompts) 2))
        (should (seq-every-p (lambda (prompt)
                               (string-match-p "Limen context and inbox hooks" prompt))
                             prompts))
        (should (limen-hooks-installed-p 'claude))
        (should (limen-hooks-installed-p 'codex))
        (should-not limen-hooks--requests)
        (should-not limen-hooks--request-timer)
        (limen-hooks--run-requests)
        (should (= (length prompts) 2))))))

(ert-deftest limen-hooks-mode-installs-and-removes-the-context-events ()
  (limen-hooks-tests--with-settings
    (let ((limen-hooks-extra-events '(("Stop"))))
      (limen-hooks-mode -1)
      (should (equal (mapcar #'car (limen-hooks-events)) '("Stop")))
      (unwind-protect
          (progn
            (limen-hooks-mode 1)
            (should (equal (mapcar #'car (limen-hooks-events))
                           '("UserPromptSubmit" "SessionStart" "Stop")))
            (dolist (provider '(claude codex))
              (should (limen-hooks-installed-p provider)))
            (limen-hooks-mode -1)
            (dolist (provider '(claude codex))
              (let ((settings (limen-hooks--read-settings
                               (limen-hooks-settings-file provider))))
                (should (limen-hooks--event-installed-p settings "Stop" provider))
                (should-not (limen-hooks--event-installed-p
                             settings "UserPromptSubmit" provider))
                (should-not (limen-hooks--event-installed-p
                             settings "SessionStart" provider)))))
        (limen-hooks-mode -1)))))

(provide 'limen-hooks-tests)
;;; limen-hooks-tests.el ends here
