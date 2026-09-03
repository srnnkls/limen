;;; limen-mcp.el --- Loopback Streamable HTTP MCP bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Exposes limen sessions through standard loopback MCP transports.

;;; Code:

(require 'cl-lib)
(require 'limen)
(require 'json)
(require 'seq)
(require 'subr-x)

(defgroup limen-mcp nil
  "Standard MCP access to limen sessions."
  :group 'limen)

(defcustom limen-mcp-max-request-bytes (* 1024 1024)
  "Maximum buffered bytes accepted from one MCP HTTP client."
  :type 'integer
  :group 'limen-mcp)

(defconst limen-mcp-protocol-versions
  '("2026-07-28" "2025-11-25" "2025-06-18" "2025-03-26" "2024-11-05")
  "MCP protocol versions accepted by the bridge, newest first.")

(cl-defstruct limen-mcp-route
  id token session clients protocol-version sink subscriptions)

(cl-defstruct limen-mcp-client
  process route stream-p pending)

(defvar limen-mcp--listener nil
  "Shared loopback HTTP listener.")
(defvar limen-mcp--routes (make-hash-table :test #'equal)
  "MCP routes keyed by opaque route ID.")
(defvar limen-mcp--unregistering nil)

(defun limen-mcp--value (key object)
  "Return KEY's value from OBJECT with symbol or string keys."
  (when (listp object)
    (or (alist-get key object nil nil #'eq)
        (alist-get (if (symbolp key) (symbol-name key) (intern key))
                   object nil nil #'equal))))

(defun limen-mcp--header (name headers)
  "Return case-insensitive header NAME from HEADERS."
  (let ((name (downcase (if (symbolp name) (symbol-name name) name))))
    (cdr (seq-find
          (lambda (header)
            (equal name (downcase (if (symbolp (car header))
                                      (symbol-name (car header))
                                    (car header)))))
          headers))))

(defun limen-mcp--secret (label)
  "Return an opaque local capability string prefixed with LABEL."
  (concat label "-"
          (secure-hash
           'sha256
           (format "%s:%s:%s:%s:%s" label (current-time) (emacs-pid)
                   (random most-positive-fixnum) (user-uid)))))

(defun limen-mcp--listener-port ()
  "Return the active listener port."
  (when (process-live-p limen-mcp--listener)
    (let ((service (process-contact limen-mcp--listener :service)))
      (if (stringp service) (string-to-number service) service))))

(defun limen-mcp-endpoint (route)
  "Return ROUTE's loopback MCP URL."
  (format "http://127.0.0.1:%d/mcp/%s"
          (or (limen-mcp--listener-port) 0)
          (limen-mcp-route-id route)))

(defun limen-mcp-state ()
  "Return the current listener state."
  (when-let* ((port (limen-mcp--listener-port)))
    `((host . "127.0.0.1") (port . ,port)
      (session_count . ,(hash-table-count limen-mcp--routes)))))

(defun limen-mcp--route-for-session (session)
  "Return the MCP route registered for SESSION."
  (let (found)
    (maphash (lambda (_id route)
               (when (eq session (limen-mcp-route-session route))
                 (setq found route)))
             limen-mcp--routes)
    found))

(defun limen-mcp--client-live-p (client)
  "Return non-nil when CLIENT has a live process."
  (let ((process (limen-mcp-client-process client)))
    (and process (process-live-p process))))

(defun limen-mcp--forget-client-request (client request)
  "Remove REQUEST from CLIENT's pending requests."
  (when client
    (setf (limen-mcp-client-pending client)
          (seq-remove (lambda (entry) (eq (cdr entry) request))
                      (limen-mcp-client-pending client)))))

(defun limen-mcp--pending-call (route request-id)
  "Return the client and pending call for REQUEST-ID on ROUTE."
  (seq-some
   (lambda (client)
     (when-let* ((entry (assoc request-id
                               (limen-mcp-client-pending client))))
       (list client entry)))
   (limen-mcp-route-clients route)))

(defun limen-mcp--cancel-client-requests (client)
  "Cancel and forget all deferred requests owned by CLIENT."
  (let ((pending (limen-mcp-client-pending client)))
    (setf (limen-mcp-client-pending client) nil)
    (dolist (entry pending)
      (ignore-errors
        (limen-request-cancel
         (cdr entry) '(limen-operation-failed "Request cancelled"))))))

(defun limen-mcp--outbound-json-value (value)
  "Return VALUE with JSON null sentinels ready for serialization."
  (cond
   ((eq value :json-null) nil)
   ((vectorp value)
    (vconcat (mapcar #'limen-mcp--outbound-json-value value)))
   ((and (consp value) (seq-every-p #'consp value))
    (mapcar
     (lambda (entry)
       (cons (car entry)
             (limen-mcp--outbound-json-value (cdr entry))))
     value))
   ((consp value)
    (mapcar #'limen-mcp--outbound-json-value value))
   (t value)))

(defun limen-mcp--json (object)
  "Serialize OBJECT as compact JSON."
  (json-serialize (limen-mcp--outbound-json-value object)
                  :false-object :json-false :null-object nil))

(defun limen-mcp--response (status &optional body headers stream)
  "Return an HTTP response with STATUS, BODY, HEADERS, and STREAM flag."
  `((status . ,status)
    (headers . ,(append headers
                        (unless (seq-find
                                 (lambda (header)
                                   (equal (downcase (symbol-name (car header)))
                                          "content-type"))
                                 headers)
                          '((Content-Type . "application/json")))))
    (body . ,body)
    ,@(when stream '((stream . t)))))

(defun limen-mcp--rpc-result (id result)
  "Return a JSON-RPC success for ID and RESULT."
  `((jsonrpc . "2.0")
    (id . ,(if (eq id :json-null) nil id))
    (result . ,result)))

(defun limen-mcp--rpc-error (id code message)
  "Return a JSON-RPC error for ID with CODE and MESSAGE."
  `((jsonrpc . "2.0")
    (id . ,(if (eq id :json-null) nil id))
    (error . ((code . ,code) (message . ,message)))))

(defun limen-mcp--json-response (status message &optional headers stream)
  "Return STATUS response for MESSAGE, HEADERS, and STREAM."
  (limen-mcp--response
   status (and message (limen-mcp--json message)) headers stream))

(defun limen-mcp--event-uri (name)
  "Return the MCP resource URI for event NAME."
  (concat "emacs://" (replace-regexp-in-string "\\." "/" name)))

(defun limen-mcp--event-name (uri)
  "Return the registered event name represented by URI."
  (when (string-match "\\`emacs://\\(.+\\)\\'" uri)
    (replace-regexp-in-string "/" "." (match-string 1 uri))))

(defun limen-mcp--tool-name (operation)
  "Return a transport-safe MCP name for OPERATION."
  (string-replace "." "_" operation))

(defun limen-mcp--tool-descriptors (session)
  "Return registry-derived MCP tools for SESSION."
  (let ((request (limen-make-request :interface 'mcp :session session)))
    (mapcar
     (lambda (operation)
       `((name . ,(limen-mcp--tool-name (alist-get 'name operation)))
         (description . ,(alist-get 'description operation))
         (inputSchema . ,(alist-get 'input_schema operation))
         (annotations . ((readOnlyHint . ,(if (equal (alist-get 'effect operation)
                                                     "read")
                                              t :json-false))))))
     (limen-operations request))))

(defun limen-mcp--operation-for-tool (session name)
  "Return SESSION's canonical operation for MCP tool NAME."
  (seq-some
   (lambda (operation)
     (let ((canonical (alist-get 'name operation)))
       (and (equal name (limen-mcp--tool-name canonical)) canonical)))
   (limen-operations
    (limen-make-request :interface 'mcp :session session))))

(defun limen-mcp--tool-result (value &optional error-p)
  "Return an MCP tool result for VALUE, marked when ERROR-P."
  (let ((text (if (stringp value)
                  value
                (limen-mcp--json value))))
    `((content . [((type . "text") (text . ,text))])
      ,@(when (and (consp value) (seq-every-p #'consp value))
          `((structuredContent . ,value)))
      (isError . ,(if error-p t :json-false)))))

(defun limen-mcp--initialize-params-p (params)
  "Return non-nil when PARAMS is a valid MCP initialize object."
  (and (listp params)
       (stringp (limen-mcp--value 'protocolVersion params))
       (let ((capabilities (or (assoc 'capabilities params)
                               (assoc "capabilities" params))))
         (and capabilities
              (or (listp (cdr capabilities))
                  (eq (cdr capabilities) :json-null))))
       (let ((client (limen-mcp--value 'clientInfo params)))
         (and (listp client)
              (stringp (limen-mcp--value 'name client))
              (stringp (limen-mcp--value 'version client))))))

(defun limen-mcp--protocol-version (requested)
  "Return the negotiated protocol version for REQUESTED."
  (if (member requested limen-mcp-protocol-versions)
      requested
    (car limen-mcp-protocol-versions)))

(defun limen-mcp--resource-descriptors ()
  "Return session event resources."
  (mapcar
   (lambda (event)
     `((uri . ,(limen-mcp--event-uri (alist-get 'name event)))
       (name . ,(alist-get 'name event))
       (description . ,(alist-get 'description event))
       (mimeType . "application/json")))
   (limen-events)))

(defun limen-mcp--resource-read (session uri)
  "Return SESSION resource URI contents, or nil when unknown."
  (when-let* ((name (limen-mcp--event-name uri))
              ((gethash name limen--events)))
    (let ((value (gethash name (limen-session-latest session))))
      `((contents . [((uri . ,uri) (mimeType . "application/json")
                      (text . ,(limen-mcp--json value)))]) ))))

(defun limen-mcp--condition-message (condition fallback)
  "Return CONDITION's public message or FALLBACK."
  (if (memq (car condition)
            '(limen-invalid-arguments
              limen-disabled-operation
              limen-unknown-operation
              limen-operation-failed
              limen-conflict
              limen-session-closed))
      (or (cadr condition) fallback)
    fallback))

(defun limen-mcp--call-tool (route id params deliver client)
  "Call ROUTE tool from PARAMS for ID, using DELIVER and CLIENT state."
  (let* ((session (limen-mcp-route-session route))
         (name (limen-mcp--value 'name params))
         (raw-arguments (limen-mcp--value 'arguments params))
         (arguments (if (eq raw-arguments :json-null) nil raw-arguments))
         (operation (and (stringp name)
                         (limen-mcp--operation-for-tool session name))))
    (if (not operation)
        (limen-mcp--json-response
         200 (limen-mcp--rpc-error id -32602 "Unknown tool"))
      (let (request)
        (setq request
              (limen-make-request
               :interface 'mcp
               :source (limen-session-provider session)
               :session session
               :frame (selected-frame)
               :window (selected-window)
               :resolve
               (lambda (value)
                 (limen-mcp--forget-client-request client request)
                 (when deliver
                   (funcall deliver
                            (limen-mcp--rpc-result
                             id (limen-mcp--tool-result value)))))
               :reject
               (lambda (condition)
                 (limen-mcp--forget-client-request client request)
                 (when deliver
                   (funcall deliver
                            (limen-mcp--rpc-result
                             id
                             (limen-mcp--tool-result
                              (limen-mcp--condition-message
                               condition "Request cancelled")
                              t)))))))
        (condition-case condition
            (let ((result (limen-call operation arguments request)))
              (if (eq result limen-deferred)
                  (append
                   (limen-mcp--response
                    200 nil
                    '((Content-Type . "text/event-stream")
                      (Cache-Control . "no-cache, no-store"))
                    t)
                   `((request . ,request)))
                (limen-mcp--json-response
                 200 (limen-mcp--rpc-result
                      id (limen-mcp--tool-result result)))))
          ((limen-invalid-arguments limen-disabled-operation
				    limen-unknown-operation)
           (limen-mcp--json-response
            200 (limen-mcp--rpc-error
                 id -32602
                 (limen-mcp--condition-message condition "Invalid params"))))
          (limen-operation-failed
           (limen-mcp--json-response
            200 (limen-mcp--rpc-result
                 id (limen-mcp--tool-result
                     (limen-mcp--condition-message condition "Operation failed") t))))
          (error
           (limen-mcp--json-response
            200 (limen-mcp--rpc-error id -32603 "Internal error"))))))))

(defun limen-mcp--dispatch-message (route message deliver client)
  "Dispatch one JSON-RPC MESSAGE for ROUTE through DELIVER and CLIENT."
  (let ((id (limen-mcp--value 'id message))
        (method (limen-mcp--value 'method message))
        (params (limen-mcp--value 'params message))
        (session (limen-mcp-route-session route)))
    (cond
     ((not (and (listp message)
                (equal (limen-mcp--value 'jsonrpc message) "2.0")
                (stringp method)))
      (limen-mcp--json-response
       400 (limen-mcp--rpc-error nil -32600 "Invalid Request")))
     ((equal method "initialize")
      (if (not (limen-mcp--initialize-params-p params))
          (limen-mcp--json-response
           200 (limen-mcp--rpc-error id -32602 "Invalid params"))
        (let ((version
               (limen-mcp--protocol-version
                (limen-mcp--value 'protocolVersion params))))
          (setf (limen-mcp-route-protocol-version route) version)
          (limen-mcp--json-response
           200
           (limen-mcp--rpc-result
            id
            `((protocolVersion . ,version)
              (capabilities . ((tools . ((listChanged . t)))
                               (resources . ((subscribe . t)
                                             (listChanged . :json-false)))
                               (prompts . ((listChanged . :json-false)))))
              (serverInfo . ((name . "limen")
                             (version . ,(number-to-string
                                          limen-protocol-version))))))
           `((Mcp-Session-Id . ,(limen-mcp-route-id route)))))))
     ((equal method "notifications/initialized")
      (limen-mcp--response 202 ""))
     ((equal method "notifications/cancelled")
      (when (listp params)
        (when-let* ((request-id (limen-mcp--value 'requestId params))
                    (pending (limen-mcp--pending-call route request-id)))
          (let ((pending-client (car pending))
                (request (cdadr pending)))
            (limen-mcp--forget-client-request pending-client request)
            (limen-request-cancel
             request '(limen-operation-failed "Request cancelled")))))
      (limen-mcp--response 202 ""))
     ((and (member method '("tools/call"
                            "resources/read"
                            "resources/subscribe"
                            "resources/unsubscribe"))
           (not (listp params)))
      (limen-mcp--json-response
       200 (limen-mcp--rpc-error id -32602 "Invalid params")))
     ((equal method "tools/list")
      (limen-mcp--json-response
       200 (limen-mcp--rpc-result
            id `((tools . ,(vconcat (limen-mcp--tool-descriptors session)))))))
     ((equal method "tools/call")
      (limen-mcp--call-tool route id params deliver client))
     ((equal method "resources/list")
      (limen-mcp--json-response
       200 (limen-mcp--rpc-result
            id `((resources . ,(vconcat (limen-mcp--resource-descriptors)))))))
     ((equal method "resources/read")
      (if-let* ((uri (limen-mcp--value 'uri params))
                (result (and (stringp uri)
                             (limen-mcp--resource-read session uri))))
          (limen-mcp--json-response
           200 (limen-mcp--rpc-result id result))
        (limen-mcp--json-response
         200 (limen-mcp--rpc-error id -32602 "Unknown resource"))))
     ((equal method "resources/subscribe")
      (let ((uri (limen-mcp--value 'uri params)))
        (if (not (and (stringp uri)
                      (limen-mcp--event-name uri)))
            (limen-mcp--json-response
             200 (limen-mcp--rpc-error id -32602 "Invalid resource"))
          (cl-pushnew uri (limen-mcp-route-subscriptions route)
                      :test #'equal)
          (limen-mcp--json-response
           200 (limen-mcp--rpc-result id nil)))))
     ((equal method "resources/unsubscribe")
      (setf (limen-mcp-route-subscriptions route)
            (delete (limen-mcp--value 'uri params)
                    (limen-mcp-route-subscriptions route)))
      (limen-mcp--json-response
       200 (limen-mcp--rpc-result id nil)))
     ((equal method "prompts/list")
      (limen-mcp--json-response
       200 (limen-mcp--rpc-result id '((prompts . [])))))
     (t
      (limen-mcp--json-response
       200 (limen-mcp--rpc-error id -32601 "Method not found"))))))

(defun limen-mcp--parse-message (body)
  "Parse BODY as one JSON-RPC object."
  (condition-case nil
      (json-parse-string body :object-type 'alist :array-type 'array
                         :null-object :json-null :false-object :json-false)
    (error nil)))

(defun limen-mcp--authorized-p (route headers)
  "Return non-nil when HEADERS authorize ROUTE."
  (equal (limen-mcp--header 'authorization headers)
         (concat "Bearer " (limen-mcp-route-token route))))

(defun limen-mcp--valid-session-header-p (route headers)
  "Return non-nil when HEADERS identify ROUTE's initialized session."
  (equal (limen-mcp--header 'mcp-session-id headers)
         (limen-mcp-route-id route)))

(defun limen-mcp-handle-request (request &optional deliver client)
  "Return the HTTP response for REQUEST.
DELIVER receives deferred JSON-RPC messages.  CLIENT carries stream state."
  (let* ((method (limen-mcp--value 'method request))
         (path (limen-mcp--value 'path request))
         (headers (or (limen-mcp--value 'headers request) nil))
         (route-id (and (stringp path)
                        (string-match "\\`/mcp/\\([a-z0-9-]+\\)\\'" path)
                        (match-string 1 path)))
         (route (and route-id (gethash route-id limen-mcp--routes))))
    (cond
     ((not route)
      (limen-mcp--json-response
       404 (limen-mcp--rpc-error nil -32001 "Session not found")))
     ((not (limen-mcp--authorized-p route headers))
      (limen-mcp--json-response
       401 (limen-mcp--rpc-error nil -32001 "Unauthorized")
       '((WWW-Authenticate . "Bearer"))))
     ((equal method "GET")
      (if (and (limen-mcp--valid-session-header-p route headers)
               (string-match-p
                "text/event-stream"
                (or (limen-mcp--header 'accept headers) "")))
          (progn
            (when client
              (setf (limen-mcp-client-stream-p client) t))
            (limen-mcp--response
             200 nil '((Content-Type . "text/event-stream")
                       (Cache-Control . "no-cache, no-store")) t))
        (limen-mcp--json-response
         405 (limen-mcp--rpc-error nil -32600 "Method not allowed")
         '((Allow . "POST, DELETE")))))
     ((equal method "DELETE")
      (if (not (limen-mcp--valid-session-header-p route headers))
          (limen-mcp--json-response
           404 (limen-mcp--rpc-error nil -32001 "Session not found"))
        (append (limen-mcp--response 204 "")
                `((close_route . ,route)))))
     ((not (equal method "POST"))
      (limen-mcp--json-response
       405 (limen-mcp--rpc-error nil -32600 "Method not allowed")
       '((Allow . "GET, POST, DELETE"))))
     (t
      (let* ((body (limen-mcp--value 'body request))
             (message (and (stringp body) (limen-mcp--parse-message body)))
             (rpc-method (and (listp message)
                              (limen-mcp--value 'method message))))
        (cond
         ((not message)
          (limen-mcp--json-response
           400 (limen-mcp--rpc-error nil -32700 "Parse error")))
         ((not (listp message))
          (limen-mcp--json-response
           400 (limen-mcp--rpc-error nil -32600 "Invalid Request")))
         ((and (not (equal rpc-method "initialize"))
               (not (limen-mcp--valid-session-header-p route headers)))
          (limen-mcp--json-response
           404 (limen-mcp--rpc-error nil -32001 "Session not found")))
         ((and (not (equal rpc-method "initialize"))
               (limen-mcp--header 'mcp-protocol-version headers)
               (not (equal (limen-mcp--header 'mcp-protocol-version headers)
                           (limen-mcp-route-protocol-version route))))
          (limen-mcp--json-response
           400 (limen-mcp--rpc-error nil -32600 "Protocol version mismatch")))
         (t
          (limen-mcp--dispatch-message route message deliver client))))))))

(defun limen-mcp--reason (status)
  "Return the HTTP reason phrase for STATUS."
  (pcase status
    (200 "OK") (202 "Accepted") (204 "No Content")
    (400 "Bad Request") (401 "Unauthorized") (404 "Not Found")
    (405 "Method Not Allowed") (411 "Length Required")
    (413 "Payload Too Large") (_ "Error")))

(defun limen-mcp--http-response (response)
  "Encode RESPONSE as a unibyte HTTP response."
  (let* ((status (alist-get 'status response))
         (body (or (alist-get 'body response) ""))
         (stream (alist-get 'stream response))
         (headers (alist-get 'headers response))
         (head
          (concat
           (format "HTTP/1.1 %d %s\r\n" status (limen-mcp--reason status))
           (mapconcat
            (lambda (header) (format "%s: %s\r\n" (car header) (cdr header)))
            headers "")
           (if stream
               "Connection: close\r\n\r\n"
             (format "Content-Length: %d\r\nConnection: keep-alive\r\n\r\n"
                     (string-bytes (encode-coding-string body 'utf-8-unix)))))))
    (encode-coding-string (concat head body) 'utf-8-unix)))

(defun limen-mcp--sse-frame (sequence message)
  "Encode MESSAGE as an SSE frame with SEQUENCE."
  (let ((data (limen-mcp--json message)))
    (format "id: %d\nevent: message\ndata: %s\n\n" sequence data)))

(defun limen-mcp--send-client-message (client message)
  "Send JSON-RPC MESSAGE to streaming CLIENT."
  (when (and (limen-mcp-client-stream-p client)
             (limen-mcp--client-live-p client))
    (let* ((route (limen-mcp-client-route client))
           (session (limen-mcp-route-session route))
           (sequence (cl-incf (limen-session-sequence session))))
      (process-send-string
       (limen-mcp-client-process client)
       (encode-coding-string
        (limen-mcp--sse-frame sequence message) 'utf-8-unix))
      t)))

(defun limen-mcp--event-published (route _session name _payload)
  "Notify ROUTE subscribers that event NAME changed."
  (let ((uri (limen-mcp--event-uri name)))
    (when (member uri (limen-mcp-route-subscriptions route))
      (dolist (client (copy-sequence (limen-mcp-route-clients route)))
        (limen-mcp--send-client-message
         client
         `((jsonrpc . "2.0")
           (method . "notifications/resources/updated")
           (params . ((uri . ,uri)))))))))

(defun limen-mcp--operations-changed (_action _name)
  "Notify streaming clients that the MCP tool list changed."
  (maphash
   (lambda (_id route)
     (dolist (client (copy-sequence (limen-mcp-route-clients route)))
       (limen-mcp--send-client-message
        client '((jsonrpc . "2.0")
                 (method . "notifications/tools/list_changed")))))
   limen-mcp--routes))

(defun limen-mcp--decode-request (input)
  "Decode one complete HTTP request from unibyte INPUT.
Return a cons of request and remaining bytes, or nil when incomplete."
  (when-let* ((boundary (string-match "\r\n\r\n" input)))
    (let* ((lines (split-string
                   (decode-coding-string (substring input 0 boundary) 'us-ascii-unix)
                   "\r\n"))
           (request-line (split-string (car lines) " "))
           (headers
            (delq nil
                  (mapcar
                   (lambda (line)
                     (when (string-match "\\`\\([^:]+\\):[[:blank:]]*\\(.*\\)\\'" line)
                       (cons (intern (downcase (match-string 1 line)))
                             (match-string 2 line))))
                   (cdr lines))))
           (method (car request-line))
           (body-start (+ boundary 4))
           (length-value (limen-mcp--header 'content-length headers))
           (body-length (if length-value
                            (and (string-match-p "\\`[0-9]+\\'" length-value)
                                 (string-to-number length-value))
                          (and (member method '("GET" "DELETE")) 0))))
      (cond
       ((not (= (length request-line) 3))
        (signal 'limen-invalid-request '("Malformed HTTP request line")))
       ((limen-mcp--header 'transfer-encoding headers)
        (signal 'limen-invalid-request '("Chunked requests are unsupported")))
       ((null body-length)
        (signal 'limen-invalid-request '("Missing Content-Length")))
       ((> body-length limen-mcp-max-request-bytes)
        (signal 'limen-invalid-request '("Request body is too large")))
       ((< (- (length input) body-start) body-length) nil)
       (t
        (let ((body-end (+ body-start body-length)))
          (cons
           `((method . ,method)
             (path . ,(cadr request-line))
             (headers . ,headers)
             (body . ,(decode-coding-string
                       (substring input body-start body-end) 'utf-8-unix)))
           (substring input body-end))))))))

(defun limen-mcp--transfer-client-route (client route)
  "Transfer CLIENT ownership and state to ROUTE."
  (let ((previous (limen-mcp-client-route client)))
    (if (eq previous route)
        t
      (when previous
        (setf (limen-mcp-route-clients previous)
              (delq client (limen-mcp-route-clients previous))))
      (limen-mcp--cancel-client-requests client)
      (setf (limen-mcp-client-stream-p client) nil
            (limen-mcp-client-route client) nil)
      (when (limen-mcp--client-live-p client)
        (setf (limen-mcp-client-route client) route)
        (cl-pushnew client (limen-mcp-route-clients route) :test #'eq)
        t))))

(defun limen-mcp--client (process route)
  "Return PROCESS client for ROUTE, creating it when needed."
  (or (process-get process 'limen-mcp-client)
      (let ((client (make-limen-mcp-client :process process :route route)))
        (process-put process 'limen-mcp-client client)
        (when route (push client (limen-mcp-route-clients route)))
        client)))

(defun limen-mcp--route-from-request (request)
  "Return the registered route named by REQUEST's path."
  (let ((path (limen-mcp--value 'path request)))
    (and (stringp path)
         (string-match "\\`/mcp/\\([a-z0-9-]+\\)\\'" path)
         (gethash (match-string 1 path) limen-mcp--routes))))

(defun limen-mcp--serve-request (process request)
  "Serve decoded HTTP REQUEST through PROCESS."
  (let* ((route (limen-mcp--route-from-request request))
         (client (limen-mcp--client process route)))
    (if (and route
             (not (eq route (limen-mcp-client-route client)))
             (not (limen-mcp--transfer-client-route client route)))
        nil
      (let* ((deliver
              (lambda (message)
                (when (process-live-p process)
                  (setf (limen-mcp-client-stream-p client) t)
                  (limen-mcp--send-client-message client message)
                  (delete-process process))))
             (response (limen-mcp-handle-request request deliver client)))
        (when (alist-get 'stream response)
          (setf (limen-mcp-client-stream-p client) t))
        (when-let* ((pending (alist-get 'request response)))
          (push (cons (limen-mcp--value
                       'id (limen-mcp--parse-message
                            (limen-mcp--value 'body request)))
                      pending)
                (limen-mcp-client-pending client)))
        (process-send-string process (limen-mcp--http-response response))
        (when-let* ((closing (alist-get 'close_route response)))
          (limen-mcp-unregister-session closing))))))

(defun limen-mcp--filter (process chunk)
  "Accumulate CHUNK and serve complete requests from PROCESS."
  (let ((input (concat (or (process-get process 'limen-mcp-input)
                           (encode-coding-string "" 'binary))
                       (encode-coding-string chunk 'binary))))
    (if (> (length input) (+ limen-mcp-max-request-bytes 16384))
        (progn
          (process-send-string
           process
           (limen-mcp--http-response
            (limen-mcp--json-response
             413 (limen-mcp--rpc-error nil -32600 "Payload too large"))))
          (delete-process process))
      (condition-case condition
          (let (decoded)
            (while (setq decoded (limen-mcp--decode-request input))
              (setq input (cdr decoded))
              (limen-mcp--serve-request process (car decoded)))
            (when (process-live-p process)
              (process-put process 'limen-mcp-input input)))
        (limen-invalid-request
         (when (process-live-p process)
           (process-send-string
            process
            (limen-mcp--http-response
             (limen-mcp--json-response
              (if (string-match-p "large" (or (cadr condition) "")) 413 400)
              (limen-mcp--rpc-error nil -32600
                                    (or (cadr condition) "Invalid Request")))))
           (delete-process process)))))))

(defun limen-mcp--sentinel (process _event)
  "Release PROCESS from its route when it closes."
  (when-let* ((client (process-get process 'limen-mcp-client)))
    (limen-mcp--cancel-client-requests client)
    (when-let* ((route (limen-mcp-client-route client)))
      (setf (limen-mcp-route-clients route)
            (delq client (limen-mcp-route-clients route))))))

(defun limen-mcp--accept (_listener client _message)
  "Configure accepted MCP CLIENT."
  (set-process-coding-system client 'binary 'binary)
  (set-process-query-on-exit-flag client nil)
  (set-process-filter client #'limen-mcp--filter)
  (set-process-sentinel client #'limen-mcp--sentinel))

(defun limen-mcp--start-listener ()
  "Start the shared loopback listener."
  (unless (process-live-p limen-mcp--listener)
    (setq limen-mcp--listener
          (make-network-process
           :name "limen-mcp" :server t :host "127.0.0.1" :service t
           :family 'ipv4 :noquery t :coding 'binary
           :filter-multibyte nil :log #'limen-mcp--accept)))
  limen-mcp--listener)

(defun limen-mcp-register-session (session)
  "Expose an open limen SESSION through the shared MCP listener."
  (or (limen-mcp--route-for-session session)
      (progn
        (when (limen-session-closed-p session)
          (signal 'limen-session-closed '("Session is closed")))
        (limen-mcp--start-listener)
        (let* ((route (make-limen-mcp-route
                       :id (limen-mcp--secret "session")
                       :token (limen-mcp--secret "token")
                       :session session))
               (sink (lambda (actual-session name payload)
                       (limen-mcp--event-published
                        route actual-session name payload))))
          (setf (limen-mcp-route-sink route) sink)
          (puthash (limen-mcp-route-id route) route limen-mcp--routes)
          (limen-session-subscribe session sink)
          route))))

(defun limen-mcp--remove-route (route)
  "Remove ROUTE and close its network clients."
  (remhash (limen-mcp-route-id route) limen-mcp--routes)
  (when-let* ((sink (limen-mcp-route-sink route)))
    (limen-session-unsubscribe (limen-mcp-route-session route) sink))
  (dolist (client (copy-sequence (limen-mcp-route-clients route)))
    (limen-mcp--cancel-client-requests client)
    (when (limen-mcp--client-live-p client)
      (delete-process (limen-mcp-client-process client))))
  (setf (limen-mcp-route-clients route) nil)
  (when (and (= (hash-table-count limen-mcp--routes) 0)
             (process-live-p limen-mcp--listener))
    (delete-process limen-mcp--listener)
    (setq limen-mcp--listener nil))
  t)

(defun limen-mcp-unregister-session (route-or-session)
  "Unregister ROUTE-OR-SESSION and close its limen session."
  (when-let* ((route (if (limen-mcp-route-p route-or-session)
                         route-or-session
                       (limen-mcp--route-for-session route-or-session))))
    (let ((session (limen-mcp-route-session route))
          (limen-mcp--unregistering t))
      (limen-mcp--remove-route route)
      (unless (limen-session-closed-p session)
        (limen-close-session session)))
    t))

(defun limen-mcp--session-closed (session)
  "Remove SESSION's MCP route when it closes elsewhere."
  (unless limen-mcp--unregistering
    (when-let* ((route (limen-mcp--route-for-session session)))
      (limen-mcp--remove-route route))))

(add-hook 'limen-operation-change-hook #'limen-mcp--operations-changed)
(add-hook 'limen-session-close-hook #'limen-mcp--session-closed t)

(provide 'limen-mcp)
;;; limen-mcp.el ends here
