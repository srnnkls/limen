;;; limen-compile-tests.el --- Compilation observer tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'compile)
(require 'ert)
(require 'limen)

(defconst limen-compile-tests--feature-available
  (require 'limen-compile nil t))

(define-derived-mode limen-compile-tests-mode compilation-mode
  "Limen Compile Test")

(defun limen-compile-tests--require-feature ()
  (should limen-compile-tests--feature-available))

(defun limen-compile-tests--operation (name interface)
  (seq-find
   (lambda (operation) (equal (alist-get 'name operation) name))
   (limen-operations (limen-make-request :interface interface))))

(defun limen-compile-tests--make-buffer (name directory &optional mode)
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (setq default-directory (file-name-as-directory directory))
      (funcall (or mode #'limen-compile-tests-mode)))
    buffer))

(defun limen-compile-tests--record (name context)
  (seq-find
   (lambda (record) (equal (alist-get 'name record) name))
   (append (limen-call "compile.list" nil context) nil)))

(defconst limen-compile-tests--process-action-functions
  '(compile compilation-start start-process make-process call-process
    process-file accept-process-output process-send-string process-send-region
    process-send-eof))

(defun limen-compile-tests--prepare-function-stubs (functions)
  (when (and (fboundp 'native-comp-available-p)
             (native-comp-available-p)
             (fboundp 'comp-subr-trampoline-install))
    (dolist (function functions)
      (when (subr-primitive-p (symbol-function function))
        (comp-subr-trampoline-install function)))))

(defmacro limen-compile-tests--without-process-actions (&rest body)
  (declare (indent 0) (debug t))
  `(progn
     (limen-compile-tests--prepare-function-stubs
      limen-compile-tests--process-action-functions)
     (cl-letf (((symbol-function 'compile)
                (lambda (&rest _) (ert-fail "compile executed")))
               ((symbol-function 'compilation-start)
                (lambda (&rest _) (ert-fail "compilation started")))
               ((symbol-function 'start-process)
                (lambda (&rest _) (ert-fail "process started")))
               ((symbol-function 'make-process)
                (lambda (&rest _) (ert-fail "process created")))
               ((symbol-function 'call-process)
                (lambda (&rest _) (ert-fail "process called")))
               ((symbol-function 'process-file)
                (lambda (&rest _) (ert-fail "process file executed")))
               ((symbol-function 'accept-process-output)
                (lambda (&rest _) (ert-fail "process waited for")))
               ((symbol-function 'process-send-string)
                (lambda (&rest _) (ert-fail "process input sent")))
               ((symbol-function 'process-send-region)
                (lambda (&rest _) (ert-fail "buffer input sent")))
               ((symbol-function 'process-send-eof)
                (lambda (&rest _) (ert-fail "process EOF sent"))))
       ,@body)))

(ert-deftest limen-compile-registers-only-read-observer-operations ()
  (limen-compile-tests--require-feature)
  (let ((cli-list (limen-compile-tests--operation "compile.list" 'cli))
        (cli-read (limen-compile-tests--operation "compile.read" 'cli)))
    (dolist (operation (list cli-list cli-read))
      (should (equal (alist-get 'effect operation) "read")))
    (dolist (name '("compile.list" "compile.read"))
      (should (limen-compile-tests--operation name 'mcp))
      (should-not (limen-compile-tests--operation name 'adapter)))
    (let ((list-schema (alist-get 'input_schema cli-list))
          (read-schema (alist-get 'input_schema cli-read)))
      (should (equal (alist-get 'required list-schema) []))
      (should (equal (alist-get 'required read-schema) ["name"]))
      (should (equal (alist-get 'type
                                (alist-get 'name
                                           (alist-get 'properties read-schema)))
                     "string")))
    (dolist (name '("compile.run" "test.run"))
      (should-not (gethash name limen--operations)))))

(ert-deftest limen-compile-list-confines-records-and-distinguishes-statuses ()
  (limen-compile-tests--require-feature)
  (let ((root (file-truename (make-temp-file "limen-compile-root" t)))
        (outside-root (file-truename
                       (make-temp-file "limen-compile-outside" t)))
        inside running running-process outside wrong-mode)
    (unwind-protect
        (progn
          (limen-compile-tests--prepare-function-stubs
           '(get-buffer-process process-status process-exit-status))
          (setq inside
                (limen-compile-tests--make-buffer
                 "*limen compile inside*" root)
                running (generate-new-buffer "*limen compile running*")
                outside
                (limen-compile-tests--make-buffer
                 "*limen compile outside*" outside-root)
                wrong-mode
                (limen-compile-tests--make-buffer
                 "*limen compile wrong mode*" root #'fundamental-mode))
          (with-current-buffer running
            (setq default-directory (file-name-as-directory root)))
          (setq running-process
                (make-pipe-process
                 :name "limen-compile-running"
                 :buffer running
                 :noquery t))
          (with-current-buffer running
            (limen-compile-tests-mode))
          (with-current-buffer inside
            (setq-local compilation-num-errors-found 2)
            (setq-local compilation-num-warnings-found 3)
            (setq-local compilation-num-infos-found 4)
            (should (local-variable-p 'compilation-start-hook))
            (should (local-variable-p 'compilation-finish-functions)))
          (let* ((context (limen-make-request :interface 'cli
                                              :project-root root))
                 (records
                  (limen-compile-tests--without-process-actions
                    (append (limen-call "compile.list" nil context) nil)))
                 (record (seq-find
                          (lambda (entry)
                            (equal (alist-get 'name entry)
                                   (buffer-name inside)))
                          records))
                 (statuses
                  `((completed-before-observation
                     ,(alist-get 'status record)
                     ,(alist-get 'process_status record)
                     ,(alist-get 'exit_code record))
                    (already-running
                     ,(alist-get
                       'status
                       (limen-compile-tests--record
                        (buffer-name running) context))
                     nil nil))))
            (should record)
            (should-not (seq-find
                         (lambda (entry)
                           (member (alist-get 'name entry)
                                   (list (buffer-name outside)
                                         (buffer-name wrong-mode))))
                         records))
            (should (equal (alist-get 'directory record)
                           (file-name-as-directory root)))
            (should (= (alist-get 'errors record) 2))
            (should (= (alist-get 'warnings record) 3))
            (should (= (alist-get 'infos record) 4))
            (dolist (secret '(command command_line environment process_environment))
              (should-not (assq secret record)))
            (dolist (case '((successful-exit exit 0)
                            (nonzero-failure exit 7)
                            (signal-stopped signal 15)))
              (pcase-let ((`(,scenario ,process-status ,exit-code) case))
                (with-current-buffer inside
                  (run-hook-with-args 'compilation-start-hook running-process))
                (cl-letf (((symbol-function 'get-buffer-process)
                           (lambda (_buffer) running-process))
                          ((symbol-function 'process-status)
                           (lambda (_process) process-status))
                          ((symbol-function 'process-exit-status)
                           (lambda (_process) exit-code)))
                  (with-current-buffer inside
                    (run-hook-with-args 'compilation-finish-functions
                                        inside "completed")))
                (let ((terminal
                       (limen-compile-tests--record
                        (buffer-name inside) context)))
                  (setq statuses
                        (append statuses
                                `((,scenario
                                   ,(alist-get 'status terminal)
                                   ,(alist-get 'process_status terminal)
                                   ,(alist-get 'exit_code terminal))))))))
            (should
             (equal statuses
                    '((completed-before-observation "unknown" nil nil)
                      (already-running "running" nil nil)
                      (successful-exit "succeeded" "exit" 0)
                      (nonzero-failure "failed" "exit" 7)
                      (signal-stopped "stopped" "signal" 15))))))
      (when (processp running-process)
        (delete-process running-process))
      (dolist (buffer (list inside running outside wrong-mode))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest limen-compile-read-returns-bounded-output-without-annotations-or-state-changes ()
  (limen-compile-tests--require-feature)
  (let ((root (file-truename (make-temp-file "limen-compile-read-root" t)))
        (outside-root (file-truename
                       (make-temp-file "limen-compile-read-outside" t)))
        inside outside wrong-mode state full-text expected-tail buffer-contents
        annotation sentinel-secret)
    (unwind-protect
        (progn
          (setq inside
                (limen-compile-tests--make-buffer
                 "*limen compile read inside*" root)
                outside
                (limen-compile-tests--make-buffer
                 "*limen compile read outside*" outside-root)
                wrong-mode
                (limen-compile-tests--make-buffer
                 "*limen compile read wrong mode*" root #'fundamental-mode)
                expected-tail (concat (make-string 65529 ?x) "α-tail")
                full-text (concat "discarded-prefix\n" expected-tail)
                sentinel-secret "LIMEN-COMPILE-ANNOTATION-SECRET-9f37"
                annotation
                (format "env LIMEN_TOKEN=%s compiler --argument=%s\n"
                        sentinel-secret sentinel-secret))
          (with-current-buffer inside
            (let ((inhibit-read-only t)
                  (split 32000))
              (insert "discarded-prefix\n")
              (insert (substring expected-tail 0 split))
              (compilation-insert-annotation annotation)
              (insert (substring expected-tail split))
              (add-text-properties (point-min) (point-max) '(face bold))
              (setq buffer-contents
                    (buffer-substring (point-min) (point-max)))
              (set-buffer-modified-p nil))
            (narrow-to-region 11 101)
            (goto-char 31)
            (set-mark 61)
            (setq mark-active t)
            (setq state
                  (list (point) (mark) mark-active (point-min) (point-max)
                        (buffer-modified-p))))
          (let* ((context (limen-make-request :interface 'cli
                                              :project-root root))
                 (record
                  (limen-compile-tests--without-process-actions
                    (limen-call
                     "compile.read" `((name . ,(buffer-name inside))) context)))
                 (text (alist-get 'text record)))
            (should (equal (alist-get 'name record) (buffer-name inside)))
            (should
             (equal (list (string-bytes text)
                          (length text)
                          (cl-mismatch text expected-tail)
                          (string-match-p (regexp-quote sentinel-secret) text))
                    '(65536 65535 nil nil)))
            (should (multibyte-string-p text))
            (should (= (alist-get 'size record) (string-bytes full-text)))
            (should (eq (alist-get 'truncated record) t))
            (dolist (property '(face compilation-annotation))
              (should-not
               (text-property-not-all 0 (length text) property nil text)))
            (dolist (secret '(command command_line environment process_environment))
              (should-not (assq secret record)))
            (with-current-buffer inside
              (save-restriction
                (widen)
                (should
                 (equal-including-properties
                  (buffer-substring (point-min) (point-max))
                  buffer-contents)))
              (should-not (buffer-modified-p))
              (should (equal
                       (list (point) (mark) mark-active (point-min) (point-max)
                             (buffer-modified-p))
                       state)))
            (should-error (limen-call "compile.read" nil context)
                          :type 'limen-invalid-arguments)
            (dolist (name (list "*limen compile missing*"
                                (buffer-name outside)
                                (buffer-name wrong-mode)))
              (ert-info ((format "name=%s" name))
                (should-error
                 (limen-call "compile.read" `((name . ,name)) context)
                 :type 'limen-operation-failed)))))
      (dolist (buffer (list inside outside wrong-mode))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory root t)
      (delete-directory outside-root t))))

(provide 'limen-compile-tests)
;;; limen-compile-tests.el ends here
