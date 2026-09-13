;; -*- mode: eask; lexical-binding: t -*-

(package "limen"
         "0.1.0"
         "Emacs interface for agents")

(website-url "https://github.com/srnnkls/limen")
(license "GPL-3.0-or-later")

(keywords "tools" "processes")

(package-file "limen.el")

(source 'gnu)
(source 'nongnu)
(source 'melpa)

(depends-on "emacs" "29.1")
(depends-on "websocket" "1.12")
(depends-on "transient" "0.9.0")

(development
 (depends-on "magit-section" "4.0.0"))

(load-paths ".")

(files "limen*.el" "bin/limen" "license"
       '("extensions/limen-pi"
         "extensions/limen-pi/index.ts"
         "extensions/limen-pi/runtime.mjs")
       '(:exclude "limen*-tests.el"))

(defconst limen-test-file-spec
  '("limen*-tests.el")
  "File spec for ERT suites excluded from the package files.")

(script "test"
        (let* ((default-directory (file-name-directory load-file-name))
               (files (eask-expand-file-specs limen-test-file-spec)))
          (unless files
            (error "No test file matches %S under %s"
                   limen-test-file-spec default-directory))
          (mapconcat #'identity
                     (cons "eask test ert"
                           (mapcar #'shell-quote-argument files))
                     " ")))

(script "test-pi-extension"
        "node --test extensions/limen-pi/runtime.test.mjs")

(add-hook 'eask-before-compile-hook
          (lambda ()
            (setq byte-compile-error-on-warn t)))
