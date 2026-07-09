;;; seance.el --- Hand an LLM a snapshot of your live Lisp image  -*- lexical-binding: t; -*-

;; Author: Real Limoges <b.real.limoges@gmail.com>
;; URL: https://github.com/real-limoges/seance
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (sly "1.0.43"))
;; Keywords: lisp, tools, convenience
;; SPDX-License-Identifier: BSD-2-Clause

;;; Commentary:
;; Everything in seance that doesn't care where the bytes end up. Two stages:
;;
;; 1. CAPTURE   -- a small ring of recent evals / compiles, grabbed with stable
;;                 `advice-add' on SLY's own entry points (not slynk). Also
;;                 stashes the focus symbol *while point is still in the Lisp
;;                 buffer*, so a chat buffer can ask about it later.
;;
;; 2. ASSEMBLE  -- `seance-context-string' calls SLYNK-SEANCE:IMAGE-CONTEXT for
;;                 the in-image stuff and staples the local eval log onto it.
;;
;; TRANSPORT is somebody else's problem. Load one, or both:
;;
;;   seance-claude.el  -- the `claude' CLI, on your Claude Code subscription
;;   seance-gptel.el   -- gptel, pointed at any OpenAI-compatible server
;;
;; They share the ring, the hook, and the assembler that live here, so loading
;; both doesn't log every eval twice.

;;; Code:

(require 'sly)
(require 'cl-lib)

(defvar seance--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Where seance.el lives, and therefore slynk-seance.lisp next to it.")

(defgroup seance nil
  "Push live Lisp image context to an LLM."
  :group 'sly)

(defcustom seance-profile :lean
  "How much snapshot to ask for: `:lean' or `:full'.

That's a question about the model's context budget, not about how the bytes
travel, so a backend can override it -- see `seance-claude-profile'.

`:lean' drops the one-hop callee expansion and the REPL values, and trims the
caller and condition lists. Small local windows need room to breathe."
  :type '(choice (const :lean) (const :full)))

(defcustom seance-log-size 12
  "How many recent interactions to keep in the eval log."
  :type 'integer)

(defcustom seance-form-limit 300
  "Hard cap in chars for any single logged form or result."
  :type 'integer)

(defcustom seance-autoload t
  "When non-nil, seance sets itself up on every new SLY connection: loads
`seance-slynk-file' into the Lisp and installs capture advice. No
`M-x seance-install' needed."
  :type 'boolean)

(defcustom seance-slynk-file
  (expand-file-name "slynk-seance.lisp" seance--dir)
  "The image side, loaded into the Lisp on connect."
  :type 'file)


;;; CAPTURE
;;; entries are the form: (:kind eval|def :form STRING :result STRING-or-nil)

(defvar seance--log nil "Ring of recent interactions, newest first.")
(defvar seance--pending nil "Form string awaiting its eval result.")
(defvar seance--last-focus nil
  "Cons (SYMBOL-STRING . PACKAGE-STRING) from the last capture.
What we fall back on when context gets assembled somewhere that isn't a Lisp
buffer -- a chat buffer, say, where `sly-symbol-at-point' would happily hand
back a word out of your own prose.")

(defun seance--truncate (s)
  (if (and s (> (length s) seance-form-limit))
      (concat (substring s 0 seance-form-limit) " ...")
    s))

(defun seance--record (kind form &optional result)
  (push (list :kind kind
              :form (seance--truncate form)
              :result (seance--truncate result))
        seance--log)
  (when (> (length seance--log) seance-log-size)
    (setq seance--log (cl-subseq seance--log 0 seance-log-size))))

(defun seance--stash-focus ()
  "Grab the symbol and package while point is still on the source."
  (let ((sym (ignore-errors (sly-symbol-at-point)))
        (pkg (ignore-errors (sly-current-package))))
    (when (or sym pkg)
      (setq seance--last-focus (cons sym pkg)))))

(defun seance-clear-log ()
  "Drop the local eval log."
  (interactive)
  (setq seance--log nil seance--pending nil)
  (message "seance: log cleared"))

;; C-x C-e / C-M-x go through `sly-interactive-eval' and the result comes back
;; out of `sly-display-eval-result'. Stash the form on the way in, pair it with
;; the value on the way out. Interactive eval is human-paced and serial so this
;; holds up fine; a stray result with nothing pending just gets dropped.

(defun seance--note-form (string &rest _)
  (seance--stash-focus)
  (setq seance--pending string))

(defun seance--note-result (value &rest _)
  (when seance--pending
    (seance--record 'eval seance--pending value)
    (setq seance--pending nil)))

;; C-c C-c compiles instead of evaling, and might be acting on a region.
(defun seance--note-compile (&rest _)
  (seance--stash-focus)
  (let ((form (ignore-errors
                (cl-destructuring-bind (beg end)
                    (if (use-region-p)
                        (list (region-beginning) (region-end))
                      (sly-region-for-defun-at-point))
                  (buffer-substring-no-properties beg end)))))
    (when form (seance--record 'def form nil))))

(defun seance-install ()
  "Install capture advice. Runs twice without complaint."
  (interactive)
  (advice-add 'sly-interactive-eval    :before #'seance--note-form)
  (advice-add 'sly-display-eval-result :after  #'seance--note-result)
  (advice-add 'sly-compile-defun       :before #'seance--note-compile)
  (message "seance: capture installed"))

(defun seance-uninstall ()
  "Remove capture advice."
  (interactive)
  (advice-remove 'sly-interactive-eval    #'seance--note-form)
  (advice-remove 'sly-display-eval-result #'seance--note-result)
  (advice-remove 'sly-compile-defun       #'seance--note-compile)
  (message "seance: capture uninstalled"))


;;; ASSEMBLE

(defun seance--render-log ()
  "Render the recent-evals log as a string; empty when the log is empty."
  (if (null seance--log) ""
    (concat
     "\n--- RECENT EVALS (newest last) ---\n"
     (mapconcat
      (lambda (e)
        (pcase (plist-get e :kind)
          ('def (format "(def) %s\n" (plist-get e :form)))
          (_    (format "%s\n => %s\n"
                        (plist-get e :form)
                        (or (plist-get e :result) "?")))))
      (reverse seance--log) ""))))

(defun seance--focus ()
  "Cons (FOCUS-STRING . PACKAGE-STRING) for whatever we're asking about.
In a Lisp buffer, point wins. Anywhere else -- a chat buffer, mostly -- use
what CAPTURE stashed, because out there `sly-symbol-at-point' will cheerfully
return whatever word you're parked on. Ask the image about \"slow\" and you
get what you deserve."
  (if (derived-mode-p 'lisp-mode)
      (cons (sly-symbol-at-point)
            (or (sly-current-package) "COMMON-LISP-USER"))
    (cons (car seance--last-focus)
          (or (cdr seance--last-focus) "COMMON-LISP-USER"))))

(defun seance-context-string (&optional profile)
  "What the image knows, via the slynk RPC, plus our own eval log.
PROFILE overrides `seance-profile' just for this call."
  (let* ((profile (or profile seance-profile))
         (focus   (seance--focus))
         (image   (condition-case err
                      (sly-eval `(slynk-seance:image-context
                                  ,(car focus) ,(cdr focus) ,profile))
                    (error
                     (format (concat ";; SLYNK-SEANCE:IMAGE-CONTEXT failed: %S\n"
                                     ";; Is slynk-seance.lisp loaded in the image?\n")
                             err)))))
    (concat image (seance--render-log))))

(defun seance-preview-context (&optional profile)
  "Show exactly what would get sent, without calling anything.
With a prefix argument, ask which PROFILE. Start here when an answer looks
wrong -- usually the snapshot was wrong first."
  (interactive
   (list (when current-prefix-arg
           (intern (completing-read "Profile: " '(":lean" ":full") nil t)))))
  (let ((buf (get-buffer-create "*seance-context*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert (seance-context-string profile))
      (goto-char (point-min)))
    (display-buffer buf)))


;;; AUTOLOAD -- get seance ready on every SLY connection.
;;; One hook, one image load, one capture ring, no matter how many backends.

(defun seance-setup-connection ()
  "Load the image side and install capture on a fresh SLY connection.
Gated by `seance-autoload'. The load is wrapped in `cl:handler-case', so a
broken `slynk-seance.lisp' gets reported instead of raised -- nothing dumps
you into SLDB the moment you connect."
  (when (and seance-autoload
             (sly-connected-p)
             (file-readable-p seance-slynk-file))
    (sly-eval-async
        `(cl:handler-case (cl:progn (cl:load ,seance-slynk-file) t)
          (cl:error (e) (cl:princ-to-string e)))
      (lambda (res)
        (if (eq res t)
            (progn
              (seance-install)
              (message "seance: image contrib loaded; capture installed"))
          (message "seance: image contrib NOT loaded: %s" res))))))

(add-hook 'sly-connected-hook #'seance-setup-connection)

(provide 'seance)
;;; seance.el ends here
