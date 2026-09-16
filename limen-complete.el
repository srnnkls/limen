;;; limen-complete.el --- Complete files, annotations and skills in a field -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Offers three completion sources inside a Cera field, each behind the
;; character that opens it: `@' project files, `#' scholia annotations of
;; the visible sessions, and `/' the skills of the harness the message is
;; going to.  A message written to Codex takes its skills in Codex's own
;; form, so the field rewrites the `/' into a `$' as the skill lands.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'limen)
(require 'limen-provider)

(declare-function limen-scholia-annotation-references "limen-scholia" (root))
(declare-function cera-complete-with-table "ext:cera" (bounds table))
(declare-function herdr-message--target-harness "ext:herdr-agent" (target))
(defvar herdr-message--pending)
(defvar cera-completion-function)

(defgroup limen-complete nil
  "Completion sources offered inside a Limen or Herdr field."
  :group 'limen
  :prefix "limen-complete-")

(defcustom limen-complete-file-seconds 5
  "Seconds a project's file list is reused before it is read again.
Listing a repository costs a subprocess, and a field is completed on
every keystroke."
  :type 'number
  :group 'limen-complete)

(defcustom limen-complete-sources
  '((?@ . limen-complete-files)
    (?# . limen-complete-annotations)
    (?/ . limen-complete-skills))
  "Completion sources keyed by the character that opens them.
Each function is called with the position just after that character and
the end of the field, and returns a `completion-at-point' list, or nil
to offer nothing."
  :type '(alist :key-type character :value-type function)
  :group 'limen-complete)

(defvar limen-complete--files (make-hash-table :test #'equal)
  "Cached project file lists, keyed by root, with the time they were read.")

(defvar limen-complete--skills nil
  "Skills of each provider, keyed by provider name and project root.")

(defun limen-complete--root ()
  "Return the project root the field's sources are confined to."
  (ignore-errors (limen--project-root default-directory)))

(defun limen-complete--target ()
  "Return the agent the message being written goes to, or nil."
  (and (boundp 'herdr-message--pending) (car-safe herdr-message--pending)))

(defun limen-complete--provider ()
  "Return the provider of the agent the message goes to, or nil."
  (when-let* ((target (limen-complete--target))
              ((fboundp 'herdr-message--target-harness))
              (harness (herdr-message--target-harness target)))
    (limen-provider harness)))


;;;; Sources

(defun limen-complete--project-files (root)
  "Return the files below ROOT, reusing a recent listing."
  (let ((cached (gethash root limen-complete--files)))
    (if (and cached (< (float-time (time-since (car cached)))
                       limen-complete-file-seconds))
        (cdr cached)
      (let ((files (when-let* ((project (project-current nil root)))
                     (mapcar (lambda (file) (file-relative-name file root))
                             (project-files project)))))
        (puthash root (cons (current-time) files) limen-complete--files)
        files))))

(defun limen-complete-files (begin end)
  "Complete a project file between BEGIN and END."
  (when-let* ((root (limen-complete--root))
              (files (limen-complete--project-files root)))
    (list begin end files
          :exclusive 'no :company-prefix-length 0
          :annotation-function (lambda (_file) " file"))))

(defun limen-complete-annotations (begin end)
  "Complete an annotation of a visible session between BEGIN and END."
  (when-let* (((fboundp 'limen-scholia-annotation-references))
              (root (limen-complete--root))
              (references (limen-scholia-annotation-references root)))
    (list begin end (mapcar #'car references)
          :exclusive 'no :company-prefix-length 0
          :annotation-function
          (lambda (reference)
            (when-let* ((text (cdr (assoc reference references))))
              (concat " " (car (split-string text "\n"))))))))

(defun limen-complete--skill-names (provider root)
  "Return PROVIDER's skills below ROOT, asking the harness once."
  (let ((key (cons (limen-provider-name provider) root)))
    (or (cdr (assoc key limen-complete--skills))
        (let ((skills (limen-provider-skills provider root)))
          (push (cons key skills) limen-complete--skills)
          skills))))

(defun limen-complete--skill-exit (provider position)
  "Return the function rewriting the character at POSITION for PROVIDER.
Nothing is returned for a harness that invokes a skill by the character
the field was opened with."
  (let ((reference (limen-provider-skill-call provider ""))
        (opened (char-to-string (char-after position))))
    (unless (equal reference opened)
      (lambda (_candidate status)
        (when (memq status '(finished exact))
          (save-excursion
            (goto-char position)
            (delete-char 1)
            (insert reference)))))))

(defun limen-complete-skills (begin end)
  "Complete a skill of the message's harness between BEGIN and END."
  (when-let* ((provider (limen-complete--provider))
              (skills (limen-complete--skill-names provider (limen-complete--root))))
    (append (list begin end (mapcar #'car skills)
                  :exclusive 'no :company-prefix-length 0
                  :annotation-function
                  (lambda (skill)
                    (if-let* ((description (cdr (assoc skill skills))))
                        (concat " " (car (split-string description "\\. ")))
                      (format " %s skill" (limen-provider-name provider)))))
            (when-let* ((exit (limen-complete--skill-exit provider (1- begin))))
              (list :exit-function exit)))))


;;;; Routing

(defun limen-complete--opens-source-p (position field)
  "Return non-nil when the character at POSITION opens a source in FIELD.
A source opens the field itself or follows whitespace, so an address in
a path or a word carrying the character is left alone."
  (or (= position field)
      (memq (char-before position) '(?\s ?\t ?\n))))

(defun limen-complete--trigger (field end)
  "Return the source character opening the text written up to END in FIELD.
The answer is a cons of the character and the position it sits at.  The
text written behind it is one run without whitespace: a source stops
offering once the word it opened is finished."
  (save-excursion
    (goto-char end)
    (skip-chars-backward "^ \t\n" field)
    (let ((position (point)))
      (when (and (< position end)
                 (assq (char-after position) limen-complete-sources)
                 (limen-complete--opens-source-p position field))
        (cons (char-after position) position)))))

(defun limen-complete-in-field (bounds table)
  "Complete in the Cera field spanning BOUNDS, behind a source's character.
Each source answers for the text behind its own character.  Text that
opens none completes on TABLE, which is what the field was given -- for a
Herdr message, the messages sent before it."
  (or (when-let* ((trigger (limen-complete--trigger (car bounds) (point)))
                  (source (alist-get (car trigger) limen-complete-sources)))
        (funcall source (1+ (cdr trigger)) (cdr bounds)))
      (cera-complete-with-table bounds table)))

(defun limen-complete-forget ()
  "Forget the cached project files and skills, asking for them again on demand."
  (interactive)
  (clrhash limen-complete--files)
  (setq limen-complete--skills nil))

(defun limen-complete-warm ()
  "Ask every harness for its skills now, so completing one does not wait.
A harness that answers through its own command takes about a second to
answer, which is a second the field would otherwise spend on the first
skill written in it."
  (interactive)
  (let ((root (limen-complete--root)))
    (dolist (provider (limen-providers))
      (when (limen-provider-skill-source provider)
        (limen-complete--skill-names provider root)))))

(defvar limen-complete--previous nil
  "Completion function the field had before the mode took it.")

(defvar limen-complete--warm-timer nil
  "Timer asking the harnesses for their skills once the editor falls idle.")

;;;###autoload
(define-minor-mode limen-complete-mode
  "Offer Limen's sources inside a Cera field.
`@' completes a project file, `#' an annotation of the visible scholia
sessions, and `/' a skill of the harness the message is going to, in
that harness's own form.  Skills are asked for once the editor falls
idle, so the first one written in a field does not wait for the harness
to answer."
  :global t
  :group 'limen-complete
  (require 'cera nil t)
  (cond
   (limen-complete-mode
    (limen-complete-forget)
    (setq limen-complete--warm-timer
          (run-with-idle-timer 1 nil #'limen-complete-warm))
    (when (boundp 'cera-completion-function)
      (setq limen-complete--previous cera-completion-function
            cera-completion-function #'limen-complete-in-field)))
   (t
    (when limen-complete--warm-timer
      (cancel-timer limen-complete--warm-timer)
      (setq limen-complete--warm-timer nil))
    (when (boundp 'cera-completion-function)
      (setq cera-completion-function limen-complete--previous)))))

(provide 'limen-complete)
;;; limen-complete.el ends here
