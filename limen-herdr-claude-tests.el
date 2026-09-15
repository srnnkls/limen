;;; limen-herdr-claude-tests.el --- Claude adoption tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-herdr-claude)

(defun limen-herdr-claude-tests--agent (name)
  "Return a Herdr Claude agent entry called NAME."
  `((agent . "claude") (agent_status . "idle") (name . ,name)
    (terminal_id . ,(concat "term-" name))
    (pane_id . ,(concat "%" name))
    (cwd . "/tmp")))

(defun limen-herdr-claude-tests--detected (name)
  "Return the event payload announcing the agent called NAME."
  `((agent . "claude") (pane_id . ,(concat "%" name))))

(ert-deftest limen-herdr-claude-auto-adoption-opens-no-terminal ()
  "Opening a terminal costs a third of a second an automatic adoption
never asked for, so the agent is taken up and the terminal is not."
  (let ((limen-herdr-claude--adopt-queue nil)
        (limen-herdr-claude--adopt-timer nil)
        (limen-herdr-claude-auto-adopt-predicate (lambda (_agent) t))
        (limen-herdr-claude-connect-on-adopt nil)
        (scheduled 0)
        (adopted nil))
    (cl-letf (((symbol-function 'herdr-agent-list)
               (lambda (&optional _key)
                 (list (limen-herdr-claude-tests--agent "a"))))
              ((symbol-function 'herdr-agent-adopt)
               (cl-function
                (lambda (agent &key attach display &allow-other-keys)
                  (push (list (alist-get 'name agent) attach display) adopted)
                  'session)))
              ((symbol-function 'run-with-idle-timer)
               (lambda (&rest _) (cl-incf scheduled) 'timer)))
      (limen-herdr-claude--maybe-adopt "/tmp/a.sock" "pane.agent_detected"
                                       (limen-herdr-claude-tests--detected "a"))
      (should (= scheduled 1))
      (should-not adopted)
      (limen-herdr-claude--drain-adoptions)
      (should (equal adopted '(("a" nil nil))))
      (should-not limen-herdr-claude--adopt-queue))))

(ert-deftest limen-herdr-claude-auto-adoption-queues-an-agent-once ()
  (let ((limen-herdr-claude--adopt-queue nil)
        (limen-herdr-claude--adopt-timer nil)
        (limen-herdr-claude-auto-adopt-predicate (lambda (_agent) t))
        (limen-herdr-claude-connect-on-adopt nil))
    (cl-letf (((symbol-function 'herdr-agent-list)
               (lambda (&optional _key)
                 (list (limen-herdr-claude-tests--agent "a")
                       (limen-herdr-claude-tests--agent "b"))))
              ((symbol-function 'run-with-idle-timer)
               (lambda (&rest _) 'timer)))
      (dotimes (_ 3)
        (limen-herdr-claude--maybe-adopt "/tmp/a.sock" "pane.agent_detected"
                                         (limen-herdr-claude-tests--detected "a")))
      (limen-herdr-claude--maybe-adopt "/tmp/a.sock" "pane.agent_detected"
                                       (limen-herdr-claude-tests--detected "b"))
      (should (equal (mapcar (lambda (queued)
                               (alist-get 'name (car queued)))
                             limen-herdr-claude--adopt-queue)
                     '("a" "b"))))))

(ert-deftest limen-herdr-claude-auto-adoption-ignores-a-released-pane ()
  (let ((limen-herdr-claude--adopt-queue nil)
        (limen-herdr-claude--adopt-timer nil)
        (limen-herdr-claude-auto-adopt-predicate (lambda (_agent) t)))
    (cl-letf (((symbol-function 'herdr-agent-list)
               (lambda (&optional _key)
                 (list (limen-herdr-claude-tests--agent "a"))))
              ((symbol-function 'run-with-idle-timer)
               (lambda (&rest _) 'timer)))
      (limen-herdr-claude--maybe-adopt
       "/tmp/a.sock" "pane.agent_detected"
       (cons '(released . t) (limen-herdr-claude-tests--detected "a")))
      (should-not limen-herdr-claude--adopt-queue))))

(provide 'limen-herdr-claude-tests)
;;; limen-herdr-claude-tests.el ends here
