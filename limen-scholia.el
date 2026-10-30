;;; limen-scholia.el --- Expose scholia annotation sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Registers read-only `annotation.*' operations over scholia's sessions,
;; adds an `annotations' section to `context.get', names the visible
;; sessions in the header of a Herdr message, and lets the message field
;; carry annotations above the message.  Requires scholia.

;;; Code:

(require 'cl-lib)
(require 'limen)
(require 'limen-herdr)

(declare-function scholia-session-list "ext:scholia-session" ())
(declare-function scholia-session-name-p "ext:scholia-core" (name))
(declare-function scholia-session-file "ext:scholia-core" (&optional name))
(declare-function scholia-session-default-name "ext:scholia-core" ())
(declare-function scholia-effective-sessions "ext:scholia-core" ())
(declare-function scholia-stored-assignments "ext:scholia-vars" ())
(declare-function scholia--directory-name "ext:scholia-vars" (directory))
(declare-function scholia-db-files "ext:scholia-db" (session-file))
(declare-function scholia-db-record "ext:scholia-db" (session-file file))
(declare-function scholia-db-record-file "ext:scholia-db" (record))
(declare-function scholia-db-record-annotations "ext:scholia-db" (record))
(declare-function scholia-db-annotation-id "ext:scholia-db" (annotation))
(declare-function scholia-db-annotation-line "ext:scholia-db" (annotation))
(declare-function scholia-db-annotation-column "ext:scholia-db" (annotation))
(declare-function scholia-db-annotation-end-column "ext:scholia-db" (annotation))
(declare-function scholia-db-annotation-text "ext:scholia-db" (annotation))
(declare-function scholia-db-annotation-annotated-text "ext:scholia-db"
                  (annotation))
(declare-function scholia-db-annotation-reply-to "ext:scholia-db" (annotation))
(declare-function scholia-export-session "ext:scholia-export"
                  (sessions &optional target format))
(declare-function scholia-export--session-record "ext:scholia-export"
                  (record cache format))
(declare-function scholia-session-name "ext:scholia-core" ())
(declare-function scholia-edit-glyph "ext:scholia-edit" (name fallback &optional color))
(defvar scholia-edit-icon)
(defvar scholia-edit-icon-fallback)
(declare-function scholia-herdr-annotations "ext:scholia-herdr"
                  (scope &optional beg end))
(declare-function scholia-herdr-render "ext:scholia-herdr"
                  (scope entries &optional session))
(defvar scholia-export-directory)
(defvar scholia-visible-sessions)
(defvar scholia-project-sessions)
(defvar scholia-mode)

(defconst limen-scholia-available-p
  (and (require 'scholia-vars nil t)
       (require 'scholia-core nil t)
       (require 'scholia-db nil t)
       (require 'scholia-session nil t)
       (require 'scholia-export nil t)
       t)
  "Non-nil when scholia loaded; the operations stay disabled otherwise.")

(defconst limen-scholia--formats '("rustc" "diff" "integrate" "compact" "yaml")
  "Export formats accepted by `annotation.export'.")

(defconst limen-scholia--entrypoint "`limen annotations list`"
  "CLI entrypoint named in message headers.")

(defun limen-scholia--sessions ()
  "Return every session name scholia knows."
  (scholia-session-list))

(defun limen-scholia--visible-sessions (&optional buffer)
  "Return the sessions drawn in BUFFER that exist on disk."
  (with-current-buffer (or buffer (current-buffer))
    (seq-filter (lambda (name)
                  (and (scholia-session-name-p name)
                       (file-exists-p (scholia-session-file name))))
                (scholia-effective-sessions))))

(defun limen-scholia--target-p (name root)
  "Return non-nil when NAME is the global or ROOT project write target."
  (or (equal name (scholia-session-default-name))
      (and root
           (equal name
                  (cdr (seq-find
                        (lambda (entry)
                          (equal (scholia--directory-name (car entry))
                                 (scholia--directory-name root)))
                        (append scholia-project-sessions
                                (scholia-stored-assignments))))))))

(defun limen-scholia--confined-files (name root)
  "Return the files of session NAME allowed below ROOT."
  (seq-filter (lambda (file) (limen-project-file-p file root))
              (scholia-db-files (scholia-session-file name))))

(defun limen-scholia--session-record (name root)
  "Return the JSON record for session NAME confined to ROOT."
  `((name . ,name)
    (active . ,(if (member name scholia-visible-sessions) t :json-false))
    (target . ,(if (limen-scholia--target-p name root) t :json-false))
    (files . ,(length (limen-scholia--confined-files name root)))))

(defun limen-scholia--annotation-record (session file annotation)
  "Return the JSON record for ANNOTATION of FILE in SESSION."
  `((id . ,(scholia-db-annotation-id annotation))
    (session . ,session)
    (file . ,file)
    (line . ,(scholia-db-annotation-line annotation))
    (column . ,(scholia-db-annotation-column annotation))
    (end_column . ,(scholia-db-annotation-end-column annotation))
    (text . ,(scholia-db-annotation-text annotation))
    (annotated_text . ,(scholia-db-annotation-annotated-text annotation))
    (reply_to . ,(scholia-db-annotation-reply-to annotation))))

(defun limen-scholia--require-session (name)
  "Return NAME when it is a known session, else signal invalid arguments."
  (unless (and (scholia-session-name-p name)
               (member name (limen-scholia--sessions)))
    (signal 'limen-invalid-arguments (list (format "Unknown session %s" name))))
  name)

(defun limen-scholia--selected-sessions (arguments)
  "Return the sessions ARGUMENTS select, defaulting to the visible ones."
  (let ((name (alist-get 'session arguments)))
    (if name
        (list (limen-scholia--require-session name))
      (limen-scholia--visible-sessions))))

(defun limen-scholia--selected-file (arguments root)
  "Return the confined file ARGUMENTS name below ROOT, or nil."
  (when-let* ((value (alist-get 'path arguments)))
    (or (limen-project-path value root)
        (signal 'limen-operation-failed
                (list "Path is outside the project or denied")))))

(defun limen-scholia--session-records-for (name files)
  "Return records of session NAME for FILES, dropping absent ones."
  (let ((session-file (scholia-session-file name)))
    (delq nil (mapcar (lambda (file) (scholia-db-record session-file file))
                      files))))

(defun limen-scholia--sessions-operation (_arguments context)
  "List scholia sessions confined to CONTEXT's project root."
  (let ((root (limen-request-project-root context)))
    (vconcat (mapcar (lambda (name) (limen-scholia--session-record name root))
                     (limen-scholia--sessions)))))

(defun limen-scholia--list-operation (arguments context)
  "List annotations selected by ARGUMENTS below CONTEXT's project root."
  (let* ((root (limen-request-project-root context))
         (limit (alist-get 'limit arguments))
         (file (limen-scholia--selected-file arguments root))
         (records nil))
    (when (and (integerp limit) (< limit 0))
      (signal 'limen-invalid-arguments '("The limit field must not be negative")))
    (catch 'done
      (dolist (name (limen-scholia--selected-sessions arguments))
        (dolist (record (limen-scholia--session-records-for
                         name (if file
                                  (list file)
                                (limen-scholia--confined-files name root))))
          (dolist (annotation (scholia-db-record-annotations record))
            (when (and (integerp limit) (>= (length records) limit))
              (throw 'done nil))
            (push (limen-scholia--annotation-record
                   name (scholia-db-record-file record) annotation)
                  records)))))
    (vconcat (nreverse records))))

(defun limen-scholia--export-operation (arguments context)
  "Render annotations selected by ARGUMENTS below CONTEXT's project root."
  (let* ((root (limen-request-project-root context))
         (name (limen-scholia--require-session (alist-get 'session arguments)))
         (format (intern (or (alist-get 'format arguments) "rustc")))
         (file (limen-scholia--selected-file arguments root)))
    (condition-case nil
        (if file
            (let ((cache (make-hash-table :test #'equal)))
              (mapconcat (lambda (record)
                           (scholia-export--session-record record cache format))
                         (limen-scholia--session-records-for name (list file))
                         "\n\n"))
          (let ((files (limen-scholia--confined-files name root)))
            (cl-letf (((symbol-function 'scholia-export--session-records)
                       (lambda (session)
                         (limen-scholia--session-records-for
                          session (sort (copy-sequence files) #'string<)))))
              (scholia-export-session name nil format))))
      (scholia-export-unknown-format
       (signal 'limen-invalid-arguments
               (list (format "Unknown export format %s" format)))))))

(defun limen-scholia--context-section (context)
  "Return the annotations section of `context.get' for CONTEXT, or nil."
  (when-let* ((limen-scholia-available-p)
              (visible (limen-scholia--visible-sessions))
              (root (limen-request-project-root context)))
    `((sessions . ,(vconcat
                    (mapcar (lambda (name)
                              (limen-scholia--session-record name root))
                            visible))))))

(defun limen-scholia--file-count (name file)
  "Return the number of annotations in session NAME for FILE."
  (if-let* ((record (scholia-db-record (scholia-session-file name) file)))
      (length (scholia-db-record-annotations record))
    0))

(defun limen-scholia-annotation-references (root)
  "Return the annotations of the visible sessions below ROOT.
Each is a cons of the reference naming it, project-relative FILE:LINE,
and the text it carries.  An annotation made in a buffer that visits no
file has no reference to give.  Nothing comes back without scholia,
without a visible session, or without a root."
  (when (and limen-scholia-available-p root)
    (let (references)
      (dolist (name (limen-scholia--visible-sessions))
        (dolist (record (limen-scholia--session-records-for
                         name (limen-scholia--confined-files name root)))
          (let ((file (scholia-db-record-file record)))
            (when (file-exists-p file)
              (dolist (annotation (scholia-db-record-annotations record))
                (push (cons (format "%s:%s" (file-relative-name file root)
                                    (scholia-db-annotation-line annotation))
                            (scholia-db-annotation-text annotation))
                      references))))))
      (nreverse references))))

(defun limen-scholia--context-field (_context _root)
  "Return the header line naming the sessions visible in the current buffer."
  (when-let* ((limen-scholia-available-p)
              (visible (limen-scholia--visible-sessions)))
    (let ((file (buffer-file-name (buffer-base-buffer))))
      (list
       (format "annotations: %s — %s"
               (mapconcat
                (lambda (name)
                  (let ((count (and file (limen-scholia--file-count name file))))
                    (if (and count (> count 0))
                        (format "%s (%d)" name count)
                      name)))
                visible ", ")
               limen-scholia--entrypoint)))))

(defconst limen-scholia-scopes
  '((point . "point") (region . "selection") (file . "buffer")
    (session . "session"))
  "Scopes a message can carry annotations from, with the names shown for them.")

(defun limen-scholia-composer-p (buffer)
  "Return non-nil when a message written from BUFFER can carry its annotations."
  (and limen-scholia-available-p
       (buffer-live-p buffer)
       (boundp 'scholia-mode)
       (buffer-local-value 'scholia-mode buffer)
       (require 'scholia-edit nil t)
       (require 'scholia-herdr nil t)))

(defun limen-scholia-composer-glyph ()
  "Return the glyph scholia's own field wears, bare, or nil for none."
  (when-let* ((glyph (scholia-edit-glyph scholia-edit-icon
                                         scholia-edit-icon-fallback)))
    (substring-no-properties glyph)))

(defun limen-scholia-composer-part (buffer scope)
  "Return the status text naming SCOPE of BUFFER's annotations.
The session BUFFER annotates into is named unless it is the default one."
  (with-current-buffer buffer
    (let ((session (scholia-session-name)))
      (concat (unless (equal session (scholia-session-default-name))
                (concat session " · "))
              (or (alist-get scope limen-scholia-scopes) "off")))))

(defun limen-scholia-composer-payload (buffer scope place)
  "Return BUFFER's annotations SCOPE takes as a send carries them, or nil.
PLACE is the region the message was begun over, as a cons of its
positions, or point consed onto itself.  They are rendered as scholia's
own sends render them, files named relative to BUFFER's project; a
session's files outside that project are left out."
  (with-current-buffer buffer
    (let* ((root (limen--project-root default-directory))
           (entries (seq-filter
                     (lambda (entry)
                       (or (null (car entry))
                           (and (file-name-absolute-p (car entry))
                                (limen-project-file-p (car entry) root))))
                     (save-excursion
                       (goto-char (car place))
                       (scholia-herdr-annotations scope (car place) (cdr place))))))
      (when entries
        (let ((scholia-export-directory root))
          (scholia-herdr-render scope entries))))))

(limen-register-operation
 "annotation.sessions" #'limen-scholia--sessions-operation
 :command "annotations sessions"
 :description "List scholia annotation sessions with their project-confined file counts."
 :effect 'read :parameters nil
 :enabled-p (lambda (_context) limen-scholia-available-p))

(limen-register-operation
 "annotation.list" #'limen-scholia--list-operation
 :command "annotations list"
 :description "List scholia annotations from visible or named sessions, confined to the project."
 :effect 'read
 :parameters '((:name "session" :type string
                      :description "Session name; omit for the visible sessions.")
               (:name "path" :type string
                      :description "Project-relative or absolute file path.")
               (:name "limit" :type integer
                      :description "Maximum number of annotations to return."))
 :enabled-p (lambda (_context) limen-scholia-available-p))

(limen-register-operation
 "annotation.export" #'limen-scholia--export-operation
 :command "annotations export"
 :description "Render a scholia session's project-confined annotations in an export format."
 :effect 'read
 :parameters `((:name "session" :type string :required t
                      :description "Session name.")
               (:name "path" :type string
                      :description "Restrict the rendering to one file.")
               (:name "format" :type string :enum ,limen-scholia--formats
                      :description "Export format; defaults to rustc."))
 :enabled-p (lambda (_context) limen-scholia-available-p))

(setf (alist-get "annotations" limen-context-sections nil nil #'equal)
      #'limen-scholia--context-section)

(add-hook 'limen-herdr-context-fields-functions #'limen-scholia--context-field)

(provide 'limen-scholia)
;;; limen-scholia.el ends here
