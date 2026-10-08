;;; limen-herdr-tests.el --- Herdr integration tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-herdr)

(ert-deftest limen-herdr-project-settings-choose-model-and-effort-at-launch ()
  (let ((limen-herdr-project-settings
         '(("/repo/" :harness "codex" :model "gpt-6" :effort "high")
           ("/repo/sub/" :model "deep")))
        (provider 'codex)
        (project "/repo/.worktrees/x"))
    (cl-letf (((symbol-function 'limen-herdr--provider) (lambda (_session) provider))
              ((symbol-function 'limen-herdr-state) #'ignore)
              ((symbol-function 'herdr-agent-session-project) (lambda (_session) project)))
      (should (equal (limen-herdr--settings-arguments 'session)
                     '("-c" "model=\"gpt-6\"" "-c" "model_reasoning_effort=\"high\"")))
      (setq provider 'claude)
      (should-not (limen-herdr--settings-arguments 'session))
      (setq project "/repo/sub/x")
      (should (equal (limen-herdr--settings-arguments 'session) '("--model" "deep")))
      (let ((limen-herdr-launch-settings '(:harness "claude" :effort "low")))
        (should (equal (limen-herdr--settings-arguments 'session) '("--effort" "low"))))
      (should (equal (limen-herdr--arguments 'session '("go"))
                     '("--model" "deep" "go"))))))

(ert-deftest limen-herdr-project-settings-round-trip-through-the-menu ()
  (let ((settings '(:harness "pi" :effort "high")))
    (should (equal (limen-herdr-settings-arguments settings)
                   '("--harness=pi" "--effort=high")))
    (should (equal (limen-herdr-arguments-settings
                    (limen-herdr-settings-arguments settings))
                   settings))))

(provide 'limen-herdr-tests)
;;; limen-herdr-tests.el ends here
