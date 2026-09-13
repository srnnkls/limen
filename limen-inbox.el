;;; limen-inbox.el --- Pending agent questions in the Herdr dashboard -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Collects the questions agents ask through their user-question tools,
;; as reported by the prompt hooks, and lists the unanswered ones in an
;; Inbox section at the top of `herdr-status'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'magit-section)
(require 'limen-hooks)

(declare-function herdr-status-agent-row "ext:herdr-status" (entry widths workspaces))
(declare-function herdr-status-request-refresh "ext:herdr-status" ())
(defvar herdr-status-sections-functions)

(defcustom limen-inbox-question-tools '("AskUserQuestion" "request_user_input")
  "Tool names whose calls ask the user a question."
  :type '(repeat string)
  :group 'limen-hooks)

(defconst limen-inbox--events
  '(("PreToolUse" . "AskUserQuestion|request_user_input")
    ("PostToolUse" . "AskUserQuestion|request_user_input")
    ("Stop") ("SessionEnd"))
  "Hook events the inbox needs installed, with their tool matcher.")

(defvar limen-inbox--questions nil
  "Pending question entries, oldest first.")

(defun limen-inbox-questions ()
  "Return the pending question entries, oldest first."
  (copy-sequence limen-inbox--questions))

(defun limen-inbox-clear ()
  "Forget every pending question."
  (interactive)
  (setq limen-inbox--questions nil)
  (limen-inbox--refresh))

(defun limen-inbox--refresh ()
  "Redraw the dashboards that show the inbox."
  (when (fboundp 'herdr-status-request-refresh)
    (herdr-status-request-refresh)))

(defun limen-inbox--server (path)
  "Return the canonical server identity for socket PATH, or nil."
  (when (and (stringp path) (not (string-empty-p path)))
    (file-truename (expand-file-name path))))

(defun limen-inbox--question (record)
  "Return the question fields kept from the tool input RECORD."
  `((header . ,(alist-get 'header record))
    (question . ,(alist-get 'question record))
    (options . ,(mapcar (lambda (option) (alist-get 'label option))
                        (append (alist-get 'options record) nil)))
    (multi . ,(eq (alist-get 'multiSelect record) t))
    (other . ,(eq (alist-get 'isOther record) t))))

(defun limen-inbox--entry (payload)
  "Return the inbox entry for the question tool call in PAYLOAD, or nil."
  (let ((questions (alist-get 'questions (alist-get 'tool_input payload)))
        (agent (alist-get 'session_id payload)))
    (when (and (vectorp questions) (> (length questions) 0))
      `((id . ,(or (alist-get 'tool_use_id payload)
                   (format "%s:%s" agent (float-time))))
        (agent_session . ,agent)
        (server . ,(limen-inbox--server (alist-get 'server payload)))
        (pane . ,(alist-get 'pane payload))
        (asked . ,(current-time))
        (questions . ,(mapcar #'limen-inbox--question (append questions nil)))))))

(defun limen-inbox--add (entry)
  "Append ENTRY, replacing an earlier entry with the same id."
  (setq limen-inbox--questions
        (append (seq-remove (lambda (existing)
                              (equal (alist-get 'id existing) (alist-get 'id entry)))
                            limen-inbox--questions)
                (list entry)))
  t)

(defun limen-inbox--remove-if (predicate)
  "Drop the entries satisfying PREDICATE; return non-nil when any did."
  (let ((kept (seq-remove predicate limen-inbox--questions)))
    (prog1 (not (eq (length kept) (length limen-inbox--questions)))
      (setq limen-inbox--questions kept))))

(defun limen-inbox--remove-agent (agent)
  "Drop every entry the agent session AGENT asked."
  (and agent
       (limen-inbox--remove-if
        (lambda (entry) (equal (alist-get 'agent_session entry) agent)))))

(defun limen-inbox--on-event (_provider payload _session _request)
  "Track the question tool call reported by hook PAYLOAD."
  (let ((event (alist-get 'hook_event_name payload))
        (tool (alist-get 'tool_name payload))
        (id (alist-get 'tool_use_id payload))
        (agent (alist-get 'session_id payload)))
    (when (pcase event
            ("PreToolUse"
             (when-let* (((member tool limen-inbox-question-tools))
                         (entry (limen-inbox--entry payload)))
               (limen-inbox--add entry)))
            ("PostToolUse"
             (when (member tool limen-inbox-question-tools)
               (if id
                   (limen-inbox--remove-if
                    (lambda (entry) (equal (alist-get 'id entry) id)))
                 (limen-inbox--remove-agent agent))))
            ((or "UserPromptSubmit" "Stop" "SessionEnd")
             (limen-inbox--remove-agent agent)))
      (limen-inbox--refresh))))

;;; Dashboard section

(defun limen-inbox--agent-for (entry agents)
  "Return the dashboard agent among AGENTS that asked ENTRY, or nil."
  (let ((pane (alist-get 'pane entry))
        (server (alist-get 'server entry)))
    (when (and (stringp pane) (not (string-empty-p pane)))
      (seq-find (lambda (agent)
                  (and (equal (alist-get 'pane_id agent) pane)
                       (equal (limen-inbox--server (alist-get 'server_key agent))
                              server)))
                agents))))

(defun limen-inbox--groups (agents)
  "Return the pending questions grouped by their asking agent among AGENTS.
Entries no listed agent asked are dropped."
  (let (groups)
    (dolist (entry limen-inbox--questions)
      (if-let* ((agent (limen-inbox--agent-for entry agents)))
          (let ((group (assoc agent groups)))
            (if group
                (setcdr group (append (cdr group) (alist-get 'questions entry)))
              (push (cons agent (copy-sequence (alist-get 'questions entry)))
                    groups)))
        (setq limen-inbox--questions (delq entry limen-inbox--questions))))
    (nreverse groups)))

(defun limen-inbox--insert-question (question)
  "Insert QUESTION under its agent row."
  (insert "    "
          (propertize (concat (alist-get 'header question)
                              (if (alist-get 'header question) ": " "")
                              (alist-get 'question question))
                      'font-lock-face 'herdr-status-label)
          (cond ((alist-get 'multi question) "  (multi)")
                ((alist-get 'other question) "  (or other)")
                (t ""))
          "\n")
  (when-let* ((options (alist-get 'options question)))
    (insert "      "
            (propertize (string-join options " · ")
                        'font-lock-face 'herdr-status-meta)
            "\n")))

(defun limen-inbox--insert-section (agents widths _tabs workspaces)
  "Insert the Inbox section for AGENTS on WIDTHS, labelled via WORKSPACES."
  (when-let* ((groups (limen-inbox--groups agents)))
    (magit-insert-section (limen-inbox)
      (magit-insert-heading
        (propertize (format "Inbox %d"
                            (apply #'+ (mapcar (lambda (group) (length (cdr group)))
                                               groups)))
                    'font-lock-face 'magit-section-heading))
      (pcase-dolist (`(,agent . ,questions) groups)
        (magit-insert-section (herdr-status-agent agent)
          (magit-insert-heading (herdr-status-agent-row agent widths workspaces))
          (magit-insert-section-body
            (mapc #'limen-inbox--insert-question questions)))))))

;;;###autoload
(define-minor-mode limen-inbox-mode
  "List agents' pending questions in the Herdr dashboard.
Enabling registers the question hook events and adds them to every
provider whose settings already run Limen's hooks; disabling removes
them again."
  :global t
  :group 'limen-hooks
  (cond
   (limen-inbox-mode
    (dolist (spec limen-inbox--events)
      (add-to-list 'limen-hooks-extra-events spec t))
    (add-hook 'limen-hooks-event-functions #'limen-inbox--on-event)
    (add-hook 'herdr-status-sections-functions #'limen-inbox--insert-section)
    (limen-hooks-complete-installed))
   (t
    (remove-hook 'limen-hooks-event-functions #'limen-inbox--on-event)
    (remove-hook 'herdr-status-sections-functions #'limen-inbox--insert-section)
    (setq limen-hooks-extra-events
          (seq-remove (lambda (spec) (member spec limen-inbox--events))
                      limen-hooks-extra-events))
    (dolist (provider limen-hooks--providers)
      (when (limen-hooks-any-installed-p provider)
        (limen-hooks-remove-events provider (mapcar #'car limen-inbox--events))))
    (setq limen-inbox--questions nil)
    (limen-inbox--refresh))))

(provide 'limen-inbox)
;;; limen-inbox.el ends here
