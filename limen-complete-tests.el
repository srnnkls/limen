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
      (should (equal (limen-complete-tests--capf) '(files 1 5))))
    (limen-complete-tests--in-field "look at @lim"
      (should (equal (limen-complete-tests--capf) '(files 9 13))))
    (limen-complete-tests--in-field "see #anno"
      (should (equal (limen-complete-tests--capf) '(notes 5 10))))
    (limen-complete-tests--in-field "@"
      (should (equal (limen-complete-tests--capf) '(files 1 2))))
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
          (should (equal (seq-take capf 3) '(1 4 ("@limen.el" "@bin/limen"))))
          (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function)
                                  "@limen.el")
                         " file")))))
    (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) root))
              ((symbol-function 'project-files)
               (lambda (_project) (ert-fail "A recent listing is reused"))))
      (limen-complete-tests--in-field "@li"
        (should (limen-complete-tests--capf))))))

(defmacro limen-complete-tests--with-tree (&rest body)
  "Run BODY with `root' bound to a fresh directory holding a small tree.
The tree is a file `here.txt' and a directory `sub' holding `deep.txt',
inside a parent directory holding `above.txt' beside it."
  (declare (indent 0) (debug t))
  `(let* ((parent (make-temp-file "limen-complete-" t))
          (root (file-name-as-directory (expand-file-name "tree" parent))))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "sub" root) t)
           (dolist (file '("../above.txt" "here.txt" "sub/deep.txt"))
             (with-temp-file (expand-file-name file root) (insert "x")))
           ,@body)
       (delete-directory parent t))))

(defun limen-complete-tests--all (capf)
  "Return every candidate CAPF offers for the text between its bounds."
  (sort (all-completions (buffer-substring (nth 0 capf) (nth 1 capf))
                         (nth 2 capf))
        #'string<))

(ert-deftest limen-complete-completes-a-written-path-against-the-file-system ()
  "A path from a directory is read from the file system, from the root.
Reading the project is not needed for it, and `..' climbs out of the
root the way it would in a shell."
  (clrhash limen-complete--files)
  (limen-complete-tests--with-tree
    (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) root))
              ((symbol-function 'project-files)
               (lambda (_project) (ert-fail "A written path leaves the project"))))
      (dolist (text '("@../other/file" "@./here" "@/etc/hosts" "@~/notes"))
        (limen-complete-tests--in-field text
          (let ((capf (limen-complete-tests--capf)))
            (should (equal (seq-take capf 2) (list 2 (point-max))))
            (should (functionp (nth 2 capf)))
            (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function)
                                    "file")
                           " path")))))
      (limen-complete-tests--in-field "@./"
        (should (equal (limen-complete-tests--all (limen-complete-tests--capf))
                       '("../" "./" "here.txt" "sub/"))))
      (limen-complete-tests--in-field "@../"
        (should (member "above.txt"
                        (limen-complete-tests--all (limen-complete-tests--capf)))))
      (limen-complete-tests--in-field "@../.."
        (should (equal (limen-complete-tests--all (limen-complete-tests--capf))
                       '("../")))))))

(ert-deftest limen-complete-offers-the-file-system-outside-a-project ()
  "Without a project a name completes from the field's directory, stepwise."
  (clrhash limen-complete--files)
  (limen-complete-tests--with-tree
    (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) root))
              ((symbol-function 'project-current) (lambda (&rest _) nil)))
      (limen-complete-tests--in-field "@h"
        (let ((capf (limen-complete-tests--capf)))
          (should (equal (seq-take capf 2) (list 2 (point-max))))
          (should (equal (limen-complete-tests--all capf) '("here.txt")))
          (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function)
                                  "here.txt")
                         " path"))))
      (limen-complete-tests--in-field "@sub/"
        (should (equal (limen-complete-tests--all (limen-complete-tests--capf))
                       '("../" "./" "deep.txt")))))))

(ert-deftest limen-complete-offers-annotations-of-the-visible-sessions ()
  (clrhash limen-complete--files)
  (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) "/tmp/p/"))
            ((symbol-function 'limen-scholia-annotation-references)
             (lambda (_root) '(("limen.el:12" . "needs a test\nsecond line")))))
    (limen-complete-tests--in-field "#lim"
      (let ((capf (limen-complete-tests--capf)))
        (should (equal (seq-take capf 3) '(1 5 ("#limen.el:12"))))
        (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function)
                                "#limen.el:12")
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
               (lambda (_provider _root)
                 '(("git" . "Modern git workflows. Use when branching.")
                   ("review" . nil)))))
      (limen-complete-tests--in-field "/re"
        (let ((capf (limen-complete-tests--capf)))
          (should (equal (seq-take capf 3) '(1 4 ("/git" "/review"))))
          (should-not (plist-get (nthcdr 3 capf) :exit-function))
          (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function) "/git")
                         " Modern git workflows"))
          (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function) "/review")
                         " claude skill")))))
    (setq limen-complete--skills nil)
    (cl-letf (((symbol-function 'limen--project-root) (lambda (_directory) "/tmp/p/"))
              ((symbol-function 'herdr-message--target-harness) (lambda (_target) "codex"))
              ((symbol-function 'limen-provider-skills)
               (lambda (_provider _root) '(("bash" . "Bash patterns")))))
      (limen-complete-tests--in-field "/ba"
        (let ((exit (plist-get (nthcdr 3 (limen-complete-tests--capf)) :exit-function)))
          (should exit)
          (goto-char (point-max))
          (insert "sh")
          (funcall exit "/bash" 'finished)
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
          (make-directory (expand-file-name ".claude/skills/git" home) t)
          (with-temp-file (expand-file-name ".claude/skills/git/SKILL.md" home)
            (insert "---\nname: git\ndescription: Personal git\n---\n"))
          (make-directory (expand-file-name ".claude/skills/review" home) t)
          (with-temp-file (expand-file-name ".claude/skills/review/SKILL.md" home)
            (insert "# review\n"))
          (make-directory (expand-file-name ".claude/skills/draft" home) t)
          (make-directory (expand-file-name ".claude/skills/git" root) t)
          (with-temp-file (expand-file-name ".claude/skills/git/SKILL.md" root)
            (insert "---\ndescription: The project's own\n---\n"))
          (make-directory (expand-file-name ".claude/skills/deploy" root) t)
          (with-temp-file (expand-file-name ".claude/skills/deploy/SKILL.md" root)
            (insert "---\ndescription: \"Ship it\"\n---\n"))
          (let ((provider (limen-provider--make
                           :name 'claude
                           :skill-source
                           (lambda (project)
                             (limen-provider--directory-skills configuration project))
                           :skill-reference (lambda (skill) (concat "/" skill)))))
            (should (equal (limen-provider-skills provider root)
                           '(("deploy" . "Ship it")
                             ("git" . "The project's own")
                             ("review" . nil))))
            (should (equal (limen-provider-skills provider nil)
                           '(("git" . "Personal git") ("review" . nil))))
            (should (equal (limen-provider-skill-call provider "git") "/git"))))
      (delete-directory home t))))

(ert-deftest limen-complete-reads-the-skills-codex-lists-for-itself ()
  (let ((dump (json-serialize
               (vector
                `((type . "message") (role . "developer")
                  (content . [((type . "input_text")
                               (text . ,(string-join
                                         '("<skills_instructions>"
                                           "### Skill roots"
                                           "- `r0` = `/home/.codex/skills`"
                                           "### Available skills"
                                           "- bash: Ultra-concise bash patterns. (file: r0/bash/SKILL.md)"
                                           "- git: Modern git workflows (file: r0/git/SKILL.md)"
                                           "</skills_instructions>")
                                         "\n")))]))))))
    (cl-letf (((symbol-function 'call-process)
               (lambda (program _infile _buffer _display &rest arguments)
                 (should (equal program "codex"))
                 (should (equal arguments '("debug" "prompt-input")))
                 (insert dump)
                 0)))
      (should (equal (limen-provider--codex-skills nil)
                     '(("bash" . "Ultra-concise bash patterns.")
                       ("git" . "Modern git workflows")))))
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 1)))
      (should-not (limen-provider--codex-skills nil)))))

(ert-deftest limen-complete-mode-takes-and-gives-back-the-field-completion ()
  (cl-progv '(cera-completion-function) '(original)
    (cl-letf (((symbol-function 'limen-complete-warm) #'ignore))
      (limen-complete-mode 1))
    (should (eq (symbol-value 'cera-completion-function) #'limen-complete-in-field))
    (limen-complete-mode -1)
    (should (eq (symbol-value 'cera-completion-function) 'original))))

(provide 'limen-complete-tests)
;;; limen-complete-tests.el ends here
