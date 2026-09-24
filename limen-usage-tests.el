;;; limen-usage-tests.el --- Context window reporting tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-usage)

(defvar herdr-status-context-token)

(defvar herdr-socket-path)

(defun limen-usage-tests--answer (model held &optional sidechain)
  "Return an answer line on MODEL accounting for HELD tokens.
A SIDECHAIN line is marked as a subagent's."
  (json-serialize
   `((type . "assistant")
     ,@(and sidechain '((isSidechain . t)))
     (message . ((model . ,model)
                 (usage . ((input_tokens . 2)
                           (cache_creation_input_tokens . 1000)
                           (cache_read_input_tokens . ,(- held 1102))
                           (output_tokens . 100))))))))

(defun limen-usage-tests--transcript (lines)
  "Write LINES to a temporary transcript and return its name."
  (let ((file (make-temp-file "limen-usage" nil ".jsonl")))
    (with-temp-file file
      (dolist (line lines) (insert line "\n")))
    file))

(ert-deftest limen-usage-reads-the-window-the-model-answers-on ()
  (should (equal (limen-usage--limit "claude-opus-5[1m]" 10000) 1000000))
  (should (equal (limen-usage--limit "claude-opus-5" 10000) 200000))
  (should (equal (limen-usage--limit nil 10000) 200000))
  (let ((limen-usage-limits '(("\\`gpt-" . 400000))))
    (should (equal (limen-usage--limit "gpt-5-codex" 10000) 400000))
    (should (equal (limen-usage--limit "claude-opus-5[1m]" 10000) 200000))))

(ert-deftest limen-usage-takes-a-count-past-the-window-as-the-larger-one ()
  (should (equal (limen-usage--limit "claude-fable-5-1" 535684) 1000000))
  (should (equal (limen-usage--limit "claude-fable-5-1" 199999) 200000))
  (let ((limen-usage-windows '(200000 500000 1000000)))
    (should (equal (limen-usage--limit "claude-opus-5" 480000) 500000)))
  (should (equal (limen-usage--limit "claude-opus-5" 1200000) 1000000)))

(ert-deftest limen-usage-takes-the-last-answer-of-the-conversation-itself ()
  (let ((file (limen-usage-tests--transcript
               (list (limen-usage-tests--answer "claude-opus-5" 10000)
                     (json-serialize '((type . "user")))
                     (limen-usage-tests--answer "claude-opus-5[1m]" 140000)
                     (limen-usage-tests--answer "claude-haiku-4-5" 9000 t)))))
    (unwind-protect
        (should (equal (limen-usage-of-transcript file) '(140000 . 1000000)))
      (delete-file file))))

(ert-deftest limen-usage-widens-its-read-until-an-answer-turns-up ()
  (let* ((filler (json-serialize `((type . "user") (content . ,(make-string 200000 ?x)))))
         (file (limen-usage-tests--transcript
                (list (limen-usage-tests--answer "claude-opus-5" 120000) filler))))
    (unwind-protect
        (should (equal (limen-usage-of-transcript file) '(120000 . 200000)))
      (delete-file file))))

(ert-deftest limen-usage-answers-nothing-for-a-transcript-without-answers ()
  (let ((file (limen-usage-tests--transcript
               (list (json-serialize '((type . "user"))) "not json" ""))))
    (unwind-protect
        (should-not (limen-usage-of-transcript file))
      (delete-file file)))
  (should-not (limen-usage-of-transcript "/nonexistent/transcript.jsonl"))
  (should-not (limen-usage-of-transcript nil)))

(defun limen-usage-tests--count (held window)
  "Return a codex count line naming HELD tokens against WINDOW."
  (json-serialize
   `((type . "event_msg")
     (payload . ((type . "token_count")
                 (info . ((last_token_usage
                           . ((input_tokens . ,(- held 384))
                              (cached_input_tokens . 35584)
                              (output_tokens . 384)
                              (total_tokens . ,held)))
                          ,@(and window (list (cons 'model_context_window
                                                    window))))))))))

(ert-deftest limen-usage-takes-the-window-codex-counts-against ()
  (let ((file (limen-usage-tests--transcript
               (list (limen-usage-tests--count 12000 258400)
                     (json-serialize '((type . "response_item")))
                     (limen-usage-tests--count 36455 258400)))))
    (unwind-protect
        (should (equal (limen-usage-of-transcript file 'codex)
                       '(36455 . 258400)))
      (delete-file file))))

(ert-deftest limen-usage-falls-back-to-a-read-window-for-a-count-naming-none ()
  (let ((file (limen-usage-tests--transcript
               (list (limen-usage-tests--count 36455 nil)))))
    (unwind-protect
        (should (equal (limen-usage-of-transcript file 'codex)
                       '(36455 . 200000)))
      (delete-file file))))

(defun limen-usage-tests--omp-answer (model held)
  "Return an omp answer line on MODEL totalling HELD tokens."
  (json-serialize
   `((type . "message")
     (message . ((role . "assistant")
                 (model . ,model)
                 (usage . ((input . 1302) (output . 241)
                           (cacheRead . ,(- held 1543)) (cacheWrite . 0)
                           (totalTokens . ,held))))))))

(ert-deftest limen-usage-totals-what-omp-counted-for-itself ()
  (let ((file (limen-usage-tests--transcript
               (list (limen-usage-tests--omp-answer "gpt-5.6-luna" 12000)
                     (json-serialize '((type . "model_change")))
                     (limen-usage-tests--omp-answer "gpt-5.6-luna" 48135)))))
    (unwind-protect
        (should (equal (limen-usage-of-transcript file 'omp) '(48135 . 200000)))
      (delete-file file))))

(ert-deftest limen-usage-reads-a-transcript-only-on-the-terms-of-its-writer ()
  (let ((file (limen-usage-tests--transcript
               (list (limen-usage-tests--count 36455 258400)))))
    (unwind-protect
        (should-not (limen-usage-of-transcript file 'claude))
      (delete-file file)))
  (let ((file (limen-usage-tests--transcript
               (list (limen-usage-tests--answer "claude-opus-5" 10000)))))
    (unwind-protect
        (progn
          (should-not (limen-usage-of-transcript file 'codex))
          (should-not (limen-usage-of-transcript file 'pi)))
      (delete-file file))))

(ert-deftest limen-usage-shortens-the-figure-to-a-column ()
  (should (equal (limen-usage-format 135600 200000) "136k/200k"))
  (should (equal (limen-usage-format 1000 1000000) "1k/1M"))
  (should (equal (limen-usage-format 1240000 1000000) "1.2M/1M"))
  (should (equal (limen-usage-format 940 200000) "940/200k")))

(ert-deftest limen-usage-reports-to-the-pane-the-event-came-from ()
  (let ((limen-usage-token "context")
        (limen-usage-source "limen")
        calls)
    (cl-letf (((symbol-function 'herdr-api-pane-report-metadata)
               (lambda (pane source &rest arguments)
                 (push (list pane source herdr-socket-path
                             (plist-get arguments :tokens))
                       calls))))
      (limen-usage-report "/tmp/alpha.sock" "%1" "136k/200k")
      (should (equal calls
                     '(("%1" "limen" "/tmp/alpha.sock"
                        ((context . "136k/200k")))))))))

(ert-deftest limen-usage-takes-the-count-an-event-carries ()
  (should (equal (limen-usage-of '((hook_event_name . "PostModelSwitch")
                                   (to_model . "claude-opus-5[1m]")
                                   (context_tokens . 535684)))
                 "536k/1M"))
  (should (equal (limen-usage-of '((hook_event_name . "SessionStart")
                                   (model . "claude-opus-5")
                                   (context_tokens . 135600)))
                 "136k/200k"))
  (should-not (limen-usage-of '((hook_event_name . "SessionStart")
                                (context_tokens . 0))))
  (should-not (limen-usage-of '((hook_event_name . "Stop")))))

(ert-deftest limen-usage-reads-no-transcript-for-an-event-it-counts-on-a-count ()
  (let (scheduled)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest arguments)
                 (push (cons function arguments) scheduled))))
      (limen-usage--report-event
       "claude"
       '((hook_event_name . "PostModelSwitch") (to_model . "claude-opus-5")
         (context_tokens . 135600) (server . "/tmp/alpha.sock") (pane . "%1")
         (transcript_path . "/tmp/a.jsonl"))
       nil nil)
      (should (equal scheduled
                     '((limen-usage-report
                        "/tmp/alpha.sock" "%1" "136k/200k"))))
      (setq scheduled nil)
      (limen-usage--report-event
       "claude"
       '((hook_event_name . "UserPromptSubmit") (server . "/tmp/alpha.sock")
         (pane . "%1") (transcript_path . "/tmp/a.jsonl"))
       nil nil)
      (should-not scheduled))))

(ert-deftest limen-usage-leaves-the-hook-filter-before-reading-or-reporting ()
  (let (scheduled)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (time repeat function &rest arguments)
                 (push (list time repeat function arguments) scheduled)))
              ((symbol-function 'herdr-api-pane-report-metadata)
               (lambda (&rest _) (ert-fail "reported from inside the hook"))))
      (should-not (limen-usage--report-event
                   "claude"
                   '((hook_event_name . "Stop") (server . "/tmp/alpha.sock")
                     (pane . "%1") (transcript_path . "/tmp/a.jsonl"))
                   nil nil))
      (should (equal scheduled
                     '((0 nil limen-usage--report
                          ("/tmp/alpha.sock" "%1" "/tmp/a.jsonl" claude)))))
      (setq scheduled nil)
      (limen-usage--report-event
       "claude"
       '((hook_event_name . "Stop") (server . "/tmp/alpha.sock") (pane . "%1"))
       nil nil)
      (should-not scheduled))))

(provide 'limen-usage-tests)
;;; limen-usage-tests.el ends here

(ert-deftest limen-usage-takes-the-window-an-event-names ()
  (should (equal (limen-usage-of '((hook_event_name . "Stop")
                                   (context_tokens . 48135)
                                   (context_window . 258400)))
                 "48k/258k"))
  (should (equal (limen-usage-of '((hook_event_name . "Stop")
                                   (context_tokens . 48135)
                                   (context_window . 400)))
                 "48k/200k")))

(ert-deftest limen-usage-passes-over-an-agent-already-counted ()
  (let ((limen-usage-token "context"))
    (should (limen-usage--reported-p '((tokens . ((context . "48k/258k"))))))
    (should-not (limen-usage--reported-p '((tokens . ((context . ""))))))
    (should-not (limen-usage--reported-p '((tokens . ((model . "opus"))))))
    (should-not (limen-usage--reported-p '((pane_id . "%1")))))
  (let ((limen-usage-token "held"))
    (should (limen-usage--reported-p '((tokens . ((held . "1k/200k"))))))
    (should-not (limen-usage--reported-p '((tokens . ((context . "1k/200k"))))))))

(ert-deftest limen-usage-backfill-reads-nothing-for-a-counted-agent ()
  (let ((limen-usage-token "context")
        read reported)
    (cl-letf (((symbol-function 'limen-usage--agent-answer)
               (lambda (entry) (push entry read) nil))
              ((symbol-function 'limen-usage-report)
               (lambda (&rest arguments) (push arguments reported) t)))
      (should (= (limen-usage-backfill
                  '(("/tmp/a.sock" . ((pane_id . "%1")
                                      (tokens . ((context . "48k/258k")))))))
                 0))
      (should-not read)
      (should-not reported))))

(ert-deftest limen-usage-takes-the-token-name-from-whatever-reads-it ()
  (let ((limen-usage-token nil))
    (let ((herdr-status-context-token "window"))
      (should (equal (limen-usage-token) "window")))
    (should (equal (limen-usage-token) "context")))
  (let ((limen-usage-token "held")
        (herdr-status-context-token "window"))
    (should (equal (limen-usage-token) "held"))))
