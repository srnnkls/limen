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
                            :interface 'adapter :project-root root
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
    (let ((skill (limen-skill (limen-make-request :interface 'cli))))
      (should (string-match-p "limen --help" skill))
      (should (string-match-p "sample\\.lookup" skill))
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

(ert-deftest limen-roadmap-core-schema-exposure-attention-and-diagnostics ()
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
            (should (boundp 'limen-virtual-buffer-read-allow-condition))
            (should-not limen-virtual-buffer-read-allow-condition)
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
              (let ((limen-virtual-buffer-read-allow-condition condition))
                (ert-info ((format "allow condition=%S" condition))
                  (should
                   (equal
                    (alist-get
                     'text
                     (limen-call
                      "buffer.read" `((name . ,(buffer-name virtual))) context))
                    "virtual text")))))
            (let ((limen-virtual-buffer-read-allow-condition t))
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
                           (ert-fail "attention.get forced redisplay"))))
                (setq snapshot (limen-call "attention.get" nil context)))
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
                                   (limen-call "attention.get" nil context)))
            (set-window-buffer (selected-window) virtual)
            (let* ((snapshot (limen-call "attention.get" nil context))
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

(ert-deftest limen-roadmap-cli-frames-attention-read-and-save ()
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
              (let ((attention (request "attention")))
                (should (equal (alist-get 'operation attention)
                               "attention.get")))
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
                                   ("attention" "extra")))
                (when (file-exists-p capture) (delete-file capture))
                (pcase-let ((`(,status . ,_output)
                             (apply #'run arguments)))
                  (should (= status 2))
                  (should-not (file-exists-p capture))))
              (dolist (command '(("attention" "--help")
                                  ("buffer" "save" "--help")))
                (pcase-let ((`(,status . ,output) (apply #'run command)))
                  (should (= status 0))
                  (should (string-match-p "expected-tick\\|attention" output)))))))
      (delete-directory directory t))))

(provide 'limen-tests)
;;; limen-tests.el ends here
