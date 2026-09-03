;;; limen-mcp-tests.el --- Standard MCP bridge tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'limen-mcp)

(defmacro limen-mcp-tests--with-state (&rest body)
  (declare (indent 0) (debug t))
  `(let ((limen--operations (copy-hash-table limen--operations))
         (limen--events (copy-hash-table limen--events))
         (limen--sessions (make-hash-table :test #'eq))
         (limen--buffers (make-hash-table :test #'eq))
         (limen-mcp--routes (make-hash-table :test #'equal))
         (limen-mcp--listener nil))
     (unwind-protect
         (progn ,@body)
       (maphash (lambda (_id route)
                  (ignore-errors (limen-mcp-unregister-session route)))
                (copy-hash-table limen-mcp--routes))
       (when (process-live-p limen-mcp--listener)
         (delete-process limen-mcp--listener)))))

(defun limen-mcp-tests--message (method id &optional params)
  (json-serialize
   `((jsonrpc . "2.0") (id . ,id) (method . ,method)
     ,@(when params `((params . ,params))))
   :false-object :json-false :null-object nil))

(defun limen-mcp-tests--request (route method body &optional headers)
  `((method . ,method)
    (path . ,(concat "/mcp/" (limen-mcp-route-id route)))
    (headers . ((authorization . ,(concat "Bearer " (limen-mcp-route-token route)))
                ,@headers))
    (body . ,body)))

(defun limen-mcp-tests--body (response)
  (json-parse-string (alist-get 'body response)
                     :object-type 'alist :array-type 'array
                     :null-object nil :false-object :json-false))

(defun limen-mcp-tests--initialize (route)
  (limen-mcp-handle-request
   (limen-mcp-tests--request
    route "POST"
    (limen-mcp-tests--message
     "initialize" 1
     '((protocolVersion . "2025-11-25")
       (capabilities . ())
       (clientInfo . ((name . "test") (version . "1"))))))))

(ert-deftest limen-mcp-registers-loopback-session-and-negotiates-initialize ()
  (limen-mcp-tests--with-state
    (let* ((session (limen-open-session
                     :provider 'test :project-root default-directory))
           (route (limen-mcp-register-session session))
           (response (limen-mcp-tests--initialize route))
           (result (alist-get 'result (limen-mcp-tests--body response))))
      (should (equal (alist-get 'status response) 200))
      (should (equal (alist-get 'protocolVersion result) "2025-11-25"))
      (should (equal (alist-get 'Mcp-Session-Id (alist-get 'headers response))
                     (limen-mcp-route-id route)))
      (should (string-prefix-p "http://127.0.0.1:"
                               (limen-mcp-endpoint route)))
      (should (process-live-p limen-mcp--listener))
      (should (limen-mcp-unregister-session route))
      (should-not (process-live-p limen-mcp--listener)))))

(ert-deftest limen-mcp-tools-derive-from-visible-operations ()
  (limen-mcp-tests--with-state
    (limen-register-operation
     "sample.read" (lambda (_arguments _request) '((value . 7)))
     :description "Read a sample." :effect 'read :parameters nil
     :interfaces '(mcp))
    (limen-register-operation
     "sample.cli" #'ignore :description "CLI only." :parameters nil
     :interfaces '(cli))
    (let* ((session (limen-open-session
                     :provider 'test :project-root default-directory))
           (route (limen-mcp-register-session session)))
      (limen-mcp-tests--initialize route)
      (let* ((response
              (limen-mcp-handle-request
               (limen-mcp-tests--request
                route "POST" (limen-mcp-tests--message "tools/list" 2)
                `((mcp-session-id . ,(limen-mcp-route-id route))))))
             (tools (alist-get 'tools
                               (alist-get 'result
                                          (limen-mcp-tests--body response))))
             (names (mapcar (lambda (tool) (alist-get 'name tool))
                            (append tools nil))))
        (should (member "sample_read" names))
        (should (member "buffer_open" names))
        (should-not (member "sample_cli" names))
        (should-not (member "elisp_eval" names))
        (should-not (member "buffer_release" names))
        (should (eq (alist-get
                     'readOnlyHint
                     (alist-get 'annotations
                                (seq-find (lambda (tool)
                                            (equal (alist-get 'name tool)
                                                   "sample_read"))
                                          (append tools nil))))
                    t))))))

(ert-deftest limen-mcp-tool-names-preserve-hyphens-and-dispatch-injectively ()
  (limen-mcp-tests--with-state
    (let (called)
      (limen-register-operation
       "a-b.c" (lambda (_arguments _request)
                 (push 'a-b.c called)
                 "hyphen-before-dot")
       :description "Hyphen before dot." :parameters nil :interfaces '(mcp))
      (limen-register-operation
       "a.b-c" (lambda (_arguments _request)
                 (push 'a.b-c called)
                 "hyphen-after-dot")
       :description "Hyphen after dot." :parameters nil :interfaces '(mcp))
      (limen-register-operation
       "sample.read" (lambda (_arguments _request)
                       (push 'sample.read called)
                       "sample")
       :description "Sample." :parameters nil :interfaces '(mcp))
      (let* ((session (limen-open-session
                       :provider 'test :project-root default-directory))
             (route (limen-mcp-register-session session)))
        (limen-mcp-tests--initialize route)
        (let* ((response
                (limen-mcp-handle-request
                 (limen-mcp-tests--request
                  route "POST" (limen-mcp-tests--message "tools/list" 2)
                  `((mcp-session-id . ,(limen-mcp-route-id route))))))
               (tools (alist-get 'tools
                                 (alist-get 'result
                                            (limen-mcp-tests--body response))))
               (names (mapcar (lambda (tool) (alist-get 'name tool))
                              (append tools nil))))
          (should (member "a-b_c" names))
          (should (member "a_b-c" names))
          (should (member "sample_read" names)))
        (let (results)
          (dolist (entry '(("a-b_c" . 3) ("a_b-c" . 4)
                           ("sample_read" . 5)))
            (let* ((response
                    (limen-mcp-handle-request
                     (limen-mcp-tests--request
                      route "POST"
                      (limen-mcp-tests--message
                       "tools/call" (cdr entry)
                       `((name . ,(car entry)) (arguments . ())))
                      `((mcp-session-id . ,(limen-mcp-route-id route))))))
                   (result (alist-get 'result
                                      (limen-mcp-tests--body response))))
              (push (alist-get 'text (aref (alist-get 'content result) 0))
                    results)))
          (should (equal (nreverse results)
                         '("hyphen-before-dot" "hyphen-after-dot" "sample")))
          (should (equal (nreverse called) '(a-b.c a.b-c sample.read))))))))

(ert-deftest limen-mcp-tool-results-structure-only-nonempty-json-objects ()
  (limen-mcp-tests--with-state
    (let (value)
      (limen-register-operation
       "sample.result" (lambda (_arguments _request) value)
       :description "Return a sample result." :parameters nil
       :interfaces '(mcp))
      (let* ((session (limen-open-session
                       :provider 'test :project-root default-directory))
             (route (limen-mcp-register-session session))
             (id 10)
             observed)
        (limen-mcp-tests--initialize route)
        (dolist (case '((object ((answer . 42)))
                        (array [1 2])
                        (scalar 42)
                        (null nil)))
          (pcase-let ((`(,label ,canonical) case))
            (setq value canonical)
            (let* ((response
                    (limen-mcp-handle-request
                     (limen-mcp-tests--request
                      route "POST"
                      (limen-mcp-tests--message
                       "tools/call" (cl-incf id)
                       '((name . "sample_result") (arguments . ())))
                      `((mcp-session-id . ,(limen-mcp-route-id route))))))
                   (result (alist-get 'result
                                      (limen-mcp-tests--body response)))
                   (structured (assq 'structuredContent result)))
              (push (list label
                          (alist-get 'text
                                     (aref (alist-get 'content result) 0))
                          (if structured
                              (list 'present (cdr structured))
                            'absent))
                    observed))))
        (should
         (equal
          (nreverse observed)
          '((object "{\"answer\":42}" (present ((answer . 42))))
            (array "[1,2]" absent)
            (scalar "42" absent)
            (null "null" absent))))))))

(ert-deftest limen-mcp-tool-result-serializes-nested-json-null ()
  (limen-mcp-tests--with-state
    (limen-register-operation
     "sample.nulls"
     (lambda (_arguments _request)
       '((viewport . ((start . ((line . 1) (column . 0)))
                      (end . :json-null)))
         (metadata . ((label . :json-null)
                      (stale . :json-false)))))
     :description "Return nested null values." :parameters nil
     :interfaces '(mcp))
    (let* ((session (limen-open-session
                     :provider 'test :project-root default-directory))
           (route (limen-mcp-register-session session)))
      (limen-mcp-tests--initialize route)
      (let* ((null-sentinel (make-symbol "json-null"))
             (response
              (limen-mcp-handle-request
               (limen-mcp-tests--request
                route "POST"
                (limen-mcp-tests--message
                 "tools/call" 20
                 '((name . "sample_nulls") (arguments . ())))
                `((mcp-session-id . ,(limen-mcp-route-id route))))))
             (message
              (json-parse-string
               (alist-get 'body response)
               :object-type 'alist :array-type 'array
               :null-object null-sentinel :false-object :json-false))
             (error (alist-get 'error message))
             (expected
              `((viewport . ((start . ((line . 1) (column . 0)))
                              (end . ,null-sentinel)))
                (metadata . ((label . ,null-sentinel)
                             (stale . :json-false)))))
             (outcome
              (if error
                  (list 'error (alist-get 'code error))
                (condition-case condition
                    (let* ((result (alist-get 'result message))
                           (text
                            (alist-get 'text
                                       (aref (alist-get 'content result) 0)))
                           (text-value
                            (json-parse-string
                             text :object-type 'alist :array-type 'array
                             :null-object null-sentinel
                             :false-object :json-false)))
                      (list 'result
                            (alist-get 'isError result)
                            text-value
                            (alist-get 'structuredContent result)))
                  (error (list 'raised (car condition)))))))
        (should (equal outcome
                       (list 'result :json-false expected expected)))))))

(ert-deftest limen-mcp-json-null-is-not-an-empty-required-object ()
  (limen-mcp-tests--with-state
    (let ((calls 0))
      (limen-register-operation
       "sample.extension"
       (lambda (_arguments _request)
         (cl-incf calls)
         "accepted")
       :description "Accept extension settings."
       :parameters '((:name "extension" :type object :required t
                            :properties
                            ((:name "enabled" :type boolean))))
       :interfaces '(mcp))
      (let* ((session (limen-open-session
                       :provider 'test :project-root default-directory))
             (route (limen-mcp-register-session session))
             (headers `((mcp-session-id . ,(limen-mcp-route-id route)))))
        (limen-mcp-tests--initialize route)
        (let* ((empty-response
                (limen-mcp-handle-request
                 (limen-mcp-tests--request
                  route "POST"
                  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"sample_extension\",\"arguments\":{\"extension\":{}}}}"
                  headers)))
               (null-response
                (limen-mcp-handle-request
                 (limen-mcp-tests--request
                  route "POST"
                  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"sample_extension\",\"arguments\":{\"extension\":null}}}"
                  headers)))
               (empty-result
                (alist-get 'result (limen-mcp-tests--body empty-response)))
               (null-error
                (alist-get 'error (limen-mcp-tests--body null-response))))
          (should
           (equal
            (list (alist-get 'text
                             (aref (alist-get 'content empty-result) 0))
                  (alist-get 'code null-error)
                  calls)
            '("accepted" -32602 1))))))))

(ert-deftest limen-mcp-null-envelopes-return-json-rpc-responses ()
  (limen-mcp-tests--with-state
    (let* ((session (limen-open-session
                     :provider 'test :project-root default-directory))
           (route (limen-mcp-register-session session))
           (headers `((mcp-session-id . ,(limen-mcp-route-id route)))))
      (limen-mcp-tests--initialize route)
      (cl-labels
          ((observe (body)
             (condition-case condition
                 (let* ((response
                         (limen-mcp-handle-request
                          (limen-mcp-tests--request
                           route "POST" body headers)))
                        (message (limen-mcp-tests--body response)))
                   (list (alist-get 'status response)
                         (alist-get 'jsonrpc message)
                         (if (assq 'id message)
                             (list 'id (alist-get 'id message))
                           'missing-id)
                         (alist-get 'code (alist-get 'error message))
                         (and (assq 'result message) 'result)))
               (error (list 'raised (car condition))))))
        (should
         (equal
          (list
           (cons 'top-level-null (observe "null"))
           (cons 'null-params
                 (observe
                  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":null}"))
           (cons 'null-id
                 (observe
                  "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"tools/list\"}")))
          '((top-level-null 400 "2.0" (id nil) -32600 nil)
            (null-params 200 "2.0" (id 2) -32602 nil)
            (null-id 200 "2.0" (id nil) nil result))))))))

(ert-deftest limen-mcp-deferred-tool-call-delivers-one-current-result ()
  (limen-mcp-tests--with-state
    (let (request deliveries)
      (limen-register-operation
       "sample.defer"
       (lambda (_arguments actual-request)
         (setq request actual-request)
         limen-deferred)
       :description "Defer a sample." :parameters nil
       :interfaces '(mcp) :deferred t)
      (let* ((session (limen-open-session
                       :provider 'test :project-root default-directory))
             (route (limen-mcp-register-session session)))
        (limen-mcp-tests--initialize route)
        (let ((response
               (limen-mcp-handle-request
                (limen-mcp-tests--request
                 route "POST"
                 (limen-mcp-tests--message
                  "tools/call" 3
                  '((name . "sample_defer") (arguments . ())))
                 `((mcp-session-id . ,(limen-mcp-route-id route))))
                (lambda (message) (push message deliveries)))))
          (should (alist-get 'stream response))
          (should-not (alist-get 'body response))
          (should (limen-request-resolve request "finished"))
          (should (= (length deliveries) 1))
          (should (equal
                   (alist-get 'text
                              (aref (alist-get
                                     'content
                                     (alist-get 'result (car deliveries)))
                                    0))
                   "finished"))
          (should-not (limen-request-resolve request "late"))
          (should (= (length deliveries) 1)))))))

(ert-deftest limen-mcp-forgets-a-deferred-call-after-delivery ()
  (limen-mcp-tests--with-state
    (let (request deliveries)
      (limen-register-operation
       "sample.defer"
       (lambda (_arguments actual-request)
         (setq request actual-request)
         limen-deferred)
       :description "Defer a sample." :parameters nil
       :interfaces '(mcp) :deferred t)
      (let* ((session (limen-open-session
                       :provider 'test :project-root default-directory))
             (route (limen-mcp-register-session session))
             (client (make-limen-mcp-client :route route))
             (response
              (limen-mcp--dispatch-message
               route
               '((jsonrpc . "2.0") (id . 3) (method . "tools/call")
                 (params . ((name . "sample_defer") (arguments . ()))))
               (lambda (message) (push message deliveries)) client)))
        (setf (limen-mcp-client-pending client)
              (list (cons 3 (alist-get 'request response))))
        (should (limen-request-resolve request "finished"))
        (should (= (length deliveries) 1))
        (should-not (limen-mcp-client-pending client))))))

(ert-deftest limen-mcp-cancellation-stops-and-forgets-a-deferred-call ()
  (limen-mcp-tests--with-state
    (let* ((session (limen-open-session
                     :provider 'test :project-root default-directory))
           (route (limen-mcp-register-session session))
           (cancelled 0)
           rejected
           (request
            (limen-make-request
             :interface 'mcp :session session
             :reject (lambda (error) (setq rejected error))
             :cancel (lambda () (cl-incf cancelled))))
           (request-client (make-limen-mcp-client
                            :route route :pending (list (cons 3 request))))
           (cancel-client (make-limen-mcp-client :route route)))
      (push request-client (limen-mcp-route-clients route))
      (push cancel-client (limen-mcp-route-clients route))
      (limen-mcp--dispatch-message
       route
       '((jsonrpc . "2.0") (method . "notifications/cancelled")
         (params . ((requestId . 3))))
       nil cancel-client)
      (should (= cancelled 1))
      (should (equal rejected
                     '(limen-operation-failed "Request cancelled")))
      (should-not (limen-mcp-client-pending request-client)))))

(ert-deftest limen-mcp-disconnect-stops-all-deferred-calls ()
  (limen-mcp-tests--with-state
    (let* ((session (limen-open-session
                     :provider 'test :project-root default-directory))
           (route (limen-mcp-register-session session))
           (cancelled 0)
           (request
            (limen-make-request
             :interface 'mcp :session session :reject #'ignore
             :cancel (lambda () (cl-incf cancelled))))
           (client (make-limen-mcp-client
                    :route route :pending (list (cons 3 request)))))
      (push client (limen-mcp-route-clients route))
      (cl-letf (((symbol-function 'process-get)
                 (lambda (_process property)
                   (and (eq property 'limen-mcp-client) client))))
        (limen-mcp--sentinel 'closed "connection closed"))
      (should (= cancelled 1))
      (should-not (limen-mcp-client-pending client))
      (should-not (limen-mcp-route-clients route)))))

(ert-deftest limen-mcp-keep-alive-client-transfers-route-ownership ()
  (limen-mcp-tests--with-state
    (let ((cancelled 0)
          deferred-request)
      (limen-register-operation
       "sample.handoff"
       (lambda (_arguments request)
         (setq deferred-request request)
         (setf (limen-request-canceller request)
               (lambda () (cl-incf cancelled)))
         limen-deferred)
       :description "Defer across a route handoff." :parameters nil
       :interfaces '(mcp) :deferred t)
      (let* ((session-a (limen-open-session
                         :provider 'test :project-root default-directory))
             (session-b (limen-open-session
                         :provider 'test :project-root default-directory))
             (route-a (limen-mcp-register-session session-a))
             (route-b (limen-mcp-register-session session-b))
             (initialize-params
              '((protocolVersion . "2025-11-25")
                (capabilities . ())
                (clientInfo . ((name . "test") (version . "1"))))))
        (let ((properties (make-hash-table :test #'equal))
              (process 'keep-alive-client)
              (live t)
              (closed 0)
              client
              old-membership)
          (unwind-protect
              (cl-letf (((symbol-function 'process-get)
                         (lambda (actual-process property)
                           (gethash (cons actual-process property)
                                    properties)))
                        ((symbol-function 'process-put)
                         (lambda (actual-process property value)
                           (puthash (cons actual-process property) value
                                    properties)))
                        ((symbol-function 'process-live-p)
                         (lambda (actual-process)
                           (and (eq actual-process process) live)))
                        ((symbol-function 'process-send-string)
                         (lambda (_actual-process _string) t))
                        ((symbol-function 'delete-process)
                         (lambda (_actual-process)
                           (setq live nil)
                           (cl-incf closed))))
                (limen-mcp--serve-request
                 process
                 (limen-mcp-tests--request
                  route-a "POST"
                  (limen-mcp-tests--message
                   "initialize" 1 initialize-params)))
                (setq client
                      (gethash (cons process 'limen-mcp-client) properties))
                (limen-mcp--serve-request
                 process
                 (limen-mcp-tests--request
                  route-b "POST"
                  (limen-mcp-tests--message
                   "initialize" 2 initialize-params)))
                (setq old-membership
                      (and (memq client (limen-mcp-route-clients route-a)) t))
                (limen-mcp--serve-request
                 process
                 (limen-mcp-tests--request
                  route-b "POST"
                  (limen-mcp-tests--message
                   "tools/call" 3
                   '((name . "sample_handoff") (arguments . ())))
                  `((mcp-session-id . ,(limen-mcp-route-id route-b)))))
                (limen-mcp-unregister-session route-a)
                (should
                 (equal
                  (list old-membership
                        (cl-count client (limen-mcp-route-clients route-b)
                                  :test #'eq)
                        (eq (limen-mcp-client-route client) route-b)
                        cancelled
                        closed
                        (and (= (length (limen-mcp-client-pending client)) 1)
                             (eq (cdar (limen-mcp-client-pending client))
                                 deferred-request))
                        (limen-mcp-client-stream-p client)
                        live)
                  '(nil 1 t 0 0 t t t))))
            (when client
              (setf (limen-mcp-client-process client) nil))))))))

(ert-deftest limen-mcp-pending-client-handoff-is-deliverable-or-aborted ()
  (limen-mcp-tests--with-state
    (let ((cancelled 0)
          (route-b-calls 0))
      (limen-register-operation
       "sample.pending"
       (lambda (_arguments request)
         (setf (limen-request-canceller request)
               (lambda () (cl-incf cancelled)))
         limen-deferred)
       :description "Keep a request pending." :parameters nil
       :interfaces '(mcp) :deferred t)
      (limen-register-operation
       "sample.effect"
       (lambda (_arguments _request)
         (cl-incf route-b-calls)
         "route-b-result")
       :description "Perform a route-B effect." :parameters nil
       :interfaces '(mcp))
      (let* ((session-a (limen-open-session
                         :provider 'test :project-root default-directory))
             (session-b (limen-open-session
                         :provider 'test :project-root default-directory))
             (route-a (limen-mcp-register-session session-a))
             (route-b (limen-mcp-register-session session-b)))
        (limen-mcp-tests--initialize route-a)
        (limen-mcp-tests--initialize route-b)
        (let ((properties (make-hash-table :test #'equal))
              (process 'keep-alive-with-pending)
              (live t)
              (closed 0)
              (undeliverable 0)
              writes
              client
              serve-outcome)
          (unwind-protect
              (cl-letf (((symbol-function 'process-get)
                         (lambda (actual-process property)
                           (gethash (cons actual-process property)
                                    properties)))
                        ((symbol-function 'process-put)
                         (lambda (actual-process property value)
                           (puthash (cons actual-process property) value
                                    properties)))
                        ((symbol-function 'process-live-p)
                         (lambda (actual-process)
                           (and (eq actual-process process) live)))
                        ((symbol-function 'process-send-string)
                         (lambda (_actual-process wire)
                           (if live
                               (progn (push wire writes) t)
                             (cl-incf undeliverable)
                             nil)))
                        ((symbol-function 'delete-process)
                         (lambda (actual-process)
                           (when live
                             (setq live nil)
                             (cl-incf closed)
                             (limen-mcp--sentinel
                              actual-process "connection closed")))))
                (limen-mcp--serve-request
                 process
                 (limen-mcp-tests--request
                  route-a "POST"
                  (limen-mcp-tests--message
                   "tools/call" 1
                   '((name . "sample_pending") (arguments . ())))
                  `((mcp-session-id . ,(limen-mcp-route-id route-a)))))
                (setq client
                      (gethash (cons process 'limen-mcp-client) properties)
                      writes nil)
                (setq serve-outcome
                      (condition-case condition
                          (progn
                            (limen-mcp--serve-request
                             process
                             (limen-mcp-tests--request
                              route-b "POST"
                              (limen-mcp-tests--message
                               "tools/call" 2
                               '((name . "sample_effect")
                                 (arguments . ())))
                              `((mcp-session-id
                                 . ,(limen-mcp-route-id route-b)))))
                            'returned)
                        (error (list 'raised (car condition)))))
                (cl-labels
                    ((wire-contains-p (text)
                       (seq-some
                        (lambda (wire)
                          (string-match-p
                           (regexp-quote text)
                           (decode-coding-string wire 'utf-8-unix)))
                        writes)))
                  (let* ((route-b-response
                          (wire-contains-p "route-b-result"))
                         (old-delivery
                          (wire-contains-p "Request cancelled"))
                         (on-a
                          (and (memq client
                                     (limen-mcp-route-clients route-a))
                               t))
                         (on-b
                          (cl-count client (limen-mcp-route-clients route-b)
                                    :test #'eq))
                         (pending
                          (length (limen-mcp-client-pending client)))
                         (classification
                          (cond
                           ((and (= cancelled 1)
                                 (= route-b-calls 1)
                                 route-b-response
                                 (not old-delivery)
                                 live
                                 (= closed 0)
                                 (= undeliverable 0)
                                 (not on-a)
                                 (= on-b 1)
                                 (eq (limen-mcp-client-route client) route-b)
                                 (= pending 0)
                                 (eq serve-outcome 'returned))
                            'delivered)
                           ((and (= cancelled 1)
                                 (= route-b-calls 0)
                                 (not route-b-response)
                                 (not live)
                                 (> closed 0)
                                 (= undeliverable 0)
                                 (not on-a)
                                 (= on-b 0)
                                 (= pending 0)
                                 (eq serve-outcome 'returned))
                            'aborted)
                           (t
                            (list 'unsafe
                                  :route-b-calls route-b-calls
                                  :route-b-response
                                  (and route-b-response t)
                                  :old-delivery (and old-delivery t)
                                  :cancelled cancelled
                                  :live live
                                  :closed closed
                                  :undeliverable undeliverable
                                  :on-a on-a
                                  :on-b on-b
                                  :client-route
                                  (cond
                                   ((eq (limen-mcp-client-route client) route-a)
                                    'a)
                                   ((eq (limen-mcp-client-route client) route-b)
                                    'b)
                                   (t 'other))
                                  :pending pending
                                  :serve-outcome serve-outcome)))))
                    (should (memq classification '(delivered aborted))))))
            (when client
              (setf (limen-mcp-client-process client) nil))))))))

(ert-deftest limen-mcp-resources-publish-updates-only-to-subscribers ()
  (limen-mcp-tests--with-state
    (let* ((session (limen-open-session
                     :provider 'test :project-root default-directory))
           (route (limen-mcp-register-session session))
           (client (make-limen-mcp-client :route route))
           sent)
      (setf (limen-mcp-route-subscriptions route)
            '("emacs://context/selection"))
      (push client (limen-mcp-route-clients route))
      (cl-letf (((symbol-function 'limen-mcp--send-client-message)
                 (lambda (_client message) (push message sent))))
        (should
         (limen-session-publish
          session "context.selection"
          '((path . "/tmp/example.el") (line . 1) (column . 0))))
        (should (= (length sent) 1))
        (should (equal
                 (alist-get 'uri (alist-get 'params (car sent)))
                 "emacs://context/selection"))))))

(ert-deftest limen-mcp-header-whitespace-does-not-consume-values ()
  (let* ((wire (encode-coding-string
                "GET /mcp/sample HTTP/1.1\r\nAccept: text/event-stream\r\n\r\n"
                'utf-8-unix))
         (request (car (limen-mcp--decode-request wire))))
    (should (equal (limen-mcp--header 'accept
                                         (alist-get 'headers request))
                   "text/event-stream"))))

(ert-deftest limen-mcp-sse-response-uses-close-delimited-http-framing ()
  (let ((wire
         (decode-coding-string
          (limen-mcp--http-response
           '((status . 200)
             (headers . ((Content-Type . "text/event-stream")))
             (stream . t)))
          'utf-8-unix)))
    (should (string-match-p "Connection: close\r\n\r\n\\'" wire))
    (should-not (string-match-p "Content-Length:" wire))))

(ert-deftest limen-mcp-frames-utf8-and-pipelined-http-requests ()
  (let* ((body "{\"path\":\"grüße.el\"}")
         (encoded (encode-coding-string body 'utf-8-unix))
         (wire (concat
                (encode-coding-string
                 (format "POST /mcp/sample HTTP/1.1\r\nContent-Length: %d\r\n\r\n"
                         (length encoded))
                 'utf-8-unix)
                encoded))
         (second
          (encode-coding-string
           "GET /mcp/sample HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
           'utf-8-unix)))
    (should-not (limen-mcp--decode-request
                 (substring wire 0 (1- (length wire)))))
    (pcase-let* ((`(,request . ,remaining)
                  (limen-mcp--decode-request (concat wire second)))
                 (`(,next . ,last)
                  (limen-mcp--decode-request remaining)))
      (should (equal (alist-get 'body request) body))
      (should (equal (alist-get 'method next) "GET"))
      (should (string-empty-p last)))))

(ert-deftest limen-mcp-rejects-unauthorized-and-stale-sessions ()
  (limen-mcp-tests--with-state
    (let* ((session (limen-open-session
                     :provider 'test :project-root default-directory))
           (route (limen-mcp-register-session session))
           (unauthorized
            (limen-mcp-handle-request
             `((method . "POST")
               (path . ,(concat "/mcp/" (limen-mcp-route-id route)))
               (headers . ())
               (body . ,(limen-mcp-tests--message "tools/list" 1)))))
           (stale
            (limen-mcp-handle-request
             (limen-mcp-tests--request
              route "POST" (limen-mcp-tests--message "tools/list" 2)
              '((mcp-session-id . "stale"))))))
      (should (= (alist-get 'status unauthorized) 401))
      (should (= (alist-get 'status stale) 404))
      (should (assoc 'Content-Type (alist-get 'headers stale))))))

(ert-deftest limen-mcp-deferred-diff-conflict-is-a-tool-error-result ()
  (limen-mcp-tests--with-state
    (let (request deliveries)
      (limen-register-operation
       "sample.diff"
       (lambda (_arguments actual-request)
         (setq request actual-request)
         limen-deferred)
       :description "Open a tick-guarded sample diff."
       :parameters '((:name "expected_tick" :type integer :required t))
       :interfaces '(mcp) :deferred t)
      (let* ((session (limen-open-session
                       :provider 'test :project-root default-directory))
             (route (limen-mcp-register-session session)))
        (limen-mcp-tests--initialize route)
        (limen-mcp-handle-request
         (limen-mcp-tests--request
          route "POST"
          (limen-mcp-tests--message
           "tools/call" 7
           '((name . "sample_diff")
             (arguments . ((expected_tick . 41)))))
          `((mcp-session-id . ,(limen-mcp-route-id route))))
         (lambda (message) (push message deliveries)))
        (limen-request-reject
         request '(limen-conflict "Buffer changed since diff opened"))
        (let* ((message (car deliveries))
               (result (alist-get 'result message)))
          (should-not (assq 'error message))
          (should (eq (alist-get 'isError result) t)))))))

(provide 'limen-mcp-tests)
;;; limen-mcp-tests.el ends here
