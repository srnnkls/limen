;;; limen-editor-tests.el --- Emacs diff tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-editor)

(defmacro limen-editor-tests--with-state (&rest body)
  (declare (indent 0) (debug t))
  `(let ((limen--buffers (make-hash-table :test #'eq))
         (limen--sessions (make-hash-table :test #'eq))
         (limen-editor-enable-diffs t)
         (limen-editor--diffs (make-hash-table :test #'eq)))
     ,@body))

(ert-deftest limen-editor-diffs-resolve-canonical-outcomes-through-registry ()
  (limen-editor-tests--with-state
    (let* ((root (make-temp-file "limen-diff" t))
           (old-file (expand-file-name "old.el" root))
           (new-file (expand-file-name "new.el" root))
           (owner (make-symbol "owner"))
           resolved
           cancelled)
      (unwind-protect
          (progn
            (with-temp-file old-file (insert "old\n"))
            (cl-letf (((symbol-function 'limen-editor--start-ediff)
                       (lambda (&rest _) nil)))
              (should
               (eq (limen-call
                    "diff.open"
                    `((old_path . ,old-file) (new_path . ,new-file)
                      (contents . "proposed") (name . "accept"))
                    (limen-make-request
                     :interface 'mcp :owner owner :project-root root
                     :resolve (lambda (result) (push result resolved))
                     :reject (lambda (result) (push result cancelled))))
                   limen-deferred))
              (let* ((diff (car (limen-editor--owner-diffs owner)))
                     (proposed (limen-editor--diff-proposed diff)))
                (with-current-buffer proposed
                  (erase-buffer)
                  (insert "edited proposal"))
                (should (limen-editor-accept-diff owner "accept"))
                (should-not (buffer-live-p proposed)))
              (should (equal (car resolved) "edited proposal"))
              (should
               (eq (limen-call
                    "diff.open"
                    `((old_path . ,old-file) (new_path . ,new-file)
                      (contents . "") (name . "empty"))
                    (limen-make-request
                     :interface 'mcp :owner owner :project-root root
                     :resolve (lambda (result) (push result resolved))
                     :reject (lambda (result) (push result cancelled))))
                   limen-deferred))
              (should (limen-editor-accept-diff owner "empty"))
              (should (equal (car resolved) ""))
              (should
               (eq (limen-call
                    "diff.open"
                    `((old_path . ,old-file) (new_path . ,new-file)
                      (contents . "Diff rejected") (name . "collision"))
                    (limen-make-request
                     :interface 'mcp :owner owner :project-root root
                     :resolve (lambda (result) (push result resolved))
                     :reject (lambda (result) (push result cancelled))))
                   limen-deferred))
              (should (limen-editor-accept-diff owner "collision"))
              (should (equal (car resolved) "Diff rejected"))
              (should
               (eq (limen-call
                    "diff.open"
                    `((old_path . ,old-file) (new_path . ,new-file)
                      (contents . "rejected") (name . "reject"))
                    (limen-make-request
                     :interface 'mcp :owner owner :project-root root
                     :resolve (lambda (result) (push result resolved))
                     :reject (lambda (result) (push result cancelled))))
                   limen-deferred))
              (should (limen-editor-reject-diff owner "reject"))
              (should (equal (car resolved) '((outcome . "rejected"))))
              (should
               (eq (limen-call
                    "diff.open"
                    `((old_path . ,old-file) (new_path . ,new-file)
                      (contents . "must not be accepted") (name . "closed"))
                    (limen-make-request
                     :interface 'mcp :owner owner :project-root root
                     :resolve (lambda (result) (push result resolved))
                     :reject (lambda (result) (push result cancelled))))
                   limen-deferred))
              (let* ((diff (car (limen-editor--owner-diffs owner)))
                     (proposed (limen-editor--diff-proposed diff)))
                (should (kill-buffer proposed))
                (should-not (buffer-live-p proposed))))
            (should-not cancelled)
            (should (equal (car resolved) '((outcome . "closed"))))
            (should (equal (nreverse resolved)
                           '("edited proposal" "" "Diff rejected"
                             ((outcome . "rejected"))
                             ((outcome . "closed")))))
            (should-not (limen-editor--owner-diffs owner)))
        (limen-editor-cancel owner)
        (when-let* ((buffer (get-file-buffer old-file))) (kill-buffer buffer))
        (delete-directory root t)))))

(ert-deftest limen-editor-cancel-is-owner-local-and-retryable ()
  (limen-editor-tests--with-state
    (let* ((first (make-symbol "first-owner"))
           (second (make-symbol "second-owner"))
           (first-cancellations 0)
           (second-cancellations 0))
      (puthash
       first
       (list (make-limen-editor--diff
              :owner first :name "first"
              :request (limen-make-request
                        :reject (lambda (_result)
                                  (cl-incf first-cancellations)))
              :proposed-released-p t :old-released-p t
              :control-released-p t))
       limen-editor--diffs)
      (puthash
       second
       (list (make-limen-editor--diff
              :owner second :name "second"
              :request (limen-make-request
                        :reject (lambda (_result)
                                  (cl-incf second-cancellations)))
              :proposed-released-p t :old-released-p t
              :control-released-p t))
       limen-editor--diffs)
      (should (limen-editor-cancel first))
      (should (= first-cancellations 1))
      (should (= second-cancellations 0))
      (should-not (gethash first limen-editor--diffs))
      (should (gethash second limen-editor--diffs))
      (should (limen-editor-cancel second))
      (should (= second-cancellations 1))
      (let* ((third (make-symbol "third-owner"))
             (proposed (generate-new-buffer " *limen-cancel-veto*"))
             (veto (lambda () nil))
             (diff (make-limen-editor--diff
                    :owner third :name "third"
                    :request (limen-make-request :reject #'ignore)
                    :proposed proposed :old-released-p t
                    :control-released-p t)))
        (with-current-buffer proposed
          (add-hook 'kill-buffer-query-functions veto nil t))
        (puthash third (list diff) limen-editor--diffs)
        (should-not (limen-editor-cancel third))
        (should (equal (gethash third limen-editor--diffs)
                       (list diff)))
        (with-current-buffer proposed
          (remove-hook 'kill-buffer-query-functions veto t))
        (should (limen-editor-cancel third))
        (should-not (buffer-live-p proposed))))))

(ert-deftest limen-close-session-preserves-state-when-editor-release-is-vetoed ()
  (limen-editor-tests--with-state
    (let* ((root (make-temp-file "limen-close-veto" t))
           (old-file (expand-file-name "old.el" root))
           (new-file (expand-file-name "new.el" root))
           (session (limen-open-session :provider 'test :project-root root))
           (owner (limen-session-owner session))
           (veto (lambda () nil))
           proposed first-error)
      (unwind-protect
          (save-window-excursion
            (with-temp-file old-file (insert "old\n"))
            (limen-call
             "buffer.open" `((path . ,old-file))
             (limen-make-request :interface 'cli :session session))
            (cl-letf (((symbol-function 'limen-editor--start-ediff)
                       (lambda (&rest _) nil)))
              (should
               (eq (limen-call
                    "diff.open"
                    `((old_path . ,old-file) (new_path . ,new-file)
                      (contents . "proposed") (name . "vetoed"))
                    (limen-make-request
                     :interface 'mcp :session session
                     :resolve #'ignore :reject #'ignore))
                   limen-deferred)))
            (setq proposed
                  (limen-editor--diff-proposed
                   (car (limen-editor--owner-diffs owner))))
            (with-current-buffer proposed
              (add-hook 'kill-buffer-query-functions veto nil t))
            (setq first-error
                  (condition-case error
                      (progn (limen-close-session session) nil)
                    (error error)))
            (should
             (and first-error
                  (not (limen-session-closed-p session))
                  (gethash session limen--sessions)
                  (buffer-live-p proposed)
                  (limen-editor--owner-diffs owner)
                  (gethash owner limen--buffers)))
            (with-current-buffer proposed
              (remove-hook 'kill-buffer-query-functions veto t))
            (should (limen-close-session session))
            (should (limen-session-closed-p session))
            (should-not (gethash session limen--sessions))
            (should-not (buffer-live-p proposed))
            (should-not (limen-editor--owner-diffs owner))
            (should-not (gethash owner limen--buffers)))
        (when (buffer-live-p proposed)
          (with-current-buffer proposed
            (remove-hook 'kill-buffer-query-functions veto t)))
        (ignore-errors (limen-editor-cancel owner))
        (when (and session (not (limen-session-closed-p session)))
          (ignore-errors (limen-close-session session)))
        (when-let* ((buffer (get-file-buffer old-file)))
          (kill-buffer buffer))
        (delete-directory root t)))))

(provide 'limen-editor-tests)
;;; limen-editor-tests.el ends here

(ert-deftest limen-editor-diffs-are-withdrawn-unless-enabled ()
  (limen-editor-tests--with-state
    (let* ((root (make-temp-file "limen-diff-off" t))
           (context (limen-make-request :interface 'mcp
                                        :owner (make-symbol "owner")
                                        :project-root root))
           (names (lambda ()
                    (mapcar (lambda (operation) (alist-get 'name operation))
                            (limen-operations context)))))
      (unwind-protect
          (progn
            (should-not (eval (car (get 'limen-editor-enable-diffs 'standard-value))))
            (let ((limen-editor-enable-diffs nil))
              (dolist (name '("diff.open" "diff.close" "diff.close-all"))
                (should-not (member name (funcall names))))
              (should-error
               (limen-call "diff.close-all" nil context)
               :type 'limen-disabled-operation))
            (dolist (name '("diff.open" "diff.close" "diff.close-all"))
              (should (member name (funcall names)))))
        (delete-directory root t)))))
