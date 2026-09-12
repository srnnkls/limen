;;; limen-herdr-claude.el --- Claude commands for Limen and Herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Adds Claude Code adoption and reconnect commands over the public Herdr bridge.

;;; Code:

(require 'cl-lib)
(require 'limen-herdr)
(require 'project)
(require 'seq)

(declare-function herdr-agent-adopt "ext:herdr-agent"
                  (agent &rest arguments) t)
(declare-function herdr-agent-list "ext:herdr-agent" (&optional server-key))
(declare-function herdr-agent-send-text "ext:herdr-agent" (target text))
(declare-function herdr-agent-session-kind "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-server "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-terminal "ext:herdr-agent" (session) t)
(defvar herdr-agent-event-functions)

(defcustom limen-herdr-claude-auto-adopt-predicate
  #'limen-herdr-claude-known-project-p
  "Predicate deciding whether automatic adoption accepts an agent."
  :type 'function
  :group 'limen-herdr)

(defcustom limen-herdr-claude-connect-on-adopt 'idle
  "When an adopted Claude Code process is asked to connect to Limen."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "While the agent is idle" idle)
                 (const :tag "Always" t))
  :group 'limen-herdr)

(defun limen-herdr-claude-known-project-p (agent)
  "Return non-nil when AGENT's directory is a known project."
  (when-let* ((cwd (alist-get 'cwd agent)))
    (and (file-directory-p cwd) (project-current nil cwd) t)))

(defun limen-herdr-claude--connect-p (agent)
  "Return non-nil when adopted AGENT should connect to Limen."
  (pcase limen-herdr-claude-connect-on-adopt
    ('nil nil)
    ('idle (equal (alist-get 'agent_status agent) "idle"))
    (_ t)))

(defun limen-herdr-claude--target (session)
  "Return composite target for Herdr SESSION."
  (cons (herdr-agent-session-server session)
        (herdr-agent-session-terminal session)))

(defun limen-herdr-claude--read-agent (prompt)
  "Read a Claude agent with PROMPT from the current Herdr server."
  (let* ((agents
          (seq-filter (lambda (agent) (equal (alist-get 'agent agent) "claude"))
                      (herdr-agent-list)))
         (choices
          (mapcar (lambda (agent)
                    (cons (format "%s  %s"
                                  (or (alist-get 'name agent) "Claude")
                                  (or (alist-get 'terminal_id agent) ""))
                          agent))
                  agents)))
    (unless choices
      (user-error "No Claude Code agent found"))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

;;;###autoload
(defun limen-herdr-claude-connect (&optional target)
  "Ask Claude Code at Herdr TARGET to connect to Limen."
  (interactive)
  (let ((session (limen-herdr--session target)))
    (unless (equal (herdr-agent-session-kind session) "claude")
      (user-error "Target is not Claude Code"))
    (herdr-agent-send-text (limen-herdr-claude--target session) "/ide\n")))

;;;###autoload
(defun limen-herdr-claude-adopt (agent &optional server-key display)
  "Adopt Claude AGENT from optional Herdr SERVER-KEY into Limen.
DISPLAY shows the attached buffer."
  (interactive (list (limen-herdr-claude--read-agent "Adopt Herdr Claude: ") nil t))
  (let ((session (herdr-agent-adopt
                  agent :server-key (or server-key (alist-get 'server_key agent))
                  :display display)))
    (when (limen-herdr-claude--connect-p agent)
      (herdr-agent-send-text (limen-herdr-claude--target session) "/ide\n"))
    session))

;;;###autoload
(defun limen-herdr-claude-at-mention (&optional target)
  "Push current context as an at-mention to Claude Code at TARGET."
  (interactive)
  (limen-herdr-push-context target))

(defun limen-herdr-claude--agent-for-pane (server-key pane-id)
  "Return SERVER-KEY's agent in PANE-ID."
  (cl-find pane-id (herdr-agent-list server-key)
           :key (lambda (agent) (alist-get 'pane_id agent)) :test #'equal))

(defun limen-herdr-claude--maybe-adopt (server-key type data)
  "Adopt Claude from Herdr event TYPE and DATA on SERVER-KEY.
The attachment stays off screen; nothing you are looking at moves."
  (when (and (equal type "pane.agent_detected")
             (equal (alist-get 'agent data) "claude")
             (not (alist-get 'released data)))
    (when-let* ((agent (limen-herdr-claude--agent-for-pane
                        server-key (alist-get 'pane_id data)))
                ((funcall limen-herdr-claude-auto-adopt-predicate agent)))
      (condition-case err
          (limen-herdr-claude-adopt agent server-key)
        (error
         (display-warning 'limen-herdr (error-message-string err) :warning))))))

;;;###autoload
(define-minor-mode limen-herdr-claude-auto-adopt-mode
  "Adopt detected Herdr Claude Code agents into Limen."
  :global t
  :group 'limen-herdr
  (if limen-herdr-claude-auto-adopt-mode
      (progn
        (unless limen-herdr-mode
          (limen-herdr-mode 1))
        (add-hook 'herdr-agent-event-functions
                  #'limen-herdr-claude--maybe-adopt))
    (remove-hook 'herdr-agent-event-functions
                 #'limen-herdr-claude--maybe-adopt)))

(provide 'limen-herdr-claude)
;;; limen-herdr-claude.el ends here
