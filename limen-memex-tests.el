;;; limen-memex-tests.el --- Live memex view tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-memex)

(defvar memex-view-session-id)
(defvar memex-view-source-path)

(defmacro limen-memex-tests--with-views (specs &rest body)
  "Run BODY with VIEWS bound to memex views made from SPECS.
Each spec is (SESSION-ID SOURCE-PATH); `memex-view-refresh' records the
buffers it is asked to redraw in REFRESHED, and timers fire at once."
  (declare (indent 1) (debug t))
  `(let ((views (mapcar (lambda (spec)
                          (let ((buffer (generate-new-buffer "*memex view*")))
                            (with-current-buffer buffer
                              (setq major-mode 'memex-session-mode)
                              (setq-local memex-view-session-id (nth 0 spec))
                              (setq-local memex-view-source-path (nth 1 spec)))
                            buffer))
                        ,specs))
         (refreshed nil)
         (limen-memex-live-visible-only nil))
     (unwind-protect
         (cl-letf (((symbol-function 'memex-view-refresh)
                    (lambda (buffer) (push buffer refreshed))))
           ,@body)
       (mapc #'kill-buffer views))))

(defun limen-memex-tests--fire (payload)
  "Hand PAYLOAD to the live mode's event function and run what it scheduled."
  (let (scheduled)
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (_delay _repeat function &rest arguments)
                 (push (cons function arguments) scheduled)
                 (timer-create))))
      (limen-memex--on-event "claude" payload nil nil))
    (dolist (call (nreverse scheduled))
      (apply (car call) (cdr call)))))

(ert-deftest limen-memex-redraws-the-view-of-the-reporting-conversation ()
  (limen-memex-tests--with-views '(("s1" "/tmp/limen-memex/s1.jsonl")
                                   ("s2" "/tmp/limen-memex/s2.jsonl"))
    (limen-memex-tests--fire '((hook_event_name . "Stop") (session_id . "s1")
                               (transcript_path . "/tmp/limen-memex/s1.jsonl")))
    (should (equal refreshed (list (car views))))))

(ert-deftest limen-memex-matches-a-harness-that-reports-no-transcript-by-id ()
  (limen-memex-tests--with-views '(("s1" "/tmp/limen-memex/s1.jsonl"))
    (limen-memex-tests--fire '((hook_event_name . "Stop") (session_id . "s1")))
    (should (equal refreshed views))))

(ert-deftest limen-memex-lets-the-transcript-decide-when-both-sides-know-one ()
  "One session id can recur across transcripts, which only the file tells apart."
  (limen-memex-tests--with-views '(("s1" "/tmp/limen-memex/one/s1.jsonl"))
    (limen-memex-tests--fire '((hook_event_name . "Stop") (session_id . "s1")
                               (transcript_path . "/tmp/limen-memex/two/s1.jsonl")))
    (should-not refreshed)))

(ert-deftest limen-memex-matches-a-transcript-named-through-a-link ()
  (let* ((directory (file-truename (make-temp-file "limen-memex" t)))
         (file (expand-file-name "s1.jsonl" directory))
         (link (expand-file-name "link.jsonl" directory)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "{}\n"))
          (make-symbolic-link file link)
          (limen-memex-tests--with-views (list (list "memex-id" file))
            (limen-memex-tests--fire `((hook_event_name . "PostToolUse")
                                       (session_id . "harness-id")
                                       (transcript_path . ,link)))
            (should (equal refreshed views))))
      (delete-directory directory t))))

(ert-deftest limen-memex-coalesces-a-burst-into-one-redraw ()
  (limen-memex-tests--with-views '(("s1" "/tmp/limen-memex/s1.jsonl"))
    (let ((limen-memex-live-delay 0.05)
          (payload '((hook_event_name . "PostToolUse") (session_id . "s1"))))
      (dotimes (_ 3)
        (limen-memex--on-event "claude" payload nil nil))
      (should-not refreshed)
      (sleep-for 0.2)
      (should (equal refreshed views))
      (should-not (buffer-local-value 'limen-memex--timer (car views))))))

(ert-deftest limen-memex-leaves-a-buried-view-alone ()
  (limen-memex-tests--with-views '(("s1" "/tmp/limen-memex/s1.jsonl"))
    (let ((limen-memex-live-visible-only t)
          (payload '((hook_event_name . "Stop") (session_id . "s1"))))
      (limen-memex-tests--fire payload)
      (should-not refreshed)
      (save-window-excursion
        (set-window-buffer (selected-window) (car views))
        (limen-memex-tests--fire payload))
      (should (equal refreshed views)))))

(ert-deftest limen-memex-ignores-buffers-in-other-modes ()
  (with-temp-buffer
    (setq-local memex-view-session-id "s1")
    (should-not (limen-memex--view-p (current-buffer) '((session_id . "s1"))))))

(ert-deftest limen-memex-live-mode-subscribes-and-unsubscribes ()
  (let ((limen-hooks--subscriptions nil)
        (limen-hooks-event-functions nil)
        requested)
    (cl-letf (((symbol-function 'limen-hooks-request-install)
               (lambda (feature) (push feature requested)))
              ((symbol-function 'limen-hooks-installing-providers) #'ignore)
              ((symbol-function 'memex-view-refresh) #'ignore)
              ((symbol-function 'require)
               (lambda (feature &rest arguments)
                 (or (eq feature 'memex-view) (apply #'require feature arguments)))))
      (unwind-protect
          (progn
            (limen-memex-live-mode 1)
            (should (equal requested '("memex")))
            (should (equal (limen-hooks-events) limen-memex-live-events))
            (should (memq #'limen-memex--on-event limen-hooks-event-functions))
            (limen-memex-live-mode -1)
            (should-not (limen-hooks-events))
            (should-not (memq #'limen-memex--on-event limen-hooks-event-functions)))
        (limen-memex-live-mode -1)))))

(ert-deftest limen-memex-live-mode-refuses-without-a-refreshing-viewer ()
  (let ((limen-hooks--subscriptions nil))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &rest arguments)
                 (unless (eq feature 'memex-view) (apply #'require feature arguments)))))
      (should-error (limen-memex-live-mode 1) :type 'user-error)
      (should-not limen-memex-live-mode)
      (should-not limen-hooks--subscriptions))))

(provide 'limen-memex-tests)
;;; limen-memex-tests.el ends here
