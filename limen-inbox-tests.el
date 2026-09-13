;;; limen-inbox-tests.el --- Inbox tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-inbox)

(defvar herdr-status-sections-functions)

(defun limen-inbox-tests--payload (event &rest fields)
  (append fields
          `((hook_event_name . ,event) (session_id . "agent-1")
            (server . "/tmp/alpha.sock") (pane . "%1"))))

(defconst limen-inbox-tests--claude-input
  '((questions . [((question . "Which database?") (header . "Database")
                   (options . [((label . "PostgreSQL") (description . "strong"))
                               ((label . "MongoDB"))])
                   (multiSelect . :false))
                  ((question . "Include tests?") (header . "Scope")
                   (options . [((label . "Yes")) ((label . "No"))])
                   (multiSelect . t))])))

(defconst limen-inbox-tests--codex-input
  '((questions . [((id . "q1") (question . "Which cache?") (header . "Cache")
                   (options . [((label . "Redis")) ((label . "Memory"))])
                   (isOther . t) (isSecret . :false))])))

(defmacro limen-inbox-tests--with-inbox (&rest body)
  (declare (indent 0) (debug t))
  `(let ((limen-inbox--questions nil)
         (refreshes 0))
     (cl-letf (((symbol-function 'herdr-status-request-refresh)
                (lambda () (cl-incf refreshes))))
       ,@body)))

(defun limen-inbox-tests--event (event &rest fields)
  (limen-inbox--on-event "claude" (apply #'limen-inbox-tests--payload event fields)
                         nil nil))

(ert-deftest limen-inbox-tracks-questions-from-ask-to-answer ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                              '(tool_use_id . "t1")
                              (cons 'tool_input limen-inbox-tests--claude-input))
    (should (= refreshes 1))
    (let ((entry (car (limen-inbox-questions))))
      (should (equal (alist-get 'id entry) "t1"))
      (should (equal (alist-get 'agent_session entry) "agent-1"))
      (should (equal (alist-get 'server entry) (file-truename "/tmp/alpha.sock")))
      (should (equal (alist-get 'pane entry) "%1"))
      (should (equal (mapcar (lambda (question)
                               (list (alist-get 'header question)
                                     (alist-get 'question question)
                                     (alist-get 'options question)
                                     (alist-get 'multi question)
                                     (alist-get 'other question)))
                             (alist-get 'questions entry))
                     '(("Database" "Which database?" ("PostgreSQL" "MongoDB") nil nil)
                       ("Scope" "Include tests?" ("Yes" "No") t nil)))))
    (limen-inbox--on-event "codex"
                           (limen-inbox-tests--payload
                            "PreToolUse" '(session_id . "agent-2")
                            '(tool_name . "request_user_input") '(tool_use_id . "c1")
                            (cons 'tool_input limen-inbox-tests--codex-input))
                           nil nil)
    (should (= (length (limen-inbox-questions)) 2))
    (should (equal (alist-get 'other (car (alist-get 'questions
                                                     (cadr (limen-inbox-questions)))))
                   t))
    (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                              '(tool_use_id . "t1")
                              (cons 'tool_input limen-inbox-tests--codex-input))
    (should (= (length (limen-inbox-questions)) 2))
    (should (equal (mapcar (lambda (entry) (alist-get 'id entry))
                           (limen-inbox-questions))
                   '("c1" "t1")))
    (limen-inbox-tests--event "PreToolUse" '(tool_name . "Bash")
                              '(tool_use_id . "b1")
                              '(tool_input . ((command . "ls"))))
    (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                              '(tool_use_id . "t2")
                              '(tool_input . ((questions . []))))
    (limen-inbox-tests--event "PostToolUse" '(tool_name . "Bash") '(tool_use_id . "b1"))
    (limen-inbox-tests--event "PostToolUse" '(tool_name . "AskUserQuestion")
                              '(tool_use_id . "unknown"))
    (should (= (length (limen-inbox-questions)) 2))
    (should (= refreshes 3))
    (limen-inbox-tests--event "PostToolUse" '(tool_name . "AskUserQuestion")
                              '(tool_use_id . "t1"))
    (should (equal (mapcar (lambda (entry) (alist-get 'id entry))
                           (limen-inbox-questions))
                   '("c1")))
    (should (= refreshes 4))
    (limen-inbox-tests--event "Stop")
    (should (= (length (limen-inbox-questions)) 1))
    (limen-inbox-tests--event "Stop" '(session_id . "agent-2"))
    (should-not (limen-inbox-questions))
    (should (= refreshes 5))
    (dolist (event '("UserPromptSubmit" "SessionEnd" "PostToolUse"))
      (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                                '(tool_use_id . "again")
                                (cons 'tool_input limen-inbox-tests--claude-input))
      (limen-inbox-tests--event event '(tool_name . "AskUserQuestion"))
      (should-not (limen-inbox-questions)))
    (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                              (cons 'tool_input limen-inbox-tests--claude-input))
    (should (string-prefix-p "agent-1:" (alist-get 'id (car (limen-inbox-questions)))))
    (limen-inbox-clear)
    (should-not (limen-inbox-questions))))

(defconst limen-inbox-tests--transcript-lines
  (list
   "{\"timestamp\":\"t\",\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn-1\"}}"
   (concat "{\"timestamp\":\"t\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\","
           "\"name\":\"request_user_input_async\",\"arguments\":\"{\\\"questions\\\":[{\\\"title\\\":\\\"Old?\\\",\\\"options\\\":[\\\"a\\\"]}]}\","
           "\"call_id\":\"call_old\",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"turn-1\"}}}")
   "{\"timestamp\":\"t\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"questions\":[{\"title\":\"noise request_user_input\"}]}}}"
   (concat "{\"timestamp\":\"t\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\","
           "\"name\":\"request_user_input_async\",\"arguments\":\"{\\\"questions\\\":[{\\\"title\\\":\\\"Which cache?\\\",\\\"options\\\":[\\\"Redis\\\",\\\"Memory\\\"]}]}\","
           "\"call_id\":\"call_new\",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"turn-2\"}}}")
   (concat "{\"timestamp\":\"t\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\","
           "\"name\":\"request_user_input\",\"arguments\":\"{\\\"questions\\\":[{\\\"id\\\":\\\"q\\\",\\\"header\\\":\\\"Scope\\\",\\\"question\\\":\\\"Tests?\\\",\\\"options\\\":[{\\\"label\\\":\\\"Yes\\\"}],\\\"isOther\\\":true}]}\","
           "\"call_id\":\"call_sync\",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"turn-2\"}}}")
   "{\"timestamp\":\"t\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"call_new\",\"output\":\"{\\\"accepted\\\":true}\"}}"
   "{\"timestamp\":\"t\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-2\"}}"))

(ert-deftest limen-inbox-reads-codex-questions-from-the-transcript-on-stop ()
  (limen-inbox-tests--with-inbox
    (let ((transcript (make-temp-file "limen-inbox-rollout" nil ".jsonl"))
          (limen-inbox-transcript-tail-bytes 4096))
      (unwind-protect
          (progn
            (with-temp-file transcript
              (dotimes (_ 200)
                (insert "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"filler\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}}\n"))
              (insert (string-join limen-inbox-tests--transcript-lines "\n") "\n"))
            (limen-inbox--on-event "codex"
                                   (limen-inbox-tests--payload
                                    "Stop" '(session_id . "codex-1") '(turn_id . "turn-2")
                                    (cons 'transcript_path transcript))
                                   nil nil)
            (should (= refreshes 1))
            (should (equal (mapcar (lambda (entry)
                                     (list (alist-get 'id entry)
                                           (alist-get 'agent_session entry)
                                           (mapcar (lambda (question)
                                                     (list (alist-get 'header question)
                                                           (alist-get 'question question)
                                                           (alist-get 'options question)
                                                           (alist-get 'other question)))
                                                   (alist-get 'questions entry))))
                                   (limen-inbox-questions))
                           '(("call_new" "codex-1" ((nil "Which cache?" ("Redis" "Memory") nil)))
                             ("call_sync" "codex-1" (("Scope" "Tests?" ("Yes") t))))))
            (limen-inbox--on-event "codex"
                                   (limen-inbox-tests--payload
                                    "Stop" '(session_id . "codex-1") '(turn_id . "turn-3")
                                    (cons 'transcript_path transcript))
                                   nil nil)
            (should-not (limen-inbox-questions))
            (limen-inbox--on-event "claude"
                                   (limen-inbox-tests--payload
                                    "Stop" '(session_id . "codex-1") '(turn_id . "turn-2")
                                    (cons 'transcript_path transcript))
                                   nil nil)
            (should-not (limen-inbox-questions))
            (limen-inbox--on-event "codex"
                                   (limen-inbox-tests--payload
                                    "Stop" '(session_id . "codex-1") '(turn_id . "turn-2")
                                    '(transcript_path . "/nonexistent/rollout.jsonl"))
                                   nil nil)
            (should-not (limen-inbox-questions)))
        (delete-file transcript)))))

(ert-deftest limen-inbox-groups-questions-by-dashboard-agent-and-prunes-the-rest ()
  (limen-inbox-tests--with-inbox
    (let ((alpha `((server_key . "/tmp/alpha.sock") (pane_id . "%1") (name . "api")))
          (beta `((server_key . "/tmp/alpha.sock") (pane_id . "%2") (name . "docs"))))
      (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                                '(tool_use_id . "t1")
                                (cons 'tool_input limen-inbox-tests--claude-input))
      (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                                '(tool_use_id . "t2") '(pane . "%9")
                                (cons 'tool_input limen-inbox-tests--codex-input))
      (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                                '(tool_use_id . "t3") '(pane . "%1")
                                (cons 'tool_input limen-inbox-tests--codex-input))
      (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                                '(tool_use_id . "t4") '(pane . "")
                                (cons 'tool_input limen-inbox-tests--codex-input))
      (let ((groups (limen-inbox--groups (list alpha beta))))
        (should (= (length groups) 1))
        (should (eq (caar groups) alpha))
        (should (equal (mapcar (lambda (question) (alist-get 'header question))
                               (cdar groups))
                       '("Database" "Scope" "Cache"))))
      (should (equal (mapcar (lambda (entry) (alist-get 'id entry))
                             (limen-inbox-questions))
                     '("t1" "t3")))
      (should-not (limen-inbox--groups (list beta)))
      (should-not (limen-inbox-questions)))))

(ert-deftest limen-inbox-drops-transcript-questions-once-the-agent-is-not-blocked ()
  (limen-inbox-tests--with-inbox
    (let* ((idle `((server_key . "/tmp/alpha.sock") (pane_id . "%1")
                   (agent_status . "idle")))
           (blocked `((server_key . "/tmp/alpha.sock") (pane_id . "%1")
                      (agent_status . "blocked")))
           (limen-inbox-settle-seconds 10)
           (entry `((id . "call_1") (agent_session . "codex-1")
                    (server . ,(file-truename "/tmp/alpha.sock")) (pane . "%1")
                    (asked . ,(current-time)) (source . transcript)
                    (questions . (((header) (question . "Which?")
                                   (options "a") (multi) (other)))))))
      (limen-inbox--add entry)
      (should (limen-inbox--groups (list idle)))
      (should (limen-inbox-questions))
      (setf (alist-get 'asked entry) (time-subtract (current-time) 60))
      (should (limen-inbox--groups (list blocked)))
      (should (limen-inbox-questions))
      (should-not (limen-inbox--groups (list idle)))
      (should-not (limen-inbox-questions))
      (limen-inbox--add (append '((source . hook)) (copy-alist entry)))
      (should (limen-inbox--groups (list idle)))
      (should (limen-inbox-questions)))))

(ert-deftest limen-inbox-mode-registers-events-and-installs-hooks ()
  (let* ((directory (make-temp-file "limen-inbox-settings" t))
         (process-environment
          (append (list (concat "CLAUDE_CONFIG_DIR=" directory)
                        (concat "CODEX_HOME=" (expand-file-name "codex" directory)))
                  process-environment))
         (limen-hooks-command "limen")
         (limen-hooks-mode t)
         (limen-hooks-extra-events nil)
         (limen-hooks-event-functions nil)
         (herdr-status-sections-functions nil)
         (limen-inbox--questions nil))
    (unwind-protect
        (progn
          (limen-inbox-mode -1)
          (limen-hooks-install 'claude)
          (should (equal (mapcar #'car (limen-hooks-events))
                         '("UserPromptSubmit" "SessionStart")))
          (limen-inbox-mode 1)
          (should (equal (mapcar #'car (limen-hooks-events))
                         '("UserPromptSubmit" "SessionStart" "PreToolUse"
                           "PostToolUse" "Stop" "SessionEnd")))
          (should (memq #'limen-inbox--on-event limen-hooks-event-functions))
          (should (memq #'limen-inbox--insert-section
                        herdr-status-sections-functions))
          (should (limen-hooks-installed-p 'claude))
          (should (limen-hooks-installed-p 'codex))
          (limen-inbox-mode -1)
          (should (equal (mapcar #'car (limen-hooks-events))
                         '("UserPromptSubmit" "SessionStart")))
          (should-not (memq #'limen-inbox--on-event limen-hooks-event-functions))
          (should (limen-hooks-installed-p 'claude))
          (should (limen-hooks-installed-p 'codex))
          (dolist (provider '(claude codex))
            (should-not (limen-hooks--event-installed-p
                         (limen-hooks--read-settings
                          (limen-hooks-settings-file provider))
                         "PreToolUse" provider))))
      (limen-inbox-mode -1)
      (delete-directory directory t))))

(provide 'limen-inbox-tests)
;;; limen-inbox-tests.el ends here
