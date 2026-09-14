;;; limen-herd-tests.el --- Herd notice tests against herdr-herd -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'herdr-herd)
(require 'herdr-herd-tests)
(require 'herdr-status)
(require 'limen-herd)

(defmacro limen-herd-integration-tests--with-state (&rest body)
  (declare (indent 0) (debug t))
  `(let ((limen-herd--prompts (make-hash-table :test #'equal))
         (limen-herd--held (make-hash-table :test #'equal))
         (limen-herd--names (make-hash-table :test #'equal)))
     ,@body))

(defun limen-herd-integration-tests--event (event pane session &rest fields)
  (limen-herd--on-event "codex"
                        (append fields `((hook_event_name . ,event)
                                         (session_id . ,session)
                                         (server . "/tmp/alpha.sock")
                                         (pane . ,pane)))
                        nil nil))

(ert-deftest limen-herd-resolves-recipients-through-herdr ()
  (let ((one (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                      :name "one" :session "s1" :pane "w1:p1"
                                      :label "herd:refactor"))
        (two (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                      :name "two" :session "s2" :pane "w2:p1"
                                      :label "herd:refactor notify:finished"))
        (three (herdr-herd-tests--entry "/tmp/dotfiles/" "dots"
                                        :name "three" :session "s3" :pane "w3:p1"
                                        :label "herd:refactor"))
        (loose (herdr-herd-tests--entry "/tmp/dotfiles/" "loose"
                                        :name "loose" :session "s4" :pane "w4:p1"
                                        :label "notify:finished")))
    (herdr-herd-tests--with-stubs (list one two three loose)
      (limen-herd-integration-tests--with-state
        (limen-herd-integration-tests--event "UserPromptSubmit" "w1:p1" "s1"
                                             '(prompt . "rebase onto main"))
        (limen-herd-integration-tests--event "Stop" "w1:p1" "s1")
        (should (equal herdr-herd-tests--prompts
                       (list (cons (herdr--entry-target two)
                                   "[herd refactor] one finished: \"rebase onto main\". No reply needed."))))
        (limen-herd-integration-tests--event "UserPromptSubmit" "w4:p1" "s4"
                                             '(prompt . "alone"))
        (limen-herd-integration-tests--event "Stop" "w4:p1" "s4")
        (should (= (length herdr-herd-tests--prompts) 1))
        (limen-herd-subscribe (list three) '(exited))
        (should (equal (car herdr-herd-tests--renames)
                       '("w3:p1" . "herd:refactor notify:exited")))))))

(ert-deftest limen-herd-joining-members-learn-about-notices ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                        :name "one" :session "s1" :pane "w1:p1"))
        (herdr-herd-protocol-functions (list #'limen-herd--protocol)))
    (herdr-herd-tests--with-stubs (list entry)
      (herdr-herd-add (list entry) '("alpha" . "refactor"))
      (should (string-match-p "notify:finished,exited"
                              (cdr (car herdr-herd-tests--prompts)))))))

(ert-deftest limen-herd-menu-attaches-to-the-dashboard-and-detaches ()
  (unwind-protect
      (progn
        (limen-herd--attach-menu)
        (should (transient-get-suffix 'herdr-status-dispatch "n"))
        (should (transient-get-suffix 'herdr-herd-dispatch "n"))
        (should (eq (lookup-key herdr-status-mode-map "n") #'limen-herd-dispatch))
        (limen-herd--attach-menu)
        (limen-herd--detach-menu)
        (should-not (ignore-errors (transient-get-suffix 'herdr-status-dispatch "n")))
        (should-not (ignore-errors (transient-get-suffix 'herdr-herd-dispatch "n")))
        (should-not (lookup-key herdr-status-mode-map "n")))
    (limen-herd--detach-menu)))

(provide 'limen-herd-integration-tests)
;;; limen-herd-tests.el ends here
