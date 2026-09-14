;;; limen-scholia-tests.el --- Limen and scholia bridge tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'scholia)
(require 'scholia-test-helper)
(require 'limen-scholia)

(defmacro limen-scholia-tests--with-project (root &rest body)
  "Run BODY with ROOT bound to a fresh project directory and session store."
  (declare (indent 1) (debug (symbolp body)))
  `(scholia-test-with-session-directory
     (let ((,root (file-truename (make-temp-file "limen-scholia-root" t)))
           (scholia-visible-sessions nil)
           (scholia-project-sessions nil)
           (limen-project-path-deny-regexps nil))
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (string-prefix-p ,root (buffer-file-name buffer)))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
         (delete-directory ,root t)))))

(defun limen-scholia-tests--annotate (file session beg end text)
  "Annotate BEG to END of FILE with TEXT in SESSION and return the buffer."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (setq-local scholia-session session)
      (scholia-mode 1)
      (scholia-create-chain beg end text)
      (scholia-core--store (scholia-core--buffer-annotations session) session))
    buffer))

(defun limen-scholia-tests--write (file content)
  (with-temp-file file (insert content))
  file)

(defun limen-scholia-tests--context (root)
  (limen-make-request :interface 'cli :project-root root
                      :frame (selected-frame) :window (selected-window)))

(defun limen-scholia-tests--names (records)
  (mapcar (lambda (record) (alist-get 'name record)) (append records nil)))

(ert-deftest limen-scholia-sessions-report-active-target-and-confined-file-counts ()
  (limen-scholia-tests--with-project root
    (let* ((outside (file-truename (make-temp-file "limen-scholia-outside" t)))
           (inside (limen-scholia-tests--write
                    (expand-file-name "inside.el" root) "alpha\nbeta\n"))
           (away (limen-scholia-tests--write
                  (expand-file-name "away.el" outside) "gamma\n"))
           (context (limen-scholia-tests--context root)))
      (unwind-protect
          (progn
            (limen-scholia-tests--annotate inside "review" 1 6 "check")
            (limen-scholia-tests--annotate away "review" 1 6 "far")
            (limen-scholia-tests--annotate inside "perf" 7 11 "slow")
            (let ((scholia-visible-sessions '("perf"))
                  (scholia-project-sessions (list (cons root "review"))))
              (let* ((records (limen-call "annotation.sessions" nil context))
                     (review (seq-find (lambda (r) (equal (alist-get 'name r) "review"))
                                       records))
                     (perf (seq-find (lambda (r) (equal (alist-get 'name r) "perf"))
                                     records)))
                (should (equal (sort (limen-scholia-tests--names records) #'string<)
                               '("perf" "review")))
                (should (eq (alist-get 'active review) :json-false))
                (should (eq (alist-get 'target review) t))
                (should (= (alist-get 'files review) 1))
                (should (eq (alist-get 'active perf) t))
                (should (eq (alist-get 'target perf) :json-false))
                (should (= (alist-get 'files perf) 1)))))
        (when-let* ((buffer (get-file-buffer away)))
          (set-buffer-modified-p nil)
          (kill-buffer buffer))
        (delete-directory outside t)))))

(ert-deftest limen-scholia-list-confines-files-and-caps-with-limit ()
  (limen-scholia-tests--with-project root
    (let* ((outside (file-truename (make-temp-file "limen-scholia-outside" t)))
           (inside (limen-scholia-tests--write
                    (expand-file-name "inside.el" root) "alpha\nbeta\n"))
           (away (limen-scholia-tests--write
                  (expand-file-name "away.el" outside) "gamma\n"))
           (context (limen-scholia-tests--context root)))
      (unwind-protect
          (progn
            (limen-scholia-tests--annotate inside "review" 1 6 "check")
            (limen-scholia-tests--annotate inside "review" 7 11 "again")
            (limen-scholia-tests--annotate away "review" 1 6 "far")
            (let* ((records (append (limen-call "annotation.list"
                                                '((session . "review")) context)
                                    nil)))
              (should (= (length records) 2))
              (should (seq-every-p (lambda (r) (equal (alist-get 'file r) inside))
                                   records))
              (should (equal (mapcar (lambda (r) (alist-get 'text r)) records)
                             '("check" "again")))
              (should (= (alist-get 'line (car records)) 1))
              (should (equal (alist-get 'annotated_text (car records)) "alpha"))
              (should (equal (alist-get 'session (car records)) "review")))
            (should (= (length (limen-call "annotation.list"
                                           '((session . "review") (limit . 1))
                                           context))
                       1))
            (should (= (length (limen-call "annotation.list"
                                           '((session . "review") (path . "inside.el"))
                                           context))
                       2))
            (let ((scholia-visible-sessions '("review")))
              (should (= (length (limen-call "annotation.list" nil context)) 2)))
            (should (= (length (limen-call "annotation.list" nil context)) 0))
            (should-error (limen-call "annotation.list" '((session . "missing"))
                                      context)
                          :type 'limen-invalid-arguments)
            (should-error (limen-call "annotation.list"
                                      `((session . "review") (path . ,away))
                                      context)
                          :type 'limen-operation-failed))
        (when-let* ((buffer (get-file-buffer away)))
          (set-buffer-modified-p nil)
          (kill-buffer buffer))
        (delete-directory outside t)))))

(ert-deftest limen-scholia-export-renders-rustc-for-a-file-and-a-session ()
  (limen-scholia-tests--with-project root
    (let* ((first (limen-scholia-tests--write
                   (expand-file-name "first.el" root) "alpha\nbeta\n"))
           (second (limen-scholia-tests--write
                    (expand-file-name "second.el" root) "gamma\n"))
           (context (limen-scholia-tests--context root)))
      (limen-scholia-tests--annotate first "review" 7 11 "check")
      (limen-scholia-tests--annotate second "review" 1 6 "again")
      (let ((one (limen-call "annotation.export"
                             '((session . "review") (path . "first.el")) context))
            (all (limen-call "annotation.export" '((session . "review")) context)))
        (should (stringp one))
        (should (string-match-p (concat "--> " (regexp-quote first) ":2:1 \\[") one))
        (should (string-match-p "\\^\\^\\^\\^ check" one))
        (should-not (string-match-p "again" one))
        (should (string-match-p "check" all))
        (should (string-match-p "again" all)))
      (should (string-match-p
               "check"
               (limen-call "annotation.export"
                           '((session . "review") (format . "integrate")) context)))
      (should-error (limen-call "annotation.export"
                                '((session . "review") (format . "bogus")) context)
                    :type 'limen-invalid-arguments)
      (should-error (limen-call "annotation.export" '((session . "missing")) context)
                    :type 'limen-invalid-arguments))))

(ert-deftest limen-scholia-context-field-names-visible-sessions-with-counts ()
  (limen-scholia-tests--with-project root
    (let* ((file (limen-scholia-tests--write
                  (expand-file-name "noted.el" root) "alpha\nbeta\n"))
           (context (limen-scholia-tests--context root))
           (buffer (limen-scholia-tests--annotate file "review" 1 6 "check")))
      (with-current-buffer buffer
        (should (equal (limen-scholia--context-field nil root)
                       '("annotations: review (1) — `limen annotations list`")))
        (let ((scholia-visible-sessions '("review")))
          (limen-scholia-tests--annotate
           (limen-scholia-tests--write (expand-file-name "other.el" root) "x\n")
           "perf" 1 2 "slow")
          (let ((scholia-visible-sessions '("review" "perf")))
            (should (equal (limen-scholia--context-field nil root)
                           '("annotations: review (1), perf — `limen annotations list`")))
            (should (equal (limen-scholia-tests--names
                            (alist-get 'sessions
                                       (alist-get 'annotations
                                                  (limen-call "context.get" nil context))))
                           '("review" "perf"))))))
      (with-temp-buffer
        (setq default-directory root)
        (should-not (limen-scholia--context-field nil root))
        (should-not (assq 'annotations (limen-call "context.get" nil context)))))))

(provide 'limen-scholia-tests)
;;; limen-scholia-tests.el ends here
