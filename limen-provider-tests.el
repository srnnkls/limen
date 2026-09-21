;;; limen-provider-tests.el --- Provider registry tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'limen-provider)

(defmacro limen-provider-tests--with-registry (&rest body)
  (declare (indent 0) (debug t))
  `(let ((limen-provider--registry (copy-sequence limen-provider--registry)))
     ,@body))

(ert-deftest limen-provider-looks-up-by-symbol-or-string-in-registration-order ()
  (should (equal (mapcar #'limen-provider-name (limen-providers))
                 '(claude codex pi omp)))
  (should (eq (limen-provider-name (limen-provider 'codex)) 'codex))
  (should (eq (limen-provider 'codex) (limen-provider "codex")))
  (should-not (limen-provider 'cursor))
  (should-not (limen-provider "cursor")))

(ert-deftest limen-provider-register-replaces-an-entry-of-the-same-name ()
  (limen-provider-tests--with-registry
    (limen-provider-register
     (limen-provider--make :name 'codex :question-tools '("ask")))
    (should (equal (mapcar #'limen-provider-name (limen-providers))
                   '(claude pi omp codex)))
    (should (equal (limen-provider-question-tools (limen-provider 'codex))
                   '("ask")))
    (limen-provider-register (limen-provider--make :name 'cursor))
    (should (= (length (limen-providers)) 5))))

(ert-deftest limen-provider-filters-by-field-and-honours-home-overrides ()
  (should (equal (mapcar #'limen-provider-name
                         (limen-providers-with #'limen-provider-hook-settings))
                 '(claude codex)))
  (should (equal (mapcar #'limen-provider-name
                         (limen-providers-with #'limen-provider-route))
                 '(codex pi omp)))
  (let* ((directory (file-name-as-directory (make-temp-file "limen-provider" t)))
         (process-environment
          (append (list (concat "CLAUDE_CONFIG_DIR=" directory)
                        (concat "CODEX_HOME=" (expand-file-name "codex" directory)))
                  process-environment)))
    (unwind-protect
        (progn
          (should (equal (funcall (limen-provider-hook-settings
                                   (limen-provider 'claude)))
                         (expand-file-name "settings.json" directory)))
          (should (equal (funcall (limen-provider-hook-settings
                                   (limen-provider 'codex)))
                         (expand-file-name "codex/hooks.json" directory)))
          (should (equal (funcall (limen-provider-config-directory
                                   (limen-provider 'claude)))
                         directory)))
      (delete-directory directory t)))
  (let ((process-environment
         (append '("CLAUDE_CONFIG_DIR=" "HOME=/tmp/limen-home") process-environment)))
    (should (equal (funcall (limen-provider-config-directory
                             (limen-provider 'claude)))
                   "/tmp/limen-home/.claude"))))

(ert-deftest limen-provider-arguments-wire-a-route-only-where-one-exists ()
  (let ((codex (limen-provider-arguments (limen-provider 'codex)))
        (pi (limen-provider-arguments (limen-provider 'pi)))
        (claude (limen-provider-arguments (limen-provider 'claude))))
    (should (equal (funcall codex "http://127.0.0.1:4100/mcp" '("resume"))
                   '("-c" "mcp_servers.limen.url=\"http://127.0.0.1:4100/mcp\""
                     "-c" "mcp_servers.limen.bearer_token_env_var=\"LIMEN_MCP_TOKEN\""
                     "resume")))
    (should (equal (funcall codex nil '("resume")) '("resume")))
    (should (equal (funcall pi nil '("x")) '("x")))
    (should (string-suffix-p "extensions"
                             (limen-provider-extension-directory)))
    (should (equal (funcall claude "http://ignored" '("x")) '("x")))))

(ert-deftest limen-provider-claude-session-name-reads-the-sessions-directory ()
  (let* ((directory (file-name-as-directory (make-temp-file "limen-provider" t)))
         (sessions (expand-file-name "sessions" directory))
         (process-environment
          (cons (concat "CLAUDE_CONFIG_DIR=" directory) process-environment))
         (lookup (limen-provider-session-name (limen-provider 'claude))))
    (unwind-protect
        (progn
          (should-not (funcall lookup "abc"))
          (make-directory sessions)
          (with-temp-file (expand-file-name "one.json" sessions)
            (insert "{\"sessionId\":\"abc\",\"name\":\"review inbox\"}"))
          (with-temp-file (expand-file-name "bad.json" sessions)
            (insert "{not json"))
          (with-temp-file (expand-file-name "two.json" sessions)
            (insert "{\"sessionId\":\"def\",\"name\":\"\"}"))
          (should (equal (funcall lookup "abc") "review inbox"))
          (should-not (funcall lookup "def"))
          (should-not (funcall lookup "zzz")))
      (delete-directory directory t))))

;;; limen-provider-tests.el ends here
