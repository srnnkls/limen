;;; limen-complete-tests.el --- Field completion tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-complete)

(defvar herdr-message--pending)

(defmacro limen-complete-tests--in-field (text &rest body)
  "Run BODY in a buffer holding TEXT as the whole of a field."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (let ((bounds (cons (point-min) (point-max))))
       (ignore bounds)
       ,@body)))

(defun limen-complete-tests--capf (&optional bounds)
  "Return what the field offers at point, with BOUNDS or the whole buffer.
Text that opens no source answers `fallback', standing in for the
field's own table."
  (cl-letf (((symbol-function 'cera-complete-with-table)
             (lambda (_bounds _table) 'fallback)))
    (limen-complete-in-field (or bounds (cons (point-min) (point-max))) nil)))

(ert-deftest limen-complete-routes-on-the-character-opening-the-word ()
  (let ((limen-complete-sources '((?@ . (lambda (begin end) (list 'files begin end)))
                                  (?# . (lambda (begin end) (list 'notes begin end))))))
    (limen-complete-tests--in-field "@lim"
      (should (equal (limen-complete-tests--capf) '(files 2 5))))
    (limen-complete-tests--in-field "look at @lim"
      (should (equal (limen-complete-tests--capf) '(files 10 13))))
    (limen-complete-tests--in-field "see #anno"
      (should (equal (limen-complete-tests--capf) '(notes 6 10))))
    (limen-complete-tests--in-field "@"
      (should (equal (limen-complete-tests--capf) '(files 2 2))))
    (cl-letf (((symbol-function 'cera-complete-with-table)
               (lambda (_bounds table) (list 'history table))))
      (dolist (text '("mail@example" "@done " "plain"))
        (limen-complete-tests--in-field text
          (should (equal (limen-complete-in-field (cons (point-min) (point-max))
                                                  '("earlier"))
                         '(history ("earlier")))))))))

(ert-deftest limen-complete-offers-project-files-relative-to-the-root ()
  (let ((root "/tmp/project/"))
    (clrhash limen-complete--files)
    (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) root))
              ((symbol-function 'project-current) (lambda (&rest _) 'project))
              ((symbol-function 'project-files)
               (lambda (_project) '("/tmp/project/limen.el" "/tmp/project/bin/limen"))))
      (limen-complete-tests--in-field "@li"
        (let ((capf (limen-complete-tests--capf)))
          (should (equal (seq-take capf 3) '(2 4 ("limen.el" "bin/limen"))))
          (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function)
                                  "limen.el")
                         " file")))))
    (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) root))
              ((symbol-function 'project-files)
               (lambda (_project) (ert-fail "A recent listing is reused"))))
      (limen-complete-tests--in-field "@li"
        (should (limen-complete-tests--capf))))))

(ert-deftest limen-complete-offers-annotations-of-the-visible-sessions ()
  (clrhash limen-complete--files)
  (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) "/tmp/p/"))
            ((symbol-function 'limen-scholia-annotation-references)
             (lambda (_root) '(("limen.el:12" . "needs a test\nsecond line")))))
    (limen-complete-tests--in-field "#lim"
      (let ((capf (limen-complete-tests--capf)))
        (should (equal (seq-take capf 3) '(2 5 ("limen.el:12"))))
        (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function)
                                "limen.el:12")
                       " needs a test")))))
  (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) "/tmp/p/"))
            ((symbol-function 'limen-scholia-annotation-references)
             (lambda (_root) nil)))
    (limen-complete-tests--in-field "#lim"
      (should (eq (limen-complete-tests--capf) 'fallback)))))

(ert-deftest limen-complete-offers-the-skills-of-the-harness-written-to ()
  (let ((herdr-message--pending '(("/servers/a.sock" . "shared") . "ctx"))
        (limen-complete--skills nil))
    (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) "/tmp/p/"))
              ((symbol-function 'herdr-message--target-harness) (lambda (_target) "claude"))
              ((symbol-function 'limen-provider-skills)
               (lambda (_provider _root) '("git" "review"))))
      (limen-complete-tests--in-field "/re"
        (let ((capf (limen-complete-tests--capf)))
          (should (equal (seq-take capf 3) '(2 4 ("git" "review"))))
          (should-not (plist-get (nthcdr 3 capf) :exit-function))
          (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function) "git")
                         " claude skill")))))
    (setq limen-complete--skills nil)
    (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) "/tmp/p/"))
              ((symbol-function 'herdr-message--target-harness) (lambda (_target) "codex"))
              ((symbol-function 'limen-provider-skills)
               (lambda (_provider _root) '("bash"))))
      (limen-complete-tests--in-field "/ba"
        (let ((exit (plist-get (nthcdr 3 (limen-complete-tests--capf)) :exit-function)))
          (should exit)
          (goto-char (point-max))
          (insert "sh")
          (funcall exit "bash" 'finished)
          (should (equal (buffer-string) "$bash")))))))

(ert-deftest limen-complete-offers-no-skills-without-an-agent-to-send-to ()
  (let ((herdr-message--pending nil))
    (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) "/tmp/p/")))
      (limen-complete-tests--in-field "/re"
        (should (eq (limen-complete-tests--capf) 'fallback))))))

(ert-deftest limen-complete-reads-skills-as-directories-holding-a-skill-file ()
  (let ((home (make-temp-file "limen-skills" t)))
    (unwind-protect
        (let ((root (expand-file-name "project" home))
              (configuration (expand-file-name ".claude" home)))
          (dolist (skill '("git" "review"))
            (make-directory (expand-file-name (format ".claude/skills/%s" skill) home) t)
            (with-temp-file (expand-file-name
                             (format ".claude/skills/%s/SKILL.md" skill) home)
              (insert "skill")))
          (make-directory (expand-file-name ".claude/skills/draft" home) t)
          (make-directory (expand-file-name ".claude/skills/git" root) t)
          (with-temp-file (expand-file-name ".claude/skills/git/SKILL.md" root)
            (insert "skill"))
          (make-directory (expand-file-name ".claude/skills/deploy" root) t)
          (with-temp-file (expand-file-name ".claude/skills/deploy/SKILL.md" root)
            (insert "skill"))
          (let ((provider (limen-provider--make
                           :name 'claude
                           :skill-directories
                           (lambda (project)
                             (limen-provider--skill-directories configuration project))
                           :skill-reference (lambda (skill) (concat "/" skill)))))
            (should (equal (limen-provider-skills provider root)
                           '("deploy" "git" "review")))
            (should (equal (limen-provider-skills provider nil) '("git" "review")))
            (should (equal (limen-provider-skill-call provider "git") "/git"))))
      (delete-directory home t))))

(ert-deftest limen-complete-mode-takes-and-gives-back-the-field-completion ()
  (cl-progv '(cera-completion-function) '(original)
    (limen-complete-mode 1)
    (should (eq (symbol-value 'cera-completion-function) #'limen-complete-in-field))
    (limen-complete-mode -1)
    (should (eq (symbol-value 'cera-completion-function) 'original))))

(provide 'limen-complete-tests)
;;; limen-complete-tests.el ends here
