;;; seance-gptel-test.el --- ERT tests for the gptel transport  -*- lexical-binding: t; -*-

;;; Commentary:
;; gptel is a soft dependency, so mostly what's worth checking is that the file
;; loads without it and then refuses to run, rather than calling void functions
;; at you. Nothing here issues a request.

;;; Code:

(require 'ert)
(require 'seance)
(require 'seance-gptel)
;; the M-x sweep below covers both transports, so don't lean on the Makefile
;; happening to load seance-claude-test.el first
(require 'seance-claude)

(ert-deftest seance-gptel-loads-without-gptel ()
  ;; the whole point of the soft (require 'gptel nil t)
  (should (featurep 'seance-gptel)))

(ert-deftest seance-gptel-refuses-without-gptel ()
  (skip-unless (not (featurep 'gptel)))
  (should-error (seance-gptel--require) :type 'user-error))

(ert-deftest seance-gptel-chat-refuses-without-gptel ()
  (skip-unless (not (featurep 'gptel)))
  (should-error (seance-gptel) :type 'user-error))

(ert-deftest seance-gptel-backend-setup-refuses-without-gptel ()
  (skip-unless (not (featurep 'gptel)))
  (should-error (seance-gptel-use-openai-compatible "local" "localhost:8080" 'a-model)
                :type 'user-error))

;;; Reachable from M-x, which the docs have always claimed

(ert-deftest seance-gptel-backend-setup-is-a-command ()
  (should (commandp 'seance-gptel-use-openai-compatible)))

(ert-deftest seance-commands-are-all-reachable-from-m-x ()
  (dolist (cmd '(seance-clear-log
                 seance-install
                 seance-uninstall
                 seance-preview-context
                 seance-claude
                 seance-claude-send
                 seance-gptel
                 seance-gptel-send
                 seance-gptel-use-openai-compatible))
    (should (fboundp cmd))
    (should (commandp cmd))))

;;; Profile: this backend inherits, because it usually points at small models

(ert-deftest seance-gptel-profile-inherits-by-default ()
  (should (null (default-value 'seance-gptel-profile))))

(ert-deftest seance-gptel-inherited-profile-resolves-to-lean ()
  (let ((seance-gptel-profile nil)
        (seance-profile :lean))
    (should (eq :lean (or seance-gptel-profile seance-profile)))))

(ert-deftest seance-gptel-profile-can-override-the-global-default ()
  (let ((seance-gptel-profile :full)
        (seance-profile :lean))
    (should (eq :full (or seance-gptel-profile seance-profile)))))

(provide 'seance-gptel-test)
;;; seance-gptel-test.el ends here
