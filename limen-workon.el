;;; limen-workon.el --- Start an agent on something to work on -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `limen-workon' offers what `limen-workon-providers' list for a project
;; in one completion, grouped by provider.  The choice gets its branch, a
;; worktree under `limen-workon-worktree-directory' of the main worktree,
;; provisioned by mise when it has a mise config, and a new agent started
;; there on its prompt, which is then shown.  Every process runs in the
;; background, and each provider's candidates are kept and refreshed
;; behind the completion.
;; `limen-workon-mode' binds it to `W' on the dashboard, where `C-u W'
;; first sets the branch base and name, harness, model, effort and an
;; extra prompt in a menu, or sends the choice's prompt to the agent at
;; point instead.  What it leaves unset comes from the project settings
;; `C-w' sets for all of the project's agents.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'limen-provider)
(require 'limen-herdr)
(require 'herdr-core nil t)

(declare-function herdr-status-new-agent "ext:herdr-status" (&optional kind root args session))
(declare-function herdr-status-new-agent-session "ext:herdr-status" ())
(declare-function herdr-agent-session-buffer "ext:herdr-agent" (session) t)
(declare-function herdr-agent-prompt "ext:herdr-agent" (target text))
(declare-function herdr-agent-prompt-when-ready "ext:herdr-agent" (session text))
(declare-function herdr-visit "ext:herdr" (entry))
(declare-function herdr--entry-target "ext:herdr" (entry))
(declare-function herdr-entry-directory "ext:herdr" (entry))
(declare-function herdr-status-entry-at-point "ext:herdr-status" ())
(defvar herdr-agent-harnesses)
(defvar herdr-status--project-root)
(defvar herdr-status-mode-map)

(defgroup limen-workon nil
  "Start an agent on something to work on."
  :group 'limen
  :prefix "limen-workon-")

(defcustom limen-workon-providers nil
  "Providers of things to work on, each a plist.
`:name' labels the provider's group in the completion.  `:candidates' is
called with the repository root and a callback, which it calls with the
provider's items, or with nil and a non-nil second argument when it
failed and the items it gave before should stay.

An item is a plist.  `:label' is what the completion shows and
`:annotation' what it shows beside it.  `:branch' is called with the
root, the options and a callback taking the branch and its base: nil for
a branch that exists, locally or on origin, `trunk' for origin's default
branch, or a ref.  The options are a plist whose `:name' and `:base',
when set, ask for a new branch so named or based.  `:prompt' is called
with the directory the agent works in, the harness and a callback taking
the prompt.  `:prepare', when there,
is called with the worktree and the root once the worktree is ready."
  :type '(repeat plist)
  :group 'limen-workon)

(defcustom limen-workon-harness "claude"
  "Harness a new agent starts as, unless the prefix argument chooses one."
  :type 'string
  :group 'limen-workon)

(defcustom limen-workon-worktree-directory ".worktrees"
  "Directory under the main worktree new worktrees go in."
  :type 'string
  :group 'limen-workon)

(defconst limen-workon--mise-configs
  '("mise.toml" ".mise.toml" ".config/mise/config.toml" "mise/config.toml")
  "Files whose presence in a new worktree has mise provision it.")

(defun limen-workon-skill (harness skill)
  "Return what HARNESS is sent to invoke SKILL."
  (if-let* ((provider (limen-provider harness))
            (reference (limen-provider-skill-reference provider)))
      (funcall reference skill)
    (concat "/" skill)))

;;; Processes

(defun limen-workon-process (directory command callback &optional failure)
  "Run COMMAND in DIRECTORY in the background.
CALLBACK receives its trimmed output once it exits zero, FAILURE its
trimmed error output otherwise.  Without FAILURE a failure is reported.
Both run from a timer, outside the process sentinel."
  (let* ((default-directory directory)
         (output (generate-new-buffer " *limen-workon*"))
         (errors (generate-new-buffer " *limen-workon-stderr*"))
         (stderr (make-pipe-process :name "limen-workon-stderr" :buffer errors
                                    :noquery t :sentinel #'ignore)))
    (make-process
     :name "limen-workon"
     :buffer output
     :stderr stderr
     :noquery t
     :connection-type 'pipe
     :command command
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (let ((code (process-exit-status process))
               (out (with-current-buffer output (string-trim (buffer-string))))
               (err (with-current-buffer errors (string-trim (buffer-string)))))
           (kill-buffer output)
           (delete-process stderr)
           (kill-buffer errors)
           (run-at-time 0 nil
                        (lambda ()
                          (cond ((zerop code) (funcall callback out))
                                (failure (funcall failure err))
                                (t (message "Limen workon: %s failed: %s"
                                            (string-join command " ") err)))))))))))

;;; Where

(defun limen-workon--main-worktree (directory)
  "Return the main worktree of the repository DIRECTORY is in."
  (let ((default-directory directory))
    (file-name-as-directory
     (string-remove-prefix
      "worktree " (car (process-lines "git" "worktree" "list" "--porcelain"))))))

(defun limen-workon--place ()
  "Return where the dashboard row at point, or the dashboard, works.
A plist of the repository's main worktree as `:root', the `:agent'
entry when the row is an agent, and the `:buffer' and `:point' a new
agent is started from, as `herdr-status-new-agent' starts one there."
  (let* ((entry (and (fboundp 'herdr-status-entry-at-point)
                     (derived-mode-p 'herdr-status-mode)
                     (herdr-status-entry-at-point)))
         (directory (or (and entry (herdr-entry-directory entry))
                        (bound-and-true-p herdr-status--project-root)
                        default-directory))
         (root (limen-workon--main-worktree
                (or (locate-dominating-file directory ".git")
                    (user-error "Not in a git repository: %s" directory)))))
    (list :root root
          :agent (and (alist-get 'agent entry) entry)
          :buffer (current-buffer)
          :point (point-marker))))

;;; Candidates

(defvar limen-workon--items (make-hash-table :test #'equal)
  "The items each provider last gave for a root, keyed by (NAME . ROOT).")

(defvar limen-workon--waiting (make-hash-table :test #'equal)
  "The callbacks waiting on each root's refresh in flight.")

(defun limen-workon--fetched-p (root)
  "Return non-nil when every provider has answered for ROOT once."
  (seq-every-p (lambda (provider)
                 (not (eq (gethash (cons (plist-get provider :name) root)
                                   limen-workon--items 'unfetched)
                          'unfetched)))
               limen-workon-providers))

(defun limen-workon-refresh (root &optional callback)
  "Ask every provider for ROOT's items in the background, then call CALLBACK.
A refresh already under way for ROOT is joined rather than repeated.  A
provider that fails keeps the items it gave before, or records none."
  (let* ((waiting (gethash root limen-workon--waiting 'idle))
         (callbacks (and (listp waiting) waiting)))
    (puthash root (if callback (cons callback callbacks) callbacks)
             limen-workon--waiting)
    (when (eq waiting 'idle)
      (let ((pending (length limen-workon-providers)))
        (cl-flet ((done ()
                    (when (<= (cl-decf pending) 0)
                      (let ((callbacks (gethash root limen-workon--waiting)))
                        (remhash root limen-workon--waiting)
                        (mapc #'funcall (reverse callbacks))))))
          (if (null limen-workon-providers)
              (done)
            (dolist (provider limen-workon-providers)
              (let ((key (cons (plist-get provider :name) root)))
                (funcall (plist-get provider :candidates) root
                         (lambda (items &optional failed)
                           (when (or (not failed)
                                     (eq (gethash key limen-workon--items 'unfetched)
                                         'unfetched))
                             (puthash key items limen-workon--items))
                           (done)))))))))))

(defun limen-workon--candidates (root)
  "Return ROOT's items as completion candidates, in provider order."
  (mapcan (lambda (provider)
            (let ((name (plist-get provider :name)))
              (mapcar (lambda (item)
                        (propertize (plist-get item :label)
                                    'limen-workon-group name
                                    'limen-workon-item item))
                      (gethash (cons name root) limen-workon--items))))
          limen-workon-providers))

(defun limen-workon--table (candidates)
  "Return a completion table over what CANDIDATES returns, grouped by provider.
CANDIDATES is called each time the table is, so items a refresh brings
in while the minibuffer is open join it."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata
          (category . limen-workon)
          (display-sort-function . identity)
          (group-function
           . ,(lambda (candidate transform)
                (if transform
                    candidate
                  (get-text-property 0 'limen-workon-group candidate))))
          (annotation-function
           . ,(lambda (candidate)
                (when-let* ((annotation (plist-get (get-text-property
                                                    0 'limen-workon-item candidate)
                                                   :annotation)))
                  (concat "  " (propertize annotation 'face 'completions-annotations))))))
      (complete-with-action action (funcall candidates) string predicate))))

(defun limen-workon--read (candidates)
  "Read one of what CANDIDATES returns and return its item."
  (let* ((choice (completing-read "Work on: " (limen-workon--table candidates) nil t))
         (candidate (seq-find (lambda (candidate) (equal candidate choice))
                              (funcall candidates))))
    (or (and candidate (get-text-property 0 'limen-workon-item candidate))
        (user-error "Nothing to work on"))))

;;; Worktrees

(defun limen-workon--worktree-of (porcelain branch)
  "Return the worktree `git worktree list --porcelain' PORCELAIN has BRANCH in."
  (seq-some (lambda (block)
              (and (string-match-p (format "^branch refs/heads/%s$" (regexp-quote branch))
                                   block)
                   (string-match "^worktree \\(.+\\)$" block)
                   (match-string 1 block)))
            (split-string porcelain "\n\n" t)))

(defun limen-workon--worktree-path (root branch)
  "Return where a new worktree of BRANCH under ROOT goes."
  (expand-file-name (string-replace "/" "--" branch)
                    (expand-file-name limen-workon-worktree-directory root)))

(defun limen-workon--trunk (root callback)
  "Call CALLBACK with ROOT's origin default branch, as a remote ref."
  (limen-workon-process
   root '("git" "symbolic-ref" "--short" "refs/remotes/origin/HEAD")
   callback (lambda (_) (funcall callback "origin/main"))))

(defun limen-workon--provision (worktree callback)
  "Have mise trust and install WORKTREE's tools, then call CALLBACK.
Without mise or a mise config in WORKTREE, CALLBACK is called at once; a
failing mise is reported and CALLBACK still called."
  (if-let* (((executable-find "mise"))
            ((seq-some (lambda (config) (file-exists-p (expand-file-name config worktree)))
                       limen-workon--mise-configs)))
      (cl-flet ((failed (error)
                  (message "Limen workon: mise failed in %s: %s"
                           (abbreviate-file-name worktree) error)
                  (funcall callback)))
        (message "Provisioning %s with mise..." (abbreviate-file-name worktree))
        (limen-workon-process
         worktree (list "mise" "trust" "--quiet" "-C" worktree)
         (lambda (_)
           (limen-workon-process worktree '("mise" "install")
                                 (lambda (_) (funcall callback)) #'failed))
         #'failed))
    (funcall callback)))

(defun limen-workon--add-worktree (root branch base callback)
  "Add a worktree of BRANCH under ROOT, from BASE when BRANCH is new.
CALLBACK receives the worktree once origin is fetched, it is added and
mise has provisioned it."
  (let ((path (limen-workon--worktree-path root branch)))
    (cl-flet ((add (arguments)
                (limen-workon-process
                 root (append '("git" "worktree" "add") arguments)
                 (lambda (_)
                   (limen-workon--provision path (lambda () (funcall callback path)))))))
      (cl-flet ((added ()
                  (if (null base)
                      (add (list path branch))
                    (limen-workon-process
                     root (list "git" "rev-parse" "--verify" "--quiet"
                                (concat "refs/heads/" branch))
                     (lambda (_) (add (list path branch)))
                     (lambda (_) (add (list "-b" branch path base)))))))
        (limen-workon-process
         root (list "git" "fetch" "origin"
                    (if base (string-remove-prefix "origin/" base) branch))
         (lambda (_) (added)) (lambda (_) (added)))))))

(defun limen-workon-worktree (root branch base callback)
  "Call CALLBACK with a worktree of BRANCH under ROOT, made when there is none.
BASE is as a provider's `:branch' gives it."
  (limen-workon-process
   root '("git" "worktree" "list" "--porcelain")
   (lambda (porcelain)
     (if-let* ((path (limen-workon--worktree-of porcelain branch)))
         (funcall callback path)
       (if (eq base 'trunk)
           (limen-workon--trunk
            root (lambda (trunk)
                   (limen-workon--add-worktree root branch trunk callback)))
         (limen-workon--add-worktree root branch base callback))))))

;;; Starting

(defun limen-workon--prompt-with (prompt options)
  "Return PROMPT followed by the extra prompt OPTIONS carry."
  (if-let* ((extra (plist-get options :prompt))
            ((not (string-empty-p extra))))
      (concat prompt "\n\n---\n\n" extra)
    prompt))

(defmacro limen-workon--at (place &rest body)
  "Run BODY in PLACE's buffer at its point, where `W' was pressed."
  (declare (indent 1))
  `(with-current-buffer (if (buffer-live-p (plist-get ,place :buffer))
                            (plist-get ,place :buffer)
                          (current-buffer))
     (save-excursion
       (when (marker-buffer (plist-get ,place :point))
         (goto-char (plist-get ,place :point)))
       ,@body)))

(defun limen-workon--launch (place session worktree options prompt)
  "Start the harness OPTIONS name in WORKTREE on SESSION with PROMPT.
`herdr-status-new-agent' starts it as from PLACE's buffer and point; the
agent is shown once started and sent PROMPT once ready."
  (limen-workon--at place
    (let* ((limen-herdr-launch-settings
            (list :harness (plist-get options :harness)
                  :model (plist-get options :model)
                  :effort (plist-get options :effort)))
           (started (herdr-status-new-agent
                     (plist-get options :harness) worktree nil session)))
      (herdr-agent-prompt-when-ready started (limen-workon--prompt-with prompt options))
      (when-let* ((buffer (herdr-agent-session-buffer started))
                  ((buffer-live-p buffer)))
        (pop-to-buffer buffer))
      started)))

(defun limen-workon-start (place item options)
  "Give ITEM its branch and worktree at PLACE and start an agent there on it.
OPTIONS is the plist `limen-workon--options' returns."
  (let ((root (plist-get place :root))
        (harness (plist-get options :harness))
        (session (limen-workon--at place (herdr-status-new-agent-session))))
    (funcall
     (plist-get item :branch) root options
     (lambda (branch base)
       (message "Preparing %s..." branch)
       (limen-workon-worktree
        root branch base
        (lambda (worktree)
          (when-let* ((prepare (plist-get item :prepare)))
            (funcall prepare worktree root))
          (funcall (plist-get item :prompt) worktree harness
                   (lambda (prompt)
                     (limen-workon--launch place session worktree options prompt)
                     (message "Working on %s in %s" branch
                              (abbreviate-file-name worktree))))))))))

(defun limen-workon-prompt (place item &optional options)
  "Send PLACE's agent ITEM's prompt, with the extra prompt OPTIONS carry.
The agent is shown once the prompt is sent."
  (let ((agent (plist-get place :agent)))
    (funcall (plist-get item :prompt)
             (or (herdr-entry-directory agent) (plist-get place :root))
             (alist-get 'agent agent)
             (lambda (prompt)
               (herdr-agent-prompt (herdr--entry-target agent)
                                   (limen-workon--prompt-with prompt options))
               (herdr-visit agent)))))

(defun limen-workon--choose (place candidates options &optional send)
  "Let the user pick among what CANDIDATES returns and work on it at PLACE.
An agent starts on the choice as OPTIONS say, or with SEND the agent at
PLACE is sent it."
  (if (null (funcall candidates))
      (message "Nothing to work on in %s" (abbreviate-file-name (plist-get place :root)))
    (let* ((inhibit-quit nil)
           (item (limen-workon--read candidates)))
      (if send
          (limen-workon-prompt place item options)
        (limen-workon-start place item options)))))

;;; Options

(defconst limen-workon--option-flags
  '((:base . "--base=") (:name . "--name=") (:harness . "--harness=")
    (:model . "--model=") (:effort . "--effort=") (:prompt . "--prompt="))
  "The menu argument each option is set with.")

(defun limen-workon--options (root &optional arguments)
  "Return the options the menu's ARGUMENTS set for ROOT.
What they leave unset comes from ROOT's project settings, and the
harness last from `limen-workon-harness'."
  (let ((options (limen-herdr-arguments-settings arguments limen-workon--option-flags)))
    (cl-loop for (key value) on (limen-herdr-settings root) by #'cddr
             unless (plist-get options key)
             do (setq options (plist-put options key value)))
    (unless (plist-get options :harness)
      (setq options (plist-put options :harness limen-workon-harness)))
    options))

(defun limen-workon--run (options &optional send)
  "Pick something to work on in the dashboard's project, as OPTIONS say.
With SEND the choice goes to the agent at point instead."
  (require 'herdr)
  (require 'herdr-agent)
  (let* ((place (limen-workon--place))
         (root (plist-get place :root))
         (candidates (lambda () (limen-workon--candidates root))))
    (when (and send (not (plist-get place :agent)))
      (user-error "No agent at point"))
    (if (limen-workon--fetched-p root)
        (progn
          (limen-workon-refresh root)
          (limen-workon--choose place candidates options send))
      (message "Asking what to work on in %s..." (abbreviate-file-name root))
      (limen-workon-refresh
       root (lambda () (limen-workon--choose place candidates options send))))))

(defun limen-workon-with-arguments (&optional arguments)
  "Work on something with the options the menu's ARGUMENTS set."
  (interactive (list (transient-args 'limen-workon-dispatch)))
  (limen-workon--run (limen-workon--options (plist-get (limen-workon--place) :root)
                                            arguments)))

(defun limen-workon-send-with-arguments (&optional arguments)
  "Send the agent at point something to work on, with the menu's extra prompt.
ARGUMENTS are the menu's; only its extra prompt applies."
  (interactive (list (transient-args 'limen-workon-dispatch)))
  (limen-workon--run (limen-workon--options (plist-get (limen-workon--place) :root)
                                            arguments)
                     t))

;;;###autoload (autoload 'limen-workon-dispatch "limen-workon" nil t)
(transient-define-prefix limen-workon-dispatch ()
  "Set how to work on something, then pick it."
  :value (lambda ()
           (limen-herdr-settings-arguments
            (limen-herdr-settings (plist-get (limen-workon--place) :root))))
  ["Branch"
   ("-b" "base" "--base=")
   ("-n" "name" "--name=")]
  ["Agent"
   ("-h" "harness" "--harness=" :reader limen-herdr-read-harness)
   ("-m" "model" "--model=" :reader limen-herdr-read-model)
   ("-e" "reasoning effort" "--effort=" :reader limen-herdr-read-effort)
   ("-p" "extra prompt" "--prompt=")]
  [("W" "work on" limen-workon-with-arguments)
   ("s" "send to the agent at point" limen-workon-send-with-arguments)])

;;;###autoload
(defun limen-workon (&optional menu)
  "Pick something `limen-workon-providers' offer for the project and work on it.
The choice gets a branch and worktree and an agent starts there on it,
as the project settings `limen-herdr-project-dispatch' sets say.  What
the providers gave last is offered at once while they refresh in the
background; only a project's first call waits for them.  With MENU, the
prefix argument, set the options first in `limen-workon-dispatch'."
  (interactive "P")
  (if menu
      (limen-workon-dispatch)
    (limen-workon--run (limen-workon--options (plist-get (limen-workon--place) :root)))))

;;; Dashboard

(defun limen-workon--attach ()
  "Bind `W' on the dashboard and list it in the dashboard's menu."
  (when (boundp 'herdr-status-mode-map)
    (define-key herdr-status-mode-map "W" #'limen-workon)
    (define-key herdr-status-mode-map (kbd "C-w") #'limen-herdr-project-dispatch))
  (when (and (fboundp 'herdr-status-dispatch)
             (get 'herdr-status-dispatch 'transient--prefix)
             (not (ignore-errors (transient-get-suffix 'herdr-status-dispatch "W"))))
    (transient-append-suffix 'herdr-status-dispatch "N"
      '("W" "work on" limen-workon))))

(defun limen-workon--detach ()
  "Take `W' off the dashboard and out of its menu."
  (when (and (boundp 'herdr-status-mode-map)
             (eq (lookup-key herdr-status-mode-map "W") #'limen-workon))
    (define-key herdr-status-mode-map "W" nil)
    (define-key herdr-status-mode-map (kbd "C-w") nil))
  (when (and (fboundp 'herdr-status-dispatch)
             (get 'herdr-status-dispatch 'transient--prefix)
             (ignore-errors (transient-get-suffix 'herdr-status-dispatch "W")))
    (transient-remove-suffix 'herdr-status-dispatch "W")))

;;;###autoload
(define-minor-mode limen-workon-mode
  "Start agents on what `limen-workon-providers' offer, with `W' on the dashboard."
  :global t
  :group 'limen-workon
  (if limen-workon-mode
      (progn
        (limen-workon--attach)
        (with-eval-after-load 'herdr-status
          (when limen-workon-mode (limen-workon--attach))))
    (limen-workon--detach)))

(provide 'limen-workon)
;;; limen-workon.el ends here
