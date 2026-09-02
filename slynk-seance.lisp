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
           #:with-captured-conditions
           #:*max-callers*
           #:*max-conditions*
           #:*max-neighbors*
           #:*max-definition-chars*))

(in-package :slynk-seance)

(defvar *max-callers* 12
  "Cap on the caller list. A hot function has hundreds of them and nobody reads
past the first dozen, so this stops one from swallowing the whole snapshot.")

(defvar *max-conditions* 5
  "Size of recent-conditions ring.")

(defvar *max-neighbors* 6
  "How many callees to expand one hop out in the focus neighborhood.")

(defvar *max-definition-chars* 600
  "Hard cap in chars on any one printed definition.
SBCL keeps the whole lambda expression for a function you defined at the REPL,
which is every function you actually care about here. Under :FULL we print one
for the focus symbol plus every neighbor, so uncapped a handful of ordinary
defuns crowds everything else out of the snapshot.")

(defvar *conditions* '()
  "Recent conditions, most recent first.")

;;; Conditions: manual for v1.
;;;
;;; slynk rebinds *DEBUGGER-HOOK* per request, so a global hook is already out of
;;; scope by the time your form runs. Auto-capture is maybe v2, if i feel like
;;; it. Until then you feed the ring yourself:
;;;
;;;   (handler-bind ((error #'slynk-seance:note-condition)) ...)
;;;
;;; or push from your own top-level handler. Whatever gets the condition in.

(defun subseq-safe (list n)
  (subseq list 0 (min n (length list))))

(defun note-condition (condition)
  "Push CONDITION onto the recent-conditions ring and hand it right back, so
   this can sit inside a HANDLER-BIND without swallowing anything."
  (push (princ-to-string condition) *conditions*)
  (setf *conditions* (subseq-safe *conditions* *max-conditions*))
  condition)

(defmacro with-captured-conditions (&body body)
  "Run BODY, noting every SERIOUS-CONDITION signalled inside it into the ring.
   Declines to handle any of them: HANDLER-BIND observes and returns, so
   whatever would have happened without this still happens, SLDB included.

   Wrapping is not laziness on our part, it is the only thing that works.
   SLYNK-BACKEND:CALL-WITH-DEBUGGER-HOOK rebinds *DEBUGGER-HOOK* around every
   request, so a handler installed globally is out of scope by the time your
   form runs. Being inside the form's dynamic extent is the whole trick.

       (slynk-seance:with-captured-conditions
         (your-flaky-thing))

   SERIOUS-CONDITION rather than ERROR, so a STORAGE-CONDITION counts too.
   HANDLER-BIND yourself if you want warnings in there as well."
  `(handler-bind ((serious-condition #'note-condition))
     ,@body))

;;; With a little help(ers) of my friends

(defun resolve-symbol (name package-designator)
  "Reads NAME as a symbol in PACKAGE-DESIGNATOR but no eval. NIL on failure.
   Handles case and package qualifiers via reader, so FOO/foo/pkg:foo all behave
   the same as they do in the REPL.

   The reader interns whatever it reads, and a snapshot has no business leaving
   symbols behind in the image it is only meant to be describing -- one typo
   under point would do it, permanently. So the read happens in a scratch
   package that gets deleted right after, and an unqualified name is then looked
   up in the real package with FIND-SYMBOL instead of interned into it.

   PKG::NAME for a name that does not exist yet is the case still interned, by
   the reader, into the package you went out of your way to spell."
  (let ((home    (or (find-package package-designator) *package*))
        (scratch (make-package (gensym "SEANCE-READ-") :use '())))
    (unwind-protect
         (handler-case
             (let ((obj (let ((*package* scratch)
                              (*read-eval* nil))
                          (read-from-string name))))
               (cond ((not (symbolp obj)) nil)
                     ;; unqualified, so the reader parked it in SCRATCH; ask
                     ;; the real package whether it has one by that name.
                     ((eq (symbol-package obj) scratch)
                      (find-symbol (symbol-name obj) home))
                     (t obj)))
           (error () nil))
      (delete-package scratch))))

(defun first-line (string)
  (let ((nl (position #\Newline string)))
    (if nl (subseq string 0 nl) string)))

(defun truncate-string (string limit)
  "STRING hard-truncated to LIMIT chars, ellipsized when it actually got cut."
  (if (> (length string) limit)
      (concatenate 'string (subseq string 0 limit) " ...")
      string))

(defun truncate-print (object &optional (limit 200))
  "PRIN1 OBJECT with depth/length caps, then hard-truncated to LIMIT chars."
  (truncate-string
   (let ((*print-length* 20)
         (*print-level* 4)
         (*print-readably* nil))
     (prin1-to-string object))
   limit))

(defun truncate-definition (lambda-expression)
  "LAMBDA-EXPRESSION printed for a prompt: downcased, elided, hard-capped.
Looser depth and length limits than TRUNCATE-PRINT allows, because this is code
somebody has to follow rather than a REPL value they only need to recognize.
*PRINT-CASE* does the downcasing that the caller's ~( ~) used to, without also
flattening any string literals inside the definition."
  (truncate-string
   (let ((*print-length* 40)
         (*print-level* 8)
         (*print-readably* nil)
         (*print-case* :downcase))
     (prin1-to-string lambda-expression))
   *max-definition-chars*))

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
          (lex (format s "~% ~A" (truncate-definition lex)))
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
  "A snapshot of the live image, ready to prefix onto an LLM prompt. PROFILE is
:lean or :full. FOCUS-NAME is the symbol under point, or NIL when there wasn't
one. Emacs staples its own eval-log section onto whatever this hands back."
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
