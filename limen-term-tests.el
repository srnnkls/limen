;;; limen-term-tests.el --- Agent terminal tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-term)

(defvar limen-term-tests--writes nil
  "What a stub backend was asked to send and paste, in order.")

(defvar limen-term-tests--screen ""
  "What a stub backend answers as its screen.")

(define-derived-mode limen-term-tests-mode fundamental-mode "Stub"
  "A terminal a test can drive.")

(defun limen-term-tests--screen ()
  "Answer the screen a test set."
  limen-term-tests--screen)

(defun limen-term-tests--send (string)
  "Record STRING as typed input."
  (push (cons 'send string) limen-term-tests--writes))

(defun limen-term-tests--paste (string)
  "Record STRING as a bracketed paste."
  (push (cons 'paste string) limen-term-tests--writes))

(defmacro limen-term-tests--with-terminal (screen &rest body)
  "Run BODY with a stub terminal answering SCREEN as the agent's."
  (declare (indent 1) (debug t))
  `(let ((limen-term-backends '((limen-term-tests-mode
                                 :screen limen-term-tests--screen
                                 :send limen-term-tests--send
                                 :paste limen-term-tests--paste)))
         (limen-term-tests--writes nil)
         (limen-term-tests--screen ,screen))
     (with-temp-buffer
       (limen-term-tests-mode)
       (let ((buffer (current-buffer)))
         (cl-letf (((symbol-function 'herdr-terminal-buffer)
                    (lambda (&rest _) buffer))
                   ((symbol-function 'get-buffer-window)
                    (lambda (&rest _) t)))
           ,@body)))))

(defun limen-term-tests--box (&rest lines)
  "Return a screen whose prompt box holds LINES."
  (let ((rule (make-string 40 ?─)))
    (string-join (append (list "⏺ a reply" "" rule)
                         lines
                         (list rule "  Opus 5 | limen"))
                 "\n")))

(ert-deftest limen-term-reads-the-draft-standing-in-the-prompt ()
  (should (equal (limen-term-draft (limen-term-tests--box "❯ keep me"))
                 "keep me"))
  (should (equal (limen-term-draft (limen-term-tests--box "› keep me"))
                 "keep me"))
  (should (equal (limen-term-draft (limen-term-tests--box "> keep me  "))
                 "keep me")))

(ert-deftest limen-term-a-prompt-parted-from-its-draft-by-a-hard-space-is-read ()
  (let ((hard "\u00a0"))
    (should (equal (limen-term-draft
                    (limen-term-tests--box (concat "❯" hard "keep me" hard hard)))
                   "keep me"))
    (should (equal (limen-term-draft
                    (limen-term-tests--box (concat "❯" hard "first")
                                           (concat hard hard "second")))
                   "first\nsecond"))
    (should-not (limen-term-draft
                 (limen-term-tests--box (concat "❯" hard hard hard))))))

(ert-deftest limen-term-an-empty-prompt-holds-no-draft ()
  (should-not (limen-term-draft (limen-term-tests--box "❯ ")))
  (should-not (limen-term-draft (limen-term-tests--box "❯    ")))
  (should-not (limen-term-draft "a screen with no prompt at all"))
  (should-not (limen-term-draft nil)))

(ert-deftest limen-term-a-draft-of-several-lines-is-read-whole ()
  (should (equal (limen-term-draft
                  (limen-term-tests--box "❯ first line" "  second line" "  third"))
                 "first line\nsecond line\nthird")))

(ert-deftest limen-term-a-draft-stops-at-the-rule-below-it ()
  (should (equal (limen-term-draft
                  (concat (limen-term-tests--box "❯ mine") "\n  -- INSERT --"))
                 "mine")))

(ert-deftest limen-term-the-last-prompt-on-a-screen-is-the-live-one ()
  (should (equal (limen-term-draft
                  (concat (limen-term-tests--box "❯ an older line") "\n"
                          (limen-term-tests--box "❯ the live one")))
                 "the live one")))

(ert-deftest limen-term-a-placeholder-is-not-a-draft ()
  (let ((limen-term-prompt-ignore '("\\`Try \"")))
    (should-not (limen-term-draft (limen-term-tests--box "❯ Try \"fix the test\"")))
    (should (equal (limen-term-draft (limen-term-tests--box "❯ mine")) "mine"))))

(ert-deftest limen-term-a-message-is-delivered-under-the-draft ()
  (limen-term-tests--with-terminal (limen-term-tests--box "❯ half a thought")
    (should (limen-term-deliver '("local" . "w1:p1") "a message"))
    (should (equal (reverse limen-term-tests--writes)
                   `((send . ,limen-term-clear-string)
                     (paste . "a message")
                     (send . ,limen-term-submit-string)
                     (paste . "half a thought"))))))

(ert-deftest limen-term-an-empty-prompt-is-left-to-the-usual-send ()
  (limen-term-tests--with-terminal (limen-term-tests--box "❯ ")
    (should-not (limen-term-deliver '("local" . "w1:p1") "a message"))
    (should-not limen-term-tests--writes)))

(ert-deftest limen-term-a-terminal-no-window-shows-answers-no-screen ()
  (limen-term-tests--with-terminal (limen-term-tests--box "❯ half a thought")
    (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
      (should-not (limen-term-screen (current-buffer)))
      (should-not (limen-term-deliver '("local" . "w1:p1") "a message"))
      (should-not limen-term-tests--writes))))

(ert-deftest limen-term-a-terminal-limen-cannot-drive-is-not-answered ()
  (limen-term-tests--with-terminal (limen-term-tests--box "❯ half a thought")
    (let ((limen-term-backends nil))
      (should-not (limen-term-buffer '("local" . "w1:p1")))
      (should-not (limen-term-deliver '("local" . "w1:p1") "a message"))
      (should-not limen-term-tests--writes))))

(ert-deftest limen-term-a-detached-session-is-not-answered ()
  (limen-term-tests--with-terminal (limen-term-tests--box "❯ half a thought")
    (cl-letf (((symbol-function 'herdr-terminal-buffer) (lambda (&rest _) nil)))
      (should-not (limen-term-buffer '("local" . "w1:p1")))
      (should-not (limen-term-deliver '("local" . "w1:p1") "a message"))
      (should-not limen-term-tests--writes))))

(provide 'limen-term-tests)
;;; limen-term-tests.el ends here
