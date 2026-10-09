;;; limen-herd.el --- Herd notices through agent hooks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tells the members of a Herdr herd what the others do: a member came
;; online, started a prompt, finished one, or exited.  Herdr's own agent
;; states report those for any harness; where a member's hooks reach
;; Emacs they report the same turns earlier and with the prompt text, and
;; a hooked turn silences its state change.  A member receives only the
;; kinds of notice it subscribed to, which its pane label records next to
;; the herd, and `limen-herd-mode' gates the whole thing.  A member
;; mid-turn is not interrupted: its notices wait, and reach it with its
;; next prompt as hook context or as soon as herdr sees it idle.
;;
;; Who hears of an event is up to `limen-herd-audiences' and how it
;; reaches them up to `limen-herd-transports'.  Besides the herd, a herdr
;; workspace marked aware is an audience: its agents learn who else is
;; there and who arrives, only ever through hook context.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'limen-hooks)

(declare-function herdr-herd-dispatch "ext:herdr-herd" ())
(declare-function herdr-herd-live-agents "ext:herdr-herd" (&optional session))
(declare-function herdr-herd-of-entry "ext:herdr-herd" (entry))
(declare-function herdr-herd-member-entries "ext:herdr-herd" (herd &optional agents))
(declare-function herdr-herd-label "ext:herdr-herd" (herd))
(declare-function herdr-herd-label-token "ext:herdr-herd" (label prefix))
(declare-function herdr-herd-label-with-token "ext:herdr-herd" (label prefix value))
(declare-function herdr-herd-notice "ext:herdr-herd" (herd text))
(declare-function herdr-herd-entry-brief "ext:herdr-herd" (entry))
(declare-function herdr-herd--roster-line "ext:herdr-herd" (entry))
(declare-function herdr-herd-at-point "ext:herdr-herd" ())
(declare-function herdr-herd--busy-p "ext:herdr-herd" (entry))
(declare-function herdr-herd--rename "ext:herdr-herd" (entry label))
(declare-function herdr-herd--refresh "ext:herdr-herd" ())
(declare-function herdr-herd--section-value "ext:herdr-herd" (type))
(declare-function herdr-herd--read-session "ext:herdr-herd" (&optional prompt))
(declare-function herdr-herd--read-entries "ext:herdr-herd" (session &optional prompt))
(declare-function herdr-agent-prompt "ext:herdr-agent" (target text))
(declare-function herdr-agent--subscribe-if-live "ext:herdr-agent" (server-key))
(declare-function herdr-all-sessions "ext:herdr" ())
(declare-function herdr-workspaces "ext:herdr" ())
(declare-function herdr-workspace-label "ext:herdr" (directory))
(declare-function herdr-status-refresh "ext:herdr-status" ())
(declare-function herdr-server-key "ext:herdr-core" ())
(declare-function herdr--entry-target "ext:herdr" (entry))
(defvar herdr-herd-protocol-functions)
(defvar herdr-herd-sent-functions)
(defvar herdr-agent-event-functions)
(defvar herdr-session)

(defgroup limen-herd nil
  "Herd notices through agent hooks."
  :group 'limen-hooks
  :prefix "limen-herd-")

(defvar limen-herd-mode)

(defconst limen-herd--kinds '(online prompt finished exited)
  "Every kind of notice a member can subscribe to, in label order.")

(defcustom limen-herd-default-events '(finished exited)
  "Notice kinds the menu's default choice subscribes an agent to."
  :type '(set (const online) (const prompt) (const finished) (const exited))
  :group 'limen-herd)

(defcustom limen-herd-hold-for-busy t
  "Whether a notice for a member mid-turn waits for its next prompt.
Nil drops it instead; a member is never interrupted either way."
  :type 'boolean
  :group 'limen-herd)

(defcustom limen-herd-prompt-length 80
  "Characters of a member's prompt a notice repeats."
  :type '(integer 0)
  :group 'limen-herd)

(defcustom limen-herd-excerpt-length 0
  "Characters of a member's last answer a finished notice repeats.
Zero leaves the answer out."
  :type '(integer 0)
  :group 'limen-herd)

(defcustom limen-herd-quiet-prefixes '("[herd " "/herd ")
  "Openings of prompts that are herd traffic rather than tasks.
A turn one starts ends without a finished notice, so notices never
answer notices.  Keep `herdr-herd-notice-prefix' among them."
  :type '(repeat string)
  :group 'limen-herd)

(defcustom limen-herd-label-prefix "notify:"
  "What opens the label word listing an agent's subscriptions."
  :type 'string
  :group 'limen-herd)

(defcustom limen-herd-fallback-delay 5
  "Seconds a herdr state change waits for a hook to report the same turn.
A hook event of the same kind for the same pane within that time after
the change, or shortly before it, makes the notice instead; none makes
the state change itself the notice, with no prompt text to repeat.  Zero
makes the state change the notice at once unless a hook came first."
  :type 'number
  :group 'limen-herd)

(defcustom limen-herd-audiences
  '(limen-herd-herd-audience limen-herd-workspace-audience)
  "Functions choosing who hears of an agent's event, and how.
Each is called with the event KIND, the sender's entry SELF, the live
AGENTS, and TEXT-FUNCTION, which makes the herd notice from a sender's
name.  It returns a list of (VIA TEXT . RECIPIENTS): VIA names a
transport in `limen-herd-transports', TEXT is what the RECIPIENTS, agent
entries, receive."
  :type '(repeat function)
  :group 'limen-herd)

(defcustom limen-herd-transports
  '((prompt . limen-herd--deliver)
    (hook . limen-herd--whisper))
  "How a notice reaches its recipient, by the name an audience gives.
Each function is called with the recipient's entry and the text.
`prompt' sends it as a prompt once the recipient is free; `hook' adds it
to the context the recipient's next prompt carries, which the user does
not see."
  :type '(alist :key-type symbol :value-type function)
  :group 'limen-herd)

(defcustom limen-herd-workspace-awareness nil
  "Whether the agents of each herdr workspace know of each other.
A workspace toggled on its project dashboard keeps its own setting."
  :type 'boolean
  :group 'limen-herd)

(defcustom limen-herd-workspace-prefix "[workspace] "
  "What opens what an aware workspace tells its agents."
  :type 'string
  :group 'limen-herd)

(defcustom limen-herd-workspace-protocol "\
Reach one: herdr agent prompt <pane> \"<msg>\" (interrupts; `herdr agent
get <pane>' first). Arrivals are announced like this; do not reply."
  "What an agent in an aware workspace is told after who else is there."
  :type 'string
  :group 'limen-herd)

(defconst limen-herd--events '(("Stop") ("SessionEnd"))
  "Hook events the notices need beyond the context ones.")

(defun limen-herd--provider-events ()
  "Return the mid-turn context events, by provider, notices reach agents on."
  (delq nil (mapcar (lambda (provider)
                      (when-let* ((events (limen-provider-turn-context-events
                                           (limen-provider provider))))
                        (cons provider (mapcar #'list events))))
                    (limen-hooks-providers))))

(defvar limen-herd--prompts (make-hash-table :test #'equal)
  "The prompt each agent session is working on and whether it is herd traffic.")

(defvar limen-herd--held (make-hash-table :test #'equal)
  "Notices waiting for each agent session's next prompt.")

(defvar limen-herd--whispers (make-hash-table :test #'equal)
  "Hook-only notices waiting for each agent session's next prompt.")

(defvar limen-herd--overrides (make-hash-table :test #'equal)
  "Workspace labels mapped to `on' or `off', overriding the global setting.")

(defvar limen-herd--labels nil
  "Workspace keys mapped to their labels for the current pass.")

(defvar limen-herd--arrived (make-hash-table :test #'equal)
  "The (SERVER . PANE) keys an aware workspace has introduced.")

(defvar limen-herd--states (make-hash-table :test #'equal)
  "The status herdr last reported for each (SERVER . PANE), with its agent entry.")

(defvar limen-herd--hooked (make-hash-table :test #'equal)
  "When a hook last reported each ((SERVER . PANE) . KIND).")

(defvar limen-herd--timers (make-hash-table :test #'equal)
  "The fallback notice waiting for each ((SERVER . PANE) . KIND).")

(defvar limen-herd--chatter (make-hash-table :test #'equal)
  "The (SERVER . PANE) keys whose current turn a herd prompt started.")

(defvar limen-herd--queue nil
  "Calls left for after the hook or herdr filter returned, newest first.")

(defvar limen-herd--queue-timer nil
  "Timer draining `limen-herd--queue', or nil.")

(defvar limen-herd--draining nil
  "Non-nil while `limen-herd--drain' runs.")

(defvar limen-herd--agents nil
  "The live agents fetched for the current drain pass, or nil.")

;;; Subscriptions

(defun limen-herd-subscriptions (entry)
  "Return the notice kinds the agent of Herdr ENTRY subscribed to."
  (when-let* ((value (herdr-herd-label-token (alist-get 'pane_label entry)
                                             limen-herd-label-prefix)))
    (seq-filter (lambda (kind) (memq kind limen-herd--kinds))
                (mapcar #'intern (split-string value "," t)))))

(defun limen-herd--rename (entry label)
  "Give ENTRY's pane LABEL."
  (herdr-herd--rename entry label))

(defun limen-herd--set-subscriptions (entry kinds)
  "Subscribe ENTRY's agent to exactly KINDS."
  (let ((kinds (seq-filter (lambda (kind) (memq kind kinds)) limen-herd--kinds)))
    (limen-herd--rename entry
                        (herdr-herd-label-with-token
                         (alist-get 'pane_label entry) limen-herd-label-prefix
                         (and kinds (mapconcat #'symbol-name kinds ","))))))

(defun limen-herd-subscribe (entries kinds)
  "Add KINDS to what the agents of ENTRIES receive."
  (dolist (entry entries)
    (limen-herd--set-subscriptions
     entry (append (limen-herd-subscriptions entry) kinds)))
  (herdr-herd--refresh))

(defun limen-herd-unsubscribe (entries kinds)
  "Take KINDS from what the agents of ENTRIES receive."
  (dolist (entry entries)
    (limen-herd--set-subscriptions
     entry (seq-difference (limen-herd-subscriptions entry) kinds)))
  (herdr-herd--refresh))

(defun limen-herd-toggle (entries kind)
  "Flip whether each agent of ENTRIES receives KIND notices."
  (dolist (entry entries)
    (let ((kinds (limen-herd-subscriptions entry)))
      (limen-herd--set-subscriptions
       entry (if (memq kind kinds) (delq kind kinds) (cons kind kinds)))))
  (herdr-herd--refresh))

;;; Notices

(defun limen-herd--clip (text limit)
  "Return the first line of TEXT within LIMIT characters, or nil."
  (when (and (stringp text) (> limit 0))
    (let ((line (string-trim (or (car (split-string text "\n" t)) ""))))
      (unless (string-empty-p line)
        (if (> (length line) limit)
            (concat (substring line 0 (1- limit)) "…")
          line)))))

(defun limen-herd--chatter-p (prompt)
  "Return non-nil when PROMPT is herd traffic rather than a task."
  (and (stringp prompt)
       (seq-some (lambda (prefix) (string-prefix-p prefix prompt))
                 limen-herd-quiet-prefixes)))

(defun limen-herd--agent-name (entry)
  "Return the name a notice gives the agent of ENTRY."
  (or (alist-get 'name entry) (alist-get 'agent entry) "an agent"))

(defun limen-herd--pane-key (server pane)
  "Return the key of the pane PANE on the Herdr socket SERVER, or nil."
  (when (and (stringp pane) (not (string-empty-p pane)))
    (cons (limen-server-key server) pane)))

(defun limen-herd--entry-key (entry)
  "Return the pane key of the Herdr agent ENTRY, or nil."
  (limen-herd--pane-key (alist-get 'server_key entry) (alist-get 'pane_id entry)))

(defun limen-herd--same-pane-p (one other)
  "Return non-nil when agent entries ONE and OTHER run in the same pane."
  (equal (limen-herd--entry-key one) (limen-herd--entry-key other)))

(defun limen-herd--live-agents ()
  "Return the live agents, fetched once per drain pass."
  (when (fboundp 'herdr-herd-live-agents)
    (or limen-herd--agents
        (setq limen-herd--agents (herdr-herd-live-agents)))))

(defun limen-herd-herd-audience (kind self agents text-function)
  "Tell the members of SELF's herd subscribed to KIND, by prompt.
AGENTS are the live agents and TEXT-FUNCTION makes the notice."
  (when-let* ((herd (herdr-herd-of-entry self))
              (recipients
               (seq-filter (lambda (member)
                             (and (not (limen-herd--same-pane-p member self))
                                  (memq kind (limen-herd-subscriptions member))))
                           (herdr-herd-member-entries herd agents))))
    (list (cons 'prompt
                (cons (herdr-herd-notice
                       herd (funcall text-function (limen-herd--agent-name self)))
                      recipients)))))

(defun limen-herd--prompt (member text)
  "Send MEMBER the prompt TEXT and note that its next turn is herd traffic."
  (condition-case err
      (progn
        (herdr-agent-prompt (herdr--entry-target member) text)
        (when-let* ((key (limen-herd--entry-key member)))
          (puthash key t limen-herd--chatter)))
    (error (message "Limen herd: %s" (error-message-string err)))))

(defun limen-herd--hold (table member text)
  "Keep TEXT in TABLE for MEMBER's agent session."
  (when-let* ((id (alist-get 'value (alist-get 'agent_session member))))
    (puthash id (append (gethash id table) (list text)) table)))

(defun limen-herd--deliver (member text)
  "Send MEMBER the notice TEXT now, or hold it until it is free."
  (cond
   ((not (herdr-herd--busy-p member))
    (limen-herd--prompt member text))
   (limen-herd-hold-for-busy
    (limen-herd--hold limen-herd--held member text))))

(defun limen-herd--whisper (member text)
  "Add TEXT to the context MEMBER's next prompt carries."
  (limen-herd--hold limen-herd--whispers member text))

(defun limen-herd--enqueue (function &rest arguments)
  "Call FUNCTION with ARGUMENTS once the current filter has returned.
Calls run in the order they were queued.  One that waits on herdr lets
the next hook in, which only adds to the queue the running drain empties."
  (push (cons function arguments) limen-herd--queue)
  (unless (or limen-herd--draining limen-herd--queue-timer)
    (setq limen-herd--queue-timer (run-at-time 0 nil #'limen-herd--drain))))

(defun limen-herd--drain ()
  "Run the queued calls, sharing one fetch of the live agents per pass."
  (setq limen-herd--queue-timer nil)
  (unless limen-herd--draining
    (let ((limen-herd--draining t))
      (while limen-herd--queue
        (let ((calls (nreverse limen-herd--queue))
              (limen-herd--agents nil)
              (limen-herd--labels nil))
          (setq limen-herd--queue nil)
          (dolist (call calls)
            (condition-case err
                (apply (car call) (cdr call))
              (error (message "Limen herd: %s" (error-message-string err))))))))))

(defun limen-herd--broadcast (payload kind text-function &optional self)
  "Tell every audience of PAYLOAD's agent about its KIND event.
TEXT-FUNCTION receives the sender's name and returns the herd notice.
SELF is the sender's entry where the caller has it."
  (when-let* ((agents (limen-herd--live-agents))
              (self (or self (limen-hooks-agent-for payload agents))))
    (dolist (audience limen-herd-audiences)
      (pcase-dolist (`(,via ,text . ,recipients)
                     (funcall audience kind self agents text-function))
        (let ((transport (or (alist-get via limen-herd-transports)
                             (error "No herd transport %s" via))))
          (dolist (member recipients)
            (funcall transport member text)))))))

(defun limen-herd--take (table id)
  "Return what TABLE holds for agent session ID as one text, forgetting it."
  (when-let* ((held (gethash id table)))
    (remhash id table)
    (string-join held "\n")))

(defun limen-herd--take-held (id)
  "Return every notice waiting for agent session ID's next prompt."
  (when-let* ((texts (delq nil (list (limen-herd--take limen-herd--whispers id)
                                     (limen-herd--take limen-herd--held id)))))
    (string-join texts "\n")))

(defun limen-herd--forget (id)
  "Drop everything kept for agent session ID."
  (remhash id limen-herd--prompts)
  (remhash id limen-herd--held)
  (remhash id limen-herd--whispers))

(defun limen-herd--finished-text (record payload)
  "Return the finished notice as a function of a name.
RECORD is the prompt the turn worked on and PAYLOAD the Stop hook's."
  (let ((prompt (limen-herd--clip (car record) limen-herd-prompt-length))
        (excerpt (limen-herd--clip (alist-get 'last_assistant_message payload)
                                   limen-herd-excerpt-length)))
    (lambda (name)
      (format "%s finished%s.%s" name
              (if prompt (format ": \"%s\"" prompt) " a turn")
              (if excerpt (format " Said: \"%s\"" excerpt) "")))))

(defun limen-herd--hook-seen (payload kind)
  "Note that a hook reported KIND for PAYLOAD's pane, dropping any fallback."
  (when-let* ((key (limen-herd--pane-key (alist-get 'server payload)
                                         (alist-get 'pane payload))))
    (puthash (cons key kind) (float-time) limen-herd--hooked)
    (when-let* ((timer (gethash (cons key kind) limen-herd--timers)))
      (cancel-timer timer)
      (remhash (cons key kind) limen-herd--timers))))

(defun limen-herd--on-event (_provider payload _session _request)
  "Turn PROVIDER's hook PAYLOAD into notices for the agent's herd.
Return the notices held for the agent where the answer carries context,
or nil.  What talks
to herdr is queued, so the hook answers without waiting on it."
  (unless (member '(limen-herd--subscribe) limen-herd--queue)
    (limen-herd--enqueue #'limen-herd--subscribe))
  (let ((id (alist-get 'session_id payload)))
    (pcase (alist-get 'hook_event_name payload)
      ("SessionStart"
       (limen-herd--hook-seen payload 'online)
       (when (member (alist-get 'source payload) '("startup" "resume"))
         (limen-herd--enqueue #'limen-herd--broadcast
                              payload 'online
                              (lambda (name) (format "%s is online." name))))
       nil)
      ("UserPromptSubmit"
       (limen-herd--hook-seen payload 'prompt)
       (let* ((prompt (alist-get 'prompt payload))
              (chatter (limen-herd--chatter-p prompt)))
         (puthash id (cons prompt chatter) limen-herd--prompts)
         (unless chatter
           (when-let* ((clipped (limen-herd--clip prompt limen-herd-prompt-length)))
             (limen-herd--enqueue #'limen-herd--broadcast
                                  payload 'prompt
                                  (lambda (name) (format "%s started: \"%s\"." name clipped)))))
         (and (alist-get 'context payload) (limen-herd--take-held id))))
      ("PostToolUse"
       (and (alist-get 'context payload) (limen-herd--take-held id)))
      ("Stop"
       (limen-herd--hook-seen payload 'finished)
       (let ((record (gethash id limen-herd--prompts)))
         (unless (or (eq (alist-get 'stop_hook_active payload) t) (cdr record))
           (limen-herd--enqueue #'limen-herd--broadcast
                                payload 'finished
                                (limen-herd--finished-text record payload))))
       nil)
      ("SessionEnd"
       (limen-herd--hook-seen payload 'exited)
       (limen-herd--enqueue #'limen-herd--broadcast
                            payload 'exited
                            (lambda (name)
                              (format "%s exited (%s)." name (or (alist-get 'reason payload) "ended"))))
       (limen-herd--enqueue #'limen-herd--forget id)
       nil))))

;;; Herdr state changes

(defun limen-herd--subscribe ()
  "Hear herdr's pane events from every session Emacs may talk to."
  (when (featurep 'herdr-agent)
    (dolist (session (herdr-all-sessions))
      (condition-case nil
          (let ((herdr-session session))
            (herdr-agent--subscribe-if-live (herdr-server-key)))
        (error nil)))))

(defconst limen-herd--hook-lookback 10
  "Seconds before a herdr state change during which a hook counts as its report.")

(defun limen-herd--seed ()
  "Record the status herdr reports now for every live agent, telling nobody."
  (when (fboundp 'herdr-herd-live-agents)
    (condition-case nil
        (dolist (entry (herdr-herd-live-agents))
          (when-let* ((key (limen-herd--entry-key entry)))
            (puthash key (cons (alist-get 'agent_status entry) entry)
                     limen-herd--states)))
      (error nil))))

(defun limen-herd--entry-for (key)
  "Return the live Herdr agent entry of the pane KEY names, or nil."
  (when (fboundp 'herdr-herd-live-agents)
    (condition-case nil
        (limen-hooks-agent-for `((server . ,(car key)) (pane . ,(cdr key)))
                               (herdr-herd-live-agents))
      (error nil))))

(defun limen-herd--transition (previous status)
  "Return the notice kind going from status PREVIOUS to STATUS means, or nil."
  (cond
   ((equal status "unknown") nil)
   ((or (null previous) (equal previous "unknown"))
    (and (member status '("idle" "working" "blocked")) 'online))
   ((equal status "done") 'exited)
   ((and (equal status "working") (equal previous "idle")) 'prompt)
   ((and (equal status "idle") (member previous '("working" "blocked")))
    'finished)))

(defun limen-herd--fallback-text (kind)
  "Return the notice text for KIND as a function of the sender's name."
  (lambda (name)
    (pcase kind
      ('online (format "%s is online." name))
      ('prompt (format "%s started a turn." name))
      ('finished (format "%s finished a turn." name))
      ('exited (format "%s exited." name)))))

(defun limen-herd--fallback (key kind entry started)
  "Send the KIND notice for the pane KEY's agent ENTRY unless a hook did.
STARTED is when herdr reported the change."
  (remhash (cons key kind) limen-herd--timers)
  (let ((hooked (gethash (cons key kind) limen-herd--hooked)))
    (unless (and hooked (>= hooked (- started limen-herd--hook-lookback)))
      (limen-herd--enqueue #'limen-herd--broadcast
                           nil kind (limen-herd--fallback-text kind) entry))))

(defun limen-herd--schedule (key kind entry)
  "Have the KIND notice for the pane KEY's agent ENTRY sent after the delay."
  (when-let* ((timer (gethash (cons key kind) limen-herd--timers)))
    (cancel-timer timer))
  (let ((started (float-time)))
    (if (<= limen-herd-fallback-delay 0)
        (limen-herd--fallback key kind entry started)
      (puthash (cons key kind)
               (run-with-timer limen-herd-fallback-delay nil
                               #'limen-herd--fallback key kind entry started)
               limen-herd--timers))))

(defun limen-herd--flush (entry)
  "Send ENTRY's agent the notices held for it, now that it is free."
  (when-let* ((id (alist-get 'value (alist-get 'agent_session entry)))
              (text (limen-herd--take-held id)))
    (limen-herd--prompt entry text)))

(defun limen-herd--observe (server pane status)
  "Act on herdr reporting STATUS for PANE on the socket SERVER."
  (when-let* ((key (limen-herd--pane-key server pane))
              (previous (gethash key limen-herd--states 'unseen))
              ((not (equal (car-safe previous) status))))
    (let* ((known (and (consp previous) (cdr previous)))
           (entry (or (and (not (equal status "done")) (limen-herd--entry-for key))
                      known))
           (kind (and entry
                      (limen-herd--transition (car-safe previous) status))))
      (if (equal status "done")
          (progn (remhash key limen-herd--states)
                 (remhash key limen-herd--arrived))
        (puthash key (cons status entry) limen-herd--states))
      (when (and kind (gethash key limen-herd--chatter))
        (when (memq kind '(finished exited))
          (remhash key limen-herd--chatter))
        (setq kind nil))
      (when kind
        (limen-herd--schedule key kind entry))
      (when (and entry (member status '("idle" "done")))
        (limen-herd--enqueue #'limen-herd--flush entry)))))

(defun limen-herd--on-herdr-event (server-key type data)
  "Read the agent status out of herdr's TYPE event DATA from SERVER-KEY."
  (pcase type
    ((or "pane.updated" "pane.agent_detected" "pane.moved")
     (let ((pane (or (alist-get 'pane data) data)))
       (when-let* ((status (alist-get 'agent_status pane)))
         (limen-herd--observe server-key (alist-get 'pane_id pane) status))))
    ((or "pane.exited" "pane.closed")
     (limen-herd--observe server-key (alist-get 'pane_id data) "done"))))

(defun limen-herd--on-sent (entry _text)
  "Mark the turn the herd prompt ENTRY just received as herd traffic."
  (when-let* ((key (limen-herd--entry-key entry)))
    (puthash key t limen-herd--chatter)))

(defun limen-herd--reset ()
  "Drop every notice, timer, and remembered state."
  (maphash (lambda (_key timer) (cancel-timer timer)) limen-herd--timers)
  (when limen-herd--queue-timer
    (cancel-timer limen-herd--queue-timer))
  (setq limen-herd--queue nil
        limen-herd--queue-timer nil)
  (dolist (table (list limen-herd--prompts limen-herd--held limen-herd--whispers
                       limen-herd--states limen-herd--hooked limen-herd--timers
                       limen-herd--chatter limen-herd--arrived))
    (clrhash table)))

(defun limen-herd--protocol (_herd)
  "Return the protocol paragraph telling a joining member about notices."
  (format "\
Notices of peers' events (online,prompt,finished,exited) are opt-in by
a pane label word, e.g. `herdr pane rename <pane> \"%sfinished,exited\"'."
          limen-herd-label-prefix))

;;; Aware workspaces

(defun limen-herd--workspace-key (entry)
  "Return the (SERVER . WORKSPACE) key of ENTRY's workspace, or nil."
  (when-let* ((workspace (alist-get 'workspace_id entry)))
    (cons (limen-server-key (alist-get 'server_key entry)) workspace)))

(defun limen-herd--workspace-label (entry)
  "Return the label of ENTRY's workspace, asked of herdr once per pass."
  (when-let* ((key (limen-herd--workspace-key entry)))
    (if-let* ((known (assoc key limen-herd--labels)))
        (cdr known)
      (let ((label (condition-case nil
                       (let ((herdr-session (alist-get 'session entry)))
                         (alist-get 'label
                                    (seq-find (lambda (workspace)
                                                (equal (alist-get 'workspace_id workspace)
                                                       (cdr key)))
                                              (herdr-workspaces))))
                     (error nil))))
        (push (cons key label) limen-herd--labels)
        label))))

(defun limen-herd--label-aware-p (label)
  "Return non-nil when the workspace LABEL names is aware.
Its own setting wins; without one `limen-herd-workspace-awareness' decides."
  (pcase (and label (gethash label limen-herd--overrides))
    ('on t)
    ('off nil)
    (_ limen-herd-workspace-awareness)))

(defun limen-herd-workspace-aware-p (entry)
  "Return non-nil when ENTRY's workspace knows its agents."
  (and (limen-herd--workspace-key entry)
       (limen-herd--label-aware-p (limen-herd--workspace-label entry))))

(defun limen-herd--workspace-peers (entry agents)
  "Return the AGENTS sharing ENTRY's workspace, ENTRY left out."
  (let ((key (limen-herd--workspace-key entry)))
    (seq-filter (lambda (agent)
                  (and (equal (limen-herd--workspace-key agent) key)
                       (not (limen-herd--same-pane-p agent entry))))
                agents)))

(defun limen-herd--workspace-intro (peers)
  "Return what an agent in an aware workspace alongside PEERS is told."
  (concat limen-herd-workspace-prefix
          (if peers
              (concat "Agents here:\n"
                      (mapconcat #'herdr-herd--roster-line peers "\n"))
            "No other agents here yet.")
          "\n" limen-herd-workspace-protocol))

(defun limen-herd--introduce (entry agents)
  "Mark ENTRY introduced and return the peers it shares a workspace with."
  (puthash (limen-herd--entry-key entry) t limen-herd--arrived)
  (limen-herd--workspace-peers entry agents))

(defun limen-herd-workspace-audience (kind self agents _text-function)
  "Introduce SELF arriving in an aware workspace, through hook context.
SELF learns who else is there and they learn of SELF, once per pane.
KIND is the event and AGENTS the live agents."
  (when (and (eq kind 'online)
             (not (gethash (limen-herd--entry-key self) limen-herd--arrived))
             (limen-herd-workspace-aware-p self))
    (let ((peers (limen-herd--introduce self agents)))
      (cons (list 'hook (limen-herd--workspace-intro peers) self)
            (when peers
              (list (cons 'hook
                          (cons (concat limen-herd-workspace-prefix
                                        (herdr-herd-entry-brief self)
                                        " arrived.")
                                peers))))))))

(defun limen-herd--sync-awareness ()
  "Introduce every agent of an aware workspace not introduced yet.
An agent whose workspace is not aware is forgotten, so it is introduced
again once it is."
  (let ((agents (limen-herd--live-agents)))
    (dolist (agent agents)
      (cond
       ((not (limen-herd-workspace-aware-p agent))
        (remhash (limen-herd--entry-key agent) limen-herd--arrived))
       ((not (gethash (limen-herd--entry-key agent) limen-herd--arrived))
        (limen-herd--whisper agent (limen-herd--workspace-intro
                                    (limen-herd--introduce agent agents))))))))

(defun limen-herd--scope-label ()
  "Return the workspace label the dashboard is scoped to, or nil for all."
  (and (derived-mode-p 'herdr-status-mode)
       (bound-and-true-p herdr-status--project-root)
       (herdr-workspace-label herdr-status--project-root)))

(defun limen-herd--awareness-description (&optional label)
  "Return whether LABEL's workspace, or every workspace, is aware."
  (format "awareness: %s %s" (or label "global")
          (if (limen-herd--label-aware-p label) "on" "off")))

(defun limen-herd-toggle-awareness ()
  "Flip whether the agents the dashboard shows know of each other.
A project dashboard flips its own workspace; the global one, and
anywhere else, flips `limen-herd-workspace-awareness', which every
workspace without a setting of its own follows."
  (interactive)
  (unless limen-herd-mode
    (user-error "Needs `limen-herd-mode'"))
  (let ((label (limen-herd--scope-label)))
    (if label
        (puthash label (if (limen-herd--label-aware-p label) 'off 'on)
                 limen-herd--overrides)
      (setq limen-herd-workspace-awareness (not limen-herd-workspace-awareness)))
    (let ((limen-herd--agents nil)
          (limen-herd--labels nil))
      (limen-herd--sync-awareness))
    (message "%s" (limen-herd--awareness-description label))))

(defun limen-herd--attach-dashboard ()
  "Bind `A' on the dashboard and list it in the dashboard's menu."
  (when (boundp 'herdr-status-mode-map)
    (define-key herdr-status-mode-map "A" #'limen-herd-toggle-awareness))
  (when (and (limen-herd--prefix-loaded-p 'herdr-status-dispatch)
             (not (ignore-errors (transient-get-suffix 'herdr-status-dispatch "A"))))
    (transient-append-suffix 'herdr-status-dispatch "h"
      '("A" limen-herd-toggle-awareness
        :description (lambda ()
                       (limen-herd--awareness-description
                        (limen-herd--scope-label)))))))

(defun limen-herd--detach-dashboard ()
  "Take `A' off the dashboard and out of its menu."
  (when (and (boundp 'herdr-status-mode-map)
             (eq (lookup-key herdr-status-mode-map "A") #'limen-herd-toggle-awareness))
    (define-key herdr-status-mode-map "A" nil))
  (when (and (limen-herd--prefix-loaded-p 'herdr-status-dispatch)
             (ignore-errors (transient-get-suffix 'herdr-status-dispatch "A")))
    (transient-remove-suffix 'herdr-status-dispatch "A")))

;;; Menu

(defun limen-herd--entry-at-point ()
  "Return the agent entry point is on in a dashboard, or nil."
  (and (featurep 'herdr-herd)
       (derived-mode-p 'herdr-status-mode)
       (herdr-herd--section-value 'herdr-status-agent)))

(defun limen-herd--targets ()
  "Return the agent entries the menu acts on."
  (or (when-let* ((entry (limen-herd--entry-at-point))) (list entry))
      (herdr-herd--read-entries (herdr-herd--read-session))))

(defun limen-herd--herd-targets ()
  "Return every member of the herd at point."
  (herdr-herd-member-entries
   (or (herdr-herd-at-point) (user-error "No herd at point"))))

(defun limen-herd--dispatch-description ()
  "Return the menu heading naming the agent at point and its subscriptions."
  (if-let* ((entry (limen-herd--entry-at-point)))
      (let ((name (limen-herd--agent-name entry))
            (herd (herdr-herd-of-entry entry)))
        (if herd
            (format "notices  ·  %s in herd %s receives %s" name
                    (herdr-herd-label herd)
                    (if-let* ((kinds (limen-herd-subscriptions entry)))
                        (mapconcat #'symbol-name kinds ", ")
                      "none"))
          (format "notices  ·  %s is in no herd" name)))
    "notices  ·  agents from the region or by completion"))

(defun limen-herd--kind-description (kind)
  "Return KIND with a mark saying whether the agent at point receives it."
  (let ((entry (limen-herd--entry-at-point)))
    (format "%s %s"
            (if (and entry (memq kind (limen-herd-subscriptions entry))) "[x]" "[ ]")
            kind)))

(defmacro limen-herd--define-toggle (kind)
  "Define the command flipping KIND for the menu's targets."
  `(defun ,(intern (format "limen-herd-toggle-%s" kind)) (entries)
     ,(format "Flip whether the agents of ENTRIES receive %s notices." kind)
     (interactive (list (limen-herd--targets)))
     (limen-herd-toggle entries ',kind)))

(limen-herd--define-toggle online)
(limen-herd--define-toggle prompt)
(limen-herd--define-toggle finished)
(limen-herd--define-toggle exited)

(defun limen-herd-subscribe-all (entries)
  "Subscribe the agents of ENTRIES to every notice kind."
  (interactive (list (limen-herd--targets)))
  (limen-herd-subscribe entries limen-herd--kinds))

(defun limen-herd-unsubscribe-all (entries)
  "Subscribe the agents of ENTRIES to no notice."
  (interactive (list (limen-herd--targets)))
  (limen-herd-unsubscribe entries limen-herd--kinds))

(defun limen-herd-subscribe-defaults (entries)
  "Subscribe the agents of ENTRIES to exactly `limen-herd-default-events'."
  (interactive (list (limen-herd--targets)))
  (dolist (entry entries)
    (limen-herd--set-subscriptions entry limen-herd-default-events))
  (herdr-herd--refresh))

(defun limen-herd-herd-subscribe-all ()
  "Subscribe every member of the herd at point to every notice kind."
  (interactive)
  (limen-herd-subscribe-all (limen-herd--herd-targets)))

(defun limen-herd-herd-unsubscribe-all ()
  "Subscribe every member of the herd at point to no notice."
  (interactive)
  (limen-herd-unsubscribe-all (limen-herd--herd-targets)))

(defun limen-herd-herd-subscribe-defaults ()
  "Subscribe every member of the herd at point to `limen-herd-default-events'."
  (interactive)
  (limen-herd-subscribe-defaults (limen-herd--herd-targets)))

;;;###autoload (autoload 'limen-herd-dispatch "limen-herd" nil t)
(transient-define-prefix limen-herd-dispatch ()
  "Choose the herd notices agents receive."
  [:description
   limen-herd--dispatch-description
   ["Toggle"
    ("o" limen-herd-toggle-online :transient t
     :description (lambda () (limen-herd--kind-description 'online)))
    ("p" limen-herd-toggle-prompt :transient t
     :description (lambda () (limen-herd--kind-description 'prompt)))
    ("f" limen-herd-toggle-finished :transient t
     :description (lambda () (limen-herd--kind-description 'finished)))
    ("x" limen-herd-toggle-exited :transient t
     :description (lambda () (limen-herd--kind-description 'exited)))]
   ["Set"
    ("a" "all" limen-herd-subscribe-all :transient t)
    ("n" "none" limen-herd-unsubscribe-all :transient t)
    ("d" "defaults" limen-herd-subscribe-defaults :transient t)]
   ["Whole herd"
    ("A" "all" limen-herd-herd-subscribe-all :transient t)
    ("N" "none" limen-herd-herd-unsubscribe-all :transient t)
    ("D" "defaults" limen-herd-herd-subscribe-defaults :transient t)]
])

(defun limen-herd--prefix-loaded-p (prefix)
  "Return non-nil when the transient PREFIX is defined, not merely autoloaded."
  (and (fboundp prefix) (get prefix 'transient--prefix) t))

(defun limen-herd--attach-menu ()
  "Reach the menu from the herd menu."
  (when (and (limen-herd--prefix-loaded-p 'herdr-herd-dispatch)
             (not (ignore-errors (transient-get-suffix 'herdr-herd-dispatch "n"))))
    (transient-append-suffix 'herdr-herd-dispatch "R"
      '("n" "notices" limen-herd-dispatch))))

(defun limen-herd--detach-menu ()
  "Take the menu out of the herd menu again."
  (when (and (limen-herd--prefix-loaded-p 'herdr-herd-dispatch)
             (eq (plist-get (cdr (ignore-errors
                                   (transient-get-suffix 'herdr-herd-dispatch "n")))
                            :command)
                 'limen-herd-dispatch))
    (transient-remove-suffix 'herdr-herd-dispatch "n")))

(defun limen-herd--start ()
  "Record the agents herdr reports and introduce those of aware workspaces.
An agent recorded here is never taken for an arrival later."
  (limen-herd--seed)
  (limen-herd--enqueue #'limen-herd--sync-awareness))

(defun limen-herd--attach-when-loaded ()
  "Attach the menus once the dashboard and herd packages are loaded."
  (limen-herd--attach-menu)
  (limen-herd--attach-dashboard)
  (with-eval-after-load 'herdr-herd
    (when limen-herd-mode (limen-herd--attach-menu)))
  (with-eval-after-load 'herdr-status
    (when limen-herd-mode (limen-herd--attach-dashboard))))

;;;###autoload
(define-minor-mode limen-herd-mode
  "Tell herd members what the others do, as their hooks report it.
Enabling subscribes the turn hook events, which asks once per provider
where they are missing after the current command; a member still
receives nothing until it subscribes, through the `n' menu of the
dashboard.  Agents of an aware workspace are introduced to each other,
and `A' on the dashboard toggles awareness for its scope.  Disabling
removes the events again where nothing else needs them."
  :global t
  :group 'limen-herd
  (cond
   (limen-herd-mode
    (add-hook 'herdr-herd-protocol-functions #'limen-herd--protocol)
    (add-hook 'herdr-herd-sent-functions #'limen-herd--on-sent)
    (add-hook 'herdr-agent-event-functions #'limen-herd--on-herdr-event)
    (limen-herd--subscribe)
    (limen-herd--attach-when-loaded)
    (limen-hooks-subscribe "herd" :events limen-herd--events
                           :provider-events (limen-herd--provider-events)
                           :function #'limen-herd--on-event)
    (with-eval-after-load 'herdr-herd
      (when limen-herd-mode (limen-herd--start))))
   (t
    (remove-hook 'herdr-herd-protocol-functions #'limen-herd--protocol)
    (remove-hook 'herdr-herd-sent-functions #'limen-herd--on-sent)
    (remove-hook 'herdr-agent-event-functions #'limen-herd--on-herdr-event)
    (limen-herd--detach-menu)
    (limen-herd--detach-dashboard)
    (limen-hooks-unsubscribe "herd")
    (limen-herd--reset))))

(provide 'limen-herd)
;;; limen-herd.el ends here
