;;; limen-memex.el --- Keep memex transcripts current as agents work -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Redraws a memex transcript while the agent it records is working.  An
;; agent's hooks say when its conversation has moved - a prompt taken, a
;; tool answered, a turn finished - and `limen-memex-live-mode' redraws
;; the views of that conversation Emacs is showing.

;;; Code:

(require 'seq)
(require 'limen)
(require 'limen-hooks)

(declare-function memex-view-refresh "ext:memex-view" (&optional buffer))
(defvar memex-view-session-id)
(defvar memex-view-source-path)

(defgroup limen-memex nil
  "Keep memex transcripts current as agents work."
  :group 'limen
  :prefix "limen-memex-")

(defcustom limen-memex-live-events
  '(("UserPromptSubmit") ("PostToolUse") ("Stop") ("SessionEnd"))
  "Hook events after which a view of the agent's conversation is redrawn.
Each is an (EVENT . MATCHER) spec as `limen-hooks-subscribe' takes it.
A tool use without a matcher runs the hook after every tool call, which
keeps a view moving through a long turn at the cost of a hook each.
Takes effect when `limen-memex-live-mode' is next enabled."
  :type '(repeat (cons string (choice (const nil) string)))
  :group 'limen-memex)

(defcustom limen-memex-live-delay 1.0
  "Seconds a view waits after its agent's last event before it is redrawn.
A turn runs tools in bursts, each firing a hook, and the harness writes
its transcript behind the hook: waiting lets both settle into one redraw."
  :type 'number
  :group 'limen-memex)

(defcustom limen-memex-live-visible-only t
  "Whether only a view shown in a visible window is redrawn.
A buried view stays as it was until it is refreshed or opened again."
  :type 'boolean
  :group 'limen-memex)

(defvar-local limen-memex--timer nil
  "The timer redrawing this view once its agent's events settle.")

(defun limen-memex--present (value)
  "Return VALUE when it is a non-empty string, or nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun limen-memex--view-p (buffer payload)
  "Return non-nil when BUFFER is a memex view of PAYLOAD's conversation.
The transcript file names the conversation when both sides know it,
since one session id can recur across files; the session id names it
where a harness reports no transcript."
  (and (eq (buffer-local-value 'major-mode buffer) 'memex-session-mode)
       (let ((id (limen-memex--present (alist-get 'session_id payload)))
             (transcript (limen-memex--present (alist-get 'transcript_path payload)))
             (shown (buffer-local-value 'memex-view-session-id buffer))
             (shown-path (limen-memex--present
                          (buffer-local-value 'memex-view-source-path buffer))))
         (if (and transcript shown-path)
             (limen--file-equivalent-p transcript shown-path)
           (and id (equal id shown))))))

(defun limen-memex--views (payload)
  "Return the live memex views of PAYLOAD's conversation to redraw."
  (seq-filter (lambda (buffer)
                (and (limen-memex--view-p buffer payload)
                     (or (not limen-memex-live-visible-only)
                         (get-buffer-window buffer 'visible))))
              (buffer-list)))

(defun limen-memex--refresh (buffer)
  "Redraw BUFFER's transcript, unless it was killed while waiting."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq limen-memex--timer nil))
    (memex-view-refresh buffer)))

(defun limen-memex--schedule (buffer)
  "Redraw BUFFER once `limen-memex-live-delay' passes without another event."
  (with-current-buffer buffer
    (when (timerp limen-memex--timer)
      (cancel-timer limen-memex--timer))
    (setq limen-memex--timer
          (run-with-timer limen-memex-live-delay nil
                          #'limen-memex--refresh buffer))))

(defun limen-memex--on-event (_provider payload _session _request)
  "Schedule a redraw of every view of the conversation hook PAYLOAD reports.
Answers nil, adding nothing to the context a prompt carries."
  (mapc #'limen-memex--schedule (limen-memex--views payload))
  nil)

(defun limen-memex--cancel-all ()
  "Cancel every redraw still waiting."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (timerp limen-memex--timer)
        (cancel-timer limen-memex--timer)
        (setq limen-memex--timer nil)))))

;;;###autoload
(define-minor-mode limen-memex-live-mode
  "Redraw memex transcripts as the agents they record work.
Enabling subscribes `limen-memex-live-events', which asks once per
provider where they are missing after the current command.  Each event
redraws the views of its agent's conversation once the events pause for
`limen-memex-live-delay'.  Disabling unsubscribes them."
  :global t
  :group 'limen-memex
  (cond
   (limen-memex-live-mode
    (unless (and (require 'memex-view nil t) (fboundp 'memex-view-refresh))
      (setq limen-memex-live-mode nil)
      (user-error "Live memex views need `memex-view-refresh' from memex-view"))
    (limen-hooks-subscribe "memex" :events limen-memex-live-events
                           :function #'limen-memex--on-event))
   (t
    (limen-hooks-unsubscribe "memex")
    (limen-memex--cancel-all))))

(provide 'limen-memex)
;;; limen-memex.el ends here
