;;; limen-transcript-tests.el --- Transcript tail tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'limen-transcript)

(defun limen-transcript-tests--file (text)
  "Write TEXT to a temporary transcript and return its name."
  (let ((file (make-temp-file "limen-transcript" nil ".jsonl")))
    (with-temp-file file (insert text))
    file))

(ert-deftest limen-transcript-reads-the-whole-of-a-short-transcript ()
  (let ((file (limen-transcript-tests--file "{\"a\":1}\n{\"a\":2}\n")))
    (unwind-protect
        (should (equal (limen-transcript-lines file) '("{\"a\":1}" "{\"a\":2}")))
      (delete-file file))))

(ert-deftest limen-transcript-cuts-a-bounded-tail-back-to-a-whole-line ()
  (let ((file (limen-transcript-tests--file
               (concat "first line that the tail cannot reach\n"
                       "{\"second\":true}\n{\"third\":true}\n"))))
    (unwind-protect
        (should (equal (limen-transcript-lines file 24)
                       '("{\"third\":true}")))
      (delete-file file))))

(ert-deftest limen-transcript-keeps-the-characters-a-tail-cuts-across ()
  (let ((file (limen-transcript-tests--file "{\"a\":\"ä\"}\n{\"b\":\"öü\"}\n")))
    (unwind-protect
        (should (equal (limen-transcript-lines file 14) '("{\"b\":\"öü\"}")))
      (delete-file file))))

(ert-deftest limen-transcript-answers-nothing-for-what-it-cannot-read ()
  (should-not (limen-transcript-tail "/nonexistent/transcript.jsonl"))
  (should-not (limen-transcript-tail nil))
  (should-not (limen-transcript-lines nil))
  (let ((file (limen-transcript-tests--file "")))
    (unwind-protect
        (should-not (limen-transcript-tail file))
      (delete-file file))))

(ert-deftest limen-transcript-counts-what-the-model-was-sent-and-answered ()
  (should (equal (limen-transcript--sum
                  '((input_tokens . 2) (cache_creation_input_tokens . 1000)
                    (cache_read_input_tokens . 534000) (output_tokens . 98))
                  '(input_tokens cache_creation_input_tokens
                                 cache_read_input_tokens output_tokens))
                 535100))
  (should (equal (limen-transcript--sum '((input_tokens . 12)) '(input_tokens)) 12))
  (should (equal (limen-transcript--sum '((input_tokens . :null)) '(input_tokens)) 0)))

(ert-deftest limen-transcript-names-the-model-of-the-last-answer ()
  (let ((file (make-temp-file "limen-transcript" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (json-serialize
                     '((type . "assistant")
                       (message . ((model . "claude-opus-5")
                                   (usage . ((input_tokens . 10)))))))
                    "\n"))
          (should (equal (alist-get 'model (limen-transcript-answer file 'claude))
                         "claude-opus-5"))
          (should-not (limen-transcript-answer file 'codex))
          (should-not (limen-transcript-answer file 'cursor)))
      (delete-file file))))

(provide 'limen-transcript-tests)
;;; limen-transcript-tests.el ends here
