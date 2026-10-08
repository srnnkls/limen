;;; limen-workon-tests.el --- Workon tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(defvar herdr-session nil)
(defvar herdr-status-mode-map)

(unless (require 'herdr-core nil t)
  (defmacro herdr-with-session (session &rest body)
    `(let ((herdr-session (or ,session herdr-session))) ,@body)))

(require 'limen-workon)

(defun limen-workon-tests--wait (predicate)
  "Run timers and process output until PREDICATE holds."
  (with-timeout (5 (error "Timed out"))
    (while (not (funcall predicate)) (accept-process-output nil 0.02))))

(defmacro limen-workon-tests--with-git (commands answers &rest body)
  "Run BODY with `limen-workon-process' answering from ANSWERS.
Each command run is pushed onto COMMANDS; ANSWERS maps a command's
leading words to (ok . OUTPUT) or (fail . ERROR), and anything else
answers (ok . \"\")."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'limen-workon-process)
              (lambda (_directory command callback &optional failure)
                (push command ,commands)
                (let ((answer (or (cdr (seq-find (lambda (entry)
                                                   (equal (car entry)
                                                          (seq-take command (length (car entry)))))
                                                 ,answers))
                                  '(ok . ""))))
                  (if (eq (car answer) 'ok)
                      (funcall callback (cdr answer))
                    (when failure (funcall failure (cdr answer))))))))
     ,@body))

(ert-deftest limen-workon-process-answers-outside-the-sentinel ()
  (let (out err)
    (limen-workon-process temporary-file-directory '("sh" "-c" "echo hi; echo oops >&2")
                          (lambda (output) (setq out output)))
    (limen-workon-process temporary-file-directory '("sh" "-c" "echo bad >&2; exit 3")
                          #'ignore (lambda (error) (setq err error)))
    (limen-workon-tests--wait (lambda () (and out err)))
    (should (equal out "hi"))
    (should (equal err "bad"))
    (should-not (seq-some (lambda (buffer) (string-prefix-p " *limen-workon" (buffer-name buffer)))
                          (buffer-list)))))

(ert-deftest limen-workon-finds-the-worktree-a-branch-is-in ()
  (let ((porcelain "worktree /repo\nHEAD abc\nbranch refs/heads/main\n\nworktree /repo/.worktrees/feat--x\nHEAD def\nbranch refs/heads/feat/x\n\nworktree /tmp/d\nHEAD 123\ndetached\n"))
    (should (equal (limen-workon--worktree-of porcelain "feat/x") "/repo/.worktrees/feat--x"))
    (should (equal (limen-workon--worktree-of porcelain "main") "/repo"))
    (should-not (limen-workon--worktree-of porcelain "feat"))))

(ert-deftest limen-workon-reuses-a-worktree-the-branch-already-has ()
  (let (commands path)
    (limen-workon-tests--with-git commands
        '((("git" "worktree" "list") . (ok . "worktree /repo/.worktrees/b\nbranch refs/heads/b")))
      (limen-workon-worktree "/repo/" "b" nil (lambda (p) (setq path p))))
    (should (equal path "/repo/.worktrees/b"))
    (should (= (length commands) 1))))

(ert-deftest limen-workon-makes-a-new-branch-off-trunk ()
  (let (commands path)
    (limen-workon-tests--with-git commands
        '((("git" "worktree" "list") . (ok . "worktree /repo\nbranch refs/heads/main"))
          (("git" "symbolic-ref") . (ok . "origin/develop"))
          (("git" "rev-parse") . (fail . "")))
      (limen-workon-worktree "/repo/" "feat/queue" 'trunk (lambda (p) (setq path p))))
    (should (equal path "/repo/.worktrees/feat--queue"))
    (should (equal (reverse commands)
                   '(("git" "worktree" "list" "--porcelain")
                     ("git" "symbolic-ref" "--short" "refs/remotes/origin/HEAD")
                     ("git" "fetch" "origin" "develop")
                     ("git" "rev-parse" "--verify" "--quiet" "refs/heads/feat/queue")
                     ("git" "worktree" "add" "-b" "feat/queue"
                      "/repo/.worktrees/feat--queue" "origin/develop"))))))

(ert-deftest limen-workon-checks-out-an-existing-branch-even-when-fetch-fails ()
  (let (commands path)
    (limen-workon-tests--with-git commands
        '((("git" "fetch") . (fail . "offline")))
      (limen-workon-worktree "/repo/" "12-fix" nil (lambda (p) (setq path p))))
    (should (equal path "/repo/.worktrees/12-fix"))
    (should (equal (car commands)
                   '("git" "worktree" "add" "/repo/.worktrees/12-fix" "12-fix")))))

(ert-deftest limen-workon-provisions-a-new-worktree-with-mise ()
  (let* ((root (make-temp-file "limen-workon" t))
         (worktree (expand-file-name ".worktrees/feat--m" root))
         commands path)
    (unwind-protect
        (progn
          (make-directory worktree t)
          (write-region "" nil (expand-file-name "mise.toml" worktree))
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (program &rest _) (equal program "mise"))))
            (limen-workon-tests--with-git commands
                '((("git" "worktree" "list") . (ok . "worktree /elsewhere\nbranch refs/heads/main")))
              (limen-workon-worktree root "feat/m" "origin/main" (lambda (p) (setq path p)))))
          (should (equal path worktree))
          (should (equal (seq-take commands 2)
                         (list '("mise" "install")
                               (list "mise" "trust" "--quiet" "-C" worktree)))))
      (delete-directory root t))))

(ert-deftest limen-workon-launches-even-when-mise-fails ()
  (let* ((worktree (make-temp-file "limen-workon" t))
         commands done)
    (unwind-protect
        (progn
          (write-region "" nil (expand-file-name ".mise.toml" worktree))
          (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) t)))
            (limen-workon-tests--with-git commands '((("mise" "install") . (fail . "boom")))
              (limen-workon--provision worktree (lambda () (setq done t)))))
          (should done))
      (delete-directory worktree t))))

(ert-deftest limen-workon-skips-mise-without-a-config ()
  (let (commands done)
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) t)))
      (limen-workon-tests--with-git commands nil
        (limen-workon--provision temporary-file-directory (lambda () (setq done t)))))
    (should done)
    (should-not commands)))

(ert-deftest limen-workon-roots-new-worktrees-in-the-main-worktree ()
  (let* ((root (file-name-as-directory (file-truename (make-temp-file "limen-workon" t))))
         (default-directory root))
    (unwind-protect
        (progn
          (call-process "git" nil nil nil "init" "-q")
          (call-process "git" nil nil nil "-c" "user.name=t" "-c" "user.email=t@t"
                        "commit" "-q" "--allow-empty" "-m" "init")
          (call-process "git" nil nil nil "worktree" "add" "-q" "-b" "side" ".worktrees/side")
          (should (equal (limen-workon--main-worktree (expand-file-name ".worktrees/side" root))
                         root))
          (should (equal (limen-workon--main-worktree root) root)))
      (delete-directory root t))))

(ert-deftest limen-workon-starts-a-worktree-agent-even-on-an-agent-row ()
  (let (calls)
    (cl-letf (((symbol-function 'limen-workon--read) (lambda (_) 'item))
              ((symbol-function 'limen-workon-start)
               (lambda (&rest _) (push 'start calls)))
              ((symbol-function 'limen-workon-prompt)
               (lambda (&rest _) (push 'prompt calls))))
      (let ((place '(:root "/repo/" :agent ((agent . "claude")))))
        (limen-workon--choose place (lambda () '("x")) nil)
        (limen-workon--choose place (lambda () '("x")) nil t)))
    (should (equal (reverse calls) '(start prompt)))))

(ert-deftest limen-workon-refresh-caches-joins-and-keeps-on-failure ()
  (let* ((limen-workon--items (make-hash-table :test #'equal))
         (limen-workon--waiting (make-hash-table :test #'equal))
         (answers nil)
         (limen-workon-providers
          (list (list :name "Issues"
                      :candidates (lambda (_root callback) (push callback answers)))))
         (called nil))
    (should-not (limen-workon--fetched-p "/repo/"))
    (limen-workon-refresh "/repo/" (lambda () (push 'first called)))
    (limen-workon-refresh "/repo/" (lambda () (push 'second called)))
    (should (= (length answers) 1))
    (funcall (pop answers) (list '(:label "#1 One")))
    (should (equal called '(second first)))
    (should (limen-workon--fetched-p "/repo/"))
    (limen-workon-refresh "/repo/")
    (funcall (pop answers) nil t)
    (should (equal (limen-workon--candidates "/repo/") '("#1 One")))
    (limen-workon-refresh "/other/")
    (funcall (pop answers) nil t)
    (should (limen-workon--fetched-p "/other/"))))

(ert-deftest limen-workon-table-groups-by-provider ()
  (let* ((limen-workon--items (make-hash-table :test #'equal))
         (limen-workon-providers (list '(:name "Issues") '(:name "Scopes"))))
    (puthash '("Issues" . "/r/") (list '(:label "#1 One" :annotation "bug")) limen-workon--items)
    (puthash '("Scopes" . "/r/") (list '(:label "draft/two")) limen-workon--items)
    (let* ((candidates (limen-workon--candidates "/r/"))
           (table (limen-workon--table (lambda () candidates)))
           (metadata (cdr (funcall table "" nil 'metadata))))
      (should (equal candidates '("#1 One" "draft/two")))
      (should (equal (funcall (alist-get 'group-function metadata) (cadr candidates) nil)
                     "Scopes"))
      (should (equal (substring-no-properties
                      (funcall (alist-get 'annotation-function metadata) (car candidates)))
                     "  bug"))
      (should (equal (all-completions "dr" table) '("draft/two"))))))

(ert-deftest limen-workon-start-prepares-then-launches-on-the-prompt ()
  (with-temp-buffer
  (let (events started shown prompted)
    (cl-letf (((symbol-function 'herdr-agent-prompt-when-ready)
               (lambda (session text) (setq prompted (list session text))))
              ((symbol-function 'limen-workon-worktree)
               (lambda (root branch base callback)
                 (push (list 'worktree root branch base) events)
                 (funcall callback "/repo/.worktrees/feat--q")))
              ((symbol-function 'herdr-status-new-agent-session)
               (lambda () (push (list 'asked (point)) events) "cmw"))
              ((symbol-function 'herdr-status-new-agent)
               (lambda (kind root args session)
                 (setq started (list kind root args limen-herdr-launch-settings
                                     (current-buffer) (point) session))
                 'session))
              ((symbol-function 'herdr-agent-session-buffer)
               (lambda (_session) (get-buffer-create " *limen-workon-agent*")))
              ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (setq shown buffer))))
      (insert "dashboard\nrow")
      (limen-workon-start
       (list :root "/repo/" :buffer (current-buffer) :point (copy-marker 3))
       (list :branch (lambda (_root options callback)
                       (push (list 'options options) events)
                       (funcall callback "feat/q" 'trunk))
             :prepare (lambda (worktree root) (push (list 'prepare worktree root) events))
             :prompt (lambda (directory harness callback)
                       (funcall callback (format "%s in %s" harness directory))))
       '(:harness "codex" :model "gpt-6" :effort "high" :prompt "Keep it small."))
)
    (should (equal (reverse events)
                   '((asked 3)
                     (options (:harness "codex" :model "gpt-6" :effort "high"
                                        :prompt "Keep it small."))
                     (worktree "/repo/" "feat/q" trunk)
                     (prepare "/repo/.worktrees/feat--q" "/repo/"))))
    (should (equal (seq-take started 4)
                   '("codex" "/repo/.worktrees/feat--q" nil
                     (:harness "codex" :model "gpt-6" :effort "high"))))
    (should (equal (nthcdr 4 started) (list (current-buffer) 3 "cmw")))
    (should (equal (buffer-name shown) " *limen-workon-agent*"))
    (should (equal prompted '(session
                              "codex in /repo/.worktrees/feat--q\n\n---\n\nKeep it small.")))
    (kill-buffer shown))))

(ert-deftest limen-workon-prompt-sends-to-the-agent-and-shows-it ()
  (let (sent visited)
    (cl-letf (((symbol-function 'herdr-entry-directory)
               (lambda (entry) (alist-get 'cwd entry)))
              ((symbol-function 'herdr--entry-target)
               (lambda (entry) (alist-get 'terminal_id entry)))
              ((symbol-function 'herdr-agent-prompt)
               (lambda (target text) (setq sent (list target text))))
              ((symbol-function 'herdr-visit) (lambda (entry) (setq visited entry))))
      (limen-workon-prompt
       (list :root "/repo/" :agent '((agent . "codex") (cwd . "/repo/wt") (terminal_id . "term-7")))
       (list :prompt (lambda (directory harness callback)
                       (funcall callback (format "%s %s" harness directory))))))
    (should (equal sent '("term-7" "codex /repo/wt")))
    (should (equal (alist-get 'terminal_id visited) "term-7"))))

(ert-deftest limen-workon-options-inherit-the-project-settings ()
  (let ((limen-herdr-project-settings
         '(("/repo/" :harness "codex" :model "gpt-6" :effort "medium")))
        (limen-workon-harness "claude"))
    (should (equal (limen-workon--options "/repo/")
                   '(:harness "codex" :model "gpt-6" :effort "medium")))
    (should (equal (limen-workon--options "/repo/" '("--effort=high" "--base=dev"))
                   '(:base "dev" :effort "high" :harness "codex" :model "gpt-6")))
    (should (equal (limen-workon--options "/other/") '(:harness "claude")))))

(ert-deftest limen-workon-skill-is-spelled-the-harness-s-way ()
  (should (equal (limen-workon-skill "claude" "implement") "/implement"))
  (should (equal (limen-workon-skill "codex" "implement") "$implement"))
  (should (equal (limen-workon-skill "pi" "implement") "/skill:implement")))

(ert-deftest limen-workon-mode-binds-w-on-the-dashboard ()
  (let ((herdr-status-mode-map (make-sparse-keymap)))
    (unwind-protect
        (progn
          (limen-workon-mode 1)
          (should (eq (lookup-key herdr-status-mode-map "W") #'limen-workon))
          (should (eq (lookup-key herdr-status-mode-map (kbd "C-w"))
                      #'limen-herdr-project-dispatch))
          (limen-workon-mode -1)
          (should-not (lookup-key herdr-status-mode-map "W")))
      (limen-workon-mode -1))))

(provide 'limen-workon-tests)
;;; limen-workon-tests.el ends here
