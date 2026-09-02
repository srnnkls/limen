;;; limen-herdr-transient.el --- Limen integration menu for Herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Provides integration controls without modifying Herdr's own transient.

;;; Code:

(require 'limen-herdr)
(require 'limen-herdr-claude)
(require 'transient)

(autoload 'limen-claude-debug-open-log "limen-claude-debug" nil t)
(autoload 'limen-claude-debug-enable "limen-claude-debug" nil t)
(autoload 'limen-claude-debug-disable "limen-claude-debug" nil t)

(declare-function herdr-agent-list "ext:herdr-agent" (&optional server-key))
(declare-function herdr-agent-session-kind "ext:herdr-agent" (session) t)

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

(defun limen-herdr-transient--reconnect (target)
  "Reconnect TARGET's Limen integration."
  (interactive (list (limen-herdr-transient--target)))
  (limen-herdr-reconnect target))

(defun limen-herdr-transient--status (target)
  "Show TARGET's Limen integration status."
  (interactive (list (limen-herdr-transient--target)))
  (message "%S" (limen-herdr-status target)))

(defun limen-herdr-transient--claude-p ()
  "Return non-nil when the current project target is Claude Code."
  (condition-case nil
      (equal (herdr-agent-session-kind (limen-herdr--session nil)) "claude")
    (error nil)))

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
    ("r" "reconnect" limen-herdr-transient--reconnect)]
   ["Claude Code"
    ("a" "adopt" limen-herdr-claude-adopt)
    ("c" "connect" limen-herdr-claude-connect
     :if limen-herdr-transient--claude-p)
    ("m" "auto-adopt" limen-herdr-transient--toggle-auto-adopt)]
   ["Protocol diagnostics"
    ("l" "protocol log" limen-claude-debug-open-log
     :if limen-herdr-transient--claude-p)
    ("d" "enable logging" limen-claude-debug-enable
     :if limen-herdr-transient--claude-p)
    ("D" "disable logging" limen-claude-debug-disable
     :if limen-herdr-transient--claude-p)]])

(provide 'limen-herdr-transient)
;;; limen-herdr-transient.el ends here
