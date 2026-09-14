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
         (limen-inbox--selected (make-hash-table :test 'equal))
         (limen-inbox--sent (make-hash-table :test 'equal))
         (limen-inbox--tabs (make-hash-table :test 'equal))
         (limen-inbox-key-delay 0)
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

(ert-deftest limen-inbox-numbers-questions-with-a-stable-qid ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                              '(tool_use_id . "t1")
                              (cons 'tool_input limen-inbox-tests--claude-input))
    (let ((questions (alist-get 'questions (car (limen-inbox-questions)))))
      (should (equal (mapcar (lambda (q) (alist-get 'qid q)) questions)
                     '("t1#0" "t1#1")))
      (should (equal (mapcar (lambda (q) (alist-get 'answerable q)) questions)
                     '(t t))))))

(ert-deftest limen-inbox-marks-transcript-questions-unanswerable ()
  (limen-inbox-tests--with-inbox
    (let ((transcript (make-temp-file "limen-inbox-rollout" nil ".jsonl")))
      (unwind-protect
          (progn
            (with-temp-file transcript
              (insert (string-join limen-inbox-tests--transcript-lines "\n") "\n"))
            (limen-inbox--on-event "codex"
                                   (limen-inbox-tests--payload
                                    "Stop" '(session_id . "codex-1")
                                    '(turn_id . "turn-2")
                                    (cons 'transcript_path transcript))
                                   nil nil)
            (let ((questions (alist-get 'questions (car (limen-inbox-questions)))))
              (should (equal (alist-get 'qid (car questions)) "call_new#0"))
              (should-not (alist-get 'answerable (car questions)))))
        (delete-file transcript)))))

(ert-deftest limen-inbox-renders-a-read-only-line-with-the-flag-off ()
  (let ((limen-inbox-answer nil))
    (with-temp-buffer
      (limen-inbox--insert-question
       '((qid . "t1#0") (answerable . t) (header . "Database")
         (question . "Which?") (options "PostgreSQL" "MongoDB") (multi) (other))
       '("/tmp/alpha.sock" . "t1") t)
      (should (string-match-p "PostgreSQL · MongoDB" (buffer-string)))
      (should-not (string-match-p "[○●]" (buffer-string))))))

(defmacro limen-inbox-tests--with-value (value &rest body)
  "Run BODY with section VALUE and recorded individual pane keys."
  (declare (indent 1) (debug t))
  `(let (sent)
     (cl-letf (((symbol-function 'limen-inbox--value) (lambda (_type) ,value))
               ((symbol-function 'herdr-agent-send-keys)
                (lambda (target keys)
                  (should (equal target '("/tmp/alpha.sock" . "t1")))
                  (should (= (length keys) 1))
                  (setq sent (append sent keys))))
               ((symbol-function 'limen-inbox--next-question) #'ignore)
               ((symbol-function 'y-or-n-p) (lambda (_) nil)))
       ,@body)))

(ert-deftest limen-inbox-toggles-without-sending ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--with-value '(:qid "t1#0" :label "Yes" :multi t)
      (limen-inbox-toggle-at-point)
      (should (equal (gethash "t1#0" limen-inbox--selected) '("Yes")))
      (limen-inbox-toggle-at-point)
      (should-not (gethash "t1#0" limen-inbox--selected))
      (should-not sent))))

(ert-deftest limen-inbox-recommits-only-the-multi-select-difference ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--with-value
        '(:qid "t1#0" :options ("A" "B" "C") :multi t
          :target ("/tmp/alpha.sock" . "t1"))
      (puthash "t1#0" '("A" "B") limen-inbox--selected)
      (limen-inbox-commit-at-point)
      (should (equal sent '("1" "2" "right")))
      (should (limen-inbox--committed-p "t1#0"))
      (limen-inbox--toggle "t1#0" "A" t)
      (limen-inbox--toggle "t1#0" "C" t)
      (should-not (limen-inbox--committed-p "t1#0"))
      (setq sent nil)
      (limen-inbox-commit-at-point)
      (should (equal sent '("left" "1" "3" "right")))
      (should (equal (gethash "t1#0" limen-inbox--sent) '("B" "C")))
      (setq sent nil)
      (limen-inbox-commit-at-point)
      (should (equal sent '("left" "right"))))))

(ert-deftest limen-inbox-replaces-single-select-without-toggling-old-choice ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--with-value
        '(:qid "t1#0" :options ("A" "B")
          :target ("/tmp/alpha.sock" . "t1"))
      (puthash "t1#0" '("A") limen-inbox--selected)
      (limen-inbox-commit-at-point)
      (limen-inbox--toggle "t1#0" "B" nil)
      (setq sent nil)
      (limen-inbox-commit-at-point)
      (should (equal sent '("left" "2" "right"))))))

(ert-deftest limen-inbox-navigates-out-of-order-and-isolates-entries ()
  (limen-inbox-tests--with-inbox
    (puthash "other" 4 limen-inbox--tabs)
    (limen-inbox-tests--with-value
        '(:qid "t1#2" :options ("A" "B")
          :target ("/tmp/alpha.sock" . "t1"))
      (puthash "t1#2" '("B") limen-inbox--selected)
      (limen-inbox-commit-at-point)
      (should (equal sent '("right" "right" "2" "right")))
      (should (= (gethash "t1" limen-inbox--tabs) 3))
      (should (= (gethash "other" limen-inbox--tabs) 4)))))

(ert-deftest limen-inbox-submission-requires-every-current-selection-committed ()
  (limen-inbox-tests--with-inbox
    (limen-inbox--add '((id . "t1")
                        (questions ((qid . "t1#0")) ((qid . "t1#1")))) )
    (puthash "t1#0" '("A") limen-inbox--selected)
    (puthash "t1#1" '("B") limen-inbox--selected)
    (limen-inbox-tests--with-value
        '(:qid "t1#1" :options ("A" "B") :last t
          :target ("/tmp/alpha.sock" . "t1"))
      (let ((prompts 0))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (_) (cl-incf prompts) nil)))
          (limen-inbox-commit-at-point)
          (should (= prompts 0))
          (puthash "t1#0" '("A") limen-inbox--sent)
          (limen-inbox-commit-at-point)
          (should (= prompts 1))
          (should (limen-inbox-questions))
          (limen-inbox--toggle "t1#0" "B" nil)
          (limen-inbox-commit-at-point)
          (should (= prompts 1))
          (puthash "t1#0" '("B") limen-inbox--sent))
        (setq sent nil)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
          (limen-inbox-commit-at-point))
        (should (equal sent '("left" "right" "return" "return")))
        (should-not (limen-inbox-questions))
        (should (= (hash-table-count limen-inbox--sent) 0))
        (should (= (hash-table-count limen-inbox--selected) 0))
        (should (= (hash-table-count limen-inbox--tabs) 0))))))

(ert-deftest limen-inbox-refuses-to-commit-without-herdr-agent ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--with-value
        '(:qid "t1#0" :options ("A") :target ("/tmp/alpha.sock" . "t1"))
      (puthash "t1#0" '("A") limen-inbox--selected)
      (cl-letf (((symbol-function 'herdr-agent-send-keys) nil))
        (limen-inbox-commit-at-point))
      (should-not (gethash "t1#0" limen-inbox--sent)))))

(ert-deftest limen-inbox-blocks-replay-after-partial-send-failure ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--with-value
        '(:qid "t1#0" :options ("A" "B") :multi t
          :target ("/tmp/alpha.sock" . "t1"))
      (puthash "t1#0" '("A" "B") limen-inbox--selected)
      (let ((calls 0))
        (cl-letf (((symbol-function 'herdr-agent-send-keys)
                   (lambda (&rest _) (when (= (cl-incf calls) 2) (error "Disconnected")))))
          (should-error (limen-inbox-commit-at-point))
          (should (eq (gethash "t1" limen-inbox--tabs) 'unknown))
          (should-error (limen-inbox-commit-at-point) :type 'user-error)
          (should (= calls 2)))))))

(provide 'limen-inbox-tests)
;;; limen-inbox-tests.el ends here
