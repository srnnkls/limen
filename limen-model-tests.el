;;; limen-model-tests.el --- Model reporting tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-model)

(defun limen-model-tests--payload (event key value)
  "Return a hook payload for EVENT carrying VALUE under KEY."
  `((hook_event_name . ,event)
    (server . "/tmp/alpha.sock")
    (pane . "%1")
    ,@(and key (list (cons key value)))))

(ert-deftest limen-model-reads-the-model-each-event-carries ()
  (should (equal (limen-model-of
                  (limen-model-tests--payload "SessionStart" 'model "Opus 5"))
                 "Opus 5"))
  (should (equal (limen-model-of
                  (limen-model-tests--payload "PostModelSwitch" 'to_model "Sonnet"))
                 "Sonnet"))
  (should-not (limen-model-of
               (limen-model-tests--payload "SessionStart" nil nil)))
  (should-not (limen-model-of
               (limen-model-tests--payload "SessionStart" 'model "")))
  (should-not (limen-model-of
               (limen-model-tests--payload "UserPromptSubmit" 'model "Opus 5")))
  (should-not (limen-model-of
               (limen-model-tests--payload "PostModelSwitch" 'from_model "Opus 5"))))

(ert-deftest limen-model-picks-the-spelling-asked-for ()
  (let ((named '((id . "claude-opus-5") (display_name . "Opus 5"))))
    (let ((limen-model-prefer 'display-name))
      (should (equal (limen-model--name named) "Opus 5")))
    (let ((limen-model-prefer 'id))
      (should (equal (limen-model--name named) "claude-opus-5")))
    (let ((limen-model-prefer 'id))
      (should (equal (limen-model--name '((display_name . "Opus 5"))) "Opus 5")))
    (let ((limen-model-prefer 'display-name))
      (should (equal (limen-model--name '((id . "claude-opus-5")))
                     "claude-opus-5")))
    (should-not (limen-model--name '((id . ""))))
    (should-not (limen-model--name nil))))

(ert-deftest limen-model-reports-to-the-pane-the-event-came-from ()
  (let ((limen-model-token "model")
        (limen-model-source "limen")
        calls)
    (cl-letf (((symbol-function 'herdr-api-pane-report-metadata)
               (lambda (pane source &rest arguments)
                 (push (list pane source herdr-socket-path
                             (plist-get arguments :tokens))
                       calls))))
      (limen-model-report "/tmp/alpha.sock" "%1" "Opus 5")
      (should (equal calls
                     '(("%1" "limen" "/tmp/alpha.sock" ((model . "Opus 5")))))))))

(ert-deftest limen-model-leaves-the-hook-filter-before-reaching-herdr ()
  (let (scheduled)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (time repeat function &rest arguments)
                 (push (list time repeat function arguments) scheduled)))
              ((symbol-function 'herdr-api-pane-report-metadata)
               (lambda (&rest _)
                 (ert-fail "reported from inside the hook"))))
      (should-not (limen-model--report-event
                   "claude"
                   (limen-model-tests--payload "SessionStart" 'model "Opus 5")
                   nil nil))
      (should (equal scheduled
                     '((0 nil limen-model-report
                          ("/tmp/alpha.sock" "%1" "Opus 5")))))
      (setq scheduled nil)
      (limen-model--report-event
       "claude" (limen-model-tests--payload "UserPromptSubmit" 'model "Opus 5")
       nil nil)
      (should-not scheduled)
      (limen-model--report-event
       "claude" (limen-model-tests--payload "SessionStart" nil nil) nil nil)
      (should-not scheduled))))

(ert-deftest limen-model-drops-a-report-an-unreachable-server-refuses ()
  (cl-letf (((symbol-function 'herdr-api-pane-report-metadata)
             (lambda (&rest _) (error "no herdr socket"))))
    (should-not (limen-model-report "/tmp/gone.sock" "%1" "Opus 5")))
  (cl-letf (((symbol-function 'herdr-api-pane-report-metadata)
             (lambda (&rest _) (ert-fail "reported without a pane"))))
    (should-not (limen-model-report "/tmp/alpha.sock" nil "Opus 5"))
    (should-not (limen-model-report "/tmp/alpha.sock" "%1" nil))))

(ert-deftest limen-model-mode-asks-for-its-events-and-gives-them-back ()
  (let ((limen-hooks-provider-events nil)
        (limen-hooks-event-functions nil)
        requested removed)
    (cl-letf (((symbol-function 'limen-hooks-request-install)
               (lambda (feature) (push feature requested)))
              ((symbol-function 'limen-hooks-remove-events-everywhere)
               (lambda (events) (setq removed events))))
      (limen-model-mode 1)
      (should (equal requested '("model")))
      (should (equal (alist-get 'claude limen-hooks-provider-events)
                     '(("Stop") ("PostModelSwitch"))))
      (should-not (alist-get 'codex limen-hooks-provider-events))
      (should (memq #'limen-model--report-event limen-hooks-event-functions))
      (limen-model-mode 1)
      (should (equal (alist-get 'claude limen-hooks-provider-events)
                     '(("Stop") ("PostModelSwitch"))))
      (limen-model-mode -1)
      (should-not (alist-get 'claude limen-hooks-provider-events))
      (should-not (memq #'limen-model--report-event limen-hooks-event-functions))
      (should (equal (sort (copy-sequence removed) #'string<)
                     '("PostModelSwitch" "Stop"))))))

(ert-deftest limen-model-keeps-a-claude-only-event-out-of-the-others ()
  (let ((limen-hooks-mode nil)
        (limen-hooks-extra-events nil)
        (limen-hooks-provider-events '((claude ("PostModelSwitch")))))
    (should (equal (limen-hooks-events 'claude) '(("PostModelSwitch"))))
    (should-not (limen-hooks-events 'codex))
    (should (equal (limen-hooks-events) '(("PostModelSwitch"))))))

(provide 'limen-model-tests)
;;; limen-model-tests.el ends here

(ert-deftest limen-model-passes-over-an-agent-already-named ()
  (let ((limen-model-token "model"))
    (should (limen-model--reported-p '((tokens . ((model . "claude-opus-5"))))))
    (should-not (limen-model--reported-p '((tokens . ((model . ""))))))
    (should-not (limen-model--reported-p '((tokens . ((context . "1k/200k"))))))
    (should-not (limen-model--reported-p '((pane_id . "%1"))))))
