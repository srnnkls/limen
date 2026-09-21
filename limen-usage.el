;;; limen-usage.el --- Report how much context window an agent holds -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Reports the part of its context window an agent is holding to its
;; Herdr pane, as the metadata token `herdr-status' draws its context
;; column from.  A hook event carrying a count of its own is taken as it
;; stands; the end of a turn carries none, and the count is read from the
;; transcript the event names, on the terms its provider writes.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'limen-hooks)
(require 'limen-transcript)
(require 'limen-herdr)

(declare-function herdr-api-pane-report-metadata "ext:herdr-api"
                  (pane-id source &rest arguments))

(defvar herdr-socket-path)

(defgroup limen-usage nil
  "Report how much of its context window an agent holds to Herdr."
  :group 'limen
  :prefix "limen-usage-")

(defcustom limen-usage-token "context"
  "Metadata token the context window figure is reported under.
Herdr keeps the token with the pane and hands it back with the agent.
Whatever reads it - `herdr-status-context-token' is the dashboard's end
of the same string - has to agree on the name."
  :type 'string
  :group 'limen-usage)

(defcustom limen-usage-source "limen"
  "Metadata source the report is made under.
Herdr patches the tokens of one source, so this leaves the model Limen
reports under the same source standing."
  :type 'string
  :group 'limen-usage)

(defcustom limen-usage-limit 200000
  "Context window a model no `limen-usage-limits' entry matches is read on."
  :type 'integer
  :group 'limen-usage)

(defcustom limen-usage-limits '(("\\[1m\\]" . 1000000))
  "Context windows, keyed by a regexp matching the model the answer names.
The first entry whose regexp matches gives the window; a model none
matches is read on `limen-usage-limit'."
  :type '(alist :key-type regexp :value-type integer)
  :group 'limen-usage)

(defcustom limen-usage-windows '(200000 1000000)
  "The context windows a model may have been opened on, smallest first.
A transcript names the model but not the window it was opened on, and a
harness hands the same model a larger one on request.  A count past the
window read from the model is taken as the larger window in use."
  :type '(repeat integer)
  :group 'limen-usage)

(defcustom limen-usage-provider-events '((claude ("Stop") ("PostModelSwitch"))
                                         (codex ("Stop"))
                                         (pi ("Stop"))
                                         (omp ("Stop")))
  "Hook events a fresh count follows, keyed by the provider that emits them.
A provider's session start already runs Limen's hook, and counts a
resumed conversation itself; these are the further events that say the
count has moved, of which only the end of a turn leaves the counting to
Limen."
  :type '(alist :key-type symbol
                :value-type (repeat (list string)))
  :group 'limen-usage)

(defun limen-usage--limit (model held)
  "Return the context window MODEL answers on, wide enough for HELD tokens."
  (let ((named (or (and (stringp model)
                        (cdr (seq-find (lambda (entry)
                                         (string-match-p (car entry) model))
                                       limen-usage-limits)))
                   limen-usage-limit)))
    (if (<= held named)
        named
      (or (seq-find (lambda (window) (>= window held))
                    (seq-sort #'< limen-usage-windows))
          (apply #'max named limen-usage-windows)))))

(defun limen-usage-of-transcript (file &optional provider)
  "Return the held and total context of FILE's last answer, or nil.
PROVIDER says whose transcript it is.  A harness that named the window
it counts against is taken at its word; one that named only the model
has the window read from that."
  (when-let* ((answer (limen-transcript-answer file provider))
              (held (alist-get 'tokens answer))
              ((numberp held))
              ((> held 0)))
    (let ((window (alist-get 'window answer)))
      (cons held (if (and (numberp window) (>= window held))
                     window
                   (limen-usage--limit (alist-get 'model answer) held))))))

(defun limen-usage--round (tokens)
  "Return TOKENS as a figure short enough for a column."
  (cond
   ((>= tokens 1000000)
    (let ((millions (/ tokens 1000000.0)))
      (if (< (abs (- millions (round millions))) 0.05)
          (format "%dM" (round millions))
        (format "%.1fM" millions))))
   ((>= tokens 1000) (format "%dk" (round (/ tokens 1000.0))))
   (t (number-to-string tokens))))

(defun limen-usage-format (held total)
  "Return HELD of TOTAL context as the figure the column carries."
  (format "%s/%s" (limen-usage--round held) (limen-usage--round total)))

(defun limen-usage-report (server pane usage)
  "Report USAGE as PANE's context window on the Herdr SERVER.
Returns the figure on success.  A server that cannot be reached is not
worth interrupting a hook over, so the report is dropped instead."
  (when (and server pane usage)
    (condition-case nil
        (let ((herdr-socket-path server))
          (herdr-api-pane-report-metadata
           pane limen-usage-source
           :tokens (list (cons (intern limen-usage-token) usage)))
          usage)
      (error nil))))

(defun limen-usage-of (payload)
  "Return the context PAYLOAD counts for itself, or nil.
A session resumed or forked, and a model switched, arrive counted on the
same terms Limen counts a transcript on; the end of a turn arrives
uncounted, except from a harness that counts every one.  A payload
naming the window it counts against is taken at its word."
  (when-let* ((held (alist-get 'context_tokens payload))
              ((numberp held))
              ((> held 0)))
    (let ((window (alist-get 'context_window payload)))
      (limen-usage-format held
                          (if (and (numberp window) (>= window held))
                              window
                            (limen-usage--limit (limen-usage--model payload)
                                                held))))))

(defun limen-usage--model (payload)
  "Return the model PAYLOAD's count was reached on, or nil.
A switch counts what the model it moved to is about to be sent."
  (seq-some (lambda (key)
              (let ((model (alist-get key payload)))
                (and (stringp model) (not (string-empty-p model)) model)))
            '(to_model model)))

(defun limen-usage--asked-for-p (provider payload)
  "Return non-nil when PROVIDER's event in PAYLOAD is one Limen counts on.
The events Limen asked for move the count; the ones other features asked
for are not worth reading a transcript over."
  (when-let* ((event (alist-get 'hook_event_name payload)))
    (assoc event (alist-get (intern provider) limen-usage-provider-events))))

(defun limen-usage--report-event (provider payload _session _context)
  "Report the context window PAYLOAD accounts for, counted or not.
PROVIDER says which events carry a count and whose terms the transcript
is written on.  Runs for every answered hook event and answers nil,
adding nothing to the context a prompt carries.

The transcript is written behind the conversation and the report waits
on a socket, so both are left until the hook's filter has returned, the
way `limen-model' leaves its own."
  (when-let* ((server (alist-get 'server payload))
              (pane (alist-get 'pane payload)))
    (if-let* ((usage (limen-usage-of payload)))
        (run-at-time 0 nil #'limen-usage-report server pane usage)
      (when-let* (((limen-usage--asked-for-p provider payload))
                  (transcript (alist-get 'transcript_path payload)))
        (run-at-time 0 nil #'limen-usage--report server pane transcript
                     (intern provider)))))
  nil)

(defun limen-usage--report (server pane transcript provider)
  "Report what PROVIDER's TRANSCRIPT holds as PANE's context window on SERVER."
  (when-let* ((latest (limen-usage-of-transcript transcript provider)))
    (limen-usage-report server pane
                        (limen-usage-format (car latest) (cdr latest)))))

(declare-function limen-herdr-agents "limen-herdr" ())
(declare-function herdr-entry-directory "ext:herdr" (entry))
(declare-function herdr--entry-server "ext:herdr" (entry))
(declare-function herdr-status-cached-agents "ext:herdr-status" ())
(defvar herdr-status-refresh-hook)

(defun limen-usage--agent-answer (entry)
  "Return the provider, pane and last answer of Herdr agent ENTRY, or nil.
An agent Herdr names no session for is looked up by the directory it
runs in, which is all a harness without a Herdr integration leaves."
  (when-let* ((provider (intern (or (alist-get 'agent entry) "")))
              (pane (alist-get 'pane_id entry))
              (file (limen-transcript-file
                     provider
                     (alist-get 'value (alist-get 'agent_session entry))
                     (or (herdr-entry-directory entry) default-directory)))
              (answer (limen-transcript-answer file provider)))
    (list provider pane answer)))

(defun limen-usage--reported-p (entry)
  "Return non-nil when ENTRY already carries what Limen would report."
  (let ((held (alist-get (intern limen-usage-token) (alist-get 'tokens entry))))
    (and (stringp held) (not (string-empty-p held)))))

;;;###autoload
(defun limen-usage-backfill (&optional agents)
  "Report what every agent Herdr knows is holding, read from its transcript.
AGENTS is a list of (SERVER . ENTRY) pairs, every agent Herdr knows by
default.  A hook reports an agent as it runs; this reports the ones that
ran before Limen was listening, and passes over an agent already
carrying a count, so running it twice costs one request."
  (interactive)
  (let ((reported 0))
    (pcase-dolist (`(,server . ,entry) (or agents (limen-herdr-agents)))
      (unless (limen-usage--reported-p entry)
        (when-let* ((found (limen-usage--agent-answer entry))
                    (answer (nth 2 found))
                    (held (alist-get 'tokens answer))
                    ((numberp held))
                    ((> held 0)))
          (let ((window (alist-get 'window answer)))
            (when (limen-usage-report
                   server (nth 1 found)
                   (limen-usage-format
                    held (if (and (numberp window) (>= window held))
                             window
                           (limen-usage--limit (alist-get 'model answer) held))))
              (cl-incf reported))))))
    (when (called-interactively-p 'any)
      (message "Limen reported the context of %d agent%s" reported
               (if (= reported 1) "" "s")))
    reported))

(defun limen-usage--on-status-refresh ()
  "Report the context of every agent a drawn dashboard still lacks one for."
  (when-let* ((wanting (seq-remove #'limen-usage--reported-p
                                   (herdr-status-cached-agents))))
    (run-at-time 0 nil #'limen-usage-backfill
                 (mapcar (lambda (entry) (cons (herdr--entry-server entry) entry))
                         wanting))))
;;;###autoload
(define-minor-mode limen-usage-mode
  "Report the context window each agent holds to its Herdr pane.
Enabling asks for the hook events a fresh count follows, the way
`limen-hooks-mode' asks for its own; disabling takes them back out."
  :global t
  :group 'limen-usage
  (if limen-usage-mode
      (progn
        (pcase-dolist (`(,provider . ,events) limen-usage-provider-events)
          (dolist (event events)
            (cl-pushnew event (alist-get provider limen-hooks-provider-events)
                        :test #'equal)))
        (add-hook 'herdr-status-refresh-hook #'limen-usage--on-status-refresh)
        (add-hook 'limen-hooks-event-functions #'limen-usage--report-event)
        (limen-hooks-request-install "context window"))
    (remove-hook 'herdr-status-refresh-hook #'limen-usage--on-status-refresh)
    (remove-hook 'limen-hooks-event-functions #'limen-usage--report-event)
    (pcase-dolist (`(,provider . ,events) limen-usage-provider-events)
      (setf (alist-get provider limen-hooks-provider-events)
            (seq-remove (lambda (spec) (member spec events))
                        (alist-get provider limen-hooks-provider-events))))
    (limen-hooks-remove-events-everywhere
     (delete-dups
      (mapcar #'car (mapcan (lambda (entry) (copy-sequence (cdr entry)))
                            limen-usage-provider-events))))))

(provide 'limen-usage)
;;; limen-usage.el ends here
