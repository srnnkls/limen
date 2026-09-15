;;; limen-trail-tests.el --- Buffer trail tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'limen)
(require 'limen-trail)

(defmacro limen-trail-tests--with-trail (&rest body)
  (declare (indent 0) (debug t))
  `(let ((limen-trail--entries nil)
         (limen-trail--timer nil)
         (limen-trail-buffer-limit 32)
         (limen-trail-point-limit 8)
         (limen-trail-point-distance 5)
         (window-selection-change-functions nil)
         (window-buffer-change-functions nil)
         (kill-buffer-hook nil))
     (unwind-protect
         (progn (limen-trail-mode 1) ,@body)
       (limen-trail-mode -1))))

(defun limen-trail-tests--operation (name interface)
  (seq-find
   (lambda (operation) (equal (alist-get 'name operation) name))
   (limen-operations (limen-make-request :interface interface))))

(defun limen-trail-tests--visit (buffer)
  (set-window-buffer (selected-window) buffer)
  (limen-trail--visit))

(defun limen-trail-tests--settle-at (buffer line)
  (with-current-buffer buffer
    (goto-char (point-min))
    (forward-line (1- line))
    (limen-trail--settle)))

(defun limen-trail-tests--make-file (root name lines)
  (let ((file (expand-file-name name root)))
    (with-temp-file file
      (dotimes (index lines)
        (insert (format "line %d\n" (1+ index)))))
    file))

(defun limen-trail-tests--lines (record)
  (mapcar (lambda (point) (alist-get 'line point))
          (append (alist-get 'points record) nil)))

(ert-deftest limen-trail-operation-is-hidden-until-the-mode-is-enabled ()
  (let ((limen-trail--entries nil)
        (limen-trail--timer nil)
        (window-selection-change-functions nil)
        (window-buffer-change-functions nil)
        (kill-buffer-hook nil)
        changes)
    (unwind-protect
        (let ((limen-operation-change-hook
               (list (lambda (action name) (push (cons action name) changes)))))
          (limen-trail-mode -1)
          (should-not (limen-trail-tests--operation "trail.list" 'mcp))
          (should-error
           (limen-call "trail.list" nil (limen-make-request :interface 'cli))
           :type 'limen-disabled-operation)
          (limen-trail-mode 1)
          (let ((operation (limen-trail-tests--operation "trail.list" 'mcp)))
            (should operation)
            (should (equal (alist-get 'effect operation) "read"))
            (should (equal (map-keys (alist-get 'properties
                                                (alist-get 'input_schema operation)))
                           '(limit))))
          (should (equal (reverse changes)
                         '((disabled . "trail.list") (enabled . "trail.list")))))
      (limen-trail-mode -1))))

(ert-deftest limen-trail-orders-visits-most-recent-first-and-bounds-entries ()
  (limen-trail-tests--with-trail
    (let* ((root (file-truename (make-temp-file "limen-trail-root" t)))
           (context (limen-make-request :interface 'cli :project-root root))
           (a (find-file-noselect (limen-trail-tests--make-file root "a.el" 3)))
           (b (find-file-noselect (limen-trail-tests--make-file root "b.el" 3)))
           (c (find-file-noselect (limen-trail-tests--make-file root "c.el" 3))))
      (unwind-protect
          (save-window-excursion
            (limen-trail-clear)
            (limen-trail-tests--visit a)
            (limen-trail-tests--visit a)
            (limen-trail-tests--visit b)
            (limen-trail-tests--visit a)
            (let ((records (append (limen-call "trail.list" nil context) nil)))
              (should (equal (mapcar (lambda (record) (alist-get 'name record))
                                     records)
                             (list (buffer-name a) (buffer-name b))))
              (should (= (alist-get 'visits (car records)) 2))
              (should (eq (alist-get 'live (car records)) t))
              (should (equal (alist-get 'file (car records))
                             (expand-file-name "a.el" root)))
              (should (stringp (alist-get 'last_visited (car records))))
              (should (equal (limen-trail-tests--lines (car records)) '(1))))
            (let ((limen-trail-buffer-limit 2))
              (limen-trail-tests--visit c)
              (should (equal (mapcar #'limen-trail-entry-name limen-trail--entries)
                             (list (buffer-name c) (buffer-name a)))))
            (should (equal (append (limen-call "trail.list" '((limit . 1)) context)
                                   nil)
                           (list (car (append (limen-call "trail.list" nil context)
                                              nil)))))
            (should-error (limen-call "trail.list" '((limit . "1")) context)
                          :type 'limen-invalid-arguments)
            (should-error (limen-call "trail.list" '((limit . -1)) context)
                          :type 'limen-invalid-arguments))
        (dolist (buffer (list a b c)) (kill-buffer buffer))
        (delete-directory root t)))))

(ert-deftest limen-trail-records-settled-points-newest-first-and-bounded ()
  (limen-trail-tests--with-trail
    (let* ((root (file-truename (make-temp-file "limen-trail-root" t)))
           (context (limen-make-request :interface 'cli :project-root root))
           (buffer (find-file-noselect
                    (limen-trail-tests--make-file root "a.el" 200)))
           (limen-trail-point-limit 3))
      (unwind-protect
          (save-window-excursion
            (limen-trail-clear)
            (limen-trail-tests--visit buffer)
            (limen-trail-tests--settle-at buffer 20)
            (should (equal (limen-trail-tests--lines
                            (aref (limen-call "trail.list" nil context) 0))
                           '(20 1)))
            (limen-trail-tests--settle-at buffer 22)
            (should (equal (limen-trail-tests--lines
                            (aref (limen-call "trail.list" nil context) 0))
                           '(22 1)))
            (limen-trail-tests--settle-at buffer 40)
            (limen-trail-tests--settle-at buffer 60)
            (let ((record (aref (limen-call "trail.list" nil context) 0)))
              (should (equal (limen-trail-tests--lines record) '(60 40 22)))
              (should (= (alist-get 'column (aref (alist-get 'points record) 0))
                         0)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (insert "inserted\n"))
            (should (equal (limen-trail-tests--lines
                            (aref (limen-call "trail.list" nil context) 0))
                           '(61 41 23)))
            (with-current-buffer buffer (set-buffer-modified-p nil)))
        (kill-buffer buffer)
        (delete-directory root t)))))

(ert-deftest limen-trail-freezes-killed-file-buffers-and-resumes-them ()
  (limen-trail-tests--with-trail
    (let* ((root (file-truename (make-temp-file "limen-trail-root" t)))
           (context (limen-make-request :interface 'cli :project-root root))
           (file (limen-trail-tests--make-file root "a.el" 30))
           (buffer (find-file-noselect file))
           (virtual (generate-new-buffer "limen-trail-virtual")))
      (unwind-protect
          (save-window-excursion
            (limen-trail-clear)
            (with-current-buffer virtual
              (setq default-directory (file-name-as-directory root)))
            (limen-trail-tests--visit virtual)
            (limen-trail-tests--visit buffer)
            (limen-trail-tests--settle-at buffer 10)
            (kill-buffer buffer)
            (kill-buffer virtual)
            (should (= (length limen-trail--entries) 1))
            (let ((record (aref (limen-call "trail.list" nil context) 0)))
              (should (eq (alist-get 'live record) :json-false))
              (should (equal (alist-get 'file record) file))
              (should (equal (alist-get 'kind record) "file"))
              (should (equal (limen-trail-tests--lines record) '(10 1))))
            (setq buffer (find-file-noselect file))
            (limen-trail-tests--visit buffer)
            (should (= (length limen-trail--entries) 1))
            (let ((record (aref (limen-call "trail.list" nil context) 0)))
              (should (eq (alist-get 'live record) t))
              (should (= (alist-get 'visits record) 2))
              (should (equal (limen-trail-tests--lines record) '(1 10 1)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p virtual) (kill-buffer virtual))
        (delete-directory root t)))))

(ert-deftest limen-trail-unconfined-discloses-entries-against-their-own-root ()
  (limen-trail-tests--with-trail
    (let* ((root (file-truename (make-temp-file "limen-trail-root" t)))
           (other (file-truename (make-temp-file "limen-trail-other" t)))
           (context (limen-make-request :interface 'cli :project-root root))
           (here (find-file-noselect
                  (limen-trail-tests--make-file root "here.el" 3)))
           (away (find-file-noselect
                  (limen-trail-tests--make-file other "away.el" 3)))
           (hidden (find-file-noselect
                    (limen-trail-tests--make-file other "secret.el" 3)))
           (limen-project-path-deny-regexps '("\\`secret")))
      (unwind-protect
          (save-window-excursion
            (limen-trail-clear)
            (dolist (buffer (list hidden away here))
              (limen-trail-tests--visit buffer))
            (should (equal (mapcar (lambda (r) (alist-get 'name r))
                                   (append (limen-call "trail.list" nil context)
                                           nil))
                           '("here.el")))
            (let ((limen-confine-to-project nil))
              (let ((records (append (limen-call "trail.list" nil context) nil)))
                (should (equal (mapcar (lambda (r) (alist-get 'name r)) records)
                               '("here.el" "away.el")))
                (should (equal (alist-get 'project (car records))
                               (limen--project-root root)))
                (should (equal (alist-get 'project (cadr records))
                               (limen--project-root other)))
                (should (equal (limen-trail-tests--lines (cadr records)) '(1))))))
        (dolist (buffer (list here away hidden))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (delete-directory root t)
        (delete-directory other t)))))

(ert-deftest limen-trail-keeps-points-of-redrawn-buffers-without-a-file ()
  (limen-trail-tests--with-trail
    (let* ((root (file-truename (make-temp-file "limen-trail-root" t)))
           (context (limen-make-request :interface 'cli :project-root root))
           (terminal (generate-new-buffer "limen-trail-terminal"))
           (limen-readable-virtual-buffer-condition t))
      (unwind-protect
          (save-window-excursion
            (limen-trail-clear)
            (with-current-buffer terminal
              (setq default-directory (file-name-as-directory root))
              (dotimes (index 200) (insert (format "line %d\n" (1+ index))))
              (goto-char (point-min)))
            (limen-trail-tests--visit terminal)
            (limen-trail-tests--settle-at terminal 20)
            (limen-trail-tests--settle-at terminal 60)
            (limen-trail-tests--settle-at terminal 62)
            (should (equal (limen-trail-tests--lines
                            (aref (limen-call "trail.list" nil context) 0))
                           '(62 20 1)))
            (with-current-buffer terminal
              (erase-buffer)
              (insert "redrawn\n"))
            (should (equal (limen-trail-tests--lines
                            (aref (limen-call "trail.list" nil context) 0))
                           '(62 20 1))))
        (when (buffer-live-p terminal) (kill-buffer terminal))
        (delete-directory root t)))))

(ert-deftest limen-trail-applies-disclosure-policy-and-ignores-internal-buffers ()
  (limen-trail-tests--with-trail
    (let* ((root (file-truename (make-temp-file "limen-trail-root" t)))
           (outside-root (file-truename (make-temp-file "limen-trail-outside" t)))
           (context (limen-make-request :interface 'cli :project-root root))
           (inside (find-file-noselect
                    (limen-trail-tests--make-file root "inside.el" 3)))
           (denied (find-file-noselect
                    (limen-trail-tests--make-file root "secret.el" 3)))
           (outside (find-file-noselect
                     (limen-trail-tests--make-file outside-root "outside.el" 3)))
           (virtual (generate-new-buffer "limen-trail-virtual"))
           (internal (generate-new-buffer " limen-trail-internal"))
           (limen-project-path-deny-regexps '("\\`secret")))
      (unwind-protect
          (save-window-excursion
            (limen-trail-clear)
            (dolist (buffer (list virtual internal))
              (with-current-buffer buffer
                (setq default-directory (file-name-as-directory root))))
            (dolist (buffer (list outside denied virtual internal inside))
              (limen-trail-tests--visit buffer))
            (should-not (seq-find (lambda (entry)
                                    (eq (limen-trail-entry-buffer entry) internal))
                                  limen-trail--entries))
            (let ((records (append (limen-call "trail.list" nil context) nil)))
              (should (equal (mapcar (lambda (record) (alist-get 'name record))
                                     records)
                             (list (buffer-name inside) (buffer-name virtual))))
              (let ((redacted (cadr records)))
                (should (eq (alist-get 'redacted redacted) t))
                (should-not (assq 'points redacted))
                (should-not (assq 'narrowing redacted))
                (should (= (alist-get 'visits redacted) 1))))
            (let ((limen-readable-virtual-buffer-condition t))
              (let ((record (cadr (append (limen-call "trail.list" nil context)
                                          nil))))
                (should-not (assq 'redacted record))
                (should (equal (limen-trail-tests--lines record) '(1)))))
            (kill-buffer outside)
            (kill-buffer denied)
            (should (= (length (limen-call "trail.list" nil context)) 2))
            (limen-trail-mode -1)
            (should-not limen-trail--entries))
        (dolist (buffer (list inside denied outside virtual internal))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (delete-directory root t)
        (delete-directory outside-root t)))))

(ert-deftest limen-trail-contributes-a-context-section-only-while-enabled ()
  (let* ((root (file-truename (make-temp-file "limen-trail-root" t)))
         (context (limen-make-request :interface 'cli :project-root root
                                      :frame (selected-frame)
                                      :window (selected-window)))
         (buffer (find-file-noselect (limen-trail-tests--make-file root "a.el" 3))))
    (unwind-protect
        (save-window-excursion
          (limen-trail-tests--with-trail
            (limen-trail-mode -1)
            (should-not (assq 'trail (limen-call "context.get" nil context)))
            (limen-trail-mode 1)
            (limen-trail-tests--visit buffer)
            (should (equal (alist-get 'trail (limen-call "context.get" nil context))
                           (limen-call "trail.list" nil context)))
            (should (equal (map-keys (limen-call "context.get"
                                                 '((sections . ["trail"]))
                                                 context))
                           '(trail)))))
      (kill-buffer buffer)
      (delete-directory root t))))

(provide 'limen-trail-tests)
;;; limen-trail-tests.el ends here
