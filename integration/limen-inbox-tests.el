;;; limen-inbox-tests.el --- Inbox dashboard tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'herdr-status)
(require 'herdr-status-tests)
(require 'limen-inbox)

(defun limen-inbox-tests--ask (pane id)
  (limen-inbox--on-event
   "claude"
   `((hook_event_name . "PreToolUse") (session_id . ,(concat "agent-" pane))
     (server . "/tmp/alpha.sock") (pane . ,pane)
     (tool_name . "AskUserQuestion") (tool_use_id . ,id)
     (tool_input
      . ((questions . [((question . "Which database?") (header . "Database")
                        (options . [((label . "PostgreSQL")) ((label . "MongoDB"))])
                        (multiSelect . :false))]))))
   nil nil))

(ert-deftest limen-inbox-section-lists-pending-questions-and-hides-when-empty ()
  (let ((limen-inbox--questions nil)
        (herdr-status-sections-functions '(limen-inbox--insert-section))
        (herdr-status-auto-refresh nil))
    (herdr-status-tests--with-dashboard
      (should-not (re-search-forward "^Inbox" nil t))
      (limen-inbox-tests--ask "%1" "t1")
      (limen-inbox-tests--ask "%9" "t2")
      (herdr-status-refresh)
      (herdr-status-tests--expand)
      (goto-char (point-min))
      (should (looking-at "Inbox 1"))
      (forward-line 1)
      (should (looking-at " +. +api-review +. +claude"))
      (should (equal (herdr-status-target-at-point) '("/tmp/alpha.sock" . "t1")))
      (forward-line 1)
      (should (looking-at "    Database: Which database\\?$"))
      (forward-line 1)
      (should (looking-at "      PostgreSQL · MongoDB$"))
      (forward-line 1)
      (should (looking-at "Recent\\|Agents"))
      (should (equal (mapcar (lambda (entry) (alist-get 'id entry))
                             (limen-inbox-questions))
                     '("t1")))
      (limen-inbox--on-event
       "claude"
       '((hook_event_name . "PostToolUse") (session_id . "agent-%1")
         (tool_name . "AskUserQuestion") (tool_use_id . "t1"))
       nil nil)
      (herdr-status-refresh)
      (goto-char (point-min))
      (should-not (re-search-forward "^Inbox" nil t)))))

(provide 'limen-inbox-integration-tests)
;;; limen-inbox-tests.el ends here
