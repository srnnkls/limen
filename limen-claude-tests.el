;;; limen-claude-tests.el --- Claude Code IDE protocol tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'limen-claude)

(define-error 'limen-claude-tests-port-failure
  "Distinctive Claude startup port failure")

(defun limen-claude-tests--value (key object)
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun limen-claude-tests--session (root name &optional instance-id)
  (limen-open-session
   :id name :provider 'claude :project-root root
   :capabilities (list :instance-id (or instance-id name))))

(defun limen-claude-tests--valid-params ()
  '((protocolVersion . "2025-11-25")
    (capabilities)
    (clientInfo . ((name . "ERT") (version . "1")))))

(defun limen-claude-tests--request (id method &optional params)
  (json-serialize
   `((jsonrpc . "2.0") (id . ,id) (method . ,method)
     ,@(when params `((params . ,params))))))

(defun limen-claude-tests--error-code (response)
  (limen-claude-tests--value
   'code (limen-claude-tests--value 'error response)))

(defun limen-claude-tests--prepare (root session &rest options)
  (apply #'limen-claude-open session
         :instance-id (plist-get (limen-session-capabilities session) :instance-id)
         :instance-name
         (format "test/%s/%s"
                 (limen-session-id session)
                 (plist-get (limen-session-capabilities session) :instance-id))
         :discovery-directory (expand-file-name "discovery" root)
         options))

(defmacro limen-claude-tests--with-runtime (&rest body)
  `(let ((process-environment
          (cons "CLAUDE_CONFIG_DIR" process-environment))
         (limen-claude--states (make-hash-table :test #'eq))
         (limen-claude--cleanup-retries (make-hash-table :test #'eq))
         (limen--sessions (make-hash-table :test #'eq))
         (limen-editor--selection-timers (make-hash-table :test #'eq))
         (limen-editor--selection-contexts (make-hash-table :test #'eq))
         (post-command-hook nil)
         (limen-claude--incoming-observers nil)
         (limen-claude--outgoing-observers nil)
         (limen-claude--defer-close nil)
         (limen-claude--close-after-send nil)
         (limen-claude-tests--servers nil)
         (limen-claude-tests--server-arguments nil)
         (limen-claude-tests--closed-servers nil)
         (limen-claude-tests--closed-raw nil)
         (limen-claude-tests--sent nil)
         (limen-claude-tests--next-port 4200)
         (original-require (symbol-function 'require)))
     (cl-letf (((symbol-function 'require)
                (lambda (feature &optional filename noerror)
                  (if (eq feature 'websocket)
                      'websocket
                    (funcall original-require feature filename noerror))))
               ((symbol-function 'websocket-server)
                (lambda (&rest arguments)
                  (push arguments limen-claude-tests--server-arguments)
                  (let ((server (make-symbol "websocket-server")))
                    (push server limen-claude-tests--servers)
                    server)))
               ((symbol-function 'websocket-server-close)
                (lambda (server)
                  (push server limen-claude-tests--closed-servers)))
               ((symbol-function 'websocket-close)
                (lambda (raw)
                  (push raw limen-claude-tests--closed-raw)))
               ((symbol-function 'websocket-send-text)
                (lambda (raw text)
                  (push (cons raw text) limen-claude-tests--sent)))
               ((symbol-function 'limen-claude--port)
                (lambda (_server)
                  (cl-incf limen-claude-tests--next-port))))
       ,@body)))

(ert-deftest limen-claude-prepare-publishes-discovery-and-environment ()
  (limen-claude-tests--with-runtime
   (let* ((root (make-temp-file "limen-claude-prepare" t))
          (session (limen-claude-tests--session root "review" "term-1"))
          written-modes
          state)
     (unwind-protect
         (progn
           (let ((original-write-region (symbol-function 'write-region)))
             (cl-letf (((symbol-function 'write-region)
                        (lambda (&rest arguments)
                          (prog1 (apply original-write-region arguments)
                            (push (file-modes (nth 2 arguments)) written-modes)))))
               (setq state (limen-claude-tests--prepare root session))))
           (should (and written-modes
                        (cl-every (lambda (mode) (= mode #o600))
                                  written-modes)))
           (let* ((lockfile (limen-claude-state-lockfile state))
                  (discovery
                   (with-temp-buffer
                     (insert-file-contents lockfile)
                     (json-parse-buffer :object-type 'alist :array-type 'list))))
             (should (equal discovery (limen-claude-state-discovery state)))
             (should (= (logand (file-modes (file-name-directory lockfile)) #o777)
                        #o700))
             (should (= (file-modes lockfile) #o600))
             (should-not (assq 'authToken discovery))
             (should (equal (limen-claude-tests--value
                             'workspaceFolders discovery)
                            (list (expand-file-name
                                   (limen-session-project-root session)))))
             (should (string-match-p
                      "review.*term-1"
                      (limen-claude-tests--value 'ideName discovery)))
             (should (equal (limen-claude-tests--value 'transport discovery)
                            "ws")))
           (let ((arguments (car limen-claude-tests--server-arguments)))
             (should (zerop (car arguments)))
             (should (equal (plist-get (cdr arguments) :host) "127.0.0.1"))
             (should (equal (plist-get (cdr arguments) :protocol) '("mcp"))))
           (should (equal (limen-claude-state-endpoint state)
                          "ws://127.0.0.1:4201"))
           (should
            (equal (limen-claude-state-environment state)
                   '((CLAUDE_CODE_SSE_PORT . "4201")
                     (ENABLE_IDE_INTEGRATION . "true")
                     (FORCE_CODE_TERMINAL . "true")
                     (TERM_PROGRAM . "emacs"))))
           (should (eq (gethash session limen-claude--states) state))
           (let* ((config (expand-file-name "claude-config" root))
                  (process-environment
                   (cons (format "CLAUDE_CONFIG_DIR=%s" config)
                         process-environment))
                  (configured-session
                   (limen-claude-tests--session
                    root "configured" "term-configured"))
                  configured-state)
             (unwind-protect
                 (progn
                   (setq configured-state
                         (limen-claude-open
                          configured-session
                          :instance-id "term-configured"
                          :instance-name "configured/term-configured"))
                   (should
                    (string-prefix-p
                     (file-name-as-directory (expand-file-name "ide" config))
                     (limen-claude-state-lockfile configured-state)))
                   (should
                    (equal
                     (alist-get
                      'CLAUDE_CONFIG_DIR
                      (limen-claude-state-environment configured-state))
                     config)))
               (when configured-state
                 (limen-claude-cleanup configured-state))))
           (should (eq (limen-claude-open session) state))
           (let ((rollback-session
                  (limen-claude-tests--session root "rollback" "term-rollback"))
                 startup-condition)
             (unwind-protect
                 (cl-letf (((symbol-function 'limen-claude--publish-discovery)
                            (lambda (&rest _)
                              (signal 'file-error '("startup failure"))))
                           ((symbol-function 'websocket-server-close)
                            (lambda (_server)
                              (error "rollback cleanup failure"))))
                   (setq startup-condition
                         (condition-case condition
                             (progn
                               (limen-claude-open
                                rollback-session
                                :instance-id "term-rollback"
                                :instance-name "rollback/term-rollback"
                                :discovery-directory
                                (expand-file-name "rollback-discovery" root))
                               nil)
                           (error condition)))
                   (should (equal startup-condition
                                  '(file-error "startup failure"))))
               (unless (limen-session-closed-p rollback-session)
                 (limen-close-session rollback-session)))))
       (when state (limen-claude-cleanup state))
       (delete-directory root t)))))





(ert-deftest limen-claude-startup-rolls-back-acquired-listener ()
  (limen-claude-tests--with-runtime
   (let* ((root (make-temp-file "limen-claude-startup" t))
          (discovery-directory (expand-file-name "discovery" root))
          (session (limen-claude-tests--session root "startup"))
          (original-start-server
           (symbol-function 'limen-claude--start-server))
          captured-state startup-condition)
     (unwind-protect
         (cl-letf (((symbol-function 'limen-claude--start-server)
                    (lambda (state)
                      (setq captured-state state)
                      (funcall original-start-server state)))
                   ((symbol-function 'limen-claude--port)
                    (lambda (_server)
                      (signal
                       'limen-claude-tests-port-failure
                       '("port derivation failed" (:stage . pre-publication))))))
           (setq startup-condition
                 (condition-case condition
                     (progn
                       (limen-claude-open
                        session
                        :instance-id "startup"
                        :instance-name "startup"
                        :discovery-directory discovery-directory)
                       nil)
                   (error condition)))
           (should
            (equal
             (list startup-condition
                   (= (length limen-claude-tests--servers) 1)
                   (equal limen-claude-tests--closed-servers
                          limen-claude-tests--servers)
                   (limen-session-closed-p session)
                   (hash-table-count limen-claude--states)
                   (limen-claude-state-discovery captured-state)
                   (limen-claude-state-lockfile captured-state)
                   (hash-table-count
                    (limen-claude-state-raw-clients captured-state))
                   (and (file-directory-p discovery-directory)
                        (directory-files
                         discovery-directory nil "\\.lock\\'")))
             '((limen-claude-tests-port-failure
                "port derivation failed" (:stage . pre-publication))
               t t t 0 nil nil 0 nil))))
       (unless (limen-session-closed-p session)
         (limen-close-session session))
       (delete-directory root t)))))

(ert-deftest limen-claude-startup-retains-failed-rollback-for-retry ()
  (limen-claude-tests--with-runtime
   (let* ((root (make-temp-file "limen-claude-startup-retry" t))
          (session (limen-claude-tests--session root "startup-retry"))
          (listener (make-symbol "listener"))
          (close-failing t)
          initial-close-attempted retry-close-attempted released-listener
          captured-state startup-condition retry-states retained before-retry)
     (unwind-protect
         (cl-letf (((symbol-function 'limen-claude--start-server)
                    (lambda (state)
                      (setq captured-state state)
                      (setf (limen-claude-state-server state) listener)
                      (signal
                       'limen-claude-tests-port-failure
                       '("port derivation failed" (:stage . pre-publication)))))
                   ((symbol-function 'websocket-server-close)
                    (lambda (server)
                      (if close-failing
                          (progn
                            (setq initial-close-attempted t)
                            (error "listener cleanup failure"))
                        (setq retry-close-attempted t
                              released-listener server)))))
           (setq startup-condition
                 (condition-case condition
                     (progn
                       (limen-claude-open
                        session
                        :instance-id "startup-retry"
                        :instance-name "startup-retry")
                       nil)
                   (error condition))
                 retry-states
                 (limen-claude--registry-states
                  limen-claude--cleanup-retries)
                 retained (car retry-states)
                 before-retry
                 (list (gethash session limen-claude--states)
                       (length retry-states)
                       (eq retained captured-state)
                       initial-close-attempted
                       (eq (limen-claude-state-server captured-state)
                           listener)))
           (setq close-failing nil)
           (when retained
             (limen-claude-cleanup retained))
           (should
            (equal
             (list startup-condition
                   before-retry
                   retry-close-attempted
                   (eq released-listener listener)
                   (limen-claude-state-server captured-state)
                   (length
                    (limen-claude--registry-states
                     limen-claude--cleanup-retries)))
             '((limen-claude-tests-port-failure
                "port derivation failed" (:stage . pre-publication))
               (nil 1 t t t)
               t t nil 0))))
       (setq close-failing nil)
       (when captured-state
         (condition-case nil
             (limen-claude-cleanup captured-state)
           (error nil)))
       (unless (limen-session-closed-p session)
         (limen-close-session session))
       (delete-directory root t)))))

(ert-deftest limen-claude-mcp-initialize-and-listing-contract ()
  (limen-claude-tests--with-runtime
   (let* ((state (make-limen-claude-state
                  :state 'waiting-for-client :client-generation 0
                  :tool-list #'limen-claude--available-tools
                  :raw-clients (make-hash-table :test #'eq)))
          (client (limen-claude-client-connect state))
          (initialize
           (limen-claude-receive
            state client
            (limen-claude-tests--request
             1 "initialize" (limen-claude-tests--valid-params))))
          (result (limen-claude-tests--value 'result initialize)))
     (should (equal (limen-claude-tests--value 'protocolVersion result)
                    "2025-11-25"))
     (should (equal (limen-claude-tests--value
                     'name (limen-claude-tests--value 'serverInfo result))
                    "limen"))
     (should
      (equal (limen-claude-tests--value 'capabilities result)
             '((tools . ((listChanged . t)))
               (resources . ((subscribe . :json-false) (listChanged . :json-false)))
               (prompts . ((listChanged . t))))))
     (let* ((initialized
             (limen-claude-receive
              state client
              (json-serialize
               '((jsonrpc . "2.0")
                 (method . "notifications/initialized")))))
            (response (limen-claude-receive
                       state client
                       (limen-claude-tests--request 2 "tools/list")))
            (tools (limen-claude-tests--value
                    'tools (limen-claude-tests--value 'result response)))
            (tool-names
             (mapcar (lambda (tool)
                       (limen-claude-tests--value 'name tool))
                     (append tools nil))))
       (should (vectorp tools))
       (should
        (equal
         (list initialized
               tool-names
               (mapcar
                (lambda (method)
                  (limen-claude-tests--error-code
                   (limen-claude-receive
                    state client
                    (limen-claude-tests--request 90 method))))
                '("getCurrentSelection" "getLatestSelection"
                  "getOpenEditors" "getWorkspaceFolders"
                  "checkDocumentDirty" "saveDocument")))
         '(nil
           ("openFile" "getDiagnostics" "close_tab" "openDiff"
            "closeAllDiffTabs")
           (-32601 -32601 -32601 -32601 -32601 -32601))))

     (dolist (entry '(("prompts/list" . prompts) ("resources/list" . resources)))
       (let* ((response (limen-claude-receive
                         state client
                         (limen-claude-tests--request 3 (car entry))))
              (listed (limen-claude-tests--value
                       (cdr entry)
                       (limen-claude-tests--value 'result response))))
         (should (equal listed []))))))))

(ert-deftest limen-claude-diff-result-preserves-accepted-text ()
  (should
   (equal
    (list (limen-claude--tool-result "diff.open" "accepted\n")
          (limen-claude--tool-result "diff.open" "")
          (limen-claude--tool-result "diff.open" "Diff rejected"))
    '(((content . [((type . "text") (text . "FILE_SAVED"))
                   ((type . "text") (text . "accepted\n"))]))
      ((content . [((type . "text") (text . "FILE_SAVED"))
                   ((type . "text") (text . ""))]))
      ((content . [((type . "text") (text . "FILE_SAVED"))
                   ((type . "text") (text . "Diff rejected"))]))))))

(ert-deftest limen-claude-diff-result-distinguishes-rejection-and-closure ()
  (should
   (equal
    (list (limen-claude--tool-result
           "diff.open" '((outcome . "rejected")))
          (limen-claude--tool-result
           "diff.open" '((outcome . "closed"))))
    '(((content . [((type . "text") (text . "DIFF_REJECTED"))]))
      ((content . [((type . "text") (text . "TAB_CLOSED"))]))))))

(ert-deftest limen-claude-mcp-errors-are-json-rpc-specific ()
  (limen-claude-tests--with-runtime
   (let* ((tool '((name . "openFile")))
          (state (make-limen-claude-state
                  :state 'connected :client-generation 1
                  :tool-list (lambda () (list tool))
                  :tool-call (lambda (&rest _) (error "handler failed"))
                  :raw-clients (make-hash-table :test #'eq)))
          (client (limen-claude-client-connect state)))
     (setf (limen-claude-state-current-client state) client
           (limen-claude-client-initialized-p client) t)
     (should (= (limen-claude-tests--error-code
                 (limen-claude-receive state client "{"))
                -32700))
     (should (= (limen-claude-tests--error-code
                 (limen-claude-receive
                  state client (json-serialize '((jsonrpc . "1.0") (method . "x")))))
                -32600))
     (should (= (limen-claude-tests--error-code
                 (limen-claude-receive
                  state client (limen-claude-tests--request 2 "missing")))
                -32601))
     (should (= (limen-claude-tests--error-code
                 (limen-claude-receive
                  state client
                  (limen-claude-tests--request
                   3 "tools/call" '((name . "missing") (arguments)))))
                -32602))
     (should (= (limen-claude-tests--error-code
                 (limen-claude-receive
                  state client
                  (limen-claude-tests--request
                   4 "tools/call"
                   '((name . "openFile") (arguments . ((filePath . "a")))))))
                -32603)))))


(ert-deftest limen-claude-mcp-tool-call-converts-operation-results ()
  (limen-claude-tests--with-runtime
   (let* ((seen nil)
          (state (make-limen-claude-state
                  :state 'connected :client-generation 1
                  :tool-list (lambda () '(((name . "openFile"))))
                  :tool-call
                  (lambda (_state name arguments request)
                    (setq seen (list name arguments
                                     (limen-claude-request-owner request)))
                    "opened")
                  :raw-clients (make-hash-table :test #'eq)))
          (client (limen-claude-client-connect state)))
     (setf (limen-claude-state-current-client state) client
           (limen-claude-client-initialized-p client) t
           (limen-claude-client-owner client) 'request-owner)
     (let* ((response
             (limen-claude-receive
              state client
              (limen-claude-tests--request
               7 "tools/call"
               '((name . "openFile") (arguments . ((filePath . "a.el")))))))
            (result (limen-claude-tests--value 'result response)))
       (should (equal seen '("openFile" ((filePath . "a.el")) request-owner)))
       (should
        (equal result
               '((content . [((type . "text") (text . "opened"))]))))))))



(ert-deftest limen-claude-reconnect-deadline-is-current-client-scoped ()
  (limen-claude-tests--with-runtime
   (let* ((root (make-temp-file "limen-claude-reconnect" t))
          (session (limen-claude-tests--session root "reconnect"))
          (callbacks nil)
          state)
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (seconds _repeat callback &rest arguments)
                  (should (= seconds 30))
                  (let ((timer (lambda () (apply callback arguments))))
                    (setq callbacks (append callbacks (list timer)))
                    timer)))
               ((symbol-function 'cancel-timer) (lambda (&rest _) nil)))
       (unwind-protect
           (progn
             (setq state (limen-claude-tests--prepare root session))
             (limen-claude-terminal-attached state)
             (let ((current (limen-claude-client-connect state 'current))
                   (bystander (limen-claude-client-connect state 'bystander)))
               (limen-claude--initialize
                state current 1 (limen-claude-tests--valid-params))
               (limen-claude-client-close state bystander)
               (should-not callbacks)
               (cl-letf (((symbol-function 'limen-editor-cancel)
                          (lambda (owner)
                            (should (eq owner
                                        (limen-claude-client-owner
                                         current)))
                            nil)))
                 (should-error
                  (limen-claude-client-close state current)
                  :type 'error)
                 (should (eq (limen-claude-state-current-client state)
                             current))
                 (should (limen-claude-client-open-p current))
                 (should (memq current
                               (limen-claude-state-clients state)))
                 (should-not callbacks))
               (limen-claude-client-close state current)
               (should (= (length callbacks) 1))
               (should (= (limen-claude-state-reconnect-deadline-seconds state)
                          30))
               (let ((replacement
                      (limen-claude-client-connect state 'replacement)))
                 (limen-claude--initialize
                  state replacement 2 (limen-claude-tests--valid-params))
                 (funcall (car callbacks))
                 (should (eq (limen-claude-state-state state) 'connected))
                 (should (eq (limen-claude-state-current-client state)
                             replacement))
                 (limen-claude-client-close state replacement)
                 (should (= (length callbacks) 2))
                 (funcall (cadr callbacks))
                 (should (eq (limen-claude-state-state state) 'stopped)))))
         (when state (limen-claude-cleanup state))
         (delete-directory root t))))))


(ert-deftest limen-claude-translates-shared-selection-for-one-project ()
  (limen-claude-tests--with-runtime
   (let* ((root-a (make-temp-file "limen-claude-context-a" t))
          (root-b (make-temp-file "limen-claude-context-b" t))
          (session-a (limen-claude-tests--session root-a "a"))
          (session-b (limen-claude-tests--session root-b "b"))
          (state-a (make-limen-claude-state
                    :session session-a :project-root root-a :client-generation 1))
          (state-b (make-limen-claude-state
                    :session session-b :project-root root-b :client-generation 1))
          (client-a (make-limen-claude-client
                     :raw 'raw-a :open-p t :initialized-p t :state state-a))
          (client-b (make-limen-claude-client
                     :raw 'raw-b :open-p t :initialized-p t :state state-b)))
     (unwind-protect
         (progn
           (setf (limen-claude-state-current-client state-a) client-a
                 (limen-claude-state-current-client state-b) client-b)
           (puthash session-a state-a limen-claude--states)
           (puthash session-b state-b limen-claude--states)
           (limen-claude-bind-session state-a session-a)
           (limen-claude-bind-session state-b session-b)
           (limen-claude-broadcast-project-context
            nil root-a "workspace_updated" '((revision . 3)))
           (should (= (length limen-claude-tests--sent) 1))
           (should (eq (caar limen-claude-tests--sent) 'raw-a))
           (setq limen-claude-tests--sent nil)
           (limen-session-publish
            session-a "context.selection"
            '((path . "/tmp/a.el") (text . "x")
              (line . 2) (column . 2) (end_line . 4) (end_column . 4)))
           (should (= (length limen-claude-tests--sent) 1))
           (let* ((message
                   (json-parse-string
                    (cdar limen-claude-tests--sent)
                    :object-type 'alist :array-type 'list))
                  (params (limen-claude-tests--value 'params message)))
             (should (equal
                      (limen-claude-tests--value 'method message)
                      "selection_changed"))
             (should
              (equal params
                     '((filePath . "/tmp/a.el") (text . "x")
                       (selection . ((start . ((line . 1) (character . 2)))
                                     (end . ((line . 3) (character . 4))))))))))
       (unless (limen-session-closed-p session-a)
         (limen-close-session session-a))
       (unless (limen-session-closed-p session-b)
         (limen-close-session session-b))
       (delete-directory root-a t)
       (delete-directory root-b t)))))

(ert-deftest limen-claude-at-mention-targets-session-or-state ()
  (limen-claude-tests--with-runtime
   (let* ((root (make-temp-file "limen-claude-mention" t))
          (outside (make-temp-file "limen-claude-outside" t))
          (file (expand-file-name "mention.el" root))
          (session (limen-claude-tests--session root "mention" "terminal"))
          (state (make-limen-claude-state
                  :session session :project-root root :client-generation 1))
          (client (make-limen-claude-client
                   :raw 'mention-raw :open-p t :initialized-p t :state state)))
     (unwind-protect
         (progn
           (with-temp-file file (insert "one\ntwo\n"))
           (setf (limen-claude-state-current-client state) client)
           (puthash session state limen-claude--states)
           (limen-claude-bind-session state session)
           (let ((buffer (find-file-noselect file)))
             (unwind-protect
                 (with-current-buffer buffer
                   (cl-letf (((symbol-function 'limen-editor-context-snapshot)
                              (lambda (&optional _)
                                `((path . ,file) (line . 1) (column . 0)
                                  (end_line . 2) (end_column . 0) (text . "")))))
                     (should (limen-claude-send-at-mentioned session))
                     (should (limen-claude-send-at-mentioned state))
                     (should (= (length limen-claude-tests--sent) 2))
                     (dolist (wire limen-claude-tests--sent)
                       (let* ((message
                               (json-parse-string
                                (cdr wire) :object-type 'alist :array-type 'list))
                              (params
                               (limen-claude-tests--value 'params message)))
                         (should (equal
                                  (limen-claude-tests--value 'method message)
                                  "at_mentioned"))
                         (should (equal params
                                        `((filePath . ,file)
                                          (lineStart . 1) (lineEnd . 2))))))))
               (kill-buffer buffer)))
           (let ((outside-file (expand-file-name "outside.el" outside)))
             (with-temp-file outside-file (insert "outside\n"))
             (with-temp-buffer
               (setq buffer-file-name outside-file)
               (should-not (limen-claude-send-at-mentioned session))))
           (should (= (length limen-claude-tests--sent) 2)))
       (unless (limen-session-closed-p session)
         (limen-close-session session))
       (delete-directory root t)
       (delete-directory outside t)))))

(ert-deftest limen-claude-cleanup-is-best-effort-and-retryable ()
  (limen-claude-tests--with-runtime
   (let* ((root (make-temp-file "limen-claude-cleanup" t))
          (lockfile (expand-file-name "4201.lock" root))
          (session (limen-claude-tests--session root "cleanup"))
          (sink (lambda (&rest _) nil))
          (raw 'raw)
          (server 'server)
          (state (make-limen-claude-state
                  :session session :project-root root :state 'connected
                  :server server :lockfile lockfile :event-sink sink
                  :reconnect-deadline 'deadline :reconnect-token 'token
                  :endpoint-live-p t :discovery '((transport . "ws"))
                  :raw-clients (make-hash-table :test #'eq)))
          (client (make-limen-claude-client
                   :raw raw :open-p t :initialized-p t :state state))
          (counts (make-hash-table :test #'eq))
          trace first-trace second-trace first-condition second-condition
          first-resources)
     (with-temp-file lockfile (insert "{}"))
     (setf (limen-claude-state-clients state) (list client)
           (limen-claude-state-current-client state) client)
     (puthash raw client (limen-claude-state-raw-clients state))
     (puthash session state limen-claude--states)
     (unwind-protect
         (cl-labels
             ((attempt
               (stage)
               (let ((count (1+ (gethash stage counts 0))))
                 (puthash stage count counts)
                 (setq trace (append trace (list stage)))
                 count))
              (covers
               (events stages)
               (cl-every (lambda (stage) (memq stage events)) stages)))
           (let ((original-delete-file (symbol-function 'delete-file)))
             (cl-letf
                 (((symbol-function 'delete-file)
                   (lambda (file &optional trash)
                     (if (equal file lockfile)
                         (let ((attempt-number (attempt 'lockfile)))
                           (when (= attempt-number 1)
                             (error "lockfile cleanup failure"))
                           (funcall original-delete-file file trash))
                       (funcall original-delete-file file trash))))
                  ((symbol-function 'limen-claude--cancel-work)
                   (lambda (_state) (> (attempt 'work) 1)))
                  ((symbol-function 'limen-claude--cancel-deadline)
                   (lambda (actual-state)
                     (when (= (attempt 'deadline) 1)
                       (error "deadline cleanup failure"))
                     (setf (limen-claude-state-reconnect-deadline actual-state) nil
                           (limen-claude-state-reconnect-token actual-state) nil)))
                  ((symbol-function 'limen-claude--cancel-selection)
                   (lambda (_state)
                     (when (= (attempt 'selection) 1)
                       (error "selection cleanup failure"))))
                  ((symbol-function 'limen-claude--close-raw)
                   (lambda (_client)
                     (when (= (attempt 'raw) 1)
                       (error "client cleanup failure"))))
                  ((symbol-function 'websocket-server-close)
                   (lambda (_server)
                     (when (= (attempt 'server) 1)
                       (error "server cleanup failure"))))
                  ((symbol-function 'limen-session-unsubscribe)
                   (lambda (_session _sink)
                     (when (= (attempt 'unsubscribe) 1)
                       (error "unsubscribe cleanup failure"))
                     t))
                  ((symbol-function 'limen-close-session)
                   (lambda (actual-session)
                     (when (= (attempt 'session) 1)
                       (error "session cleanup failure"))
                     (setf (limen-session-closed-p actual-session) t)
                     (remhash actual-session limen--sessions)
                     t)))
               (setq first-condition
                     (condition-case condition
                         (progn (limen-claude-cleanup state) nil)
                       (error condition))
                     first-trace trace
                     first-resources
                     (list (file-exists-p lockfile)
                           (and (memq client (limen-claude-state-clients state)) t)
                           (limen-claude-client-open-p client)
                           (eq (gethash raw
                                        (limen-claude-state-raw-clients state))
                               client)
                           (eq (limen-claude-state-server state) server)
                           (eq (limen-claude-state-event-sink state) sink)
                           (not (limen-session-closed-p session))
                           (limen-claude-state-state state))
                     trace nil
                     second-condition
                     (condition-case condition
                         (progn (limen-claude-cleanup state) nil)
                       (error condition))
                     second-trace trace)
               (should
                (equal
                 (list (and first-condition t)
                       (eq (car first-trace) 'lockfile)
                       (covers first-trace
                               '(lockfile work deadline selection raw server
                                 unsubscribe session))
                       first-resources
                       second-condition
                       (covers second-trace
                               '(lockfile work deadline selection raw server
                                 unsubscribe session))
                       (mapcar (lambda (stage)
                                 (>= (gethash stage counts 0) 2))
                               '(lockfile work deadline selection raw server
                                 unsubscribe session))
                       (file-exists-p lockfile)
                       (list (limen-claude-state-state state)
                             (limen-claude-state-clients state)
                             (limen-claude-state-current-client state)
                             (limen-claude-state-server state)
                             (limen-claude-state-event-sink state)
                             (limen-claude-state-endpoint-live-p state)
                             (limen-claude-state-discovery state)
                             (limen-session-closed-p session)
                             (hash-table-count limen-claude--states)
                             (hash-table-count
                              (limen-claude-state-raw-clients state))))
                 '(t t t
                   (t t t t t t t detaching)
                   nil t
                   (t t t t t t t t)
                   nil
                   (stopped nil nil nil nil nil nil t 0 0)))))))
       (unless (limen-session-closed-p session)
         (setf (limen-session-closed-p session) t)
         (remhash session limen--sessions))
       (delete-directory root t)))))

(provide 'limen-claude-tests)
;;; limen-claude-tests.el ends here
