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
         (limen-inbox--notes (make-hash-table :test 'equal))
         (limen-inbox--sent-notes (make-hash-table :test 'equal))
         (limen-inbox-key-delay 0)
         (limen-inbox-inline-notes nil)
         (refreshes 0))
     (cl-letf (((symbol-function 'herdr-status-request-refresh)
                (lambda () (cl-incf refreshes))))
       ,@body)))

(defun limen-inbox-tests--event (event &rest fields)
  (limen-inbox--on-event "claude" (apply #'limen-inbox-tests--payload event fields)
                         'session nil))

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
                           'session nil)
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
          (limen-transcript-tail-bytes 4096))
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
                                   'session nil)
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
                                   'session nil)
            (should-not (limen-inbox-questions))
            (limen-inbox--on-event "claude"
                                   (limen-inbox-tests--payload
                                    "Stop" '(session_id . "codex-1") '(turn_id . "turn-2")
                                    (cons 'transcript_path transcript))
                                   'session nil)
            (should-not (limen-inbox-questions))
            (limen-inbox--on-event "codex"
                                   (limen-inbox-tests--payload
                                    "Stop" '(session_id . "codex-1") '(turn_id . "turn-2")
                                    '(transcript_path . "/nonexistent/rollout.jsonl"))
                                   'session nil)
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

(ert-deftest limen-inbox-mode-keeps-installed-hooks-when-disabled ()
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
          (let ((settings-before
                 (mapcar (lambda (provider)
                           (cons provider
                                 (with-temp-buffer
                                   (insert-file-contents (limen-hooks-settings-file provider))
                                   (buffer-string))))
                         '(claude codex))))
            (cl-letf (((symbol-function 'limen-hooks--write-settings)
                       (lambda (&rest _) (ert-fail "Disabling rewrote provider settings"))))
              (limen-inbox-mode -1))
            (dolist (entry settings-before)
              (should (equal (cdr entry)
                             (with-temp-buffer
                               (insert-file-contents (limen-hooks-settings-file (car entry)))
                               (buffer-string))))))
          (should (equal (mapcar #'car (limen-hooks-events))
                         '("UserPromptSubmit" "SessionStart")))
          (should-not (memq #'limen-inbox--on-event limen-hooks-event-functions))
          (should-not (memq #'limen-inbox--insert-section herdr-status-sections-functions))
          (should (limen-hooks-installed-p 'claude))
          (should (limen-hooks-installed-p 'codex))
          (dolist (provider '(claude codex))
            (should (limen-hooks--event-installed-p
                     (limen-hooks--read-settings
                      (limen-hooks-settings-file provider))
                     "PreToolUse" provider))
            (should (limen-hooks-uninstall provider))
            (should-not (limen-hooks-any-installed-p provider))))
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
                                   'session nil)
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
      (let ((prompts 0)
            (limen-inbox-answer-submit-eagerly t))
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

(ert-deftest limen-inbox-dismisses-from-submit-tab-and-attaches ()
  (dolist (multi '(nil t))
    (limen-inbox-tests--with-inbox
      (limen-inbox--add '((id . "t1")
                          (questions ((qid . "t1#0")) ((qid . "t1#1")))))
      (puthash "t1" 2 limen-inbox--tabs)
      (puthash "t1#0" '("A") limen-inbox--selected)
      (puthash "t1#1" '("B") limen-inbox--sent)
      (limen-inbox-tests--with-value
          (list :qid "t1#0" :options '("A" "B" "C") :multi multi
                :target '("/tmp/alpha.sock" . "t1"))
        (let (attached)
          (cl-letf (((symbol-function 'herdr-agent-switch)
                     (lambda (target)
                       (should (equal sent '("left" "left" "5")))
                       (should-not (limen-inbox-questions))
                       (setq attached target))))
            (limen-inbox-dismiss-at-point))
          (should (equal attached '("/tmp/alpha.sock" . "t1")))
          (should (= (hash-table-count limen-inbox--selected) 0))
          (should (= (hash-table-count limen-inbox--sent) 0))
          (should (= (hash-table-count limen-inbox--tabs) 0)))))))

(ert-deftest limen-inbox-dismissal-without-attachment-api-sends-nothing ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--with-value
        '(:qid "t1#0" :options ("A" "B") :target ("/tmp/alpha.sock" . "t1"))
      (cl-letf (((symbol-function 'herdr-agent-switch) nil))
        (should-error (limen-inbox-dismiss-at-point) :type 'user-error))
      (should-not sent))))

(ert-deftest limen-inbox-failed-dismissal-keeps-entry-and-does-not-attach ()
  (limen-inbox-tests--with-inbox
    (limen-inbox--add '((id . "t1") (questions ((qid . "t1#0")))))
    (limen-inbox-tests--with-value
        '(:qid "t1#0" :options ("A" "B") :target ("/tmp/alpha.sock" . "t1"))
      (cl-letf (((symbol-function 'herdr-agent-send-keys)
                 (lambda (&rest _) (error "Disconnected")))
                ((symbol-function 'herdr-agent-switch)
                 (lambda (_) (ert-fail "Must not attach after a failed dismissal"))))
        (should-error (limen-inbox-dismiss-at-point)))
      (should (limen-inbox-questions))
      (should (eq (gethash "t1" limen-inbox--tabs) 'unknown)))))

(ert-deftest limen-inbox-dismissal-without-target-keeps-entry ()
  (limen-inbox-tests--with-inbox
    (limen-inbox--add '((id . "t1") (questions ((qid . "t1#0")))))
    (limen-inbox-tests--with-value '(:qid "t1#0" :options ("A" "B"))
      (cl-letf (((symbol-function 'herdr-agent-switch)
                 (lambda (_) (ert-fail "Must not attach without a target"))))
        (limen-inbox-dismiss-at-point))
      (should-not sent)
      (should (limen-inbox-questions)))))

(ert-deftest limen-inbox-eager-submit-is-opt-in-for-single-and-multiple-questions ()
  (dolist (eager '(nil t))
    (dolist (count '(1 2))
      (limen-inbox-tests--with-inbox
        (let ((limen-inbox-answer-submit-eagerly eager)
              (prompts 0)
              (last-qid (format "t1#%d" (1- count))))
          (limen-inbox--add
           `((id . "t1")
             (questions . ,(cl-loop for index below count
                                    collect `((qid . ,(format "t1#%d" index)))))))
          (when (= count 2)
            (puthash "t1#0" '("A") limen-inbox--selected)
            (puthash "t1#0" '("A") limen-inbox--sent))
          (puthash last-qid '("B") limen-inbox--selected)
          (limen-inbox-tests--with-value
              (list :qid last-qid :options '("A" "B") :last t
                    :target '("/tmp/alpha.sock" . "t1"))
            (cl-letf (((symbol-function 'y-or-n-p)
                       (lambda (_) (cl-incf prompts) t)))
              (limen-inbox-commit-at-point))
            (should (= prompts (if eager 1 0)))
            (should (equal sent
                           (append (when (= count 2) '("right"))
                                   '("2" "right")
                                   (when eager '("return" "return")))))
            (if eager
                (should-not (limen-inbox-questions))
              (should (limen-inbox-questions))
              (should (limen-inbox--committed-p last-qid))
              (should (= (gethash "t1" limen-inbox--tabs) count)))))))))

(ert-deftest limen-inbox-confirmation-decline-or-interruption-allows-retry ()
  (dolist (response '(no quit error))
    (limen-inbox-tests--with-inbox
      (let ((limen-inbox-answer-submit-eagerly t))
        (limen-inbox--add '((id . "t1") (questions ((qid . "t1#0")))))
        (puthash "t1#0" '("A") limen-inbox--selected)
        (limen-inbox-tests--with-value
            '(:qid "t1#0" :options ("A" "B") :last t
              :target ("/tmp/alpha.sock" . "t1"))
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (_)
                       (pcase response
                         ('no nil)
                         ('quit (signal 'quit nil))
                         ('error (error "Confirmation interrupted"))))))
            (pcase response
              ('no (limen-inbox-commit-at-point))
              ('quit (should (condition-case nil
                                 (progn (limen-inbox-commit-at-point) nil)
                               (quit t))))
              ('error (should-error (limen-inbox-commit-at-point)))))
          (should (equal sent '("1" "right")))
          (should (= (gethash "t1" limen-inbox--tabs) 1))
          (should (limen-inbox--committed-p "t1#0"))
          (should (limen-inbox-questions))
          (setq sent nil)
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
            (limen-inbox-commit-at-point))
          (should (equal sent '("left" "right" "return" "return")))
          (should-not (limen-inbox-questions)))))))

(ert-deftest limen-inbox-eager-submit-after-out-of-order-commits ()
  (dolist (confirm '(nil t))
    (limen-inbox-tests--with-inbox
      (let ((limen-inbox-answer-submit-eagerly t)
            (prompts 0)
            (current 2))
        (limen-inbox--add
         '((id . "t1")
           (questions ((qid . "t1#0")) ((qid . "t1#1")) ((qid . "t1#2")))))
        (dolist (qid '("t1#0" "t1#1" "t1#2"))
          (puthash qid '("A") limen-inbox--selected))
        (limen-inbox-tests--with-value
            (list :qid (format "t1#%d" current) :options '("A" "B")
                  :last (= current 2) :target '("/tmp/alpha.sock" . "t1"))
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (_) (cl-incf prompts) confirm)))
            (limen-inbox-commit-at-point)
            (should (= prompts 0))
            (setq current 1)
            (limen-inbox-commit-at-point)
            (should (= prompts 0))
            (setq current 0 sent nil)
            (limen-inbox-commit-at-point)
            (should (= prompts 1))
            (should (equal sent
                           (append '("left" "left" "1" "right")
                                   (when confirm
                                     '("right" "right" "return" "return"))))))
          (if confirm
              (should-not (limen-inbox-questions))
            (should (limen-inbox--ready-p "t1"))
            (should (= (gethash "t1" limen-inbox--tabs) 1))
            (setq sent nil)
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
              (limen-inbox-commit-at-point))
            (should (equal sent '("left" "right" "right" "right" "return" "return")))
            (should-not (limen-inbox-questions))))))))

(ert-deftest limen-inbox-preserves-preview-positions-and-gates-notes ()
  (let* ((record '((options . [((label . "A") (preview . "one\n  two"))
                               ((label . "A"))
                               ((label . "C") (preview . ""))])))
         (question (limen-inbox--question record)))
    (should (equal (alist-get 'options question) '("A" "A" "C")))
    (should (equal (alist-get 'previews question) '("one\n  two" nil "")))
    (should (limen-inbox--preview-p question))
    (setf (alist-get 'multi question) t)
    (should-not (limen-inbox--preview-p question))
    (should-not (limen-inbox--preview-p
                 (limen-inbox--question '((options . ["Redis" "Memory"])))))))

(ert-deftest limen-inbox-notes-edit-is-local-and-cancellation-preserves-state ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--with-value '(:qid "t1#0" :preview t :index 1 :previews ("A"))
      (puthash "t1#0" "Original" limen-inbox--notes)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt initial &rest _)
                   (should (equal initial "Original")) "Revised\nnotes")))
        (limen-inbox-notes-at-point))
      (should (equal (limen-inbox--note "t1#0" 1) "Revised\nnotes"))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (signal 'quit nil))))
        (should (condition-case nil (limen-inbox-notes-at-point) (quit t))))
      (should (equal (limen-inbox--note "t1#0" 1) "Revised\nnotes"))
      (should-not sent))))

(ert-deftest limen-inbox-notes-require-preview-question ()
  (limen-inbox-tests--with-inbox
    (limen-inbox-tests--with-value '(:qid "t1#0")
      (should-error (limen-inbox-notes-at-point) :type 'user-error)
      (should (= (hash-table-count limen-inbox--notes) 0)))))

(ert-deftest limen-inbox-notes-only-commit-tracks-edits-and-clearing ()
  (limen-inbox-tests--with-inbox
    (puthash "t1#0" "Keep it small" limen-inbox--notes)
    (should-not (limen-inbox--committed-p "t1#0"))
    (puthash "t1#0" nil limen-inbox--sent)
    (puthash "t1#0" "Keep it small" limen-inbox--sent-notes)
    (should (limen-inbox--committed-p "t1#0"))
    (puthash "t1#0" "Revised" limen-inbox--notes)
    (should-not (limen-inbox--committed-p "t1#0"))
    (puthash "t1#0" "Keep it small" limen-inbox--notes)
    (should (limen-inbox--committed-p "t1#0"))
    (puthash "t1#0" "  \n " limen-inbox--notes)
    (puthash "t1#0" "  \n " limen-inbox--sent-notes)
    (should-not (limen-inbox--committed-p "t1#0"))))

(ert-deftest limen-inbox-forgets-notes-when-entry-is-removed-or-replaced ()
  (limen-inbox-tests--with-inbox
    (dolist (operation '(remove replace clear))
      (limen-inbox--add '((id . "t1") (questions ((qid . "t1#0")))))
      (puthash "t1#0" "Old" limen-inbox--notes)
      (puthash "t1#0" "Old" limen-inbox--sent-notes)
      (pcase operation
        ('remove (limen-inbox--answered "t1#0"))
        ('replace (limen-inbox--add
                   '((id . "t1") (questions ((qid . "t1#0") (question . "New"))))))
        ('clear (limen-inbox-clear)))
      (should (= (hash-table-count limen-inbox--notes) 0))
      (should (= (hash-table-count limen-inbox--sent-notes) 0)))))

(defmacro limen-inbox-tests--with-preview (&rest body)
  "Run BODY with a two-question preview entry and recorded key/paste calls."
  (declare (indent 0) (debug t))
  `(limen-inbox-tests--with-inbox
     (let ((value '(:qid "p#0" :options ("A" "B") :preview t
                   :header "First" :question "First question?"
                   :target ("/tmp/alpha.sock" . "t1")))
           (screen "☐ First ☐ Second ✔ Submit\nFirst question?\nNotes: press n to add notes\nChat about this")
           (limen-inbox-answer-submit-eagerly nil)
           sent pasted)
       (limen-inbox--add
        '((id . "p")
          (questions ((qid . "p#0") (previews "A" "B"))
                     ((qid . "p#1") (previews "A" "B")))) )
       (cl-letf (((symbol-function 'limen-inbox--value) (lambda (_) value))
                 ((symbol-function 'limen-inbox--next-question) #'ignore)
                 ((symbol-function 'herdr-agent-read) (lambda (_) screen))
                 ((symbol-function 'herdr-agent-send-keys)
                  (lambda (_target keys)
                    (should (= (length keys) 1))
                    (setq sent (append sent keys))
                    (when (equal keys '("return"))
                      (setq screen "☐ First ☐ Second ✔ Submit\nSecond question?\nNotes: press n to add notes\nChat about this"))))
                 ((symbol-function 'herdr-agent-paste)
                  (lambda (_target text)
                    (push text pasted)
                    (setq sent (append sent (list (list :paste text)))))))
         ,@body))))

(ert-deftest limen-inbox-preview-commits-notes-before-answering ()
  (limen-inbox-tests--with-preview
    (puthash "p#0" '("B") limen-inbox--selected)
    (puthash "p#0" "literal λ\nsecond line" limen-inbox--notes)
    (limen-inbox-commit-at-point)
    (should (equal sent '("n" "ctrl+a" "ctrl+k"
                          (:paste "literal λ\nsecond line") "escape" "2" "return")))
    (should (equal pasted '("literal λ\nsecond line")))
    (should (limen-inbox--committed-p "p#0"))
    (should (= (gethash "p" limen-inbox--tabs) 1))))

(ert-deftest limen-inbox-preview-accepts-notes-without-selecting-an-option ()
  (limen-inbox-tests--with-preview
    (puthash "p#0" "Neither design" limen-inbox--notes)
    (limen-inbox-commit-at-point)
    (should (equal sent '("n" "ctrl+a" "ctrl+k" (:paste "Neither design")
                          "escape" "n" "return")))
    (should (limen-inbox--committed-p "p#0"))
    (should-not (gethash "p#0" limen-inbox--selected))))

(ert-deftest limen-inbox-preview-selection-requires-return-without-extra-right ()
  (limen-inbox-tests--with-preview
    (puthash "p#0" '("A") limen-inbox--selected)
    (limen-inbox-commit-at-point)
    (should (equal sent '("1" "return")))
    (should (= (gethash "p" limen-inbox--tabs) 1))))

(ert-deftest limen-inbox-preview-replaces-or-clears-committed-multiline-notes ()
  (dolist (replacement '("Revised" ""))
    (limen-inbox-tests--with-preview
      (setq screen "☐ First ☐ Second ✔ Submit\nFirst question?\nNotes: old\nline\nChat about this")
      (puthash "p#0" '("A") limen-inbox--selected)
      (puthash "p#0" '("A") limen-inbox--sent)
      (puthash "p#0" "old\nline" limen-inbox--sent-notes)
      (puthash "p#0" replacement limen-inbox--notes)
      (puthash "p" 1 limen-inbox--tabs)
      (limen-inbox-commit-at-point)
      (should (equal sent
                     (append '("left" "n") (make-list 8 "right")
                             '("ctrl+a" "ctrl+k" "backspace" "ctrl+a" "ctrl+k")
                             (unless (string-empty-p replacement)
                               (list (list :paste replacement)))
                             '("escape" "1" "return"))))
      (should (equal (gethash "p#0" limen-inbox--sent-notes) replacement)))))

(ert-deftest limen-inbox-preview-unchanged-recommit-only-navigates ()
  (limen-inbox-tests--with-preview
    (setq screen "☐ First ☐ Second ✔ Submit\nFirst question?\nNotes: Done\nChat about this")
    (puthash "p#0" nil limen-inbox--sent)
    (puthash "p#0" "Done" limen-inbox--notes)
    (puthash "p#0" "Done" limen-inbox--sent-notes)
    (puthash "p" 1 limen-inbox--tabs)
    (limen-inbox-commit-at-point)
    (should (equal sent '("left" "right")))
    (should-not pasted)))

(ert-deftest limen-inbox-preview-single-question-confirms-before-any-answer ()
  (dolist (confirm '(nil t))
    (limen-inbox-tests--with-preview
      (setq limen-inbox-answer-submit-eagerly t
            screen "☐ First\nFirst question?\nNotes: press n to add notes\nChat about this")
      (setf (alist-get 'questions (car limen-inbox--questions))
            '(((qid . "p#0") (previews "A" "B"))))
      (puthash "p#0" '("B") limen-inbox--selected)
      (let ((prompts 0))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (_)
                     (cl-incf prompts)
                     (should-not sent)
                     confirm)))
          (limen-inbox-commit-at-point))
        (should (= prompts 1)))
      (if confirm
          (progn (should (equal sent '("2" "return")))
                 (should-not (limen-inbox-questions)))
        (should-not sent)
        (should (limen-inbox-questions))
        (should-not (limen-inbox--committed-p "p#0"))))))

(ert-deftest limen-inbox-preview-rejects-unsafe-layout-or-input-before-sending ()
  (dolist (failure '(layout controls eager-disabled notes-edited))
    (limen-inbox-tests--with-preview
      (puthash "p#0" '("A") limen-inbox--selected)
      (pcase failure
        ('layout (setq screen "Ordinary question without preview notes"))
        ('controls (puthash "p#0" "text\e[return" limen-inbox--notes))
        ('eager-disabled
         (setf (alist-get 'questions (car limen-inbox--questions))
               '(((qid . "p#0") (previews "A" "B"))))
         (setq screen "☐ First\nFirst question?\nNotes: press n to add notes\nChat about this"))
        ('notes-edited
         (setq screen "☐ First ☐ Second ✔ Submit\nFirst question?\nNotes: Outside edit\nChat about this")))
      (should-error (limen-inbox-commit-at-point) :type 'user-error)
      (should-not sent)
      (should-not pasted)
      (should-not (eq (gethash "p" limen-inbox--tabs) 'unknown)))))

(ert-deftest limen-inbox-preview-paste-failure-keeps-answer-uncommitted ()
  (limen-inbox-tests--with-preview
    (puthash "p#0" "Notes" limen-inbox--notes)
    (cl-letf (((symbol-function 'herdr-agent-paste)
               (lambda (&rest _) (error "Disconnected"))))
      (should-error (limen-inbox-commit-at-point)))
    (should (eq (gethash "p" limen-inbox--tabs) 'unknown))
    (should-not (limen-inbox--committed-p "p#0"))
    (should (equal (gethash "p#0" limen-inbox--notes) "Notes"))
    (should (equal sent '("n" "ctrl+a" "ctrl+k")))))

(ert-deftest limen-inbox-preview-dismiss-uses-chat-row-not-plain-digit ()
  (limen-inbox-tests--with-preview
    (let (attached)
      (cl-letf (((symbol-function 'herdr-agent-switch)
                 (lambda (target) (setq attached target))))
        (limen-inbox-dismiss-at-point))
      (should (equal sent '("down" "down" "return")))
      (should (equal attached '("/tmp/alpha.sock" . "t1")))
      (should-not (limen-inbox-questions)))))

(ert-deftest limen-inbox-preview-submit-screen-needs-only-one-return ()
  (limen-inbox-tests--with-preview
    (setq screen "Review your answers\nReady to submit your answers?")
    (limen-inbox--submit-block '("/tmp/alpha.sock" . "t1") "p")
    (should (equal sent '("return")))))

(ert-deftest limen-inbox-previews-remain-visible-with-answering-disabled ()
  (let ((limen-inbox-answer nil))
    (with-temp-buffer
      (limen-inbox--insert-question
       '((qid . "p#0") (answerable . t) (header . "Design")
         (question . "Which?") (options "A" "B") (previews "one\n  two" nil))
       nil t)
      (should (string-match-p "1[.] A\n         ┃ one\n         ┃   two" (buffer-string)))
      (should-not (text-property-not-all (point-min) (point-max) 'keymap nil)))))

(ert-deftest limen-inbox-single-preview-header-named-submit-is-not-submit-tab ()
  (should-not
   (limen-inbox--preview-submit-tab-p
    "☐ Submit\nQuestion?\nNotes: press n to add notes\nChat about this"
    '(:header "Submit"))))

(ert-deftest limen-inbox-preview-stalled-answer-is-not-marked-committed ()
  (limen-inbox-tests--with-preview
    (puthash "p#0" '("A") limen-inbox--selected)
    (cl-letf (((symbol-function 'herdr-agent-send-keys)
               (lambda (_target keys) (setq sent (append sent keys))))
              ((symbol-function 'sleep-for) #'ignore))
      (should-error (limen-inbox-commit-at-point)))
    (should (eq (gethash "p" limen-inbox--tabs) 'unknown))
    (should-not (limen-inbox--committed-p "p#0"))
    (should (equal sent '("1" "return")))))

(ert-deftest limen-inbox-preview-cleans-up-after-post-tool-hook-races-submit ()
  (limen-inbox-tests--with-preview
    (setq limen-inbox-answer-submit-eagerly t
          screen "☐ First\nFirst question?\nNotes: press n to add notes\nChat about this")
    (setf (alist-get 'questions (car limen-inbox--questions))
          '(((qid . "p#0") (previews "A" "B"))))
    (puthash "p#0" '("A") limen-inbox--selected)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'herdr-agent-send-keys)
               (lambda (_target keys)
                 (when (equal keys '("return"))
                   (setq screen "User answered")
                   (limen-inbox--answered "p#0")))))
      (limen-inbox-commit-at-point))
    (should-not (limen-inbox-questions))
    (dolist (table (list limen-inbox--selected limen-inbox--sent
                         limen-inbox--notes limen-inbox--sent-notes
                         limen-inbox--tabs))
      (should (= (hash-table-count table) 0)))))

(ert-deftest limen-inbox-preview-callout-preserves-blank-lines-and-indentation ()
  (with-temp-buffer
    (limen-inbox--insert-preview "first\n\n  last")
    (should (equal (get-text-property (point-min) 'display) '(space :width (+ 9 (7)))))
    (should (equal (buffer-string)
                   "         ┃ first\n         ┃ \n         ┃   last\n"))))

(ert-deftest limen-inbox-dismiss-answers-to-both-cancel-keys ()
  (dolist (key '("C-c C-d" "C-c C-k"))
    (should (eq (keymap-lookup limen-inbox-question-section-map key)
                #'limen-inbox-dismiss-at-point))
    (should (eq (keymap-lookup limen-inbox--preview-option-map key)
                #'limen-inbox-dismiss-at-point))))

(ert-deftest limen-inbox-committed-note-reads-behind-its-mark ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'herdr-status-mark)
               (lambda (_glyph _face &optional _property) "✎ ")))
      (limen-inbox--insert-note "first\nsecond"))
    (should (equal (buffer-string) "         ✎ first\n           second\n")))
  (with-temp-buffer
    (cl-letf (((symbol-function 'fboundp)
               (lambda (symbol) (not (eq symbol 'herdr-status-mark)))))
      (limen-inbox--insert-note "bare"))
    (should (equal (buffer-string) "         Notes: bare\n"))))

(ert-deftest limen-inbox-preview-reuses-the-herdr-preview-rule ()
  (cl-progv '(herdr-status-preview-rule) '("▌")
    (with-temp-buffer
      (limen-inbox--insert-preview "design")
      (should (equal (buffer-string) "         ▌ design\n")))))

(defmacro limen-inbox-tests--with-inline-notes (&rest body)
  "Run BODY at a preview option with Cera available as a stub."
  (declare (indent 0) (debug t))
  `(limen-inbox-tests--with-inbox
     (let ((require-function (symbol-function 'require))
           (limen-inbox-answer t)
           (limen-inbox-inline-notes t)
           (question '((qid . "p#0") (answerable . t) (header . "Design")
                       (question . "Which design?") (options "A" "B")
                       (previews "preview A" nil))))
       (cl-letf (((symbol-function 'require)
                  (lambda (feature &rest arguments)
                    (if (eq feature 'cera) 'cera
                      (apply require-function feature arguments)))))
         (cl-progv '(herdr-status--refreshing) '(nil)
         (limen-inbox--add `((id . "p") (questions ,question)))
         (with-temp-buffer
           (magit-section-mode)
           (let ((inhibit-read-only t))
             (magit-insert-section (limen-inbox-test-root)
               (limen-inbox--insert-question question '("/tmp/alpha.sock" . "t1") t)))
           (goto-char (point-min))
           (search-forward "preview A")
           ,@body))))))

(ert-deftest limen-inbox-inline-notes-prefills-and-anchors-below-preview ()
  (limen-inbox-tests--with-inline-notes
    (puthash "p#0" "Existing" limen-inbox--notes)
    (cl-letf (((symbol-function 'cera-read)
               (lambda (table initial bounds source-face)
                 (should-not source-face)
                 (should-not table)
                 (should (equal initial "Existing"))
                 (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                                "         ┃ preview A\n"))
                 (should (symbol-value 'herdr-status--refreshing))
                 "New\nnotes"))
              ((symbol-function 'herdr-agent-send-keys)
               (lambda (&rest _) (ert-fail "Editing must not send pane keys"))))
      (limen-inbox-notes-at-point))
    (should (equal (limen-inbox--note "p#0" 1) "New\nnotes"))
    (should-not (symbol-value 'herdr-status--refreshing))
    (should (= refreshes 2))
    (should buffer-read-only)))

(ert-deftest limen-inbox-inline-notes-mark-the-field-with-a-note-glyph ()
  (limen-inbox-tests--with-inline-notes
    (let (marks prefixes)
      (cl-letf (((symbol-function 'herdr-status-mark)
                 (lambda (glyph face &optional _property)
                   (push (list glyph face) marks)
                   (propertize "note " 'face face)))
                ((symbol-function 'cera-read)
                 (lambda (&rest _)
                   (push (symbol-value 'cera-input-prefix) prefixes)
                   "noted")))
        (limen-inbox-notes-at-point))
      (should (equal marks `((,limen-inbox-note-glyph limen-inbox-note-mark))))
      (should (equal (car prefixes) "note "))
      (should (equal (get-text-property 0 'face (car prefixes))
                     'limen-inbox-note-mark)))))

(ert-deftest limen-inbox-inline-notes-unwinds-on-cancel-and-error ()
  (dolist (failure '(quit error))
    (limen-inbox-tests--with-inline-notes
      (puthash "p#0" "Saved" limen-inbox--notes)
      (cl-letf (((symbol-function 'cera-read)
                 (lambda (&rest _)
                   (should (symbol-value 'herdr-status--refreshing))
                   (signal failure (and (eq failure 'error) '("Failed"))))))
        (if (eq failure 'quit)
            (should (condition-case nil (limen-inbox-notes-at-point) (quit t)))
          (should-error (limen-inbox-notes-at-point))))
      (should (equal (gethash "p#0" limen-inbox--notes) "Saved"))
      (should-not (symbol-value 'herdr-status--refreshing))
      (should (= refreshes 2)))))

(ert-deftest limen-inbox-inline-notes-refuses-stale-question-on-accept ()
  (dolist (change '(remove replace))
    (limen-inbox-tests--with-inline-notes
      (cl-letf (((symbol-function 'cera-read)
                 (lambda (&rest _)
                   (if (eq change 'remove)
                       (setq limen-inbox--questions nil)
                     (setf (alist-get 'questions (car limen-inbox--questions))
                           '(((qid . "p#0") (question . "Different")))))
                   "Stale draft")))
        (should-error (limen-inbox-notes-at-point) :type 'user-error))
      (should-not (gethash "p#0" limen-inbox--notes))
      (should-not (symbol-value 'herdr-status--refreshing)))))

(ert-deftest limen-inbox-inline-notes-missing-cera-does-not-change-buffer ()
  (limen-inbox-tests--with-inline-notes
    (let ((before (buffer-string))
          (original-require (symbol-function 'require)))
      (cl-letf (((symbol-function 'require)
                 (lambda (feature &rest arguments)
                   (unless (eq feature 'cera)
                     (apply original-require feature arguments)))))
        (should-error (limen-inbox-notes-at-point) :type 'user-error))
      (should (equal (buffer-string) before))
      (should-not (symbol-value 'herdr-status--refreshing))
      (should (zerop refreshes)))))

(ert-deftest limen-inbox-keeps-preview-notes-separate-and-combines-in-option-order ()
  (limen-inbox-tests--with-inbox
    (limen-inbox--add '((id . "p") (questions ((qid . "p#0") (options "A" "B")))) )
    (limen-inbox--set-note "p#0" 2 "Second design\nwith changes")
    (limen-inbox--set-note "p#0" 1 "First design")
    (should (equal (limen-inbox--note "p#0" 1) "First design"))
    (should (equal (limen-inbox--note "p#0" 2) "Second design\nwith changes"))
    (should (equal (limen-inbox--question-notes "p#0")
                   "1. A:\nFirst design\n\n2. B:\nSecond design\nwith changes"))
    (puthash "p#0" '("A") limen-inbox--selected)
    (puthash "p#0" '("A") limen-inbox--sent)
    (puthash "p#0" (limen-inbox--question-notes "p#0") limen-inbox--sent-notes)
    (should (limen-inbox--committed-p "p#0"))
    (limen-inbox--set-note "p#0" 2 "Unselected option revised")
    (should-not (limen-inbox--committed-p "p#0"))
    (limen-inbox--set-note "p#0" 1 "")
    (should (equal (limen-inbox--question-notes "p#0") "2. B:\nUnselected option revised"))
    (limen-inbox--set-note "p#0" 2 " \n ")
    (should (equal (limen-inbox--question-notes "p#0") ""))))

(ert-deftest limen-inbox-preview-commit-sends-all-labeled-notes ()
  (limen-inbox-tests--with-preview
    (setf (alist-get 'options (car (alist-get 'questions (car limen-inbox--questions))))
          '("A" "B"))
    (limen-inbox--set-note "p#0" 2 "Avoid this")
    (limen-inbox--set-note "p#0" 1 "Use this")
    (puthash "p#0" '("A") limen-inbox--selected)
    (limen-inbox-commit-at-point)
    (should (equal pasted '("1. A:\nUse this\n\n2. B:\nAvoid this")))
    (should (limen-inbox--committed-p "p#0"))
    (should (equal (limen-inbox--note "p#0" 2) "Avoid this"))))

(ert-deftest limen-inbox-preview-note-target-follows-point-then-selection ()
  (limen-inbox-tests--with-inbox
    (let ((question '(:qid "p#0" :preview t :options ("A" "B") :previews ("A" "B")))
          option)
      (cl-letf (((symbol-function 'limen-inbox--value)
                 (lambda (type) (if (eq type 'limen-inbox-option) option question))))
        (should (= (limen-inbox--note-index question) 1))
        (puthash "p#0" '("B") limen-inbox--selected)
        (should (= (limen-inbox--note-index question) 2))
        (setq option '(:index 1))
        (should (= (limen-inbox--note-index question) 1))
        (setf (plist-get question :previews) '(nil "B"))
        (should-error (limen-inbox--note-index question) :type 'user-error)))))

(ert-deftest limen-inbox-inline-notes-keeps-each-preview-draft ()
  (limen-inbox-tests--with-inline-notes
    (setf (alist-get 'previews question) '("preview A" "preview B"))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (magit-insert-section (limen-inbox-test-root)
        (limen-inbox--insert-question question '("/tmp/alpha.sock" . "t1") t)))
    (dolist (item '(("preview A" 1 "Note A") ("preview B" 2 "Note B")
                    ("preview A" 1 "Revised A")))
      (goto-char (point-min))
      (search-forward (car item))
      (cl-letf (((symbol-function 'cera-read)
                 (lambda (_table initial bounds source-face)
                   (should-not source-face)
                   (should (equal initial (limen-inbox--note "p#0" (cadr item))))
                   (should (string-match-p (car item)
                                           (buffer-substring-no-properties
                                            (car bounds) (cdr bounds))))
                   (caddr item))))
        (limen-inbox-notes-at-point)))
    (should (equal (limen-inbox--note "p#0" 1) "Revised A"))
    (should (equal (limen-inbox--note "p#0" 2) "Note B"))))

(ert-deftest limen-inbox-preserves-legacy-notes-on-the-selected-preview ()
  (limen-inbox-tests--with-inbox
    (limen-inbox--add
     '((id . "p") (questions ((qid . "p#0") (options "A" "B") (previews "A" "B")))))
    (puthash "p#0" '("B") limen-inbox--selected)
    (puthash "p#0" "Existing note" limen-inbox--notes)
    (should (equal (limen-inbox--note "p#0" 1) ""))
    (should (equal (limen-inbox--note "p#0" 2) "Existing note"))
    (should (equal (limen-inbox--question-notes "p#0") "Existing note"))
    (limen-inbox--set-note "p#0" 1 "Another note")
    (should (equal (limen-inbox--question-notes "p#0")
                   "1. A:\nAnother note\n\n2. B:\nExisting note"))))

(provide 'limen-inbox-tests)
;;; limen-inbox-tests.el ends here

(ert-deftest limen-inbox-redraws-from-the-dashboard-cache-when-it-lists-the-asker ()
  (limen-inbox-tests--with-inbox
    (let (calls listed)
      (cl-letf (((symbol-function 'herdr-status-redraw-cached)
                 (lambda (&optional ready-p)
                   (push (and ready-p (funcall ready-p) t) calls)
                   t))
                ((symbol-function 'herdr-status-cached-agents)
                 (lambda () listed)))
        (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                                  '(tool_use_id . "t1")
                                  (cons 'tool_input limen-inbox-tests--claude-input))
        (should (equal calls '(nil)))
        (setq listed '(((pane_id . "%1") (server_key . "/tmp/alpha.sock"))))
        (limen-inbox-tests--event "PreToolUse" '(tool_name . "AskUserQuestion")
                                  '(tool_use_id . "t2")
                                  (cons 'tool_input limen-inbox-tests--claude-input))
        (should (equal calls '(t nil)))
        (setq calls nil)
        (limen-inbox--toggle "t1#0" "Yes" nil)
        (limen-inbox--answered "t1#0")
        (should (equal calls '(nil)))
        (should (zerop refreshes))))))

(ert-deftest limen-inbox-keeps-to-the-agents-emacs-took-up ()
  (limen-inbox-tests--with-inbox
    (let ((limen-inbox-attached-only t))
      (limen-inbox--on-event
       "claude"
       (limen-inbox-tests--payload "PreToolUse" '(tool_name . "AskUserQuestion")
                                   '(tool_use_id . "t1")
                                   (cons 'tool_input limen-inbox-tests--claude-input))
       nil nil)
      (should-not (limen-inbox-questions))
      (limen-inbox--on-event
       "claude"
       (limen-inbox-tests--payload "PreToolUse" '(tool_name . "AskUserQuestion")
                                   '(tool_use_id . "t2")
                                   (cons 'tool_input limen-inbox-tests--claude-input))
       'session nil)
      (should (equal (mapcar (lambda (entry) (alist-get 'id entry))
                             (limen-inbox-questions))
                     '("t2"))))
    (let ((limen-inbox-attached-only nil))
      (limen-inbox--on-event
       "claude"
       (limen-inbox-tests--payload "PreToolUse" '(tool_name . "AskUserQuestion")
                                   '(tool_use_id . "t3")
                                   (cons 'tool_input limen-inbox-tests--claude-input))
       nil nil)
      (should (member "t3" (mapcar (lambda (entry) (alist-get 'id entry))
                                   (limen-inbox-questions)))))))
