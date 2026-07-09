;;;; slynk-seance.lisp
;;;;
;;;; Exposes one RPC and SLYNK-SEANCE:IMAGE-CONTEXT.
;;;; SLYNK-SEANCE:IMAGE-CONTEXT returns a token-efficient snapshot of the live image
;;;; for prepending to an LLM prompt.
;;;;
;;;; I split it in two: a CL side and an ELisp side. EmacsLisp already has the data
;;;; and can capture it with stable advice. slynk-seance.lisp controls
;;;; what is inside the image: call-graph neighborhood, live REPL stuff, and noted conditions.
;;;;
;;;; The transports (seance-claude.el, seance-gptel.el) share this file, but they differ
;;;; in the PROFILE they ask for and where they send the result.
;;;;
;;;; Load AFTER slynk is up:  (load "slynk-seance.lisp")
;;;;
;;;; Tested only against SBCL

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-introspect))

(defpackage :slynk-seance
  (:use :cl)
  (:import-from :slynk-api #:defslyfun)
  (:export #:image-context
           #:note-condition
           #:*max-callers*
           #:*max-conditions*
           #:*max-neighbors*))

(in-package :slynk-seance)

(defvar *max-callers* 12
  "Prevents hot function from blowing up")

(defvar *max-conditions* 5
  "Size of recent-conditions ring.")

(defvar *max-neighbors* 6
  "How many callees to expand one hop out in the focus neighborhood.")

(defvar *conditions* '()
  "Recent conditions, most recent first.")

;;; Conditions: Manual for V1
;;;
;;; slynk rebinds *DEBUGGER-HOOK* per request  - so we can shadow a global hook
;;; inside slynk evals (auto-capture is maybe v2 if i feel like it).
;;; iFeeds the ring explicitly
;;;
;;;   (handler-bind ((error #'slynk-seance:note-condition)) ...)
;;;
;;; I guess you can also push from your own top-level handler?

(defun subseq-safe (list n)
  (subseq list 0 (min n (length list))))

(defun note-condition (condition)
  "Record CONDITION into recent-conditions ring.
   Also returns CONDITION as well so it can sit transparently in a HANDLER-BIND"
  (push (princ-to-string condition) *conditions*)
  (setf *conditions* (subseq-safe *conditions* *max-conditions*))
  condition)

;;; With a little help(ers) of my friends

(defun resolve-symbol (name package-designator)
  "Reads NAME as a symbol in PACKAGE-DESIGNATOR but no eval. NIL on failure.
   Handles case and package qualifiers via reader, so FOO/foo/pkg:foo all behave
   the same as they do in the REPL"
  (let ((*package* (or (find-package package-designator) *package*))
        (*read-eval* nil))
    (handler-case
        (let ((obj (read-from-string name)))
          (and (symbolp obj) obj))
      (error () nil))))

(defun first-line (string)
  (let ((nl (position #\Newline string)))
    (if nl (subseq string 0 nl) string)))

(defun truncate-print (object &optional (limit 200))
  "PRIN1 OBJECT with depth/length caps. Hard-truncated to LIMIT chars"
  (let ((s (let ((*print-length* 20)
                 (*print-level* 4)
                 (*print-readably* nil))
             (prin1-to-string object))))
    (if (> (length s) limit)
        (concatenate 'string (subseq s 0 limit) " ...")
        s)))

(defun xref-names (result)
  "Deduped name strings out of a SLYNK-BACKEND xref RESULT.
   A backend that can't answer says :NOT-IMPLEMENTED instead of signalling,
   so anything that isn't a list gets NIL. Don't hand a keyword to MAPCAR."
  (when (listp result)
    (remove-duplicates
     (mapcar (lambda (entry)
               ;; entries are like (name . loc) or (name loc); CAR is the name
               (princ-to-string (if (consp entry) (car entry) entry)))
             result)
     :test #'string=)))

(defun callers (symbol)
  "Who calls SYMBOL. Empty when there's no xref data."
  (handler-case (xref-names (slynk-backend:who-calls symbol))
    (error () '())))

(defun function-name-string (function)
  (let ((name (nth-value 2 (function-lambda-expression function))))
    (and name (princ-to-string name))))

(defun callees (symbol)
  "What SYMBOL calls. Empty when nobody can tell us.
   SLYNK-BACKEND:CALLS-WHO just says :NOT-IMPLEMENTED on SBCL, which is the
   only place this actually runs, so ask SB-INTROSPECT instead. Everyone else
   keeps the portable path. Without this the callee list is always empty and
   the one-hop expansion below never fires."
  (handler-case
      (or (xref-names (slynk-backend:calls-who symbol))
          #+sbcl
          (when (fboundp symbol)
            (remove-duplicates
             (remove nil
                     (mapcar #'function-name-string
                             (sb-introspect:find-function-callees
                              (fdefinition symbol))))
             :test #'string=)))
    (error () '())))

(defun symbol-summary (symbol)
  "Name, definition (if available), and the first doc line"
  (with-output-to-string (s)
    (format s "~A" symbol)
    (when (fboundp symbol)
      (let ((lex (ignore-errors
                  (nth-value 0
                             (function-lambda-expression
                              (fdefinition symbol))))))
        (cond
          ;; SBCL keeps this for interactive-defined fns. NIL otherwise
          (lex (format s "~% ~(~S~)" lex))
          (t (let ((arglist (ignore-errors (slynk-backend:arglist symbol))))
               (when (and arglist (not (eq arglist :not-available)))
                 (format s "~% arglist: ~(~A~)" arglist)))))
        (let ((doc (documentation symbol 'function)))
          (when doc (format s "~% doc: ~A" (first-line doc))))))))

(defun repl-values ()
  (with-output-to-string (s)
    (loop for var in '(* ** ***)
          for label in '("*" "**" "***")
          do (format s "~% ~A => ~A"
                     label
                     (handler-case (truncate-print (symbol-value var))
                       (unbound-variable () "<unbound>")
                       (error () "<unprintable>"))))))

;;; RPC

(defslyfun image-context
    (&optional focus-name
               (package-name (package-name *package*))
               (profile :lean))
  "Returns a snapshot of the live image for LLM prefix PROFILE is :lean or :full.
FOCUS-NAME is the symbol at a point or NIL. Emacs concatenates its own eval-log section
onto whatever this returns"
  (let* ((full   (eq profile :full))
         (n-call (if full *max-callers* (min 6 *max-callers*))))
    (with-output-to-string (out)
      (format out "=== LISP IMAGE CONTEXT (~(~A~)) ===~%" profile)
      (format out "Package: ~A~%" package-name)
      (let ((focus (and focus-name (resolve-symbol focus-name package-name))))
        (when focus
          (format out "~%--- FOCUS: ~A ---~%~A~%" focus (symbol-summary focus))
          (let ((callers (callers focus))
                (callees (callees focus)))
            (format out " called-by: ~{~A~^, ~}~%"
                    (or (subseq-safe callers n-call) '("<none>")))
            (format out " calls: ~{~A~^, ~}~%"
                    (or (subseq-safe callees n-call) '("<none>")))
            ;; one hop neighborhood - only full
            (when full
              (dolist (name (subseq-safe callees *max-neighbors*))
                (let ((sym (resolve-symbol name package-name)))
                  (when (and sym (fboundp sym) (not (eq sym focus)))
                    (format out "~%~A~%" (symbol-summary sym))))))))
        (when full
          (format out "~%--- LAST REPL VALUES ---~A~%" (repl-values))))
      ;; conditions: one line each under :lean, the whole messy text under :full
      (when *conditions*
        (let ((n-cond (if full *max-conditions* (min 2 *max-conditions*))))
          (format out "~%--- RECENT CONDITIONS ---~%")
          (dolist (c (subseq-safe *conditions* n-cond))
            (format out " ~A~%" (if full c (first-line c)))))))))

(provide :slynk-seance)
