;;; seance-claude-test.el --- ERT tests for the claude CLI transport  -*- lexical-binding: t; -*-

;;; Commentary:
;; Argument construction and session ids. Nothing here spawns the subprocess --
;; that wants a logged-in `claude' CLI, and it costs tokens.

;;; Code:

(require 'ert)
(require 'seance)
(require 'seance-claude)

;;; CLI argument construction

(ert-deftest seance-claude-base-args-are-streaming-json ()
  (let ((seance-claude-lean nil)
        (seance-claude-model nil)
        (seance-claude-extra-args nil))
    (let ((args (seance-claude--base-args nil)))
      (should (member "-p" args))
      (should (member "--output-format" args))
      (should (member "stream-json" args)))))

(ert-deftest seance-claude-base-args-honor-lean-model-and-extras ()
  (let ((seance-claude-lean t)
        (seance-claude-model "some-model")
        (seance-claude-extra-args '("--disallowed-tools" "Bash")))
    (let ((args (seance-claude--base-args '("--resume" "id"))))
      (should (member "--setting-sources" args))
      (should (member "some-model" args))
      (should (member "--disallowed-tools" args))
      ;; EXTRA lands last so it can override
      (should (equal '("--resume" "id") (last args 2))))))

(ert-deftest seance-claude-base-args-omit-model-when-nil ()
  (let ((seance-claude-lean nil)
        (seance-claude-model nil)
        (seance-claude-extra-args nil))
    (should-not (member "--model" (seance-claude--base-args nil)))))

(ert-deftest seance-claude-base-args-omit-lean-flags-when-disabled ()
  (let ((seance-claude-lean nil)
        (seance-claude-model nil)
        (seance-claude-extra-args nil))
    (should-not (member "--setting-sources" (seance-claude--base-args nil)))))

;;; Session ids

(ert-deftest seance-claude-uuid-is-v4-shaped-and-unique ()
  (let ((a (seance-claude--uuid)) (b (seance-claude--uuid)))
    (should (string-match-p
             "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'" a))
    (should-not (equal a b))))

;;; Missing CLI

(ert-deftest seance-claude-executable-errors-helpfully-when-missing ()
  (let ((seance-claude-program "definitely-not-a-real-program-xyz"))
    (should-error (seance-claude--executable) :type 'user-error)))

;;; Profile: this backend overrides the global default

(ert-deftest seance-claude-asks-for-the-full-profile-by-default ()
  (should (eq :full (default-value 'seance-claude-profile))))

(ert-deftest seance-claude-profile-nil-inherits-the-global-default ()
  (let ((seance-claude-profile nil)
        (seance-profile :lean))
    (should (eq :lean (or seance-claude-profile seance-profile)))))

;;; Sending outside a chat buffer

(ert-deftest seance-claude-send-refuses-outside-a-chat-buffer ()
  (with-temp-buffer
    (should-error (seance-claude-send) :type 'user-error)))

(provide 'seance-claude-test)
;;; seance-claude-test.el ends here
