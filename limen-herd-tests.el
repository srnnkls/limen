;;; limen-herd-tests.el --- Herd notice tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'limen-herd)

(defvar herdr-herd-protocol-functions)
(defvar herdr-herd-sent-functions)
(defvar herdr-agent-event-functions)
(defvar herdr-entries-in-scope-function)

(defun limen-herd-tests--entry (name &rest keys)
  "Return a Herdr agent entry called NAME.
KEYS may set :status :label :session :workspace :herdr-workspace.
:workspace names the editor workspace the agent's directory belongs in,
:herdr-workspace the herdr workspace its pane sits in."
  `((name . ,name) (agent . "claude")
    (workspace_id . ,(plist-get keys :herdr-workspace))
    (foreground_cwd . ,(and (plist-get keys :workspace)
                            (concat "/src/" (plist-get keys :workspace))))
    (agent_status . ,(or (plist-get keys :status) "idle"))
    (agent_session . ((value . ,(or (plist-get keys :session) name))))
    (pane_label . ,(plist-get keys :label))
    (server_key . "/tmp/alpha.sock")
    (terminal_id . ,(concat "term-" name))
    (pane_id . ,(concat "%" name))))

(defun limen-herd-tests--payload (event id &rest fields)
  (append fields `((hook_event_name . ,event) (session_id . ,id)
                   (server . "/tmp/alpha.sock") (pane . ,(concat "%" id))
                   (context . ,(and (member event '("UserPromptSubmit" "PostToolUse"))
                                    t)))))

(defmacro limen-herd-tests--with-herd (members &rest body)
  "Run BODY with MEMBERS as the herd `limen' and every Herdr call stubbed.
The sender is the member whose pane the payload names; `prompts' collects
what `herdr-agent-prompt' received as (TARGET . TEXT), which must stay
empty, `renames' what `limen-herd--rename' received as (PANE . LABEL),
and `fetches' how often herdr was asked for the live agents."
  (declare (indent 1) (debug (form body)))
  `(let ((limen-herd--prompts (make-hash-table :test #'equal))
         (limen-herd--held (make-hash-table :test #'equal))
         (limen-herd--overrides (make-hash-table :test #'equal))
         (limen-herd--labels nil)
         (limen-herd--arrived (make-hash-table :test #'equal))
         (limen-herd--states (make-hash-table :test #'equal))
         (limen-herd--hooked (make-hash-table :test #'equal))
         (limen-herd--timers (make-hash-table :test #'equal))
         (limen-herd--chatter (make-hash-table :test #'equal))
         (limen-herd--queue nil)
         (limen-herd--queue-timer nil)
         (limen-herd--snapshot nil)
         (limen-herd-fallback-delay 0)
         (members ,members)
         (prompts nil)
         (renames nil)
         (fetches 0))
     (ignore renames fetches)
     (cl-letf (((symbol-function 'herdr-herd-live-agents)
                (lambda (&rest _) (cl-incf fetches) members))
               ((symbol-function 'herdr-herd-of-entry)
                (lambda (entry)
                  (when (string-prefix-p "herd:" (or (alist-get 'pane_label entry) ""))
                    '("alpha" . "limen"))))
               ((symbol-function 'herdr-herd-member-entries)
                (lambda (_herd &optional agents)
                  (seq-filter #'herdr-herd-of-entry agents)))
               ((symbol-function 'herdr-entry-directory)
                (lambda (entry) (alist-get 'foreground_cwd entry)))
               ((symbol-function 'herdr-workspace-label)
                (lambda (directory) (concat "ws-" (file-name-nondirectory directory))))
               ((symbol-function 'herdr-herd-notice)
                (lambda (herd text) (format "[herd %s] %s" (cdr herd) text)))
               ((symbol-function 'herdr-herd-entry-brief)
                (lambda (entry) (format "%s (claude, %s)" (alist-get 'name entry)
                                        (alist-get 'pane_id entry))))
               ((symbol-function 'herdr-herd--roster-line)
                (lambda (entry) (format "  %s %s" (alist-get 'pane_id entry)
                                        (alist-get 'name entry))))
               ((symbol-function 'herdr-herd-label-token)
                (lambda (label prefix)
                  (when (and (stringp label)
                             (string-match (concat (regexp-quote prefix)
                                                   "\\([^[:space:]]*\\)")
                                           label))
                    (match-string 1 label))))
               ((symbol-function 'herdr-herd-label-with-token)
                (lambda (_label prefix value) (and value (concat prefix value))))
               ((symbol-function 'herdr-herd--busy-p)
                (lambda (member)
                  (member (alist-get 'agent_status member) '("working" "blocked"))))
               ((symbol-function 'herdr-herd--rename)
                (lambda (entry label)
                  (push (cons (alist-get 'pane_id entry) label) renames)))
               ((symbol-function 'herdr-herd--refresh) #'ignore)
               ((symbol-function 'herdr--entry-target)
                (lambda (entry) (alist-get 'terminal_id entry)))
               ((symbol-function 'herdr-agent-prompt)
                (lambda (target text) (push (cons target text) prompts) text)))
       (prog1 (progn ,@body)
         (should-not prompts)))))

(defun limen-herd-tests--held (id)
  "Return the notices waiting for agent session ID's hook context."
  (gethash id limen-herd--held))

(defun limen-herd-tests--event (event id &rest fields)
  "Answer the hook EVENT from agent ID, then run what it queued."
  (prog1 (limen-herd--on-event "claude" (apply #'limen-herd-tests--payload event id fields)
                               nil nil)
    (limen-herd-tests--drain)))

(defun limen-herd-tests--drain ()
  (when limen-herd--queue-timer
    (cancel-timer limen-herd--queue-timer))
  (limen-herd--drain))

(ert-deftest limen-herd-subscriptions-round-trip-through-the-label ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen notify:finished,exited wip"))
    (let ((entry (car members)))
      (should (equal '(finished exited) (limen-herd-subscriptions entry)))
      (limen-herd-subscribe (list entry) '(prompt))
      (should (equal '("%a" . "notify:prompt,finished,exited") (car renames)))
      (limen-herd-unsubscribe (list entry) '(finished exited))
      (should (equal '("%a" . nil) (car renames)))
      (limen-herd-toggle (list entry) 'finished)
      (should (equal '("%a" . "notify:exited") (car renames)))
      (limen-herd-toggle (list entry) 'online)
      (should (equal '("%a" . "notify:online,finished,exited") (car renames)))
      (limen-herd-subscribe-defaults (list entry))
      (should (equal '("%a" . "notify:finished,exited") (car renames)))
      (should-not (limen-herd-subscriptions
                   (limen-herd-tests--entry "b" :label "herd:limen notify:bogus"))))))

(ert-deftest limen-herd-finished-notice-waits-for-each-subscribed-peer-s-hook-context ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:finished")
            (limen-herd-tests--entry "c" :label "herd:limen notify:finished"
                                     :status "working")
            (limen-herd-tests--entry "d" :label "herd:limen"))
    (let ((limen-herd-excerpt-length 160)
          (notice "[herd limen] a finished: \"fix the tests\". Said: \"All green.\""))
      (should-not (limen-herd-tests--event
                   "UserPromptSubmit" "a" '(prompt . "fix the tests\nplease")))
      (should (= (hash-table-count limen-herd--held) 0))
      (limen-herd-tests--event "Stop" "a" '(stop_hook_active . :false)
                               '(last_assistant_message . "All green.\nDetails."))
      (should (equal (limen-herd-tests--event "UserPromptSubmit" "b" '(prompt . "go on"))
                     notice))
      (should (equal (limen-herd-tests--event "PostToolUse" "c") notice))
      (should-not (limen-herd-tests--event "UserPromptSubmit" "c" '(prompt . "more")))
      (should (= (hash-table-count limen-herd--held) 0)))))

(ert-deftest limen-herd-ignores-chatter-turns ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:finished,prompt"))
    (limen-herd-tests--event "UserPromptSubmit" "a"
                             '(prompt . "[herd limen] b finished."))
    (limen-herd-tests--event "Stop" "a")
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "/herd limen — you are a"))
    (limen-herd-tests--event "Stop" "a")
    (should-not (limen-herd-tests--held "b"))
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "real work"))
    (limen-herd-tests--event "Stop" "a" '(stop_hook_active . t))
    (should (equal (limen-herd-tests--held "b")
                   '("[herd limen] a started: \"real work\".")))
    (limen-herd-tests--event "Stop" "a")
    (should (equal (limen-herd-tests--held "b")
                   '("[herd limen] a started: \"real work\"."
                     "[herd limen] a finished: \"real work\".")))))

(ert-deftest limen-herd-online-and-exit-notices ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:online,exited"))
    (limen-herd-tests--event "SessionStart" "a" '(source . "compact"))
    (should-not (limen-herd-tests--held "b"))
    (limen-herd-tests--event "SessionStart" "a" '(source . "resume"))
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "task"))
    (limen-herd-tests--event "SessionEnd" "a" '(reason . "logout"))
    (should (equal (limen-herd-tests--held "b")
                   '("[herd limen] a is online."
                     "[herd limen] a exited (logout).")))
    (should (= (hash-table-count limen-herd--prompts) 0))))

(defun limen-herd-tests--observe (pane status)
  (limen-herd--on-herdr-event
   "/tmp/alpha.sock" "pane.updated"
   `((pane . ((pane_id . ,pane) (agent_status . ,status)))))
  (limen-herd-tests--drain))

(ert-deftest limen-herd-herdr-state-changes-make-notices-without-hooks ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:online,prompt,finished,exited"))
    (limen-herd-tests--observe "%a" "unknown")
    (should-not (limen-herd-tests--held "b"))
    (limen-herd-tests--observe "%a" "idle")
    (limen-herd-tests--observe "%a" "idle")
    (should (equal (limen-herd-tests--held "b") '("[herd limen] a is online.")))
    (limen-herd-tests--observe "%a" "working")
    (limen-herd-tests--observe "%a" "blocked")
    (limen-herd-tests--observe "%a" "idle")
    (limen-herd--on-herdr-event "/tmp/alpha.sock" "pane.exited" '((pane_id . "%a")))
    (limen-herd-tests--drain)
    (should (equal (limen-herd-tests--held "b")
                   '("[herd limen] a is online."
                     "[herd limen] a started a turn."
                     "[herd limen] a finished a turn."
                     "[herd limen] a exited.")))
    (should (= (hash-table-count limen-herd--states) 0))))

(ert-deftest limen-herd-seeding-tells-nobody-about-agents-already-there ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen" :status "working")
            (limen-herd-tests--entry "b" :label "herd:limen notify:online,finished"))
    (limen-herd--seed)
    (should (= (hash-table-count limen-herd--states) 2))
    (limen-herd-tests--observe "%a" "working")
    (should-not (limen-herd-tests--held "b"))
    (limen-herd-tests--observe "%a" "idle")
    (should (equal (limen-herd-tests--held "b") '("[herd limen] a finished a turn.")))))

(ert-deftest limen-herd-a-hooked-turn-silences-its-state-change ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:prompt,finished"))
    (limen-herd--seed)
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "task"))
    (limen-herd-tests--observe "%a" "working")
    (limen-herd-tests--event "Stop" "a")
    (limen-herd-tests--observe "%a" "idle")
    (should (equal (limen-herd-tests--held "b")
                   '("[herd limen] a started: \"task\"."
                     "[herd limen] a finished: \"task\".")))
    (let ((limen-herd-fallback-delay 5)
          (key (cons (limen-herd--pane-key "/tmp/alpha.sock" "%a") 'prompt)))
      (limen-herd-tests--observe "%a" "working")
      (should (gethash key limen-herd--timers))
      (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "again"))
      (should-not (gethash key limen-herd--timers))
      (should (= (length (limen-herd-tests--held "b")) 3)))))

(ert-deftest limen-herd-notices-wait-for-hook-context-when-herdr-sees-the-member-idle ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:prompt,finished")
            (limen-herd-tests--entry "c" :label "herd:limen notify:finished"
                                     :status "working"))
    (limen-herd--seed)
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "task"))
    (limen-herd-tests--event "Stop" "a")
    (limen-herd-tests--observe "%c" "idle")
    (should (equal (limen-herd-tests--held "c") '("[herd limen] a finished: \"task\".")))
    (should (equal (car (last (limen-herd-tests--held "b")))
                   "[herd limen] c finished a turn."))
    (should (equal (limen-herd-tests--event "UserPromptSubmit" "c" '(prompt . "next"))
                   "[herd limen] a finished: \"task\"."))
    (should (= (length (limen-herd-tests--held "b")) 4))
    (limen-herd--on-sent (nth 2 members) "[herd limen] roster")
    (limen-herd-tests--observe "%c" "working")
    (limen-herd-tests--observe "%c" "idle")
    (should (= (length (limen-herd-tests--held "b")) 4))))

(ert-deftest limen-herd-a-hook-answers-before-herdr-is-reached ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:prompt,finished"))
    (let (calls)
      (cl-letf (((symbol-function 'limen-herd--live-agents)
                 (lambda () (push 'agents calls) nil))
                ((symbol-function 'limen-herd--subscribe)
                 (lambda () (push 'subscribe calls))))
        (dolist (event '("UserPromptSubmit" "Stop" "SessionEnd"))
          (limen-herd--on-event "claude"
                                (limen-herd-tests--payload event "a" '(prompt . "task"))
                                nil nil))
        (should-not calls)
        (should limen-herd--queue-timer)
        (limen-herd-tests--drain)
        (should (equal (reverse calls)
                       '(subscribe agents agents agents)))
        (should-not limen-herd--queue)
        (should (= (hash-table-count limen-herd--prompts) 0))))))

(ert-deftest limen-herd-an-agent-in-no-herd-sends-nothing ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "b" :label "herd:limen notify:finished"))
    (limen-herd-tests--event "UserPromptSubmit" "z" '(prompt . "task"))
    (limen-herd-tests--event "Stop" "z")
    (should (= (hash-table-count limen-herd--held) 0))))

(ert-deftest limen-herd-awareness-introduces-every-agent-and-arrivals-through-hooks-only ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :workspace "w1")
            (limen-herd-tests--entry "b" :workspace "w1" :status "working")
            (limen-herd-tests--entry "z" :workspace "w2"))
    (let ((limen-herd-workspace-awareness t))
      (limen-herd--enqueue #'limen-herd--sync-awareness)
      (limen-herd-tests--drain)
      (should (equal (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "go"))
                     (concat "[workspace] Agents here:\n  %b b\n"
                             "Other workspaces: ws-w2 (1 agent).\n"
                             limen-herd-workspace-protocol)))
      (should (equal (limen-herd-tests--event "UserPromptSubmit" "z" '(prompt . "go"))
                     (concat "[workspace] No other agents here yet.\n"
                             "Other workspaces: ws-w1 (2 agents).\n"
                             limen-herd-workspace-protocol)))
      (setq members (append members
                            (list (limen-herd-tests--entry "c" :workspace "w1"))))
      (limen-herd-tests--event "SessionStart" "c" '(source . "startup"))
      (limen-herd-tests--event "SessionStart" "c" '(source . "resume"))
      (should-not prompts)
      (should (equal (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "go"))
                     "[workspace] c (claude, %c) arrived."))
      (should (equal (limen-herd-tests--event "UserPromptSubmit" "c" '(prompt . "go"))
                     (concat "[workspace] Agents here:\n  %a a\n  %b b\n"
                             "Other workspaces: ws-w2 (1 agent).\n"
                             limen-herd-workspace-protocol)))
      (should-not (limen-herd-tests--event "UserPromptSubmit" "z" '(prompt . "go")))
      (should-not prompts))))

(ert-deftest limen-herd-awareness-follows-the-editor-workspace-not-herdr-s ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :workspace "w1" :herdr-workspace "h1")
            (limen-herd-tests--entry "b" :workspace "w1" :herdr-workspace "h2")
            (limen-herd-tests--entry "z" :workspace "w2" :herdr-workspace "h1"))
    (let ((limen-herd-workspace-awareness t))
      (limen-herd--enqueue #'limen-herd--sync-awareness)
      (limen-herd-tests--drain)
      (should (equal (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "go"))
                     (concat "[workspace] Agents here:\n  %b b\n"
                             "Other workspaces: ws-w2 (1 agent).\n"
                             limen-herd-workspace-protocol)))
      (should (equal (limen-herd-tests--event "UserPromptSubmit" "z" '(prompt . "go"))
                     (concat "[workspace] No other agents here yet.\n"
                             "Other workspaces: ws-w1 (2 agents).\n"
                             limen-herd-workspace-protocol))))))

(ert-deftest limen-herd-a-workspace-setting-overrides-the-global-one ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :workspace "w1")
            (limen-herd-tests--entry "z" :workspace "w2"))
    (let ((limen-herd-workspace-awareness nil)
          (limen-herd-mode t))
      (cl-letf (((symbol-function 'limen-herd--scope-label) (lambda () "ws-w1")))
        (limen-herd-toggle-awareness))
      (should (eq (gethash "ws-w1" limen-herd--overrides) 'on))
      (should (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "go")))
      (should-not (limen-herd-tests--event "UserPromptSubmit" "z" '(prompt . "go")))
      (cl-letf (((symbol-function 'limen-herd--scope-label) (lambda () nil)))
        (limen-herd-toggle-awareness))
      (should limen-herd-workspace-awareness)
      (should-not (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "go")))
      (should (limen-herd-tests--event "UserPromptSubmit" "z" '(prompt . "go")))
      (cl-letf (((symbol-function 'limen-herd--scope-label) (lambda () "ws-w1")))
        (limen-herd-toggle-awareness))
      (should (eq (gethash "ws-w1" limen-herd--overrides) 'off))
      (setq members (append members
                            (list (limen-herd-tests--entry "c" :workspace "w1"))))
      (limen-herd-tests--event "SessionStart" "c" '(source . "startup"))
      (should-not (limen-herd-tests--event "UserPromptSubmit" "c" '(prompt . "go"))))))

(ert-deftest limen-herd-notices-reach-an-agent-mid-turn-only-where-context-is-carried ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :workspace "w1" :status "working")
            (limen-herd-tests--entry "b" :workspace "w1"))
    (let ((limen-herd-workspace-awareness t))
      (limen-herd--enqueue #'limen-herd--sync-awareness)
      (limen-herd-tests--drain)
      (should-not (limen-herd-tests--event "PostToolUse" "a" '(context)))
      (should (string-prefix-p "[workspace] Agents here:"
                               (limen-herd-tests--event "PostToolUse" "a")))
      (should-not (limen-herd-tests--event "PostToolUse" "a")))))

(ert-deftest limen-herd-agents-already-running-are-introduced-not-announced ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :workspace "w1")
            (limen-herd-tests--entry "b" :workspace "w1"))
    (let ((limen-herd-workspace-awareness t))
      (limen-herd--start)
      (limen-herd-tests--drain)
      (limen-herd-tests--observe "%a" "working")
      (limen-herd-tests--observe "%b" "idle")
      (should (equal (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "go"))
                     (concat "[workspace] Agents here:\n  %b b\n"
                             limen-herd-workspace-protocol)))
      (should-not (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "go"))))))

(ert-deftest limen-herd-audiences-and-transports-are-pluggable ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a")
            (limen-herd-tests--entry "b"))
    (let* ((sent nil)
           (limen-herd-transports `((log . ,(lambda (member text)
                                              (push (cons (alist-get 'name member) text)
                                                    sent)))))
           (limen-herd-audiences
            (list (lambda (kind self agents text-function)
                    (list (cons 'log (cons (format "%s:%s" kind
                                                   (funcall text-function
                                                            (alist-get 'name self)))
                                           (remove self agents))))))))
      (limen-herd-tests--event "SessionStart" "a" '(source . "startup"))
      (should (equal sent '(("b" . "online:a is online.")))))))

(ert-deftest limen-herd-notices-reuse-the-agents-herdr-last-reported ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:prompt"))
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "one"))
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "two"))
    (should (= fetches 1))
    (should (equal (limen-herd-tests--held "b")
                   '("[herd limen] a started: \"one\"."
                     "[herd limen] a started: \"two\".")))
    (setcar limen-herd--snapshot (- (float-time) limen-herd-agents-max-age 1))
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "three"))
    (should (= fetches 2))))

(ert-deftest limen-herd-pane-events-keep-the-reported-agents-current ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:prompt"))
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "one"))
    (should (= fetches 1))
    (limen-herd--on-herdr-event
     "/tmp/alpha.sock" "pane.updated"
     '((pane (pane_id . "%b") (label . "herd:limen notify:prompt")
             (agent . "claude") (agent_status . "working")
             (agent_session (value . "b")))))
    (should (equal (alist-get 'agent_status
                              (limen-herd--known-agent
                               (limen-herd--pane-key "/tmp/alpha.sock" "%b")))
                   "working"))
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "two"))
    (should (= fetches 1))
    (setq members (list (car members)))
    (limen-herd--on-herdr-event "/tmp/alpha.sock" "pane.exited" '((pane_id . "%b")))
    (should-not (limen-herd--known-agent (limen-herd--pane-key "/tmp/alpha.sock" "%b")))
    (should (= fetches 1))
    (setq members (append members
                          (list (limen-herd-tests--entry "c" :label "herd:limen notify:prompt"))))
    (limen-herd--on-herdr-event
     "/tmp/alpha.sock" "pane.agent_detected"
     '((pane_id . "%c") (agent . "claude") (agent_status . "idle")))
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "three"))
    (should (= fetches 2))
    (should (equal (limen-herd-tests--held "c") '("[herd limen] a started: \"three\".")))
    (limen-herd--on-herdr-event
     "/tmp/alpha.sock" "pane.updated"
     '((pane (pane_id . "%c") (label . "herd:limen") (agent . "claude")
             (agent_status . "idle") (agent_session (value . "c")))))
    (should-not limen-herd--snapshot)))

(ert-deftest limen-herd-an-unknown-sender-has-herdr-asked-once-per-pass ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:prompt"))
    (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "warm"))
    (should (= fetches 1))
    (limen-herd--on-event "claude" (limen-herd-tests--payload
                                    "UserPromptSubmit" "x" '(prompt . "one"))
                          nil nil)
    (limen-herd--on-event "claude" (limen-herd-tests--payload
                                    "UserPromptSubmit" "y" '(prompt . "two"))
                          nil nil)
    (limen-herd-tests--drain)
    (should (= fetches 2))
    (limen-herd-tests--event "UserPromptSubmit" "outside" '(prompt . "x")
                             '(pane . ""))
    (should (= fetches 2))))

(ert-deftest limen-herd-a-drain-that-must-ask-herdr-waits-while-the-user-is-busy ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :label "herd:limen")
            (limen-herd-tests--entry "b" :label "herd:limen notify:prompt"))
    (let ((busy t))
      (cl-letf (((symbol-function 'limen-herd--input-busy-p) (lambda () busy)))
        (unwind-protect
            (progn
              (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "one"))
              (should (= fetches 0))
              (should limen-herd--queue)
              (should (timerp limen-herd--queue-timer))
              (setq busy nil)
              (limen-herd-tests--drain)
              (should (= fetches 1))
              (should-not limen-herd--queue)
              (setq busy t)
              (limen-herd-tests--event "UserPromptSubmit" "a" '(prompt . "two"))
              (should-not limen-herd--queue)
              (should (equal (limen-herd-tests--held "b")
                             '("[herd limen] a started: \"one\"."
                               "[herd limen] a started: \"two\"."))))
          (when limen-herd--queue-timer
            (cancel-timer limen-herd--queue-timer)))))))

(ert-deftest limen-herd-asks-herdr-for-every-session-whatever-buffer-is-current ()
  (limen-herd-tests--with-herd (list (limen-herd-tests--entry "a"))
    (let ((seen t))
      (cl-letf (((symbol-function 'herdr-herd-live-agents)
                 (lambda (&rest _)
                   (setq seen (local-variable-p 'herdr-entries-in-scope-function))
                   members)))
        (with-temp-buffer
          (setq-local herdr-entries-in-scope-function #'ignore)
          (limen-herd--fetch-agents))
        (should-not seen)))))

(ert-deftest limen-herd-lists-agents-by-workspace-with-their-herds ()
  (limen-herd-tests--with-herd
      (list (limen-herd-tests--entry "a" :workspace "w2"
                                     :label "herd:limen notify:finished")
            (limen-herd-tests--entry "b" :workspace "w1" :status "working")
            (limen-herd-tests--entry "c" :workspace "w2" :label "herd:limen")
            (limen-herd-tests--entry "d"))
    (cl-letf (((symbol-function 'herdr-herd-label)
               (lambda (herd) (format "%s/%s" (car herd) (cdr herd)))))
      (let* ((limen-herd-workspace-awareness nil)
             (_ (puthash "ws-w2" 'on limen-herd--overrides))
             (result (limen-herd--list nil nil))
             (workspaces (alist-get 'workspaces result)))
        (should (equal (mapcar (lambda (workspace) (alist-get 'label workspace))
                               workspaces)
                       '("ws-w1" "ws-w2" nil)))
        (should (equal (mapcar (lambda (workspace) (alist-get 'aware workspace))
                               workspaces)
                       '(:json-false t :json-false)))
        (should (equal (aref (alist-get 'agents (aref workspaces 1)) 0)
                       '((pane . "%a") (server . "/tmp/alpha.sock") (name . "a")
                         (agent . "claude") (status . "idle")
                         (herd . "alpha/limen") (notify . ["finished"]))))
        (should (equal (alist-get 'status
                                  (aref (alist-get 'agents (aref workspaces 0)) 0))
                       "working"))
        (should (equal (alist-get 'herds result)
                       [((name . "alpha/limen") (members . ["%a" "%c"]))]))
        (json-serialize result :null-object nil :false-object :json-false)
        (let ((one (limen-herd--list '((workspace . "ws-w1")) nil)))
          (should (equal (mapcar (lambda (workspace)
                                   (alist-get 'label workspace))
                                 (alist-get 'workspaces one))
                         '("ws-w1")))
          (should (equal (alist-get 'herds one) [])))
        (should (= fetches 1))))))

(ert-deftest limen-herd-mode-registers-and-installs ()
  (let ((limen-hooks--subscriptions nil)
        (limen-hooks-event-functions nil)
        (herdr-herd-protocol-functions nil)
        (herdr-herd-sent-functions nil)
        (herdr-agent-event-functions nil)
        (limen-hooks--requests nil)
        (limen-hooks--request-timer nil)
        (installed nil)
        (removed nil))
    (cl-letf (((symbol-function 'limen-hooks-request-install)
               (lambda (feature) (push feature installed)))
              ((symbol-function 'limen-hooks-installing-providers)
               (lambda () '(claude)))
              ((symbol-function 'limen-hooks--remove-groups)
               (lambda (_provider predicate)
                 (setq removed (seq-filter (lambda (event) (funcall predicate event nil))
                                           '("Stop" "SessionEnd" "UserPromptSubmit" "PostToolUse"))))))
      (unwind-protect
          (progn
            (limen-herd-mode 1)
            (should (equal (limen-hooks-events) '(("Stop") ("SessionEnd") ("PostToolUse"))))
            (should (memq #'limen-herd--on-event limen-hooks-event-functions))
            (should (memq #'limen-herd--protocol herdr-herd-protocol-functions))
            (should (memq #'limen-herd--on-sent herdr-herd-sent-functions))
            (should (memq #'limen-herd--on-herdr-event herdr-agent-event-functions))
            (should (equal installed '("herd")))
            (should (string-match-p "notify:finished,exited"
                                    (limen-herd--protocol '("alpha" . "limen"))))
            (limen-herd-mode -1)
            (should-not (limen-hooks-events))
            (should-not (memq #'limen-herd--on-event limen-hooks-event-functions))
            (should-not (memq #'limen-herd--protocol herdr-herd-protocol-functions))
            (should-not (memq #'limen-herd--on-herdr-event herdr-agent-event-functions))
            (should (equal removed '("Stop" "SessionEnd" "PostToolUse"))))
        (limen-herd-mode -1)))))

(provide 'limen-herd-tests)
;;; limen-herd-tests.el ends here
