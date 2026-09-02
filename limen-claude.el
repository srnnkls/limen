;;; limen-claude.el --- Claude Code compatibility transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Provides Claude Code's loopback WebSocket interface over Limen sessions.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'limen)
(require 'limen-editor)
(require 'seq)

(declare-function websocket-server "websocket" (port &rest plist))
(declare-function websocket-server-close "websocket" (server))
(declare-function websocket-close "websocket" (websocket))
(declare-function websocket-send-text "websocket" (websocket text))
(declare-function websocket-frame-text "websocket" (frame))

(cl-defstruct limen-claude-client
  raw open-p initialized-p generation state owner)

(cl-defstruct limen-claude-request
  state client generation id owner operation resolved-p)

(cl-defstruct limen-claude-state
  session event-sink project-root instance-id instance-name state endpoint endpoint-live-p
  server lockfile discovery environment clients current-client client-generation
  reconnect-deadline reconnect-deadline-seconds reconnect-token tool-list tool-call
  raw-clients)

(defvar limen-claude--states (make-hash-table :test #'eq))
(defvar limen-claude--defer-close nil)
(defvar limen-claude--close-after-send nil)
(defvar limen-claude--incoming-observers nil)
(defvar limen-claude--outgoing-observers nil)

(defconst limen-claude--invalid-params
  'limen-claude--invalid-params)

(defun limen-claude--value (key object)
  "Return KEY's value from OBJECT."
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)
      (plist-get object (intern (concat ":" (symbol-name key))))))

(defun limen-claude--registry-states (&optional states)
  "Return states from STATES or the global registry."
  (cond ((hash-table-p states)
         (let (values) (maphash (lambda (_ state) (push state values)) states) values))
        ((null states)
         (limen-claude--registry-states limen-claude--states))
        ((limen-claude-state-p (car states)) states)
        (t (mapcar #'cdr states))))

(defun limen-claude--port (server)
  "Return SERVER's listening port."
  (let ((service (plist-get (process-contact server t) :service)))
    (if (stringp service) (string-to-number service) service)))

(defun limen-claude--project-root (root)
  "Return ROOT in canonical project form."
  (and root (directory-file-name (file-truename root))))

(defun limen-claude--same-project-root-p (left right)
  "Return non-nil when LEFT and RIGHT name the same project."
  (and left right
       (equal (limen-claude--project-root left)
              (limen-claude--project-root right))))

(defun limen-claude--state-root (state)
  "Return STATE's project root."
  (limen-claude-state-project-root state))

(defun limen-claude--current-client-p (state)
  "Return non-nil when STATE has an initialized client."
  (when-let* ((session (limen-claude-state-session state))
              ((not (limen-session-closed-p session)))
              (client (limen-claude-state-current-client state)))
    (and (limen-claude-client-open-p client)
         (limen-claude-client-initialized-p client))))

(defun limen-claude--observe (observers state client text)
  "Notify OBSERVERS of TEXT for STATE and CLIENT."
  (dolist (observer (symbol-value observers))
    (condition-case nil
        (funcall observer state client text)
      (error nil))))

(defun limen-claude--send (state client payload)
  "Send PAYLOAD through CLIENT for STATE."
  (when (limen-claude-client-open-p client)
    (let ((text (json-serialize payload :false-object :json-false :null-object nil)))
      (limen-claude--observe
       'limen-claude--outgoing-observers state client text)
      (websocket-send-text (limen-claude-client-raw client) text)
      t)))

(defun limen-claude--notify (client method payload)
  "Send METHOD with PAYLOAD to CLIENT."
  (limen-claude--send
   (limen-claude-client-state client) client
   `((jsonrpc . "2.0") (method . ,method) (params . ,payload))))

(defun limen-claude-broadcast-project-context (states root method payload)
  "Send METHOD and PAYLOAD to initialized states in ROOT.
STATES selects a registry; nil uses the global registry."
  (let ((root (limen-claude--project-root root)))
    (dolist (state (limen-claude--registry-states states))
      (when (and (limen-claude--same-project-root-p
                  root (limen-claude--state-root state))
                 (limen-claude--current-client-p state))
        (limen-claude--notify
         (limen-claude-state-current-client state) method payload)))))

(defun limen-claude--selection-payload (snapshot)
  "Convert normalized Emacs SNAPSHOT to Claude selection payload."
  `((filePath . ,(alist-get 'path snapshot))
    (text . ,(alist-get 'text snapshot))
    (selection . ((start . ((line . ,(1- (alist-get 'line snapshot)))
                            (character . ,(alist-get 'column snapshot))))
                  (end . ((line . ,(1- (alist-get 'end_line snapshot)))
                          (character . ,(alist-get 'end_column snapshot))))))))

(defun limen-claude--integration-event (state _session name payload)
  "Translate shared event NAME with PAYLOAD for Claude protocol STATE."
  (when (limen-claude--current-client-p state)
    (pcase name
      ("context.selection"
       (limen-claude--notify
        (limen-claude-state-current-client state)
        "selection_changed"
        (limen-claude--selection-payload payload)))
      ("context.push"
       (limen-claude--notify
        (limen-claude-state-current-client state)
        "at_mentioned"
        `((filePath . ,(alist-get 'path payload))
          (lineStart . ,(alist-get 'line payload))
          (lineEnd . ,(alist-get 'end_line payload))))))))

(defun limen-claude-bind-session (state session)
  "Bind Claude transport STATE to Limen SESSION events."
  (when-let* ((old (limen-claude-state-session state))
              (sink (limen-claude-state-event-sink state)))
    (limen-session-unsubscribe old sink))
  (let ((sink (lambda (actual-session name payload)
                (limen-claude--integration-event
                 state actual-session name payload))))
    (setf (limen-claude-state-session state) session
          (limen-claude-state-project-root state)
          (limen-session-project-root session)
          (limen-claude-state-event-sink state) sink)
    (limen-session-subscribe session sink))
  state)

(defun limen-claude--cancel-selection (state)
  "Cancel STATE's pending Emacs selection notification."
  (when-let* ((client (limen-claude-state-current-client state))
              (owner (limen-claude-client-owner client)))
    (limen-editor-cancel-selection owner)))

(defun limen-claude--state-for-target (target &optional states)
  "Return Claude state for Limen TARGET from STATES."
  (cond
   ((limen-claude-state-p target) target)
   ((not (limen-session-p target)) nil)
   (states
    (cl-find target (limen-claude--registry-states states)
             :key #'limen-claude-state-session :test #'eq))
   (t (gethash target limen-claude--states))))

(defun limen-claude-send-at-mentioned (target &optional states)
  "Send current selection as an at-mention to Limen TARGET in STATES."
  (when-let* ((state (limen-claude--state-for-target target states))
              (file (buffer-file-name))
              ((limen-project-file-p file (limen-claude--state-root state)))
              ((limen-claude--current-client-p state))
              (session (limen-claude-state-session state)))
    (limen-session-publish
     session "context.push" (limen-editor-context-snapshot))))

(defun limen-claude--start-server (state)
  "Start STATE's local MCP WebSocket server."
  (unless (require 'websocket nil t)
    (error "Claude protocol transport requires websocket.el"))
  (let ((server
         (websocket-server
          0 :host "127.0.0.1" :protocol '("mcp")
          :on-open (lambda (raw)
                     (puthash raw
                              (limen-claude-client-connect state raw)
                              (limen-claude-state-raw-clients state)))
          :on-message (lambda (raw frame)
                        (when-let* ((client (gethash raw
                                                     (limen-claude-state-raw-clients state))))
                          (let ((limen-claude--defer-close t)
                                (limen-claude--close-after-send nil))
                            (when-let* ((response (limen-claude-receive
                                                   state client (websocket-frame-text frame))))
                              (unwind-protect
                                  (limen-claude--send state client response)
                                (when limen-claude--close-after-send
                                  (limen-claude-client-close state client)))))))
          :on-close (lambda (raw)
                      (when-let* ((client (gethash raw
                                                   (limen-claude-state-raw-clients state))))
                        (limen-claude-client-close state client))))))
    (setf (limen-claude-state-server state) server)
    (limen-claude--port server)))

(defun limen-claude--default-tools ()
  "Return the default MCP tool definitions."
  (let ((empty-properties (make-hash-table :test #'equal)))
    (list
     '((name . "openFile") (description . "Open a file in Emacs.")
       (inputSchema . ((type . "object")
                       (properties . ((filePath . ((type . "string")))
                                      (startLine . ((type . "integer")))
                                      (endLine . ((type . "integer")))
                                      (startText . ((type . "string")))
                                      (endText . ((type . "string")))))
                       (required . ["filePath"]))))
     '((name . "getDiagnostics") (description . "Get diagnostics for visited files.")
       (inputSchema . ((type . "object") (properties . ((uri . ((type . "string")))))
                       (required . []))))
     '((name . "close_tab")
       (description . "Release the requesting session buffer or diff.")
       (inputSchema . ((type . "object")
                       (properties . ((path . ((type . "string")))
                                      (tab_name . ((type . "string")))))
                       (required . []))))
     '((name . "openDiff") (description . "Open an editable diff.")
       (inputSchema . ((type . "object")
                       (properties . ((old_file_path . ((type . "string")))
                                      (new_file_path . ((type . "string")))
                                      (new_file_contents . ((type . "string")))
                                      (tab_name . ((type . "string")))))
                       (required . ["new_file_contents" "new_file_path" "old_file_path" "tab_name"]))))
     `((name . "closeAllDiffTabs") (description . "Close all session-owned diffs.")
       (inputSchema . ((type . "object") (properties . ,empty-properties)
                       (required . [])))))))

(defun limen-claude--available-tools ()
  "Return the Claude compatibility tool definitions."
  (limen-claude--default-tools))

(defun limen-claude--wire-argument (key target arguments)
  "Map wire KEY in ARGUMENTS to canonical TARGET when present."
  (when-let* ((value (limen-claude--value key arguments)))
    (cons target value)))

(defun limen-claude--normalize-tool-call (name arguments)
  "Return canonical operations for wire tool NAME and ARGUMENTS."
  (when (listp arguments)
    (pcase name
      ("openFile"
       (list
        (cons "buffer.open"
              (delq nil
                    (list
                     (limen-claude--wire-argument
                      'filePath 'path arguments)
                     (limen-claude--wire-argument
                      'startLine 'line arguments)
                     (limen-claude--wire-argument
                      'endLine 'end_line arguments)
                     (limen-claude--wire-argument
                      'startText 'start_text arguments)
                     (limen-claude--wire-argument
                      'endText 'end_text arguments))))))
      ("getDiagnostics"
       (list
        (cons "diagnostic.list"
              (delq nil
                    (list (limen-claude--wire-argument
                           'uri 'uri arguments))))))
      ("close_tab"
       (or (delq nil
                 (list
                  (when-let* ((path (limen-claude--value
                                     'path arguments)))
                    (list "buffer.release" (cons 'path path)))
                  (when-let* ((diff-name (limen-claude--value
                                          'tab_name arguments)))
                    (list "diff.close" (cons 'name diff-name)))))
           'noop))
      ("openDiff"
       (list
        (cons "diff.open"
              (delq nil
                    (list
                     (limen-claude--wire-argument
                      'old_file_path 'old_path arguments)
                     (limen-claude--wire-argument
                      'new_file_path 'new_path arguments)
                     (limen-claude--wire-argument
                      'new_file_contents 'contents arguments)
                     (limen-claude--wire-argument
                      'tab_name 'name arguments))))))
      ("closeAllDiffTabs" (list (cons "diff.close-all" nil))))))

(defun limen-claude--operation-result (operation result)
  "Normalize RESULT from canonical OPERATION for Claude."
  (cond
   ((equal operation "buffer.open") "Opened file")
   ((or (stringp result) (equal operation "diagnostic.list")) result)
   (t (json-serialize result :false-object :json-false :null-object nil))))

(defun limen-claude--tool-result (operation result)
  "Convert OPERATION RESULT to a Claude tool result."
  (cond
   ((equal operation "diagnostic.list")
    `((content . ,(vconcat
                   (mapcar
                    (lambda (diagnostic)
                      `((filePath . ,(limen-claude--value
                                      'file diagnostic))
                        (message . ,(limen-claude--value
                                     'message diagnostic))
                        (line . ,(limen-claude--value
                                  'line diagnostic))
                        (column . ,(limen-claude--value
                                    'column diagnostic))
                        (severity . ,(limen-claude--value
                                      'severity diagnostic))))
                    (append result nil))))))
   ((equal operation "diff.open")
    `((content
       . ,(cond
           ((equal result "")
            [((type . "text") (text . "TAB_CLOSED"))])
           ((equal result "Diff rejected")
            [((type . "text") (text . "DIFF_REJECTED"))])
           (t
            `[((type . "text") (text . "FILE_SAVED"))
              ((type . "text")
               (text . ,(limen-claude--operation-result
                         operation result)))])))))
   (t
    `((content . [((type . "text")
                   (text . ,(limen-claude--operation-result
                             operation result)))])))))

(defun limen-claude--request-current-p (request)
  "Return non-nil when REQUEST may still send a response."
  (let ((state (limen-claude-request-state request))
        (client (limen-claude-request-client request)))
    (and (not (limen-claude-request-resolved-p request))
         (eq client (limen-claude-state-current-client state))
         (limen-claude-client-open-p client)
         (limen-claude-client-initialized-p client)
         (= (limen-claude-request-generation request)
            (limen-claude-state-client-generation state)))))

(defun limen-claude-resolve (request result)
  "Resolve opaque REQUEST with normalized Emacs RESULT."
  (when (limen-claude--request-current-p request)
    (setf (limen-claude-request-resolved-p request) t)
    (limen-claude--send
     (limen-claude-request-state request)
     (limen-claude-request-client request)
     (limen-claude--response
      (limen-claude-request-id request)
      (limen-claude--tool-result
       (limen-claude-request-operation request) result)))))

(defun limen-claude-reject (request code message)
  "Reject opaque REQUEST with CODE and MESSAGE."
  (when (limen-claude--request-current-p request)
    (setf (limen-claude-request-resolved-p request) t)
    (limen-claude--send
     (limen-claude-request-state request)
     (limen-claude-request-client request)
     (limen-claude--error
      (limen-claude-request-id request) code message))))

(defun limen-claude--dispatch-operation (state name arguments request)
  "Dispatch Claude tool NAME and ARGUMENTS for STATE using opaque REQUEST."
  (condition-case condition
      (let ((calls (limen-claude--normalize-tool-call name arguments))
            result)
        (cond
         ((eq calls 'noop)
          "No buffer or diff specified")
         ((null calls)
          (cons limen-claude--invalid-params "Invalid params"))
         (t
          (dolist (call calls result)
            (let ((operation (car call)))
              (setf (limen-claude-request-operation request) operation)
              (setq result
                    (limen-call
                     operation (cdr call)
                     (let ((session (limen-claude-state-session state)))
                       (limen-make-request
                        :interface 'adapter :source 'claude-ide :session session
                        :owner (if session
                                   (limen-session-owner session)
                                 (limen-claude-request-owner request))
                        :project-root (if session
                                          (limen-session-project-root session)
                                        (limen-claude--state-root state))
                        :generation (if session
                                        (limen-session-generation session)
                                      (limen-claude-request-generation request))
                        :frame (selected-frame) :window (selected-window)
                        :resolve
			(lambda (value)
                          (limen-claude-resolve request value))
			:reject
			(lambda (&optional _error)
                          (limen-claude-reject
                           request -32800 "Request cancelled"))))))
              (unless (eq result limen-deferred)
                (setq result
                      (limen-claude--operation-result operation result))))))))
    ((limen-invalid-arguments limen-disabled-operation
			      limen-operation-failed)
     (cons limen-claude--invalid-params
           (or (cadr condition) "Invalid params")))))

(defun limen-claude--initialize-result ()
  "Return the MCP initialize response."
  `((protocolVersion . "2025-11-25")
    (capabilities . ((tools . ((listChanged . t)))
                     (resources . ((subscribe . :json-false) (listChanged . :json-false)))
                     (prompts . ((listChanged . t)))))
    (serverInfo . ((name . "limen") (version . ,limen-version)))))

(defun limen-claude--response (id result)
  "Return a JSON-RPC success response for ID and RESULT."
  `((jsonrpc . "2.0") (id . ,id) (result . ,result)))

(defun limen-claude--error (id code message)
  "Return a JSON-RPC error response for ID, CODE, and MESSAGE."
  `((jsonrpc . "2.0") (id . ,id) (error . ((code . ,code) (message . ,message)))))

(defun limen-claude--close-raw (client)
  "Close CLIENT's raw WebSocket connection."
  (when-let* ((raw (limen-claude-client-raw client)))
    (when (fboundp 'websocket-close)
      (let* ((state (limen-claude-client-state client))
             (raw-clients (limen-claude-state-raw-clients state))
             (mapped (eq (gethash raw raw-clients) client)))
        (when mapped
          (remhash raw raw-clients))
        (condition-case err
            (prog1 (websocket-close raw)
              (when (and mapped
                         (eq (limen-claude-state-state state) 'detaching))
                (puthash raw client raw-clients)))
          (error
           (when mapped
             (puthash raw client raw-clients))
           (signal (car err) (cdr err))))))))

(defun limen-claude--cancel-work (state)
  "Cancel Emacs work owned by STATE's current client."
  (condition-case nil
      (if-let* ((client (limen-claude-state-current-client state))
                (owner (limen-claude-client-owner client)))
          (limen-editor-cancel owner)
        t)
    (error nil)))

(defun limen-claude--publish-discovery (lockfile discovery)
  "Atomically publish DISCOVERY at LOCKFILE with mode 0600."
  (let ((temporary (make-temp-file (concat lockfile "."))))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (with-temp-file temporary
            (insert (json-serialize discovery)))
          (set-file-modes temporary #o600)
          (rename-file temporary lockfile t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun limen-claude--cancel-deadline (state)
  "Cancel STATE's reconnect deadline."
  (when-let* ((timer (limen-claude-state-reconnect-deadline state)))
    (cancel-timer timer))
  (setf (limen-claude-state-reconnect-deadline state) nil
        (limen-claude-state-reconnect-token state) nil))

(defun limen-claude--arm-deadline (state generation)
  "Arm STATE's reconnect deadline for GENERATION."
  (let ((token (make-symbol "reconnect")))
    (setf (limen-claude-state-reconnect-token state) token
          (limen-claude-state-reconnect-deadline-seconds state) 30
          (limen-claude-state-reconnect-deadline state)
          (run-at-time 30 nil
                       (lambda ()
                         (when (and (eq token (limen-claude-state-reconnect-token state))
                                    (eq generation (limen-claude-state-client-generation state))
                                    (null (limen-claude-state-current-client state))
                                    (eq (limen-claude-state-state state) 'waiting-for-client))
                           (setf (limen-claude-state-reconnect-deadline state) nil)
                           (limen-claude-cleanup state)))))))

(cl-defun limen-claude-open
    (session &key instance-id instance-name discovery-directory tool-list tool-call)
  "Open Claude compatibility transport for Limen SESSION.
INSTANCE-ID and INSTANCE-NAME identify the discovery endpoint.
DISCOVERY-DIRECTORY, TOOL-LIST, and TOOL-CALL override transport defaults."
  (or (gethash session limen-claude--states)
      (let* ((instance-id (or instance-id (limen-session-id session)))
             (instance-name (or instance-name instance-id))
             (root (limen-session-project-root session))
             (state (make-limen-claude-state
                     :session session :project-root root :instance-id instance-id
                     :instance-name instance-name :state 'starting :client-generation 0
                     :tool-list (or tool-list #'limen-claude--available-tools)
                     :tool-call (or tool-call #'limen-claude--dispatch-operation)
                     :raw-clients (make-hash-table :test #'eq))))
        (condition-case err
            (let* ((port (limen-claude--start-server state))
                   (directory (file-name-as-directory
                               (expand-file-name
                                (or discovery-directory
                                    (limen-claude-discovery-directory)))))
                   (lockfile (expand-file-name (format "%s.lock" port) directory))
                   (discovery `((pid . ,(emacs-pid))
                                (workspaceFolders . ,(vector (expand-file-name root)))
                                (ideName . ,(format "limen %s" instance-name))
                                (transport . "ws"))))
              (make-directory directory t)
              (set-file-modes directory #o700)
              (setf (limen-claude-state-lockfile state) lockfile)
              (limen-claude--publish-discovery lockfile discovery)
              (setf (limen-claude-state-endpoint state)
                    (format "ws://127.0.0.1:%s" port)
                    (limen-claude-state-endpoint-live-p state) t
                    (limen-claude-state-discovery state)
                    (json-parse-string
                     (json-serialize discovery) :object-type 'alist :array-type 'list
                     :null-object nil :false-object :json-false)
                    (limen-claude-state-environment state)
                    (append
                     `((CLAUDE_CODE_SSE_PORT . ,(number-to-string port))
                       (ENABLE_IDE_INTEGRATION . "true")
                       (FORCE_CODE_TERMINAL . "true") (TERM_PROGRAM . "emacs"))
                     (when-let* ((configured (getenv "CLAUDE_CONFIG_DIR"))
                                 ((not (string= configured ""))))
                       `((CLAUDE_CONFIG_DIR . ,configured)))))
              (puthash session state limen-claude--states)
              (limen-claude-bind-session state session)
              state)
          (error
           (condition-case nil
               (limen-claude-cleanup state)
             (error nil))
           (signal (car err) (cdr err)))))))

(defun limen-claude-client-connect (state &optional raw)
  "Create a client for STATE and optional RAW connection."
  (let ((client (make-limen-claude-client
                 :raw raw :open-p t :state state)))
    (push client (limen-claude-state-clients state))
    client))

(defun limen-claude--known-tool-p (state name)
  "Return NAME's tool from STATE, if present."
  (seq-find (lambda (tool) (equal (limen-claude--value 'name tool) name))
            (funcall (limen-claude-state-tool-list state))))

(defun limen-claude--initialize-params-p (params)
  "Return non-nil when PARAMS is a valid initialize payload."
  (and (listp params)
       (equal (limen-claude--value 'protocolVersion params) "2025-11-25")
       (let ((capabilities (or (assoc 'capabilities params)
                               (assoc "capabilities" params))))
         (and capabilities (listp (cdr capabilities))))
       (let ((client-info (limen-claude--value 'clientInfo params)))
         (and (listp client-info)
              (stringp (limen-claude--value 'name client-info))
              (stringp (limen-claude--value 'version client-info))))))

(defun limen-claude--initialize-params (text)
  "Return initialize parameters parsed from TEXT."
  (limen-claude--value
   'params
   (json-parse-string text :object-type 'alist :array-type 'array
                      :null-object :json-null :false-object :json-false)))

(defun limen-claude--reject-initialize (state client id close code message)
  "Reject CLIENT initialization on STATE with CODE and MESSAGE."
  (when close
    (if limen-claude--defer-close
        (setq limen-claude--close-after-send t)
      (limen-claude-client-close state client)))
  (limen-claude--error id code message))

(defun limen-claude--initialize (state client id params)
  "Initialize CLIENT on STATE with ID and PARAMS."
  (if (memq (limen-claude-state-state state) '(detaching stopped))
      (progn
        (limen-claude-client-close state client)
        nil)
    (let* ((old (limen-claude-state-current-client state))
           (session (limen-claude-state-session state))
           (generation
            (1+ (or (limen-claude-state-client-generation state) 0)))
           (owner (if session
                      (limen-session-owner session)
                    (make-symbol "limen-claude-owner"))))
      (cond
       ((not (limen-claude--initialize-params-p params))
        (limen-claude--reject-initialize
         state client id (not (eq client old)) -32602 "Invalid params"))
       ((eq client old)
        (limen-claude--error id -32602 "Invalid params"))
       (t
        (if (and old (not (limen-claude--cancel-work state)))
            (limen-claude--reject-initialize
             state client id t -32603 "Internal error")
          (when old (limen-claude--cancel-selection state))
          (limen-claude--cancel-deadline state)
          (setf (limen-claude-state-current-client state) client
                (limen-claude-state-client-generation state) generation
                (limen-claude-client-initialized-p client) t
                (limen-claude-client-generation client) generation
                (limen-claude-client-owner client) owner)
          (when session
            (setf (limen-session-generation session) generation))
          (when old (limen-claude-client-close state old))
          (unless (eq (limen-claude-state-state state) 'starting)
            (setf (limen-claude-state-state state) 'connected))
          (limen-claude--response
           id (limen-claude--initialize-result))))))))

(defun limen-claude-receive (state client text)
  "Process TEXT received from CLIENT for STATE."
  (setf (limen-claude-client-state client) state)
  (limen-claude--observe
   'limen-claude--incoming-observers state client text)
  (when (limen-claude-client-open-p client)
    (condition-case nil
        (let* ((message (json-parse-string text :object-type 'alist :array-type 'list
                                           :null-object nil :false-object :json-false))
               (id (limen-claude--value 'id message))
               (method (limen-claude--value 'method message))
               (params (limen-claude--value 'params message)))
          (cond
           ((or (not (listp message)) (not (equal (limen-claude--value 'jsonrpc message) "2.0"))
                (not (stringp method)))
            (limen-claude--error nil -32600 "Invalid Request"))
           ((equal method "initialize")
            (limen-claude--initialize
             state client id (limen-claude--initialize-params text)))
           ((or (not (eq client (limen-claude-state-current-client state)))
                (not (limen-claude-client-initialized-p client))) nil)
           ((equal method "notifications/initialized") nil)
           ((equal method "ide_connected") nil)
           ((equal method "tools/list")
            (limen-claude--response id
                                    `((tools . ,(vconcat (funcall (limen-claude-state-tool-list state)))))))
           ((equal method "prompts/list")
            (limen-claude--response id '((prompts . []))))
           ((equal method "resources/list")
            (limen-claude--response id '((resources . []))))
           ((equal method "tools/call")
            (let* ((name (limen-claude--value 'name params))
                   (arguments (limen-claude--value 'arguments params)))
              (if (and (stringp name) (limen-claude--known-tool-p state name)
                       (functionp (limen-claude-state-tool-call state)))
                  (condition-case nil
                      (let* ((request
                              (make-limen-claude-request
                               :state state :client client
                               :generation (limen-claude-state-client-generation state)
                               :id id :owner (limen-claude-client-owner client)))
                             (result
                              (funcall (limen-claude-state-tool-call state)
                                       state name arguments request)))
                        (cond
                         ((eq result limen-deferred) nil)
                         ((eq (car-safe result) limen-claude--invalid-params)
                          (setf (limen-claude-request-resolved-p request) t)
                          (limen-claude--error id -32602 (cdr result)))
                         (t
                          (setf (limen-claude-request-resolved-p request) t)
                          (limen-claude--response
                           id (limen-claude--tool-result
                               (limen-claude-request-operation request)
                               result)))))
                    (error (limen-claude--error id -32603 "Internal error")))
                (limen-claude--error id -32602 "Unknown tool"))))
           (t (limen-claude--error id -32601 "Method not found"))))
      (error (limen-claude--error nil -32700 "Parse error")))))

(defun limen-claude-client-close (state client)
  "Close CLIENT for STATE."
  (let ((current (eq client (limen-claude-state-current-client state)))
        (raw (limen-claude-client-raw client)))
    (when (and current
               (not (eq (limen-claude--cancel-work state) t)))
      (error "Deferred work cancellation is incomplete"))
    (limen-claude--close-raw client)
    (setf (limen-claude-client-open-p client) nil
          (limen-claude-state-clients state)
          (delq client (limen-claude-state-clients state)))
    (when (and raw
               (eq (gethash raw (limen-claude-state-raw-clients state)) client))
      (remhash raw (limen-claude-state-raw-clients state)))
    (when current
      (setf (limen-claude-state-current-client state) nil)
      (when (memq (limen-claude-state-state state) '(connected waiting-for-client))
        (setf (limen-claude-state-state state) 'waiting-for-client)
        (limen-claude--arm-deadline
         state (limen-claude-state-client-generation state)))))
  nil)

(defun limen-claude-terminal-attached (state)
  "Mark STATE's terminal attachment complete."
  (when (eq (limen-claude-state-state state) 'starting)
    (setf (limen-claude-state-state state)
          (if (limen-claude-state-current-client state) 'connected 'waiting-for-client))))

(defun limen-claude-cleanup (state)
  "Clean up STATE resources."
  (unless (eq (limen-claude-state-state state) 'stopped)
    (setf (limen-claude-state-state state) 'detaching)
    (let (errors)
      (when-let* ((lockfile (limen-claude-state-lockfile state)))
        (condition-case err
            (progn
              (when (file-exists-p lockfile)
                (delete-file lockfile))
              (setf (limen-claude-state-lockfile state) nil
                    (limen-claude-state-endpoint-live-p state) nil
                    (limen-claude-state-discovery state) nil))
          (error (push err errors))))
      (condition-case err
          (unless (eq (limen-claude--cancel-work state) t)
            (error "Deferred work cancellation is incomplete"))
        (error (push err errors)))
      (when (or (limen-claude-state-reconnect-deadline state)
                (limen-claude-state-reconnect-token state))
        (condition-case err
            (limen-claude--cancel-deadline state)
          (error (push err errors))))
      (condition-case err
          (limen-claude--cancel-selection state)
        (error (push err errors)))
      (dolist (client (copy-sequence (limen-claude-state-clients state)))
        (condition-case err
            (progn
              (limen-claude--close-raw client)
              (setf (limen-claude-client-open-p client) nil
                    (limen-claude-state-clients state)
                    (delq client (limen-claude-state-clients state)))
              (when (eq client (limen-claude-state-current-client state))
                (setf (limen-claude-state-current-client state) nil)))
          (error (push err errors))))
      (when-let* ((server (limen-claude-state-server state)))
        (condition-case err
            (progn
              (if (fboundp 'websocket-server-close)
                  (websocket-server-close server)
                (when (process-live-p server)
                  (delete-process server)))
              (setf (limen-claude-state-server state) nil))
          (error (push err errors))))
      (when-let* ((session (limen-claude-state-session state))
                  (sink (limen-claude-state-event-sink state)))
        (condition-case err
            (progn
              (limen-session-unsubscribe session sink)
              (setf (limen-claude-state-event-sink state) nil))
          (error (push err errors))))
      (when-let* ((session (limen-claude-state-session state)))
        (unless (limen-session-closed-p session)
          (condition-case err
              (limen-close-session session)
            (error (push err errors)))))
      (if errors
          (signal (caar errors) (cdar errors))
        (setf (limen-claude-state-clients state) nil
              (limen-claude-state-current-client state) nil
              (limen-claude-state-event-sink state) nil
              (limen-claude-state-server state) nil
              (limen-claude-state-endpoint-live-p state) nil
              (limen-claude-state-discovery state) nil)
        (clrhash (limen-claude-state-raw-clients state))
        (remhash (or (limen-claude-state-session state) state)
                 limen-claude--states)
        (setf (limen-claude-state-state state) 'stopped))))
  state)

(defun limen-claude-discovery-directory ()
  "Return Claude Code's IDE discovery directory."
  (let ((configured (getenv "CLAUDE_CONFIG_DIR")))
    (expand-file-name
     "ide"
     (if (and configured (not (string= configured "")))
         configured
       (expand-file-name ".claude" (or (getenv "HOME") "~"))))))

(defun limen-claude-environment (state)
  "Return launch environment entries for Claude transport STATE."
  (limen-claude-state-environment state))

(defun limen-claude-attached (state &optional instance-id)
  "Mark Claude transport STATE attached with optional INSTANCE-ID."
  (when instance-id
    (setf (limen-claude-state-instance-id state) instance-id))
  (limen-claude-terminal-attached state))

(defun limen-claude-status (state)
  "Return integration status for Claude transport STATE."
  `((integration_label . "Claude Code")
    (integration_status . ,(symbol-name (limen-claude-state-state state)))
    (integration_endpoint . ,(limen-claude-state-endpoint state))))

(defun limen-claude-close (state)
  "Close Claude transport STATE and its Limen session."
  (limen-claude-cleanup state))

(provide 'limen-claude)
;;; limen-claude.el ends here
