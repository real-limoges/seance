;;; seance-test.el --- ERT tests for the seance core  -*- lexical-binding: t; -*-

;;; Commentary:
;; CAPTURE (the log ring, truncation, focus stashing) and ASSEMBLE
;; (`seance-context-string' and how it picks a focus symbol).
;;
;; ASSEMBLE gets tested by stubbing `sly-eval', so no live image needed. The
;; image side has its own suite over in test/run-tests.lisp.
;;
;;   emacs -Q --batch -L . -L test -L $SLY_DIR -l test/seance-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sly)
(require 'seance)

;;; Helpers

(defmacro seance-test--with-clean-state (&rest body)
  "Run BODY with a fresh capture ring and predictable limits."
  (declare (indent 0))
  `(let ((seance--log nil)
         (seance--pending nil)
         (seance--last-focus nil)
         (seance-log-size 12)
         (seance-form-limit 300)
         (seance-profile :lean))
     ,@body))

(defmacro seance-test--capturing-rpc (var &rest body)
  "Run BODY with `sly-eval' stubbed to record its form into VAR.
The stub returns a marker string so callers can see it reached the image."
  (declare (indent 1))
  ;; the stub's parameter must not be named after anything a caller might pass
  ;; as VAR, or the `setq' below writes to the lambda's local instead.
  (let ((arg (gensym "rpc-form-")))
    `(let ((,var nil))
       (cl-letf (((symbol-function 'sly-eval)
                  (lambda (,arg &rest _) (setq ,var ,arg) "<<IMAGE>>")))
         ,@body))))

;;; CAPTURE: truncation

(ert-deftest seance-truncate-leaves-short-strings-alone ()
  (let ((seance-form-limit 10))
    (should (equal "abc" (seance--truncate "abc")))))

(ert-deftest seance-truncate-caps-long-strings ()
  (let ((seance-form-limit 3))
    (should (equal "abc ..." (seance--truncate "abcdef")))))

(ert-deftest seance-truncate-passes-nil-through ()
  (should (null (seance--truncate nil))))

;;; CAPTURE: the ring

(ert-deftest seance-record-pushes-newest-first ()
  (seance-test--with-clean-state
    (seance--record 'eval "(first)" "1")
    (seance--record 'eval "(second)" "2")
    (should (equal "(second)" (plist-get (car seance--log) :form)))))

(ert-deftest seance-record-caps-the-ring ()
  (seance-test--with-clean-state
    (let ((seance-log-size 3))
      (dotimes (i 10) (seance--record 'eval (format "(form %d)" i) "v"))
      (should (= 3 (length seance--log)))
      (should (equal "(form 9)" (plist-get (car seance--log) :form))))))

(ert-deftest seance-record-truncates-both-form-and-result ()
  (seance-test--with-clean-state
    (let ((seance-form-limit 2))
      (seance--record 'eval "abcdef" "ghijkl")
      (let ((e (car seance--log)))
        (should (equal "ab ..." (plist-get e :form)))
        (should (equal "gh ..." (plist-get e :result)))))))

(ert-deftest seance-clear-log-empties-ring-and-pending ()
  (seance-test--with-clean-state
    (setq seance--log '(:x) seance--pending "(pending)")
    (seance-clear-log)
    (should (null seance--log))
    (should (null seance--pending))))

;;; CAPTURE: eval/result pairing

(ert-deftest seance-note-result-without-pending-form-is-ignored ()
  (seance-test--with-clean-state
    (seance--note-result "stray")
    (should (null seance--log))))

(ert-deftest seance-note-form-then-result-pairs-them ()
  (seance-test--with-clean-state
    (with-temp-buffer
      (lisp-mode)
      (seance--note-form "(+ 1 1)"))
    (seance--note-result "2")
    (let ((e (car seance--log)))
      (should (equal "(+ 1 1)" (plist-get e :form)))
      (should (equal "2" (plist-get e :result))))
    ;; pending is consumed, so a second result does not double-record
    (seance--note-result "3")
    (should (= 1 (length seance--log)))))

;;; CAPTURE: focus stashing

(ert-deftest seance-stash-focus-remembers-symbol-under-point ()
  (seance-test--with-clean-state
    (with-temp-buffer
      (lisp-mode)
      (insert "(defun my-defun () nil)")
      (goto-char (point-min))
      (search-forward "my-defun")
      (backward-char 2)
      (seance--stash-focus))
    (should (equal "my-defun" (car seance--last-focus)))))

(ert-deftest seance-note-form-stashes-focus ()
  ;; capture advice runs while point is still in the Lisp buffer
  (seance-test--with-clean-state
    (with-temp-buffer
      (lisp-mode)
      (insert "(my-defun 1)")
      (goto-char (point-min))
      (forward-char 2)
      (seance--note-form "(my-defun 1)"))
    (should (equal "my-defun" (car seance--last-focus)))))

;;; ASSEMBLE: rendering

(ert-deftest seance-render-log-is-empty-when-log-is-empty ()
  (seance-test--with-clean-state
    (should (equal "" (seance--render-log)))))

(ert-deftest seance-render-log-orders-oldest-first ()
  ;; the ring is newest-first; the prompt wants newest *last*
  (seance-test--with-clean-state
    (seance--record 'eval "(older)" "1")
    (seance--record 'eval "(newer)" "2")
    (let ((out (seance--render-log)))
      (should (< (string-match-p (regexp-quote "(older)") out)
                 (string-match-p (regexp-quote "(newer)") out))))))

(ert-deftest seance-render-log-marks-defs-and-shows-eval-results ()
  (seance-test--with-clean-state
    (seance--record 'def "(defun f ())")
    (seance--record 'eval "(+ 1 1)" "2")
    (let ((out (seance--render-log)))
      (should (string-match-p (regexp-quote "(def) (defun f ())") out))
      (should (string-match-p (regexp-quote "(+ 1 1)\n => 2") out)))))

(ert-deftest seance-render-log-shows-question-mark-for-missing-result ()
  (seance-test--with-clean-state
    (seance--record 'eval "(hangs)" nil)
    (should (string-match-p (regexp-quote "=> ?") (seance--render-log)))))

;;; ASSEMBLE: focus resolution -- the bug that made the merge worth doing.
;;;
;;; Old sly-claude.el called (sly-symbol-at-point) unconditionally, then
;;; assembled context from inside its own chat buffer. So the focus it shipped
;;; was whatever word your cursor was parked on in your own prose -- "slow", out
;;; of "why is my defun slow" -- or just nil. These keep it fixed.

(ert-deftest seance-focus-comes-from-point-inside-a-lisp-buffer ()
  (seance-test--with-clean-state
    (with-temp-buffer
      (lisp-mode)
      (insert "(frobnicate 1)")
      (goto-char (point-min))
      (forward-char 2)
      (should (equal "frobnicate" (car (seance--focus)))))))

(ert-deftest seance-focus-falls-back-to-stash-outside-lisp-buffers ()
  (seance-test--with-clean-state
    (setq seance--last-focus (cons "my-defun" "MY-PKG"))
    (with-temp-buffer                   ; fundamental-mode: a chat buffer
      (insert "why is my defun slow")
      (goto-char (point-max))
      (backward-word 1)                 ; point is on "slow"
      (let ((focus (seance--focus)))
        (should (equal "my-defun" (car focus)))
        (should (equal "MY-PKG" (cdr focus)))
        (should-not (equal "slow" (car focus)))))))

(ert-deftest seance-focus-defaults-package-when-nothing-is-stashed ()
  (seance-test--with-clean-state
    (with-temp-buffer
      (insert "prose")
      (let ((focus (seance--focus)))
        (should (null (car focus)))
        (should (equal "COMMON-LISP-USER" (cdr focus)))))))

;;; ASSEMBLE: the RPC call itself

(ert-deftest seance-context-string-sends-focus-package-and-profile ()
  (seance-test--with-clean-state
    (setq seance--last-focus (cons "my-defun" "MY-PKG"))
    (seance-test--capturing-rpc form
      (with-temp-buffer
        (insert "prose")
        (seance-context-string :full))
      (should (eq 'slynk-seance:image-context (nth 0 form)))
      (should (equal "my-defun" (nth 1 form)))
      (should (equal "MY-PKG"   (nth 2 form)))
      (should (eq :full         (nth 3 form))))))

(ert-deftest seance-context-string-defaults-profile-to-seance-profile ()
  (seance-test--with-clean-state
    (let ((seance-profile :lean))
      (seance-test--capturing-rpc form
        (with-temp-buffer (seance-context-string))
        (should (eq :lean (nth 3 form)))))))

(ert-deftest seance-context-string-appends-the-eval-log ()
  (seance-test--with-clean-state
    (seance--record 'eval "(+ 1 1)" "2")
    (seance-test--capturing-rpc _form
      (let ((out (with-temp-buffer (seance-context-string))))
        (should (string-prefix-p "<<IMAGE>>" out))
        (should (string-match-p (regexp-quote "RECENT EVALS") out))
        (should (string-match-p (regexp-quote "(+ 1 1)") out))))))

(ert-deftest seance-context-string-degrades-when-the-rpc-fails ()
  ;; a missing slynk-seance.lisp must not signal into the caller's chat buffer
  (seance-test--with-clean-state
    (cl-letf (((symbol-function 'sly-eval)
               (lambda (&rest _) (error "package SLYNK-SEANCE does not exist"))))
      (let ((out (with-temp-buffer (seance-context-string))))
        (should (string-match-p "IMAGE-CONTEXT failed" out))
        (should (string-match-p "slynk-seance.lisp" out))))))

;;; Wiring

(ert-deftest seance-slynk-file-points-at-the-shared-contrib ()
  (should (equal "slynk-seance.lisp" (file-name-nondirectory seance-slynk-file))))

(ert-deftest seance-defaults-to-the-lean-profile ()
  (should (eq :lean (default-value 'seance-profile))))

(ert-deftest seance-installs-exactly-one-connection-hook ()
  ;; one hook, one image load, however many backends are loaded
  (should (= 1 (cl-count #'seance-setup-connection sly-connected-hook))))

(provide 'seance-test)
;;; seance-test.el ends here
