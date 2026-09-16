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
(require 'subr-x)
(require 'magit-section)
(require 'limen-hooks)

(declare-function herdr-status-agent-row "ext:herdr-status" (entry widths workspaces))
(declare-function herdr-status-request-refresh "ext:herdr-status" ())
(declare-function herdr-status-redraw-cached "ext:herdr-status" (&optional ready-p))
(declare-function herdr-status-cached-agents "ext:herdr-status" ())
(declare-function herdr-agent-send-keys "ext:herdr-agent" (target keys))
(declare-function herdr-agent-switch "ext:herdr-agent" (target))
(declare-function herdr-agent-paste "ext:herdr-agent" (target text))
(declare-function herdr-agent-read "ext:herdr-agent" (target))
(declare-function cera-read "ext:cera" (table &optional initial bounds source-face))
(defvar herdr-status--refreshing)
(defvar herdr-status-sections-functions)
(defvar herdr-status-preview-rule)

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
option is its own line.  Selection stays local until
`limen-inbox-commit-at-point' commits and advances the question.
Submission requires confirmation."
  :type 'boolean
  :group 'limen-hooks)

(defcustom limen-inbox-inline-notes nil
  "Whether to edit question notes in a Cera inline field.
When nil, use the minibuffer.  When non-nil, Cera must be available.
Accepting the field saves notes locally; it does not commit an answer."
  :type 'boolean
  :group 'limen-hooks)

(defcustom limen-inbox-answer-submit-eagerly nil
  "Whether completing all question commits offers to submit the answers.
When non-nil, any question's commit can offer submission once every
current choice is committed, regardless of tab order.  Confirmation is
required before navigating to Submit and sending the whole block.
When nil, commits only advance to the next tab.  A preview dialog that
submits immediately on Enter must then be answered in the agent window."
  :type 'boolean
  :group 'limen-hooks)

(defun limen-inbox--question-tools ()
  "Return every tool name that asks the user a question."
  (mapcan (lambda (entry) (copy-sequence (limen-provider-question-tools entry)))
          (limen-providers)))

(defconst limen-inbox--events
  (let ((matcher (string-join (limen-inbox--question-tools) "|")))
    `(("PreToolUse" . ,matcher) ("PostToolUse" . ,matcher)
      ("Stop") ("SessionEnd")))
  "Hook events the inbox needs installed, with their tool matcher.")

(defvar limen-inbox--questions nil
  "Pending question entries, oldest first.")

(defvar limen-inbox--selected (make-hash-table :test 'equal)
  "Chosen labels of each multi-select question, keyed by its qid.")

(defvar limen-inbox--sent (make-hash-table :test 'equal)
  "Last committed selections, keyed by question id.")

(defvar limen-inbox--notes (make-hash-table :test 'equal)
  "Per-option note alists, keyed by question id.
Each alist maps 1-based option indices to note text.")

(defvar limen-inbox--sent-notes (make-hash-table :test 'equal)
  "Last committed notes, keyed by question id.")

(defvar limen-inbox--tabs (make-hash-table :test 'equal)
  "Current pane tab index per entry, or `unknown' after a send error.")

(defun limen-inbox-questions ()
  "Return the pending question entries, oldest first."
  (copy-sequence limen-inbox--questions))

(defun limen-inbox-clear ()
  "Forget every pending question."
  (interactive)
  (setq limen-inbox--questions nil)
  (dolist (table (list limen-inbox--selected limen-inbox--sent
                       limen-inbox--notes limen-inbox--sent-notes
                       limen-inbox--tabs))
    (clrhash table))
  (limen-inbox--refresh))

(defun limen-inbox--refresh (&optional entry)
  "Redraw the dashboards that show the inbox.
The inbox changes in Emacs alone, so a dashboard redraws from its last
fetch at once; one whose fetch does not yet list the agent that asked
ENTRY waits for the next fetched refresh, which is where it learns of
the agent."
  (cond
   ((fboundp 'herdr-status-redraw-cached)
    (herdr-status-redraw-cached
     (and entry
          (lambda ()
            (limen-inbox--agent-for entry (herdr-status-cached-agents))))))
   ((fboundp 'herdr-status-request-refresh)
    (herdr-status-request-refresh))))

(defun limen-inbox--question (record)
  "Return the question fields kept from the tool input RECORD.
Claude names the text `question' and its options carry a `label';
Codex names it `title' and may list its options as plain strings."
  `((header . ,(alist-get 'header record))
    (question . ,(or (alist-get 'question record) (alist-get 'title record)))
    (options . ,(mapcar (lambda (option)
                          (if (stringp option) option (alist-get 'label option)))
                        (append (alist-get 'options record) nil)))
    (previews . ,(mapcar (lambda (option)
                           (and (listp option) (alist-get 'preview option)))
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
        (server . ,(limen-server-key (alist-get 'server payload)))
        (pane . ,(alist-get 'pane payload))
        (asked . ,(current-time))
        (questions . ,(limen-inbox--number-questions
                       id t (mapcar #'limen-inbox--question
                                    (append questions nil))))))))

(defun limen-inbox--add (entry)
  "Append ENTRY, replacing an earlier entry with the same id."
  (limen-inbox--remove-if
   (lambda (existing)
     (and (equal (alist-get 'id existing) (alist-get 'id entry))
          (not (equal (alist-get 'questions existing)
                      (alist-get 'questions entry))))))
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
      (dolist (entry (seq-difference limen-inbox--questions kept))
        (remhash (alist-get 'id entry) limen-inbox--tabs)
        (dolist (question (alist-get 'questions entry))
          (remhash (alist-get 'qid question) limen-inbox--selected)
          (remhash (alist-get 'qid question) limen-inbox--sent)
          (remhash (alist-get 'qid question) limen-inbox--notes)
          (remhash (alist-get 'qid question) limen-inbox--sent-notes)))
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
             (server . ,(limen-server-key (alist-get 'server payload)))
             (pane . ,(alist-get 'pane payload))
             (asked . ,(current-time))
             (source . transcript)
             (questions . ,(limen-inbox--number-questions id nil (cdr call))))))
        (setq added t)))
    added))

(defun limen-inbox--asker (payload)
  "Return the fields naming the agent behind hook PAYLOAD, as an entry does."
  `((agent_session . ,(alist-get 'session_id payload))
    (server . ,(limen-server-key (alist-get 'server payload)))
    (pane . ,(alist-get 'pane payload))))

(defun limen-inbox--on-event (provider payload _session _request)
  "Track the question tool call reported by PROVIDER's hook PAYLOAD."
  (let ((event (alist-get 'hook_event_name payload))
        (tool (alist-get 'tool_name payload))
        (id (alist-get 'tool_use_id payload))
        (agent (alist-get 'session_id payload)))
    (pcase (pcase event
             ("PreToolUse"
              (when-let* (((member tool (limen-inbox--question-tools)))
                          (entry (limen-inbox--entry payload)))
                (limen-inbox--add entry)
                'added))
             ("PostToolUse"
              (when (member tool (limen-inbox--question-tools))
                (if id
                    (limen-inbox--remove-if
                     (lambda (entry) (equal (alist-get 'id entry) id)))
                  (limen-inbox--remove-agent agent))))
             ("Stop"
              (let ((removed (limen-inbox--remove-agent agent))
                    (added (and (when-let* ((entry (limen-provider provider)))
                                  (limen-provider-transcript-questions-p entry))
                                (limen-inbox--add-transcript-questions payload))))
                (cond (added 'added) (removed t))))
             ((or "UserPromptSubmit" "SessionEnd")
              (limen-inbox--remove-agent agent)))
      ('nil nil)
      ('added (limen-inbox--refresh (limen-inbox--asker payload)))
      (_ (limen-inbox--refresh)))))

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
        (limen-inbox--remove-if (lambda (candidate) (eq candidate entry)))))
    (nreverse groups)))

(defun limen-inbox--entry-id (qid)
  "Return the entry id encoded in QID."
  (car (split-string qid "#")))

(defcustom limen-inbox-key-delay 0.05
  "Seconds to wait between keys sent to an agent pane.
A burst sent at once drops keys, so each is sent on its own with this
pause in between."
  :type 'number
  :group 'limen-hooks)

(defun limen-inbox--send-keys (target keys id)
  "Send KEYS individually to TARGET for entry ID.
Return non-nil on success.  Mark ID out of sync only if sending fails."
  (cond
   ((not (fboundp 'herdr-agent-send-keys))
    (message "herdr-agent is not available") nil)
   ((not target)
    (message "This question has no live agent pane") nil)
   (t (condition-case err
          (progn
            (dolist (key keys)
              (herdr-agent-send-keys target (list key))
              (sleep-for limen-inbox-key-delay))
            t)
        ((error quit)
         (puthash id 'unknown limen-inbox--tabs)
         (limen-inbox--refresh)
         (signal (car err) (cdr err)))))))

(defun limen-inbox--answered (qid)
  "Drop the entry owning QID and its selection, then redraw."
  (let ((id (limen-inbox--entry-id qid)))
    (limen-inbox--remove-if (lambda (entry) (equal (alist-get 'id entry) id)))
    (remhash id limen-inbox--tabs))
  (dolist (table (list limen-inbox--selected limen-inbox--sent
                       limen-inbox--notes limen-inbox--sent-notes))
    (remhash qid table))
  (limen-inbox--refresh))

(defun limen-inbox--toggle (qid label multi)
  "Choose LABEL for the question QID.
MULTI toggles LABEL in the set; otherwise LABEL becomes the sole choice."
  (let ((chosen (gethash qid limen-inbox--selected)))
    (puthash qid
             (cond ((not multi) (list label))
                   ((member label chosen) (remove label chosen))
                   (t (append chosen (list label))))
             limen-inbox--selected)))

(defun limen-inbox--value (type)
  "Return the value of the TYPE section at point, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (eq (oref section type) type)))
      (setq section (oref section parent)))
    (and section (oref section value))))

(defun limen-inbox--preview-p (question)
  "Return non-nil if QUESTION supports preview notes."
  (and (not (alist-get 'multi question))
       (seq-some #'stringp (alist-get 'previews question))))

(defun limen-inbox--notes-p (notes)
  "Return non-nil if NOTES contain non-whitespace text."
  (and (stringp notes) (not (string-empty-p (string-trim notes)))))

(defun limen-inbox--note-values (qid)
  "Return QID's notes as an alist keyed by option index.
Legacy question notes belong to its selected option or first preview."
  (let ((notes (gethash qid limen-inbox--notes)))
    (if (stringp notes)
        (let* ((question (seq-find (lambda (question)
                                     (equal (alist-get 'qid question) qid))
                                   (limen-inbox--entry-questions
                                    (limen-inbox--entry-id qid))))
               (selected (car (gethash qid limen-inbox--selected)))
               (position (or (and selected
                                  (seq-position (alist-get 'options question)
                                                selected #'equal))
                             (seq-position (alist-get 'previews question)
                                           nil (lambda (preview _) (stringp preview)))
                             0)))
          (list (cons (1+ position) notes)))
      notes)))

(defun limen-inbox--note (qid index)
  "Return the note for QID's option at 1-based INDEX."
  (or (alist-get index (limen-inbox--note-values qid)) ""))

(defun limen-inbox--set-note (qid index text)
  "Set QID's option note at 1-based INDEX to TEXT."
  (let ((notes (copy-tree (limen-inbox--note-values qid))))
    (setf (alist-get index notes) text)
    (puthash qid notes limen-inbox--notes)))

(defun limen-inbox--question-notes (qid &optional options)
  "Combine QID's preview notes, labeled by OPTIONS, in option order.
Legacy question-level text is preserved until its first edit."
  (let ((notes (gethash qid limen-inbox--notes)))
    (if (stringp notes) notes
      (let ((labels (or options
                        (alist-get 'options
                                   (seq-find
                                    (lambda (question) (equal (alist-get 'qid question) qid))
                                    (limen-inbox--entry-questions
                                     (limen-inbox--entry-id qid)))))))
        (string-join
         (seq-keep
          (pcase-lambda (`(,index . ,text))
            (when (limen-inbox--notes-p text)
              (format "%d. %s:\n%s" index
                      (or (nth (1- index) labels) "Option") text)))
          (sort (copy-sequence notes) (lambda (a b) (< (car a) (car b)))))
         "\n\n")))))

(defun limen-inbox--note-index (value)
  "Return the preview option index for question VALUE at point."
  (let* ((option (limen-inbox--value 'limen-inbox-option))
         (previews (plist-get value :previews))
         (selected (car (gethash (plist-get value :qid) limen-inbox--selected)))
         (position (and selected (seq-position (plist-get value :options) selected #'equal)))
         (index (or (plist-get option :index)
                    (and position (stringp (nth position previews)) (1+ position))
                    (when-let* ((first (seq-position previews nil
                                                     (lambda (preview _) (stringp preview)))))
                      (1+ first)))))
    (unless (and index (stringp (nth (1- index) previews)))
      (user-error "This option has no preview to annotate"))
    index))

(defun limen-inbox--committed-p (qid)
  "Return non-nil if QID's current selection and notes are committed."
  (let ((sent (gethash qid limen-inbox--sent 'missing))
        (chosen (gethash qid limen-inbox--selected))
        (notes (limen-inbox--question-notes qid)))
    (and (listp sent) (or chosen (limen-inbox--notes-p notes))
         (null (seq-difference sent chosen #'equal))
         (null (seq-difference chosen sent #'equal))
         (equal notes (gethash qid limen-inbox--sent-notes "")))))

(defun limen-inbox--inline-notes (qid index)
  "Edit QID's option note at INDEX below its preview using Cera."
  (unless (require 'cera nil t)
    (user-error "Inline notes require Cera on load-path"))
  (unless (boundp 'herdr-status--refreshing)
    (user-error "Inline notes require the herdr dashboard refresh guard"))
  (let* ((buffer (current-buffer))
         (id (limen-inbox--entry-id qid))
         (question (copy-tree
                    (seq-find (lambda (question)
                                (equal (alist-get 'qid question) qid))
                              (limen-inbox--entry-questions id))))
         (section (magit-current-section)))
    (while (and section (not (eq (oref section type) 'limen-inbox-question)))
      (setq section (oref section parent)))
    (unless (and section question)
      (user-error "This question is no longer available"))
    (setq section
          (seq-find (lambda (child)
                      (and (eq (oref child type) 'limen-inbox-option)
                           (eql (plist-get (oref child value) :index) index)))
                    (oref section children)))
    (unless section (user-error "This preview is no longer available"))
    (magit-section-show section)
    (let ((bounds (cons (oref section content) (oref section end))))
      (unwind-protect
          (let* ((herdr-status--refreshing t)
                 (notes (cera-read nil (limen-inbox--note qid index) bounds nil)))
            (unless (and (buffer-live-p buffer)
                         (equal question
                                (seq-find (lambda (current)
                                            (equal (alist-get 'qid current) qid))
                                          (limen-inbox--entry-questions id))))
              (user-error "Question changed or disappeared; notes were not saved"))
            (limen-inbox--set-note qid index notes))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (limen-inbox--refresh)
            (when (fboundp 'herdr-status-request-refresh)
              (herdr-status-request-refresh))))))))

(defun limen-inbox-notes-at-point ()
  "Edit notes locally for the preview option at point."
  (interactive)
  (let* ((value (limen-inbox--value 'limen-inbox-question))
         (qid (plist-get value :qid)))
    (unless (plist-get value :preview)
      (user-error "Notes require a single-select question with previews"))
    (let ((index (limen-inbox--note-index value)))
      (if limen-inbox-inline-notes
          (limen-inbox--inline-notes qid index)
        (let ((notes (read-string "Notes: " (limen-inbox--note qid index))))
          (limen-inbox--set-note qid index notes)
          (limen-inbox--refresh))))))

(defun limen-inbox--entry-questions (id)
  "Return the questions belonging to entry ID."
  (alist-get 'questions
             (seq-find (lambda (entry) (equal (alist-get 'id entry) id))
                       limen-inbox--questions)))

(defun limen-inbox--ready-p (id)
  "Return non-nil when every question of entry ID is committed."
  (let ((questions (limen-inbox--entry-questions id)))
    (and questions
         (seq-every-p (lambda (question)
			(limen-inbox--committed-p (alist-get 'qid question)))
                      questions))))

(defun limen-inbox--goto-tab (target id index)
  "Move TARGET's entry ID to tab INDEX from its tracked position."
  (let ((current (gethash id limen-inbox--tabs 0)))
    (when (eq current 'unknown)
      (user-error "Pane position unknown; finish this question in the agent window"))
    (when (limen-inbox--send-keys
           target (make-list (abs (- index current))
                             (if (< index current) "left" "right")) id)
      (puthash id index limen-inbox--tabs)
      t)))

(defun limen-inbox--next-question (qid)
  "Move point to the question section following QID."
  (let ((section (magit-current-section)))
    (while (and section
                (not (and (eq (oref section type) 'limen-inbox-question)
                          (equal (plist-get (oref section value) :qid) qid))))
      (setq section (oref section parent)))
    (when section
      (goto-char (oref section end)))))

(defun limen-inbox-toggle-at-point ()
  "Toggle the inbox option at point in its question's selection."
  (interactive)
  (let ((value (or (limen-inbox--value 'limen-inbox-option)
                   (user-error "No inbox option at point"))))
    (limen-inbox--toggle (plist-get value :qid)
                         (plist-get value :label)
                         (plist-get value :multi))
    (limen-inbox--refresh)))

(defun limen-inbox--screen (target)
  "Read TARGET's current screen without changing pane state."
  (unless (fboundp 'herdr-agent-read)
    (user-error "Update herdr.el to read preview questions"))
  (let ((text (herdr-agent-read target)))
    (unless (stringp text) (user-error "Cannot read the agent screen"))
    text))

(defun limen-inbox--screen-question-p (screen value)
  "Recognize the preview question described by VALUE in SCREEN."
  (let ((question (plist-get value :question)))
    (and question
         (string-match-p "Notes:" screen)
         (string-match-p "Chat about this" screen)
         (string-match-p
          (regexp-quote (replace-regexp-in-string "[[:space:]]+" " " question))
          (replace-regexp-in-string "[[:space:]]+" " " screen)))))

(defun limen-inbox--preview-screen (target value)
  "Read TARGET and verify the preview layout for VALUE."
  (let ((screen (limen-inbox--screen target)))
    (unless (limen-inbox--screen-question-p screen value)
      (user-error "Preview layout not recognized; answer in the agent window"))
    screen))

(defun limen-inbox--preview-submit-tab-p (screen value)
  "Return whether SCREEN's question tabs include Submit for VALUE."
  (let* ((header (plist-get value :header))
         (tabs (and header
                    (seq-find (lambda (line)
                                (and (string-match-p "[☐☑☒✔]" line)
                                     (string-match-p (regexp-quote header) line)))
                              (split-string screen "\n")))))
    (unless tabs
      (user-error "Question tabs not recognized; answer in the agent window"))
    (and (string-match-p "[✔✓][[:space:]]+Submit\\_>" tabs) t)))

(defun limen-inbox--paste-notes (target text id)
  "Paste literal notes TEXT into TARGET, tracking failures for entry ID."
  (condition-case err
      (progn
        (herdr-agent-paste target text)
        (sleep-for limen-inbox-key-delay)
        t)
    ((error quit)
     (puthash id 'unknown limen-inbox--tabs)
     (limen-inbox--refresh)
     (signal (car err) (cdr err)))))

(defun limen-inbox--clear-notes-keys (old)
  "Return keys clearing the known OLD notes from any cursor position."
  (append (make-list (length old) "right")
          '("ctrl+a" "ctrl+k")
          (apply #'append
                 (make-list (cl-count ?\n old)
                            '("backspace" "ctrl+a" "ctrl+k")))))

(defun limen-inbox--preview-answer (target value id keys)
  "Send answering KEYS to TARGET for VALUE and verify the pane advances.
Entry ID is marked out of sync if the old question remains on screen."
  (when (limen-inbox--send-keys target keys id)
    (let ((attempts 0))
      (condition-case err
          (progn
            (while (and (< attempts 10)
                        (limen-inbox--screen-question-p
                         (limen-inbox--screen target) value))
              (cl-incf attempts)
              (sleep-for 0.1))
            (when (= attempts 10)
              (error "Preview answer did not advance; check the agent window"))
            t)
        ((error quit)
         (puthash id 'unknown limen-inbox--tabs)
         (limen-inbox--refresh)
         (signal (car err) (cdr err)))))))

(defun limen-inbox--commit-preview (value)
  "Commit preview VALUE, returning t, nil, or `submitted'."
  (let* ((qid (plist-get value :qid))
         (id (limen-inbox--entry-id qid))
         (index (string-to-number (car (last (split-string qid "#")))))
         (target (plist-get value :target))
         (chosen (copy-sequence (gethash qid limen-inbox--selected)))
         (notes (limen-inbox--question-notes qid (plist-get value :options)))
         (old (gethash qid limen-inbox--sent-notes ""))
         (choice (and chosen (seq-position (plist-get value :options)
                                           (car chosen) #'equal))))
    (unless (or chosen (limen-inbox--notes-p notes))
      (user-error "Select an option or add notes"))
    (when (or (and chosen (null choice)) (and choice (> choice 8)))
      (user-error "Unsupported preview option; answer in the agent window"))
    (when (string-match-p "[\x00-\x08\x0b-\x1f\x7f]" notes)
      (user-error "Notes contain unsupported control characters"))
    (unless (equal notes old)
      (unless (fboundp 'herdr-agent-paste)
        (user-error "Update herdr.el to paste preview notes")))
    (when (limen-inbox--goto-tab target id index)
      (let* ((screen (limen-inbox--preview-screen target value))
             (submit-tab (limen-inbox--preview-submit-tab-p screen value))
             (count (length (limen-inbox--entry-questions id))))
        (unless (or submit-tab (= count 1))
          (user-error "Unexpected question tabs; answer in the agent window"))
        (when (and (string-empty-p old)
                   (not (string-match-p "press n to add notes" screen)))
          (user-error "Pane notes were edited externally; finish in the agent window"))
        (unless (or submit-tab limen-inbox-answer-submit-eagerly)
          (user-error "This question submits immediately; answer in the agent window"))
        (when (or submit-tab (y-or-n-p "Submit all answers? "))
          (if (limen-inbox--committed-p qid)
              (limen-inbox--goto-tab target id (1+ index))
            (unless (equal notes old)
              (limen-inbox--send-keys
               target (append '("n") (limen-inbox--clear-notes-keys old)) id)
              (unless (string-empty-p notes)
                (limen-inbox--paste-notes target notes id))
              (limen-inbox--send-keys target '("escape") id))
            (when (limen-inbox--preview-answer
                   target value id
                   (if choice (list (number-to-string (1+ choice)) "return")
                     '("n" "return")))
              (puthash qid chosen limen-inbox--sent)
              (puthash qid notes limen-inbox--sent-notes)
              (puthash id (1+ index) limen-inbox--tabs)))
          (if submit-tab t
            (limen-inbox--answered qid)
            'submitted))))))

(defun limen-inbox--submit-block (target id)
  "Submit entry ID on TARGET from its Submit tab."
  (if (seq-some #'limen-inbox--preview-p (limen-inbox--entry-questions id))
      (progn
        (unless (string-match-p "Ready to submit your answers?"
                                (limen-inbox--screen target))
          (user-error "Submit screen not recognized; finish in the agent window"))
        (limen-inbox--send-keys target '("return") id))
    (limen-inbox--send-keys target '("return" "return") id)))

(defun limen-inbox-commit-at-point ()
  "Commit the question at point and advance to the next tab.
Revisited questions send only changed choices and notes.  With
`limen-inbox-answer-submit-eagerly', any commit offers submission
when every question has its current answer committed."
  (interactive)
  (let* ((value (or (limen-inbox--value 'limen-inbox-question)
                    (user-error "No inbox question at point")))
         (qid (plist-get value :qid))
         (id (limen-inbox--entry-id qid))
         (index (string-to-number (car (last (split-string qid "#")))))
         (target (plist-get value :target))
         (chosen (gethash qid limen-inbox--selected))
         result)
    (if (plist-get value :preview)
        (setq result (limen-inbox--commit-preview value))
      (unless chosen (user-error "No options selected"))
      (let* ((options (plist-get value :options))
             (sent (gethash qid limen-inbox--sent))
             (changed (if (plist-get value :multi)
                          (append (seq-difference sent chosen #'equal)
                                  (seq-difference chosen sent #'equal))
                        (unless (equal sent chosen) chosen)))
             (keys (seq-keep (lambda (label)
                               (when (member label changed)
                                 (number-to-string
                                  (1+ (seq-position options label #'equal)))))
                             options)))
        (when (and (limen-inbox--goto-tab target id index)
                   (limen-inbox--send-keys target keys id))
          (puthash qid (copy-sequence chosen) limen-inbox--sent)
          (setq result (limen-inbox--goto-tab target id (1+ index))))))
    (when (eq result t)
      (limen-inbox--refresh)
      (cond
       ((and limen-inbox-answer-submit-eagerly
             (limen-inbox--ready-p id)
             (y-or-n-p "Submit all answers? ")
             (limen-inbox--goto-tab
              target id (length (limen-inbox--entry-questions id)))
             (limen-inbox--submit-block target id))
        (limen-inbox--answered qid))
       ((not (plist-get value :last))
        (limen-inbox--next-question qid))))))

(defun limen-inbox-attach-at-point ()
  "Open the agent for the question at point without changing its answers."
  (interactive)
  (let* ((value (or (limen-inbox--value 'limen-inbox-question)
                    (user-error "No inbox question at point")))
         (target (plist-get value :target)))
    (unless target (user-error "This question has no live agent pane"))
    (unless (fboundp 'herdr-agent-switch)
      (user-error "Herdr-agent is not available"))
    (herdr-agent-switch target)))

(defun limen-inbox-dismiss-at-point ()
  "Choose Chat about this for the question at point and open its agent."
  (interactive)
  (let* ((value (or (limen-inbox--value 'limen-inbox-question)
                    (user-error "No inbox question at point")))
         (qid (plist-get value :qid))
         (id (limen-inbox--entry-id qid))
         (index (string-to-number (car (last (split-string qid "#")))))
         (target (plist-get value :target))
         (chat-key (number-to-string (+ 2 (length (plist-get value :options))))))
    (unless (fboundp 'herdr-agent-switch)
      (user-error "Herdr-agent is not available"))
    (when (and (limen-inbox--goto-tab target id index)
               (if (plist-get value :preview)
                   (progn
                     (limen-inbox--preview-screen target value)
                     (limen-inbox--send-keys
                      target (append (make-list (length (plist-get value :options))
                                                "down")
                                     '("return")) id))
                 (limen-inbox--send-keys target (list chat-key) id)))
      (limen-inbox--answered qid)
      (herdr-agent-switch target))))

(defun limen-inbox-toggle-index ()
  "Toggle the option whose number is the digit key that called this."
  (interactive)
  (let* ((value (or (limen-inbox--value 'limen-inbox-question)
                    (user-error "No inbox question at point")))
         (number (- last-command-event ?0))
         (label (nth (1- number) (plist-get value :options))))
    (unless label (user-error "No option %d" number))
    (limen-inbox--toggle (plist-get value :qid) label (plist-get value :multi))
    (limen-inbox--refresh)))

(defvar-keymap magit-limen-inbox-option-section-map
  :doc "Keymap on an inbox option line."
  "RET" #'limen-inbox-toggle-at-point)

(defvar-keymap magit-limen-inbox-question-section-map
  :doc "Keymap on an inbox question tab."
  "RET" #'limen-inbox-attach-at-point
  "C-c C-c" #'limen-inbox-commit-at-point
  "C-c C-d" #'limen-inbox-dismiss-at-point
  "1" #'limen-inbox-toggle-index
  "2" #'limen-inbox-toggle-index
  "3" #'limen-inbox-toggle-index
  "4" #'limen-inbox-toggle-index
  "5" #'limen-inbox-toggle-index
  "6" #'limen-inbox-toggle-index
  "7" #'limen-inbox-toggle-index
  "8" #'limen-inbox-toggle-index
  "9" #'limen-inbox-toggle-index)

(set-keymap-parent magit-limen-inbox-option-section-map
                   magit-limen-inbox-question-section-map)

(defvar-keymap limen-inbox--preview-question-map
  :parent magit-limen-inbox-question-section-map
  "n" #'limen-inbox-notes-at-point)

(defvar-keymap limen-inbox--preview-option-map
  :parent limen-inbox--preview-question-map
  "RET" #'limen-inbox-toggle-at-point)

(dolist (map (list magit-limen-inbox-option-section-map
                   limen-inbox--preview-option-map))
  (keymap-unset map "SPC"))

(defun limen-inbox--insert-preview (preview)
  "Insert PREVIEW literally, preserving line breaks and indentation."
  (when (stringp preview)
    (dolist (line (split-string (substring-no-properties preview) "\n"))
      (insert (propertize "         " 'display '(space :width (+ 9 (7))))
              (propertize (if (boundp 'herdr-status-preview-rule)
                              herdr-status-preview-rule
                            "┃")
                          'font-lock-face 'shadow)
              " " line "\n"))))

(defun limen-inbox--insert-options (qid options multi &optional previews)
  "Insert OPTIONS of QID as circle lines with optional PREVIEWS.
MULTI controls toggling and whether notes are supported."
  (let ((chosen (gethash qid limen-inbox--selected))
        (notes-enabled (and (not multi) (seq-some #'stringp previews))))
    (seq-map-indexed
     (lambda (label index)
       (magit-insert-section section
         (limen-inbox-option
          (list :qid qid :label label :multi multi :index (1+ index)))
         (when notes-enabled
           (oset section keymap 'limen-inbox--preview-option-map))
         (magit-insert-heading
           (format "      %d. " (1+ index))
           (if (member label chosen) "● " "○ ")
           (propertize label 'font-lock-face 'herdr-status-meta))
         (limen-inbox--insert-preview (nth index previews))
         (when (and notes-enabled (stringp (nth index previews)))
           (let ((notes (limen-inbox--note qid (1+ index))))
             (when (limen-inbox--notes-p notes)
               (insert "         Notes: "
                       (replace-regexp-in-string "\n" "\n         " notes) "\n"))))))
     options)))

(defun limen-inbox--question-heading (question)
  "Return QUESTION's header and text as one label line."
  (concat (alist-get 'header question)
          (if (alist-get 'header question) ": " "")
          (alist-get 'question question)))

(defun limen-inbox--insert-question (question target last)
  "Insert QUESTION under its agent row.
With `limen-inbox-answer' and an answerable QUESTION, render a togglable
tab whose options answer into TARGET; LAST submits the whole call.  Any
other case renders the question read-only."
  (let ((qid (alist-get 'qid question))
        (multi (alist-get 'multi question))
        (options (alist-get 'options question))
        (previews (alist-get 'previews question))
        (preview (limen-inbox--preview-p question)))
    (if (not (and limen-inbox-answer (alist-get 'answerable question)))
        (progn
          (insert "    "
                  (propertize (limen-inbox--question-heading question)
                              'font-lock-face 'herdr-status-label)
                  (cond (multi "  (multi)")
                        ((alist-get 'other question) "  (or other)")
                        (t ""))
                  "\n")
          (when options
            (if (seq-some #'stringp previews)
                (seq-map-indexed
                 (lambda (label index)
                   (insert (format "      %d. %s\n" (1+ index) label))
                   (limen-inbox--insert-preview (nth index previews)))
                 options)
              (insert "      "
                      (propertize (string-join options " · ")
                                  'font-lock-face 'herdr-status-meta)
                      "\n"))))
      (magit-insert-section section
        (limen-inbox-question
         (list :qid qid :target target :options options :multi multi
               :previews previews :preview preview :last last
               :header (alist-get 'header question)
               :question (alist-get 'question question)))
        (when preview
          (oset section keymap 'limen-inbox--preview-question-map))
	(magit-insert-heading
	  "    "
	  (propertize (limen-inbox--question-heading question)
		      'font-lock-face 'herdr-status-label)
	  (cond ((eq (gethash (limen-inbox--entry-id qid) limen-inbox--tabs)
		     'unknown)
		 (propertize "  pane out of sync" 'font-lock-face 'warning))
		((limen-inbox--committed-p qid)
		 (propertize "  ✓ sent" 'font-lock-face 'success))
		((not (eq (gethash qid limen-inbox--sent 'missing) 'missing))
		 (propertize "  changed" 'font-lock-face 'warning))
		(multi (propertize "  (multi)" 'font-lock-face 'herdr-status-meta))
		(t "")))
        (limen-inbox--insert-options qid options multi previews)))))

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
	(let ((target (limen-inbox--agent-target agent))
	      (last-qids (limen-inbox--last-qids questions)))
	  (magit-insert-section (herdr-status-agent agent)
	    (magit-insert-heading (herdr-status-agent-row agent widths workspaces))
	    (magit-insert-section-body
	      (dolist (question questions)
		(limen-inbox--insert-question
		 question target
		 (and (member (alist-get 'qid question) last-qids) t))))))))))

(defun limen-inbox--last-qids (questions)
  "Return the qid of the final question of each entry among QUESTIONS."
  (let ((seen (make-hash-table :test 'equal))
        (last nil))
    (dolist (question (reverse questions))
      (let ((id (limen-inbox--entry-id (alist-get 'qid question))))
        (unless (gethash id seen)
          (puthash id t seen)
          (push (alist-get 'qid question) last))))
    last))

;;;###autoload
(define-minor-mode limen-inbox-mode
  "List agents' pending questions in the Herdr dashboard.
Enabling registers the question hook events and requests their install
for every provider, which asks once per provider where they are missing
after the current command.  Disabling stops inbox collection and rendering
without changing provider settings.  Use `limen-hooks-uninstall' to
explicitly remove installed hooks."
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
    (setq limen-inbox--questions nil)
    (clrhash limen-inbox--selected)
    (clrhash limen-inbox--sent)
    (clrhash limen-inbox--notes)
    (clrhash limen-inbox--sent-notes)
    (clrhash limen-inbox--tabs)
    (limen-inbox--refresh))))

(provide 'limen-inbox)
;;; limen-inbox.el ends here
