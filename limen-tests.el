;;; limen-tests.el --- Agent-facing Emacs interface tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)
(require 'limen)

(defmacro limen-tests--with-registry (&rest body)
  (declare (indent 0) (debug t))
  `(let ((limen--operations (copy-hash-table limen--operations))
         (limen--buffers (make-hash-table :test #'eq)))
     ,@body))

(defun limen-tests--decode-dispatch (response)
  (pcase-let* ((`(,status ,encoded) (split-string response ":"))
               (payload (decode-coding-string (base64-decode-string encoded) 'utf-8)))
    (cons (string-to-number status) payload)))

(ert-deftest limen-registers-replaces-discovers-and-validates-operations ()
  (limen-tests--with-registry
    (let (seen)
      (limen-register-operation
       "sample.lookup"
       (lambda (arguments context)
         (setq seen (list arguments context))
         "old")
       :description "Look up a sample."
       :effect 'read
       :parameters '((:name "name" :type string :required t)))
      (limen-register-operation
       "sample.lookup"
       (lambda (arguments context)
         (setq seen (list arguments context))
         (alist-get 'name arguments))
       :description "Look up a replacement sample."
       :effect 'read
       :parameters '((:name "name" :type string :required t)))
      (let ((descriptor (car (seq-filter
                              (lambda (entry)
                                (equal (alist-get 'name entry) "sample.lookup"))
                              (limen-operations
                               (limen-make-request :interface 'cli))))))
        (should (equal (alist-get 'description descriptor)
                       "Look up a replacement sample.")))
      (should (equal (limen-call
                      "sample.lookup" '((name . "current"))
                      (limen-make-request :interface 'cli :source 'cli))
                     "current"))
      (should (equal (alist-get 'name (car seen)) "current"))
      (should-error
       (limen-call "sample.lookup" nil (limen-make-request :interface 'cli))
       :type 'limen-invalid-arguments)
      (should-error
       (limen-call "sample.lookup" '((name . 7)) (limen-make-request :interface 'cli))
       :type 'limen-invalid-arguments)
      (should-error
       (limen-call "sample.lookup" '((name . "x") (extra . t))
                      (limen-make-request :interface 'cli))
       :type 'limen-invalid-arguments)
      (limen-register-operation
       "sample.array" (lambda (arguments _context) (alist-get 'items arguments))
       :parameters '((:name "items" :type array :required t)))
      (should (equal (limen-call "sample.array" '((items . [1 2]))
                                    (limen-make-request :interface 'cli))
                     [1 2]))
      (should-error
       (limen-call "sample.array" '((items . ((key . "value"))))
                      (limen-make-request :interface 'cli))
       :type 'limen-invalid-arguments))))

(ert-deftest limen-empty-operation-schema-serializes-properties-as-an-object ()
  (limen-tests--with-registry
    (limen-register-operation
     "sample.empty" #'ignore :description "Empty." :parameters nil)
    (let* ((descriptor
            (seq-find (lambda (entry)
                        (equal (alist-get 'name entry) "sample.empty"))
                      (limen-operations)))
           (parsed
            (json-parse-string
             (json-serialize descriptor :null-object nil
                             :false-object :json-false)
             :object-type 'hash-table :array-type 'array
             :null-object nil :false-object :json-false))
           (schema (gethash "input_schema" parsed)))
      (should (hash-table-p (gethash "properties" schema))))))

(ert-deftest limen-projects-prefer-projectile-with-project-fallback ()
  (let ((projectile-root (make-temp-file "limen-projectile" t))
        (project-root (make-temp-file "limen-project" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'projectile-relevant-known-projects)
                   (lambda () (list projectile-root)))
                  ((symbol-function 'project-known-project-roots)
                   (lambda () (list project-root))))
          (let ((original-require (symbol-function 'require)))
            (cl-letf (((symbol-function 'require)
                       (lambda (feature &optional filename noerror)
                         (if (eq feature 'projectile)
                             t
                           (funcall original-require feature filename noerror)))))
              (should (equal (limen--known-project-roots)
                             (list (file-name-as-directory
                                    (file-truename projectile-root))))))
            (cl-letf (((symbol-function 'require)
                       (lambda (feature &optional filename noerror)
                         (if (eq feature 'projectile)
                             nil
                           (funcall original-require feature filename noerror)))))
              (should (equal (limen--known-project-roots)
                             (list (file-name-as-directory
                                    (file-truename project-root))))))))
      (delete-directory projectile-root t)
      (delete-directory project-root t))))

(ert-deftest limen-project-root-prefers-projectile-with-project-fallback ()
  (let ((projectile-root (make-temp-file "limen-projectile-root" t))
        (project-root (make-temp-file "limen-project-root" t))
        (original-require (symbol-function 'require)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &optional filename noerror)
                       (if (eq feature 'projectile)
                           t
                         (funcall original-require feature filename noerror))))
                    ((symbol-function 'projectile-project-root)
                     (lambda (_directory) projectile-root))
                    ((symbol-function 'project-current)
                     (lambda (&rest _arguments)
                       (ert-fail "project.el fallback was called"))))
            (should (equal (limen--project-root default-directory)
                           (file-truename projectile-root))))
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &optional filename noerror)
                       (if (eq feature 'projectile)
                           nil
                         (funcall original-require feature filename noerror))))
                    ((symbol-function 'project-current)
                     (lambda (&rest _arguments) 'project))
                    ((symbol-function 'project-root)
                     (lambda (_project) project-root)))
            (should (equal (limen--project-root default-directory)
                           (file-truename project-root)))))
      (delete-directory projectile-root t)
      (delete-directory project-root t))))

(ert-deftest limen-project-list-marks-the-current-project ()
  (let ((current (file-name-as-directory
                  (file-truename (make-temp-file "limen-current-project" t))))
        (other (file-name-as-directory
                (file-truename (make-temp-file "limen-other-project" t)))))
    (unwind-protect
        (cl-letf (((symbol-function 'limen--known-project-roots)
                   (lambda () (list current other))))
          (let ((projects
                 (limen--project-list
                  nil (limen-make-request :interface 'cli
                                          :project-root current))))
            (should (equal (mapcar (lambda (project)
                                    (alist-get 'root project))
                                  (append projects nil))
                           (list current other)))
            (should (eq (alist-get 'current (aref projects 0)) t))
            (should (eq (alist-get 'current (aref projects 1))
                        :json-false))))
      (delete-directory current t)
      (delete-directory other t))))

(ert-deftest limen-base-operations-use-buffer-and-window-terminology ()
  (limen-tests--with-registry
    (let* ((root (file-truename (make-temp-file "limen-root" t)))
           (file (expand-file-name "inside.el" root))
           (outside (make-temp-file "limen-outside"))
           buffer)
      (unwind-protect
          (save-window-excursion
            (with-temp-file file (insert "one\ntwo\n"))
            (setq buffer
                  (limen-call
                   "buffer.open"
                   '((path . "inside.el") (line . 2) (column . 1))
                   (limen-make-request
                    :interface 'cli :project-root root :owner 'test-owner)))
            (should (equal (alist-get 'file buffer) file))
            (should (equal (alist-get 'line buffer) 2))
            (should (seq-find
                     (lambda (entry) (equal (alist-get 'file entry) file))
                     (limen-call "buffer.list" nil
                                    (limen-make-request :interface 'cli :project-root root))))
            (should (seq-find
                     (lambda (entry)
                       (equal (alist-get 'buffer entry)
                              (file-name-nondirectory file)))
                     (limen-call "window.list" nil
                                    (limen-make-request :interface 'cli :project-root root))))
            (should-error
             (limen-call "buffer.open" `((path . ,outside))
                            (limen-make-request :interface 'cli :project-root root))
             :type 'limen-operation-failed))
        (when (buffer-live-p (get-file-buffer file))
          (kill-buffer (get-file-buffer file)))
        (delete-directory root t)
        (when (file-exists-p outside) (delete-file outside))))))

(ert-deftest limen-window-list-with-project-root-omits-unrelated-windows ()
  (limen-tests--with-registry
    (let* ((root (file-truename (make-temp-file "limen-window-root" t)))
           (inside-file (expand-file-name "inside.el" root))
           (outside-file (make-temp-file "limen-window-outside"))
           inside-buffer outside-buffer non-file-buffer)
      (unwind-protect
          (save-window-excursion
            (with-temp-file inside-file (insert "inside\n"))
            (setq inside-buffer (find-file-noselect inside-file)
                  outside-buffer (find-file-noselect outside-file)
                  non-file-buffer (generate-new-buffer "*limen non-file*"))
            (delete-other-windows)
            (set-window-buffer (selected-window) inside-buffer)
            (set-window-buffer (split-window-right) outside-buffer)
            (set-window-buffer (split-window-below) non-file-buffer)
            (let ((records
                   (append
                    (limen-call
                     "window.list" nil
                     (limen-make-request
                      :interface 'cli :project-root root
                      :frame (selected-frame)))
                    nil)))
              (should
               (equal
                (mapcar (lambda (record)
                          (list (alist-get 'buffer record)
                                (alist-get 'file record)))
                        records)
                (list (list (buffer-name inside-buffer) inside-file))))))
        (dolist (buffer (list inside-buffer outside-buffer non-file-buffer))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (delete-directory root t)
        (when (file-exists-p outside-file) (delete-file outside-file))))))

(ert-deftest limen-buffer-open-updates-visible-state-and-releases-owner ()
  (limen-tests--with-registry
    (let* ((root (file-truename (make-temp-file "limen-visible" t)))
           (file (expand-file-name "visible.el" root))
           buffer)
      (unwind-protect
          (save-window-excursion
            (with-temp-file file (insert "one\ntwo\n"))
            (delete-other-windows)
            (let ((target (split-window-right))
                  (context (limen-make-request
                            :interface 'mcp :project-root root
                            :owner 'visible-owner)))
              (setf (limen-request-window context) target)
              (limen-call "buffer.open" '((path . "visible.el")) context)
              (setq buffer (get-file-buffer file))
              (with-current-buffer buffer
                (goto-char (point-max))
                (push-mark (point-min) t t))
              (set-window-point target (point-min))
              (limen-call
               "buffer.open" '((path . "visible.el") (line . 2) (column . 1))
               context)
              (should (= (window-point target)
                         (with-current-buffer buffer (point))))
              (should-not (buffer-local-value 'mark-active buffer))
              (set-window-buffer (selected-window) buffer)
              (should (limen-release-owner 'visible-owner))
              (should (buffer-live-p buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory root t)))))

(ert-deftest limen-elisp-eval-is-hidden-and-disabled-by-default ()
  (limen-tests--with-registry
    (let ((limen-enable-elisp-eval nil))
      (should-not
       (seq-find (lambda (entry) (equal (alist-get 'name entry) "elisp.eval"))
                 (limen-operations (limen-make-request :interface 'cli))))
      (should-error
       (limen-call "elisp.eval" '((code . "(+ 1 2)")) (limen-make-request :interface 'cli))
       :type 'limen-disabled-operation))
    (let ((limen-enable-elisp-eval t))
      (should (equal (limen-call
                      "elisp.eval" '((code . "(+ 1 2)")) (limen-make-request :interface 'cli))
                     "3")))))

(ert-deftest limen-dispatch-decodes-command-argument-values ()
  (limen-tests--with-registry
    (limen-register-operation
     "sample.echo"
     (lambda (arguments _context) arguments)
     :description "Echo arguments."
     :effect 'read
     :parameters '((:name "text" :type string :required t)
                   (:name "count" :type integer :required t)))
    (let* ((text "grüße \"quoted\"")
           (request
            (json-serialize
             `((version . 1) (method . "call")
               (operation . "sample.echo")
               (arguments . ((text . ((base64 . ,(base64-encode-string
                                                    (encode-coding-string text 'utf-8)
                                                    t))))
                             (count . 7)))
               (cwd_base64 . ,(base64-encode-string default-directory t)))))
           (response
            (limen-tests--decode-dispatch
             (limen-server-dispatch (base64-encode-string request t))))
           (payload (json-parse-string (cdr response) :object-type 'alist)))
      (should (zerop (car response)))
      (should (equal (alist-get 'text (alist-get 'result payload)) text))
      (should (= (alist-get 'count (alist-get 'result payload)) 7)))))

(ert-deftest limen-dispatches-versioned-json-and-redacts-errors ()
  (limen-tests--with-registry
    (limen-register-operation
     "sample.fail" (lambda (_arguments _context) (error "secret detail"))
     :description "Fail." :effect 'read :parameters nil)
    (pcase-let* ((request (json-serialize
                           `((version . 1) (method . "call")
                             (operation . "sample.fail")
                             (arguments . ,(make-hash-table :test #'equal))
                             (cwd_base64 . "Lw=="))))
                 (`(,status . ,payload)
                  (limen-tests--decode-dispatch
                   (limen-server-dispatch
                    (base64-encode-string request t)))))
      (should (= status 5))
      (let ((response (json-parse-string payload :object-type 'alist
                                         :false-object nil)))
        (should-not (alist-get 'ok response))
        (should (equal (alist-get 'code (alist-get 'error response))
                       "internal_error"))
        (should-not (string-match-p "secret" payload))))
    (pcase-let* ((request (json-serialize
                           '((version . 2) (method . "operations")
                             (cwd_base64 . "Lw=="))))
                 (`(,status . ,payload)
                  (limen-tests--decode-dispatch
                   (limen-server-dispatch
                    (base64-encode-string request t)))))
      (should (= status 2))
      (should (string-match-p "unsupported_version" payload)))
    (dolist (arguments '("[]" "null"))
      (pcase-let* ((request
                    (format
                     "{\"version\":1,\"method\":\"call\",\"operation\":\"sample.fail\",\"arguments\":%s,\"cwd_base64\":\"Lw==\"}"
                     arguments))
                   (`(,status . ,payload)
                    (limen-tests--decode-dispatch
                     (limen-server-dispatch
                      (base64-encode-string request t)))))
        (should (= status 2))
        (should (string-match-p "invalid_request" payload))))))

(ert-deftest limen-sessions-dispatch-requests-events-and-deferred-results ()
  (limen-tests--with-registry
    (let ((limen--events (copy-hash-table limen--events))
          (limen--sessions (make-hash-table :test #'eq))
          deliveries resolved rejected request)
      (limen-register-event
       "sample.changed"
       :description "Report a changed sample."
       :parameters '((:name "value" :type string :required t))
       :replay t)
      (let ((session
             (limen-open-session
              :id "sample" :provider 'test :project-root default-directory)))
        (limen-session-subscribe
         session
         (lambda (_session name payload)
           (push (list name payload) deliveries)))
        (should (limen-session-publish
                 session "sample.changed" '((value . "first"))))
        (should-not (limen-session-publish
                     session "sample.changed" '((value . "first"))))
        (should-error
         (limen-session-publish session "sample.changed" '((value . 1)))
         :type 'limen-invalid-arguments)
        (setq request
              (limen-make-request
               :interface 'mcp :source 'test :session session
               :resolve (lambda (value) (setq resolved value))
               :reject (lambda (error) (setq rejected error))))
        (limen-register-operation
         "sample.defer"
         (lambda (_arguments actual-request)
           (should (eq actual-request request))
           limen-deferred)
         :description "Defer a sample."
         :parameters nil :interfaces '(mcp) :deferred t)
        (should (eq (limen-call "sample.defer" nil request)
                    limen-deferred))
        (should (limen-request-resolve request '((done . t))))
        (should (equal resolved '((done . t))))
        (should-not rejected)
        (let (replayed)
          (limen-session-subscribe
           session
           (lambda (_session name payload)
             (push (list name payload) replayed)))
          (should (equal (caar replayed) "sample.changed"))
          (should (= (alist-get 'sequence (cadar replayed)) 1)))
        (should (limen-close-session session))
        (should-not (limen-request-resolve request "late"))
        (should (= (length deliveries) 1))))))

(ert-deftest limen-request-cancel-stops-and-forgets-deferred-work ()
  (limen-tests--with-registry
    (let ((limen--sessions (make-hash-table :test #'eq))
          (cancelled 0)
          rejected)
      (limen-register-operation
       "sample.defer" (lambda (_arguments _request) limen-deferred)
       :description "Defer a sample."
       :parameters nil :interfaces '(mcp) :deferred t)
      (let* ((session (limen-open-session
                       :provider 'test :project-root default-directory))
             (request
              (limen-make-request
               :interface 'mcp :session session
               :reject (lambda (error) (setq rejected error))
               :cancel (lambda () (cl-incf cancelled)))))
        (should (eq (limen-call "sample.defer" nil request)
                    limen-deferred))
        (should (memq request (limen-session-requests session)))
        (should
         (limen-request-cancel
          request '(limen-operation-failed "Request cancelled")))
        (should (= cancelled 1))
        (should (equal rejected
                       '(limen-operation-failed "Request cancelled")))
        (should-not (limen-session-requests session))
        (should-not
         (limen-request-cancel
          request '(limen-operation-failed "Request cancelled")))
        (should (= cancelled 1))))))

(ert-deftest limen-skill-reflects-the-live-operation-registry ()
  (limen-tests--with-registry
    (limen-register-operation
     "sample.lookup" (lambda (_arguments _context) [])
     :description "Look up a sample." :effect 'read :parameters nil)
    (limen-register-operation
     "sample.fetch" (lambda (_arguments _context) [])
     :command "sample fetch"
     :description "Fetch a sample." :effect 'read :parameters nil)
    (let ((skill (limen-skill (limen-make-request :interface 'cli))))
      (should (string-match-p "limen --help" skill))
      (should (string-match-p "^- `sample\\.lookup` (read): Look up a sample\\.$" skill))
      (should (string-match-p "^- `limen sample fetch` (sample\\.fetch, read): Fetch a sample\\.$" skill))
      (should (string-match-p "^- `limen focus` (focus\\.get, read): " skill))
      (should (equal (alist-get 'command
                                (seq-find (lambda (o) (equal (alist-get 'name o) "sample.fetch"))
                                          (limen-operations (limen-make-request :interface 'cli))))
                     "sample fetch"))
      (should-not (string-match-p "elisp\\.eval" skill)))))

(ert-deftest limen-launcher-shows-command-help-by-default ()
  (let ((launcher (expand-file-name
                   "bin/limen"
                   (file-name-directory (locate-library "limen-tests")))))
    (cl-labels ((run (&rest arguments)
                  (with-temp-buffer
                    (should (zerop (apply #'process-file
                                          launcher nil t nil arguments)))
                    (buffer-string))))
      (let ((help (run)))
        (should (equal help (run "--help")))
        (should (string-match-p "Usage: limen <COMMAND>" help))
        (should (string-match-p "skill +Generate" help))
        (should (string-match-p "buffer +Work" help))
        (should (string-match-p "^  compile[[:space:]]" help))
        (should (string-match-p "^  context[[:space:]]" help))
        (should (string-match-p "^  trail[[:space:]]" help))
        (should (string-match-p "^  annotations[[:space:]]" help))
        (should (string-match-p "^  hook[[:space:]]" help))
        (should-not (string-match-p "registry" help))
        (should-not (string-match-p "limen call" help)))
      (should (equal (run "buffer") (run "help" "buffer")))
      (let ((compile-help (run "help" "compile")))
        (should (equal (run "compile") compile-help))
        (should (string-match-p "Usage: limen compile <COMMAND>"
                                compile-help))
        (dolist (command '("list" "read"))
          (should (string-match-p
                   (format "^  %s[[:space:]]" command)
                   compile-help))))
      (should (equal (run "buffer" "open" "--help")
                     (run "help" "buffer" "open")))
      (should (string-match-p
               "Usage: limen buffer open <PATH> \\[OPTIONS\\]"
               (run "buffer" "open" "--help"))))))

(ert-deftest limen-launcher-frames-json-without-elisp-interpolation ()
  (let* ((directory (make-temp-file "limen-cli" t))
         (client (expand-file-name "emacsclient" directory))
         (capture (expand-file-name "expression" directory))
         (launcher (expand-file-name
                    "bin/limen"
                    (file-name-directory (locate-library "limen-tests"))))
         (payload "{\"version\":1,\"ok\":true,\"result\":\"ok\"}")
         (response (format "\"0:%s\"\n" (base64-encode-string payload t))))
    (unwind-protect
        (progn
          (with-temp-file client
            (insert "#!/bin/sh\nprintf '%s' \"$2\" > \"$LIMEN_CAPTURE\"\nprintf '%s' \"$LIMEN_RESPONSE\"\n"))
          (set-file-modes client #o700)
          (let ((process-environment
                 (append (list (concat "EMACSCLIENT=" client)
                               (concat "LIMEN_CAPTURE=" capture)
                               (concat "LIMEN_RESPONSE=" response))
                         process-environment)))
            (with-temp-buffer
              (should (= (process-file launcher nil t nil
                                       "buffer" "open"
                                       "');(error \"injected\");('")
                         0))
              (should (equal (string-trim (buffer-string)) payload))))
          (with-temp-buffer
            (insert-file-contents capture)
            (let ((expression (buffer-string)))
              (should
               (string-match
                "(limen-server-dispatch \\\"\\([A-Za-z0-9+/=]+\\)\\\")"
                expression))
              (let* ((encoded-request (match-string 1 expression))
                     (request
                      (json-parse-string
                       (decode-coding-string
                        (base64-decode-string encoded-request) 'utf-8)
                       :object-type 'alist))
                     (path (alist-get 'path (alist-get 'arguments request))))
                (should (equal (alist-get 'operation request) "buffer.open"))
                (should (equal
                         (decode-coding-string
                          (base64-decode-string (alist-get 'base64 path)) 'utf-8)
                         "');(error \"injected\");('")))
              (should-not (string-match-p "injected" expression)))))
      (delete-directory directory t))))

(ert-deftest limen-launcher-compile-list-read-and-validation-contract ()
  (let* ((directory (make-temp-file "limen-compile-cli" t))
         (client (expand-file-name "emacsclient" directory))
         (capture (expand-file-name "expression" directory))
         (launcher (expand-file-name
                    "bin/limen"
                    (file-name-directory (locate-library "limen-tests"))))
         (payload "{\"version\":1,\"ok\":true,\"result\":[]}")
         (response (format "\"0:%s\"\n" (base64-encode-string payload t))))
    (unwind-protect
        (progn
          (with-temp-file client
            (insert
             "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do\n  case $1 in\n    -e|--eval)\n      shift\n      [ \"$#\" -gt 0 ] || exit 64\n      printf '%s' \"$1\" > \"$LIMEN_CAPTURE\"\n      printf '%s' \"$LIMEN_RESPONSE\"\n      exit 0\n      ;;\n  esac\n  shift\ndone\nexit 64\n"))
          (set-file-modes client #o700)
          (let ((process-environment
                 (append (list (concat "EMACSCLIENT=" client)
                               (concat "LIMEN_CAPTURE=" capture)
                               (concat "LIMEN_RESPONSE=" response))
                         process-environment)))
            (cl-labels
                ((run (&rest arguments)
                   (with-temp-buffer
                     (cons (apply #'process-file launcher nil t nil arguments)
                           (buffer-string))))
                 (expression-forms ()
                   (with-temp-buffer
                     (insert-file-contents capture)
                     (let ((expression
                            (car (read-from-string (buffer-string)))))
                       (if (eq (car-safe expression) 'progn)
                           (cdr expression)
                         (list expression)))))
                 (request (&rest arguments)
                   (pcase-let ((`(,status . ,output)
                                (apply #'run arguments)))
                     (should (= status 0))
                     (should (equal (string-trim output) payload)))
                   (let* ((forms (expression-forms))
                          (dispatch
                           (seq-find
                            (lambda (form)
                              (eq (car-safe form) 'limen-server-dispatch))
                            forms)))
                     (should (and dispatch
                                  (= (length dispatch) 2)
                                  (stringp (cadr dispatch))))
                     (cons
                      (json-parse-string
                       (decode-coding-string
                        (base64-decode-string (cadr dispatch)) 'utf-8)
                       :object-type 'hash-table :false-object :json-false)
                      forms)))
                 (decoded-string (value)
                   (should (hash-table-p value))
                   (should (= (hash-table-count value) 1))
                   (decode-coding-string
                    (base64-decode-string (gethash "base64" value)) 'utf-8))
                 (should-load-compile-before-dispatch (forms)
                   (let ((require-position
                          (cl-position '(require 'limen-compile) forms
                                       :test #'equal))
                         (dispatch-position
                          (cl-position-if
                           (lambda (form)
                             (eq (car-safe form) 'limen-server-dispatch))
                           forms)))
                     (should (= (cl-count '(require 'limen-compile) forms
                                          :test #'equal)
                                1))
                     (should (and require-position dispatch-position
                                  (< require-position dispatch-position))))))
              (dolist (arguments '(("compile" "bogus")
                                   ("compile" "read")
                                   ("compile" "read" "buffer" "extra")
                                   ("compile" "list" "extra")))
                (when (file-exists-p capture) (delete-file capture))
                (pcase-let ((`(,status . ,_output) (apply #'run arguments)))
                  (ert-info ((format "arguments=%S" arguments))
                    (should (= status 2))
                    (should-not (file-exists-p capture)))))
              (pcase-let* ((`(,list-request . ,list-forms)
                            (request "compile" "list"))
                           (arguments (gethash "arguments" list-request)))
                (should (equal (gethash "operation" list-request)
                               "compile.list"))
                (should (hash-table-p arguments))
                (should (zerop (hash-table-count arguments)))
                (should-load-compile-before-dispatch list-forms))
              (pcase-let* ((buffer-name "*compilé output 7*")
                           (`(,read-request . ,read-forms)
                            (request "compile" "read" buffer-name))
                           (arguments (gethash "arguments" read-request)))
                (should (equal (gethash "operation" read-request)
                               "compile.read"))
                (should (equal (decoded-string (gethash "name" arguments))
                               buffer-name))
                (should-load-compile-before-dispatch read-forms))
              (pcase-let ((`(,buffer-request . ,buffer-forms)
                           (request "buffer" "list")))
                (should (equal (gethash "operation" buffer-request)
                               "buffer.list"))
                (should-not
                 (cl-find '(require 'limen-compile) buffer-forms
                          :test #'equal))))))
      (delete-directory directory t))))

(ert-deftest limen-buffer-list-contract ()
  (let* ((root (file-truename (make-temp-file "limen-list-root" t)))
         (outside-root (file-truename
                        (make-temp-file "limen-list-outside" t)))
         (inside-file (expand-file-name "inside.el" root))
         (outside-file (expand-file-name "outside.el" outside-root))
         inside-buffer outside-buffer inside-virtual outside-virtual internal)
    (unwind-protect
        (progn
          (with-temp-file inside-file (insert "inside\n"))
          (with-temp-file outside-file (insert "outside\n"))
          (setq inside-buffer (find-file-noselect inside-file)
                outside-buffer (find-file-noselect outside-file)
                inside-virtual (generate-new-buffer "limen-list-virtual")
                outside-virtual (generate-new-buffer "limen-list-outside-virtual")
                internal (generate-new-buffer " limen-list-internal"))
          (with-current-buffer inside-virtual
            (setq default-directory (file-name-as-directory root)))
          (with-current-buffer outside-virtual
            (setq default-directory (file-name-as-directory outside-root)))
          (with-current-buffer internal
            (setq default-directory (file-name-as-directory root)))
          (let ((context (limen-make-request :interface 'cli
                                             :project-root root)))
            (cl-labels ((names (arguments)
                          (sort
                           (mapcar (lambda (record) (alist-get 'name record))
                                   (append (limen-call "buffer.list" arguments
                                                       context)
                                           nil))
                           #'string<)))
              (should (equal (names nil)
                             (list (buffer-name inside-buffer))))
              (should (equal (names '((virtual . :json-false)))
                             (list (buffer-name inside-buffer))))
              (should (equal (names '((virtual . t)))
                             (list (buffer-name inside-virtual))))
              (should (equal (names '((all . t)))
                             (sort (list (buffer-name inside-buffer)
                                         (buffer-name inside-virtual))
                                   #'string<)))
              (let* ((descriptor
                      (seq-find
                       (lambda (entry)
                         (equal (alist-get 'name entry) "buffer.list"))
                       (limen-operations context)))
                     (properties (alist-get
                                  'properties
                                  (alist-get 'input_schema descriptor))))
                (dolist (name '(virtual all))
                  (should (equal (alist-get
                                  'type (alist-get name properties))
                                 "boolean"))))
              (should-error
               (limen--buffer-list '((virtual . t) (all . t)) context)
               :type 'limen-invalid-arguments))))
      (dolist (buffer (list inside-buffer outside-buffer inside-virtual
                            outside-virtual internal))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest limen-buffer-read-contract ()
  (let* ((root (file-truename (make-temp-file "limen-read-root" t)))
         (outside-root (file-truename
                        (make-temp-file "limen-read-outside" t)))
         (inside-file (expand-file-name "inside.el" root))
         (unvisited-file (expand-file-name "unvisited.el" root))
         (outside-file (expand-file-name "outside.el" outside-root))
         (column-file (expand-file-name "columns.el" root))
         inside-buffer outside-buffer virtual-buffer outside-virtual internal
         column-buffer
         buffer-state)
    (unwind-protect
        (progn
          (with-temp-file inside-file (insert "saved\n"))
          (with-temp-file unvisited-file (insert "unvisited\n"))
          (with-temp-file outside-file (insert "outside\n"))
          (with-temp-file column-file (insert "start\n\t界z\n"))
          (setq inside-buffer (find-file-noselect inside-file)
                outside-buffer (find-file-noselect outside-file)
                virtual-buffer (generate-new-buffer "limen-read-virtual")
                outside-virtual (generate-new-buffer "limen-read-outside-virtual")
                internal (generate-new-buffer " limen-read-internal"))
          (with-current-buffer inside-buffer
            (erase-buffer)
            (insert "alpha\nlive\nomega")
            (add-text-properties 7 11 '(face bold))
            (narrow-to-region 7 12)
            (goto-char 8)
            (push-mark 10 t t)
            (setq buffer-state
                  (list (point) (mark) mark-active (point-min) (point-max)
                        (buffer-modified-p))))
          (with-current-buffer virtual-buffer
            (setq default-directory (file-name-as-directory root))
            (insert "virtual text"))
          (with-current-buffer outside-virtual
            (setq default-directory (file-name-as-directory outside-root))
            (insert "outside virtual"))
          (with-current-buffer internal
            (setq default-directory (file-name-as-directory root))
            (insert "internal"))
          (let* ((context (limen-make-request :interface 'cli
                                              :project-root root))
                 (record
                  (condition-case nil
                      (limen-call "buffer.read" '((path . "inside.el"))
                                  context)
                    (limen-unknown-operation :operation-missing))))
            (should (equal (and (listp record) (alist-get 'text record))
                           "live\n"))
            (should (equal (alist-get 'name record)
                           (buffer-name inside-buffer)))
            (should (equal (alist-get 'file record) inside-file))
            (should (equal (alist-get 'major_mode record)
                           "emacs-lisp-mode"))
            (should (eq (alist-get 'modified record) t))
            (should (= (alist-get 'line record) 2))
            (should (= (alist-get 'end_line record) 2))
            (should-not (text-property-any 0 (length (alist-get 'text record))
                                           'face 'bold
                                           (alist-get 'text record)))
            (let ((named-file
                   (limen-call
                    "buffer.read"
                    `((name . ,(buffer-name inside-buffer))) context)))
              (should (equal (alist-get 'text named-file)
                             "live\n")))
            (should-error
             (limen-call
              "buffer.read"
              `((name . ,(buffer-name virtual-buffer))) context)
             :type 'limen-operation-failed)
            (let ((middle
                   (limen-call "buffer.read"
                               '((path . "inside.el") (widen . t)
                                 (line . 2) (end_line . 2))
                               context)))
              (should (= (alist-get 'line middle) 2))
              (should (= (alist-get 'end_line middle) 2))
              (should (equal (alist-get 'text middle) "live\n")))
            (let ((last
                   (limen-call "buffer.read"
                               '((path . "inside.el") (widen . t)
                                 (line . 3) (end_line . 3))
                               context)))
              (should (= (alist-get 'line last) 3))
              (should (= (alist-get 'end_line last) 3))
              (should (equal (alist-get 'text last) "omega")))
            (with-current-buffer inside-buffer
              (should (equal
                       (list (point) (mark) mark-active (point-min) (point-max)
                             (buffer-modified-p))
                       buffer-state)))
            (let* ((descriptor
                    (seq-find
                     (lambda (entry)
                       (equal (alist-get 'name entry) "buffer.read"))
                     (limen-operations context)))
                   (schema (alist-get 'input_schema descriptor))
                   (properties (alist-get 'properties schema)))
              (dolist (parameter '((path . "string") (name . "string")
                                   (line . "integer")
                                   (end_line . "integer")
                                   (widen . "boolean")
                                   (expected_tick . "integer")))
                (should (equal
                         (alist-get 'type
                                    (alist-get (car parameter) properties))
                         (cdr parameter))))
              (should (equal (alist-get 'required schema) [])))
            (should (integerp (alist-get 'tick record)))
            (let ((same-tick
                   (limen-call
                    "buffer.read"
                    `((path . "inside.el")
                      (expected_tick . ,(alist-get 'tick record)))
                    context)))
              (should (equal (alist-get 'text same-tick) "live\n")))
            (let ((opened
                   (limen-call "buffer.open"
                               '((path . "columns.el")
                                 (line . 2) (column . 2))
                               context)))
              (setq column-buffer (get-file-buffer column-file))
              (should (= (alist-get 'column opened) 2))
              (with-current-buffer column-buffer
                (should (eq (char-after) ?z))))
            (with-current-buffer inside-buffer
              (goto-char (point-max))
              (insert "!"))
            (should-error
             (limen-call
              "buffer.read"
              `((path . "inside.el")
                (expected_tick . ,(alist-get 'tick record)))
              context)
             :type 'limen-operation-failed)
            (let* ((save-descriptor
                    (seq-find
                     (lambda (entry)
                       (equal (alist-get 'name entry) "buffer.save"))
                     (limen-operations context)))
                   (save-schema (alist-get 'input_schema save-descriptor))
                   (save-properties (alist-get 'properties save-schema))
                   (tick (with-current-buffer inside-buffer
                           (buffer-chars-modified-tick)))
                   saved)
              (should (equal (alist-get 'type
                                        (alist-get 'path save-properties))
                             "string"))
              (should (equal (alist-get 'type
                                        (alist-get 'expected_tick save-properties))
                             "integer"))
              (should (equal (append (alist-get 'required save-schema) nil)
                             '("path" "expected_tick")))
              (cl-letf (((symbol-function 'read-file-name)
                         (lambda (&rest _arguments)
                           (ert-fail "buffer.save prompted for a path")))
                        ((symbol-function 'yes-or-no-p)
                         (lambda (&rest _arguments)
                           (ert-fail "buffer.save prompted for confirmation")))
                        ((symbol-function 'y-or-n-p)
                         (lambda (&rest _arguments)
                           (ert-fail "buffer.save prompted for confirmation"))))
                (setq saved
                      (limen-call
                       "buffer.save"
                       `((path . "inside.el") (expected_tick . ,tick))
                       context)))
              (should (equal (alist-get 'file saved) inside-file))
              (should (integerp (alist-get 'tick saved)))
              (should (eq (alist-get 'modified saved) :json-false))
              (with-current-buffer inside-buffer
                (should (= (alist-get 'tick saved)
                           (buffer-chars-modified-tick)))
                (goto-char (point-max))
                (insert "buffer change")
                (setq tick (buffer-chars-modified-tick)))
              (with-temp-file inside-file (insert "disk change\n"))
              (set-file-times inside-file (time-add (current-time) 2))
              (should-error
               (limen-call
                "buffer.save"
                `((path . "inside.el") (expected_tick . ,tick))
                context)
               :type 'limen-operation-failed))
            (dolist
                (arguments
                 `((nil . nil)
                   (both . ((path . "inside.el")
                            (name . ,(buffer-name inside-buffer))))
                   (zero-line . ((path . "inside.el") (line . 0)))
                   (zero-end-line . ((path . "inside.el") (end_line . 0)))
                   (reversed . ((path . "inside.el")
                                (line . 3) (end_line . 2)))
                   (start-out-of-range . ((path . "inside.el") (line . 4)))
                   (end-out-of-range . ((path . "inside.el") (end_line . 4)))))
              (ert-info ((format "case=%s arguments=%S"
                                 (car arguments) (cdr arguments)))
                (should-error (limen-call "buffer.read" (cdr arguments)
                                          context)
                              :type 'limen-invalid-arguments)))
            (dolist
                (arguments
                 `((unvisited . ((path . "unvisited.el")))
                   (missing-path . ((path . "missing.el")))
                   (outside-path . ((path . ,outside-file)))
                   (outside-file-name
                    . ((name . ,(buffer-name outside-buffer))))
                   (outside-virtual-name
                    . ((name . ,(buffer-name outside-virtual))))
                   (internal-name . ((name . ,(buffer-name internal))))
                   (missing-name . ((name . "limen-read-missing")))))
              (ert-info ((format "case=%s arguments=%S"
                                 (car arguments) (cdr arguments)))
                (should-error (limen-call "buffer.read" (cdr arguments)
                                          context)
                              :type 'limen-operation-failed)))))
      (dolist (buffer (list inside-buffer outside-buffer virtual-buffer
                            outside-virtual internal column-buffer))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest limen-launcher-buffer-list-and-read-contract ()
  (let* ((directory (make-temp-file "limen-buffer-cli" t))
         (client (expand-file-name "emacsclient" directory))
         (capture (expand-file-name "expression" directory))
         (launcher (expand-file-name
                    "bin/limen"
                    (file-name-directory (locate-library "limen-tests"))))
         (payload "{\"version\":1,\"ok\":true,\"result\":[]}")
         (response (format "\"0:%s\"\n" (base64-encode-string payload t))))
    (unwind-protect
        (progn
          (with-temp-file client
            (insert "#!/bin/sh\nprintf '%s' \"$2\" > \"$LIMEN_CAPTURE\"\nprintf '%s' \"$LIMEN_RESPONSE\"\n"))
          (set-file-modes client #o700)
          (let ((process-environment
                 (append (list (concat "EMACSCLIENT=" client)
                               (concat "LIMEN_CAPTURE=" capture)
                               (concat "LIMEN_RESPONSE=" response))
                         process-environment)))
            (cl-labels
                ((run (&rest arguments)
                   (with-temp-buffer
                     (cons (apply #'process-file launcher nil t nil arguments)
                           (buffer-string))))
                 (request (&rest arguments)
                   (pcase-let ((`(,status . ,output)
                                (apply #'run arguments)))
                     (should (= status 0))
                     (should (equal (string-trim output) payload)))
                   (with-temp-buffer
                     (insert-file-contents capture)
                     (should
                      (re-search-forward
                       "(limen-server-dispatch \\\"\\([A-Za-z0-9+/=]+\\)\\\")"
                       nil t))
                     (json-parse-string
                      (decode-coding-string
                       (base64-decode-string (match-string 1)) 'utf-8)
                      :object-type 'alist :false-object :json-false)))
                 (decoded-string (value)
                   (should (equal (mapcar #'car value) '(base64)))
                   (decode-coding-string
                    (base64-decode-string (alist-get 'base64 value)) 'utf-8)))
              (let* ((virtual-request (request "buffer" "list" "--virtual"))
                     (arguments (alist-get 'arguments virtual-request)))
                (should (equal (alist-get 'operation virtual-request)
                               "buffer.list"))
                (should (eq (alist-get 'virtual arguments) t)))
              (let* ((all-request (request "buffer" "list" "--all"))
                     (arguments (alist-get 'arguments all-request)))
                (should (eq (alist-get 'all arguments) t)))
              (when (file-exists-p capture) (delete-file capture))
              (pcase-let ((`(,status . ,_output)
                           (run "buffer" "list" "--virtual" "--all")))
                (should (= status 2))
                (should-not (file-exists-p capture)))
              (let* ((path-request
                      (request "buffer" "read" "src/a b.el"
                               "--line" "02" "--end-line" "4"))
                     (arguments (alist-get 'arguments path-request)))
                (should (equal (alist-get 'operation path-request)
                               "buffer.read"))
                (should (equal (decoded-string (alist-get 'path arguments))
                               "src/a b.el"))
                (should (= (alist-get 'line arguments) 2))
                (should (= (alist-get 'end_line arguments) 4)))
              (let* ((name-request
                      (request "buffer" "read" "--name" "virtual ü"))
                     (arguments (alist-get 'arguments name-request)))
                (should (equal (decoded-string (alist-get 'name arguments))
                               "virtual ü")))
              (let ((direct (run "buffer" "list" "--help"))
                    (routed (run "help" "buffer" "list")))
                (should (= (car direct) 0))
                (should (equal direct routed))
                (should (string-match-p "Usage: limen buffer list" (cdr direct)))
                (should (string-match-p "--virtual" (cdr direct)))
                (should (string-match-p "--all" (cdr direct))))
              (let ((direct (run "buffer" "read" "--help"))
                    (routed (run "help" "buffer" "read")))
                (should (= (car direct) 0))
                (should (equal direct routed))
                (should (string-match-p "Usage: limen buffer read" (cdr direct)))
                (dolist (option '("--name" "--line" "--end-line"))
                  (should (string-match-p option (cdr direct))))))))
      (delete-directory directory t))))

(defun limen-tests--operation (name &optional context)
  (seq-find (lambda (entry) (equal (alist-get 'name entry) name))
            (limen-operations context)))

(ert-deftest limen-roadmap-core-schema-exposure-focus-and-diagnostics ()
  (limen-tests--with-registry
    (let* ((root (file-truename (make-temp-file "limen-roadmap-root" t)))
           (outside-root (file-truename
                          (make-temp-file "limen-roadmap-outside" t)))
           (file (expand-file-name "visible.el" root))
           (denied-file (expand-file-name "secret.el" root))
           (outside-file (expand-file-name "outside.el" outside-root))
           (context (limen-make-request :interface 'cli :project-root root
                                        :owner 'roadmap-owner
                                        :frame (selected-frame)
                                        :window (selected-window)))
           file-buffer denied-buffer outside-buffer virtual internal overlays)
      (unwind-protect
          (save-window-excursion
            (limen-register-operation
             "sample.batch"
             (lambda (arguments _context) (alist-get 'requests arguments))
             :parameters
             '((:name "requests" :type array :required t
                      :items (:type object
                              :properties
                              ((:name "action" :type string :required t
                                      :enum ("read" "write"))
                               (:name "targets" :type array :required t
                                      :items (:type string
                                              :enum ("buffer" "project"))))))))
            (let* ((descriptor (limen-tests--operation "sample.batch" context))
                   (requests (alist-get
                              'requests
                              (alist-get 'properties
                                         (alist-get 'input_schema descriptor))))
                   (item (alist-get 'items requests))
                   (properties (alist-get 'properties item)))
              (should (equal (alist-get 'type item) "object"))
              (should (equal (alist-get 'enum (alist-get 'action properties))
                             ["read" "write"]))
              (should (equal
                       (alist-get 'enum
                                  (alist-get 'items
                                             (alist-get 'targets properties)))
                       ["buffer" "project"]))
              (should (equal (append (alist-get 'required item) nil)
                             '("action" "targets"))))
            (should
             (equal
              (limen-call
               "sample.batch"
               '((requests . [((action . "read")
                                (targets . ["buffer" "project"]))]))
               context)
              [((action . "read") (targets . ["buffer" "project"]))]))
            (should-error
             (limen-call
              "sample.batch"
              '((requests . [((action . "delete")
                               (targets . ["buffer"]))]))
              context)
             :type 'limen-invalid-arguments)
            (should-error
             (limen-call
              "sample.batch"
              '((requests . [((action . "read")
                               (targets . ["buffer"])
                               (extra . t))]))
              context)
             :type 'limen-invalid-arguments)
            (should (boundp 'limen-readable-virtual-buffer-condition))
            (should-not limen-readable-virtual-buffer-condition)
            (should (boundp 'limen-project-path-deny-regexps))
            (with-temp-file file (insert "one\ntwo\nthree\n"))
            (with-temp-file denied-file (insert "secret\n"))
            (with-temp-file outside-file (insert "outside\n"))
            (setq file-buffer (find-file-noselect file)
                  denied-buffer (find-file-noselect denied-file)
                  outside-buffer (find-file-noselect outside-file)
                  virtual (generate-new-buffer "limen-roadmap-allowed")
                  internal (generate-new-buffer " limen-roadmap-internal"))
            (with-current-buffer virtual
              (setq default-directory (file-name-as-directory root))
              (emacs-lisp-mode)
              (insert "virtual text"))
            (with-current-buffer internal
              (setq default-directory (file-name-as-directory root))
              (insert "internal text"))
            (should
             (seq-find
              (lambda (record)
                (equal (alist-get 'name record) (buffer-name virtual)))
              (append (limen-call "buffer.list" '((virtual . t)) context)
                      nil)))
            (should-error
             (limen-call "buffer.read"
                         `((name . ,(buffer-name virtual))) context)
             :type 'limen-operation-failed)
            (dolist (condition '(t "allowed\\'" (derived-mode . prog-mode)))
              (let ((limen-readable-virtual-buffer-condition condition))
                (ert-info ((format "allow condition=%S" condition))
                  (should
                   (equal
                    (alist-get
                     'text
                     (limen-call
                      "buffer.read" `((name . ,(buffer-name virtual))) context))
                    "virtual text")))))
            (let ((limen-readable-virtual-buffer-condition t))
              (dolist (name (list (buffer-name outside-buffer)
                                  (buffer-name internal)))
                (should-error
                 (limen-call "buffer.read" `((name . ,name)) context)
                 :type 'limen-operation-failed)))
            (limen-call "buffer.open" '((path . "secret.el")) context)
            (let ((limen-project-path-deny-regexps
                   '("\\`secret\\.el\\'")))
              (should-not
               (seq-find
                (lambda (record)
                  (equal (alist-get 'file record) denied-file))
                (append (limen-call "buffer.list" nil context) nil)))
              (should-error
               (limen-call "buffer.read" '((path . "secret.el")) context)
               :type 'limen-operation-failed)
              (should-error
               (limen-call "buffer.open" '((path . "secret.el")) context)
               :type 'limen-operation-failed)
              (should (limen-release-owner 'roadmap-owner)))
            (let ((mcp-context
                   (limen-make-request :interface 'mcp :project-root root)))
              (should-not (limen-tests--operation "project.list" mcp-context))
              (should-error (limen-call "project.list" nil mcp-context)
                            :type 'limen-disabled-operation))
            (delete-other-windows)
            (set-window-buffer (selected-window) file-buffer)
            (with-current-buffer file-buffer
              (narrow-to-region 5 13)
              (goto-char 7)
              (push-mark 10 t t)
              (dotimes (index 130)
                (let ((overlay (make-overlay
                                (+ (point-min) (% index 4))
                                (1+ (+ (point-min) (% index 4)))
                                file-buffer)))
                  (overlay-put overlay 'invisible t)
                  (push overlay overlays))))
            (let (snapshot)
              (cl-letf (((symbol-function 'redisplay)
                         (lambda (&rest _arguments)
                           (ert-fail "focus.get forced redisplay"))))
                (setq snapshot (limen-call "focus.get" nil context)))
              (should (equal (alist-get 'kind snapshot) "file"))
              (should (integerp (alist-get 'tick snapshot)))
              (should (alist-get 'narrowing snapshot))
              (should (alist-get 'point snapshot))
              (should (alist-get 'selection snapshot))
              (should (alist-get 'viewport snapshot))
              (should (vectorp (alist-get 'invisible_spans snapshot)))
              (should (<= (length (alist-get 'invisible_spans snapshot)) 100)))
            (set-window-buffer (selected-window) outside-buffer)
            (should-not (alist-get 'focus
                                   (limen-call "focus.get" nil context)))
            (set-window-buffer (selected-window) virtual)
            (let* ((snapshot (limen-call "focus.get" nil context))
                   (expected
                    (with-current-buffer virtual
                      `((name . ,(buffer-name))
                        (file . ,buffer-file-name)
                        (kind . "virtual")
                        (major_mode . ,(symbol-name major-mode))
                        (modified . ,(if (buffer-modified-p) t :json-false))
                        (tick . ,(buffer-chars-modified-tick))
                        (narrowed . ,(if (buffer-narrowed-p) t :json-false))
                        (redacted . t)))))
              (dolist (entry expected)
                (should (equal (assq (car entry) snapshot) entry)))
              (dolist (field '(narrowing point selection viewport
                               invisible_spans truncated text))
                (should-not (assq field snapshot)))
              (should-not
               (string-match-p "virtual text" (prin1-to-string snapshot))))
            (let* ((other (flymake-make-diagnostic
                           outside-buffer 1 2 :warning "other"))
                   (wanted (flymake-make-diagnostic
                            file-buffer 5 6 :error "wanted"))
                   (uri (concat "file://" file)))
              (cl-letf (((symbol-function 'flymake-diagnostics)
                         (lambda (&rest _arguments)
                           (cond
                            ((eq (current-buffer) file-buffer)
                             (list wanted wanted))
                            ((eq (current-buffer) outside-buffer)
                             (list other))))))
                (let ((records
                       (append
                        (limen-call "diagnostic.list" `((uri . ,uri)) context)
                        nil)))
                  (should (= (length records) 1))
                  (should (equal (alist-get 'file (car records)) file))
                  (should (equal (alist-get 'source (car records)) "flymake"))))))
        (mapc #'delete-overlay overlays)
        (dolist (buffer (list file-buffer denied-buffer outside-buffer
                              virtual internal))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))
        (delete-directory root t)
        (delete-directory outside-root t)))))

(ert-deftest limen-core-authorization-is-stable-and-fails-closed ()
  (limen-tests--with-registry
    (let* ((root (file-truename (make-temp-file "limen-auth-root" t)))
           (outside-root (file-truename
                          (make-temp-file "limen-auth-outside" t)))
           (inside-directory (expand-file-name "inside" root))
           (outside-directory (expand-file-name "outside" outside-root))
           (link-directory (expand-file-name "redirect" root))
           (inside-file (expand-file-name "secret.el" inside-directory))
           (outside-file (expand-file-name "secret.el" outside-directory))
           (outside-target (expand-file-name "created.el" outside-root))
           (denied-directory (expand-file-name "blocked" root))
           (denied-target (expand-file-name "created.el" denied-directory))
           (context (limen-make-request :interface 'cli :project-root root))
           buffers observations)
      (unwind-protect
          (progn
            (make-directory inside-directory)
            (make-directory outside-directory)
            (make-directory denied-directory)
            (with-temp-file inside-file (insert "inside\n"))
            (with-temp-file outside-file (insert "outside secret\n"))
            (make-symbolic-link outside-directory link-directory)
            (let ((buffer (find-file-noselect
                           (expand-file-name "secret.el" link-directory))))
              (push buffer buffers)
              (should (file-equal-p
                       (buffer-local-value 'buffer-file-truename buffer)
                       outside-file))
              (delete-file link-directory)
              (make-symbolic-link inside-directory link-directory)
              (push
               (cons
                'retargeted-buffer-read
                (condition-case nil
                    (progn
                      (limen-call "buffer.read"
                                  `((name . ,(buffer-name buffer))) context)
                      nil)
                  (error t)))
               observations)
              (push
               (cons
                'retargeted-buffer-listed
                (and (seq-find
                      (lambda (record)
                        (equal (alist-get 'name record) (buffer-name buffer)))
                      (append (limen-call "buffer.list" nil context) nil))
                     t))
               observations)
              (let ((before (buffer-list))
                    record opened failed unauthorized-displayed)
                (save-window-excursion
                  (condition-case nil
                      (setq record
                            (limen-call "buffer.open"
                                        '((path . "redirect/secret.el"))
                                        context)
                            opened (get-buffer (alist-get 'buffer record)))
                    (error (setq failed t)))
                  (setq unauthorized-displayed
                        (and (get-buffer-window-list buffer nil 0) t)))
                (dolist (candidate (buffer-list))
                  (unless (memq candidate before)
                    (cl-pushnew candidate buffers :test #'eq)))
                (push
                 (cons
                  'retargeted-buffer-open-preserved-identity
                  (and (buffer-live-p buffer)
                       (stringp
                        (buffer-local-value 'buffer-file-truename buffer))
                       (file-equal-p
                        (buffer-local-value 'buffer-file-truename buffer)
                        outside-file)))
                 observations)
                (push
                 (cons 'retargeted-buffer-open-hidden
                       (not unauthorized-displayed))
                 observations)
                (push
                 (cons
                  'retargeted-buffer-open-outcome-safe
                  (or failed
                      (and (buffer-live-p opened)
                           (not (eq opened buffer))
                           (stringp (alist-get 'file record))
                           (file-equal-p (alist-get 'file record) inside-file)
                           (stringp
                            (buffer-local-value 'buffer-file-truename opened))
                           (file-equal-p
                            (buffer-local-value 'buffer-file-truename opened)
                            inside-file))))
                 observations)))
            (dolist (case `((outside ,(expand-file-name "outside-source.el" root)
                                    ,outside-target nil)
                            (denied ,(expand-file-name "denied-source.el" root)
                                   ,denied-target ("\\`blocked/"))))
              (pcase-let ((`(,label ,source ,target ,deny-regexps) case))
                (with-temp-file source (insert "before\n"))
                (let ((buffer (find-file-noselect source)))
                  (push buffer buffers)
                  (with-current-buffer buffer
                    (goto-char (point-max))
                    (insert "after\n")
                    (add-hook
                     'before-save-hook
                     (lambda ()
                       (setq buffer-file-name target
                             buffer-file-truename target))
                     nil t))
                  (let ((limen-project-path-deny-regexps deny-regexps)
                        (tick (with-current-buffer buffer
                                (buffer-chars-modified-tick))))
                    (push
                     (cons
                      (intern (format "%s-save" label))
                      (list
                       (condition-case nil
                           (progn
                             (limen-call
                              "buffer.save"
                              `((path . ,source) (expected_tick . ,tick))
                              context)
                             nil)
                         (error t))
                       (file-exists-p target)))
                     observations)))))
            (let ((rootless (limen-make-request :interface 'cli)))
              (dolist (operation '("window.list" "diagnostic.list"))
                (push
                 (cons
                  (intern operation)
                  (condition-case nil
                      (progn (limen-call operation nil rootless) nil)
                    (error t)))
                 observations)))
            (should
             (equal
              (nreverse observations)
              '((retargeted-buffer-read . t)
                (retargeted-buffer-listed)
                (retargeted-buffer-open-preserved-identity . t)
                (retargeted-buffer-open-hidden . t)
                (retargeted-buffer-open-outcome-safe . t)
                (outside-save t nil)
                (denied-save t nil)
                (window.list . t)
                (diagnostic.list . t)))))
        (dolist (buffer buffers)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))
        (delete-directory root t)
        (delete-directory outside-root t)))))

(ert-deftest limen-context-get-composes-registered-sections ()
  (limen-tests--with-registry
    (let* ((root (file-truename (make-temp-file "limen-context-root" t)))
           (file (expand-file-name "a.el" root))
           (context (limen-make-request :interface 'cli :project-root root
                                        :frame (selected-frame)
                                        :window (selected-window)))
           (limen-context-sections
            (append (seq-filter (lambda (section)
                                  (member (car section)
                                          '("project" "focus" "windows" "buffers")))
                                limen-context-sections)
                    (list (cons "sample" (lambda (_context) nil)))))
           buffer)
      (unwind-protect
          (save-window-excursion
            (with-temp-file file (insert "one\ntwo\n"))
            (setq buffer (find-file-noselect file))
            (set-window-buffer (selected-window) buffer)
            (let ((result (limen-call "context.get" nil context)))
              (should (equal (map-keys result)
                             '(project focus windows buffers)))
              (should (equal (alist-get 'root (alist-get 'project result)) root))
              (should (equal (alist-get 'focus result)
                             (limen-call "focus.get" nil context)))
              (should (equal (alist-get 'windows result)
                             (limen-call "window.list" nil context)))
              (should (equal (alist-get 'buffers result)
                             (limen-call "buffer.list" '((all . t)) context))))
            (should (equal (map-keys (limen-call "context.get"
                                                 '((sections . ["focus"]))
                                                 context))
                           '(focus)))
            (should-error (limen-call "context.get"
                                      '((sections . ["missing"])) context)
                          :type 'limen-invalid-arguments)
            (should-error (limen-call "context.get" '((sections . "focus"))
                                      context)
                          :type 'limen-invalid-arguments)
            (let ((operation (limen-tests--operation "context.get" context)))
              (should (equal (alist-get 'effect operation) "read"))
              (should (equal (alist-get 'type
                                        (alist-get 'sections
                                                   (alist-get 'properties
                                                              (alist-get 'input_schema
                                                                         operation))))
                             "array"))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory root t)))))

(ert-deftest limen-roadmap-cli-frames-focus-read-and-save ()
  (let* ((directory (make-temp-file "limen-roadmap-cli" t))
         (client (expand-file-name "emacsclient" directory))
         (capture (expand-file-name "expression" directory))
         (launcher (expand-file-name
                    "bin/limen"
                    (file-name-directory (locate-library "limen-tests"))))
         (payload "{\"version\":1,\"ok\":true,\"result\":{}}")
         (response (format "\"0:%s\"\n" (base64-encode-string payload t))))
    (unwind-protect
        (progn
          (with-temp-file client
            (insert "#!/bin/sh\nprintf '%s' \"$2\" > \"$LIMEN_CAPTURE\"\nprintf '%s' \"$LIMEN_RESPONSE\"\n"))
          (set-file-modes client #o700)
          (let ((process-environment
                 (append (list (concat "EMACSCLIENT=" client)
                               (concat "LIMEN_CAPTURE=" capture)
                               (concat "LIMEN_RESPONSE=" response))
                         process-environment)))
            (cl-labels
                ((run (&rest arguments)
                   (with-temp-buffer
                     (cons (apply #'process-file launcher nil t nil arguments)
                           (buffer-string))))
                 (request (&rest arguments)
                   (pcase-let ((`(,status . ,output) (apply #'run arguments)))
                     (should (= status 0))
                     (should (equal (string-trim output) payload)))
                   (with-temp-buffer
                     (insert-file-contents capture)
                     (should
                      (re-search-forward
                       "(limen-server-dispatch \\\"\\([A-Za-z0-9+/=]+\\)\\\")"
                       nil t))
                     (json-parse-string
                      (decode-coding-string
                       (base64-decode-string (match-string 1)) 'utf-8)
                      :object-type 'alist :false-object :json-false)))
                 (decoded-string (value)
                   (decode-coding-string
                    (base64-decode-string (alist-get 'base64 value)) 'utf-8)))
              (let ((focus (request "focus")))
                (should (equal (alist-get 'operation focus)
                               "focus.get")))
              (let ((whole (request "context")))
                (should (equal (alist-get 'operation whole) "context.get"))
                (should (equal (alist-get 'arguments whole) nil)))
              (let* ((partial (request "context" "--section" "focus"
                                       "--section" "trail"))
                     (arguments (alist-get 'arguments partial)))
                (should (equal (alist-get 'sections arguments)
                               ["focus" "trail"])))
              (let ((trail (request "trail")))
                (should (equal (alist-get 'operation trail) "trail.list"))
                (should (equal (alist-get 'arguments trail) nil)))
              (let* ((trail (request "trail" "--limit" "04"))
                     (arguments (alist-get 'arguments trail)))
                (should (= (alist-get 'limit arguments) 4)))
              (let ((sessions (request "annotations" "sessions")))
                (should (equal (alist-get 'operation sessions)
                               "annotation.sessions")))
              (let* ((listing (request "annotations" "list" "--session" "review"
                                       "--path" "src/a.el" "--limit" "3"))
                     (arguments (alist-get 'arguments listing)))
                (should (equal (alist-get 'operation listing) "annotation.list"))
                (should (equal (decoded-string (alist-get 'session arguments))
                               "review"))
                (should (equal (decoded-string (alist-get 'path arguments))
                               "src/a.el"))
                (should (= (alist-get 'limit arguments) 3)))
              (let* ((export (request "annotations" "export" "--session" "review"
                                      "--format" "diff"))
                     (arguments (alist-get 'arguments export)))
                (should (equal (alist-get 'operation export) "annotation.export"))
                (should (equal (decoded-string (alist-get 'session arguments))
                               "review"))
                (should (equal (alist-get 'format arguments) "diff")))
              (let* ((read (request "buffer" "read" "src/a.el"
                                    "--widen" "--expected-tick" "07"))
                     (arguments (alist-get 'arguments read)))
                (should (equal (decoded-string (alist-get 'path arguments))
                               "src/a.el"))
                (should (eq (alist-get 'widen arguments) t))
                (should (= (alist-get 'expected_tick arguments) 7)))
              (let* ((save (request "buffer" "save" "src/a.el"
                                    "--expected-tick" "9"))
                     (arguments (alist-get 'arguments save)))
                (should (equal (alist-get 'operation save) "buffer.save"))
                (should (equal (decoded-string (alist-get 'path arguments))
                               "src/a.el"))
                (should (= (alist-get 'expected_tick arguments) 9)))
              (dolist (arguments '(("buffer" "read" "src/a.el"
                                    "--expected-tick" "1x")
                                   ("buffer" "save" "src/a.el")
                                   ("focus" "extra")
                                   ("context" "--section" "Focus")
                                   ("context" "--section")
                                   ("trail" "--limit" "x")
                                   ("trail" "extra")
                                   ("annotations" "export" "--path" "x")
                                   ("annotations" "export" "--session" "r"
                                    "--format" "bogus")
                                   ("annotations" "list" "--limit" "x")
                                   ("annotations" "sessions" "extra")))
                (when (file-exists-p capture) (delete-file capture))
                (pcase-let ((`(,status . ,_output)
                             (apply #'run arguments)))
                  (should (= status 2))
                  (should-not (file-exists-p capture))))
              (dolist (command '(("focus" "--help")
                                  ("buffer" "save" "--help")))
                (pcase-let ((`(,status . ,output) (apply #'run command)))
                  (should (= status 0))
                  (should (string-match-p "expected-tick\\|focus" output)))))))
      (delete-directory directory t))))

(ert-deftest limen-launcher-hook-frames-the-payload-and-never-fails ()
  (let* ((directory (make-temp-file "limen-hook-cli" t))
         (client (expand-file-name "emacsclient" directory))
         (capture (expand-file-name "expression" directory))
         (payload-file (expand-file-name "payload.json" directory))
         (launcher (expand-file-name
                    "bin/limen"
                    (file-name-directory (locate-library "limen-tests"))))
         (payload "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}")
         (output "{\"hookSpecificOutput\":{\"additionalContext\":\"Emacs context\"}}")
         (response (format "\"0:%s\"\n" (base64-encode-string output t))))
    (unwind-protect
        (progn
          (with-temp-file payload-file (insert payload))
          (with-temp-file client
            (insert "#!/bin/sh\nprintf '%s' \"$2\" > \"$LIMEN_CAPTURE\"\n"
                    "[ -z \"$LIMEN_FAIL\" ] || exit 1\n"
                    "[ -z \"$LIMEN_SLOW\" ] || sleep 5\n"
                    "printf '%s' \"$LIMEN_RESPONSE\"\n"))
          (set-file-modes client #o700)
          (cl-labels
              ((run (environment &rest arguments)
                 (when (file-exists-p capture) (delete-file capture))
                 (let ((process-environment
                        (append environment
                                (list (concat "EMACSCLIENT=" client)
                                      (concat "LIMEN_CAPTURE=" capture)
                                      (concat "LIMEN_RESPONSE=" response)
                                      "LIMEN_SESSION" "HERDR_ENV" "LIMEN_FAIL"
                                      "LIMEN_SLOW" "HERDR_SOCKET_PATH" "HERDR_PANE_ID")
                                process-environment)))
                   (with-temp-buffer
                     (cons (apply #'process-file launcher payload-file t nil arguments)
                           (buffer-string)))))
               (captured ()
                 (with-temp-buffer
                   (insert-file-contents capture)
                   (should (re-search-forward
                            "(limen-server-dispatch \\\"\\([A-Za-z0-9+/=]+\\)\\\")"
                            nil t))
                   (should (string-match-p "(require 'limen-hooks nil t)"
                                           (buffer-string)))
                   (json-parse-string
                    (decode-coding-string
                     (base64-decode-string (match-string 1)) 'utf-8)
                    :object-type 'alist)))
               (decoded (value)
                 (decode-coding-string (base64-decode-string value) 'utf-8)))
            (pcase-let ((`(,status . ,text)
                         (run '("LIMEN_SESSION=limen-1") "hook" "claude")))
              (should (= status 0))
              (should (equal (string-trim text) output))
              (let ((request (captured)))
                (should (equal (alist-get 'method request) "hook"))
                (should (equal (alist-get 'provider request) "claude"))
                (should (equal (decoded (alist-get 'session_base64 request))
                               "limen-1"))
                (should (equal (decoded (alist-get 'payload_base64 request))
                               payload))
                (should (equal (decoded (alist-get 'server_base64 request)) ""))
                (should (equal (decoded (alist-get 'pane_base64 request)) ""))))
            (pcase-let ((`(,status . ,text)
                         (run '("HERDR_ENV=1" "HERDR_SOCKET_PATH=/tmp/h.sock"
                                "HERDR_PANE_ID=%7")
                              "hook" "codex")))
              (should (= status 0))
              (should (equal (string-trim text) output))
              (let ((request (captured)))
                (should (equal (decoded (alist-get 'session_base64 request)) ""))
                (should (equal (decoded (alist-get 'server_base64 request))
                               "/tmp/h.sock"))
                (should (equal (decoded (alist-get 'pane_base64 request)) "%7"))))
            (pcase-let ((`(,status . ,text) (run nil "hook" "claude")))
              (should (= status 0))
              (should (equal text ""))
              (should-not (file-exists-p capture)))
            (pcase-let ((`(,status . ,text)
                         (run '("LIMEN_SESSION=limen-1" "LIMEN_FAIL=1")
                              "hook" "claude")))
              (should (= status 0))
              (should (equal text "")))
            (let ((started (float-time)))
              (pcase-let ((`(,status . ,text)
                           (run '("LIMEN_SESSION=limen-1" "LIMEN_SLOW=1"
                                  "LIMEN_HOOK_TIMEOUT=1")
                                "hook" "claude")))
                (should (= status 0))
                (should (equal text ""))
                (should (< (- (float-time) started) 4))))
            (let ((response "*ERROR*: Cannot open load file: limen\n"))
              (pcase-let ((`(,status . ,text)
                           (run (list "LIMEN_SESSION=limen-1"
                                      (concat "LIMEN_RESPONSE=" response))
                                "hook" "claude")))
                (should (= status 0))
                (should (equal text "")))
              (pcase-let ((`(,status . ,text)
                           (let ((process-environment
                                  (append (list (concat "EMACSCLIENT=" client)
                                                (concat "LIMEN_CAPTURE=" capture)
                                                (concat "LIMEN_RESPONSE=" response))
                                          process-environment)))
                             (with-temp-buffer
                               (cons (process-file launcher nil '(t t) nil "focus")
                                     (buffer-string))))))
                (should (= status 5))
                (should (string-match-p "Emacs answered Cannot open load file"
                                        text))))
            (let ((response (format "\"3:%s\"\n"
                                    (base64-encode-string "{\"ok\":false}" t))))
              (pcase-let ((`(,status . ,text)
                           (run (list "LIMEN_SESSION=limen-1"
                                      (concat "LIMEN_RESPONSE=" response))
                                "hook" "claude")))
                (should (= status 0))
                (should (equal text ""))))
            (pcase-let ((`(,status . ,_) (run '("LIMEN_SESSION=limen-1")
                                              "hook" "cursor")))
              (should (= status 2)))
            (pcase-let ((`(,status . ,text) (run nil "hook" "--help")))
              (should (= status 0))
              (should (string-match-p "LIMEN_SESSION" text)))))
      (delete-directory directory t))))

(ert-deftest limen-buffer-open-preserves-retargeted-owned-buffer ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-identity-overwrite-root" t)))
           (file-a (expand-file-name "a.el" root))
           (file-b (expand-file-name "b.el" root))
           (owner (make-symbol "limen-identity-overwrite-owner"))
           (context (limen-make-request
                     :interface 'mcp :project-root root :owner owner))
           original replacement open-outcome observations)
      (unwind-protect
          (progn
            (with-temp-file file-a (insert "shared\n"))
            (save-window-excursion
              (let ((parking
                     (generate-new-buffer " limen identity overwrite parking")))
                (unwind-protect
                    (progn
                      (delete-other-windows)
                      (setq original
                            (get-buffer
                             (alist-get
                              'buffer
                              (limen-call
                               "buffer.open" '((path . "a.el")) context))))
                      (with-current-buffer original
                        (set-visited-file-name file-b t)
                        (save-buffer))
                      (cl-labels
                          ((owner-state ()
                             (let ((files (limen--owner-buffers owner))
                                   tracks-original tracks-replacement)
                               (when files
                                 (maphash
                                  (lambda (_identity record)
                                    (let ((tracked
                                           (limen--owned-buffer-buffer record)))
                                      (when (eq tracked original)
                                        (setq tracks-original t))
                                      (when (and replacement
                                                 (eq tracked replacement))
                                        (setq tracks-replacement t))))
                                  files))
                               (list (if files (hash-table-count files) 0)
                                     tracks-original tracks-replacement))))
                        (let ((identity-is-b
                               (equal (limen-buffer-file-identity original)
                                      (file-truename file-b)))
                              (unmodified
                               (not (buffer-modified-p original)))
                              (before-open (owner-state)))
                          (setq open-outcome
                                (condition-case nil
                                    (progn
                                      (setq replacement
                                            (get-buffer
                                             (alist-get
                                              'buffer
                                              (limen-call
                                               "buffer.open"
                                               '((path . "a.el"))
                                               context))))
                                      'opened)
                                  (limen-operation-failed 'rejected)))
                          (set-window-buffer (selected-window) parking)
                          (let* ((after-open (owner-state))
                                 (open-contract
                                  (pcase open-outcome
                                    ('opened
                                     (and (buffer-live-p original)
                                          (buffer-live-p replacement)
                                          (not (eq original replacement))
                                          (equal after-open '(2 t t))))
                                    ('rejected
                                     (and (buffer-live-p original)
                                          (not (buffer-live-p replacement))
                                          (null (get-file-buffer file-a))
                                          (equal after-open '(1 t nil))))))
                                 (open-evidence
                                  (if open-contract
                                      'valid
                                    (list open-outcome after-open
                                          (buffer-live-p original)
                                          (and (buffer-live-p replacement) t)
                                          (and (get-file-buffer file-a) t))))
                                 (released (limen-release-owner owner))
                                 (unregistered
                                  (null (limen--owner-buffers owner)))
                                 (original-disposed
                                  (not (buffer-live-p original)))
                                 (replacement-disposed
                                  (not (buffer-live-p replacement))))
                            (setq observations
                                  (list identity-is-b unmodified before-open
                                        open-evidence released unregistered
                                        original-disposed
                                        replacement-disposed))))))
                  (when (buffer-live-p parking)
                    (kill-buffer parking)))))
            (should
             (equal observations
                    '(t t (1 t nil) valid t t t t))))
        (limen-release-owner owner)
        (dolist (candidate (list original replacement
                                  (get-file-buffer file-a)
                                  (get-file-buffer file-b)))
          (when (buffer-live-p candidate)
            (with-current-buffer candidate (set-buffer-modified-p nil))
            (kill-buffer candidate)))
        (delete-directory root t)))))

(ert-deftest limen-buffer-open-and-release-coalesce-same-owner-retarget ()
  (limen-tests--with-registry
    (dolist (release-path '("a.el" "b.el"))
      (ert-info ((format "release-path=%s" release-path))
        (let* ((root (file-truename
                      (make-temp-file "limen-same-owner-retarget-root" t)))
               (file-a (expand-file-name "a.el" root))
               (file-b (expand-file-name "b.el" root))
               (owner (make-symbol "limen-same-owner-retarget-owner"))
               (context (limen-make-request
                         :interface 'mcp :project-root root :owner owner))
               buffer reopened parking)
          (unwind-protect
              (progn
                (with-temp-file file-a (insert "shared\n"))
                (with-temp-file file-b (insert "shared\n"))
                (save-window-excursion
                  (setq parking
                        (generate-new-buffer " limen same owner retarget parking"))
                  (delete-other-windows)
                  (setq buffer
                        (get-buffer
                         (alist-get
                          'buffer
                          (limen-call "buffer.open" '((path . "a.el"))
                                      context))))
                  (with-current-buffer buffer
                    (set-visited-file-name file-b t)
                    (set-buffer-modified-p nil))
                  (setq reopened
                        (get-buffer
                         (alist-get
                          'buffer
                          (limen-call "buffer.open" '((path . "b.el"))
                                      context))))
                  (set-window-buffer (selected-window) parking)
                  (let ((files (limen--owner-buffers owner)) records)
                    (maphash (lambda (_identity record)
                               (push record records))
                             files)
                    (should (eq reopened buffer))
                    (should (buffer-live-p buffer))
                    (should (= (length records) 1))
                    (let ((record (car records)))
                      (should (eq (limen--owned-buffer-buffer record) buffer))
                      (should (limen--owned-buffer-owned-p record))
                      (dolist (file (list file-a file-b))
                        (let ((entry (limen--owned-buffer-entry files file)))
                          (should entry)
                          (should (eq (cdr entry) record))))))
                  (should-not (buffer-modified-p buffer))
                  (should-not (get-buffer-window-list buffer nil 0))
                  (limen-call "buffer.release"
                              `((path . ,release-path)) context)
                  (should-not (limen--owner-buffers owner))
                  (should-not (buffer-live-p buffer))))
            (limen-release-owner owner)
            (dolist (candidate
                     (delete-dups
                      (list buffer reopened parking
                            (get-file-buffer file-a)
                            (get-file-buffer file-b))))
              (when (buffer-live-p candidate)
                (with-current-buffer candidate
                  (set-buffer-modified-p nil)
                  (setq-local kill-buffer-query-functions nil))
                (kill-buffer candidate)))
            (delete-directory root t)))))))

(ert-deftest limen-release-owner-transfers-cross-identity-buffer-ownership ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-cross-identity-root" t)))
           (file-a (expand-file-name "a.el" root))
           (file-b (expand-file-name "b.el" root))
           (owner-a (make-symbol "limen-cross-identity-owner-a"))
           (owner-b (make-symbol "limen-cross-identity-owner-b"))
           (context-a (limen-make-request
                       :interface 'mcp :project-root root :owner owner-a))
           (context-b (limen-make-request
                       :interface 'mcp :project-root root :owner owner-b))
           buffer opened-as-b observations)
      (unwind-protect
          (progn
            (with-temp-file file-a (insert "shared\n"))
            (save-window-excursion
              (let ((parking
                     (generate-new-buffer " limen cross identity parking")))
                (unwind-protect
                    (progn
                      (delete-other-windows)
                      (setq buffer
                            (get-buffer
                             (alist-get
                              'buffer
                              (limen-call
                               "buffer.open" '((path . "a.el"))
                               context-a))))
                      (with-current-buffer buffer
                        (set-visited-file-name file-b t)
                        (save-buffer))
                      (setq opened-as-b
                            (get-buffer
                             (alist-get
                              'buffer
                              (limen-call
                               "buffer.open" '((path . "b.el"))
                               context-b))))
                      (set-window-buffer (selected-window) parking)
                      (cl-labels
                          ((owner-state (owner)
                             (let ((files (limen--owner-buffers owner))
                                   tracks-live)
                               (when files
                                 (maphash
                                  (lambda (_identity record)
                                    (when (and
                                           (eq (limen--owned-buffer-buffer
                                                record)
                                               buffer)
                                           (buffer-live-p buffer))
                                      (setq tracks-live t)))
                                  files))
                               (and files
                                    (cons (hash-table-count files)
                                          tracks-live)))))
                        (let* ((same-buffer (eq opened-as-b buffer))
                               (identity-is-b
                                (equal (limen-buffer-file-identity buffer)
                                       (file-truename file-b)))
                               (unmodified (not (buffer-modified-p buffer)))
                               (a-before (owner-state owner-a))
                               (b-before (owner-state owner-b))
                               (released-a (limen-release-owner owner-a))
                               (a-unregistered
                                (null (limen--owner-buffers owner-a)))
                               (live-after-a (buffer-live-p buffer))
                               (b-after-a (owner-state owner-b))
                               (released-b (limen-release-owner owner-b))
                               (b-unregistered
                                (null (limen--owner-buffers owner-b)))
                               (disposed (not (buffer-live-p buffer))))
                          (setq observations
                                (list
                                 same-buffer identity-is-b unmodified
                                 a-before b-before released-a
                                 a-unregistered live-after-a b-after-a
                                 released-b b-unregistered disposed)))))
                  (when (buffer-live-p parking)
                    (kill-buffer parking)))))
            (should
             (equal observations
                    '(t t t (1 . t) (1 . t) t t t (1 . t) t t t))))
        (limen-release-owner owner-a)
        (limen-release-owner owner-b)
        (dolist (candidate (list buffer opened-as-b
                                  (get-file-buffer file-a)
                                  (get-file-buffer file-b)))
          (when (buffer-live-p candidate)
            (with-current-buffer candidate (set-buffer-modified-p nil))
            (kill-buffer candidate)))
        (delete-directory root t)))))

(ert-deftest limen-buffer-release-prefers-recorded-alias-after-retarget ()
  (limen-tests--with-registry
    (let (observations)
      (dolist (scenario '(current-b outside denied))
        (let* ((root (file-truename
                      (make-temp-file "limen-release-alias-root" t)))
               (outside-root
                (file-truename
                 (make-temp-file "limen-release-alias-outside" t)))
               (directory-a (expand-file-name "a" root))
               (directory-b (expand-file-name "b" root))
               (denied-directory (expand-file-name "denied" root))
               (outside-directory (expand-file-name "outside" outside-root))
               (alias (expand-file-name "alias" root))
               (file-a (expand-file-name "shared.el" directory-a))
               (file-b (expand-file-name "shared.el" directory-b))
               (owner (make-symbol "limen-alias-owner"))
               (context (limen-make-request
                         :interface 'mcp :project-root root :owner owner))
               (limen-project-path-deny-regexps
                (and (eq scenario 'denied) '("\\`denied/")))
               buffer-a buffer-b)
          (unwind-protect
              (progn
                (dolist (directory
                         (list directory-a directory-b denied-directory
                               outside-directory))
                  (make-directory directory))
                (with-temp-file file-a (insert "a\n"))
                (with-temp-file file-b (insert "b\n"))
                (with-temp-file
                    (expand-file-name "shared.el" denied-directory)
                  (insert "denied\n"))
                (with-temp-file
                    (expand-file-name "shared.el" outside-directory)
                  (insert "outside\n"))
                (make-symbolic-link directory-a alias)
                (save-window-excursion
                  (let ((parking
                         (generate-new-buffer " limen alias parking")))
                    (unwind-protect
                        (progn
                          (delete-other-windows)
                          (setq buffer-a
                                (get-buffer
                                 (alist-get
                                  'buffer
                                  (limen-call
                                   "buffer.open"
                                   '((path . "alias/shared.el")) context))))
                          (delete-file alias)
                          (make-symbolic-link
                           (pcase scenario
                             ('current-b directory-b)
                             ('outside outside-directory)
                             ('denied denied-directory))
                           alias)
                          (setq buffer-b
                                (get-buffer
                                 (alist-get
                                  'buffer
                                  (limen-call
                                   "buffer.open"
                                   '((path . "b/shared.el")) context))))
                          (set-window-buffer (selected-window) parking)
                          (cl-labels
                              ((owner-state ()
                                 (let ((files
                                        (limen--owner-buffers owner))
                                       tracks-a tracks-b)
                                   (when files
                                     (maphash
                                      (lambda (_identity record)
                                        (let ((tracked
                                               (limen--owned-buffer-buffer
                                                record)))
                                          (when (eq tracked buffer-a)
                                            (setq tracks-a t))
                                          (when (eq tracked buffer-b)
                                            (setq tracks-b t))))
                                      files))
                                   (list (if files
                                             (hash-table-count files)
                                           0)
                                         tracks-a tracks-b))))
                            (let* ((alias-release
                                    (condition-case nil
                                        (progn
                                          (limen-call
                                           "buffer.release"
                                           '((path . "alias/shared.el"))
                                           context)
                                          'released)
                                      (limen-operation-failed 'rejected)))
                                   (a-live (buffer-live-p buffer-a))
                                   (b-live (buffer-live-p buffer-b))
                                   (state (owner-state))
                                   (b-release
                                    (condition-case nil
                                        (progn
                                          (limen-call
                                           "buffer.release"
                                           '((path . "b/shared.el"))
                                           context)
                                          'released)
                                      (limen-operation-failed 'rejected))))
                              (push
                               (list scenario alias-release a-live b-live state
                                     b-release
                                     (null (limen--owner-buffers owner))
                                     (buffer-live-p buffer-a)
                                     (buffer-live-p buffer-b))
                               observations))))
                      (when (buffer-live-p parking)
                        (kill-buffer parking))))))
            (limen-release-owner owner)
            (dolist (buffer (list buffer-a buffer-b))
              (when (buffer-live-p buffer)
                (with-current-buffer buffer (set-buffer-modified-p nil))
                (kill-buffer buffer)))
            (delete-directory root t)
            (delete-directory outside-root t))))
      (should
       (equal
        (nreverse observations)
        '((current-b released nil t (1 nil t) released t nil nil)
          (outside released nil t (1 nil t) released t nil nil)
          (denied released nil t (1 nil t) released t nil nil)))))))

(ert-deftest limen-buffer-release-prefers-exact-recorded-alias-over-current-identity ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-release-exact-alias" t)))
           (directory-a (expand-file-name "a" root))
           (directory-b (expand-file-name "b" root))
           (alias-directory (expand-file-name "alias" root))
           (file-a (expand-file-name "x.el" directory-a))
           (file-b (expand-file-name "x.el" directory-b))
           (alias-file (expand-file-name "x.el" alias-directory))
           (owner (make-symbol "limen-release-exact-alias-owner"))
           (context (limen-make-request
                     :interface 'mcp :project-root root :owner owner))
           buffer-a buffer-b parking identity-a identity-b record-a record-b)
      (unwind-protect
          (progn
            (make-directory directory-a)
            (make-directory directory-b)
            (with-temp-file file-a (insert "a\n"))
            (with-temp-file file-b (insert "b\n"))
            (make-symbolic-link directory-a alias-directory)
            (save-window-excursion
              (setq parking
                    (generate-new-buffer " limen release exact alias parking"))
              (delete-other-windows)
              (setq buffer-b
                    (get-buffer
                     (alist-get
                      'buffer
                      (limen-call "buffer.open" '((path . "b/x.el"))
                                  context))))
              (setq buffer-a
                    (get-buffer
                     (alist-get
                      'buffer
                      (limen-call "buffer.open" '((path . "alias/x.el"))
                                  context))))
              (set-window-buffer (selected-window) parking)
              (let ((files (limen--owner-buffers owner)))
                (setq identity-a (file-truename file-a)
                      identity-b (file-truename file-b)
                      record-a (gethash identity-a files)
                      record-b (gethash identity-b files))
                (should (= (hash-table-count files) 2))
                (should-not (eq buffer-a buffer-b))
                (should (and record-a record-b (not (eq record-a record-b))))
                (should (eq (limen--owned-buffer-buffer record-a) buffer-a))
                (should (eq (limen--owned-buffer-buffer record-b) buffer-b))
                (should (limen--owned-buffer-owned-p record-a))
                (should (limen--owned-buffer-owned-p record-b))
                (should (equal (limen--owned-buffer-paths record-a)
                               (list alias-file)))
                (should (equal (limen--owned-buffer-paths record-b)
                               (list file-b)))
                (dolist (buffer (list buffer-a buffer-b))
                  (should (buffer-live-p buffer))
                  (should-not (buffer-modified-p buffer))
                  (should-not (get-buffer-window-list buffer nil 0)))
                (delete-file alias-directory)
                (make-symbolic-link directory-b alias-directory)
                (should (file-equal-p alias-file file-b))
                (should (equal (limen-call "buffer.release"
                                           '((path . "alias/x.el")) context)
                               "Released buffer"))
                (let ((remaining (limen--owner-buffers owner)))
                  (should (eq remaining files))
                  (should (= (hash-table-count remaining) 1))
                  (should
                   (equal
                    (list (buffer-live-p buffer-a)
                          (buffer-live-p buffer-b)
                          (eq (gethash identity-a remaining) record-a)
                          (eq (gethash identity-b remaining) record-b))
                    '(nil t nil t))))
                (should (equal (limen-call "buffer.release"
                                           '((path . "b/x.el")) context)
                               "Released buffer"))
                (should-not (limen--owner-buffers owner))
                (should-not (buffer-live-p buffer-b)))))
        (limen-release-owner owner)
        (dolist (candidate
                 (delete-dups
                  (list buffer-a buffer-b parking
                        (get-file-buffer file-a)
                        (get-file-buffer file-b))))
          (when (buffer-live-p candidate)
            (with-current-buffer candidate
              (set-buffer-modified-p nil)
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer candidate)))
        (delete-directory root t)))))

(ert-deftest limen-buffer-release-finds-case-variant-alias-after-retarget ()
  (limen-tests--with-registry
    (let* ((sandbox (file-truename
                     (make-temp-file "limen-case-alias-retarget" t)))
           (root (expand-file-name "CaseRoot" sandbox))
           (variant-root (expand-file-name "caseroot" sandbox))
           (inside-directory (expand-file-name "inside" root))
           (outside-directory (expand-file-name "outside" sandbox))
           (alias (expand-file-name "alias" root))
           (inside-file (expand-file-name "shared.el" inside-directory))
           (outside-file (expand-file-name "shared.el" outside-directory))
           (variant-alias-file
            (expand-file-name "alias/shared.el" variant-root))
           (owner (make-symbol "limen-case-alias-retarget-owner"))
           (context (limen-make-request
                     :interface 'mcp :project-root root :owner owner))
           buffer parking)
      (unwind-protect
          (progn
            (make-directory inside-directory t)
            (make-directory outside-directory)
            (unless (and (not (equal root variant-root))
                         (condition-case nil
                             (file-equal-p root variant-root)
                           (file-error nil)))
              (ert-skip "Filesystem does not equate case-variant roots"))
            (with-temp-file inside-file (insert "inside\n"))
            (with-temp-file outside-file (insert "outside\n"))
            (make-symbolic-link inside-directory alias)
            (save-window-excursion
              (setq parking
                    (generate-new-buffer " limen case alias retarget parking"))
              (delete-other-windows)
              (setq buffer
                    (get-buffer
                     (alist-get
                      'buffer
                      (limen-call "buffer.open"
                                  `((path . ,variant-alias-file)) context))))
              (set-window-buffer (selected-window) parking)
              (let* ((files (limen--owner-buffers owner))
                     (entry (limen--recorded-buffer-entry
                             files variant-alias-file))
                     (record (cdr entry)))
                (should (and record
                             (eq (limen--owned-buffer-buffer record) buffer)
                             (limen--owned-buffer-owned-p record))))
              (should-not (buffer-modified-p buffer))
              (should-not (get-buffer-window-list buffer nil 0))
              (delete-file alias)
              (make-symbolic-link outside-directory alias)
              (let ((outcome
                     (condition-case nil
                         (progn
                           (limen-call "buffer.release"
                                       `((path . ,variant-alias-file)) context)
                           'released)
                       (limen-operation-failed 'rejected))))
                (should
                 (equal (list outcome
                              (null (limen--owner-buffers owner))
                              (not (buffer-live-p buffer)))
                        '(released t t))))))
        (limen-release-owner owner)
        (dolist (candidate (list buffer parking
                                 (get-file-buffer inside-file)
                                 (get-file-buffer outside-file)))
          (when (buffer-live-p candidate)
            (with-current-buffer candidate
              (set-buffer-modified-p nil)
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer candidate)))
        (delete-directory sandbox t)))))

(ert-deftest limen-buffer-open-does-not-transfer-stale-ownership ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-stale-ownership-root" t)))
           (positive-file (expand-file-name "positive.el" root))
           (file (expand-file-name "shared.el" root))
           (positive-owner (make-symbol "limen-positive-owner"))
           (owner (make-symbol "limen-stale-owner"))
           (positive-context
            (limen-make-request
             :interface 'mcp :project-root root :owner positive-owner))
           (context (limen-make-request
                     :interface 'mcp :project-root root :owner owner))
           created reopened owned external replacement
           positive-observations replacement-observations)
      (unwind-protect
          (progn
            (with-temp-file positive-file (insert "positive\n"))
            (with-temp-file file (insert "shared\n"))
            (save-window-excursion
              (let ((parking
                     (generate-new-buffer " limen stale ownership parking")))
                (unwind-protect
                    (progn
                      (delete-other-windows)
                      (setq created
                            (get-buffer
                             (alist-get
                              'buffer
                              (limen-call
                               "buffer.open" '((path . "positive.el"))
                               positive-context)))
                            reopened
                            (get-buffer
                             (alist-get
                              'buffer
                              (limen-call
                               "buffer.open" '((path . "positive.el"))
                               positive-context))))
                      (set-window-buffer (selected-window) parking)
                      (let ((release
                             (condition-case nil
                                 (progn
                                   (limen-call
                                    "buffer.release"
                                    '((path . "positive.el"))
                                    positive-context)
                                   'released)
                               (limen-operation-failed 'rejected))))
                        (setq positive-observations
                              (list (eq reopened created)
                                    release
                                    (null (limen--owner-buffers
                                           positive-owner))
                                    (not (buffer-live-p created)))))
                      (setq owned
                            (get-buffer
                             (alist-get
                              'buffer
                              (limen-call
                               "buffer.open" '((path . "shared.el"))
                               context))))
                      (set-window-buffer (selected-window) parking)
                      (kill-buffer owned)
                      (setq external (find-file-noselect file)
                            replacement
                            (get-buffer
                             (alist-get
                              'buffer
                              (limen-call
                               "buffer.open" '((path . "shared.el"))
                               context))))
                      (set-window-buffer (selected-window) parking)
                      (let ((files (limen--owner-buffers owner))
                            tracks-replacement)
                        (when files
                          (maphash
                           (lambda (_identity record)
                             (when (eq (limen--owned-buffer-buffer record)
                                       external)
                               (setq tracks-replacement t)))
                           files))
                        (setq replacement-observations
                              (list
                               (eq replacement external)
                               (list (if files (hash-table-count files) 0)
                                     tracks-replacement)
                               (condition-case nil
                                   (progn
                                     (limen-call
                                      "buffer.release"
                                      '((path . "shared.el")) context)
                                     'released)
                                 (limen-operation-failed 'rejected))
                               (null (limen--owner-buffers owner))
                               (buffer-live-p external))))
                      (when (buffer-live-p external)
                        (kill-buffer external))
                      (setq replacement-observations
                            (append replacement-observations
                                    (list (not (buffer-live-p external))))))
                  (when (buffer-live-p parking)
                    (kill-buffer parking)))))
            (should
             (equal
              (list positive-observations replacement-observations)
              '((t released t t)
                (t (1 t) released t t t)))))
        (limen-release-owner positive-owner)
        (limen-release-owner owner)
        (dolist (buffer (list created reopened owned external replacement
                               (get-file-buffer positive-file)
                               (get-file-buffer file)))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))
        (delete-directory root t)))))

(ert-deftest limen-canonical-path-boundary-rejects-remotes-and-shares-buffer-ownership ()
  (limen-tests--with-registry
    (let ((limen--sessions (make-hash-table :test #'eq))
          (limen-session-open-hook nil)
          (remote-root "/ssh:limen.invalid:/project")
          remote-canonicalized session-outcome remote-root-confined
          expanded-remote-confined shared-buffer survived
          owner-a-unregistered owner-b-tracks-live
          owner-b-unregistered disposed root file buffer second-buffer)
      (unwind-protect
          (progn
            (let ((original-file-truename
                   (symbol-function 'file-truename)))
              (cl-letf (((symbol-function 'file-truename)
                         (lambda (path)
                           (if (file-remote-p path)
                               (progn
                                 (setq remote-canonicalized t)
                                 path)
                             (funcall original-file-truename path)))))
                (setq session-outcome
                      (condition-case condition
                          (progn
                            (limen-open-session
                             :provider 'test :project-root remote-root)
                            'opened)
                        (limen-operation-failed 'rejected)
                        (error (list 'unexpected (car condition)))))))
            (setq root (file-truename
                        (make-temp-file "limen-owned-identity-root" t)))
            (let* ((child (expand-file-name "child.el" root))
                   (remote-directory (expand-file-name "remote" root))
                   (remote-child
                    (expand-file-name "child.el" remote-directory))
                   (synthetic-tramp-prefix "/ssh:limen.invalid:"))
              (make-directory remote-directory)
              (with-temp-file child (insert "child\n"))
              (with-temp-file remote-child (insert "remote child\n"))
              (cl-labels
                  ((synthetic-remote-p (path base)
                     (when (and (stringp path)
                                (file-name-absolute-p path))
                       (let ((normalized-path (expand-file-name path))
                             (normalized-base
                              (directory-file-name
                               (expand-file-name base))))
                         (when (or (equal (directory-file-name
                                          normalized-path)
                                         normalized-base)
                                   (string-prefix-p
                                    (file-name-as-directory normalized-base)
                                    normalized-path))
                           synthetic-tramp-prefix)))))
                (let ((original-file-remote-p
                       (symbol-function 'file-remote-p)))
                  (cl-letf (((symbol-function 'file-remote-p)
                             (lambda (path &rest arguments)
                               (or (synthetic-remote-p path root)
                                   (apply original-file-remote-p
                                          path arguments)))))
                    (setq remote-root-confined
                          (and (limen--project-file-confined-p
                                "child.el" root)
                               t))))
                (let ((original-file-remote-p
                       (symbol-function 'file-remote-p)))
                  (cl-letf (((symbol-function 'file-remote-p)
                             (lambda (path &rest arguments)
                               (or (synthetic-remote-p
                                    path remote-directory)
                                   (apply original-file-remote-p
                                          path arguments)))))
                    (setq expanded-remote-confined
                          (and (limen--project-file-confined-p
                                "remote/child.el" root)
                               t))))))
            (let* ((directory (expand-file-name "actual" root))
                   (alias (expand-file-name "alias" root))
                   (owner-a (make-symbol "limen-owner-a"))
                   (owner-b (make-symbol "limen-owner-b"))
                   (context-a (limen-make-request
                               :interface 'cli :project-root root
                               :owner owner-a))
                   (context-b (limen-make-request
                               :interface 'cli :project-root root
                               :owner owner-b)))
              (make-directory directory)
              (setq file (expand-file-name "shared.el" directory))
              (with-temp-file file (insert "shared\n"))
              (make-symbolic-link directory alias)
              (save-window-excursion
                (let ((parking (generate-new-buffer
                                " limen ownership parking")))
                  (unwind-protect
                      (progn
                        (delete-other-windows)
                        (setq buffer
                              (get-buffer
                               (alist-get
                                'buffer
                                (limen-call
                                 "buffer.open"
                                 '((path . "actual/shared.el"))
                                 context-a))))
                        (setq second-buffer
                              (get-buffer
                               (alist-get
                                'buffer
                                (limen-call
                                 "buffer.open"
                                 '((path . "alias/shared.el"))
                                 context-b))))
                        (setq shared-buffer (eq buffer second-buffer))
                        (set-window-buffer (selected-window) parking)
                        (limen-release-owner owner-a)
                        (setq survived (buffer-live-p buffer)
                              owner-a-unregistered
                              (null (limen--owner-buffers owner-a)))
                        (let ((files (limen--owner-buffers owner-b))
                              tracked)
                          (when files
                            (maphash
                             (lambda (_identity record)
                               (when (and
                                      (eq (limen--owned-buffer-buffer record)
                                          buffer)
                                      (buffer-live-p
                                       (limen--owned-buffer-buffer record)))
                                 (setq tracked t)))
                             files))
                          (setq owner-b-tracks-live tracked))
                        (limen-release-owner owner-b)
                        (setq owner-b-unregistered
                              (null (limen--owner-buffers owner-b))
                              disposed (not (buffer-live-p buffer))))
                    (when (buffer-live-p parking)
                      (kill-buffer parking))))))
            (should
             (equal
              (list session-outcome remote-canonicalized
                    remote-root-confined expanded-remote-confined
                    shared-buffer survived owner-a-unregistered
                    owner-b-tracks-live owner-b-unregistered disposed)
              '(rejected nil nil nil t t t t t t))))
        (dolist (candidate (list buffer second-buffer
                                 (and file (get-file-buffer file))))
          (when (buffer-live-p candidate)
            (with-current-buffer candidate (set-buffer-modified-p nil))
            (kill-buffer candidate)))
        (when (and root (file-directory-p root))
          (delete-directory root t))))))

(ert-deftest limen-launcher-buffer-open-rejects-duplicate-options-locally ()
  (let* ((directory (make-temp-file "limen-open-duplicates" t))
         (client (expand-file-name "emacsclient" directory))
         (capture (expand-file-name "expression" directory))
         (launcher (expand-file-name
                    "bin/limen"
                    (file-name-directory (locate-library "limen-tests"))))
         (payload "{\"version\":1,\"ok\":true,\"result\":{}}")
         (response (format "\"0:%s\"\n" (base64-encode-string payload t)))
         observations)
    (unwind-protect
        (progn
          (with-temp-file client
            (insert "#!/bin/sh\nprintf '%s' called > \"$LIMEN_CAPTURE\"\nprintf '%s' \"$LIMEN_RESPONSE\"\n"))
          (set-file-modes client #o700)
          (let ((process-environment
                 (append (list (concat "EMACSCLIENT=" client)
                               (concat "LIMEN_CAPTURE=" capture)
                               (concat "LIMEN_RESPONSE=" response))
                         process-environment)))
            (dolist (case '(("--line" "1" "2")
                            ("--column" "0" "3")
                            ("--end-line" "4" "5")
                            ("--start-text" "first" "second")
                            ("--end-text" "first" "second")))
              (when (file-exists-p capture) (delete-file capture))
              (pcase-let ((`(,option ,first ,second) case))
                (let ((status
                       (with-temp-buffer
                         (apply #'process-file launcher nil t nil
                                (list "buffer" "open" "inside.el"
                                      option first option second)))))
                  (push (list option status
                              (and (file-exists-p capture) t))
                        observations))))
            (should
             (equal
              (nreverse observations)
              '(("--line" 2 nil)
                ("--column" 2 nil)
                ("--end-line" 2 nil)
                ("--start-text" 2 nil)
                ("--end-text" 2 nil))))))
      (delete-directory directory t))))

(defun limen-tests--equivalent-file-ownership-observations
    (root primary alternate)
  (let* ((owner (make-symbol "limen-equivalent-file-owner"))
         (context (limen-make-request
                   :interface 'mcp :project-root root :owner owner))
         primary-buffer alternate-buffer)
    (unwind-protect
        (save-window-excursion
          (let ((parking
                 (generate-new-buffer " limen equivalent file parking")))
            (unwind-protect
                (progn
                  (delete-other-windows)
                  (setq primary-buffer
                        (get-buffer
                         (alist-get
                          'buffer
                          (limen-call
                           "buffer.open"
                           `((path . ,(file-relative-name primary root)))
                           context))))
                  (let ((open
                         (condition-case condition
                             (progn
                               (setq alternate-buffer
                                     (get-buffer
                                      (alist-get
                                       'buffer
                                       (limen-call
                                        "buffer.open"
                                        `((path . ,(file-relative-name
                                                    alternate root)))
                                        context))))
                               'succeeded)
                           (limen-operation-failed
                            (cons 'rejected (cdr condition))))))
                    (set-window-buffer (selected-window) parking)
                    (let* ((files (limen--owner-buffers owner))
                           (ownership-count
                            (if files (hash-table-count files) 0))
                           record
                           (primary-live (buffer-live-p primary-buffer))
                           (same-buffer
                            (and primary-live
                                 (eq primary-buffer alternate-buffer)))
                           (hidden
                            (and primary-live
                                 (null (get-buffer-window-list
                                        primary-buffer nil 0))))
                           (unmodified
                            (and primary-live
                                 (with-current-buffer primary-buffer
                                   (not (buffer-modified-p))))))
                      (when files
                        (maphash (lambda (_identity candidate)
                                   (setq record candidate))
                                 files))
                      (let ((ownership-connected
                             (and (= ownership-count 1)
                                  (eq (limen--owned-buffer-buffer record)
                                      primary-buffer)
                                  (limen--owned-buffer-owned-p record)))
                            (release
                             (condition-case condition
                                 (progn
                                   (limen-call
                                    "buffer.release"
                                    `((path . ,(file-relative-name
                                                alternate root)))
                                    context)
                                   'succeeded)
                               (limen-operation-failed
                                (cons 'rejected (cdr condition))))))
                        `((open . ,open)
                          (same_buffer . ,(and same-buffer t))
                          (ownership_count . ,ownership-count)
                          (ownership_connected . ,(and ownership-connected t))
                          (hidden . ,(and hidden t))
                          (unmodified . ,(and unmodified t))
                          (release . ,release)
                          (tracking_removed
                           . ,(null (limen--owner-buffers owner)))
                          (disposed
                           . ,(and same-buffer
                                   (not (buffer-live-p primary-buffer))
                                   (not (buffer-live-p alternate-buffer)))))))))
              (when (buffer-live-p parking)
                (kill-buffer parking)))))
      (limen-release-owner owner)
      (dolist (buffer (list primary-buffer alternate-buffer
                            (get-file-buffer primary)
                            (get-file-buffer alternate)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest limen-buffer-open-and-release-share-case-variant-file-ownership ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-case-ownership-root" t)))
           (primary (expand-file-name "OwnershipCase.el" root))
           (alternate (expand-file-name "ownershipcase.el" root)))
      (unwind-protect
          (progn
            (with-temp-file primary (insert "shared\n"))
            (unless (file-equal-p primary alternate)
              (ert-skip "Filesystem does not equate case-variant paths"))
            (should
             (equal
              (limen-tests--equivalent-file-ownership-observations
               root primary alternate)
              '((open . succeeded)
                (same_buffer . t)
                (ownership_count . 1)
                (ownership_connected . t)
                (hidden . t)
                (unmodified . t)
                (release . succeeded)
                (tracking_removed . t)
                (disposed . t)))))
        (delete-directory root t)))))

(ert-deftest limen-buffer-open-and-release-share-hard-link-file-ownership ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-hard-link-ownership-root" t)))
           (primary (expand-file-name "primary.el" root))
           (alternate (expand-file-name "alias.el" root)))
      (unwind-protect
          (progn
            (with-temp-file primary (insert "shared\n"))
            (add-name-to-file primary alternate)
            (should
             (equal
              (limen-tests--equivalent-file-ownership-observations
               root primary alternate)
              '((open . succeeded)
                (same_buffer . t)
                (ownership_count . 1)
                (ownership_connected . t)
                (hidden . t)
                (unmodified . t)
                (release . succeeded)
                (tracking_removed . t)
                (disposed . t)))))
        (delete-directory root t)))))

(ert-deftest limen-buffer-save-rejects-atomic-replacement-with-restored-modtime ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-save-atomic-replacement" t)))
           (file (expand-file-name "visited.el" root))
           (owner (make-symbol "limen-save-atomic-replacement-owner"))
           (context (limen-make-request
                     :interface 'mcp :project-root root :owner owner))
           (initial "original\n")
           (baseline "baseline\n")
           (external "external\n")
           (modified "modified\n")
           (timestamp (seconds-to-time 1577836800))
           (make-backup-files nil)
           (create-lockfiles nil)
           replacement buffer parking observations)
      (unwind-protect
          (progn
            (should-not (equal initial baseline))
            (should-not (equal baseline external))
            (should (= (string-bytes baseline) (string-bytes external)))
            (with-temp-file file (insert initial))
            (set-file-times file timestamp)
            (save-window-excursion
              (setq parking
                    (generate-new-buffer " limen atomic replacement parking"))
              (delete-other-windows)
              (setq buffer
                    (get-buffer
                     (alist-get
                      'buffer
                      (limen-call "buffer.open" '((path . "visited.el"))
                                  context))))
              (set-window-buffer (selected-window) parking)
              (let* ((baseline-tick
                      (with-current-buffer buffer
                        (erase-buffer)
                        (insert baseline)
                        (buffer-chars-modified-tick)))
                     (saved
                      (limen-call
                       "buffer.save"
                       `((path . "visited.el")
                         (expected_tick . ,baseline-tick))
                       context)))
                (should (equal (alist-get 'file saved) file))
                (should (eq (alist-get 'modified saved) :json-false))
                (should
                 (equal
                  (with-temp-buffer
                    (insert-file-contents-literally file)
                    (buffer-string))
                  baseline)))
              (let* ((original-attributes (file-attributes file))
                     (original-identifier
                      (file-attribute-file-identifier original-attributes))
                     (original-size
                      (file-attribute-size original-attributes))
                     (original-modtime
                      (file-attribute-modification-time original-attributes))
                     (visited-identifier
                      (with-current-buffer buffer buffer-file-number))
                     (tick
                      (with-current-buffer buffer
                        (erase-buffer)
                        (insert modified)
                        (buffer-chars-modified-tick)))
                     (files-before (limen--owner-buffers owner))
                     entry-before record-before paths-before window-before)
                (unless (and visited-identifier original-identifier
                             (equal visited-identifier original-identifier))
                  (ert-skip
                   "Filesystem does not expose stable visited-file identifiers"))
                (should (hash-table-p files-before))
                (should (= (hash-table-count files-before) 1))
                (setq entry-before
                      (limen--recorded-buffer-entry files-before file)
                      record-before (cdr entry-before)
                      paths-before
                      (copy-sequence (limen--owned-buffer-paths record-before))
                      window-before (limen--owned-buffer-window record-before))
                (should entry-before)
                (should (eq (limen--owned-buffer-buffer record-before) buffer))
                (should (limen--owned-buffer-owned-p record-before))
                (setq replacement
                      (make-temp-file
                       (expand-file-name ".limen-replacement-" root)))
                (with-temp-file replacement (insert external))
                (rename-file replacement file t)
                (setq replacement nil)
                (set-file-times file original-modtime)
                (let* ((current-attributes (file-attributes file))
                       (current-identifier
                        (file-attribute-file-identifier current-attributes))
                       (current-size
                        (file-attribute-size current-attributes))
                       (current-modtime
                        (file-attribute-modification-time current-attributes)))
                  (should (= original-size current-size))
                  (unless (and current-identifier
                               (not (equal visited-identifier
                                           current-identifier))
                               (time-equal-p original-modtime current-modtime)
                               (verify-visited-file-modtime buffer))
                    (ert-skip
                     "Filesystem cannot establish atomic replacement preconditions"))
                  (should-not (equal visited-identifier current-identifier))
                  (should (time-equal-p original-modtime current-modtime))
                  (should (verify-visited-file-modtime buffer)))
                (let* ((outcome
                        (condition-case condition
                            (progn
                              (limen-call
                               "buffer.save"
                               `((path . "visited.el")
                                 (expected_tick . ,tick))
                               context)
                              'saved)
                          (limen-conflict (car condition))
                          (error
                           (list 'unexpected-condition (car condition)))))
                       (disk-contents
                        (with-temp-buffer
                          (insert-file-contents-literally file)
                          (buffer-string)))
                       (identifier-preserved
                        (with-current-buffer buffer
                          (equal buffer-file-number visited-identifier)))
                       (buffer-modified
                        (with-current-buffer buffer (buffer-modified-p)))
                       (buffer-contents
                        (with-current-buffer buffer (buffer-string)))
                       (files-after (limen--owner-buffers owner))
                       (entry-after
                        (and files-after
                             (limen--recorded-buffer-entry files-after file)))
                       (record-after (cdr entry-after))
                       (ownership-preserved
                        (and (eq files-after files-before)
                             (= (hash-table-count files-after) 1)
                             (equal (car entry-after) (car entry-before))
                             (eq record-after record-before)
                             (eq (limen--owned-buffer-buffer record-after) buffer)
                             (eq (limen--owned-buffer-window record-after)
                                 window-before)
                             (eq (limen--owned-buffer-owned-p record-after) t)
                             (equal (limen--owned-buffer-paths record-after)
                                    paths-before))))
                  (setq observations
                        `((outcome . ,outcome)
                          (disk_contents . ,disk-contents)
                          (buffer_identifier_preserved
                           . ,(and identifier-preserved t))
                          (buffer_modified . ,(and buffer-modified t))
                          (buffer_contents . ,buffer-contents)
                          (ownership_preserved
                           . ,(and ownership-preserved t))))
                  (let ((released (limen-release-owner owner)))
                    (setq observations
                          (append
                           observations
                           `((owner_released . ,released)
                             (tracking_removed
                              . ,(null (limen--owner-buffers owner)))
                             (modified_buffer_survived_release
                              . ,(and (buffer-live-p buffer) t)))))))))
            (should
             (equal
              observations
              '((outcome . limen-conflict)
                (disk_contents . "external\n")
                (buffer_identifier_preserved . t)
                (buffer_modified . t)
                (buffer_contents . "modified\n")
                (ownership_preserved . t)
                (owner_released . t)
                (tracking_removed . t)
                (modified_buffer_survived_release . t)))))
        (limen-release-owner owner)
        (dolist (candidate
                 (delete-dups
                  (list buffer parking (get-file-buffer file))))
          (when (buffer-live-p candidate)
            (with-current-buffer candidate
              (set-buffer-modified-p nil)
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer candidate)))
        (when (and replacement (file-exists-p replacement))
          (delete-file replacement))
        (delete-directory root t)))))

(ert-deftest limen-buffer-save-rejects-after-save-atomic-replacement ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-save-after-save-replacement" t)))
           (file (expand-file-name "visited.el" root))
           (owner (make-symbol "limen-save-after-save-replacement-owner"))
           (context (limen-make-request
                     :interface 'mcp :project-root root :owner owner))
           (initial "original\n")
           (modified "modified\n")
           (external "external\n")
           (make-backup-files nil)
           (create-lockfiles nil)
           (hook-count 0)
           replacement buffer parking hook-error
           saved-contents saved-identifier recorded-saved-identifier
           current-identifier saved-size current-size
           saved-modtime current-modtime modtime-verified observations)
      (unwind-protect
          (progn
            (should-not (equal modified external))
            (should (= (string-bytes modified) (string-bytes external)))
            (with-temp-file file (insert initial))
            (save-window-excursion
              (setq parking
                    (generate-new-buffer
                     " limen after-save replacement parking"))
              (delete-other-windows)
              (setq buffer
                    (get-buffer
                     (alist-get
                      'buffer
                      (limen-call "buffer.open" '((path . "visited.el"))
                                  context))))
              (set-window-buffer (selected-window) parking)
              (let ((tick
                     (with-current-buffer buffer
                       (erase-buffer)
                       (insert modified)
                       (add-hook
                        'after-save-hook
                        (lambda ()
                          (cl-incf hook-count)
                          (when (= hook-count 1)
                            (condition-case condition
                                (let ((attributes (file-attributes file)))
                                  (setq saved-contents
                                        (with-temp-buffer
                                          (insert-file-contents-literally file)
                                          (buffer-string))
                                        saved-identifier
                                        (file-attribute-file-identifier
                                         attributes)
                                        recorded-saved-identifier
                                        buffer-file-number
                                        saved-size
                                        (file-attribute-size attributes)
                                        saved-modtime
                                        (file-attribute-modification-time
                                         attributes)
                                        replacement
                                        (make-temp-file
                                         (expand-file-name
                                          ".limen-after-save-replacement-"
                                          root)))
                                  (with-temp-file replacement (insert external))
                                  (rename-file replacement file t)
                                  (setq replacement nil)
                                  (set-file-times file saved-modtime)
                                  (let ((current-attributes
                                         (file-attributes file)))
                                    (setq current-identifier
                                          (file-attribute-file-identifier
                                           current-attributes)
                                          current-size
                                          (file-attribute-size
                                           current-attributes)
                                          current-modtime
                                          (file-attribute-modification-time
                                           current-attributes)
                                          modtime-verified
                                          (verify-visited-file-modtime buffer))))
                              (file-error
                               (setq hook-error condition)))))
                        nil t)
                       (buffer-chars-modified-tick)))
                    (files-before (limen--owner-buffers owner))
                    entry-before record-before paths-before window-before)
                (should (hash-table-p files-before))
                (should (= (hash-table-count files-before) 1))
                (setq entry-before
                      (limen--recorded-buffer-entry files-before file))
                (should entry-before)
                (setq record-before (cdr entry-before)
                      paths-before
                      (copy-sequence (limen--owned-buffer-paths record-before))
                      window-before (limen--owned-buffer-window record-before))
                (should (eq (limen--owned-buffer-buffer record-before) buffer))
                (should (limen--owned-buffer-owned-p record-before))
                (let ((outcome
                       (condition-case condition
                           (progn
                             (limen-call
                              "buffer.save"
                              `((path . "visited.el")
                                (expected_tick . ,tick))
                              context)
                             'saved)
                         (limen-conflict (car condition))
                         (error
                          (list 'unexpected-condition (car condition))))))
                  (when hook-error
                    (ert-skip
                     (format "Filesystem could not replace after save: %S"
                             hook-error)))
                  (should (= hook-count 1))
                  (should (equal saved-contents modified))
                  (should (= saved-size current-size))
                  (unless (and saved-identifier recorded-saved-identifier
                               current-identifier
                               (equal saved-identifier
                                      recorded-saved-identifier)
                               (not (equal saved-identifier current-identifier))
                               (time-equal-p saved-modtime current-modtime)
                               modtime-verified)
                    (ert-skip
                     "Filesystem cannot establish after-save replacement preconditions"))
                  (should (equal saved-identifier recorded-saved-identifier))
                  (should-not (equal saved-identifier current-identifier))
                  (should (time-equal-p saved-modtime current-modtime))
                  (should modtime-verified)
                  (let* ((disk-contents
                          (with-temp-buffer
                            (insert-file-contents-literally file)
                            (buffer-string)))
                         (buffer-contents
                          (with-current-buffer buffer (buffer-string)))
                         (files-after (limen--owner-buffers owner))
                         (entry-after
                          (and files-after
                               (limen--recorded-buffer-entry files-after file)))
                         (record-after (cdr entry-after))
                         (ownership-preserved
                          (and (eq files-after files-before)
                               (= (hash-table-count files-after) 1)
                               (equal (car entry-after) (car entry-before))
                               (eq record-after record-before)
                               (eq (limen--owned-buffer-buffer record-after)
                                   buffer)
                               (eq (limen--owned-buffer-window record-after)
                                   window-before)
                               (eq (limen--owned-buffer-owned-p record-after) t)
                               (equal
                                (limen--owned-buffer-paths record-after)
                                paths-before))))
                    (setq observations
                          `((outcome . ,outcome)
                            (hook_count . ,hook-count)
                            (disk_contents . ,disk-contents)
                            (buffer_contents . ,buffer-contents)
                            (ownership_preserved
                             . ,(and ownership-preserved t))))
                    (let ((released (limen-release-owner owner)))
                      (setq observations
                            (append
                             observations
                             `((owner_released . ,released)
                               (tracking_removed
                                . ,(null (limen--owner-buffers owner)))
                               (disk_after_release
                                . ,(with-temp-buffer
                                     (insert-file-contents-literally file)
                                     (buffer-string))))))))))
              (should
               (equal
                observations
                '((outcome . limen-conflict)
                  (hook_count . 1)
                  (disk_contents . "external\n")
                  (buffer_contents . "modified\n")
                  (ownership_preserved . t)
                  (owner_released . t)
                  (tracking_removed . t)
                  (disk_after_release . "external\n"))))))
        (limen-release-owner owner)
        (dolist (candidate
                 (delete-dups
                  (list buffer parking (get-file-buffer file))))
          (when (buffer-live-p candidate)
            (with-current-buffer candidate
              (set-buffer-modified-p nil)
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer candidate)))
        (when (and replacement (file-exists-p replacement))
          (delete-file replacement))
        (delete-directory root t)))))

(ert-deftest limen-buffer-save-rejects-disallowed-hard-link-retargets ()
  (limen-tests--with-registry
    (let* ((sandbox (file-truename
                     (make-temp-file "limen-save-hard-link" t)))
           (root (expand-file-name "project" sandbox))
           (outside-root (expand-file-name "outside" sandbox))
           (blocked-directory (expand-file-name "blocked" root))
           (limen-project-path-deny-regexps '("\\`blocked/"))
           (make-backup-files nil)
           buffers owners observations)
      (unwind-protect
          (save-window-excursion
            (make-directory blocked-directory t)
            (make-directory outside-root t)
            (cl-labels
                ((contents (file)
                   (with-temp-buffer
                     (insert-file-contents-literally file)
                     (buffer-string)))
                 (ownership-state (owner buffer)
                   (let ((files (limen--owner-buffers owner)) key record)
                     (when files
                       (maphash
                        (lambda (candidate-key candidate-record)
                          (setq key candidate-key
                                record candidate-record))
                        files))
                     (list (if files (hash-table-count files) 0)
                           key
                           (and record
                                (eq (limen--owned-buffer-buffer record)
                                    buffer))
                           (and record
                                (limen--owned-buffer-owned-p record))
                           (and record
                                (copy-sequence
                                 (limen--owned-buffer-paths record)))))))
              (dolist (case `((outside-name
                               ,outside-root buffer-file-name)
                              (outside-truename
                               ,outside-root buffer-file-truename)
                              (denied-name
                               ,blocked-directory buffer-file-name)
                              (denied-truename
                               ,blocked-directory buffer-file-truename)))
                (pcase-let
                    ((`(,label ,destination-directory ,retargeted-variable)
                      case))
                  (let* ((source
                          (expand-file-name
                           (format "%s-source.el" label) root))
                         (destination
                          (expand-file-name
                           (format "%s-alias.el" label)
                           destination-directory))
                         (owner (make-symbol
                                 (format "limen-save-hard-link-%s-owner"
                                         label)))
                         (context (limen-make-request
                                   :interface 'mcp :project-root root
                                   :owner owner))
                         (before (format "before %s\n" label))
                         (after (format "after %s\n" label))
                         buffer hook-state)
                    (push owner owners)
                    (with-temp-file source (insert before))
                    (add-name-to-file source destination)
                    (setq buffer
                          (get-buffer
                           (alist-get
                            'buffer
                            (limen-call
                             "buffer.open"
                             `((path . ,(file-relative-name source root)))
                             context))))
                    (push buffer buffers)
                    (with-current-buffer buffer
                      (erase-buffer)
                      (insert after)
                      (add-hook
                       'before-save-hook
                       (lambda ()
                         (set retargeted-variable destination)
                         (setq hook-state
                               (list buffer-file-name
                                     buffer-file-truename)))
                       nil t))
                    (let* ((ownership-before
                            (ownership-state owner buffer))
                           (tick (with-current-buffer buffer
                                   (buffer-chars-modified-tick)))
                           (outcome
                            (condition-case nil
                                (let* ((result
                                        (limen-call
                                         "buffer.save"
                                         `((path . ,(file-relative-name
                                                     source root))
                                           (expected_tick . ,tick))
                                         context))
                                       (returned (alist-get 'file result)))
                                  (cond
                                   ((equal returned destination)
                                    'returned-disallowed-destination)
                                   ((equal returned source)
                                    'returned-safe-source)
                                   (t (list 'returned-other returned))))
                              (limen-operation-failed 'rejected)
                              (error 'unexpected-error)))
                           (ownership-after
                            (ownership-state owner buffer))
                           (buffer-state
                            (with-current-buffer buffer
                              (list buffer-file-name
                                    buffer-file-truename
                                    (buffer-modified-p)
                                    (buffer-string))))
                           (released (limen-release-owner owner)))
                      (push
                       `((case . ,label)
                         (source . ,source)
                         (destination . ,destination)
                         (retargeted_variable . ,retargeted-variable)
                         (before . ,before)
                         (after . ,after)
                         (outcome . ,outcome)
                         (hook_state . ,hook-state)
                         (destination_contents . ,(contents destination))
                         (buffer_state . ,buffer-state)
                         (ownership_before . ,ownership-before)
                         (ownership_after . ,ownership-after)
                         (owner_released . ,released)
                         (tracking_removed
                          . ,(null (limen--owner-buffers owner)))
                         (buffer_live . ,(and (buffer-live-p buffer) t)))
                       observations))))))
            (setq observations (nreverse observations))
            (should
             (equal (mapcar (lambda (observation)
                              (alist-get 'outcome observation))
                            observations)
                    '(rejected rejected rejected rejected)))
            (dolist (observation observations)
              (let* ((label (alist-get 'case observation))
                     (source (alist-get 'source observation))
                     (destination (alist-get 'destination observation))
                     (retargeted-variable
                      (alist-get 'retargeted_variable observation))
                     (before (alist-get 'before observation))
                     (after (alist-get 'after observation))
                     (ownership-before
                      (alist-get 'ownership_before observation))
                     (ownership-after
                      (alist-get 'ownership_after observation)))
                (ert-info ((format "case=%s" label))
                  (should
                   (equal
                    (alist-get 'hook_state observation)
                    (list (if (eq retargeted-variable 'buffer-file-name)
                              destination
                            source)
                          (if (eq retargeted-variable
                                  'buffer-file-truename)
                              destination
                            source))))
                  (should
                   (equal (alist-get 'destination_contents observation)
                          before))
                  (should
                   (equal (alist-get 'buffer_state observation)
                          (list source source t after)))
                  (should
                   (equal ownership-before
                          (list 1 source t t (list source))))
                  (should (equal ownership-after ownership-before))
                  (should (equal (nth 1 ownership-after) source))
                  (should (eq (nth 3 ownership-after) t))
                  (should (equal (nth 4 ownership-after) (list source)))
                  (should-not (member destination
                                      (nth 4 ownership-after)))
                  (should (alist-get 'owner_released observation))
                  (should (alist-get 'tracking_removed observation))
                  (should (alist-get 'buffer_live observation))))))
        (dolist (owner owners)
          (limen-release-owner owner))
        (dolist (buffer buffers)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (set-buffer-modified-p nil)
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer buffer)))
        (delete-directory sandbox t)))))

(ert-deftest limen-buffer-open-disposes-vetoing-provisional-but-preserves-existing ()
  (limen-tests--with-registry
    (let* ((sandbox (file-truename
                     (make-temp-file "limen-open-veto-retarget" t)))
           (root (expand-file-name "project" sandbox))
           (outside-root (expand-file-name "outside" sandbox))
           (inside-file (expand-file-name "inside.el" root))
           buffers owners observations)
      (unwind-protect
          (progn
            (make-directory root)
            (make-directory outside-root)
            (with-temp-file inside-file (insert "inside\n"))
            (dolist (scenario '(provisional existing))
              (let* ((outside-file
                      (expand-file-name (format "%s.el" scenario)
                                        outside-root))
                     (owner (make-symbol
                             (format "limen-open-veto-%s-owner" scenario)))
                     (context (limen-make-request
                               :interface 'mcp :project-root root
                               :owner owner))
                     user-buffer opened requested outcome)
                (push owner owners)
                (with-temp-file outside-file (insert "outside\n"))
                (when (eq scenario 'existing)
                  (setq user-buffer (find-file-noselect outside-file)
                        opened user-buffer)
                  (push user-buffer buffers)
                  (with-current-buffer user-buffer
                    (add-hook 'kill-buffer-query-functions
                              (lambda () nil) nil t)))
                (let ((original-find-file-noselect
                       (symbol-function 'find-file-noselect)))
                  (cl-letf
                      (((symbol-function 'find-file-noselect)
                        (lambda (file &rest arguments)
                          (setq requested file)
                          (if (eq scenario 'existing)
                              user-buffer
                            (let ((candidate
                                   (apply original-find-file-noselect
                                          file arguments)))
                              (setq opened candidate)
                              (push candidate buffers)
                              (with-current-buffer candidate
                                (set-visited-file-name outside-file t)
                                (set-buffer-modified-p nil)
                                (add-hook 'kill-buffer-query-functions
                                          (lambda () nil) nil t))
                              candidate)))))
                    (setq outcome
                          (condition-case nil
                              (progn
                                (limen-call "buffer.open"
                                            '((path . "inside.el")) context)
                                'opened)
                            (limen-operation-failed 'rejected)))))
                (push
                 (pcase scenario
                   ('provisional
                    (list scenario
                          (and (stringp requested)
                               (file-equal-p requested inside-file))
                          outcome
                          (null (limen--owner-buffers owner))
                          (not (buffer-live-p opened))
                          (null (get-file-buffer outside-file))))
                   ('existing
                    (list scenario
                          (and (stringp requested)
                               (file-equal-p requested inside-file))
                          outcome
                          (null (limen--owner-buffers owner))
                          (eq opened user-buffer)
                          (buffer-live-p user-buffer)
                          (eq (get-file-buffer outside-file) user-buffer))))
                 observations)))
            (should
             (equal
              (nreverse observations)
              '((provisional t rejected t t t)
                (existing t rejected t t t t)))))
        (dolist (owner owners)
          (limen-release-owner owner))
        (dolist (buffer buffers)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (set-buffer-modified-p nil)
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer buffer)))
        (delete-directory sandbox t)))))

(ert-deftest limen-buffer-open-rejects-retargeted-outside-buffers-and-disposes-only-new ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-open-retarget-root" t)))
           (outside-root (file-truename
                          (make-temp-file "limen-open-retarget-outside" t)))
           (inside-file (expand-file-name "inside.el" root))
           buffers owners observations)
      (unwind-protect
          (progn
            (with-temp-file inside-file (insert "inside\n"))
            (dolist (scenario '(new live))
              (let* ((outside-file
                      (expand-file-name (format "%s-outside.el" scenario)
                                        outside-root))
                     (owner (make-symbol
                             (format "limen-open-retarget-%s-owner" scenario)))
                     (context (limen-make-request
                               :interface 'mcp :project-root root
                               :owner owner))
                     user-buffer opened requested outcome)
                (push owner owners)
                (with-temp-file outside-file (insert "outside\n"))
                (when (eq scenario 'live)
                  (setq user-buffer (find-file-noselect outside-file))
                  (push user-buffer buffers))
                (let ((original-find-file-noselect
                       (symbol-function 'find-file-noselect)))
                  (cl-letf (((symbol-function 'find-file-noselect)
                             (lambda (file &rest arguments)
                               (setq requested file)
                               (let ((buffer
                                      (apply original-find-file-noselect
                                             outside-file arguments)))
                                 (when (eq scenario 'new)
                                   (push buffer buffers))
                                 (setq opened buffer)))))
                    (setq outcome
                          (condition-case nil
                              (progn
                                (limen-call
                                 "buffer.open" '((path . "inside.el"))
                                 context)
                                'opened)
                            (limen-operation-failed 'rejected)))))
                (push
                 (pcase scenario
                   ('new
                    (list scenario
                          (and (stringp requested)
                               (file-equal-p requested inside-file))
                          outcome
                          (not (buffer-live-p opened))
                          (null (get-file-buffer outside-file))
                          (null (limen--owner-buffers owner))))
                   ('live
                    (list scenario
                          (and (stringp requested)
                               (file-equal-p requested inside-file))
                          outcome
                          (eq opened user-buffer)
                          (buffer-live-p user-buffer)
                          (eq (get-file-buffer outside-file) user-buffer)
                          (null (limen--owner-buffers owner)))))
                 observations)))
            (should
             (equal
              (nreverse observations)
              '((new t rejected t t t)
                (live t rejected t t t t)))))
        (dolist (owner owners)
          (limen-release-owner owner))
        (push (get-file-buffer inside-file) buffers)
        (dolist (buffer buffers)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (set-buffer-modified-p nil)
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer buffer)))
        (delete-directory root t)
        (delete-directory outside-root t)))))

(ert-deftest limen-release-owner-disposes-owned-buffer-despite-kill-query-veto ()
  (limen-tests--with-registry
    (let* ((root (file-truename
                  (make-temp-file "limen-release-veto-root" t)))
           (file (expand-file-name "owned.el" root))
           (owner (make-symbol "limen-release-veto-owner"))
           (context (limen-make-request
                     :interface 'mcp :project-root root :owner owner))
           buffer parking observations)
      (unwind-protect
          (progn
            (with-temp-file file (insert "owned\n"))
            (save-window-excursion
              (setq parking (generate-new-buffer " limen release veto parking"))
              (delete-other-windows)
              (setq buffer
                    (get-buffer
                     (alist-get
                      'buffer
                      (limen-call "buffer.open" '((path . "owned.el"))
                                  context))))
              (set-window-buffer (selected-window) parking)
              (with-current-buffer buffer
                (should-not (buffer-modified-p))
                (add-hook 'kill-buffer-query-functions (lambda () nil) nil t))
              (should-not (get-buffer-window-list buffer nil 0))
              (let* ((files (limen--owner-buffers owner))
                     (entry (and files
                                 (limen--owned-buffer-entry files file)))
                     (record (cdr entry)))
                (should (and record
                             (eq (limen--owned-buffer-buffer record) buffer)
                             (limen--owned-buffer-owned-p record))))
              (setq observations
                    (list (limen-release-owner owner)
                          (null (limen--owner-buffers owner))
                          (not (buffer-live-p buffer)))))
            (should (equal observations '(t t t))))
        (limen-release-owner owner)
        (dolist (candidate (list buffer parking (get-file-buffer file)))
          (when (buffer-live-p candidate)
            (with-current-buffer candidate
              (set-buffer-modified-p nil)
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer candidate)))
        (delete-directory root t)))))

(provide 'limen-tests)
;;; limen-tests.el ends here

(ert-deftest limen-focus-and-windows-follow-the-session-when-unconfined ()
  (let* ((root (file-truename (make-temp-file "limen-confine-root" t)))
         (other (file-truename (make-temp-file "limen-confine-other" t)))
         (here (expand-file-name "here.el" root))
         (away (expand-file-name "away.el" other))
         (context (limen-make-request :interface 'cli :project-root root))
         buffers)
    (unwind-protect
        (save-window-excursion
          (dolist (file (list here away))
            (with-temp-file file (insert "alpha\nbeta\n")))
          (setq buffers (mapcar #'find-file-noselect (list here away)))
          (delete-other-windows)
          (set-window-buffer (selected-window) (cadr buffers))
          (set-window-buffer (split-window) (car buffers))
          (with-current-buffer (cadr buffers)
            (goto-char (point-min))
            (push-mark 5 t t))
          (let ((limen-confine-to-project t))
            (should-not (limen-call "focus.get" nil context))
            (should (equal (mapcar (lambda (w) (alist-get 'file w))
                                   (append (limen-call "window.list" nil context) nil))
                           (list here))))
          (let ((limen-confine-to-project nil))
            (let ((focus (limen-call "focus.get" nil context)))
              (should (equal (alist-get 'file focus) away))
              (should (equal (alist-get 'project focus) (limen--project-root other)))
              (should (equal (alist-get 'text (alist-get 'selection focus)) "alph")))
            (let ((windows (append (limen-call "window.list" nil context) nil)))
              (should (equal (sort (mapcar (lambda (w) (alist-get 'file w)) windows)
                                   #'string<)
                             (sort (list here away) #'string<)))
              (should (equal (alist-get 'project
                                        (seq-find (lambda (w) (equal (alist-get 'file w) away))
                                                  windows))
                             (limen--project-root other))))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory root t)
      (delete-directory other t))))

(define-derived-mode limen-tests-terminal-mode fundamental-mode "LimenTerm")

(ert-deftest limen-focus-looks-past-the-agent-terminal ()
  (let* ((root (file-truename (make-temp-file "limen-terminal-root" t)))
         (file (expand-file-name "edited.el" root))
         (context (limen-make-request :interface 'cli :project-root root))
         (terminal (generate-new-buffer "limen-terminal"))
         (limen-focus-terminal-modes '(limen-tests-terminal-mode))
         buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file (insert "one\ntwo\nthree\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer terminal
            (limen-tests-terminal-mode)
            (setq default-directory (file-name-as-directory root)))
          (delete-other-windows)
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer (goto-char (point-min)) (forward-line 2))
          (let ((other (split-window)))
            (set-window-buffer other terminal)
            (select-window other)
            (let ((focus (limen-call "focus.get" nil context)))
              (should (equal (alist-get 'file focus) file))
              (should (= (alist-get 'line (alist-get 'point focus)) 3)))
            (let ((limen-focus-terminal-modes nil))
              (should (equal (alist-get 'name (limen-call "focus.get" nil context))
                             "limen-terminal")))
            (delete-other-windows other)
            (should (equal (alist-get 'name (limen-call "focus.get" nil context))
                           "limen-terminal"))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (kill-buffer terminal)
      (delete-directory root t))))
