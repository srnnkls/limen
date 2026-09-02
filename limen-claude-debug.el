;;; limen-claude-debug.el --- Claude protocol debugging -*- lexical-binding: t; -*-

;;; Commentary:

;; Debug controls for the Claude protocol integration.

;;; Code:

(require 'limen-claude)

(defvar limen-claude-debug--log-buffer-name "*limen-claude*"
  "Name of the raw Claude IDE protocol log buffer.")
(defvar limen-claude-debug--log-buffer nil
  "Raw Claude IDE protocol log buffer.")

(defun limen-claude-debug--set-raw-protocol-logging (symbol value)
  "Set SYMBOL to VALUE and update raw protocol logging hooks."
  (set-default symbol value)
  (if value
      (progn
        (add-hook 'limen-claude--incoming-observers
                  #'limen-claude-debug--incoming)
        (add-hook 'limen-claude--outgoing-observers
                  #'limen-claude-debug--outgoing))
    (remove-hook 'limen-claude--incoming-observers
                 #'limen-claude-debug--incoming)
    (remove-hook 'limen-claude--outgoing-observers
                 #'limen-claude-debug--outgoing)
    (when (buffer-live-p limen-claude-debug--log-buffer)
      (kill-buffer limen-claude-debug--log-buffer))
    (unless (buffer-live-p limen-claude-debug--log-buffer)
      (setq limen-claude-debug--log-buffer nil))))

(defcustom limen-claude-logging nil
  "When non-nil, log raw protocol payloads.
Raw protocol data can expose sensitive project and user content."
  :type 'boolean
  :group 'limen
  :set #'limen-claude-debug--set-raw-protocol-logging)

(defun limen-claude-debug-log-buffer ()
  "Return the Claude IDE protocol log buffer."
  (or (and (buffer-live-p limen-claude-debug--log-buffer)
           limen-claude-debug--log-buffer)
      (setq limen-claude-debug--log-buffer
            (generate-new-buffer limen-claude-debug--log-buffer-name))))

(defun limen-claude-debug--record (direction state client text)
  "Record DIRECTION TEXT for STATE and CLIENT."
  (when limen-claude-logging
    (with-current-buffer (limen-claude-debug-log-buffer)
      (goto-char (point-max))
      (insert (format "%s session=%S generation=%s %s\n"
                      direction
                      (when-let* ((session (limen-claude-state-session state)))
                        (limen-session-id session))
                      (limen-claude-client-generation client)
                      text)))))

(defun limen-claude-debug--incoming (state client text)
  "Record incoming TEXT for STATE and CLIENT."
  (limen-claude-debug--record "incoming" state client text))

(defun limen-claude-debug--outgoing (state client text)
  "Record outgoing TEXT for STATE and CLIENT."
  (limen-claude-debug--record "outgoing" state client text))

;;;###autoload
(defun limen-claude-debug-open-log ()
  "Display the raw Claude protocol log."
  (interactive)
  (pop-to-buffer (limen-claude-debug-log-buffer)))

(defun limen-claude-debug-enable ()
  "Enable raw Claude IDE protocol logging."
  (interactive)
  (customize-set-variable 'limen-claude-logging t))

(defun limen-claude-debug-disable ()
  "Disable raw Claude IDE protocol logging."
  (interactive)
  (customize-set-variable 'limen-claude-logging nil))

(provide 'limen-claude-debug)
;;; limen-claude-debug.el ends here
