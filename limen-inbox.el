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
(declare-function herdr-agent-prompt "ext:herdr-agent" (target text))
(defvar herdr-status-sections-functions)

(defcustom limen-inbox-question-tools '("AskUserQuestion" "request_user_input")
  "Tool names whose calls ask the user a question."
  :type '(repeat string)
  :group 'limen-hooks)

(defcustom limen-inbox-transcript-tail-bytes 262144
  "How many bytes from the end of a Codex transcript are scanned for questions."
  :type '(integer 1024)
  :group 'limen-hooks)

(defcustom limen-inbox-settle-seconds 10
  "Seconds a transcript-sourced question is kept before its agent must be blocked.
Herdr detects the question UI on screen a moment after the turn ends."
  :type 'number
  :group 'limen-hooks)

(defcustom limen-inbox-answer nil
  "Whether inbox options are selectable lines that answer into the agent's pane.
When nil the options render as one read-only line.  When non-nil each
option is its own line: RET on a single-select option sends its label to
the agent, and a multi-select question toggles options with circles and
sends the checked labels from its submit line."
  :type 'boolean
  :group 'limen-hooks)

(defconst limen-inbox--events
  '(("PreToolUse" . "AskUserQuestion|request_user_input")
    ("PostToolUse" . "AskUserQuestion|request_user_input")
    ("Stop") ("SessionEnd"))
  "Hook events the inbox needs installed, with their tool matcher.")

(defvar limen-inbox--questions nil
  "Pending question entries, oldest first.")

(defvar limen-inbox--selected (make-hash-table :test 'equal)
  "Chosen labels of each multi-select question, keyed by its qid.")

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

(defun limen-inbox--question (record)
  "Return the question fields kept from the tool input RECORD.
Claude names the text `question' and its options carry a `label';
Codex names it `title' and may list its options as plain strings."
  `((header . ,(alist-get 'header record))
    (question . ,(or (alist-get 'question record) (alist-get 'title record)))
    (options . ,(mapcar (lambda (option)
                          (if (stringp option) option (alist-get 'label option)))
                        (append (alist-get 'options record) nil)))
    (multi . ,(eq (alist-get 'multiSelect record) t))
    (other . ,(eq (alist-get 'isOther record) t))))

(defun limen-inbox--number-questions (id answerable questions)
  "Tag each of QUESTIONS with a stable qid from ID and the ANSWERABLE flag.
The qid is \"ID#INDEX\", so an answer can recover its entry id from it."
  (seq-map-indexed
   (lambda (question index)
     `((qid . ,(format "%s#%d" id index))
       (answerable . ,answerable)
       ,@question))
   questions))

(defun limen-inbox--entry (payload)
  "Return the inbox entry for the question tool call in PAYLOAD, or nil."
  (let* ((questions (alist-get 'questions (alist-get 'tool_input payload)))
         (agent (alist-get 'session_id payload))
         (id (or (alist-get 'tool_use_id payload)
                 (format "%s:%s" agent (float-time)))))
    (when (and (vectorp questions) (> (length questions) 0))
      `((id . ,id)
        (agent_session . ,agent)
        (server . ,(limen-hooks-server-key (alist-get 'server payload)))
        (pane . ,(alist-get 'pane payload))
        (asked . ,(current-time))
        (questions . ,(limen-inbox--number-questions
                       id t (mapcar #'limen-inbox--question
                                    (append questions nil))))))))

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

(defun limen-inbox--transcript-lines (path)
  "Return the complete lines in the tail of the transcript PATH."
  (when (and (stringp path) (file-readable-p path))
    (let* ((size (file-attribute-size (file-attributes path)))
           (start (max 0 (- size limen-inbox-transcript-tail-bytes))))
      (with-temp-buffer
        (insert-file-contents path nil start size)
        (goto-char (point-min))
        (when (> start 0)
          (forward-line 1))
        (split-string (buffer-substring (point) (point-max)) "\n" t)))))

(defun limen-inbox--transcript-call (line turn)
  "Return (CALL-ID . QUESTIONS) when LINE records a question call in TURN."
  (when (string-match-p "request_user_input" line)
    (when-let* ((record (ignore-errors
                          (json-parse-string line :object-type 'alist)))
                (payload (alist-get 'payload record))
                ((equal (alist-get 'type record) "response_item"))
                ((equal (alist-get 'type payload) "function_call"))
                ((string-prefix-p "request_user_input"
                                  (or (alist-get 'name payload) "")))
                (call-turn (alist-get
                            'turn_id
                            (alist-get 'internal_chat_message_metadata_passthrough
                                       payload)
                            turn))
                ((or (null turn) (equal call-turn turn)))
                (arguments (ignore-errors
                             (json-parse-string (alist-get 'arguments payload)
                                                :object-type 'alist)))
                (questions (alist-get 'questions arguments))
                ((vectorp questions))
                ((> (length questions) 0)))
      (cons (alist-get 'call_id payload)
            (mapcar #'limen-inbox--question (append questions nil))))))

(defun limen-inbox--add-transcript-questions (payload)
  "Add the questions the turn ending with hook PAYLOAD asked asynchronously.
Codex answers `request_user_input_async' at once and ends the turn, so
the call only shows in the transcript; return non-nil when any was added."
  (let ((agent (alist-get 'session_id payload))
        (turn (alist-get 'turn_id payload))
        added)
    (dolist (line (limen-inbox--transcript-lines
                   (alist-get 'transcript_path payload)))
      (when-let* ((call (limen-inbox--transcript-call line turn)))
        (let ((id (or (car call) (format "%s:%s" agent (float-time)))))
          (limen-inbox--add
           `((id . ,id)
             (agent_session . ,agent)
             (server . ,(limen-hooks-server-key (alist-get 'server payload)))
             (pane . ,(alist-get 'pane payload))
             (asked . ,(current-time))
             (source . transcript)
             (questions . ,(limen-inbox--number-questions id nil (cdr call))))))
        (setq added t)))
    added))

(defun limen-inbox--on-event (provider payload _session _request)
  "Track the question tool call reported by PROVIDER's hook PAYLOAD."
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
            ("Stop"
             (let ((removed (limen-inbox--remove-agent agent))
                   (added (and (equal provider "codex")
                               (limen-inbox--add-transcript-questions payload))))
               (or removed added)))
            ((or "UserPromptSubmit" "SessionEnd")
             (limen-inbox--remove-agent agent)))
      (limen-inbox--refresh))))

;;; Dashboard section

(defun limen-inbox--agent-for (entry agents)
  "Return the dashboard agent among AGENTS that asked ENTRY, or nil."
  (limen-hooks-agent-for `((pane . ,(alist-get 'pane entry))
                           (server . ,(alist-get 'server entry))
                           (session_id . ,(alist-get 'agent_session entry)))
                         agents))

(defun limen-inbox--stale-p (entry agent)
  "Return non-nil when ENTRY's question is no longer showing in AGENT's pane.
Only transcript-sourced questions have no answering hook; they are stale
once AGENT is not blocked and ENTRY is older than `limen-inbox-settle-seconds'."
  (and (eq (alist-get 'source entry) 'transcript)
       (not (equal (alist-get 'agent_status agent) "blocked"))
       (> (float-time (time-since (alist-get 'asked entry)))
          limen-inbox-settle-seconds)))

(defun limen-inbox--groups (agents)
  "Return the pending questions grouped by their asking agent among AGENTS.
Entries no listed agent asked, or whose question left the screen, are dropped."
  (let (groups)
    (dolist (entry limen-inbox--questions)
      (if-let* ((agent (limen-inbox--agent-for entry agents))
                ((not (limen-inbox--stale-p entry agent))))
          (let ((group (assoc agent groups)))
            (if group
                (setcdr group (append (cdr group) (alist-get 'questions entry)))
              (push (cons agent (copy-sequence (alist-get 'questions entry)))
                    groups)))
        (setq limen-inbox--questions (delq entry limen-inbox--questions))))
    (nreverse groups)))

(defun limen-inbox--entry-id (qid)
  "Return the entry id encoded in QID."
  (car (split-string qid "#")))

(defun limen-inbox--send (target text)
  "Send TEXT to the agent at TARGET; return non-nil when it was sent."
  (cond
   ((not (fboundp 'herdr-agent-prompt))
    (message "herdr-agent is not available") nil)
   ((not target)
    (message "This question has no live agent pane") nil)
   (t (herdr-agent-prompt target text) t)))

(defun limen-inbox--answered (qid)
  "Drop the entry owning QID and its selection, then redraw."
  (remhash qid limen-inbox--selected)
  (let ((id (limen-inbox--entry-id qid)))
    (limen-inbox--remove-if (lambda (entry) (equal (alist-get 'id entry) id))))
  (limen-inbox--refresh))

(defun limen-inbox--toggle (qid label)
  "Toggle LABEL in the chosen set of the question QID."
  (let ((chosen (gethash qid limen-inbox--selected)))
    (puthash qid
             (if (member label chosen)
                 (remove label chosen)
               (append chosen (list label)))
             limen-inbox--selected)))

(defun limen-inbox--value (type)
  "Return the value of the TYPE section at point, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (eq (oref section type) type)))
      (setq section (oref section parent)))
    (and section (oref section value))))

(defun limen-inbox-answer-at-point ()
  "Answer the single-select option at point, or toggle a multi-select one."
  (interactive)
  (let ((value (or (limen-inbox--value 'limen-inbox-option)
                   (user-error "No inbox option at point"))))
    (let ((qid (plist-get value :qid))
          (label (plist-get value :label))
          (target (plist-get value :target)))
      (cond
       ((plist-get value :other)
        (let ((text (read-string "Answer: ")))
          (when (and (not (string-empty-p text)) (limen-inbox--send target text))
            (limen-inbox--answered qid))))
       ((plist-get value :multi)
        (limen-inbox--toggle qid label)
        (limen-inbox--refresh))
       ((limen-inbox--send target label)
        (limen-inbox--answered qid))))))

(defun limen-inbox-submit-at-point ()
  "Send the checked labels of the multi-select question at point."
  (interactive)
  (let ((value (or (limen-inbox--value 'limen-inbox-submit)
                   (user-error "No inbox submit at point"))))
    (let* ((qid (plist-get value :qid))
           (chosen (gethash qid limen-inbox--selected)))
      (if (null chosen)
          (message "No options selected")
        (when (limen-inbox--send (plist-get value :target)
                                 (string-join chosen "\n"))
          (limen-inbox--answered qid))))))

(defvar-keymap magit-limen-inbox-option-section-map
  :doc "Keymap on an inbox option line."
  "RET" #'limen-inbox-answer-at-point)

(defvar-keymap magit-limen-inbox-submit-section-map
  :doc "Keymap on the inbox submit line."
  "RET" #'limen-inbox-submit-at-point)

(defun limen-inbox--insert-options (question target)
  "Insert QUESTION's options as selectable lines answering into TARGET."
  (let* ((qid (alist-get 'qid question))
         (multi (alist-get 'multi question))
         (chosen (gethash qid limen-inbox--selected)))
    (dolist (label (alist-get 'options question))
      (magit-insert-section
          (limen-inbox-option
           (list :qid qid :label label :target target :multi multi))
        (insert "      "
                (if multi (if (member label chosen) "● " "○ ") "")
                (propertize label 'font-lock-face 'herdr-status-meta)
                "\n")))
    (when (alist-get 'other question)
      (magit-insert-section
          (limen-inbox-option (list :qid qid :target target :other t))
        (insert "      "
                (if multi "○ " "")
                (propertize "other…" 'font-lock-face 'herdr-status-meta)
                "\n")))
    (when multi
      (magit-insert-section (limen-inbox-submit (list :qid qid :target target))
        (insert "      "
                (propertize (format "↵ send %d selected" (length chosen))
                            'font-lock-face 'herdr-status-label)
                "\n")))))

(defun limen-inbox--insert-question (question target)
  "Insert QUESTION under its agent row; TARGET answers it, or nil to read only."
  (insert "    "
          (propertize (concat (alist-get 'header question)
                              (if (alist-get 'header question) ": " "")
                              (alist-get 'question question))
                      'font-lock-face 'herdr-status-label)
          (cond ((alist-get 'multi question) "  (multi)")
                ((alist-get 'other question) "  (or other)")
                (t ""))
          "\n")
  (if (and limen-inbox-answer (alist-get 'answerable question))
      (limen-inbox--insert-options question target)
    (when-let* ((options (alist-get 'options question)))
      (insert "      "
              (propertize (string-join options " · ")
                          'font-lock-face 'herdr-status-meta)
              "\n"))))

(defun limen-inbox--agent-target (agent)
  "Return AGENT's (server . terminal) target, or nil when it lacks one."
  (let ((server (alist-get 'server_key agent))
        (terminal (alist-get 'terminal_id agent)))
    (and server terminal (cons server terminal))))

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
        (let ((target (limen-inbox--agent-target agent)))
          (magit-insert-section (herdr-status-agent agent)
            (magit-insert-heading (herdr-status-agent-row agent widths workspaces))
            (magit-insert-section-body
              (dolist (question questions)
                (limen-inbox--insert-question question target)))))))))

;;;###autoload
(define-minor-mode limen-inbox-mode
  "List agents' pending questions in the Herdr dashboard.
Enabling registers the question hook events and requests their install
for every provider, which asks once per provider where they are missing
after the current command; disabling removes the question events again."
  :global t
  :group 'limen-hooks
  (cond
   (limen-inbox-mode
    (dolist (spec limen-inbox--events)
      (add-to-list 'limen-hooks-extra-events spec t))
    (add-hook 'limen-hooks-event-functions #'limen-inbox--on-event)
    (add-hook 'herdr-status-sections-functions #'limen-inbox--insert-section)
    (limen-hooks-request-install "inbox"))
   (t
    (remove-hook 'limen-hooks-event-functions #'limen-inbox--on-event)
    (remove-hook 'herdr-status-sections-functions #'limen-inbox--insert-section)
    (setq limen-hooks-extra-events
          (seq-remove (lambda (spec) (member spec limen-inbox--events))
                      limen-hooks-extra-events))
    (limen-hooks-remove-events-everywhere (mapcar #'car limen-inbox--events))
    (setq limen-inbox--questions nil)
    (clrhash limen-inbox--selected)
    (limen-inbox--refresh))))

(provide 'limen-inbox)
;;; limen-inbox.el ends here
