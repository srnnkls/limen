;;; limen-model.el --- Report the model an agent answers with -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Reports the model an agent answers with to its Herdr pane, as the
;; metadata token `herdr-status' draws its model column from.  The model
;; arrives on the provider's own session-start and model-switch hooks,
;; which `limen-model-mode' asks to have installed.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'limen-hooks)
(require 'limen-transcript)
(require 'limen-herdr)

(declare-function herdr-api-pane-report-metadata "ext:herdr-api"
                  (pane-id source &rest arguments))

(defvar herdr-socket-path)

(defgroup limen-model nil
  "Report the model an agent answers with to its Herdr pane."
  :group 'limen
  :prefix "limen-model-")

(defcustom limen-model-token "model"
  "Metadata token the model is reported under.
Herdr keeps the token with the pane and hands it back with the agent.
Whatever reads it - `herdr-status-model-token' is the dashboard's end of
the same string - has to agree on the name."
  :type 'string
  :group 'limen-model)

(defcustom limen-model-source "limen"
  "Metadata source the report is made under.
Herdr keeps one set of tokens per source, so a source of its own leaves
whatever else reports about the pane alone."
  :type 'string
  :group 'limen-model)

(defcustom limen-model-prefer 'display-name
  "Which spelling of the model is reported.
A provider that names the model twice offers a display name fit for a
column and an identifier fit for a machine; one that names it once is
reported as it stands either way."
  :type '(choice (const :tag "Display name" display-name)
                 (const :tag "Identifier" id))
  :group 'limen-model)

(defcustom limen-model-provider-events '((claude ("PostModelSwitch") ("Stop"))
                                         (pi ("PostModelSwitch") ("Stop"))
                                         (omp ("PostModelSwitch") ("Stop")))
  "Hook events a model is read from, keyed by the provider that emits them.
A provider's session start already runs Limen's hook, and sometimes says
which model the agent opened on; these are the further events that say
which model it moved to, and the end of a turn, which says nothing and
has the transcript read instead."
  :type '(alist :key-type symbol
                :value-type (repeat (list string)))
  :group 'limen-model)

(defconst limen-model--payload-keys
  '(("SessionStart" . model) ("PostModelSwitch" . to_model))
  "The key each event carries its model under, keyed by event.")

(defun limen-model--name (value)
  "Return the model VALUE names, or nil.
A provider reports either the name itself or an object naming it twice,
of which `limen-model-prefer' picks one and the other stands in."
  (cond
   ((stringp value) (and (not (string-empty-p value)) value))
   ((consp value)
    (let ((display (alist-get 'display_name value))
          (id (alist-get 'id value)))
      (limen-model--name (if (eq limen-model-prefer 'id)
                             (or id display)
                           (or display id)))))))

(defun limen-model-of (payload)
  "Return the model PAYLOAD reports, or nil when it reports none.
A hook event that carries no model is not a mistake: Claude documents
the session start as sometimes leaving it out."
  (when-let* ((event (alist-get 'hook_event_name payload))
              (key (cdr (assoc event limen-model--payload-keys))))
    (limen-model--name (alist-get key payload))))

(defun limen-model-report (server pane model)
  "Report MODEL as PANE's model on the Herdr SERVER.
Returns the model on success.  A server that cannot be reached is not
worth interrupting a hook over, so the report is dropped instead."
  (when (and server pane model)
    (condition-case nil
        (let ((herdr-socket-path server))
          (herdr-api-pane-report-metadata
           pane limen-model-source
           :tokens (list (cons (intern limen-model-token) model)))
          model)
      (error nil))))

(defun limen-model-of-transcript (file &optional provider)
  "Return the model the last answer in FILE was given, or nil.
Claude names a model on the session start it sometimes leaves out, and
on nothing else until the model changes; the transcript names it on
every answer."
  (when-let* ((model (alist-get 'model (limen-transcript-answer file provider)))
              ((stringp model))
              ((not (string-empty-p model))))
    (limen-model--name model)))

(defun limen-model--report-transcript (server pane transcript provider)
  "Report the model PROVIDER's TRANSCRIPT last answered with to PANE on SERVER."
  (when-let* ((model (limen-model-of-transcript transcript provider)))
    (limen-model-report server pane model)))

(defun limen-model--asked-for-p (provider payload)
  "Return non-nil when PROVIDER's event in PAYLOAD is one Limen reads on."
  (when-let* ((event (alist-get 'hook_event_name payload)))
    (assoc event (alist-get (intern provider) limen-model-provider-events))))

(defun limen-model--report-event (provider payload _session _context)
  "Report the model PAYLOAD names, or the one its transcript last answered with.
Runs for every answered hook event and answers nil, adding nothing to
the context a prompt carries.

A hook is answered inside the Emacs server's process filter, and Herdr's
request waits on `accept-process-output', which runs that filter again
and lets the next hook in.  The report is made once the filter has
returned, where waiting on a socket reaches nothing but itself."
  (when-let* ((server (alist-get 'server payload))
              (pane (alist-get 'pane payload)))
    (if-let* ((model (limen-model-of payload)))
        (run-at-time 0 nil #'limen-model-report server pane model)
      (when-let* (((limen-model--asked-for-p provider payload))
                  (transcript (alist-get 'transcript_path payload)))
        (run-at-time 0 nil #'limen-model--report-transcript
                     server pane transcript (intern provider)))))
  nil)

(declare-function limen-herdr-agents "limen-herdr" ())
(declare-function herdr-entry-directory "ext:herdr" (entry))
(declare-function herdr--entry-server "ext:herdr" (entry))
(declare-function herdr-status-cached-agents "ext:herdr-status" ())
(defvar herdr-status-refresh-hook)

(defun limen-model--agent-answer (entry)
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

(defun limen-model--reported-p (entry)
  "Return non-nil when ENTRY already carries the model Limen would report."
  (let ((model (alist-get (intern limen-model-token) (alist-get 'tokens entry))))
    (and (stringp model) (not (string-empty-p model)))))

;;;###autoload
(defun limen-model-backfill (&optional agents)
  "Report the model every agent Herdr knows last answered with.
AGENTS is a list of (SERVER . ENTRY) pairs, every agent Herdr knows by
default.  A hook reports a model when a session starts or moves; this
reports the ones that started before Limen was listening, and passes
over an agent already carrying one."
  (interactive)
  (let ((reported 0))
    (pcase-dolist (`(,server . ,entry) (or agents (limen-herdr-agents)))
      (unless (limen-model--reported-p entry)
        (when-let* ((found (limen-model--agent-answer entry))
                    (model (limen-model--name (alist-get 'model (nth 2 found)))))
          (when (limen-model-report server (nth 1 found) model)
            (cl-incf reported)))))
    (when (called-interactively-p 'any)
      (message "Limen reported the model of %d agent%s" reported
               (if (= reported 1) "" "s")))
    reported))

(defun limen-model--on-status-refresh ()
  "Report the model of every agent a drawn dashboard still lacks one for."
  (when-let* ((wanting (seq-remove #'limen-model--reported-p
                                   (herdr-status-cached-agents))))
    (run-at-time 0 nil #'limen-model-backfill
                 (mapcar (lambda (entry) (cons (herdr--entry-server entry) entry))
                         wanting))))
;;;###autoload
(define-minor-mode limen-model-mode
  "Report the model each agent answers with to its Herdr pane.
Enabling asks for the hook events the model arrives on, the way
`limen-hooks-mode' asks for its own; disabling takes them back out."
  :global t
  :group 'limen-model
  (if limen-model-mode
      (progn
        (pcase-dolist (`(,provider . ,events) limen-model-provider-events)
          (dolist (event events)
            (cl-pushnew event (alist-get provider limen-hooks-provider-events)
                        :test #'equal)))
        (add-hook 'herdr-status-refresh-hook #'limen-model--on-status-refresh)
        (add-hook 'limen-hooks-event-functions #'limen-model--report-event)
        (limen-hooks-request-install "model"))
    (remove-hook 'herdr-status-refresh-hook #'limen-model--on-status-refresh)
    (remove-hook 'limen-hooks-event-functions #'limen-model--report-event)
    (pcase-dolist (`(,provider . ,events) limen-model-provider-events)
      (setf (alist-get provider limen-hooks-provider-events)
            (seq-remove (lambda (spec) (member spec events))
                        (alist-get provider limen-hooks-provider-events))))
    (limen-hooks-remove-events-everywhere
     (delete-dups
      (mapcar #'car (mapcan (lambda (entry) (copy-sequence (cdr entry)))
                            limen-model-provider-events))))))

(provide 'limen-model)
;;; limen-model.el ends here
