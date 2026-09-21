;;; limen-provider.el --- Describe each agent harness once -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Holds what Limen knows about each harness it can talk to: where its
;; settings live, how a launched pane is wired, which of its tools ask
;; questions or edit files, and how to name its sessions.  Every other
;; file reads these fields instead of branching on the harness name.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)

(cl-defstruct (limen-provider (:constructor limen-provider--make))
  "What Limen knows about one agent harness.
NAME is its symbol.  CONFIG-DIRECTORY and HOOK-SETTINGS are functions
returning the harness configuration directory and the file holding its
hooks, or nil when it has none.  HOOK-TRANSPORT is `settings' for a
harness whose own settings file Limen writes the hooks into, `extension'
for one whose extension answers them instead, and nil for one that
answers none.  ROUTE is `mcp' when a launched pane is given an MCP
route.  ARGUMENTS receives the route endpoint, or nil, and the launch
arguments and returns the complete argument list.
QUESTION-TOOLS name the tools that ask the user a question and
TRANSCRIPT-QUESTIONS-P says those questions must be read from the
transcript instead.  EDIT-TOOLS name the tools that change files.
SESSION-NAME maps a session id to the name the harness gave it.
SKILL-SOURCE receives a project root, or nil, and returns the harness's
skills as an alist of name and description.  SKILL-REFERENCE maps a
skill name to what the harness is sent to invoke it.
CAPABILITIES is the plist `limen-herdr-status' reports."
  name config-directory hook-settings hook-transport route arguments
  question-tools transcript-questions-p edit-tools session-name
  skill-source skill-reference capabilities)

(defvar limen-provider--registry nil
  "Registered providers, oldest first.")

(defun limen-provider-register (provider)
  "Register PROVIDER, replacing one of the same name."
  (let ((name (limen-provider-name provider)))
    (setq limen-provider--registry
          (append (seq-remove (lambda (entry) (eq (limen-provider-name entry) name))
                              limen-provider--registry)
                  (list provider)))
    provider))

(defun limen-provider (name)
  "Return the provider called NAME, a symbol or string, or nil."
  (let ((name (if (stringp name) (intern name) name)))
    (seq-find (lambda (entry) (eq (limen-provider-name entry) name))
              limen-provider--registry)))

(defun limen-providers ()
  "Return every registered provider."
  (copy-sequence limen-provider--registry))

(defun limen-providers-with (accessor)
  "Return the providers for which ACCESSOR returns non-nil."
  (seq-filter accessor limen-provider--registry))

(defun limen-provider--home (variable directory)
  "Return VARIABLE's directory when set, else DIRECTORY below the home."
  (let ((configured (getenv variable)))
    (if (and configured (not (string= configured "")))
        configured
      (expand-file-name directory (or (getenv "HOME") "~")))))

(defun limen-provider--claude-config-directory ()
  "Return Claude Code's configuration directory."
  (limen-provider--home "CLAUDE_CONFIG_DIR" ".claude"))

(defun limen-provider--codex-home ()
  "Return Codex's state directory."
  (limen-provider--home "CODEX_HOME" ".codex"))

(defun limen-provider--pi-home ()
  "Return Pi's state directory."
  (limen-provider--home "PI_HOME" ".pi"))

(defun limen-provider--omp-home ()
  "Return Oh My Pi's state directory."
  (limen-provider--home "OMP_HOME" ".omp"))

(defun limen-provider--claude-session-name (id)
  "Return the name Claude Code gave session ID, or nil."
  (let ((directory (expand-file-name
                    "sessions" (limen-provider--claude-config-directory))))
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

(defun limen-provider--skill-directories (configuration root)
  "Return the skill directories of CONFIGURATION, and of ROOT when given.
A harness reads its own below its configuration directory and a
project's below a directory of the same name in the project."
  (delq nil
        (list (expand-file-name "skills" configuration)
              (when root
                (expand-file-name
                 (format "%s/skills"
                         (file-name-nondirectory
                          (directory-file-name configuration)))
                 root)))))

(defun limen-provider--skill-description (file)
  "Return the description SKILL.md FILE carries in its front matter, or nil."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (goto-char (point-min))
    (when (re-search-forward "^description:[ \t]*\\(.*\\)$" nil t)
      (string-trim (match-string 1) "[ \t\"']+" "[ \t\"']+"))))

(defun limen-provider--directory-skills (configuration root)
  "Return the skills below CONFIGURATION, and below ROOT, as name and description.
A skill is a directory holding a SKILL.md.  A project's skill of some
name is the one that answers for it."
  (let (skills)
    (dolist (directory (limen-provider--skill-directories configuration root))
      (when (file-directory-p directory)
        (dolist (entry (directory-files directory t "\\`[^.]"))
          (let ((file (expand-file-name "SKILL.md" entry)))
            (when (file-exists-p file)
              (setf (alist-get (file-name-nondirectory
                                (directory-file-name entry))
                               skills nil nil #'equal)
                    (limen-provider--skill-description file)))))))
    (sort skills (lambda (a b) (string< (car a) (car b))))))

(defconst limen-provider--codex-skill-line
  "\\`- \\([a-zA-Z0-9][^:`]*\\): \\(.*?\\)[ \t]*(file: [^)]*)\\'"
  "Regexp matching one skill of Codex's own listing.")

(defun limen-provider--codex-skills (root)
  "Return the skills Codex lists for ROOT, as name and description.
Codex resolves its own, the project's and its bundled skills, so its
answer is taken over reading the directories they live in."
  (let ((default-directory (or root default-directory)))
    (with-temp-buffer
      (when (zerop (ignore-errors
                     (call-process "codex" nil t nil "debug" "prompt-input")))
        (goto-char (point-min))
        (let (skills)
          (dolist (message (ignore-errors (json-parse-buffer :object-type 'alist
                                                             :array-type 'list)))
            (dolist (part (alist-get 'content message))
              (let ((text (alist-get 'text part)))
                (when (and (stringp text) (string-search "<skills_instructions>" text))
                  (dolist (line (split-string text "\n"))
                    (when (string-match limen-provider--codex-skill-line line)
                      (setf (alist-get (match-string 1 line) skills nil nil #'equal)
                            (match-string 2 line))))))))
          (sort skills (lambda (a b) (string< (car a) (car b)))))))))

(defun limen-provider-skills (provider &optional root)
  "Return the skills PROVIDER offers below ROOT, as name and description.
A harness that lists its own is asked; one that does not has the
directories it reads them from read instead."
  (when-let* ((skills (limen-provider-skill-source provider)))
    (funcall skills root)))

(defun limen-provider-skill-call (provider skill)
  "Return what PROVIDER is sent to invoke SKILL."
  (if-let* ((reference (limen-provider-skill-reference provider)))
      (funcall reference skill)
    skill))

(defun limen-provider-extension-directory ()
  "Return the directory holding the packaged harness extensions.
`mise run install-extensions' links them into the harness's own
extension directory, which is where Pi and Oh My Pi discover them, in a
pane Limen launched and in one it only adopted alike."
  (expand-file-name
   "extensions"
   (file-name-directory (or (locate-library "limen-provider") load-file-name))))

(limen-provider-register
 (limen-provider--make
  :name 'claude
  :config-directory #'limen-provider--claude-config-directory
  :hook-settings (lambda ()
                   (expand-file-name
                    "settings.json" (limen-provider--claude-config-directory)))
  :hook-transport 'settings
  :arguments (lambda (_endpoint arguments) arguments)
  :question-tools '("AskUserQuestion")
  :edit-tools '("Edit" "Write" "MultiEdit")
  :session-name #'limen-provider--claude-session-name
  :skill-source (lambda (root)
                  (limen-provider--directory-skills
                   (limen-provider--claude-config-directory) root))
  :skill-reference (lambda (skill) (concat "/" skill))
  :capabilities
  '(:transport hooks :operations cli
               :passive-context prompt :explicit-context prompt :diffs nil)))

(limen-provider-register
 (limen-provider--make
  :name 'codex
  :config-directory #'limen-provider--codex-home
  :hook-settings (lambda ()
                   (expand-file-name "hooks.json" (limen-provider--codex-home)))
  :hook-transport 'settings
  :route 'mcp
  :arguments (lambda (endpoint arguments)
               (if endpoint
                   (append
                    (list "-c"
                          (format "mcp_servers.limen.url=\"%s\"" endpoint)
                          "-c"
                          "mcp_servers.limen.bearer_token_env_var=\"LIMEN_MCP_TOKEN\"")
                    arguments)
                 arguments))
  :question-tools '("request_user_input")
  :transcript-questions-p t
  :skill-source (lambda (root)
                  (or (limen-provider--codex-skills root)
                      (limen-provider--directory-skills
                       (limen-provider--codex-home) root)))
  :skill-reference (lambda (skill) (concat "$" skill))
  :capabilities
  '(:transport streamable-http :operations registry
               :passive-context resource :explicit-context terminal :diffs t)))

(limen-provider-register
 (limen-provider--make
  :name 'pi
  :config-directory #'limen-provider--pi-home
  :hook-transport 'extension
  :route 'mcp
  :arguments (lambda (_endpoint arguments) arguments)
  :edit-tools '("edit" "write")
  :skill-source (lambda (root)
                  (limen-provider--directory-skills
                   (limen-provider--pi-home) root))
  :skill-reference (lambda (skill) (concat "/skill:" skill))
  :capabilities
  '(:transport extension :operations registry
               :passive-context next-turn :explicit-context message :diffs t)))

(limen-provider-register
 (limen-provider--make
  :name 'omp
  :config-directory #'limen-provider--omp-home
  :hook-transport 'extension
  :route 'mcp
  :arguments (lambda (_endpoint arguments) arguments)
  :edit-tools '("edit" "write")
  :skill-source (lambda (root)
                  (limen-provider--directory-skills
                   (limen-provider--omp-home) root))
  :skill-reference (lambda (skill) (concat "/skill:" skill))
  :capabilities
  '(:transport extension :operations registry
               :passive-context next-turn :explicit-context message :diffs t)))

(provide 'limen-provider)
;;; limen-provider.el ends here
