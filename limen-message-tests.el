;;; limen-message-tests.el --- Message context tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit coverage with public API and process boundaries stubbed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'limen-message)

(defvar cera-read-context-function nil)
(defvar cera-session-keymap nil)
(defvar cera-session-start-hook nil)

(defun limen-message-tests--text (content)
  "Return CONTENT as the text a pane draws, whether blocks or one string."
  (if (stringp content)
      content
    (string-join (mapcar #'car content) "\n")))

(defun limen-message-tests--bare (content)
  "Return CONTENT without its spacers and the margin each line carries.
A pane stacks blocks, which stand where the lines of one text stood."
  (let* ((text (limen-message-tests--text content))
         (text (if (string-prefix-p "\n" text) (substring text 1) text))
         (offset (if (string-prefix-p " " (limen-message--margin 'default)) " " ""))
         (rule (concat offset limen-message-rule " "))
         (blank (make-string (string-width (concat limen-message-rule " ")) ?\s)))
    (string-trim-right
     (mapconcat (lambda (line)
                  (cond
                   ((string-prefix-p rule line) (substring line (length rule)))
                   ((string-prefix-p blank line) (substring line (length blank)))
                   (t line)))
                (split-string text "\n") "\n"))))

(defmacro limen-message-tests--state (&rest body)
  "Evaluate BODY with an active composer STATE and captured UPDATES."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let* ((state (limen-message--make-state
                    :buffer (current-buffer) :token (make-symbol "test")
                    :target '("server" . "terminal") :context t :live t))
            (limen-message--scopes (make-hash-table :test #'equal))
            (limen-message--replies (make-hash-table :test #'equal))
            updates)
       (setq limen-message--active state)
       (cl-letf (((symbol-function 'cera-update-pane)
                  (lambda (id text) (push (cons id text) updates)))
                 ((symbol-function 'make-process)
                  (lambda (&rest _) (ert-fail "Unexpected subprocess"))))
         (unwind-protect (progn ,@body)
           (limen-message--close state))))))

(defun limen-message-tests--record (turn role text &optional tool)
  "Return a record for TURN with ROLE, TEXT and optional TOOL."
  `((turn_id . ,turn) (doc_id . ,turn) (role . ,role)
    (text . ,text) (tool_name . ,tool)))

(defun limen-message-tests--exchange (turn answer)
  "Return TURN's question and its ANSWER, newest first."
  (list (limen-message-tests--record (1+ (* 2 turn)) "assistant" answer)
        (limen-message-tests--record (* 2 turn) "user" (format "question %d" turn))))

(ert-deftest limen-message-off-delegates-without-loads-or-keymaps ()
  (let ((limen-message-context nil) (limen-message-summary t))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) (ert-fail "Load")))
              ((symbol-function 'make-sparse-keymap) (lambda (&rest _) (ert-fail "Map")))
              ((symbol-function 'herdr-agent-find) (lambda (&rest _) (ert-fail "Read"))))
      (should (equal (limen-message--read-field #'list 'target "source")
                     '(target "source"))))))

(ert-deftest limen-message-missing-cera-delegates ()
  (let ((limen-message-context t))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
      (should (equal (limen-message--read-field #'list 'target "source")
                     '(target "source"))))))

(ert-deftest limen-message-missing-memex-is-unavailable ()
  (limen-message-tests--state
    (cl-letf (((symbol-function 'herdr-agent-find) (lambda (&rest _) 'session))
              ((symbol-function 'herdr-agent-session-agent-session)
               (lambda (_) '((kind . "id") (value . "id"))))
              ((symbol-function 'herdr-agent-session-kind) (lambda (_) "claude"))
              ((symbol-function 'herdr-agent-session-project) #'ignore)
              ((symbol-function 'require) (lambda (&rest _) nil)))
      (limen-message--resolve state)
      (should (equal (cdar updates) "")))))

(ert-deftest limen-message-api-total-not-analytics-and-filtered-exact-session ()
  (limen-message-tests--state
    (let ((limen-message-page-size 32)
          sessions-callback page-callback calls filters)
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'herdr-agent-find) (lambda (&rest _) 'session))
                ((symbol-function 'herdr-agent-session-agent-session)
                 (lambda (_) '((kind . "id") (value . "id"))))
                ((symbol-function 'herdr-agent-session-kind) (lambda (_) "claude"))
                ((symbol-function 'herdr-agent-session-project) #'ignore)
                ((symbol-function 'memex-api-index)
                 (lambda (callback &rest _) (funcall callback '())))
                ((symbol-function 'memex-api-sessions)
                 (lambda (callback &rest keys)
                   (setq sessions-callback callback filters keys)))
                ((symbol-function 'memex-api-session-page)
                 (lambda (id path callback &rest keys)
                   (push (list id path keys) calls)
                   (setq page-callback callback))))
        (limen-message--resolve state)
        (should-not calls)
        (should (equal (plist-get filters :session-id) "id"))
        (should (equal (plist-get filters :source) "claude"))
        (funcall sessions-callback
                 '(((session_id . "id") (source_path . "/opaque")
                    (source . "claude") (message_count . 99999))))
        (should (= (plist-get (nth 2 (car calls)) :limit) 1))
        (funcall page-callback '((total . 100) (message_count . 900)))
        (should (= (plist-get (nth 2 (car calls)) :offset) 68))
        (should (= (plist-get (nth 2 (car calls)) :limit) 32))
        (should (equal (limen-message--state-scope state) '("claude" "id" "/opaque")))))))

(ert-deftest limen-message-path-filter-and-ambiguous-session ()
  (limen-message-tests--state
    (let (filters)
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'herdr-agent-find) (lambda (&rest _) 'session))
                ((symbol-function 'herdr-agent-session-agent-session)
                 (lambda (_) '((kind . "path") (value . "/opaque"))))
                ((symbol-function 'herdr-agent-session-kind) (lambda (_) "pi"))
                ((symbol-function 'herdr-agent-session-project) #'ignore)
                ((symbol-function 'memex-api-index)
                 (lambda (callback &rest _) (funcall callback '())))
                ((symbol-function 'memex-api-sessions)
                 (lambda (callback &rest keys)
                   (setq filters keys)
                   (funcall callback
                            '(((source . "pi") (session_id . "a") (source_path . "/opaque"))
                              ((source . "pi") (session_id . "b") (source_path . "/opaque")))))))
        (limen-message--resolve state)
        (should (equal (plist-get filters :source-path) "/opaque"))
        (should-not (limen-message--state-scope state))
        (should (equal (cdar updates) ""))))))

(ert-deftest limen-message-true-roles-latest-order-and-turn-grouping ()
  (limen-message-tests--state
    (setf (limen-message--state-scope state) '("claude" "id" "/opaque"))
    (cl-letf (((symbol-function 'memex-api-session-page)
               (lambda (_id _path callback &rest _)
                 (funcall callback
                          `((records . ,(list
                                         (limen-message-tests--record 1 "assistant" "old")
                                         (limen-message-tests--record 2 "user" "question")
                                         (limen-message-tests--record 2 "assistant" "first block")
                                         (limen-message-tests--record 2 "assistant" "last block")
                                         (limen-message-tests--record 3 "assistant" "tool" "shell")
                                         (limen-message-tests--record 3 "reasoning" "private")
                                         (limen-message-tests--record 4 "tool_result" "result")
                                         (limen-message-tests--record 4 "user" "new question"))))))))
      (limen-message--page state 8)
      (should (equal (limen-message--state-latest state) "first block\nlast block"))
      (should (= (length (limen-message--state-records state)) 5)))))

(ert-deftest limen-message-summary-selects-five-turns-not-five-records ()
  (limen-message-tests--state
    (setf (limen-message--state-summary state) t
          (limen-message--state-records state)
          (cl-loop for turn downfrom 6 to 1 append
                   (list (limen-message-tests--record turn "assistant" (format "answer%d" turn))
                         (limen-message-tests--record turn "user" (format "question%d" turn)))))
    (let (prompt)
      (cl-letf (((symbol-function 'limen-message--generate)
                 (lambda (_state _key text) (setq prompt text))))
        (limen-message--finish state)
        (should-not (string-match-p "answer1\\|question1" prompt))
        (should (string-prefix-p "user: question2" prompt))
        (should (string-suffix-p "assistant: answer6" prompt))
        (should (= (length (split-string prompt "\n\n")) 10))))))

(ert-deftest limen-message-paging-backward-completes-boundary-turn ()
  (limen-message-tests--state
    (setf (limen-message--state-scope state) '("claude" "id" "/opaque"))
    (let ((limen-message-page-size 32) offsets)
      (cl-letf (((symbol-function 'memex-api-session-page)
                 (lambda (_id _path callback &rest keys)
                   (let ((offset (plist-get keys :offset)))
                     (push offset offsets)
                     (funcall callback
                              `((records . ,(if (= offset 32)
                                                (list (limen-message-tests--record 99 "assistant" "tail"))
                                              (cl-loop for turn from 1 to 6 append
                                                       (reverse (limen-message-tests--exchange
                                                                 turn "head")))))))))))
        (limen-message--page state 64)
        (should (equal offsets '(0 32)))
        (should (equal (limen-message--state-latest state) "head\ntail"))))))

(defun limen-message-tests--capped (records char-limit)
  "Read RECORDS under a scan cap of one page and CHAR-LIMIT, returning STATE."
  (limen-message-tests--state
    (setf (limen-message--state-scope state) '("claude" "id" "/opaque"))
    (let ((limen-message-page-size 32)
          (limen-message--scan-limit 1)
          (limen-message--char-limit char-limit))
      (cl-letf (((symbol-function 'memex-api-session-page)
                 (lambda (_id _path callback &rest _)
                   (funcall callback `((records . ,records))))))
        (limen-message--page state 100)
        (cons (limen-message--state-latest state) (cdar updates))))))

(ert-deftest limen-message-char-cap-gives-up ()
  "Text past the cap was cut off mid-read, so there is nothing whole to show."
  (let ((read (limen-message-tests--capped
               (list (limen-message-tests--record 1 "assistant" "long")) 1)))
    (should-not (car read))
    (should (equal (cdr read) ""))))

(ert-deftest limen-message-scan-cap-shows-what-it-read ()
  "A spent scan budget answers with fewer messages rather than with none."
  (let ((read (limen-message-tests--capped
               (list (limen-message-tests--record 1 "assistant" "long")) 100)))
    (should (equal (car read) "long"))
    (should (string-match-p "long" (limen-message-tests--text (cdr read))))))

(ert-deftest limen-message-scan-cap-with-nothing-read-gives-up ()
  "A budget spent without one message is a session that could not be read."
  (let ((read (limen-message-tests--capped
               (list (limen-message-tests--record 1 "tool_result" "tool")) 100)))
    (should-not (car read))
    (should (equal (cdr read) ""))))

(ert-deftest limen-message-late-callback-and-replaced-composer-ignored ()
  (limen-message-tests--state
    (setf (limen-message--state-scope state) '("claude" "id" "/opaque"))
    (let (callback)
      (cl-letf (((symbol-function 'memex-api-session-page)
                 (lambda (_id _path cb &rest _) (setq callback cb))))
        (limen-message--page state 1)
        (setq limen-message--active 'replacement)
        (funcall callback `((records . ,(list (limen-message-tests--record 1 "assistant" "late")))))
        (should-not updates)
        (setq limen-message--active state)
        (limen-message--close state)
        (funcall callback '((records)))
        (should-not updates)))))

(ert-deftest limen-message-context-pane-leads-with-the-recap-line ()
  (limen-message-tests--state
    (setf (limen-message--state-summary state) t)
    (limen-message--set-latest state "The reply body")
    (limen-message--set-recap state "**Recap** line")
    (should (equal (limen-message-tests--bare (cdr (assq 'limen-context updates)))
                   "Recap line\nThe reply body"))
    (should (string-match-p
             (concat "Recap line\n" (regexp-quote limen-message-rule) " ")
             (limen-message-tests--text (cdr (assq 'limen-context updates)))))
    (should (eq (get-text-property (+ 1 (string-width limen-message-rule) 1)
                                   'face (limen-message-tests--text
                                          (cdr (assq 'limen-context updates))))
                limen-message-recap-face))
    (setq updates nil)
    (limen-message--set-recap state nil)
    (should (equal (limen-message-tests--bare (cdr (assq 'limen-context updates)))
                   "\nThe reply body"))
    (setq updates nil)
    (limen-message--set-latest state nil)
    (should (equal (cdr (assq 'limen-context updates)) ""))))

(ert-deftest limen-message-an-unsummarizable-page-keeps-the-recap-shown ()
  (limen-message-tests--state
    (let ((limen-message--recaps (make-hash-table :test #'equal))
          (limen-message--summary-limit 8))
      (setf (limen-message--state-summary state) t
            (limen-message--state-scope state) '("claude" "id" "/one")
            (limen-message--state-records state)
            (list (limen-message-tests--record 1 "assistant" "a long answer")))
      (puthash '("claude" "id" "/one") "earlier recap" limen-message--recaps)
      (cl-letf (((symbol-function 'limen-message--generate)
                 (lambda (&rest _) (ert-fail "Unexpected generation"))))
        (limen-message--finish state)
        (should (equal (limen-message--state-recap state) "earlier recap"))
        (should (equal (limen-message-tests--bare (cdar updates))
                       "earlier recap\na long answer"))))))

(ert-deftest limen-message-summary-cache-uses-content-and-session ()
  (limen-message-tests--state
    (let ((limen-message--summaries (make-hash-table :test #'equal)) (calls 0))
      (setf (limen-message--state-summary state) t
            (limen-message--state-scope state) '("claude" "id" "/one")
            (limen-message--state-records state)
            (list (limen-message-tests--record 1 "assistant" "answer")))
      (cl-letf (((symbol-function 'limen-message--generate)
                 (lambda (_state key _text)
                   (cl-incf calls) (puthash key "cached" limen-message--summaries))))
        (limen-message--finish state)
        (limen-message--finish state)
        (should (= calls 1))
        (should (equal (limen-message-tests--bare (cdar updates)) "cached\nanswer"))
        (setf (alist-get 'text (car (limen-message--state-records state))) "changed")
        (limen-message--finish state)
        (should (= calls 2))
        (setf (limen-message--state-scope state) '("claude" "id" "/two"))
        (limen-message--finish state)
        (should (= calls 3))))))

(defmacro limen-message-tests--process (&rest body)
  "Evaluate BODY with stub process transport and captured callbacks."
  (declare (indent 0) (debug t))
  `(limen-message-tests--state
     (let ((limen-message--summaries (make-hash-table :test #'equal))
           ;; One backend, so that what is asserted here is the transport
           ;; rather than the stepping between them.
           (limen-message-backends '(claude))
           argv stdin sentinel filter timeout (status 'run) (exit-code 0) killed eof cwd)
       (cl-letf (((symbol-function 'make-process)
                  (lambda (&rest keys)
                    (setq argv (plist-get keys :command)
                          sentinel (plist-get keys :sentinel)
                          filter (plist-get keys :filter)
                          cwd default-directory)
                    'fake-process))
                 ((symbol-function 'process-send-string) (lambda (_ text) (setq stdin text)))
                 ((symbol-function 'process-send-eof) (lambda (_) (setq eof t)))
                 ((symbol-function 'process-status) (lambda (_) status))
                 ((symbol-function 'process-exit-status) (lambda (_) exit-code))
                 ((symbol-function 'process-live-p) (lambda (_) (eq status 'run)))
                 ((symbol-function 'delete-process) (lambda (_) (setq killed t status 'signal)))
                 ((symbol-function 'run-at-time)
                  (lambda (_seconds _repeat callback &rest _) (setq timeout callback) (timer-create)))
                 ((symbol-function 'cancel-timer) #'ignore))
         (unwind-protect
             (progn ,@body
                    (should (and (consp argv) (stringp stdin) eof
                                 (functionp sentinel) (functionp filter)
                                 (functionp timeout) (stringp cwd)))
                    (should-not (and killed (eq status 'run))))
           (limen-message--close state))))))

(ert-deftest limen-message-process-argv-stdin-isolation-and-success ()
  (limen-message-tests--process
    (limen-message--generate state 'key "private transcript; $(bad)")
    (should (equal stdin "private transcript; $(bad)"))
    (should-not (seq-some (lambda (arg) (string-match-p "private transcript" arg)) argv))
    (should (equal (cadr (member "--model" argv)) "haiku"))
    (should (equal (cadr (member "--tools" argv)) ""))
    (should (equal (cadr (member "--setting-sources" argv)) ""))
    (should (member "--strict-mcp-config" argv))
    (should (member "--no-session-persistence" argv))
    (should (member "--disable-slash-commands" argv))
    (should (equal (cadr (member "--settings" argv)) "{\"disableAllHooks\":true}"))
    (should-not (member "--bare" argv))
    (should (file-directory-p cwd))
    (should eof)
    (funcall filter 'fake-process "A concise recap.")
    (setq status 'exit)
    (funcall sentinel 'fake-process "finished")
    (should (equal (gethash 'key limen-message--summaries) "A concise recap."))
    (should-not (file-exists-p cwd))
    (should-not killed)))

(ert-deftest limen-message-process-failure-no-cache ()
  (limen-message-tests--process
    (limen-message--generate state 'key "conversation")
    (funcall filter 'fake-process "partial")
    (setq status 'exit exit-code 1)
    (funcall sentinel 'fake-process "failed")
    (should-not (gethash 'key limen-message--summaries))
    (should (equal (cdar updates) ""))))

(ert-deftest limen-message-process-timeout-and-close-cancel-own-process ()
  (limen-message-tests--process
    (limen-message--generate state 'key "conversation")
    (funcall timeout)
    (should killed)
    (should-not (file-exists-p cwd))
    (should (equal (cdar updates) ""))
    (setq updates nil)
    (limen-message--close state)
    (funcall sentinel 'fake-process "late")
    (should-not updates)))

(ert-deftest limen-message-process-output-is-bounded ()
  (limen-message-tests--process
    (limen-message--generate state 'key "conversation")
    (funcall filter 'fake-process (make-string 5000 ?x))
    (funcall filter 'fake-process (make-string 5000 ?y))
    (setq status 'exit)
    (funcall sentinel 'fake-process "finished")
    ;; What was kept is cut to the limit, and the recap taken from it to
    ;; the line a recap is allowed to be.
    (should (<= (length (gethash 'key limen-message--summaries))
                limen-message--recap-max-chars))
    (should-not (string-match-p "y" (gethash 'key limen-message--summaries)))))

(ert-deftest limen-message-process-launch-error-is-nonfatal ()
  (limen-message-tests--state
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "Missing CLI"))))
      (limen-message--generate state 'key "conversation")
      (should-not (limen-message--state-directory state))
      (should-not (limen-message--state-stderr state))
      (should (equal (cdar updates) "")))))

(ert-deftest limen-message-enable-disable-is-idempotent ()
  (unwind-protect
      (progn
        (limen-message-enable)
        (limen-message-enable)
        (should (advice-member-p #'limen-message--read-field 'herdr-message-read-field))
        (limen-message-disable)
        (should-not (advice-member-p #'limen-message--read-field 'herdr-message-read-field)))
    (limen-message-disable)))

(ert-deftest limen-message-wrapper-starts-after-field-and-scopes-hooks ()
  (let ((limen-message-context t) (limen-message-summary t) (limen-message-status t)
        (cera-read-context-function nil) (cera-session-keymap nil)
        (cera-session-start-hook nil) started scheduled owned)
    (with-temp-buffer
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'cera-pane) #'list)
                ((symbol-function 'cera-update-pane) #'ignore)
                ((symbol-function 'cera-read-stack) #'ignore)
                ((symbol-function 'cera-origin-buffer) #'current-buffer)
                ((symbol-function 'run-at-time)
                 (lambda (&rest _)
                   (should started) (setq scheduled t) (timer-create))))
        (should
         (eq (limen-message--read-field
              (lambda (target context)
                (should (eq target 'target))
                (should (equal context "source only"))
                (should-not scheduled)
                (with-temp-buffer
                  (should (equal (funcall cera-read-context-function '(input)) '(input)))
                  (run-hook-with-args 'cera-session-start-hook 'session)
                  (should-not limen-message--active))
                (let ((panes (funcall cera-read-context-function '(source input))))
                  (should (eq (plist-get (nth 0 panes) :id) 'limen-context))
                  (should-not (plist-get (nth 0 panes) :bracket))
                  (should-not (plist-get (nth 0 panes) :prefix))
                  (should (equal (plist-get (nth 0 panes) :text) ""))
                  (should (equal (seq-subseq panes 1 3) '(source input)))
                  (should (eq (plist-get (nth 3 panes) :id) 'limen-status))
                  (should-not (plist-get (nth 3 panes) :bracket)))
                (setq started t)
                (run-hook-with-args 'cera-session-start-hook 'session)
                (setq owned limen-message--active)
                (should scheduled)
                (let ((overriding-local-map cera-session-keymap))
                  ;; The composer adds no keys of its own.
                  (should-not (key-binding (kbd "C-c C-v"))))
                (setq scheduled nil)
                (run-hook-with-args 'cera-session-start-hook 'session)
                (should-not scheduled)
                'unchanged-result)
              'target "source only")
             'unchanged-result))
        (should-not (limen-message--state-live owned))
        (should-not (limen-message--state-timers owned))
        (should-not limen-message--active)))))

(ert-deftest limen-message-close-keeps-the-recap-but-stops-drawing-it ()
  (limen-message-tests--process
    (let ((limen-message--recaps (make-hash-table :test #'equal)))
      (setf (limen-message--state-scope state) '("claude" "id" "/one"))
      (limen-message--generate state 'key "conversation")
      (limen-message--close state)
      (should-not killed)
      (should-not (limen-message--state-timers state))
      (setq updates nil status 'exit)
      (funcall filter 'fake-process "late recap")
      (funcall sentinel 'fake-process "finished")
      ;; The field is gone, so nothing is drawn; the next one starts here.
      (should-not updates)
      (should (equal (gethash 'key limen-message--summaries) "late recap"))
      (should (equal (gethash '("claude" "id" "/one") limen-message--recaps)
                     "late recap"))
      (should-not (file-exists-p cwd)))))

(ert-deftest limen-message-context-only-stops-at-complete-latest-turn ()
  (limen-message-tests--state
    (setf (limen-message--state-scope state) '("claude" "id" "/opaque"))
    (let ((limen-message--scan-limit 32) (limen-message-messages 1) (calls 0))
      (cl-letf (((symbol-function 'memex-api-session-page)
                 (lambda (_id _path callback &rest _)
                   (cl-incf calls)
                   (funcall callback
                            `((records . ,(append
                                           (list (limen-message-tests--record 1 "user" "previous")
                                                 (limen-message-tests--record 2 "assistant" "full reply"))
                                           (make-list 30 (limen-message-tests--record 3 "tool_result" "tool")))))))))
        (limen-message--page state 320)
        (should (= calls 1))
        (should (equal (limen-message--state-latest state) "full reply"))
        (should (string-match-p "full reply" (limen-message-tests--text (cdar updates))))))))

(ert-deftest limen-message-reads-back-the-messages-the-walk-wants ()
  (limen-message-tests--state
    (setf (limen-message--state-scope state) '("claude" "id" "/opaque"))
    (let ((limen-message--scan-limit 256) (limen-message-messages 3)
          (limen-message-page-size 32) (calls 0))
      (cl-letf (((symbol-function 'memex-api-session-page)
                 (lambda (_id _path callback &rest _)
                   (cl-incf calls)
                   (let ((turn (* calls 10)))
                     (funcall callback
                              `((records . ,(append
                                             (make-list 30 (limen-message-tests--record
                                                            (1- turn) "tool_result" "tool"))
                                             (reverse (limen-message-tests--exchange
                                                       turn (format "reply %d" calls)))))))))))
        (limen-message--page state 320)
        ;; One page carries one turn above the tool traffic of the one
        ;; before, so three wanted means paging back until three stand
        ;; complete.
        (should (= calls 3))
        (should (equal (mapcar #'cdr (limen-message--state-messages state))
                       '("reply 1" "reply 2" "reply 3")))))))

(ert-deftest limen-message-explicit-reasoning-flag-is-not-conversation ()
  (should-not (limen-message--conversation-p
               '((role . "assistant") (text . "private") (reasoning . t))))
  (should (limen-message--conversation-p
           '((role . "assistant") (text . "answer") (reasoning . nil)))))

(ert-deftest limen-message-rpc-handles-cancel-through-public-api-on-close ()
  (limen-message-tests--state
    (let ((index-handle (make-pipe-process :name "limen-test-index" :noquery t))
          (session-handle (make-pipe-process :name "limen-test-session" :noquery t))
          (page-handle (make-pipe-process :name "limen-test-page" :noquery t))
          index-callback sessions-callback page-callback cancelled)
      (unwind-protect
          (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                    ((symbol-function 'herdr-agent-find) (lambda (&rest _) 'session))
                    ((symbol-function 'herdr-agent-session-agent-session)
                     (lambda (_) '((kind . "id") (value . "id"))))
                    ((symbol-function 'herdr-agent-session-kind) (lambda (_) "claude"))
                    ((symbol-function 'herdr-agent-session-project) #'ignore)
                    ((symbol-function 'memex-api-index)
                     (lambda (callback &rest _)
                       (setq index-callback callback) index-handle))
                    ((symbol-function 'memex-api-sessions)
                     (lambda (callback &rest _)
                       (setq sessions-callback callback) session-handle))
                    ((symbol-function 'memex-api-session-page)
                     (lambda (_id _path callback &rest _)
                       (setq page-callback callback) page-handle))
                    ((symbol-function 'memex-cancel-rpc)
                     (lambda (handle)
                       (push handle cancelled) (delete-process handle))))
            (limen-message--resolve state)
            (should (eq (caar (limen-message--state-requests state)) session-handle))
            (delete-process session-handle)
            (funcall sessions-callback
                     '(((source . "claude") (session_id . "id") (source_path . "/opaque"))))
            (should (eq (caar (limen-message--state-requests state)) index-handle))
            (delete-process index-handle)
            (funcall index-callback '((files_scanned . 0)))
            (should (eq (caar (limen-message--state-requests state)) page-handle))
            (should (= (length (limen-message--state-requests state)) 1))
            (limen-message--close state)
            (should (equal cancelled (list page-handle)))
            (should-not (process-live-p page-handle))
            (should-not (limen-message--state-requests state))
            (funcall page-callback '((total . 99)))
            (should-not updates)
            (should-not (limen-message--state-requests state)))
        (dolist (handle (list index-handle session-handle page-handle))
          (when (process-live-p handle) (delete-process handle)))))))

(ert-deftest limen-message-lists-sessions-before-paying-for-a-scan ()
  (limen-message-tests--state
    (let (order)
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'herdr-agent-find) (lambda (&rest _) 'session))
                ((symbol-function 'herdr-agent-session-agent-session)
                 (lambda (_) '((kind . "id") (value . "id"))))
                ((symbol-function 'herdr-agent-session-kind) (lambda (_) "claude"))
                ((symbol-function 'herdr-agent-session-project) #'ignore)
                ((symbol-function 'memex-api-index)
                 (lambda (callback &rest _)
                   (push 'index order) (funcall callback '())))
                ((symbol-function 'memex-api-sessions)
                 (lambda (callback &rest _)
                   (push 'sessions order) (funcall callback '())))
                ((symbol-function 'memex-api-session-page)
                 (lambda (&rest _) (push 'page order) nil)))
        (limen-message--resolve state)
        (should (equal (reverse order) '(sessions index sessions)))))))

(ert-deftest limen-message-a-known-session-is-read-without-listing-again ()
  (limen-message-tests--state
    (let (order)
      (puthash (limen-message--state-target state) '("claude" "id" "/opaque")
               limen-message--scopes)
      (puthash '("claude" "id" "/opaque") "earlier reply" limen-message--replies)
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'herdr-agent-find) (lambda (&rest _) 'session))
                ((symbol-function 'herdr-agent-session-agent-session)
                 (lambda (_) '((kind . "id") (value . "id"))))
                ((symbol-function 'herdr-agent-session-kind) (lambda (_) "claude"))
                ((symbol-function 'herdr-agent-session-project) #'ignore)
                ((symbol-function 'memex-api-index)
                 (lambda (callback &rest _)
                   (push 'index order) (funcall callback '())))
                ((symbol-function 'memex-api-sessions)
                 (lambda (&rest _) (ert-fail "Unexpected listing")))
                ((symbol-function 'memex-api-session-page)
                 (lambda (&rest _) (push 'page order) nil)))
        (limen-message--resolve state)
        (should (equal (reverse order) '(index page)))
        (should (equal (limen-message--state-latest state) "earlier reply"))
        (should (string-match-p "earlier reply"
                                (limen-message-tests--text (cdar updates))))))))

(ert-deftest limen-message-a-session-that-lost-its-records-is-looked-up-again ()
  (limen-message-tests--state
    (let (order)
      (puthash (limen-message--state-target state) '("claude" "id" "/gone")
               limen-message--scopes)
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'herdr-agent-find) (lambda (&rest _) 'session))
                ((symbol-function 'herdr-agent-session-agent-session)
                 (lambda (_) '((kind . "id") (value . "id"))))
                ((symbol-function 'herdr-agent-session-kind) (lambda (_) "claude"))
                ((symbol-function 'herdr-agent-session-project) #'ignore)
                ((symbol-function 'memex-api-index)
                 (lambda (callback &rest _) (push 'index order) (funcall callback '())))
                ((symbol-function 'memex-api-sessions)
                 (lambda (callback &rest _) (push 'sessions order) (funcall callback '())))
                ((symbol-function 'memex-api-session-page)
                 (lambda (_id _path callback &rest _)
                   (push 'page order) (funcall callback '((total . 0))))))
        (limen-message--resolve state)
        (should (equal (reverse order) '(index page sessions index sessions)))
        (should-not (gethash (limen-message--state-target state)
                             limen-message--scopes))))))

(ert-deftest limen-message-rpc-timeout-cancels-handle-and-ignores-late-response ()
  (limen-message-tests--state
    (let ((handle (make-pipe-process :name "limen-test-timeout" :noquery t))
          callback timeout cancelled)
      (unwind-protect
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (seconds _repeat function &rest _)
                       (should (= seconds 10))
                       (setq timeout function) (timer-create)))
                    ((symbol-function 'memex-cancel-rpc)
                     (lambda (request)
                       (should (eq request handle))
                       (setq cancelled t) (delete-process request))))
            (limen-message--request
             state (lambda (success &rest _) (setq callback success) handle)
             nil (lambda (_) (ert-fail "Late response delivered")))
            (funcall timeout)
            (should cancelled)
            (should-not (process-live-p handle))
            (should-not (limen-message--state-requests state))
            (should (equal (cdar updates) ""))
            (setq updates nil)
            (funcall callback 'late)
            (should-not updates))
        (when (process-live-p handle) (delete-process handle))))))

(ert-deftest limen-message-missing-content-hides-both-panes ()
  (limen-message-tests--state
    (setf (limen-message--state-summary state) t
          (limen-message--state-latest state) "Previous reply")
    (limen-message--unavailable state)
    (should-not (limen-message--state-latest state))
    (should (equal (cdr (assq 'limen-context updates)) ""))))

(ert-deftest limen-message-whitespace-is-not-available-context ()
  (should-not (limen-message--conversation-p
               (limen-message-tests--record "turn" "assistant" " \n\t "))))

(ert-deftest limen-message-failed-recap-leaves-the-latest-reply-visible ()
  (limen-message-tests--state
    (limen-message--set-latest state "Keep this reply")
    (limen-message--set-latest state (limen-message--state-latest state))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "No model"))))
      (limen-message--generate state 'key "Conversation"))
    (should (equal (limen-message-tests--bare (cdr (assq 'limen-context updates)))
                   "\nKeep this reply"))))

(ert-deftest limen-message-recap-is-one-plain-line-of-fifty-characters ()
  (let ((long (make-string 400 ?w)))
    (dolist (case (list (cons "**Bold** and `code`" "Bold and code")
                        (cons "# Heading\n- bullet one\n- bullet two"
                              "Heading bullet one bullet two")
                        (cons "See [the docs](https://example.test/a) now"
                              "See the docs now")
                        (cons "```\ncode fence\n```\nplain" "code fence plain")
                        (cons long (concat (substring long 0 49) "…"))))
      (let ((plain (limen-message--recap-text (car case))))
        (should (equal plain (cdr case)))
        (should-not (string-match-p "\n" plain))
        (should (<= (length plain) limen-message--recap-max-chars))
        (should-not (string-match-p "[*`#_~]" plain))))))

(ert-deftest limen-message-recap-prompt-asks-for-one-plain-short-line ()
  (let ((prompt limen-message--instruction))
    (should (string-match-p "one plain-text line" prompt))
    (should (string-match-p (number-to-string limen-message--recap-max-chars) prompt))
    (should (string-match-p "No Markdown" prompt))))

(ert-deftest limen-message-context-pane-carries-no-styling ()
  (let ((limen-message-context t) (limen-message-summary t) (limen-message-status t)
        (cera-read-context-function nil) (cera-session-keymap nil)
        (cera-session-start-hook nil) panes context)
    (with-temp-buffer
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'cera-pane) (lambda (&rest properties)
                                                (push properties panes) properties))
                ((symbol-function 'cera-update-pane) #'ignore)
                ((symbol-function 'cera-read-stack) #'ignore)
                ((symbol-function 'run-at-time) (lambda (&rest _) (timer-create))))
        (limen-message--read-field
         (lambda (&rest _) (setq context cera-read-context-function))
         'target "source")
        (funcall context '(input))))
    (should (= (length panes) 2))
    (dolist (pane panes)
      (should-not (plist-get pane :face)))))

(ert-deftest limen-message-recap-pane-shows-one-normalized-line ()
  (limen-message-tests--state
    (setf (limen-message--state-summary state) t)
    (dolist (case (list (cons "**Bold**\nsecond line" "Bold second line")
                        (cons (make-string 120 ?z) (concat (make-string 49 ?z) "…"))))
      (setq updates nil)
      (limen-message--set-recap state (car case))
      (let ((shown (limen-message-tests--bare (cdar updates))))
        (should-not (string-match-p "\n" shown))
        (should (<= (length shown) limen-message--recap-max-chars))
        (should-not (string-match-p "[*`#_~]" shown))))))

(ert-deftest limen-message-keeps-the-last-recap-until-a-new-one-arrives ()
  (let ((limen-message--recaps (make-hash-table :test #'equal))
        (limen-message--summaries (make-hash-table :test #'equal)))
    (limen-message-tests--state
      (setf (limen-message--state-summary state) t
            (limen-message--state-scope state) '("claude" "id" "/one")
            (limen-message--state-records state)
            (list (limen-message-tests--record 1 "assistant" "answer")))
      (limen-message--set-recap state "the earlier recap")
      (should (equal (gethash '("claude" "id" "/one") limen-message--recaps)
                     "the earlier recap"))
      ;; A turn later the exact-history cache misses, so the one before
      ;; it stands while the new recap is generated.
      (setf (limen-message--state-recap state) nil)
      (cl-letf (((symbol-function 'limen-message--generate) #'ignore))
        (limen-message--finish state))
      (should (equal (limen-message--state-recap state) "the earlier recap"))
      ;; A failed generation falls back to it rather than blanking.
      (limen-message--set-recap state nil)
      (limen-message--fall-back-recap state)
      (should (equal (limen-message--state-recap state) "the earlier recap")))))

(ert-deftest limen-message-dismissal-keeps-the-draft-for-the-next-field ()
  (let ((limen-message--drafts (make-hash-table :test #'equal))
        cancelled)
    (limen-message-tests--state
      (cl-letf (((symbol-function 'cera-input-text) (lambda () "half a message"))
                ((symbol-function 'cera-cancel) (lambda () (setq cancelled t))))
        (should (limen-message--dismiss))
        (should cancelled)
        (should (equal (gethash '("server" . "terminal") limen-message--drafts)
                       "half a message")))
      ;; A field put away empty leaves nothing behind.
      (cl-letf (((symbol-function 'cera-input-text) (lambda () "  \n "))
                ((symbol-function 'cera-cancel) #'ignore))
        (should (limen-message--dismiss))
        (should-not (gethash '("server" . "terminal") limen-message--drafts))))
    (should-not (limen-message--dismiss))))

(ert-deftest limen-message-sending-takes-the-draft-away ()
  (let ((limen-message-context t)
        (limen-message--drafts (make-hash-table :test #'equal))
        (cera-read-context-function nil) (cera-session-keymap nil)
        (cera-session-start-hook nil)
        (target '("server" . "terminal")))
    (puthash target "left unsent" limen-message--drafts)
    (with-temp-buffer
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'cera-pane) (lambda (&rest properties) properties))
                ((symbol-function 'cera-update-pane) #'ignore)
                ((symbol-function 'cera-read-stack) #'ignore)
                ((symbol-function 'run-at-time) (lambda (&rest _) (timer-create))))
        (should (equal (limen-message--read-field (lambda (&rest _) "sent")
                                                  target "source")
                       "sent"))))
    (should-not (gethash target limen-message--drafts))
    ;; A field abandoned rather than put away leaves nothing behind either.
    (puthash target "left unsent" limen-message--drafts)
    (with-temp-buffer
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'cera-pane) (lambda (&rest properties) properties))
                ((symbol-function 'cera-update-pane) #'ignore)
                ((symbol-function 'cera-read-stack) #'ignore)
                ((symbol-function 'run-at-time) (lambda (&rest _) (timer-create))))
        (should (eq (condition-case nil
                        (limen-message--read-field (lambda (&rest _) (signal 'quit nil))
                                                    target "source")
                      (quit 'quit))
                    'quit))))
    (should-not (gethash target limen-message--drafts))))

(ert-deftest limen-message-a-field-put-away-keeps-its-draft ()
  (let ((limen-message-context t)
        (limen-message--drafts (make-hash-table :test #'equal))
        (cera-read-context-function nil) (cera-session-keymap nil)
        (cera-session-start-hook nil)
        (target '("server" . "terminal")))
    (puthash target "left unsent" limen-message--drafts)
    (with-temp-buffer
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'cera-pane) (lambda (&rest properties) properties))
                ((symbol-function 'cera-pane-kind) (lambda (_) 'other))
                ((symbol-function 'cera-update-pane) #'ignore)
                ((symbol-function 'cera-read-stack) #'ignore)
                ((symbol-function 'cera-input-text) (lambda () "left unsent"))
                ((symbol-function 'cera-cancel) #'ignore)
                ((symbol-function 'cera-origin-buffer) #'current-buffer)
                ((symbol-function 'run-at-time) (lambda (&rest _) (timer-create))))
        (should (eq (condition-case nil
                        (limen-message--read-field
                         (lambda (&rest _)
                           (funcall cera-read-context-function nil)
                           (run-hook-with-args 'cera-session-start-hook nil)
                           (limen-message--dismiss)
                           (signal 'quit nil))
                         target "source")
                      (quit 'quit))
                    'quit))))
    (should (equal (gethash target limen-message--drafts) "left unsent"))))

(ert-deftest limen-message-transcript-opens-beside-the-field-in-the-host-frame ()
  "A field in a child frame has that frame selected; the transcript goes to the host."
  (let* ((host (selected-window))
         (state (limen-message--make-state :scope '("claude" "id" "/opaque")))
         opened displayed)
    (cl-letf (((symbol-function 'limen-message--state-here) (lambda () state))
              ((symbol-function 'memex-view-session)
               (lambda (id path _doc display)
                 (setq opened (list id path))
                 (funcall display (get-buffer-create " *limen transcript*"))))
              ((symbol-function 'display-buffer)
               (lambda (buffer action)
                 (setq displayed (list buffer (selected-window) action))
                 nil)))
      (limen-message-transcript))
    (should (equal opened '("id" "/opaque")))
    (should (eq (nth 1 displayed) host))
    (should (equal (nth 2 displayed) '(nil (inhibit-same-window . t))))
    (should (eq (selected-window) host))
    (kill-buffer " *limen transcript*")))

(ert-deftest limen-message-messages-are-what-the-assistant-said-per-turn ()
  "A turn opens at a question, whatever the records number themselves.
Memex gives each record of a Claude session a `turn_id' of its own, so
a reply written in several blocks is one message only if the grouping
is read off the questions."
  (let ((records (list (limen-message-tests--record 7 "assistant" "second, part two")
                       (limen-message-tests--record 6 "assistant" "second, part one")
                       (limen-message-tests--record 5 "user" "second question")
                       (limen-message-tests--record 4 "assistant" "first answer")
                       (limen-message-tests--record 3 "user" "first question")
                       (limen-message-tests--record 2 "assistant" "before the page"))))
    (should (equal (limen-message--messages records)
                   '(("assistant" . "second, part one\nsecond, part two")
                     ("assistant" . "first answer")
                     ("assistant" . "before the page"))))
    (should (equal (limen-message--messages records '("assistant" "user"))
                   '(("assistant" . "second, part one\nsecond, part two")
                     ("user" . "second question")
                     ("assistant" . "first answer")
                     ("user" . "first question")
                     ("assistant" . "before the page"))))
    (should-not (limen-message--messages
                 (list (limen-message-tests--record 1 "user" "only asked"))))
    (should (equal (limen-message--messages
                    (list (limen-message-tests--record 2 "assistant" "answered")
                          (limen-message-tests--record 2 "user" "asked"))
                    '("assistant" "user"))
                   '(("assistant" . "answered") ("user" . "asked"))))))

(ert-deftest limen-message-walks-back-through-what-the-agent-said ()
  (limen-message-tests--state
    (setf (limen-message--state-scope state) '("claude" "id" "/opaque"))
    (cl-letf (((symbol-function 'memex-api-session-page)
               (lambda (_id _path callback &rest _)
                 (funcall callback
                          `((records . ,(append
                                         (reverse (limen-message-tests--exchange 1 "oldest"))
                                         (reverse (limen-message-tests--exchange 2 "middle"))
                                         (reverse (limen-message-tests--exchange 3 "newest")))))))))
      (limen-message--page state 8))
    (should (equal (limen-message--state-latest state) "newest"))
    (should (= (limen-message--state-cursor state) 0))
    (limen-message-older)
    (should (equal (limen-message--state-latest state) "middle"))
    (limen-message-older)
    (limen-message-older)
    (should (equal (limen-message--state-latest state) "oldest"))
    (should (= (limen-message--state-cursor state) 2))
    (limen-message-newer)
    (should (equal (limen-message--state-latest state) "middle"))
    ;; Walking back leaves the cache holding the latest, not what is shown.
    (should (equal (gethash (limen-message--state-scope state)
                            limen-message--replies)
                   "newest"))
    (should (seq-some (lambda (update)
                        (string-match-p
                         "middle"
                         (limen-message-tests--text (or (cdr update) ""))))
                      updates))))

(ert-deftest limen-message-record-keeps-what-each-agent-was-sent ()
  (let ((limen-message--history (make-hash-table :test #'equal))
        (limen-message-history-limit 3)
        (one '("server" . "one"))
        (two '("server" . "two")))
    (should-not (limen-message-record one "first" nil))
    (limen-message-record one "second" nil)
    (limen-message-record two "elsewhere" nil)
    (limen-message-record one "   " nil)
    (limen-message-record one "first" nil)
    (should (equal (gethash one limen-message--history) '("first" "second")))
    (should (equal (gethash two limen-message--history) '("elsewhere")))
    (dolist (text '("a" "b" "c"))
      (limen-message-record one text nil))
    (should (equal (gethash one limen-message--history) '("c" "b" "a")))))

(ert-deftest limen-message-walks-back-through-what-was-sent ()
  (limen-message-tests--state
    (let ((input "draft")
          (bounds (cons (point-min) (point-max))))
      (setf (limen-message--state-history state) '("newest" "older"))
      (cl-letf (((symbol-function 'cera-input-text) (lambda () input))
                ((symbol-function 'cera-input-bounds) (lambda () bounds))
                ((symbol-function 'cera-set-input) (lambda (text) (setq input text))))
        ;; Nothing recalled yet: the key moves the point instead.
        (ignore-errors (limen-message-history-newer))
        (should (equal input "draft"))
        (limen-message-history-older)
        (should (equal input "newest"))
        (should (= (limen-message--state-recalled state) 0))
        (limen-message-history-older)
        (limen-message-history-older)
        (should (equal input "older"))
        (should (= (limen-message--state-recalled state) 1))
        (limen-message-history-newer)
        (should (equal input "newest"))
        (limen-message-history-newer)
        (should (equal input "draft"))
        (should-not (limen-message--state-recalled state))))))

(ert-deftest limen-message-message-keys-say-when-there-is-nothing-indexed ()
  (limen-message-tests--state
    (should-error (limen-message-older) :type 'user-error)
    (should-error (limen-message-newer) :type 'user-error)))

(ert-deftest limen-message-history-keys-yield-where-the-point-can-still-move ()
  (limen-message-tests--state
    (insert "first line\nlast line")
    (let ((bounds (cons (point-min) (point-max))))
      (cl-letf (((symbol-function 'cera-input-bounds) (lambda () bounds)))
        (goto-char (point-min))
        (should (limen-message--input-edge-p 'first))
        (should-not (limen-message--input-edge-p 'last))
        (goto-char (point-max))
        (should (limen-message--input-edge-p 'last))
        (should-not (limen-message--input-edge-p 'first))))))

(ert-deftest limen-message-draws-the-message-as-the-markdown-it-was ()
  (limen-message-tests--state
    (let ((drawn 0)
          (limen-message--rendered (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'lectio-render)
                 (lambda (markdown &optional _code)
                   (cl-incf drawn)
                   (upcase markdown))))
        (limen-message--set-latest state "**bold** reply")
        (should (string-match-p "BOLD" (limen-message-tests--text (cdar updates))))
        ;; Redrawing the same message draws it once.
        (limen-message--show-context state)
        (should (= drawn 1))
        (let ((limen-message-markdown nil))
          (limen-message--show-context state)
          (should (string-match-p "\\*\\*bold\\*\\*"
                                  (limen-message-tests--text (cdar updates)))))))))

(ert-deftest limen-message-markdown-that-cannot-be-drawn-is-left-as-it-came ()
  (let ((limen-message--rendered (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'lectio-render)
               (lambda (&rest _) (error "No renderer"))))
      (should (equal (limen-message--rendered "plain") "plain")))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) nil))
              ((symbol-function 'fboundp) (lambda (&rest _) nil)))
      (should (equal (limen-message--rendered "plain") "plain")))))

(ert-deftest limen-message-callout-keeps-the-faces-the-markdown-was-drawn-in ()
  (let* ((drawn (concat "plain " (propertize "bold" 'face 'bold)))
         (callout (limen-message--callout drawn 'limen-message-text-face))
         (at (lambda (needle)
               (get-text-property (string-match needle callout) 'face callout))))
    (should (equal (funcall at "plain") 'limen-message-text-face))
    (should (equal (funcall at "bold") '(bold limen-message-text-face)))))

(ert-deftest limen-message-history-keys-stand-back-for-the-completion-menu ()
  (let ((completion-in-region-mode nil))
    (should (eq (limen-message--without-completion 'limen-message-history-older)
                'limen-message-history-older)))
  (let ((completion-in-region-mode t))
    (should-not (limen-message--without-completion 'limen-message-history-older))))

(ert-deftest limen-message-toggle-user-shows-both-sides-and-says-which-spoke ()
  (limen-message-tests--state
    (let ((limen-message-user-messages nil))
      (setf (limen-message--state-records state)
            (list (limen-message-tests--record 2 "assistant" "answered")
                  (limen-message-tests--record 2 "user" "asked"))
            (limen-message--state-scope state) '("claude" "id" "/opaque"))
      (limen-message--finish state)
      (should (equal (mapcar #'cdr (limen-message--state-messages state))
                     '("answered")))
      (should (eq (limen-message--rule-face (limen-message--state-role state)) limen-message-rule-face))
      (limen-message-toggle-user)
      (should limen-message-user-messages)
      (should (equal (limen-message--state-messages state)
                     '(("assistant" . "answered") ("user" . "asked"))))
      (should (eq (limen-message--rule-face (limen-message--state-role state)) 'limen-message-agent-rule))
      (limen-message-older)
      (should (equal (limen-message--state-latest state) "asked"))
      (should (eq (limen-message--rule-face (limen-message--state-role state)) 'limen-message-user-rule))
      (let ((pane (limen-message-tests--text (cdar updates))))
        (should (text-property-any 0 (length pane) 'face 'limen-message-user-rule pane))
        (should-not (text-property-any 0 (length pane) 'face
                                       'limen-message-agent-rule pane)))
      (limen-message-toggle-user)
      (should-not limen-message-user-messages))))

(ert-deftest limen-message-cycling-shows-more-messages-oldest-first ()
  (limen-message-tests--state
    (let ((limen-message-message-counts '(1 2 3))
          (limen-message--shown nil)
          (limen-message-markdown nil))
      (setf (limen-message--state-records state)
            (append (limen-message-tests--exchange 3 "third")
                    (limen-message-tests--exchange 2 "second")
                    (limen-message-tests--exchange 1 "first"))
            (limen-message--state-scope state) '("claude" "id" "/opaque"))
      (limen-message--finish state)
      (should (equal (mapcar #'cdr (limen-message--state-messages state))
                     '("third" "second" "first")))
      (should (equal (limen-message-tests--bare (cdar updates)) "\nthird"))
      (limen-message-cycle-messages)
      (should (= limen-message--shown 2))
      (should (equal (limen-message-tests--bare (cdar updates))
                     "\nsecond\nthird"))
      (limen-message-cycle-messages)
      (should (equal (limen-message-tests--bare (cdar updates))
                     "\nfirst\nsecond\nthird"))
      ;; The steps wrap round to the first.
      (limen-message-cycle-messages)
      (should (= limen-message--shown 1))
      (should (equal (limen-message-tests--bare (cdar updates)) "\nthird"))
      ;; The window follows the walk, and stops where what was read does.
      (limen-message-cycle-messages)
      (limen-message-older)
      (should (equal (limen-message-tests--bare (cdar updates))
                     "\nfirst\nsecond")))))

(ert-deftest limen-message-codex-is-asked-in-its-own-directory-and-read-from-a-file ()
  (limen-message-tests--process
    (let ((limen-message-backends '(codex))
          (limen-message-codex-model "gpt-5.6-luna")
          (limen-message-codex-effort "low"))
      (limen-message--generate state 'key "private transcript; $(bad)")
      (should (equal (car argv) "codex"))
      (should (equal (cadr argv) "exec"))
      (should (equal (cadr (member "--model" argv)) "gpt-5.6-luna"))
      (should (equal (cadr (member "-c" argv)) "model_reasoning_effort=\"low\""))
      (should (equal (cadr (member "--sandbox" argv)) "read-only"))
      (should (member "--ephemeral" argv))
      (should (member "--skip-git-repo-check" argv))
      (should (member "--ignore-user-config" argv))
      ;; The transcript is never an argument, and the instruction leads it.
      (should-not (seq-some (lambda (arg) (string-match-p "private transcript" arg)) argv))
      (should (string-prefix-p limen-message--instruction stdin))
      (should (string-suffix-p "private transcript; $(bad)" stdin))
      ;; Codex reports as it works, so its answer is taken from the file it
      ;; was told to leave it in rather than from what it said.
      (let ((file (cadr (member "-o" argv))))
        (should (equal (file-name-directory file) cwd))
        (write-region "Rescanning the stale index." nil file nil 'quiet))
      (funcall filter 'fake-process "thinking out loud")
      (setq status 'exit)
      (funcall sentinel 'fake-process "finished")
      (should (equal (gethash 'key limen-message--summaries)
                     "Rescanning the stale index.")))))

(ert-deftest limen-message-a-backend-that-fails-hands-on-to-the-next ()
  (limen-message-tests--state
    (let ((limen-message--summaries (make-hash-table :test #'equal))
          (limen-message-backends '(codex claude))
          commands sentinels (status 'run) (exit-code 1))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest keys)
                   (push (car (plist-get keys :command)) commands)
                   (push (plist-get keys :sentinel) sentinels)
                   'fake-process))
                ((symbol-function 'process-send-string) #'ignore)
                ((symbol-function 'process-send-eof) #'ignore)
                ((symbol-function 'process-status) (lambda (_) status))
                ((symbol-function 'process-exit-status) (lambda (_) exit-code))
                ((symbol-function 'process-live-p) (lambda (_) (eq status 'run)))
                ((symbol-function 'delete-process) #'ignore)
                ((symbol-function 'run-at-time)
                 (lambda (&rest _) (timer-create)))
                ((symbol-function 'cancel-timer) #'ignore))
        (limen-message--generate state 'key "conversation")
        (should (equal commands '("codex")))
        ;; Codex ends badly, so claude is asked the same question.
        (setq status 'exit)
        (funcall (car sentinels) 'fake-process "failed")
        (should (equal (reverse commands) '("codex" "claude")))
        (setq exit-code 0)
        (cl-letf (((symbol-function 'limen-message--answered)
                   (lambda (&rest _) "What claude said")))
          (funcall (car sentinels) 'fake-process "finished"))
        (should (equal (gethash 'key limen-message--summaries) "What claude said"))))))

(ert-deftest limen-message-nothing-left-to-ask-keeps-the-recap-already-held ()
  (limen-message-tests--state
    (let ((limen-message--recaps (make-hash-table :test #'equal)))
      (setf (limen-message--state-scope state) '("claude" "id" "/one"))
      (puthash '("claude" "id" "/one") "earlier recap" limen-message--recaps)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "Unexpected command"))))
        (let ((limen-message-backends '()))
          (limen-message--generate state 'key "conversation"))
        (should (equal (limen-message--state-recap state) "earlier recap"))))))

(ert-deftest limen-message-messages-are-held-apart-by-a-gap ()
  (limen-message-tests--state
    (let ((limen-message-message-counts '(2))
          (limen-message--shown nil)
          (limen-message-message-gap 3)
          (limen-message-headroom 8)
          (limen-message-headroom-above 1)
          (limen-message-markdown nil))
      (setf (limen-message--state-records state)
            (append (limen-message-tests--exchange 2 "second")
                    (limen-message-tests--exchange 1 "first"))
            (limen-message--state-scope state) '("claude" "id" "/opaque"))
      (limen-message--finish state)
      (let ((blocks (cdar updates)))
        (should (equal (mapcar #'cdr blocks) '(1 0 3 8)))
        (should (equal (car (car blocks)) ""))
        (should-not (equal (car (car (last blocks))) ""))
        (should (equal (limen-message-tests--bare blocks) "\nfirst\nsecond"))))))

(ert-deftest limen-message-the-count-chosen-outlives-the-field ()
  "A number of messages chosen in one field is what the next opens on."
  (let ((limen-message-message-counts '(1 2 3))
        (limen-message--shown nil)
        (limen-message-markdown nil))
    (limen-message-tests--state
      (setf (limen-message--state-records state)
            (list (limen-message-tests--record 2 "assistant" "second")
                  (limen-message-tests--record 1 "assistant" "first"))
            (limen-message--state-scope state) '("claude" "id" "/opaque"))
      (limen-message--finish state)
      (limen-message-cycle-messages)
      (should (= limen-message--shown 2)))
    ;; A field of its own, opened after the one that chose the number.
    (limen-message-tests--state
      (setf (limen-message--state-records state)
            (list (limen-message-tests--record 2 "assistant" "second")
                  (limen-message-tests--record 1 "assistant" "first"))
            (limen-message--state-scope state) '("claude" "id" "/opaque"))
      (limen-message--finish state)
      (should (equal (limen-message-tests--bare (cdar updates))
                     "\nfirst\nsecond")))))

;; The picker offers the provider's models with their windows beside them,
;; and moves the agent with the command the provider takes.
(ert-deftest limen-message-picks-a-model-for-the-agent ()
  (require 'limen-usage)
  (let ((limen-message-status nil)
        (limen-message-models '((claude :command "/model %s"
                                        :models ("claude-opus-5-5"
                                                 "claude-opus-5-5[1m]"))))
        sent annotations)
    (limen-message-tests--state
      (cl-letf (((symbol-function 'herdr-agent-find) (lambda (&rest _) 'agent))
                ((symbol-function 'herdr-agent-session-agent-session) #'ignore)
                ((symbol-function 'herdr-agent-session-kind) (lambda (_) "claude"))
                ((symbol-function 'herdr-agent-session-project) #'ignore)
                ((symbol-function 'herdr-agent-prompt)
                 (lambda (target text) (setq sent (cons target text))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (let ((annotate (alist-get 'annotation-function
                                              (cdr (funcall table "" nil 'metadata)))))
                     (setq annotations
                           (mapcar (lambda (model)
                                     (string-trim (funcall annotate model)))
                                   (all-completions "" table))))
                   "claude-opus-5-5[1m]")))
        (limen-message-pick-model)
        (should (equal sent '(("server" . "terminal") . "/model claude-opus-5-5[1m]")))
        (should (equal annotations '("200k" "1M")))
        (should (equal (limen-message--state-model state) "claude-opus-5-5[1m]"))))))

(defconst limen-message-tests--codex-screens
  '((composer . "› Ask Codex to do anything\n")
    (models . "  Select Model and Effort
› 1. gpt-6-astra (current)  Frontier intelligence for the most demanding work.
  2. gpt-5.6-sol
Older coding model for complex work.
  3. gpt-6-sol
Workhorse model for coding and everyday work.
Press enter to confirm or esc to go back\n")
    (levels . "  Select Reasoning Level for gpt-6-sol
  1. Low
Fast responses with lighter reasoning
› 2. Medium (default)  Balances speed and reasoning depth for everyday tasks
  3. High
Greater reasoning depth for complex problems
  5. More reasoning…   Max consumes usage limits faster
Press enter to confirm or esc to go back\n")
    (advanced . "  Advanced Reasoning
⚠ Consumes usage limits faster
› 1. Max  For difficult problems when quality matters more than speed
Press enter to confirm or esc to go back\n"))
  "The screens Codex 0.155 draws for /model, keyed by where it is.")

(defmacro limen-message-tests--with-codex (choose &rest body)
  "Run BODY against a Codex walking its /model menus as the real one does.
CHOOSE answers each reasoning prompt, called with the offered levels and
the default.  BODY sees the keys sent in SENT, the offers in OFFERED and
where Codex ended up in PLACE."
  (declare (indent 1))
  `(let ((place 'composer) sent offered)
     (cl-letf (((symbol-function 'herdr-agent-paste)
                (lambda (_target text) (push text sent)))
               ((symbol-function 'herdr-agent-type-keys)
                (lambda (_target keys)
                  (dolist (key keys)
                    (push key sent)
                    (setq place
                          (pcase (cons place key)
                            ('(composer . "enter") 'models)
                            ('(models . "3") 'levels)
                            ('(levels . "5") 'advanced)
                            (`(levels . ,(or "1" "2" "3")) 'composer)
                            ('(advanced . "1") 'composer)
                            ('(advanced . "esc") 'levels)
                            ('(levels . "esc") 'models)
                            ('(models . "esc") 'composer)
                            (_ place))))))
               ((symbol-function 'herdr-agent-read)
                (lambda (_target)
                  (alist-get place limen-message-tests--codex-screens)))
               ((symbol-function 'completing-read)
                (lambda (_prompt levels &rest args)
                  (push (cons levels (nth 4 args)) offered)
                  (funcall ,choose levels (nth 4 args))))
               ((symbol-function 'sleep-for) #'ignore))
       ,@body)))

(ert-deftest limen-message-moves-codex-onto-a-model-and-reasoning-level ()
  (limen-message-tests--with-codex (lambda (_levels _default) "High")
    (limen-message-codex-model '("server" . "terminal") "gpt-6-sol")
    (should (equal (reverse sent) '("/model" "enter" "3" "3")))
    (should (equal offered '((("Low" "Medium" "High" "More reasoning…") . "Medium"))))
    (should (eq place 'composer))))

(ert-deftest limen-message-follows-codex-into-its-advanced-reasoning ()
  (limen-message-tests--with-codex
      (lambda (levels _default) (if (member "Max" levels) "Max" "More reasoning…"))
    (limen-message-codex-model '("server" . "terminal") "gpt-6-sol")
    (should (equal (reverse sent) '("/model" "enter" "3" "5" "1")))
    (should (equal (car offered) '(("Max") . "Max")))
    (should (eq place 'composer))))

(ert-deftest limen-message-closes-codex-s-menu-for-a-model-it-lacks ()
  (limen-message-tests--with-codex #'ignore
    (should-error (limen-message-codex-model '("server" . "terminal") "gpt-9")
                  :type 'user-error)
    (should (equal (reverse sent) '("/model" "enter" "esc")))
    (should (eq place 'composer))))

(ert-deftest limen-message-closes-codex-s-menu-when-the-level-is-not-given ()
  (limen-message-tests--with-codex (lambda (&rest _) (signal 'quit nil))
    (should (eq (condition-case nil
                    (limen-message-codex-model '("server" . "terminal") "gpt-6-sol")
                  (quit 'quit))
                'quit))
    (should (equal (reverse sent) '("/model" "enter" "3" "esc" "esc")))
    (should (eq place 'composer))))

(defmacro limen-message-tests--with-agent-in (workspace &rest body)
  "Run BODY with STATE's agent named \"agent\" working in WORKSPACE's project."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'herdr-agent-find) #'ignore)
             ((symbol-function 'herdr--entry-for-target)
              (lambda (_target) '((name . "agent") (cwd . "/p/shiftlet/"))))
             ((symbol-function 'herdr-entry-directory)
              (lambda (entry) (alist-get 'cwd entry)))
             ((symbol-function 'herdr--entry-label)
              (lambda (entry) (alist-get 'name entry)))
             ((symbol-function 'herdr-workspace-label)
              (lambda (_directory) ,workspace)))
     ,@body))

(ert-deftest limen-message-status-names-an-agent-of-another-workspace ()
  (skip-unless (require 'herdr-status nil t))
  (let ((herdr-status-field-glyphs '((workspace "W") (pane "P"))))
    (limen-message-tests--state
      (setf (limen-message--state-workspace state) "main")
      (limen-message-tests--with-agent-in "shiftlet"
        (should (equal (substring-no-properties (limen-message--status state))
                       "W shiftlet  P agent"))))))

(ert-deftest limen-message-reads-an-agent-attached-nowhere-from-herdr ()
  (limen-message-tests--state
    (cl-letf (((symbol-function 'herdr-agent-find) #'ignore)
              ((symbol-function 'herdr--entry-for-target)
               (lambda (_target)
                 '((agent . "codex")
                   (agent_session (kind . "id") (value . "01a0")))))
              ((symbol-function 'herdr-agent--entry-project)
               (lambda (_entry) "/p/shiftlet/")))
      (should (equal (limen-message--agent state)
                     '(codex ((kind . "id") (value . "01a0")) "/p/shiftlet/"))))))

(ert-deftest limen-message-status-leaves-out-an-agent-of-its-own-workspace ()
  (limen-message-tests--state
    (setf (limen-message--state-workspace state) "shiftlet")
    (limen-message-tests--with-agent-in "shiftlet"
      (should-not (limen-message--status state)))))

(ert-deftest limen-message-sets-the-agent-s-effort ()
  (let ((limen-message-models '((claude :effort "/effort %s"
                                        :efforts ("low" "high"))))
        sent offered)
    (limen-message-tests--state
      (cl-letf (((symbol-function 'herdr-agent-find) (lambda (&rest _) 'agent))
                ((symbol-function 'herdr-agent-session-agent-session) #'ignore)
                ((symbol-function 'herdr-agent-session-kind) (lambda (_) "claude"))
                ((symbol-function 'herdr-agent-session-project) #'ignore)
                ((symbol-function 'herdr-agent-prompt)
                 (lambda (target text) (setq sent (cons target text))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt efforts &rest _) (setq offered efforts) "high")))
        (limen-message-pick-effort)
        (should (equal offered '("low" "high")))
        (should (equal sent '(("server" . "terminal") . "/effort high")))
        (should-not (limen-message--state-model state))))))

(ert-deftest limen-message-knows-no-models-for-an-unlisted-agent ()
  (let ((limen-message-models nil))
    (limen-message-tests--state
      (cl-letf (((symbol-function 'herdr-agent-find) (lambda (&rest _) 'agent))
                ((symbol-function 'herdr-agent-session-agent-session) #'ignore)
                ((symbol-function 'herdr-agent-session-kind) (lambda (_) "codex"))
                ((symbol-function 'herdr-agent-session-project) #'ignore)
                ((symbol-function 'herdr-agent-prompt)
                 (lambda (&rest _) (ert-fail "Prompted"))))
        (should-error (limen-message-pick-model) :type 'user-error)))))

(ert-deftest limen-message-status-shows-the-effort-behind-the-model ()
  (limen-message-tests--state
    (setf (limen-message--state-model state) "Opus 5.5"
          (limen-message--state-effort state) "xhigh")
    (cl-letf (((symbol-function 'limen-message--agent) #'ignore)
              ((symbol-function 'limen-message--elsewhere) #'ignore))
      (should (string-suffix-p "Opus 5.5/xhigh"
                               (substring-no-properties (limen-message--status state)))))))

(ert-deftest limen-message-pick-effort-reports-it-with-the-model ()
  "The effort picked goes to the agent, the status line and the dashboard."
  (require 'limen-model)
  (limen-message-tests--state
    (setf (limen-message--state-model state) "Opus 5.5")
    (let ((limen-message-models '((claude :efforts ("high" "xhigh") :effort "/effort %s")))
          (limen-message-status nil)
          sent reported)
      (cl-letf (((symbol-function 'limen-message--state-here) (lambda () state))
                ((symbol-function 'limen-message--agent) (lambda (_) '(claude nil nil)))
                ((symbol-function 'completing-read) (lambda (&rest _) "xhigh"))
                ((symbol-function 'herdr-agent-prompt)
                 (lambda (_target text) (push text sent)))
                ((symbol-function 'herdr--entry-for-target)
                 (lambda (_target) '((pane_id . "%4"))))
                ((symbol-function 'limen-model-report)
                 (lambda (server pane label) (setq reported (list server pane label)))))
        (limen-message-pick-effort))
      (should (equal sent '("/effort xhigh")))
      (should (equal (limen-message--state-effort state) "xhigh"))
      (should (equal reported '("server" "%4" "Opus 5.5/xhigh"))))))

(provide 'limen-message-tests)
;;; limen-message-tests.el ends here
