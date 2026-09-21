;;; limen-transcript.el --- Read the tail of an agent transcript -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Every provider writes its conversation to a file of one JSON object
;; per line and names that file in its hook payloads.  What a feature
;; wants of one is almost always its end, which is what this reads: a
;; bounded tail, cut back to the first whole line.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup limen-transcript nil
  "Read the tail of the transcript a provider writes."
  :group 'limen
  :prefix "limen-transcript-")

(defcustom limen-transcript-tail-bytes 262144
  "How many bytes from the end of a transcript are read by default."
  :type 'natnum
  :group 'limen-transcript)

(defun limen-transcript-tail (file &optional bytes)
  "Return the last BYTES of FILE, from its first whole line onwards.
BYTES defaults to `limen-transcript-tail-bytes'.  A transcript the whole
of which is shorter is returned entire, and an unreadable or empty one
answers nil."
  (when-let* (((stringp file))
              ((file-readable-p file))
              (size (file-attribute-size (file-attributes file)))
              ((> size 0)))
    (let ((start (max 0 (- size (or bytes limen-transcript-tail-bytes)))))
      (with-temp-buffer
        (insert-file-contents-literally file nil start size)
        (when (> start 0)
          (goto-char (point-min))
          (when (search-forward "\n" nil t)
            (delete-region (point-min) (point))))
        (decode-coding-string (buffer-string) 'utf-8)))))

(defun limen-transcript-lines (file &optional bytes)
  "Return the whole lines in the last BYTES of FILE.
BYTES defaults to `limen-transcript-tail-bytes'."
  (when-let* ((text (limen-transcript-tail file bytes)))
    (split-string text "\n" t)))

;;; The last answer

(defconst limen-transcript--widths '(65536 524288 4194304)
  "Bytes read from the end of a transcript, widened until an answer is found.")

(defun limen-transcript-record (line)
  "Return the JSON object LINE holds, or nil when it holds none."
  (and (string-prefix-p "{" line)
       (condition-case nil
           (json-parse-string line :object-type 'alist
                              :null-object nil :false-object nil)
         (error nil))))

(defun limen-transcript--sum (usage keys)
  "Return the sum of USAGE's KEYS, counting what it does not name as zero."
  (cl-reduce #'+
             (mapcar (lambda (key)
                       (let ((value (alist-get key usage)))
                         (if (numberp value) value 0)))
                     keys)))

(defun limen-transcript--claude-answer-p (record)
  "Return non-nil when RECORD is an answer of the conversation itself.
A subagent's answers share the transcript and are marked apart; they
hold a context window of their own, not the one being read."
  (and (equal (alist-get 'type record) "assistant")
       (not (alist-get 'isSidechain record))
       (alist-get 'usage (alist-get 'message record))))

(defun limen-transcript-claude-answer (text)
  "Return what Claude's last answer in TEXT accounts for, or nil.
Claude names the model and counts the request; the window it was sent
on it leaves to be read from the model."
  (cl-loop for line in (nreverse (split-string text "\n" t))
           for record = (limen-transcript-record line)
           when (and record (limen-transcript--claude-answer-p record))
           return (let ((message (alist-get 'message record)))
                    `((tokens . ,(limen-transcript--sum
                                  (alist-get 'usage message)
                                  '(input_tokens cache_creation_input_tokens
                                                 cache_read_input_tokens
                                                 output_tokens)))
                      (model . ,(alist-get 'model message))))))

(defun limen-transcript-codex-answer (text)
  "Return what Codex's last count in TEXT accounts for, or nil.
Codex counts the window itself and names the one it counts against, so
neither figure is inferred; the model it answers with it names apart,
on the turn rather than on the count."
  (let (held window model)
    (dolist (line (nreverse (split-string text "\n" t)))
      (unless (and held model)
        (when-let* (((or (string-search "token_count" line)
                         (string-search "turn_context" line)))
                    (record (limen-transcript-record line))
                    (payload (alist-get 'payload record)))
          (cond
           ((and (not model) (equal (alist-get 'type record) "turn_context"))
            (setq model (alist-get 'model payload)))
           ((not held)
            (when-let* ((info (alist-get 'info payload))
                        (total (alist-get 'total_tokens
                                          (alist-get 'last_token_usage info)))
                        ((numberp total))
                        ((> total 0)))
              (setq held total
                    window (alist-get 'model_context_window info))))))))
    (when held
      `((tokens . ,held) (window . ,window) (model . ,model)))))

(defun limen-transcript-pi-answer (text)
  "Return what Pi's last answer in TEXT accounts for, or nil.
Pi totals a request itself, in the session file Oh My Pi writes the same
way, and names the model it answered with."
  (cl-loop for line in (nreverse (split-string text "\n" t))
           for record = (and (string-search "usage" line)
                             (limen-transcript-record line))
           for message = (and (equal (alist-get 'type record) "message")
                              (alist-get 'message record))
           for held = (alist-get 'totalTokens (alist-get 'usage message))
           when (and (numberp held) (> held 0))
           return `((tokens . ,held) (model . ,(alist-get 'model message)))))

(defcustom limen-transcript-readers '((claude . limen-transcript-claude-answer)
                                      (codex . limen-transcript-codex-answer)
                                      (pi . limen-transcript-pi-answer)
                                      (omp . limen-transcript-pi-answer))
  "What reads the last answer out of a transcript, keyed by its writer.
Each function takes the tail of a transcript and answers with what that
answer named - `tokens', `window' and `model' - or nil when the tail
holds no answer at all."
  :type '(alist :key-type symbol :value-type function)
  :group 'limen-transcript)

(defun limen-transcript-answer (file &optional provider)
  "Return what the last answer in FILE named, or nil.
PROVIDER says which reader the transcript is read with, claude's by
default.  The transcript is read from its end, widening until an answer
turns up, so a long conversation costs no more than a short one.  A
harness that names the model apart from the count - Codex names it on
the turn - has the read widened once more for it, and keeps what it
found when the model is nowhere in the file."
  (when-let* ((reader (alist-get (or provider 'claude) limen-transcript-readers))
              ((stringp file))
              ((file-readable-p file)))
    (let ((size (file-attribute-size (file-attributes file)))
          best)
      (cl-loop for bytes in limen-transcript--widths
               for text = (limen-transcript-tail file bytes)
               for answer = (and text (funcall reader text))
               when (and answer (alist-get 'model answer)) return answer
               when answer do (setq best answer)
               while (and size (< bytes size))
               finally return best))))

;;; The file a session was written to

(defun limen-transcript--claude-file (session root)
  "Return the file Claude wrote SESSION under ROOT to, or nil."
  (when-let* ((session)
              (file (expand-file-name
               (format "%s.jsonl" session)
               (expand-file-name
                (replace-regexp-in-string "[/.]" "-" (directory-file-name root))
                (expand-file-name "~/.claude/projects"))))
              ((file-readable-p file)))
    file))

(defun limen-transcript--newest (files)
  "Return the most recently written of FILES, or nil."
  (car (sort (seq-filter #'file-readable-p files)
             (lambda (a b)
               (time-less-p (file-attribute-modification-time (file-attributes b))
                            (file-attribute-modification-time
                             (file-attributes a)))))))

(defun limen-transcript--matching (directory session)
  "Return the files under DIRECTORY whose name ends in SESSION's id."
  (and (file-directory-p directory)
       (directory-files-recursively
        directory (format "%s\\.jsonl\\'" (regexp-quote session)))))

(defun limen-transcript--codex-file (session _root)
  "Return the rollout Codex wrote SESSION to, or nil."
  (when session
    (limen-transcript--newest
     (limen-transcript--matching (expand-file-name "~/.codex/sessions")
                                 session))))

(defun limen-transcript--slug (root separator)
  "Return the directory name Pi gives ROOT, wrapped in SEPARATOR."
  (concat separator
          (replace-regexp-in-string
           "[/.]" "-" (directory-file-name (expand-file-name root)))
          separator))

(defun limen-transcript--home-slug (root)
  "Return the directory name Oh My Pi gives ROOT, named from the home."
  (let ((path (directory-file-name (expand-file-name root)))
        (home (directory-file-name (expand-file-name "~"))))
    (replace-regexp-in-string
     "[/.]" "-"
     (if (string-prefix-p home path) (substring path (length home)) path))))

(defun limen-transcript--by-directory (sessions name)
  "Return the newest transcript under SESSIONS in the directory called NAME.
A harness Herdr knows no session id for is found by the directory it
runs in, which names a session file of its own.  The newest one there
is the session at hand, unless two were opened on the same directory."
  (let ((directory (expand-file-name name sessions)))
    (when (file-directory-p directory)
      (limen-transcript--newest
       (directory-files directory t "\\.jsonl\\'")))))

(defun limen-transcript--pi-file (session root)
  "Return the session file Pi wrote SESSION to under ROOT, or nil."
  (let ((sessions (expand-file-name "~/.pi/agent/sessions")))
    (or (and session (limen-transcript--newest
                      (limen-transcript--matching sessions session)))
        (limen-transcript--by-directory
         sessions (limen-transcript--slug root "--")))))

(defun limen-transcript--omp-file (session root)
  "Return the session file Oh My Pi wrote SESSION to under ROOT, or nil."
  (let ((sessions (expand-file-name "~/.omp/agent/sessions")))
    (or (and session (limen-transcript--newest
                      (limen-transcript--matching sessions session)))
        (limen-transcript--by-directory
         sessions (limen-transcript--home-slug root)))))

(defcustom limen-transcript-files '((claude . limen-transcript--claude-file)
                                    (codex . limen-transcript--codex-file)
                                    (pi . limen-transcript--pi-file)
                                    (omp . limen-transcript--omp-file))
  "What finds a session's transcript, keyed by the harness that wrote it.
Each function takes the harness's own session id and the directory the
agent runs in, and answers with the file or nil.  A hook names its
transcript itself; this is for an agent that has not run one yet."
  :type '(alist :key-type symbol :value-type function)
  :group 'limen-transcript)

(defun limen-transcript-file (provider session &optional root)
  "Return the transcript PROVIDER wrote SESSION to under ROOT, or nil.
A nil SESSION leaves the finder ROOT alone, which is all Herdr knows of
a harness whose integration it has not been given."
  (when-let* ((finder (alist-get provider limen-transcript-files)))
    (funcall finder
             (and (stringp session) (not (string-empty-p session)) session)
             (or root default-directory))))

(provide 'limen-transcript)
;;; limen-transcript.el ends here
