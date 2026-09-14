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

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'limen-hooks)

(declare-function herdr-herd-live-agents "ext:herdr-herd" (&optional session))
(declare-function herdr-herd-of-entry "ext:herdr-herd" (entry))
(declare-function herdr-herd-member-entries "ext:herdr-herd" (herd &optional agents))
(declare-function herdr-herd-label "ext:herdr-herd" (herd))
(declare-function herdr-herd-label-token "ext:herdr-herd" (label prefix))
(declare-function herdr-herd-label-with-token "ext:herdr-herd" (label prefix value))
(declare-function herdr-herd-notice "ext:herdr-herd" (herd text))
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
(declare-function herdr-server-key "ext:herdr-core" ())
(declare-function herdr--entry-target "ext:herdr" (entry))
(defvar herdr-herd-protocol-functions)
(defvar herdr-herd-sent-functions)
(defvar herdr-agent-event-functions)
(defvar herdr-session)
(defvar herdr-status-mode-map)

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

(defcustom limen-herd-prompt-length 120
  "Characters of a member's prompt a notice repeats."
  :type '(integer 0)
  :group 'limen-herd)

(defcustom limen-herd-excerpt-length 160
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

(defconst limen-herd--events '(("Stop") ("SessionEnd"))
  "Hook events the notices need beyond the context ones.")

(defvar limen-herd--prompts (make-hash-table :test #'equal)
  "The prompt each agent session is working on and whether it is herd traffic.")

(defvar limen-herd--held (make-hash-table :test #'equal)
  "Notices waiting for each agent session's next prompt.")

(defvar limen-herd--names (make-hash-table :test #'equal)
  "The name each agent session's harness gave it.")

(defvar limen-herd--states (make-hash-table :test #'equal)
  "The status herdr last reported for each (SERVER . PANE), with its agent entry.")

(defvar limen-herd--hooked (make-hash-table :test #'equal)
  "When a hook last reported each ((SERVER . PANE) . KIND).")

(defvar limen-herd--timers (make-hash-table :test #'equal)
  "The fallback notice waiting for each ((SERVER . PANE) . KIND).")

(defvar limen-herd--chatter (make-hash-table :test #'equal)
  "The (SERVER . PANE) keys whose current turn a herd prompt started.")

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

(defun limen-herd--claude-session-name (id)
  "Return the name Claude Code gave session ID, or nil."
  (let ((directory (expand-file-name "sessions" (limen-claude-config-directory))))
    (when (file-directory-p directory)
      (seq-some (lambda (file)
                  (condition-case nil
                      (let ((record (with-temp-buffer
                                      (insert-file-contents file)
                                      (json-parse-buffer :object-type 'alist))))
                        (and (equal (alist-get 'sessionId record) id)
                             (let ((name (alist-get 'name record)))
                               (and (stringp name) (not (string-empty-p name))
                                    name))))
                    (error nil)))
                (directory-files directory t "\\.json\\'")))))

(defun limen-herd--session-name (provider id)
  "Return the name PROVIDER gave agent session ID, or nil."
  (or (gethash (cons provider id) limen-herd--names)
      (when (and (equal provider "claude") (stringp id))
        (when-let* ((name (limen-herd--claude-session-name id)))
          (puthash (cons provider id) name limen-herd--names)))))

(defun limen-herd--session-suffix (provider id)
  "Return what names PROVIDER's session ID in a notice, or an empty string."
  (if-let* ((name (limen-herd--session-name provider id)))
      (format " (%s session %s)" provider name)
    ""))

(defun limen-herd--agent-name (entry)
  "Return the name a notice gives the agent of ENTRY."
  (or (alist-get 'name entry) (alist-get 'agent entry) "an agent"))

(defun limen-herd--pane-key (server pane)
  "Return the key of the pane PANE on the Herdr socket SERVER, or nil."
  (when (and (stringp pane) (not (string-empty-p pane)))
    (cons (limen-hooks-server-key server) pane)))

(defun limen-herd--entry-key (entry)
  "Return the pane key of the Herdr agent ENTRY, or nil."
  (limen-herd--pane-key (alist-get 'server_key entry) (alist-get 'pane_id entry)))

(defun limen-herd--recipients (payload kind &optional self)
  "Return the herd, the sender, and the members to tell about KIND for PAYLOAD.
SELF is the sender's entry where the caller has it, else PAYLOAD names it.
Nil where the sender is in no herd or nobody subscribed."
  (when (featurep 'herdr-herd)
    (when-let* ((agents (herdr-herd-live-agents))
                (self (or self (limen-hooks-agent-for payload agents)))
                (herd (herdr-herd-of-entry self))
                (recipients
                 (seq-filter (lambda (member)
                               (and (not (and (equal (alist-get 'pane_id member)
                                                     (alist-get 'pane_id self))
                                              (equal (alist-get 'server_key member)
                                                     (alist-get 'server_key self))))
                                    (memq kind (limen-herd-subscriptions member))))
                             (herdr-herd-member-entries herd agents))))
      (list herd self recipients))))

(defun limen-herd--prompt (member text)
  "Send MEMBER the prompt TEXT and note that its next turn is herd traffic."
  (condition-case err
      (progn
        (herdr-agent-prompt (herdr--entry-target member) text)
        (when-let* ((key (limen-herd--entry-key member)))
          (puthash key t limen-herd--chatter)))
    (error (message "Limen herd: %s" (error-message-string err)))))

(defun limen-herd--deliver (member text)
  "Send MEMBER the notice TEXT now, or hold it until it is free."
  (cond
   ((not (herdr-herd--busy-p member))
    (limen-herd--prompt member text))
   (limen-herd-hold-for-busy
    (when-let* ((id (alist-get 'value (alist-get 'agent_session member))))
      (puthash id (append (gethash id limen-herd--held) (list text))
               limen-herd--held)))))

(defun limen-herd--broadcast (payload kind text-function &optional self)
  "Send KIND's subscribers a notice about PAYLOAD's agent from TEXT-FUNCTION.
TEXT-FUNCTION receives the sender's name and returns the notice text.
SELF is the sender's entry where the caller has it."
  (pcase-let ((`(,herd ,self ,recipients)
               (limen-herd--recipients payload kind self)))
    (when recipients
      (let ((text (herdr-herd-notice
                   herd (funcall text-function (limen-herd--agent-name self)))))
        (dolist (member recipients)
          (limen-herd--deliver member text))))))

(defun limen-herd--take-held (id)
  "Return the notices waiting for agent session ID as one text, forgetting them."
  (when-let* ((held (gethash id limen-herd--held)))
    (remhash id limen-herd--held)
    (string-join held "\n")))

(defun limen-herd--forget (provider id)
  "Drop everything kept for PROVIDER's agent session ID."
  (remhash id limen-herd--prompts)
  (remhash id limen-herd--held)
  (remhash (cons provider id) limen-herd--names))

(defun limen-herd--finished-text (provider id record payload)
  "Return the finished notice of PROVIDER's session ID as a function of a name.
RECORD is the prompt the turn worked on and PAYLOAD the Stop hook's."
  (let ((prompt (limen-herd--clip (car record) limen-herd-prompt-length))
        (excerpt (limen-herd--clip (alist-get 'last_assistant_message payload)
                                   limen-herd-excerpt-length))
        (suffix (limen-herd--session-suffix provider id)))
    (lambda (name)
      (format "%s finished%s%s.%s" name
              (if prompt (format ": \"%s\"" prompt) " a turn")
              suffix
              (if excerpt (format " Said: \"%s\"" excerpt) "")))))

(defun limen-herd--hook-seen (payload kind)
  "Note that a hook reported KIND for PAYLOAD's pane, dropping any fallback."
  (when-let* ((key (limen-herd--pane-key (alist-get 'server payload)
                                         (alist-get 'pane payload))))
    (puthash (cons key kind) (float-time) limen-herd--hooked)
    (when-let* ((timer (gethash (cons key kind) limen-herd--timers)))
      (cancel-timer timer)
      (remhash (cons key kind) limen-herd--timers))))

(defun limen-herd--on-event (provider payload _session _request)
  "Turn PROVIDER's hook PAYLOAD into notices for the agent's herd.
Return the notices held for the agent on a prompt, or nil."
  (limen-herd--subscribe)
  (let ((id (alist-get 'session_id payload)))
    (pcase (alist-get 'hook_event_name payload)
      ("SessionStart"
       (limen-herd--hook-seen payload 'online)
       (when (member (alist-get 'source payload) '("startup" "resume"))
         (limen-herd--broadcast
          payload 'online
          (lambda (name)
            (format "%s is online%s." name
                    (limen-herd--session-suffix provider id)))))
       nil)
      ("UserPromptSubmit"
       (limen-herd--hook-seen payload 'prompt)
       (let* ((prompt (alist-get 'prompt payload))
              (chatter (limen-herd--chatter-p prompt)))
         (puthash id (cons prompt chatter) limen-herd--prompts)
         (unless chatter
           (when-let* ((clipped (limen-herd--clip prompt limen-herd-prompt-length)))
             (limen-herd--broadcast
              payload 'prompt
              (lambda (name) (format "%s started: \"%s\"." name clipped)))))
         (limen-herd--take-held id)))
      ("Stop"
       (limen-herd--hook-seen payload 'finished)
       (let ((record (gethash id limen-herd--prompts)))
         (unless (or (eq (alist-get 'stop_hook_active payload) t) (cdr record))
           (limen-herd--broadcast
            payload 'finished
            (limen-herd--finished-text provider id record payload))))
       nil)
      ("SessionEnd"
       (limen-herd--hook-seen payload 'exited)
       (limen-herd--broadcast
        payload 'exited
        (lambda (name)
          (format "%s exited (%s)." name (or (alist-get 'reason payload) "ended"))))
       (limen-herd--forget provider id)
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
      (limen-herd--broadcast nil kind (limen-herd--fallback-text kind) entry))))

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
          (remhash key limen-herd--states)
        (puthash key (cons status entry) limen-herd--states))
      (when (and kind (gethash key limen-herd--chatter))
        (when (memq kind '(finished exited))
          (remhash key limen-herd--chatter))
        (setq kind nil))
      (when kind
        (limen-herd--schedule key kind entry))
      (when (and entry (member status '("idle" "done")))
        (limen-herd--flush entry)))))

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
  (dolist (table (list limen-herd--prompts limen-herd--held limen-herd--names
                       limen-herd--states limen-herd--hooked limen-herd--timers
                       limen-herd--chatter))
    (clrhash table)))

(defun limen-herd--protocol (_herd)
  "Return the protocol paragraph telling a joining member about notices."
  (format "\
Herd notices are opt-in per member: a `%sKINDS' word on your pane
label, such as `%sfinished,exited', selects which of your peers'
events reach you — online, prompt (a peer started a task), finished (a
peer's turn ended, with its prompt), exited. Set it with `herdr pane
rename <pane> \"herd:<name> %sfinished,exited\"'. A notice opens with
`[herd <name>]' and needs no reply."
          limen-herd-label-prefix limen-herd-label-prefix limen-herd-label-prefix))

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
    ("D" "defaults" limen-herd-herd-subscribe-defaults :transient t)]])

(defun limen-herd--prefix-loaded-p (prefix)
  "Return non-nil when the transient PREFIX is defined, not merely autoloaded."
  (and (fboundp prefix) (get prefix 'transient--prefix) t))

(defun limen-herd--attach-menu ()
  "Reach the menu from the dashboard and the herd menu."
  (when (and (limen-herd--prefix-loaded-p 'herdr-status-dispatch)
             (not (ignore-errors (transient-get-suffix 'herdr-status-dispatch "n"))))
    (transient-append-suffix 'herdr-status-dispatch "h"
      '("n" "notices" limen-herd-dispatch)))
  (when (boundp 'herdr-status-mode-map)
    (define-key herdr-status-mode-map "n" #'limen-herd-dispatch))
  (when (and (limen-herd--prefix-loaded-p 'herdr-herd-dispatch)
             (not (ignore-errors (transient-get-suffix 'herdr-herd-dispatch "n"))))
    (transient-append-suffix 'herdr-herd-dispatch "R"
      '("n" "notices" limen-herd-dispatch))))

(defun limen-herd--detach-menu ()
  "Take the menu out of the dashboard and the herd menu again."
  (dolist (prefix '(herdr-status-dispatch herdr-herd-dispatch))
    (when (and (limen-herd--prefix-loaded-p prefix)
               (ignore-errors (transient-get-suffix prefix "n")))
      (transient-remove-suffix prefix "n")))
  (when (and (boundp 'herdr-status-mode-map)
             (eq (lookup-key herdr-status-mode-map "n") #'limen-herd-dispatch))
    (define-key herdr-status-mode-map "n" nil)))

(defun limen-herd--attach-when-loaded ()
  "Attach the menu once the dashboard and herd packages are loaded."
  (limen-herd--attach-menu)
  (with-eval-after-load 'herdr-status
    (when limen-herd-mode (limen-herd--attach-menu)))
  (with-eval-after-load 'herdr-herd
    (when limen-herd-mode (limen-herd--attach-menu))))

;;;###autoload
(define-minor-mode limen-herd-mode
  "Tell herd members what the others do, as their hooks report it.
Enabling registers the turn hook events and requests their install for
every provider, which asks once per provider where they are missing
after the current command; a member still receives nothing until it
subscribes, through the `n' menu of the dashboard.  Disabling removes
the events again where nothing else needs them."
  :global t
  :group 'limen-herd
  (cond
   (limen-herd-mode
    (dolist (spec limen-herd--events)
      (add-to-list 'limen-hooks-extra-events spec t))
    (add-hook 'limen-hooks-event-functions #'limen-herd--on-event)
    (add-hook 'herdr-herd-protocol-functions #'limen-herd--protocol)
    (add-hook 'herdr-herd-sent-functions #'limen-herd--on-sent)
    (add-hook 'herdr-agent-event-functions #'limen-herd--on-herdr-event)
    (limen-herd--seed)
    (limen-herd--subscribe)
    (limen-herd--attach-when-loaded)
    (limen-hooks-request-install "herd"))
   (t
    (remove-hook 'limen-hooks-event-functions #'limen-herd--on-event)
    (remove-hook 'herdr-herd-protocol-functions #'limen-herd--protocol)
    (remove-hook 'herdr-herd-sent-functions #'limen-herd--on-sent)
    (remove-hook 'herdr-agent-event-functions #'limen-herd--on-herdr-event)
    (limen-herd--detach-menu)
    (setq limen-hooks-extra-events
          (seq-remove (lambda (spec) (member spec limen-herd--events))
                      limen-hooks-extra-events))
    (limen-hooks-remove-events-everywhere (mapcar #'car limen-herd--events))
    (limen-herd--reset))))

(provide 'limen-herd)
;;; limen-herd.el ends here
