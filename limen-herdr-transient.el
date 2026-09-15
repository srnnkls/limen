;;; limen-herdr-transient.el --- Limen integration menu for Herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Provides integration controls without modifying Herdr's own transient.

;;; Code:

(require 'limen-herdr)
(require 'limen-herdr-claude)
(require 'limen-hooks)
(require 'transient)

(declare-function herdr-agent-list "ext:herdr-agent" (&optional server-key))

(defun limen-herdr-transient--target ()
  "Read an agent target from the current Herdr server."
  (let* ((agents (herdr-agent-list))
         (choices
          (mapcar (lambda (agent)
                    (cons (format "%s  %s"
                                  (or (alist-get 'name agent)
                                      (alist-get 'agent agent)
                                      "agent")
                                  (or (alist-get 'terminal_id agent) ""))
                          (alist-get 'terminal_id agent)))
                  agents)))
    (unless choices
      (user-error "No Herdr agent found"))
    (cdr (assoc (completing-read "Agent target: " choices nil t) choices))))

(defun limen-herdr-transient--push-context (target)
  "Push current context to TARGET."
  (interactive (list (limen-herdr-transient--target)))
  (limen-herdr-push-context target))

(defun limen-herdr-transient--status (target)
  "Show TARGET's Limen integration status."
  (interactive (list (limen-herdr-transient--target)))
  (message "%S" (limen-herdr-status target)))

(defun limen-herdr-transient--toggle-auto-adopt ()
  "Toggle automatic Claude Code adoption."
  (interactive)
  (limen-herdr-claude-auto-adopt-mode 'toggle))

;;;###autoload
(transient-define-prefix limen-herdr-transient ()
  "Manage Limen integration for Herdr agents."
  [["Integration"
    ("p" "push context" limen-herdr-transient--push-context)
    ("s" "status" limen-herdr-transient--status)
    ("h" "install hooks" limen-hooks-install)]
   ["Claude Code"
    ("a" "adopt" limen-herdr-claude-adopt)
    ("m" "auto-adopt" limen-herdr-transient--toggle-auto-adopt)]])

(provide 'limen-herdr-transient)
;;; limen-herdr-transient.el ends here
