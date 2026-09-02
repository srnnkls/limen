;;; limen-editor.el --- Emacs context and interactive diffs -*- lexical-binding: t; -*-

;;; Commentary:

;; Implements Agent selection events and interactive Emacs diffs.

;;; Code:

(require 'cl-lib)
(require 'ediff)
(require 'limen)
(require 'seq)

(defvar limen-editor--diffs (make-hash-table :test #'eq)
  "Deferred diffs indexed by opaque protocol owner.")
(defvar limen-editor--selection-timers (make-hash-table :test #'eq)
  "Selection debounce timers indexed by opaque protocol owner.")
(defvar limen-editor--selection-contexts (make-hash-table :test #'eq)
  "Last selection snapshots indexed by opaque protocol owner.")

(cl-defstruct limen-editor--diff
  "A deferred Emacs diff and its resources."
  owner request name proposed old old-path old-owned-p root expected-tick completion control
  control-completion hook-removed-p response-sent-p proposed-released-p old-released-p
  control-released-p)

(defun limen-editor-context-snapshot (&optional buffer)
  "Return BUFFER's normalized file and selection context."
  (limen-buffer-context-snapshot buffer))

(defun limen-editor-cancel-selection (owner)
  "Cancel OWNER's pending selection notification."
  (when-let* ((entry (gethash owner limen-editor--selection-timers)))
    (cancel-timer (cdr entry)))
  (remhash owner limen-editor--selection-timers)
  (remhash owner limen-editor--selection-contexts))

(defun limen-editor-schedule-selection
    (owner buffer root current-p callback)
  "Debounce BUFFER selection for OWNER below ROOT.
CURRENT-P validates ownership before CALLBACK receives a normalized snapshot."
  (let ((token (make-symbol "selection")))
    (when-let* ((previous (gethash owner limen-editor--selection-timers)))
      (cancel-timer (cdr previous)))
    (puthash
     owner
     (cons token
           (run-at-time
            0.1 nil
            (lambda ()
              (when-let* ((entry (gethash owner limen-editor--selection-timers))
                          ((eq token (car entry))))
                (remhash owner limen-editor--selection-timers)
                (if (and (funcall current-p) (buffer-live-p buffer))
                    (with-current-buffer buffer
                      (if (limen-project-buffer-file buffer root)
                          (let ((snapshot (limen-editor-context-snapshot buffer)))
                            (unless (equal snapshot
                                           (gethash owner
                                                    limen-editor--selection-contexts))
                              (puthash owner snapshot
                                       limen-editor--selection-contexts)
                              (funcall callback snapshot)))
                        (remhash owner limen-editor--selection-contexts)))
                  (remhash owner limen-editor--selection-contexts))))))
     limen-editor--selection-timers)))

(defun limen-editor--session-current-p (session)
  "Return non-nil when SESSION remains open and registered."
  (and (gethash session limen--sessions)
       (not (limen-session-closed-p session))))

(defun limen-editor-selection-context-changed ()
  "Publish the current file selection to matching Limen sessions."
  (when-let* ((buffer (current-buffer)))
    (maphash
     (lambda (session _present)
       (when-let* ((root (limen-session-project-root session))
                   ((limen-project-buffer-file buffer root)))
         (limen-editor-schedule-selection
          (limen-session-owner session) buffer root
          (lambda () (limen-editor--session-current-p session))
          (lambda (snapshot)
            (when (limen-editor--session-current-p session)
              (limen-session-publish
               session "context.selection" snapshot))))))
     limen--sessions)))

(defun limen-editor--session-opened (_session)
  "Install the shared selection hook for the first Limen session."
  (unless (memq #'limen-editor-selection-context-changed post-command-hook)
    (add-hook 'post-command-hook #'limen-editor-selection-context-changed)))

(defun limen-editor--other-session-open-p (closing)
  "Return non-nil when an open session other than CLOSING remains."
  (let (open)
    (maphash
     (lambda (session _present)
       (when (and (not (eq session closing))
                  (not (limen-session-closed-p session)))
         (setq open t)))
     limen--sessions)
    open))

(defun limen-editor--owner-diffs (owner)
  "Return deferred diffs owned by OWNER."
  (gethash owner limen-editor--diffs))

(defun limen-editor--track-diff (owner diff)
  "Track DIFF for OWNER."
  (puthash owner (cons diff (delq diff (gethash owner limen-editor--diffs)))
           limen-editor--diffs)
  diff)

(defun limen-editor--untrack-diff (diff)
  "Remove fully released DIFF from its owner state."
  (let ((owner (limen-editor--diff-owner diff)))
    (when (and (limen-editor--diff-response-sent-p diff)
               (limen-editor--diff-proposed-released-p diff)
               (limen-editor--diff-old-released-p diff)
               (limen-editor--diff-control-released-p diff))
      (let ((diffs (delq diff (gethash owner limen-editor--diffs))))
        (if diffs
            (puthash owner diffs limen-editor--diffs)
          (remhash owner limen-editor--diffs))))))

(defun limen-editor--remove-diff-hook (diff)
  "Remove completion hooks installed for DIFF."
  (unless (limen-editor--diff-hook-removed-p diff)
    (when-let* ((buffer (limen-editor--diff-proposed diff))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (remove-hook 'kill-buffer-hook
                     (limen-editor--diff-completion diff) t)))
    (when-let* ((buffer (limen-editor--diff-control diff))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (remove-hook 'ediff-after-quit-hook-internal
                     (limen-editor--diff-control-completion diff) t)))
    (setf (limen-editor--diff-hook-removed-p diff) t)))

(defun limen-editor--release-diff-resources (diff &optional killed)
  "Release DIFF resources, treating proposed buffers as killed when KILLED."
  (limen-editor--remove-diff-hook diff)
  (unless (limen-editor--diff-control-released-p diff)
    (let ((control (limen-editor--diff-control diff)))
      (if (not (buffer-live-p control))
          (setf (limen-editor--diff-control-released-p diff) t)
        (setf (limen-editor--diff-control-released-p diff) t)
        (condition-case err
            (with-current-buffer control
              (let ((ediff-control-buffer control))
                (ediff-really-quit nil)))
          (error
           (setf (limen-editor--diff-control-released-p diff) nil)
           (signal (car err) (cdr err))))
        (unless (buffer-live-p control)
          (setq ediff-session-registry (delq control ediff-session-registry))
          (dolist (buffer (list (limen-editor--diff-old diff)
                                (limen-editor--diff-proposed diff)))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (setq ediff-this-buffer-ediff-sessions
                      (delq control ediff-this-buffer-ediff-sessions))))))
        (setf (limen-editor--diff-control-released-p diff)
              (not (buffer-live-p control))))))
  (unless (limen-editor--diff-proposed-released-p diff)
    (let ((buffer (limen-editor--diff-proposed diff)))
      (if (or killed (not (buffer-live-p buffer)))
          (setf (limen-editor--diff-proposed-released-p diff) t)
        (kill-buffer buffer)
        (setf (limen-editor--diff-proposed-released-p diff)
              (not (buffer-live-p buffer))))))
  (unless (limen-editor--diff-old-released-p diff)
    (let ((old (limen-editor--diff-old diff)))
      (if (and (limen-editor--diff-old-owned-p diff)
               (buffer-live-p old) (not (buffer-modified-p old))
               (null (get-buffer-window-list old nil 0)))
          (progn
            (kill-buffer old)
            (setf (limen-editor--diff-old-released-p diff)
                  (not (buffer-live-p old))))
        (setf (limen-editor--diff-old-released-p diff) t)))))

(defun limen-editor--finish-diff
    (diff &optional result killed rejection)
  "Complete DIFF with RESULT, then release its resources.
KILLED records an already killed proposed buffer.  REJECTION, when non-nil,
is the condition sent to the pending request; t denotes cancellation."
  (unless (limen-editor--diff-response-sent-p diff)
    (let ((request (limen-editor--diff-request diff)))
      (condition-case nil
          (if rejection
              (limen-request-reject
               request
               (if (eq rejection t)
                   '(limen-operation-failed "Diff cancelled")
                 rejection))
            (limen-request-resolve request result))
        (error nil))
      (setf (limen-editor--diff-response-sent-p diff) t)))
  (limen-editor--release-diff-resources diff killed)
  (limen-editor--untrack-diff diff)
  (and (limen-editor--diff-response-sent-p diff)
       (limen-editor--diff-proposed-released-p diff)
       (limen-editor--diff-old-released-p diff)
       (limen-editor--diff-control-released-p diff)))

(defun limen-editor--diff-base-current-p (diff)
  "Return non-nil when DIFF's tick-guarded base remains current."
  (let ((expected-tick (limen-editor--diff-expected-tick diff)))
    (or (null expected-tick)
        (let* ((old (limen-editor--diff-old diff))
               (identity (limen-buffer-file-identity old))
               (root (limen-editor--diff-root diff)))
          (and identity root
               (equal identity (limen-editor--diff-old-path diff))
               (limen-project-buffer-file old root)
               (= (with-current-buffer old (buffer-chars-modified-tick))
                  expected-tick))))))

(defun limen-editor--complete-diff (diff accept &optional killed)
  "Complete DIFF as ACCEPT, with optional KILLED proposed buffer."
  (if (and accept (not (limen-editor--diff-base-current-p diff)))
      (limen-editor--finish-diff
       diff nil killed '(limen-conflict "Buffer changed since diff opened"))
    (limen-editor--finish-diff
     diff
     (if accept
         (if (buffer-live-p (limen-editor--diff-proposed diff))
             (with-current-buffer (limen-editor--diff-proposed diff)
               (buffer-string))
           "")
       "Diff rejected")
     killed)))

(defun limen-editor--find-diff (owner name)
  "Return OWNER's deferred diff named NAME."
  (seq-find (lambda (diff)
              (and (limen-editor--diff-p diff)
                   (equal name (limen-editor--diff-name diff))))
            (limen-editor--owner-diffs owner)))

(defun limen-editor-accept-diff (owner name)
  "Accept OWNER's deferred diff named NAME."
  (when-let* ((diff (limen-editor--find-diff owner name)))
    (limen-editor--complete-diff diff t)))

(defun limen-editor-reject-diff (owner name)
  "Reject OWNER's deferred diff named NAME."
  (when-let* ((diff (limen-editor--find-diff owner name)))
    (limen-editor--complete-diff diff nil)))

(defun limen-editor--cancel-diff (diff)
  "Cancel DIFF and release its resources."
  (limen-editor--finish-diff diff nil nil t))

(defun limen-editor-cancel (owner)
  "Cancel diffs, selections, and buffers owned by opaque OWNER."
  (limen-editor-cancel-selection owner)
  (let ((diffs-released t))
    (dolist (diff (copy-sequence (limen-editor--owner-diffs owner)))
      (when (and (limen-editor--diff-p diff)
                 (not (limen-editor--cancel-diff diff)))
        (setq diffs-released nil)))
    (and diffs-released
         (null (limen-editor--owner-diffs owner))
         (limen-release-owner owner))))

(defun limen-editor--bind-diff-control (diff control)
  "Associate DIFF with Ediff CONTROL and install completion handling."
  (setf (limen-editor--diff-control diff) control)
  (if (limen-editor--diff-response-sent-p diff)
      (limen-editor--release-diff-resources diff)
    (when (and control (buffer-live-p control))
      (setf (limen-editor--diff-control-released-p diff) nil)
      (with-current-buffer control
        (add-hook 'ediff-after-quit-hook-internal
                  (limen-editor--diff-control-completion diff) nil t)))
    (unless (and control (buffer-live-p control))
      (setf (limen-editor--diff-control-released-p diff) t)))
  diff)

(defun limen-editor--start-ediff (diff old proposed)
  "Start Ediff for DIFF between OLD and PROPOSED buffers."
  (let ((capture
         (lambda ()
           (limen-editor--bind-diff-control diff ediff-control-buffer))))
    (add-hook 'ediff-startup-hook capture)
    (unwind-protect
        (progn
          (ediff-buffers old proposed)
          nil)
      (remove-hook 'ediff-startup-hook capture))))

(defun limen-editor--open-diff (owner root arguments request)
  "Open ARGUMENTS as a deferred diff below ROOT for OWNER and REQUEST."
  (let* ((old-requested
          (limen-project-path (plist-get arguments :old-path) root))
         (new (limen-project-path (plist-get arguments :new-path) root))
         (contents (plist-get arguments :contents))
         (name (plist-get arguments :name))
         (expected-tick (plist-get arguments :expected-tick)))
    (if (not (and old-requested new (stringp contents) (stringp name) request))
        (signal 'limen-operation-failed
                '("Diff paths are outside the project or denied"))
      (let* ((old-existing (limen--buffer-for-file old-requested))
             (old (or old-existing
                      (and (null expected-tick)
                           (find-file-noselect old-requested)))))
        (unless old
          (signal 'limen-operation-failed
                  '("Tick-guarded diff base is not visited")))
        (let ((old-identity (limen-project-buffer-file old root)))
          (unless (and old-identity
                       (limen--same-file-identity-p
                        old-requested old-identity))
            (signal 'limen-operation-failed
                    '("Diff base is outside the project or denied")))
          (when expected-tick
            (limen--assert-buffer-tick old expected-tick))
          (let* ((proposed (generate-new-buffer (format " *limen diff %s*" name)))
                 (diff (make-limen-editor--diff
                        :owner owner :request request :name name
                        :proposed proposed :old old :old-path old-identity
                        :old-owned-p (null old-existing) :root root
                        :expected-tick expected-tick)))
            (with-current-buffer proposed (insert contents))
            (let ((completion (lambda () (limen-editor--complete-diff diff t t)))
                  (control-completion (lambda () (limen-editor--cancel-diff diff))))
              (setf (limen-editor--diff-completion diff) completion
                    (limen-editor--diff-control-completion diff) control-completion)
              (with-current-buffer proposed
                (add-hook 'kill-buffer-hook completion nil t)))
            (limen-editor--track-diff owner diff)
            (condition-case err
                (let ((control (limen-editor--start-ediff diff old proposed)))
                  (unless (limen-editor--diff-control diff)
                    (limen-editor--bind-diff-control diff control))
                  (setf (limen-request-canceller request)
                        (lambda () (limen-editor--cancel-diff diff)))
                  limen-deferred)
              (error
               (if (limen-editor--diff-response-sent-p diff)
                   limen-deferred
                 (setf (limen-editor--diff-response-sent-p diff) t)
                 (condition-case nil
                     (limen-editor--finish-diff diff)
                   (error nil))
                 (signal (car err) (cdr err)))))))))))

(defun limen-editor--close-diffs (owner &optional name)
  "Close OWNER diffs, optionally limited to NAME."
  (dolist (diff (copy-sequence (limen-editor--owner-diffs owner)))
    (when (and (limen-editor--diff-p diff)
               (or (null name)
                   (equal name (limen-editor--diff-name diff))))
      (limen-editor--cancel-diff diff)))
  "Closed diffs")

(defun limen-editor--diff-open-operation (arguments request)
  "Open a diff from ARGUMENTS using REQUEST."
  (limen-editor--open-diff
   (limen-request-owner request)
   (limen-request-project-root request)
   (list :old-path (alist-get 'old_path arguments)
         :new-path (alist-get 'new_path arguments)
         :contents (alist-get 'contents arguments)
         :name (alist-get 'name arguments)
         :expected-tick (alist-get 'expected_tick arguments))
   request))

(defun limen-editor--diff-close-operation (arguments request)
  "Close the diff in ARGUMENTS using REQUEST."
  (limen-editor--close-diffs
   (limen-request-owner request) (alist-get 'name arguments)))

(defun limen-editor--diff-close-all-operation (_arguments request)
  "Close all diffs owned by REQUEST."
  (limen-editor--close-diffs (limen-request-owner request)))

(defun limen-editor--close-session (session)
  "Release editor resources owned by SESSION."
  (unless (limen-editor-cancel (limen-session-owner session))
    (signal 'limen-operation-failed '("Editor resources remain open")))
  (unless (limen-editor--other-session-open-p session)
    (remove-hook 'post-command-hook
                 #'limen-editor-selection-context-changed))
  t)

(add-hook 'limen-session-open-hook #'limen-editor--session-opened)
(add-hook 'limen-session-close-hook #'limen-editor--close-session)

(limen-register-operation
 "diff.open" #'limen-editor--diff-open-operation
 :description "Open an editable Emacs diff."
 :effect 'write :interfaces '(adapter mcp) :deferred t
 :parameters '((:name "old_path" :type string :required t)
               (:name "new_path" :type string :required t)
               (:name "contents" :type string :required t)
               (:name "name" :type string :required t)
               (:name "expected_tick" :type integer)))

(limen-register-operation
 "diff.close" #'limen-editor--diff-close-operation
 :description "Close an adapter-owned Emacs diff."
 :effect 'write :interfaces '(adapter mcp)
 :parameters '((:name "name" :type string :required t)))

(limen-register-operation
 "diff.close-all" #'limen-editor--diff-close-all-operation
 :description "Close all adapter-owned Emacs diffs."
 :effect 'write :interfaces '(adapter mcp) :parameters nil)

(provide 'limen-editor)
;;; limen-editor.el ends here
