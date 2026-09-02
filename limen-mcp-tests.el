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
