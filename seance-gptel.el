;;; seance-gptel.el --- seance transport: gptel  -*- lexical-binding: t; -*-

;; Author: Real Limoges <b.real.limoges@gmail.com>
;; URL: https://github.com/real-limoges/seance
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (sly "1.0.43") (seance "0.1.0"))
;; Keywords: lisp, tools, convenience
;; SPDX-License-Identifier: BSD-2-Clause

;;; Commentary:
;; TRANSPORT for seance: hands the snapshot to gptel, which will talk to any
;; OpenAI-compatible server -- llama.cpp, Ollama, MLX, whatever. The snapshot
;; gets refreshed into the system message before every single send, because
;; the image has probably moved since the last one.
;;
;; gptel is optional. This file loads fine without it; `seance-gptel' just
;; refuses to do anything until gptel is installed and you've picked a backend
;; with `seance-gptel-use-openai-compatible'.
;;
;; Bind:
;;   (with-eval-after-load 'sly
;;     (define-key sly-mode-map (kbd "C-c C-S-l") #'seance-gptel))

;;; Code:

(require 'sly)
(require 'seance)
(require 'gptel nil t)

;; gptel is optional, so the byte-compiler can't see any of its symbols. Declare
;; the ones we use to shut up the "not known to be defined" noise; they resolve
;; at runtime.

(declare-function gptel-send        "gptel")
(declare-function gptel-mode        "gptel")
(declare-function gptel-make-openai "gptel-openai")
(defvar gptel--system-message)
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-stream)

(defgroup seance-gptel nil
  "Push live Lisp image context to a local LLM via gptel."
  :group 'seance)

(defcustom seance-gptel-backend nil
  "GPTEL backend object. See `seance-gptel-use-openai-compatible'."
  :type 'sexp)

(defcustom seance-gptel-model nil
  "GPTEL model symbol."
  :type 'symbol)

(defcustom seance-gptel-profile nil
  "Snapshot size for this backend, overriding `seance-profile'.
nil inherits `seance-profile', which is `:lean' -- about right for the small
local models this thing usually points at."
  :type '(choice (const :tag "Inherit seance-profile" nil)
                 (const :lean) (const :full)))

(defcustom seance-gptel-buffer-name "*seance-gptel*"
  "Buffer for the interactive chat."
  :type 'string)

(defcustom seance-gptel-preamble
  (concat "You are at a live SBCL REPL via SLY. The snapshot below is the "
          "current state of the image; trust it over any earlier code in the "
          "conversation. Answer concisely with forms ready to evaluate. "
          "No file scaffolding, no preamble.")
  "This is the system preamble.
Small models follow tight instructions better than vibes."
  :type 'string)


;;; Backend setup

(defun seance-gptel--require ()
  "Require gptel."
  (unless (featurep 'gptel)
    (user-error "seance-gptel: gptel not available: install and configure")))

(defun seance-gptel-use-openai-compatible (name host model)
  "Point seance at a local OpenAI-compatible server (llama.cpp, ...).
NAME labels the backend, HOST looks like \"localhost:8080\", MODEL is a symbol."
  (seance-gptel--require)
  (setq seance-gptel-backend (gptel-make-openai name
                                                :host host
                                                :protocol "http"
                                                :stream t
                                                :models (list model))
        seance-gptel-model model)
  (message "seance-gptel: using %s @ %s" model host))


;;; Transport

;; Re-snapshot the image before each send. The image moved. It always moves.
(defun seance-gptel-send ()
  "Refresh the snapshot into the system message, then send.
Bound to whatever `gptel-send' is bound to inside the chat buffer."
  (interactive)
  (setq-local gptel--system-message
              (concat seance-gptel-preamble
                      "\n\n"
                      ;; we're in the chat buffer, so focus comes from whatever
                      ;; CAPTURE stashed. see `seance--focus'
                      (seance-context-string
                       (or seance-gptel-profile seance-profile))))
  (call-interactively #'gptel-send))

(defvar seance-gptel-chat-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap gptel-send] #'seance-gptel-send)
    m)
  "Keymap for `seance-gptel-chat-mode'.
Remaps `gptel-send' to `seance-gptel-send' so every send grabs a fresh
snapshot first.")

(define-minor-mode seance-gptel-chat-mode
  "Re-snapshot the live Lisp image before every gptel send."
  :lighter " Seance" :keymap seance-gptel-chat-mode-map)

;;;###autoload
(defun seance-gptel ()
  "Open or switch to the chat buffer wired into the gptel backend.
Ask a question, send it with your usual gptel key. The snapshot gets refreshed
into the system message on the way out."
  (interactive)
  (seance-gptel--require)
  (let ((buf (get-buffer-create seance-gptel-buffer-name)))
    (with-current-buffer buf
      (unless (bound-and-true-p gptel-mode) (gptel-mode 1))
      (when seance-gptel-backend (setq-local gptel-backend seance-gptel-backend))
      (when seance-gptel-model   (setq-local gptel-model seance-gptel-model))
      (setq-local gptel-stream t)       ; local models are slow, stream it
      (seance-gptel-chat-mode 1)
      (goto-char (point-max)))
    (pop-to-buffer buf)))

(provide 'seance-gptel)
;;; seance-gptel.el ends here
