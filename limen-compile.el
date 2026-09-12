;;; limen-compile.el --- Observe compilation buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provides read-only access to existing project compilation buffers.

;;; Code:

(require 'compile)
(require 'limen)

(defconst limen-compile--tail-byte-limit 65536
  "Maximum number of UTF-8 bytes returned by `compile.read'.")

(defvar-local limen-compile--status "unknown"
  "Observed lifecycle status of the current compilation buffer.")

(defvar-local limen-compile--process-status nil
  "Observed terminal process status of the current compilation buffer.")

(defvar-local limen-compile--exit-code nil
  "Observed terminal process exit code of the current compilation buffer.")

(defvar-local limen-compile--process nil
  "Process most recently observed for the current compilation buffer.")

(defun limen-compile--started (process)
  "Record that the current compilation buffer started PROCESS."
  (setq limen-compile--status "running"
        limen-compile--process-status nil
        limen-compile--exit-code nil
        limen-compile--process process))

(defun limen-compile--terminal-status (status exit-code)
  "Return the lifecycle status for process STATUS and EXIT-CODE."
  (pcase status
    ('exit (if (zerop exit-code) "succeeded" "failed"))
    ('signal "stopped")
    (_ "unknown")))

(defun limen-compile--finished (buffer _message)
  "Record the terminal process state observed for compilation BUFFER."
  (with-current-buffer buffer
    (let* ((process (or (get-buffer-process buffer) limen-compile--process))
           (process-status (and process (process-status process)))
           (exit-code (and process (memq process-status '(exit signal))
                           (process-exit-status process))))
      (setq limen-compile--status
            (limen-compile--terminal-status process-status exit-code)
            limen-compile--process-status
            (and process-status (symbol-name process-status))
            limen-compile--exit-code exit-code
            limen-compile--process nil))))

(defun limen-compile--observe-current-buffer ()
  "Install buffer-local lifecycle observers in a compilation buffer."
  (when (derived-mode-p 'compilation-mode)
    (unless (local-variable-p 'limen-compile--status)
      (setq-local limen-compile--status "unknown"))
    (add-hook 'compilation-start-hook #'limen-compile--started nil t)
    (add-hook 'compilation-finish-functions #'limen-compile--finished nil t)))

(defun limen-compile--eligible-p (buffer root)
  "Return non-nil when BUFFER is a compilation buffer confined to ROOT."
  (and (buffer-live-p buffer)
       root
       (with-current-buffer buffer
         (and (derived-mode-p 'compilation-mode)
              (limen--buffer-kind buffer root)))))

(defun limen-compile--count (variable)
  "Return the numeric buffer-local counter stored in VARIABLE, or zero."
  (let ((value (and (boundp variable) (symbol-value variable))))
    (if (numberp value) value 0)))

(defun limen-compile--effective-status ()
  "Return the observed status of the current compilation buffer."
  (if (and (equal limen-compile--status "unknown")
           (when-let* ((process (get-buffer-process (current-buffer))))
             (process-live-p process)))
      "running"
    limen-compile--status))

(defun limen-compile--record (buffer)
  "Return the observable compilation record for BUFFER."
  (with-current-buffer buffer
    `((name . ,(buffer-name buffer))
      (directory . ,(file-name-as-directory (file-truename default-directory)))
      (status . ,(limen-compile--effective-status))
      ,@(when limen-compile--process-status
          `((process_status . ,limen-compile--process-status)))
      ,@(when (numberp limen-compile--exit-code)
          `((exit_code . ,limen-compile--exit-code)))
      (errors . ,(limen-compile--count 'compilation-num-errors-found))
      (warnings . ,(limen-compile--count 'compilation-num-warnings-found))
      (infos . ,(limen-compile--count 'compilation-num-infos-found)))))

(defun limen-compile--list (_arguments context)
  "List project compilation buffers visible through CONTEXT."
  (let ((root (limen-request-project-root context))
        records)
    (dolist (buffer (buffer-list))
      (when (limen-compile--eligible-p buffer root)
        (push (limen-compile--record buffer) records)))
    (vconcat (nreverse records))))

(defun limen-compile--trim-encoded-tail (encoded)
  "Trim UTF-8 ENCODED to the largest complete-character bounded tail."
  (let ((size (string-bytes encoded)))
    (if (<= size limen-compile--tail-byte-limit)
        encoded
      (let ((start (- size limen-compile--tail-byte-limit)))
        (while (= (logand (aref encoded start) #xc0) #x80)
          (cl-incf start))
        (substring encoded start)))))

(defun limen-compile--observable-output ()
  "Return the property-free observable output, byte size, and truncation state."
  (let ((position (point-min))
        (end (point-max))
        (size 0)
        (encoded-tail (encode-coding-string "" 'utf-8)))
    (while (< position end)
      (let ((next (next-single-property-change
                   position 'compilation-annotation nil end)))
        (if (get-text-property position 'compilation-annotation)
            (setq position next)
          (let* ((chunk-end (min next (+ position 8192)))
                 (encoded
                  (encode-coding-string
                   (buffer-substring-no-properties position chunk-end) 'utf-8)))
            (cl-incf size (string-bytes encoded))
            (setq encoded-tail
                  (limen-compile--trim-encoded-tail
                   (concat encoded-tail encoded))
                  position chunk-end)))))
    (list (decode-coding-string encoded-tail 'utf-8)
          size
          (if (> size limen-compile--tail-byte-limit) t :json-false))))

(defun limen-compile--read (arguments context)
  "Read the bounded output tail named by ARGUMENTS using CONTEXT."
  (let* ((name (alist-get 'name arguments))
         (buffer (get-buffer name))
         (root (limen-request-project-root context)))
    (unless (and buffer
                 (limen-compile--eligible-p buffer root)
                 (limen--buffer-readable-p buffer root))
      (signal 'limen-operation-failed
              '("Compilation buffer is unavailable for this project")))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (let ((output (limen-compile--observable-output)))
            (append (limen-compile--record buffer)
                    `((size . ,(cadr output))
                      (truncated . ,(caddr output))
                      (text . ,(car output))))))))))

(add-hook 'compilation-mode-hook #'limen-compile--observe-current-buffer)

(dolist (buffer (buffer-list))
  (when (with-current-buffer buffer (derived-mode-p 'compilation-mode))
    (with-current-buffer buffer
      (limen-compile--observe-current-buffer))))

(limen-register-operation
 "compile.list" #'limen-compile--list
 :description "List existing project compilation buffers."
 :effect 'read :parameters nil :interfaces '(cli mcp))

(limen-register-operation
 "compile.read" #'limen-compile--read
 :description "Read a bounded tail from an existing project compilation buffer."
 :effect 'read
 :parameters '((:name "name" :type string :required t
                      :description "Compilation buffer name."))
 :interfaces '(cli mcp))

(defun limen-compile--context-section (context)
  "Return the compilations section of `context.get' for CONTEXT."
  (limen-compile--list nil context))

(setf (alist-get "compilations" limen-context-sections nil nil #'equal)
      #'limen-compile--context-section)

(provide 'limen-compile)
;;; limen-compile.el ends here
