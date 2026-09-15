;;; limen-trail.el --- Track recently visited buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Keeps an opt-in, bounded most-recently-used trail of visited buffers with
;; settled point positions and exposes it as the read-only `trail.list'
;; operation and the `trail' section of `context.get'.

;;; Code:

(require 'cl-lib)
(require 'limen)

(defcustom limen-trail-buffer-limit 32
  "Maximum number of buffers kept in the trail."
  :type '(integer 1)
  :group 'limen)

(defcustom limen-trail-point-limit 8
  "Maximum number of settled points kept per trail entry."
  :type '(integer 1)
  :group 'limen)

(defcustom limen-trail-idle-delay 0.5
  "Seconds Emacs must be idle before point is sampled into the trail."
  :type 'number
  :group 'limen)

(defcustom limen-trail-confine-to-project t
  "Whether `trail.list' discloses only entries of the requested project.
When nil, every entry is disclosed against its own project root, which
its record names, and that root's access policy applies to it."
  :type 'boolean
  :group 'limen)

(defcustom limen-trail-point-distance 5
  "Minimum line distance between consecutive settled points.
Smaller moves update the latest point in place."
  :type '(integer 0)
  :group 'limen)

(cl-defstruct (limen-trail-entry (:constructor limen-trail--make-entry))
  buffer file name points visits time)

(defvar limen-trail--entries nil
  "Trail entries, most recently visited first.")

(defvar limen-trail--timer nil
  "Idle timer sampling point into the trail.")

(defun limen-trail--trackable-p (buffer)
  "Return non-nil when BUFFER belongs in the trail."
  (and (buffer-live-p buffer)
       (not (minibufferp buffer))
       (not (string-prefix-p " " (buffer-name buffer)))))

(defun limen-trail--find (buffer)
  "Return the trail entry for BUFFER, matching a killed entry by file."
  (let ((file (limen-buffer-file-identity buffer)))
    (seq-find (lambda (entry)
                (or (eq (limen-trail-entry-buffer entry) buffer)
                    (and file
                         (null (limen-trail-entry-buffer entry))
                         (equal (limen-trail-entry-file entry) file))))
              limen-trail--entries)))

(defun limen-trail--point-line (point)
  "Return the absolute line of trail POINT, a marker or a frozen cons."
  (if (markerp point)
      (limen--absolute-line-number (marker-position point))
    (car point)))

(defun limen-trail--make-point (position)
  "Return a trail point for POSITION in the current buffer.
A file buffer keeps a live marker, so later edits carry the point along
with the text it marks.  A buffer without a file keeps a frozen line and
column, because a wholesale redraw of its text drags every marker inside
it to `point-min' and reports a position the point never held."
  (if buffer-file-name
      (copy-marker position)
    (cons (limen--absolute-line-number position)
          (limen-logical-column-at-position position))))

(defun limen-trail--push-point (entry position)
  "Record POSITION in the current buffer as ENTRY's latest settled point."
  (let* ((points (limen-trail-entry-points entry))
         (head (car points))
         (line (limen--absolute-line-number position))
         (head-here (if (markerp head)
                        (eq (marker-buffer head) (current-buffer))
                      (and head (null buffer-file-name)))))
    (if (and head-here
             (< (abs (- line (limen-trail--point-line head)))
                limen-trail-point-distance))
        (if (markerp head)
            (set-marker head position)
          (setcar points (limen-trail--make-point position)))
      (setf (limen-trail-entry-points entry)
            (cons (limen-trail--make-point position)
                  (seq-take points (1- limen-trail-point-limit)))))))

(defun limen-trail--visit (&optional _window)
  "Record the selected window's buffer as the most recent trail entry."
  (let ((buffer (window-buffer (selected-window))))
    (when (and (limen-trail--trackable-p buffer)
               (not (eq (and limen-trail--entries
                             (limen-trail-entry-buffer (car limen-trail--entries)))
                        buffer)))
      (let ((entry (limen-trail--find buffer)))
        (if entry
            (setq limen-trail--entries (delq entry limen-trail--entries))
          (setq entry (limen-trail--make-entry :visits 0)))
        (setf (limen-trail-entry-buffer entry) buffer
              (limen-trail-entry-file entry) (limen-buffer-file-identity buffer)
              (limen-trail-entry-name entry) (buffer-name buffer)
              (limen-trail-entry-visits entry) (1+ (limen-trail-entry-visits entry))
              (limen-trail-entry-time entry) (float-time))
        (with-current-buffer buffer
          (limen-trail--push-point entry (point)))
        (setq limen-trail--entries
              (cons entry (seq-take limen-trail--entries
                                    (1- limen-trail-buffer-limit))))))))

(defun limen-trail--settle ()
  "Sample point of the current buffer into its head trail entry."
  (let ((entry (car limen-trail--entries)))
    (when (and entry (eq (limen-trail-entry-buffer entry) (current-buffer)))
      (let ((head (car (limen-trail-entry-points entry))))
        (unless (and (markerp head) (eq (marker-position head) (point)))
          (limen-trail--push-point entry (point)))))))

(defun limen-trail--freeze ()
  "Detach the current buffer from its trail entry before it is killed."
  (when-let* ((entry (limen-trail--find (current-buffer))))
    (if (limen-trail-entry-file entry)
        (setf (limen-trail-entry-buffer entry) nil
              (limen-trail-entry-points entry)
              (mapcar (lambda (point)
                        (if (markerp point)
                            (prog1 (cons (limen--absolute-line-number
                                          (marker-position point))
                                         (limen-logical-column-at-position
                                          (marker-position point)))
                              (set-marker point nil))
                          point))
                      (limen-trail-entry-points entry)))
      (limen-trail--drop entry))))

(defun limen-trail--drop (entry)
  "Remove ENTRY from the trail and release its markers."
  (dolist (point (limen-trail-entry-points entry))
    (when (markerp point) (set-marker point nil)))
  (setq limen-trail--entries (delq entry limen-trail--entries)))

(defun limen-trail-clear ()
  "Forget every trail entry."
  (interactive)
  (dolist (entry limen-trail--entries)
    (limen-trail--drop entry)))

(defun limen-trail--point-record (point)
  "Return a JSON line and column record for trail POINT."
  (if (markerp point)
      (with-current-buffer (marker-buffer point)
        (let ((position (marker-position point)))
          `((line . ,(limen--absolute-line-number position))
            (column . ,(limen-logical-column-at-position position)))))
    `((line . ,(car point)) (column . ,(cdr point)))))

(defun limen-trail--entry-root (entry root)
  "Return the root ENTRY is disclosed against for a request below ROOT.
Confinement answers with ROOT.  Without it each entry answers with the
project of the buffer or file it names, so that root's access policy is
the one applied to it."
  (if limen-trail-confine-to-project
      root
    (let ((buffer (limen-trail-entry-buffer entry))
          (file (limen-trail-entry-file entry)))
      (cond
       ((buffer-live-p buffer)
        (limen--project-root (buffer-local-value 'default-directory buffer)))
       (file (limen--project-root (file-name-directory file)))
       (t root)))))

(defun limen-trail--entry-fields (entry root)
  "Return the recency fields shared by every ENTRY record disclosed below ROOT."
  (append
   `((live . ,(if (limen-trail-entry-buffer entry) t :json-false))
     (visits . ,(limen-trail-entry-visits entry))
     (last_visited . ,(format-time-string "%FT%T%z"
                                          (limen-trail-entry-time entry))))
   (unless limen-trail-confine-to-project `((project . ,root)))))

(defun limen-trail--entry-record (entry root)
  "Return the disclosed record for ENTRY below ROOT, or nil."
  (let ((buffer (limen-trail-entry-buffer entry))
        (file (limen-trail-entry-file entry))
        (root (limen-trail--entry-root entry root)))
    (if buffer
        (pcase (limen--buffer-kind buffer root)
          ('nil nil)
          ((and 'virtual (guard (not (limen--virtual-buffer-readable-p buffer))))
           (append (limen--redacted-virtual-buffer-record buffer)
                   (limen-trail--entry-fields entry root)))
          (_ (append (limen--buffer-record buffer)
                     (limen-trail--entry-fields entry root)
                     `((points . ,(vconcat
                                   (mapcar #'limen-trail--point-record
                                           (limen-trail-entry-points entry))))))))
      (when (and file (limen-project-file-p file root))
        (append `((name . ,(limen-trail-entry-name entry))
                  (file . ,file)
                  (kind . "file"))
                (limen-trail--entry-fields entry root)
                `((points . ,(vconcat
                              (mapcar #'limen-trail--point-record
                                      (limen-trail-entry-points entry))))))))))

(defun limen-trail--list (arguments context)
  "List disclosed trail entries for ARGUMENTS and CONTEXT, newest first."
  (let ((root (limen-request-project-root context))
        (limit (alist-get 'limit arguments))
        records)
    (when (and (integerp limit) (< limit 0))
      (signal 'limen-invalid-arguments '("The limit field must not be negative")))
    (catch 'done
      (dolist (entry limen-trail--entries)
        (when (and (integerp limit) (>= (length records) limit))
          (throw 'done nil))
        (when-let* ((record (limen-trail--entry-record entry root)))
          (push record records))))
    (vconcat (nreverse records))))

;;;###autoload
(define-minor-mode limen-trail-mode
  "Track recently visited buffers and settled points for agents."
  :global t
  :group 'limen
  (when limen-trail--timer
    (cancel-timer limen-trail--timer)
    (setq limen-trail--timer nil))
  (cond
   (limen-trail-mode
    (add-hook 'window-selection-change-functions #'limen-trail--visit)
    (add-hook 'window-buffer-change-functions #'limen-trail--visit)
    (add-hook 'kill-buffer-hook #'limen-trail--freeze)
    (setq limen-trail--timer
          (run-with-idle-timer limen-trail-idle-delay t #'limen-trail--settle))
    (limen-trail--visit))
   (t
    (remove-hook 'window-selection-change-functions #'limen-trail--visit)
    (remove-hook 'window-buffer-change-functions #'limen-trail--visit)
    (remove-hook 'kill-buffer-hook #'limen-trail--freeze)
    (limen-trail-clear)))
  (run-hook-with-args 'limen-operation-change-hook
                      (if limen-trail-mode 'enabled 'disabled) "trail.list"))

(defun limen-trail--context-section (context)
  "Return the trail section of `context.get' for CONTEXT."
  (when limen-trail-mode
    (limen-trail--list nil context)))

(limen-register-operation
 "trail.list" #'limen-trail--list
 :description "List recently visited project-confined buffers, newest first, with settled point traces."
 :effect 'read
 :parameters '((:name "limit" :type integer
                      :description "Maximum number of entries to return."))
 :interfaces '(cli mcp)
 :enabled-p (lambda (_context) limen-trail-mode))

(setf (alist-get "trail" limen-context-sections nil nil #'equal)
      #'limen-trail--context-section)

(provide 'limen-trail)
;;; limen-trail.el ends here
