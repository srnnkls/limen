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
(declare-function herdr-agent-session-server "ext:herdr-agent" (session) t)
(declare-function herdr-agent-session-terminal "ext:herdr-agent" (session) t)
(defvar herdr-agent-event-functions)

(defcustom limen-herdr-claude-auto-adopt-predicate
  #'limen-herdr-claude-known-project-p
  "Predicate deciding whether automatic adoption accepts an agent."
  :type 'function
  :group 'limen-herdr)

(defun limen-herdr-claude-known-project-p (agent)
  "Return non-nil when AGENT's directory is a known project."
  (when-let* ((cwd (alist-get 'cwd agent)))
    (and (file-directory-p cwd) (project-current nil cwd) t)))

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
(cl-defun limen-herdr-claude-adopt (agent &optional server-key display
                                          &key (attach t))
  "Adopt Claude AGENT from optional Herdr SERVER-KEY into Limen.
DISPLAY shows the attached buffer.  ATTACH nil takes the agent up
without opening its terminal, which is what the agent is for; the
terminal follows when something asks to see it."
  (interactive (list (limen-herdr-claude--read-agent "Adopt Herdr Claude: ") nil t))
  (herdr-agent-adopt
   agent :server-key (or server-key (alist-get 'server_key agent))
   :attach attach :display display))

(defun limen-herdr-claude--agent-for-pane (server-key pane-id)
  "Return SERVER-KEY's agent in PANE-ID."
  (cl-find pane-id (herdr-agent-list server-key)
           :key (lambda (agent) (alist-get 'pane_id agent)) :test #'equal))

(defcustom limen-herdr-claude-adopt-quietly t
  "Whether an adopted agent is taken up out of sight and one at a time.
Nobody asked for an automatic adoption, so it claims no window and waits
for an idle moment instead of holding up the event that announced it.
Herdr answers its requests synchronously, so an adoption still stops
Emacs for as long as it takes; what this buys is that a room full of
agents stops it once per agent, with room to type in between, rather
than all at once.  Nil adopts in the event's own turn."
  :type 'boolean
  :group 'limen-herdr)

(defcustom limen-herdr-claude-adopt-interval 0.3
  "Idle seconds between two queued adoptions.
Long enough that a keystroke lands between them, short enough that a
machine left alone works through the queue."
  :type 'number
  :group 'limen-herdr)

(defvar limen-herdr-claude--adopt-queue nil
  "Agents waiting to be adopted, each a cons of the agent and its server.")

(defvar limen-herdr-claude--adopt-timer nil
  "Timer draining `limen-herdr-claude--adopt-queue', or nil when idle.")

(defcustom limen-herdr-claude-adopt-attach nil
  "Whether an automatic adoption also opens the agent's terminal in Emacs.
Opening one costs about a third of a second, and a machine that has been
running a while has a room full of agents, so nothing is opened by
default: the agent is taken up, and its terminal waits until something
asks to see it."
  :type 'boolean
  :group 'limen-herdr)

(defun limen-herdr-claude--adopt-now (agent server-key)
  "Adopt AGENT on SERVER-KEY without taking a window, reporting a failure."
  (condition-case err
      (let ((display-buffer-overriding-action
             (and limen-herdr-claude-adopt-quietly
                  '(display-buffer-no-window (allow-no-window . t)))))
        (limen-herdr-claude-adopt agent server-key nil
                                  :attach limen-herdr-claude-adopt-attach))
    (error
     (display-warning 'limen-herdr (error-message-string err) :warning))))

(defun limen-herdr-claude--drain-adoptions ()
  "Adopt the agent at the head of the queue and come back for the next."
  (setq limen-herdr-claude--adopt-timer nil)
  (when-let* ((next (pop limen-herdr-claude--adopt-queue)))
    (unwind-protect
        (limen-herdr-claude--adopt-now (car next) (cdr next))
      (limen-herdr-claude--schedule-adoptions))))

(defun limen-herdr-claude--schedule-adoptions ()
  "Arrange for the adoption queue to be drained once Emacs is idle."
  (when (and limen-herdr-claude--adopt-queue
             (null limen-herdr-claude--adopt-timer))
    (setq limen-herdr-claude--adopt-timer
          (run-with-idle-timer limen-herdr-claude-adopt-interval nil
                               #'limen-herdr-claude--drain-adoptions))))

(defun limen-herdr-claude--queue-adoption (agent server-key)
  "Put AGENT on SERVER-KEY in line to be adopted, unless it already is."
  (let ((terminal (alist-get 'terminal_id agent)))
    (unless (seq-find (lambda (queued)
                        (equal terminal (alist-get 'terminal_id (car queued))))
                      limen-herdr-claude--adopt-queue)
      (setq limen-herdr-claude--adopt-queue
            (append limen-herdr-claude--adopt-queue
                    (list (cons agent server-key))))
      (limen-herdr-claude--schedule-adoptions))))

(defun limen-herdr-claude--maybe-adopt (server-key type data)
  "Adopt Claude from Herdr event TYPE and DATA on SERVER-KEY.
The attachment stays off screen; nothing you are looking at moves."
  (when (and (equal type "pane.agent_detected")
             (equal (alist-get 'agent data) "claude")
             (not (alist-get 'released data)))
    (when-let* ((agent (limen-herdr-claude--agent-for-pane
                        server-key (alist-get 'pane_id data)))
                ((funcall limen-herdr-claude-auto-adopt-predicate agent)))
      (if limen-herdr-claude-adopt-quietly
          (limen-herdr-claude--queue-adoption agent server-key)
        (limen-herdr-claude--adopt-now agent server-key)))))

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
