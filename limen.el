;;; limen.el --- Emacs interface for agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.9.0"))
;; Keywords: tools, processes
;; URL: https://github.com/srnnkls/limen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provides a small, extensible operation registry for local agent clients.

;;; Code:

(require 'cl-lib)
(require 'flymake)
(require 'json)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)

(declare-function flycheck-error-column "ext:flycheck" (error))
(declare-function flycheck-error-filename "ext:flycheck" (error))
(declare-function flycheck-error-level "ext:flycheck" (error))
(declare-function flycheck-error-line "ext:flycheck" (error))
(declare-function flycheck-error-message "ext:flycheck" (error))
(declare-function projectile-project-root "ext:projectile" (&optional directory))
(declare-function projectile-relevant-known-projects "ext:projectile" ())
(declare-function limen-hooks-output "limen-hooks" (request context))
(defvar flycheck-current-errors)
(defvar projectile-require-project-root)

(defgroup limen nil
  "Emacs operations exposed to local agents."
  :group 'external)

(defcustom limen-enable-elisp-eval nil
  "Whether `elisp.eval' may evaluate arbitrary Emacs Lisp."
  :type 'boolean
  :group 'limen)

(defcustom limen-readable-virtual-buffer-condition nil
  "Buffer match condition allowing project-confined virtual buffer content.
A nil or invalid condition denies access.  The value t explicitly allows all
project-confined non-internal virtual buffers."
  :type 'sexp
  :group 'limen)

(defvaralias 'limen-project-relative-deny-regexps
  'limen-project-path-deny-regexps)

(defcustom limen-confine-to-project t
  "Whether reads of where the user is stay within the requested project.
Focus, the window list and the trail answer only for buffers below the
project root when non-nil.  When nil, each buffer answers against its
own project, which its record names, and that project's deny patterns
apply to it; what a virtual buffer discloses still follows
`limen-readable-virtual-buffer-condition'."
  :type 'boolean
  :group 'limen)

(defcustom limen-focus-terminal-modes '(ghostel-mode vterm-mode eat-mode term-mode)
  "Major modes of the terminals an agent prompts from.
Focus looks past a selected window showing one of these to the window
used most recently before it: a prompt typed into an agent's own
terminal means the buffer the user came from, not the terminal."
  :type '(repeat symbol)
  :group 'limen)

(defcustom limen-project-path-deny-regexps nil
  "Regexps denying canonical project-relative paths."
  :type '(repeat regexp)
  :group 'limen)

(defcustom limen-focus-invisible-span-limit 100
  "Maximum number of invisible spans returned by `focus.get'."
  :type '(integer 0)
  :group 'limen)

(defconst limen-version "0.1.0"
  "Current Limen package version.")

(defconst limen-protocol-version 1
  "Current limen request and response protocol version.")

(define-error 'limen-error "limen error")
(define-error 'limen-invalid-request "Invalid limen request" 'limen-error)
(define-error 'limen-unsupported-version "Unsupported limen version" 'limen-error)
(define-error 'limen-unknown-operation "Unknown limen operation" 'limen-error)
(define-error 'limen-disabled-operation "Disabled limen operation" 'limen-error)
(define-error 'limen-invalid-arguments "Invalid limen arguments" 'limen-error)
(define-error 'limen-operation-failed "limen operation failed" 'limen-error)
(define-error 'limen-conflict "Limen state conflict" 'limen-operation-failed)
(define-error 'limen-unknown-event "Unknown limen event" 'limen-error)
(define-error 'limen-session-closed "Closed limen session" 'limen-error)

(defconst limen-deferred 'limen-deferred
  "Return value marking an operation that will complete through its request.")

(cl-defstruct (limen-request
               (:constructor limen--make-request))
  interface source session project-root owner generation frame window resolver rejecter
  canceller)

(cl-defstruct (limen-session
               (:constructor limen--make-session))
  id provider project-root owner generation capabilities subscribers latest requests sequence
  closed-p location)

(cl-defstruct (limen--event
               (:constructor limen--make-event))
  name description parameters replay)

(cl-defstruct (limen--operation
               (:constructor limen--make-operation))
  name handler description parameters effect interfaces enabled-p deferred command)

(cl-defstruct (limen--owned-buffer
               (:constructor limen--make-owned-buffer))
  buffer window owned-p paths)

(defvar limen--operations (make-hash-table :test #'equal)
  "Registered operations keyed by dotted name.")

(defvar limen-operation-change-hook nil
  "Hook run with an action and name after the operation registry changes.")

(defvar limen--events (make-hash-table :test #'equal)
  "Registered events keyed by dotted name.")

(defvar limen--sessions (make-hash-table :test #'eq)
  "Open integration sessions keyed by identity.")

(defvar limen-session-open-hook nil
  "Hook run with a session immediately after it is registered.")

(defvar limen-session-close-hook nil
  "Hook run with a session immediately before its resources are released.")

(defvar limen--buffers (make-hash-table :test #'eq)
  "File buffers opened for each opaque owner.")

(defun limen--valid-name-p (name)
  "Return non-nil when NAME is a valid dotted operation name."
  (and (stringp name)
       (string-match-p "\\`[a-z][a-z0-9-]*\\(?:\\.[a-z][a-z0-9-]*\\)+\\'" name)))

(cl-defun limen-register-operation
    (name handler &key description parameters (effect 'read) (interfaces '(cli))
          enabled-p deferred command)
  "Register NAME with HANDLER and replace an existing descriptor.
DESCRIPTION documents it.  PARAMETERS declares its arguments.  EFFECT is `read'
or `write'.  INTERFACES controls discovery.  ENABLED-P gates invocation, and
DEFERRED marks callback-based operations.  COMMAND is the `limen' command
line that runs it, without the program name, for the agent skill."
  (unless (limen--valid-name-p name)
    (signal 'wrong-type-argument (list 'limen-operation-name name)))
  (unless (functionp handler)
    (signal 'wrong-type-argument (list 'functionp handler)))
  (unless (memq effect '(read write))
    (signal 'wrong-type-argument (list '(member read write) effect)))
  (let ((operation
         (limen--make-operation
          :name name :handler handler :description (or description "")
          :parameters parameters :effect effect :interfaces interfaces
          :enabled-p enabled-p :deferred deferred :command command)))
    (puthash name operation limen--operations)
    (run-hook-with-args 'limen-operation-change-hook 'registered name)
    operation))

(defun limen-unregister-operation (name)
  "Unregister the operation named NAME."
  (when (remhash name limen--operations)
    (run-hook-with-args 'limen-operation-change-hook 'unregistered name)
    t))

(cl-defun limen-register-event
    (name &key description parameters replay)
  "Register event NAME with DESCRIPTION and PARAMETERS.
REPLAY makes the latest payload replayable to new subscribers."
  (unless (limen--valid-name-p name)
    (signal 'wrong-type-argument (list 'limen-event-name name)))
  (let ((event (limen--make-event
                :name name :description (or description "")
                :parameters parameters :replay replay)))
    (puthash name event limen--events)
    event))

(defun limen-unregister-event (name)
  "Unregister the event named NAME."
  (remhash name limen--events))

(defun limen-server-key (path)
  "Return the canonical identity of the Herdr socket PATH, or nil."
  (when (and (stringp path) (not (string-empty-p path)))
    (file-truename (expand-file-name path))))

(cl-defun limen-open-session
    (&key id provider project-root owner capabilities location)
  "Open an integration session for PROVIDER and PROJECT-ROOT.
ID and OWNER default to opaque values.  CAPABILITIES describes the transport.
LOCATION names the pane the session's agent runs in, as a cons of the
Herdr server key and the pane id, so a hook from that pane finds it."
  (let ((canonical-root
         (when project-root
           (when (file-remote-p project-root)
             (signal 'limen-operation-failed
                     '("Remote project roots are unavailable")))
           (let ((expanded-root (expand-file-name project-root)))
             (when (file-remote-p expanded-root)
               (signal 'limen-operation-failed
                       '("Remote project roots are unavailable")))
             (directory-file-name (file-truename expanded-root))))))
    (let ((session
           (limen--make-session
            :id (or id (format "limen-%x" (sxhash (list (float-time) (random)))))
            :provider provider
            :project-root canonical-root
            :owner (or owner (make-symbol "limen-owner"))
            :generation 1
            :capabilities capabilities
            :location location
            :latest (make-hash-table :test #'equal)
            :sequence 0)))
      (puthash session t limen--sessions)
      (run-hook-with-args 'limen-session-open-hook session)
      session)))

(defun limen-find-session-at (location)
  "Return the open session whose agent runs at LOCATION, or nil.
LOCATION is a cons of the Herdr server key and the pane id."
  (catch 'found
    (maphash (lambda (session _)
               (when (and (not (limen-session-closed-p session))
                          (equal (limen-session-location session) location))
                 (throw 'found session)))
             limen--sessions)
    nil))

(defun limen-find-session (id)
  "Return the open integration session whose ID matches, or nil."
  (catch 'found
    (maphash (lambda (session _)
               (when (equal (limen-session-id session) id)
                 (throw 'found session)))
             limen--sessions)
    nil))

(defun limen--request-current-p (request)
  "Return non-nil when REQUEST still belongs to its live generation."
  (let ((session (limen-request-session request)))
    (or (null session)
        (and (not (limen-session-closed-p session))
             (= (limen-request-generation request)
                (limen-session-generation session))))))

(defun limen--forget-request (request)
  "Remove REQUEST from its session's pending requests."
  (when-let* ((session (limen-request-session request)))
    (setf (limen-session-requests session)
          (delq request (limen-session-requests session)))))

(cl-defun limen-make-request
    (&key interface source session project-root owner generation frame window resolve reject
          cancel)
  "Create a request from INTERFACE and SOURCE.
SESSION supplies PROJECT-ROOT, OWNER, and GENERATION defaults.  FRAME and WINDOW
locate editor work; RESOLVE, REJECT, and CANCEL manage deferred requests."
  (limen--make-request
   :interface interface :source source :session session
   :project-root (or project-root (and session (limen-session-project-root session)))
   :owner (or owner (and session (limen-session-owner session)))
   :generation (or generation (and session (limen-session-generation session)) 0)
   :frame frame :window window :resolver resolve :rejecter reject :canceller cancel))

(defun limen-request-resolve (request value)
  "Resolve REQUEST with VALUE when its session generation is still current."
  (let ((resolver (limen-request-resolver request)))
    (limen--forget-request request)
    (setf (limen-request-resolver request) nil
          (limen-request-rejecter request) nil
          (limen-request-canceller request) nil)
    (when (and resolver (limen--request-current-p request))
      (funcall resolver value)
      t)))

(defun limen-request-reject (request error)
  "Reject REQUEST with ERROR when its session generation is still current."
  (let ((rejecter (limen-request-rejecter request)))
    (limen--forget-request request)
    (setf (limen-request-resolver request) nil
          (limen-request-rejecter request) nil
          (limen-request-canceller request) nil)
    (when (and rejecter (limen--request-current-p request))
      (funcall rejecter error)
      t)))

(defun limen-request-cancel (request error)
  "Cancel deferred REQUEST and reject it with ERROR."
  (let ((canceller (limen-request-canceller request))
        (active (or (limen-request-resolver request)
                    (limen-request-rejecter request)
                    (limen-request-canceller request))))
    (setf (limen-request-canceller request) nil)
    (unwind-protect
        (when canceller (funcall canceller))
      (limen-request-reject request error))
    (and active t)))

(defun limen-session-subscribe (session sink)
  "Subscribe SINK to SESSION and replay its replayable latest events."
  (when (limen-session-closed-p session)
    (signal 'limen-session-closed '("Session is closed")))
  (unless (functionp sink)
    (signal 'wrong-type-argument (list 'functionp sink)))
  (cl-pushnew sink (limen-session-subscribers session) :test #'eq)
  (maphash
   (lambda (name payload)
     (when-let* ((event (gethash name limen--events))
                 ((limen--event-replay event)))
       (funcall sink session name payload)))
   (limen-session-latest session))
  sink)

(defun limen-session-unsubscribe (session sink)
  "Remove SINK from SESSION."
  (setf (limen-session-subscribers session)
        (delq sink (limen-session-subscribers session)))
  t)

(defun limen-session-publish (session name payload)
  "Publish event NAME with PAYLOAD to SESSION.
Return nil when it is identical to the latest published value."
  (when (limen-session-closed-p session)
    (signal 'limen-session-closed '("Session is closed")))
  (let ((event (gethash name limen--events)))
    (unless event
      (signal 'limen-unknown-event (list "Unknown event")))
    (limen--validate-parameters
     (limen--event-parameters event) payload 'limen-invalid-arguments)
    (let* ((previous (gethash name (limen-session-latest session)))
           (previous-value (and previous
                                (assq-delete-all 'sequence (copy-tree previous)))))
      (unless (and (limen--event-replay event)
                   (equal payload previous-value))
        (cl-incf (limen-session-sequence session))
        (let ((value (append (copy-tree payload)
                             `((sequence . ,(limen-session-sequence session))))))
          (puthash name value (limen-session-latest session))
          (dolist (sink (copy-sequence (limen-session-subscribers session)))
            (funcall sink session name value)))
        t))))

(defun limen-close-session (session)
  "Close SESSION and release only its owned resources."
  (unless (limen-session-closed-p session)
    (run-hook-with-args 'limen-session-close-hook session)
    (dolist (request (copy-sequence (limen-session-requests session)))
      (limen-request-cancel request '(limen-session-closed "Session closed")))
    (setf (limen-session-closed-p session) t
          (limen-session-generation session)
          (1+ (limen-session-generation session))
          (limen-session-subscribers session) nil
          (limen-session-requests session) nil)
    (remhash session limen--sessions)
    (limen-release-owner (limen-session-owner session))
    t))

(defun limen--parameter-name (parameter)
  "Return PARAMETER's symbol name."
  (intern (plist-get parameter :name)))

(defun limen--json-type-p (value type)
  "Return non-nil when VALUE has declared JSON TYPE."
  (pcase type
    ('string (stringp value))
    ('integer (integerp value))
    ('number (numberp value))
    ('boolean (or (eq value t) (eq value :json-false)))
    ('object (and (listp value) (seq-every-p #'consp value)))
    ('array (vectorp value))
    ('null (eq value :json-null))
    (_ nil)))

(defun limen--validate-parameter-value (parameter value condition path)
  "Validate VALUE against PARAMETER at PATH, signaling CONDITION on failure."
  (unless (limen--json-type-p value (plist-get parameter :type))
    (signal condition (list (format "Invalid field: %s" path))))
  (when (and (plist-member parameter :enum)
             (not (seq-some (lambda (allowed) (equal value allowed))
                            (plist-get parameter :enum))))
    (signal condition (list (format "Invalid field: %s" path))))
  (pcase (plist-get parameter :type)
    ('array
     (when-let* ((items (plist-get parameter :items)))
       (cl-loop for item across value
                for index from 0
                do (limen--validate-parameter-value
                    items item condition (format "%s[%d]" path index)))))
    ('object
     (limen--validate-parameters
      (plist-get parameter :properties) value condition path))))

(defun limen--validate-parameters (parameters value condition &optional path)
  "Validate VALUE against PARAMETERS, signaling CONDITION on failure.
PATH identifies a containing object when validation is recursive."
  (unless (listp value)
    (signal condition
            (list (if path
                      (format "Invalid field: %s" path)
                    "Value must be a JSON object"))))
  (let ((known (mapcar #'limen--parameter-name parameters)))
    (dolist (entry value)
      (unless (and (consp entry) (memq (car entry) known))
        (signal condition
                (list (format "Unknown field: %s%s"
                              (if path (concat path ".") "")
                              (car-safe entry))))))
    (dolist (parameter parameters)
      (let* ((name (limen--parameter-name parameter))
             (entry (assq name value))
             (field (if path
                        (format "%s.%s" path name)
                      (symbol-name name))))
        (when (and (plist-get parameter :required) (null entry))
          (signal condition (list (format "Missing field: %s" field))))
        (when entry
          (limen--validate-parameter-value
           parameter (cdr entry) condition field)))))
  value)

(defun limen--validate-arguments (operation arguments)
  "Validate ARGUMENTS against OPERATION and return them."
  (limen--validate-parameters
   (limen--operation-parameters operation)
   arguments 'limen-invalid-arguments))

(defun limen--enabled-p (operation request)
  "Return non-nil when OPERATION is enabled for REQUEST."
  (let ((predicate (limen--operation-enabled-p operation)))
    (or (null predicate) (funcall predicate request))))

(defun limen--available-p (operation request)
  "Return non-nil when OPERATION is available for REQUEST."
  (let ((interface (and request (limen-request-interface request))))
    (and (or (null interface)
             (memq interface (limen--operation-interfaces operation)))
         (limen--enabled-p operation request))))

(defun limen--parameters-schema (parameters)
  "Return a strict JSON object schema for PARAMETERS."
  (let ((properties nil)
        (required nil))
    (dolist (parameter parameters)
      (let ((name (limen--parameter-name parameter)))
        (push (cons name (limen--parameter-schema parameter)) properties)
        (when (plist-get parameter :required)
          (push (symbol-name name) required))))
    `((type . "object")
      (properties . ,(or (nreverse properties)
                         (make-hash-table :test #'equal)))
      (required . ,(vconcat (nreverse required)))
      (additionalProperties . :json-false))))

(defun limen--parameter-schema (parameter)
  "Return the JSON schema fragment for PARAMETER."
  (let ((schema
         `((type . ,(symbol-name (plist-get parameter :type)))
           ,@(when-let* ((description (plist-get parameter :description)))
               `((description . ,description))))))
    (when (plist-member parameter :enum)
      (setq schema
            (append schema `((enum . ,(vconcat (plist-get parameter :enum)))))))
    (when-let* ((items (plist-get parameter :items)))
      (setq schema
            (append schema `((items . ,(limen--parameter-schema items))))))
    (when (eq (plist-get parameter :type) 'object)
      (setq schema
            (append schema
                    (cdr (limen--parameters-schema
                          (plist-get parameter :properties))))))
    schema))

(defun limen--operation-schema (operation)
  "Return OPERATION as a JSON-serializable descriptor."
  `((name . ,(limen--operation-name operation))
    (description . ,(limen--operation-description operation))
    (effect . ,(symbol-name (limen--operation-effect operation)))
    ,@(when-let* ((command (limen--operation-command operation)))
        `((command . ,command)))
    (input_schema . ,(limen--parameters-schema
                      (limen--operation-parameters operation)))))

(defun limen--event-schema (event)
  "Return EVENT as a JSON-serializable descriptor."
  `((name . ,(limen--event-name event))
    (description . ,(limen--event-description event))
    (replay . ,(if (limen--event-replay event) t :json-false))
    (payload_schema . ,(limen--parameters-schema
                        (limen--event-parameters event)))))

(defun limen-events ()
  "Return canonical registered event descriptors."
  (let (events)
    (maphash (lambda (_name event)
               (push (limen--event-schema event) events))
             limen--events)
    (sort events
          (lambda (left right)
            (string< (alist-get 'name left) (alist-get 'name right))))))

(defun limen-operations (&optional request)
  "Return descriptors available for optional REQUEST."
  (let (operations)
    (maphash
     (lambda (_name operation)
       (when (and (limen--available-p operation request)
                  (or (not (eq (and request (limen-request-interface request)) 'cli))
                      (not (limen--operation-deferred operation))))
         (push (limen--operation-schema operation) operations)))
     limen--operations)
    (sort operations
          (lambda (left right)
            (string< (alist-get 'name left) (alist-get 'name right))))))

(defun limen-call (name arguments &optional request)
  "Invoke operation NAME with ARGUMENTS and optional REQUEST."
  (let ((operation (gethash name limen--operations)))
    (unless operation
      (signal 'limen-unknown-operation (list "Unknown operation")))
    (unless (limen--available-p operation request)
      (signal 'limen-disabled-operation (list "Operation is disabled")))
    (when (and (eq (and request (limen-request-interface request)) 'cli)
               (limen--operation-deferred operation))
      (signal 'limen-disabled-operation
              (list "Deferred operation is unavailable through the CLI")))
    (let ((result
           (funcall (limen--operation-handler operation)
                    (limen--validate-arguments operation arguments)
                    request)))
      (when (eq result limen-deferred)
        (unless (limen--operation-deferred operation)
          (signal 'limen-operation-failed
                  '("Operation returned an undeclared deferred result")))
        (unless (and request
                     (or (limen-request-resolver request)
                         (limen-request-rejecter request)))
          (signal 'limen-operation-failed
                  '("Deferred operation requires completion callbacks")))
        (when-let* ((session (limen-request-session request)))
          (cl-pushnew request (limen-session-requests session) :test #'eq)))
      result)))

(defun limen--project-file-confined-p (file root)
  "Return non-nil when local FILE is beneath ROOT, ignoring access policy."
  (when (and (stringp file) (stringp root)
             (not (file-remote-p file))
             (not (file-remote-p root)))
    (let* ((root (expand-file-name root))
           (file (expand-file-name file root)))
      (and (not (file-remote-p root))
           (not (file-remote-p file))
           (not (file-symlink-p file))
           (file-in-directory-p
            (if (file-exists-p file)
                (file-truename file)
              (file-truename (file-name-directory file)))
            (file-truename (file-name-as-directory root)))))))

(defun limen--canonical-project-relative-path (file root)
  "Return FILE's canonical path relative to ROOT."
  (let* ((file (expand-file-name file root))
         (canonical
          (if (file-exists-p file)
              (file-truename file)
            (expand-file-name (file-name-nondirectory file)
                              (file-truename (file-name-directory file))))))
    (file-relative-name canonical
                        (file-name-as-directory (file-truename root)))))

(defun limen--project-path-denied-p (file root)
  "Return non-nil when FILE is denied by project path policy below ROOT."
  (condition-case nil
      (seq-some
       (lambda (regexp)
         (string-match-p regexp
                         (limen--canonical-project-relative-path file root)))
       limen-project-path-deny-regexps)
    (error t)))

(defun limen-project-file-p (file root)
  "Return non-nil when local FILE is allowed beneath ROOT."
  (and (limen--project-file-confined-p file root)
       (not (limen--project-path-denied-p file root))))

(defun limen--confined-project-path (value root)
  "Return local VALUE below ROOT as an absolute path, ignoring access policy."
  (when (and (stringp value) (limen--project-file-confined-p value root))
    (expand-file-name value root)))

(defun limen--lexically-confined-project-path (value root)
  "Return local VALUE lexically below ROOT without resolving links."
  (when (and (stringp value) (stringp root)
             (not (file-remote-p value))
             (not (file-remote-p root)))
    (let* ((root (file-name-as-directory (expand-file-name root)))
           (file (expand-file-name value root)))
      (when (and (not (file-remote-p root))
                 (not (file-remote-p file))
                 (string-prefix-p root file
                                  (file-name-case-insensitive-p root)))
        file))))

(defun limen-project-path (value root)
  "Return allowed local VALUE below ROOT as an absolute path, or nil."
  (when (and (stringp value) (limen-project-file-p value root))
    (expand-file-name value root)))

(defun limen--canonical-file-identity (file)
  "Return local FILE's canonical identity, or nil when unavailable."
  (when (and (stringp file) (not (file-remote-p file)))
    (condition-case nil
        (let ((file (expand-file-name file)))
          (when (not (file-remote-p file))
            (if (file-exists-p file)
                (file-truename file)
              (when-let* ((directory (file-name-directory file))
                          ((file-directory-p directory)))
                (expand-file-name (file-name-nondirectory file)
                                  (file-truename directory))))))
      (file-error nil))))

(defun limen--file-equivalent-p (left right)
  "Return non-nil when local paths LEFT and RIGHT identify the same file."
  (when (and (stringp left) (stringp right)
             (not (file-remote-p left))
             (not (file-remote-p right)))
    (condition-case nil
        (if (and (file-exists-p left) (file-exists-p right))
            (file-equal-p left right)
          (equal left right))
      (file-error (equal left right)))))

(defun limen-buffer-file-identity (buffer)
  "Return BUFFER's stable canonical visited-file identity, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (stringp buffer-file-name)
                 (stringp buffer-file-truename)
                 (not (file-remote-p buffer-file-truename)))
        (expand-file-name buffer-file-truename)))))

(defun limen-project-buffer-file (buffer root)
  "Return BUFFER's stable file identity when it is allowed below ROOT."
  (when-let* ((file (limen-buffer-file-identity buffer))
              ((limen-project-file-p file root)))
    file))

(defun limen--same-file-identity-p (file identity)
  "Return non-nil when FILE currently has canonical IDENTITY."
  (limen--file-equivalent-p (limen--canonical-file-identity file) identity))

(defun limen--buffer-file-path (buffer)
  "Return BUFFER's visited path bound to its stable file identity."
  (when-let* ((identity (limen-buffer-file-identity buffer)))
    (with-current-buffer buffer
      (if (limen--same-file-identity-p buffer-file-name identity)
          buffer-file-name
        identity))))

(defun limen--buffer-for-file (file)
  "Return the live buffer whose stable identity matches FILE."
  (when-let* ((identity (limen--canonical-file-identity file)))
    (seq-find (lambda (buffer)
                (limen--file-equivalent-p
                 (limen-buffer-file-identity buffer) identity))
              (buffer-list))))

(defun limen--require-project-root (context)
  "Return CONTEXT's project root, failing closed when it is absent."
  (or (and context (limen-request-project-root context))
      (signal 'limen-operation-failed '("Project root is unavailable"))))

(defun limen--buffer-kind (buffer root)
  "Return BUFFER's project-confined kind relative to ROOT."
  (when (and (buffer-live-p buffer) root)
    (with-current-buffer buffer
      (when (not (string-prefix-p " " (buffer-name buffer)))
        (if buffer-file-name
            (and (limen-project-buffer-file buffer root) 'file)
          (and (limen-project-file-p default-directory root) 'virtual))))))

(defun limen--virtual-buffer-readable-p (buffer)
  "Return non-nil when BUFFER's virtual content is explicitly allowed."
  (condition-case nil
      (and limen-readable-virtual-buffer-condition
           (buffer-match-p limen-readable-virtual-buffer-condition buffer))
    (error nil)))

(defun limen--buffer-readable-p (buffer root)
  "Return non-nil when BUFFER may expose content below ROOT."
  (pcase (limen--buffer-kind buffer root)
    ('file t)
    ('virtual (limen--virtual-buffer-readable-p buffer))))

(defun limen--buffer-record (buffer)
  "Return a JSON record describing BUFFER."
  (with-current-buffer buffer
    `((name . ,(buffer-name buffer))
      (file . ,(limen--buffer-file-path buffer))
      (kind . ,(if buffer-file-name "file" "virtual"))
      (major_mode . ,(symbol-name major-mode))
      (modified . ,(if (buffer-modified-p) t :json-false))
      (tick . ,(buffer-chars-modified-tick))
      (narrowed . ,(if (buffer-narrowed-p) t :json-false))
      (narrowing . ((start . ,(point-min)) (end . ,(point-max)))))))

(defun limen--absolute-line-number (position)
  "Return the one-based absolute line number at POSITION."
  (line-number-at-pos position t))

(defun limen-logical-column-at-position (&optional position)
  "Return the zero-based logical character column at POSITION or point."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (or position (point)))
      (- (point) (line-beginning-position)))))

(defun limen--position-record (position)
  "Return a JSON position record for buffer POSITION."
  `((position . ,position)
    (line . ,(limen--absolute-line-number position))
    (column . ,(limen-logical-column-at-position position))))

(defun limen--selection-bounds (&optional position)
  "Return normalized active selection bounds around POSITION, or nil."
  (when (and mark-active (mark t))
    (let ((point (min (point-max) (max (point-min) (or position (point)))))
          (mark (min (point-max) (max (point-min) (mark t)))))
      (cons (min point mark) (max point mark)))))

(defun limen--selection-record (bounds)
  "Return a JSON selection record for BOUNDS."
  (let ((start (car bounds))
        (end (cdr bounds)))
    `((start . ,start)
      (end . ,end)
      (line . ,(limen--absolute-line-number start))
      (column . ,(limen-logical-column-at-position start))
      (end_line . ,(limen--absolute-line-number end))
      (end_column . ,(limen-logical-column-at-position end))
      (text . ,(buffer-substring-no-properties start end)))))

(defun limen-buffer-context-snapshot (&optional buffer)
  "Return BUFFER's normalized file and selection context."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((bounds (or (limen--selection-bounds)
                       (cons (point) (point))))
           (selection (limen--selection-record bounds)))
      `((path . ,(limen--buffer-file-path (current-buffer)))
        (text . ,(alist-get 'text selection))
        (line . ,(alist-get 'line selection))
        (column . ,(alist-get 'column selection))
        (end_line . ,(alist-get 'end_line selection))
        (end_column . ,(alist-get 'end_column selection))))))

(defun limen--assert-buffer-tick (buffer expected-tick)
  "Signal `limen-conflict' unless BUFFER has EXPECTED-TICK."
  (unless (= (with-current-buffer buffer (buffer-chars-modified-tick))
             expected-tick)
    (signal 'limen-conflict '("Buffer changed since the requested state"))))

(defun limen--buffer-list (arguments context)
  "List project buffers selected by ARGUMENTS using CONTEXT."
  (let ((root (limen-request-project-root context))
        (virtual (eq (alist-get 'virtual arguments) t))
        (all (eq (alist-get 'all arguments) t)))
    (when (and virtual all)
      (signal 'limen-invalid-arguments
              '("The virtual and all fields are mutually exclusive")))
    (vconcat
     (delq nil
           (mapcar
            (lambda (buffer)
              (let ((kind (limen--buffer-kind buffer root)))
                (when (if all kind (eq kind (if virtual 'virtual 'file)))
                  (limen--buffer-record buffer))))
            (buffer-list))))))

(defun limen--buffer-line-range (line end-line)
  "Return accessible text and line bounds selected by LINE and END-LINE."
  (let* ((minimum-line (limen--absolute-line-number (point-min)))
         (maximum-line
          (limen--absolute-line-number
           (if (= (point-min) (point-max))
               (point-max)
             (1- (point-max)))))
         (first-line (or line minimum-line))
         (last-line (or end-line maximum-line)))
    (when (or (< first-line minimum-line)
              (> first-line maximum-line)
              (< last-line minimum-line)
              (> last-line maximum-line)
              (> first-line last-line))
      (signal 'limen-invalid-arguments '("Line is out of range")))
    (goto-char (point-min))
    (forward-line (- first-line minimum-line))
    (let ((start (point)))
      (goto-char (point-min))
      (forward-line (- last-line minimum-line))
      (forward-line 1)
      `((line . ,first-line)
        (end_line . ,last-line)
        (text . ,(buffer-substring-no-properties start (point)))))))

(defun limen--buffer-read (arguments context)
  "Read live buffer text selected by ARGUMENTS using CONTEXT."
  (let ((path-entry (assq 'path arguments))
        (name-entry (assq 'name arguments))
        (line (alist-get 'line arguments))
        (end-line (alist-get 'end_line arguments))
        (widen (eq (alist-get 'widen arguments) t))
        (tick-entry (assq 'expected_tick arguments))
        (root (limen-request-project-root context)))
    (when (eq (null path-entry) (null name-entry))
      (signal 'limen-invalid-arguments
              '("Exactly one of path and name is required")))
    (when (or (and line (< line 1))
              (and end-line (< end-line 1))
              (and line end-line (> line end-line)))
      (signal 'limen-invalid-arguments '("Invalid line range")))
    (let* ((file (and path-entry root
                      (limen-project-path (cdr path-entry) root)))
           (buffer (if path-entry
                       (and file (limen--buffer-for-file file))
                     (get-buffer (cdr name-entry)))))
      (when (and path-entry (null file))
        (signal 'limen-operation-failed
                '("Path is outside the project or denied")))
      (unless buffer
        (signal 'limen-operation-failed
                (list (if path-entry
                          "File is not visited"
                        "Buffer does not exist"))))
      (unless (limen--buffer-kind buffer root)
        (signal 'limen-operation-failed
                '("Buffer is outside the project, denied, or internal")))
      (unless (limen--buffer-readable-p buffer root)
        (signal 'limen-operation-failed
                '("Virtual buffer content is not allowed")))
      (when tick-entry
        (limen--assert-buffer-tick buffer (cdr tick-entry)))
      (let ((record (limen--buffer-record buffer)))
        (with-current-buffer buffer
          (save-excursion
            (save-restriction
              (when widen (widen))
              (append record (limen--buffer-line-range line end-line)))))))))

(defun limen--move-to-logical-column (column)
  "Move to zero-based logical character COLUMN on the current line."
  (forward-char (min (max column 0) (- (line-end-position) (point)))))

(defun limen--select-position
    (buffer line column end-line start-text end-text)
  "Select a location in BUFFER from LINE, COLUMN, and END-LINE.
START-TEXT and END-TEXT refine the selection bounds."
  (with-current-buffer buffer
    (setq mark-active nil)
    (goto-char (point-min))
    (when line (forward-line (1- (max 1 line))))
    (when column (limen--move-to-logical-column column))
    (let ((begin (point))
          finish)
      (when start-text
        (unless (search-forward start-text (and line (line-end-position)) t)
          (setq begin nil))
        (when begin (setq begin (match-beginning 0))))
      (goto-char (or begin (point-min)))
      (cond
       (end-line
        (goto-char (point-min))
        (forward-line (1- (max 1 end-line)))
        (setq finish (line-end-position))
        (when end-text
          (when (search-forward end-text finish t)
            (setq finish (match-end 0)))))
       (end-text
        (when (search-forward end-text nil t)
          (setq finish (match-end 0)))))
      (if (and begin finish)
          (progn (goto-char finish) (push-mark begin t t))
        (goto-char (or begin (point-min)))))))

(defun limen--owner-buffers (owner &optional create)
  "Return OWNER's buffer table, creating it when CREATE is non-nil."
  (or (gethash owner limen--buffers)
      (and create
           (puthash owner (make-hash-table :test #'equal) limen--buffers))))

(defun limen--file-identity-entry (files file)
  "Return FILE's equivalent identity entry from FILES."
  (when (and (hash-table-p files) (stringp file)
             (not (file-remote-p file)))
    (or (when-let* ((record (gethash file files)))
          (cons file record))
        (let (entry)
          (maphash
           (lambda (identity record)
             (when (and (null entry)
                        (limen--file-equivalent-p identity file))
               (setq entry (cons identity record))))
           files)
          entry))))

(defun limen--remember-buffer (owner identity record)
  "Remember that OWNER opened canonical IDENTITY through RECORD."
  (when owner
    (let* ((files (limen--owner-buffers owner t))
           (entry (limen--file-identity-entry files identity))
           same-buffer-identities)
      (maphash
       (lambda (stored-identity stored-record)
         (when (eq (limen--owned-buffer-buffer record)
                   (limen--owned-buffer-buffer stored-record))
           (push stored-identity same-buffer-identities)
           (setf (limen--owned-buffer-owned-p record)
                 (or (limen--owned-buffer-owned-p record)
                     (limen--owned-buffer-owned-p stored-record))
                 (limen--owned-buffer-paths record)
                 (delete-dups
                  (append
                   (copy-sequence (limen--owned-buffer-paths record))
                   (copy-sequence
                    (limen--owned-buffer-paths stored-record)))))))
       files)
      (dolist (stored-identity same-buffer-identities)
        (remhash stored-identity files))
      (puthash (if entry (car entry) identity) record files))))

(defun limen--other-buffer-owner-records (owner buffer)
  "Return records for owners other than OWNER that track live BUFFER."
  (when (buffer-live-p buffer)
    (let (records)
      (maphash
       (lambda (other files)
         (unless (eq other owner)
           (maphash
            (lambda (_identity record)
              (when (eq buffer (limen--owned-buffer-buffer record))
                (push record records)))
            files)))
       limen--buffers)
      records)))

(defun limen--recorded-buffer-entry (files file)
  "Return FILE's equivalent recorded ownership entry from FILES."
  (let (exact case-equivalent equivalent)
    (maphash
     (lambda (identity record)
       (let ((paths (limen--owned-buffer-paths record)))
         (cond
          ((and (null exact) (member file paths))
           (setq exact (cons identity record)))
          ((and (null case-equivalent)
                (seq-some
                 (lambda (path)
                   (and (string-equal-ignore-case path file)
                        (file-name-case-insensitive-p path)))
                 paths))
           (setq case-equivalent (cons identity record)))
          ((and (null equivalent)
                (seq-some
                 (lambda (path)
                   (limen--file-equivalent-p path file))
                 paths))
           (setq equivalent (cons identity record))))))
     files)
    (or exact
        case-equivalent
        (when-let* ((record (gethash file files)))
          (cons file record))
        equivalent)))

(defun limen--owned-buffer-entry (files file)
  "Return FILE's ownership entry from FILES."
  (or (limen--recorded-buffer-entry files file)
      (limen--file-identity-entry files file)
      (when-let* ((identity (limen--canonical-file-identity file)))
        (limen--file-identity-entry files identity))))

(defun limen--buffer-open (arguments context)
  "Open the file in ARGUMENTS using CONTEXT."
  (let* ((root (limen-request-project-root context))
         (file (and root (limen-project-path (alist-get 'path arguments) root)))
         (identity (and file (limen--canonical-file-identity file)))
         (line (alist-get 'line arguments))
         (column (alist-get 'column arguments))
         (end-line (alist-get 'end_line arguments))
         (start-text (alist-get 'start_text arguments))
         (end-text (alist-get 'end_text arguments))
         (owner (limen-request-owner context)))
    (unless (and identity (limen-project-file-p identity root))
      (signal 'limen-operation-failed
              '("Path is outside the project or denied")))
    (let* ((existing (limen--buffer-for-file identity))
           (stale-alias (and (null existing) (get-file-buffer identity)))
           (owned (and owner (limen--owner-buffers owner)))
           (previous-entry
            (and owned (limen--file-identity-entry owned identity)))
           (previous (cdr previous-entry))
           (previous-buffer
            (and previous (limen--owned-buffer-buffer previous)))
           (previous-identity
            (and (buffer-live-p previous-buffer)
                 (limen-buffer-file-identity previous-buffer)))
           (relocation
            (when (and previous
                       (limen--owned-buffer-owned-p previous)
                       (buffer-live-p previous-buffer)
                       (not (limen--file-equivalent-p
                             previous-identity identity)))
              (unless previous-identity
                (signal 'limen-operation-failed
                        '("Tracked buffer has no stable file identity")))
              (let* ((collision-entry
                      (limen--file-identity-entry owned previous-identity))
                     (collision (cdr collision-entry)))
                (when (and collision
                           (not (eq previous-buffer
                                    (limen--owned-buffer-buffer collision))))
                  (signal 'limen-operation-failed
                          '("Tracked buffer identity is already owned")))
                (cons previous-identity collision))))
           (buffer
            (progn
              (when stale-alias
                (signal 'limen-operation-failed
                        '("A visited file alias has a different identity")))
              (let* ((buffers-before-open (buffer-list))
                     (resolved (or existing (find-file-noselect identity)))
                     (created (not (memq resolved buffers-before-open))))
                (unless (limen--file-equivalent-p
                         (limen-project-buffer-file resolved root) identity)
                  (when (and created (buffer-live-p resolved))
                    (with-current-buffer resolved
                      (let ((kill-buffer-query-functions nil))
                        (kill-buffer resolved))))
                  (signal 'limen-operation-failed
                          '("Resolved buffer is outside the project or denied")))
                resolved)))
           (same-buffer-p
            (and previous
                 (buffer-live-p buffer)
                 (eq buffer (limen--owned-buffer-buffer previous))))
           (window (or (get-buffer-window buffer 0)
                       (or (limen-request-window context) (selected-window))))
           (record (limen--make-owned-buffer
                    :buffer buffer :window window
                    :owned-p (or (null existing)
                                 (and same-buffer-p
                                      (limen--owned-buffer-owned-p previous)))
                    :paths (cl-adjoin
                            file
                            (and same-buffer-p
                                 (copy-sequence
                                  (limen--owned-buffer-paths previous)))
                            :test #'equal))))
      (when (window-live-p window) (set-window-buffer window buffer))
      (limen--select-position buffer line column end-line start-text end-text)
      (when (window-live-p window)
        (set-window-point window (with-current-buffer buffer (point))))
      (when relocation
        (let ((relocated-identity (car relocation))
              (collision (cdr relocation)))
          (if collision
              (setf (limen--owned-buffer-owned-p collision) t
                    (limen--owned-buffer-paths collision)
                    (delete-dups
                     (append
                      (copy-sequence (limen--owned-buffer-paths collision))
                      (copy-sequence (limen--owned-buffer-paths previous)))))
            (limen--remember-buffer owner relocated-identity previous))))
      (limen--remember-buffer owner identity record)
      (with-current-buffer buffer
        (append
         (limen--buffer-record buffer)
         `((buffer . ,(buffer-name buffer))
           (line . ,(limen--absolute-line-number (point)))
           (column . ,(limen-logical-column-at-position (point)))))))))

(defun limen-release-buffer (owner file)
  "Release OWNER's tracked FILE buffer and return non-nil on completion."
  (when-let* ((files (limen--owner-buffers owner))
              (entry (limen--owned-buffer-entry files file)))
    (let* ((identity (car entry))
           (record (cdr entry))
           (buffer (limen--owned-buffer-buffer record))
           (window (limen--owned-buffer-window record))
           (other-records
            (limen--other-buffer-owner-records owner buffer)))
      (when (and (window-live-p window) (eq (window-buffer window) buffer))
        (set-window-buffer window (other-buffer buffer t)))
      (when (limen--owned-buffer-owned-p record)
        (dolist (other-record other-records)
          (setf (limen--owned-buffer-owned-p other-record) t)))
      (when (and (limen--owned-buffer-owned-p record)
                 (buffer-live-p buffer)
                 (not (buffer-modified-p buffer))
                 (null other-records)
                 (null (get-buffer-window-list buffer nil 0)))
        (with-current-buffer buffer
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buffer))))
      (when (or (not (limen--owned-buffer-owned-p record))
                (not (buffer-live-p buffer))
                (buffer-modified-p buffer)
                other-records
                (get-buffer-window-list buffer nil 0))
        (remhash identity files))
      (when (= (hash-table-count files) 0)
        (remhash owner limen--buffers))
      (not (gethash identity files)))))

(defun limen-release-owner (owner)
  "Release buffers tracked for opaque OWNER without killing modified buffers."
  (when-let* ((files (limen--owner-buffers owner)))
    (maphash (lambda (file _record) (limen-release-buffer owner file))
             (copy-hash-table files))
    (when (= (hash-table-count files) 0)
      (remhash owner limen--buffers)))
  (null (limen--owner-buffers owner)))

(defun limen--buffer-release (arguments context)
  "Release the buffer in ARGUMENTS using CONTEXT."
  (let* ((root (limen-request-project-root context))
         (owner (limen-request-owner context))
         (requested (alist-get 'path arguments))
         (lexical (and root
                       (limen--lexically-confined-project-path
                        requested root)))
         (files (limen--owner-buffers owner))
         (recorded (and lexical files
                        (limen--recorded-buffer-entry files lexical)))
         (file (or (and recorded lexical)
                   (and root (limen-project-path requested root)))))
    (unless file
      (signal 'limen-operation-failed '("Path is outside the project")))
    (limen-release-buffer owner file)
    "Released buffer"))

(defun limen--buffer-save-destination-p (buffer identity root)
  "Return non-nil when BUFFER will save to authorized IDENTITY below ROOT."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (let ((destinations
                (delq nil (list buffer-file-name buffer-file-truename))))
           (and (seq-every-p
                 (lambda (destination)
                   (and (stringp destination)
                        (not (file-remote-p destination))
                        (let ((expanded (expand-file-name destination)))
                          (and (not (file-remote-p expanded))
                               (limen-project-file-p expanded root)))))
                 destinations)
                (limen--file-equivalent-p
                 (limen-buffer-file-identity buffer) identity)
                (seq-every-p
                 (lambda (destination)
                   (limen--same-file-identity-p destination identity))
                 destinations)
                (limen-project-file-p identity root))))))

(defun limen--file-identifier-current-p (file identifier)
  "Return non-nil when FILE still has IDENTIFIER."
  (condition-case nil
      (equal identifier
             (file-attribute-file-identifier (file-attributes file)))
    (file-error nil)))

(defun limen--buffer-save (arguments context)
  "Save the visited file in ARGUMENTS using CONTEXT."
  (let* ((root (limen-request-project-root context))
         (file (and root
                    (limen-project-path (alist-get 'path arguments) root)))
         (buffer (and file (limen--buffer-for-file file)))
         (identity (and buffer (limen-buffer-file-identity buffer)))
         (expected-tick (alist-get 'expected_tick arguments)))
    (unless file
      (signal 'limen-operation-failed
              '("Path is outside the project or denied")))
    (unless (and buffer identity)
      (signal 'limen-operation-failed '("File is not visited")))
    (unless (limen--buffer-save-destination-p buffer identity root)
      (signal 'limen-operation-failed
              '("Save destination is outside the project or denied")))
    (limen--assert-buffer-tick buffer expected-tick)
    (with-current-buffer buffer
      (let* ((original-name buffer-file-name)
             (original-truename buffer-file-truename)
             (visited-identifier buffer-file-number)
             (backed-up-before buffer-backed-up)
             (backup-file
              (and make-backup-files
                   (not backup-inhibited)
                   (not backed-up-before)
                   (car (find-backup-file-name original-name))))
             (write-region-function (symbol-function 'write-region))
             (destination-guard
              (lambda ()
                (unless (limen--buffer-save-destination-p
                         buffer identity root)
                  (signal 'limen-operation-failed
                          '("Save destination changed during save")))))
             (write-guard
              (lambda ()
                (funcall destination-guard)
                (unless
                    (or (limen--file-identifier-current-p
                         identity visited-identifier)
                        (and (not backed-up-before)
                             buffer-backed-up
                             backup-file
                             (not (file-exists-p identity))
                             (limen--file-identifier-current-p
                              backup-file visited-identifier)))
                  (signal 'limen-conflict '("File changed on disk"))))))
        (unless (and (verify-visited-file-modtime buffer)
                     (limen--file-identifier-current-p
                      identity visited-identifier))
          (signal 'limen-conflict '("File changed on disk")))
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'ask-user-about-supersession-threat)
                         (lambda (_file)
                           (signal 'limen-conflict '("File changed on disk"))))
                        ((symbol-function 'write-region)
                         (lambda (start end filename &rest options)
                           (when (and (eq (current-buffer) buffer)
                                      (or (equal filename buffer-file-name)
                                          (nth 1 options)))
                             (funcall write-guard))
                           (apply write-region-function
                                  start end filename options))))
                (save-buffer))
              (funcall destination-guard)
              (unless (limen--file-identifier-current-p
                       identity buffer-file-number)
                (signal 'limen-conflict '("File changed on disk")))
              (limen--buffer-record buffer))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (unless (limen--buffer-save-destination-p
                       buffer identity root)
                (setq buffer-file-name original-name
                      buffer-file-truename original-truename)))))))))

(defun limen--invisible-span-less-p (left right)
  "Return non-nil when invisible span LEFT precedes RIGHT."
  (let ((left-start (alist-get 'start left))
        (right-start (alist-get 'start right))
        (left-end (alist-get 'end left))
        (right-end (alist-get 'end right)))
    (or (< left-start right-start)
        (and (= left-start right-start)
             (or (< left-end right-end)
                 (and (= left-end right-end)
                      (string< (alist-get 'type left)
                               (alist-get 'type right))))))))

(defun limen--invisible-spans (start end)
  "Return bounded typed invisible spans between START and END."
  (let (spans)
    (dolist (overlay (overlays-in start end))
      (when (overlay-get overlay 'invisible)
        (let ((span-start (max start (overlay-start overlay)))
              (span-end (min end (overlay-end overlay))))
          (when (< span-start span-end)
            (push `((start . ,span-start) (end . ,span-end)
                    (type . "overlay"))
                  spans)))))
    (let ((position start))
      (while (< position end)
        (let ((next (next-single-property-change
                     position 'invisible nil end)))
          (when (get-text-property position 'invisible)
            (push `((start . ,position) (end . ,next)
                    (type . "text-property"))
                  spans))
          (setq position next))))
    (setq spans (sort spans #'limen--invisible-span-less-p))
    (let* ((count (length spans))
           (limit (max 0 limen-focus-invisible-span-limit))
           (truncated (> count limit)))
      (when truncated
        (setq spans (seq-take spans limit)))
      (cons (vconcat spans) truncated))))

(defun limen--terminal-window-p (window)
  "Return non-nil when WINDOW shows a terminal of `limen-focus-terminal-modes'."
  (with-current-buffer (window-buffer window)
    (seq-some (lambda (mode) (derived-mode-p mode)) limen-focus-terminal-modes)))

(defun limen--focus-window (context)
  "Return the window CONTEXT's focus is read from.
That is the live request or selected window, unless it shows an agent's
terminal, in which case the window of its frame used most recently
before it, when there is one."
  (let* ((requested (and context (limen-request-window context)))
         (window (if (window-live-p requested) requested (selected-window))))
    (or (and (limen--terminal-window-p window)
             (get-mru-window (window-frame window) nil t))
        window)))

(defun limen--disclosure-root (buffer root)
  "Return the root BUFFER is disclosed against for a request below ROOT.
Confinement answers with ROOT; without it, BUFFER's own project."
  (if (or limen-confine-to-project (not (buffer-live-p buffer)))
      root
    (limen--project-root (buffer-local-value 'default-directory buffer))))

(defun limen--project-field (root)
  "Return the `project' field naming ROOT for an unconfined record."
  (unless limen-confine-to-project `((project . ,root))))

(defun limen--redacted-virtual-buffer-record (buffer)
  "Return public non-positional metadata for redacted virtual BUFFER."
  (append
   (seq-remove (lambda (entry) (eq (car entry) 'narrowing))
               (limen--buffer-record buffer))
   '((redacted . t))))

(defun limen--focus-get (_arguments context)
  "Return the current focus snapshot for CONTEXT.
Confined, that is the focus within CONTEXT's project; otherwise the
focused buffer answers against its own project."
  (let* ((window (limen--focus-window context))
         (buffer (window-buffer window))
         (root (limen--disclosure-root buffer (limen-request-project-root context)))
         (kind (limen--buffer-kind buffer root)))
    (cond
     ((null kind) nil)
     ((and (eq kind 'virtual)
           (not (limen--virtual-buffer-readable-p buffer)))
      (append (limen--redacted-virtual-buffer-record buffer)
              (limen--project-field root)))
     (t
      (with-current-buffer buffer
        (let* ((window-point (window-point window))
               (point (min (point-max)
                           (max (point-min)
                                (if (markerp window-point)
                                    (marker-position window-point)
                                  window-point))))
               (selection (limen--selection-bounds point))
               (cached-start (window-start window))
               (cached-end (window-end window))
               (visible-start
                (min (point-max) (max (point-min) cached-start)))
               (visible-end
                (and cached-end
                     (min (point-max) (max visible-start cached-end))))
               (span-state
                (if visible-end
                    (limen--invisible-spans visible-start visible-end)
                  (cons [] nil))))
          (append
           (limen--buffer-record buffer)
           `((point . ,(limen--position-record point))
             ,@(when selection
                 `((selection . ,(limen--selection-record selection))))
             (viewport . ((start . ,visible-start)
                          (end . ,(or visible-end :json-null))))
             (invisible_spans . ,(car span-state))
             (truncated . ,(if (cdr span-state) t :json-false)))
           (limen--project-field root))))))))

(defun limen--window-list (_arguments context)
  "List the file windows of the frame in CONTEXT.
Confined, only windows on files of CONTEXT's project; otherwise every
file window, each against its own project."
  (let ((frame (or (limen-request-frame context) (selected-frame)))
        (root (limen--require-project-root context)))
    (vconcat
     (delq
      nil
      (mapcar
       (lambda (window)
         (let* ((buffer (window-buffer window))
                (root (limen--disclosure-root buffer root))
                (identity (limen-project-buffer-file buffer root)))
           (when identity
             `((buffer . ,(buffer-name buffer))
               (file . ,(limen--buffer-file-path buffer))
               (selected . ,(if (eq window (selected-window)) t :json-false))
               (start . ,(window-start window))
               ,@(limen--project-field root)))))
       (window-list frame 'nomini))))))

(defvar limen-context-sections
  '(("project" . limen--context-project)
    ("focus" . limen--context-focus)
    ("windows" . limen--context-windows)
    ("buffers" . limen--context-buffers))
  "Alist of `context.get' section names to functions of one request.
Each function returns a JSON value, or nil to omit the section.")

(defun limen--context-project (context)
  "Return the project section for CONTEXT."
  `((root . ,(limen-request-project-root context))))

(defun limen--context-focus (context)
  "Return the focus section for CONTEXT."
  (limen--focus-get nil context))

(defun limen--context-windows (context)
  "Return the windows section for CONTEXT."
  (limen--window-list nil context))

(defun limen--context-buffers (context)
  "Return the buffers section for CONTEXT."
  (limen--buffer-list '((all . t)) context))

(defun limen--context-get (arguments context)
  "Return the selected `limen-context-sections' for ARGUMENTS and CONTEXT."
  (let ((names (alist-get 'sections arguments)))
    (when (vectorp names)
      (dolist (name (append names nil))
        (unless (assoc name limen-context-sections)
          (signal 'limen-invalid-arguments
                  (list (format "Unknown context section %s" name))))))
    (delq nil
          (mapcar
           (lambda (section)
             (when (or (not (vectorp names))
                       (seq-contains-p names (car section)))
               (when-let* ((value (funcall (cdr section) context)))
                 (cons (intern (car section)) value))))
           limen-context-sections))))

(defun limen--diagnostic-severity (type)
  "Return normalized diagnostic severity for TYPE."
  (let ((name (downcase (if (symbolp type) (symbol-name type) "info"))))
    (cond
     ((string-match-p "error" name) "error")
     ((string-match-p "warn" name) "warning")
     (t "info"))))

(defun limen--diagnostic-record (diagnostic)
  "Return a JSON record for Flymake DIAGNOSTIC."
  (when-let* ((buffer (flymake-diagnostic-buffer diagnostic))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (let ((position (flymake-diagnostic-beg diagnostic)))
          `((file . ,(limen--buffer-file-path buffer))
            (message . ,(flymake-diagnostic-text diagnostic))
            (line . ,(limen--absolute-line-number position))
            (column . ,(limen-logical-column-at-position position))
            (severity . ,(limen--diagnostic-severity
                          (flymake-diagnostic-type diagnostic)))
            (source . "flymake")))))))

(defun limen--flycheck-diagnostic-record (error buffer)
  "Return a JSON record for an already computed Flycheck ERROR in BUFFER."
  (let ((line (flycheck-error-line error)))
    (when (and (integerp line) (> line 0))
      (let* ((filename (or (flycheck-error-filename error)
                           (limen--buffer-file-path buffer)))
             (file (and filename
                        (limen--canonical-file-identity
                         (expand-file-name
                          filename
                          (buffer-local-value 'default-directory buffer)))))
             (column (flycheck-error-column error)))
        `((file . ,file)
          (message . ,(or (flycheck-error-message error) ""))
          (line . ,line)
          (column . ,(if (integerp column) (max 0 (1- column)) 0))
          (severity . ,(limen--diagnostic-severity
                        (flycheck-error-level error)))
          (source . "flycheck"))))))

(defun limen--diagnostic-uri-file (uri root)
  "Return the allowed local file named by URI below ROOT."
  (let* ((parsed (and (stringp uri) (url-generic-parse-url uri)))
         (host (and parsed (url-host parsed)))
         (filename
          (and parsed
               (equal (url-type parsed) "file")
               (member host '(nil "" "localhost"))
               (url-filename parsed)))
         (decoded
          (and filename
               (decode-coding-string (url-unhex-string filename) 'utf-8)))
         (file (and decoded root (limen-project-path decoded root)))
         (identity (and file (limen--canonical-file-identity file))))
    (unless identity
      (signal 'limen-operation-failed
              '("Diagnostic URI is outside the project or denied")))
    identity))

(defun limen--diagnostic-file-selected-p (file root target)
  "Return non-nil when FILE is allowed below ROOT and matches TARGET."
  (and file
       (limen-project-file-p file root)
       (or (null target)
           (limen--same-file-identity-p file target))))

(defun limen--diagnostic-less-p (left right)
  "Return non-nil when diagnostic LEFT precedes RIGHT."
  (string<
   (format "%s\0%020d\0%020d\0%s\0%s\0%s"
           (alist-get 'file left) (alist-get 'line left)
           (alist-get 'column left) (alist-get 'severity left)
           (alist-get 'source left) (alist-get 'message left))
   (format "%s\0%020d\0%020d\0%s\0%s\0%s"
           (alist-get 'file right) (alist-get 'line right)
           (alist-get 'column right) (alist-get 'severity right)
           (alist-get 'source right) (alist-get 'message right))))

(defun limen--diagnostic-list (arguments context)
  "List computed project diagnostics selected by ARGUMENTS using CONTEXT."
  (let* ((root (limen--require-project-root context))
         (uri (alist-get 'uri arguments))
         (target (and uri (limen--diagnostic-uri-file uri root)))
         diagnostics)
    (dolist (buffer (buffer-list))
      (when-let* ((file (limen-project-buffer-file buffer root))
                  ((limen--diagnostic-file-selected-p file root target)))
        (with-current-buffer buffer
          (when (fboundp 'flymake-diagnostics)
            (dolist (diagnostic (flymake-diagnostics))
              (when-let* ((record (limen--diagnostic-record diagnostic))
                          ((limen--diagnostic-file-selected-p
                            (alist-get 'file record) root target)))
                (push record diagnostics))))
          (when (and (featurep 'flycheck)
                     (boundp 'flycheck-current-errors))
            (dolist (error flycheck-current-errors)
              (when-let* ((record
                           (limen--flycheck-diagnostic-record error buffer))
                          ((limen--diagnostic-file-selected-p
                            (alist-get 'file record) root target)))
                (push record diagnostics)))))))
    (vconcat
     (sort (delete-dups diagnostics) #'limen--diagnostic-less-p))))

(defun limen--eval (arguments _context)
  "Evaluate the code in ARGUMENTS."
  (let ((code (alist-get 'code arguments))
        (position 0)
        value)
    (condition-case err
        (while t
          (pcase-let ((`(,form . ,next) (read-from-string code position)))
            (setq value (eval form t)
                  position next)))
      (end-of-file
       (unless (string-match-p "\\`\\(?:[ \t\n\r]+\\|;[^\n]*\\)*\\'"
                               (substring code position))
         (signal (car err) (cdr err)))))
    (prin1-to-string value)))

(defun limen--known-project-roots ()
  "Return known project roots from Projectile or `project.el'."
  (let ((roots (if (require 'projectile nil t)
                   (projectile-relevant-known-projects)
                 (project-known-project-roots))))
    (delete-dups
     (mapcar (lambda (root)
               (file-name-as-directory (file-truename root)))
             (seq-filter #'file-directory-p roots)))))

(defun limen--project-list (_arguments context)
  "List known projects using CONTEXT to identify the current project."
  (let ((current (limen-request-project-root context)))
    (vconcat
     (mapcar
      (lambda (root)
        `((name . ,(file-name-nondirectory (directory-file-name root)))
          (root . ,root)
          (current . ,(if (and current (file-equal-p root current))
                          t
                        :json-false))))
      (limen--known-project-roots)))))

(defun limen--project-root (directory)
  "Return a canonical project root for DIRECTORY."
  (let* ((default-directory (file-name-as-directory (expand-file-name directory)))
         (projectile-root
          (when (require 'projectile nil t)
            (let ((projectile-require-project-root nil))
              (projectile-project-root default-directory))))
         (project (and (null projectile-root)
                       (project-current nil default-directory))))
    (file-truename
     (or projectile-root
         (and project (project-root project))
         default-directory))))

(defun limen-skill (&optional context)
  "Return the current agent skill for optional CONTEXT."
  (concat
   "# limen\n\n"
   "Use `limen` to inspect or operate the local Emacs session.\n\n"
   "## Commands\n\n"
   "Run `limen --help` for the live command index and "
   "`limen help COMMAND` for command-specific arguments. "
   "Normal output is one JSON object.\n\n"
   "## Operations\n\n"
   (mapconcat
    (lambda (operation)
      (if-let* ((command (alist-get 'command operation)))
          (format "- `limen %s` (%s, %s): %s"
                  command
                  (alist-get 'name operation)
                  (alist-get 'effect operation)
                  (alist-get 'description operation))
        (format "- `%s` (%s): %s"
                (alist-get 'name operation)
                (alist-get 'effect operation)
                (alist-get 'description operation))))
    (limen-operations context) "\n")
   "\n\n"
   "## Authority\n\n"
   "This interface uses the current user's local Emacs server. It reduces "
   "accidental misuse and payload quoting errors; it is not a sandbox.\n"))

(defun limen--success (operation result)
  "Return a successful envelope for OPERATION and RESULT."
  `((version . ,limen-protocol-version) (ok . t)
    ,@(when operation `((operation . ,operation)))
    (result . ,result)))

(defun limen--failure (operation code message)
  "Return a failure envelope for OPERATION with CODE and MESSAGE."
  `((version . ,limen-protocol-version) (ok . :json-false)
    ,@(when operation `((operation . ,operation)))
    (error . ((code . ,code) (message . ,message)))))

(defun limen--dispatch-error (condition operation)
  "Map CONDITION for OPERATION to a status and envelope."
  (let* ((type (car condition))
         (message (or (cadr condition) "Operation failed"))
         (mapping
          (cond
           ((eq type 'limen-unsupported-version) '(2 . "unsupported_version"))
           ((eq type 'limen-invalid-request) '(2 . "invalid_request"))
           ((eq type 'limen-unknown-operation) '(3 . "unknown_operation"))
           ((eq type 'limen-disabled-operation) '(3 . "disabled_operation"))
           ((eq type 'limen-invalid-arguments) '(3 . "invalid_arguments"))
           ((eq type 'limen-conflict) '(6 . "conflict"))
           ((eq type 'limen-operation-failed) '(5 . "operation_failed"))
           (t '(5 . "internal_error")))))
    (cons (car mapping)
          (limen--failure operation (cdr mapping)
                          (if (eq (car mapping) 5)
                              (if (eq type 'limen-operation-failed)
                                  message
                                "Internal error")
                            message)))))

(defun limen--decode-request (encoded)
  "Decode and validate the Base64 JSON request ENCODED."
  (unless (and (stringp encoded)
               (string-match-p "\\`[A-Za-z0-9+/]*=\\{0,2\\}\\'" encoded))
    (signal 'limen-invalid-request '("Malformed request encoding")))
  (condition-case nil
      (json-parse-string
       (decode-coding-string (base64-decode-string encoded) 'utf-8)
       :object-type 'alist :array-type 'array :null-object :json-null
       :false-object :json-false)
    (error (signal 'limen-invalid-request '("Malformed JSON request")))))

(defun limen--decode-cli-argument (value)
  "Decode a Base64-wrapped CLI argument VALUE."
  (if (and (listp value)
           (= (length value) 1)
           (eq (caar value) 'base64))
      (let ((encoded (cdar value)))
        (unless (and (stringp encoded)
                     (string-match-p "\\`[A-Za-z0-9+/]*=\\{0,2\\}\\'" encoded))
          (signal 'limen-invalid-request '("Malformed command argument")))
        (condition-case nil
            (decode-coding-string (base64-decode-string encoded) 'utf-8)
          (error (signal 'limen-invalid-request
                         '("Malformed command argument")))))
    value))

(defun limen--decode-cli-arguments (arguments)
  "Decode Base64-wrapped values in CLI ARGUMENTS."
  (mapcar (lambda (argument)
            (cons (car argument)
                  (limen--decode-cli-argument (cdr argument))))
          arguments))

(defun limen--request-context (request)
  "Build an invocation context from REQUEST."
  (let ((encoded (alist-get 'cwd_base64 request)))
    (unless (stringp encoded)
      (signal 'limen-invalid-request '("Missing working directory")))
    (let ((directory
           (condition-case nil
               (decode-coding-string (base64-decode-string encoded) 'utf-8)
             (error (signal 'limen-invalid-request
                            '("Malformed working directory"))))))
      (unless (file-directory-p directory)
        (signal 'limen-invalid-request '("Working directory does not exist")))
      (limen-make-request
       :interface 'cli :source 'cli
       :project-root (limen--project-root directory)
       :frame (selected-frame) :window (selected-window)))))

(defun limen--dispatch (request)
  "Dispatch parsed REQUEST and return a status plus payload."
  (let ((operation (alist-get 'operation request)))
    (condition-case condition
        (progn
          (unless (equal (alist-get 'version request) limen-protocol-version)
            (signal 'limen-unsupported-version '("Unsupported protocol version")))
          (let ((method (alist-get 'method request))
                (context (limen--request-context request)))
            (pcase method
              ("operations"
               (cons 0 (limen--success nil (vconcat (limen-operations context)))))
              ("call"
               (let ((arguments (alist-get 'arguments request)))
                 (unless (and (stringp operation) (listp arguments))
                   (signal 'limen-invalid-request '("Invalid call request")))
                 (cons 0 (limen--success
                          operation
                          (limen-call operation
                                      (limen--decode-cli-arguments arguments)
                                      context)))))
              ("skill" (cons 0 (limen-skill context)))
              ("hook"
               (unless (fboundp 'limen-hooks-output)
                 (signal 'limen-invalid-request '("Prompt hooks are unavailable")))
               (cons 0 (limen-hooks-output request context)))
              (_ (signal 'limen-invalid-request '("Unknown method"))))))
      (error (limen--dispatch-error condition operation)))))

(defun limen-server-dispatch (encoded-request)
  "Dispatch ENCODED-REQUEST and return `STATUS:BASE64(PAYLOAD)'."
  (let* ((response
          (condition-case condition
              (limen--dispatch (limen--decode-request encoded-request))
            (error (limen--dispatch-error condition nil))))
         (status (car response))
         (value (cdr response))
         (payload (if (stringp value)
                      value
                    (json-serialize value :null-object nil
                                    :false-object :json-false))))
    (format "%d:%s" status
            (base64-encode-string (encode-coding-string payload 'utf-8) t))))

(limen-register-operation
 "buffer.list" #'limen--buffer-list
 :command "buffer list"
 :description "List project-confined Emacs buffers."
 :effect 'read
 :parameters '((:name "virtual" :type boolean
                      :description "List virtual buffers instead of file buffers.")
               (:name "all" :type boolean
                      :description "List file and virtual buffers."))
 :interfaces '(cli mcp))

(limen-register-operation
 "buffer.read" #'limen--buffer-read
 :command "buffer read"
 :description "Read live text from a project-confined Emacs buffer."
 :effect 'read
 :parameters '((:name "path" :type string
                      :description "Project-relative or absolute visited file path.")
               (:name "name" :type string
                      :description "Live Emacs buffer name.")
               (:name "line" :type integer :description "One-based start line.")
               (:name "end_line" :type integer :description "One-based end line.")
               (:name "widen" :type boolean
                      :description "Temporarily ignore buffer narrowing.")
               (:name "expected_tick" :type integer
                      :description "Required current character modification tick."))
 :interfaces '(cli mcp))

(limen-register-operation
 "buffer.save" #'limen--buffer-save
 :command "buffer save"
 :description "Save a visited file when its buffer and disk state are current."
 :effect 'write
 :parameters '((:name "path" :type string :required t
                      :description "Project-relative or absolute visited file path.")
               (:name "expected_tick" :type integer :required t
                      :description "Required current character modification tick."))
 :interfaces '(cli mcp))

(limen-register-operation
 "buffer.open" #'limen--buffer-open
 :command "buffer open"
 :description "Open a local file in an Emacs buffer."
 :effect 'write
 :parameters '((:name "path" :type string :required t
                      :description "Project-relative or absolute file path.")
               (:name "line" :type integer :description "One-based start line.")
               (:name "column" :type integer :description "Zero-based start column.")
               (:name "end_line" :type integer :description "One-based end line.")
               (:name "start_text" :type string :description "Text locating the start.")
               (:name "end_text" :type string :description "Text locating the end."))
 :interfaces '(cli mcp))

(limen-register-operation
 "buffer.release" #'limen--buffer-release
 :description "Release an Emacs buffer the requesting session opened."
 :effect 'write :interfaces '(mcp)
 :parameters '((:name "path" :type string :required t)))

(limen-register-operation
 "project.list" #'limen--project-list
 :command "projects"
 :description "List known projects."
 :effect 'read :parameters nil :interfaces '(cli))

(limen-register-operation
 "focus.get" #'limen--focus-get
 :command "focus"
 :description "Read the focus of the selected window, or of the window used before an agent's terminal."
 :effect 'read :parameters nil :interfaces '(cli mcp))

(limen-register-operation
 "context.get" #'limen--context-get
 :command "context"
 :description "Read the current editor context in one call: project, focus, windows, buffers, and any optional sections."
 :effect 'read
 :parameters '((:name "sections" :type array :items (:type string)
                      :description "Section names to include; omit for all."))
 :interfaces '(cli mcp))

(limen-register-operation
 "window.list" #'limen--window-list
 :command "windows"
 :description "List windows in the selected Emacs frame."
 :effect 'read :parameters nil :interfaces '(cli mcp))

(limen-register-operation
 "diagnostic.list" #'limen--diagnostic-list
 :command "diagnostics"
 :description "List computed Flymake and loaded Flycheck diagnostics."
 :effect 'read
 :parameters '((:name "uri" :type string :description "Optional file URI."))
 :interfaces '(cli mcp))

(limen-register-operation
 "elisp.eval" #'limen--eval
 :command "eval"
 :description "Evaluate explicitly enabled Emacs Lisp."
 :effect 'write :parameters '((:name "code" :type string :required t))
 :enabled-p (lambda (_context) limen-enable-elisp-eval))

(limen-register-event
 "context.selection"
 :description "Report the latest project file selection."
 :parameters '((:name "path" :type string :required t)
               (:name "line" :type integer :required t)
               (:name "column" :type integer :required t)
               (:name "end_line" :type integer)
               (:name "end_column" :type integer)
               (:name "text" :type string))
 :replay t)

(limen-register-event
 "context.push"
 :description "Push explicit project context to an agent."
 :parameters '((:name "path" :type string :required t)
               (:name "line" :type integer :required t)
               (:name "column" :type integer :required t)
               (:name "end_line" :type integer)
               (:name "end_column" :type integer)
               (:name "text" :type string)
               (:name "items" :type array
                      :items (:type object
                                    :properties
                                    ((:name "type" :type string :required t
                                            :enum ("file"))
                                     (:name "path" :type string :required t)
                                     (:name "line" :type integer)
                                     (:name "column" :type integer)
                                     (:name "end_line" :type integer)
                                     (:name "end_column" :type integer)
                                     (:name "text" :type string))))))

(provide 'limen)
;;; limen.el ends here
