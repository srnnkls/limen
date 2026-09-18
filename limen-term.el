;;; limen-term.el --- Drive an agent's terminal where Emacs holds it -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A session Emacs attached itself keeps its screen as buffer text, so the
;; draft standing in an agent's prompt can be read exactly and at once,
;; where the daemon only offers a snapshot taken some time ago.  With the
;; draft known, a message can be delivered under it: the prompt is cleared,
;; the message is pasted and submitted, and the draft is pasted back.  All
;; four reach the terminal as one ordered run of bytes from one writer, so
;; the result does not depend on when the agent reacts to any of them.
;;
;; Ghostel, vterm and eat each answer a screen and take bytes, behind the
;; three operations in `limen-term-backends'.  A session that no backend
;; here knows, or that no window shows, answers nothing, and the caller is
;; left to send the message the way it would have anyway.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(declare-function herdr-terminal-buffer "ext:herdr" (terminal-id &optional server-key))
(declare-function ghostel-force-redraw "ext:ghostel" ())
(declare-function ghostel-send-string "ext:ghostel" (string))
(declare-function ghostel-paste-string "ext:ghostel" (string))
(declare-function vterm-send-string "ext:vterm" (string &optional paste-p))
(declare-function eat-term-send-string "ext:eat" (terminal string))
(declare-function eat-term-send-string-as-yank "ext:eat" (terminal args))
(defvar eat-terminal)

(defgroup limen-term nil
  "The terminal of an agent this Emacs holds."
  :group 'limen
  :prefix "limen-term-")

(defcustom limen-term-backends
  '((ghostel-mode :screen limen-term--ghostel-screen
                  :send limen-term--ghostel-send
                  :paste limen-term--ghostel-paste)
    (vterm-mode :screen limen-term--buffer-screen
                :send limen-term--vterm-send
                :paste limen-term--vterm-paste)
    (eat-mode :screen limen-term--buffer-screen
              :send limen-term--eat-send
              :paste limen-term--eat-paste))
  "Terminal backends Limen can read and write, keyed by their major mode.
Each entry carries a `:screen' function returning the terminal's screen
text, a `:send' function writing a string as typed input, and a `:paste'
function writing one as a bracketed paste.  All three are called with the
terminal's buffer current and take no arguments beyond the string."
  :type '(alist :key-type symbol :value-type plist)
  :group 'limen-term)

(defconst limen-term--blank "[ \t\u00a0]"
  "A blank cell of a terminal screen, which a prompt pads itself with.")

(defconst limen-term--filled "[^ \t\u00a0]"
  "A cell of a terminal screen carrying something.")

(defcustom limen-term-prompt-marker
  (concat "\\`" limen-term--blank "*\\(?:❯\\|›\\|▌\\|>\\)" limen-term--blank)
  "What the beginning of an agent's input line looks like on screen.
The draft is the text after the match, together with the lines below it
up to `limen-term-prompt-rule'."
  :type 'regexp
  :group 'limen-term)

(defcustom limen-term-prompt-rule
  (concat "\\`" limen-term--blank "*[─━—_-]\\{8,\\}" limen-term--blank "*\\'")
  "What closes the box an agent's input line sits in."
  :type 'regexp
  :group 'limen-term)

(defcustom limen-term-prompt-ignore nil
  "Regexps whose match as a whole draft is the prompt's own placeholder."
  :type '(repeat regexp)
  :group 'limen-term)

(defcustom limen-term-clear-string "\C-u"
  "What is sent to empty an agent's input line."
  :type 'string
  :group 'limen-term)

(defcustom limen-term-submit-string "\r"
  "What is sent to submit an agent's input line."
  :type 'string
  :group 'limen-term)

(defun limen-term--backend (buffer)
  "Return the backend entry for BUFFER's major mode, or nil."
  (when (buffer-live-p buffer)
    (let ((mode (buffer-local-value 'major-mode buffer)))
      (cdr (seq-find (lambda (entry)
                       (provided-mode-derived-p mode (car entry)))
                     limen-term-backends)))))

(defun limen-term--call (buffer operation &rest arguments)
  "Apply BUFFER's backend OPERATION to ARGUMENTS with BUFFER current."
  (when-let* ((backend (limen-term--backend buffer))
              (function (plist-get backend operation)))
    (with-current-buffer buffer
      (apply function arguments))))

(defun limen-term--buffer-screen ()
  "Return the current buffer's text as the terminal's screen."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun limen-term--ghostel-screen ()
  "Return Ghostel's screen, repainted so pending output is on it."
  (ghostel-force-redraw)
  (limen-term--buffer-screen))

(defun limen-term--ghostel-send (string)
  "Send STRING to the Ghostel terminal as typed input."
  (ghostel-send-string string))

(defun limen-term--ghostel-paste (string)
  "Send STRING to the Ghostel terminal as a bracketed paste."
  (ghostel-paste-string string))

(defun limen-term--vterm-send (string)
  "Send STRING to the vterm terminal as typed input."
  (vterm-send-string string))

(defun limen-term--vterm-paste (string)
  "Send STRING to the vterm terminal as a bracketed paste."
  (vterm-send-string string t))

(defun limen-term--eat-send (string)
  "Send STRING to the eat terminal as typed input."
  (eat-term-send-string eat-terminal string))

(defun limen-term--eat-paste (string)
  "Send STRING to the eat terminal as a bracketed paste."
  (eat-term-send-string-as-yank eat-terminal string))

(defun limen-term-buffer (target)
  "Return the buffer holding agent TARGET's terminal, or nil.
Only a terminal one of `limen-term-backends' can drive is answered."
  (when-let* ((buffer (herdr-terminal-buffer (cdr target) (car target)))
              (backend (limen-term--backend buffer)))
    (ignore backend)
    buffer))

(defun limen-term-screen (buffer)
  "Return BUFFER's terminal screen, or nil when it cannot be trusted.
A terminal no window shows is not repainted, so its buffer may still
carry the screen from before the output that is already in."
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (limen-term--call buffer :screen)))

(defun limen-term--marker-width (line)
  "Return how far into LINE the text after the prompt marker begins."
  (and (string-match limen-term-prompt-marker line) (match-end 0)))

(defun limen-term--trim (line)
  "Return LINE without the blank cells the screen padded it out with."
  (replace-regexp-in-string (concat limen-term--blank "+\\'") "" line))

(defun limen-term--unindent (line width)
  "Return LINE without the blanks the prompt indents it by, at most WIDTH."
  (substring line (min width (or (string-match limen-term--filled line)
                                 (length line)))))

(defun limen-term-draft (screen)
  "Return the draft standing in the input line of SCREEN, or nil.
Lines below the input line belong to the draft up to the rule closing
its box.  A line that wrapped and one the agent was made to break look
alike on a screen, and both are read as a break."
  (when screen
    (let* ((lines (split-string screen "\n"))
           (index (cl-position-if #'limen-term--marker-width lines :from-end t)))
      (when index
        (let* ((rest (nthcdr index lines))
               (width (limen-term--marker-width (car rest)))
               (body (cons (substring (car rest) width)
                           (seq-take-while
                            (lambda (line)
                              (not (string-match-p limen-term-prompt-rule line)))
                            (cdr rest))))
               (draft (limen-term--trim
                       (mapconcat
                        (lambda (line)
                          (limen-term--trim (limen-term--unindent line width)))
                        body "\n"))))
          (unless (or (string-empty-p draft)
                      (seq-some (lambda (pattern) (string-match-p pattern draft))
                                limen-term-prompt-ignore))
            draft))))))

(defun limen-term-deliver (target text)
  "Send TEXT to agent TARGET under the draft its prompt holds.
Answers nil when the terminal is not one this Emacs can drive, or when
its prompt holds nothing worth keeping, leaving TEXT to be sent the way
it would have been.  The clear, the message, its submission and the
draft are written in that order by one writer."
  (when-let* ((buffer (limen-term-buffer target))
              (draft (limen-term-draft (limen-term-screen buffer))))
    (limen-term--call buffer :send limen-term-clear-string)
    (limen-term--call buffer :paste text)
    (limen-term--call buffer :send limen-term-submit-string)
    (limen-term--call buffer :paste draft)
    t))

(provide 'limen-term)
;;; limen-term.el ends here
