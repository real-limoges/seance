;;; seance-claude.el --- seance transport: the claude CLI  -*- lexical-binding: t; -*-

;; Author: Real Limoges <b.real.limoges@gmail.com>
;; URL: https://github.com/real-limoges/seance
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (sly "1.0.43") (seance "0.1.0"))
;; Keywords: lisp, tools, convenience
;; SPDX-License-Identifier: BSD-2-Clause

;;; Commentary:
;; TRANSPORT for seance: shoves the snapshot at the `claude' CLI in headless
;; mode (-p/--print). Runs on whatever subscription the CLI is logged into --
;; no API key.
;;
;; Which is the entire reason this exists next to seance-gptel.el. gptel can
;; talk to Claude too, but only if you hand it an API key.
;;
;; Wants the `claude' CLI on PATH and logged in (this is Claude Code itself).
;; Set `seance-claude-program' to an absolute path when a GUI Emacs can't find
;; it, which it usually can't.
;;
;; Bind:
;;   (with-eval-after-load 'sly
;;     (define-key sly-mode-map (kbd "C-c C-S-y") #'seance-claude))

;;; Code:

(require 'sly)
(require 'seance)

(defgroup seance-claude nil
  "Push live Lisp image context to Claude via the claude CLI."
  :group 'seance)

(defcustom seance-claude-program "claude"
  "The Claude Code CLI we shell out to.
Headless (`-p'), on whatever subscription the CLI is logged into -- no API
key. Set an absolute path (e.g. \"/opt/homebrew/bin/claude\") when a GUI
Emacs can't find it on PATH."
  :type 'string)

(defcustom seance-claude-model nil
  "Model passed to `claude --model'.  nil uses the CLI's default."
  :type '(choice (const :tag "CLI default" nil) string))

(defcustom seance-claude-extra-args nil
  "Extra args tacked onto every `claude' invocation.
E.g. \\='(\"--disallowed-tools\" \"Edit\" \"Write\" \"Bash\") to keep it pure
Q&A that never touches your repo."
  :type '(repeat string))

(defcustom seance-claude-profile :full
  "Snapshot size for this backend, overriding `seance-profile'.
Claude's window is big enough that the full one is worth sending. nil to
inherit `seance-profile' instead."
  :type '(choice (const :tag "Inherit seance-profile" nil)
                 (const :lean) (const :full)))

(defcustom seance-claude-buffer-name "*seance-claude*"
  "Buffer name for the multi-turn chat."
  :type 'string)

(defcustom seance-claude-lean t
  "When non-nil, run `claude' lean for these one-off calls.
The process gets a neutral directory and `--setting-sources project', so with
no project sitting there the SessionStart hooks never fire and no CLAUDE.md
turns up. Each call carries the image context you sent and nothing else --
not your whole Claude Code project payload. Cheaper, faster, easier on the
5-hour limit. Keychain auth survives."
  :type 'boolean)

(defcustom seance-claude-preamble
  (concat "You are pair-programming with an experienced Lisper at a live SBCL "
          "REPL via SLY. Definitions evolve in the image; the snapshot below is "
          "the current truth. Prefer small, modular functions. Reply with forms "
          "ready to eval, not file scaffolding.")
  "System message preamble prepended to image context."
  :type 'string)


;;; TRANSPORT -- the `claude' CLI (your subscription), no gptel / API key

;; (I pick up buffers and put them down)

(defun seance-claude--executable ()
  "Where the claude CLI lives, or an error that says something useful."
  (or (executable-find seance-claude-program)
      (and (file-name-absolute-p seance-claude-program)
           (file-executable-p seance-claude-program)
           seance-claude-program)
      (user-error
       "seance-claude: can't find `%s' (set `seance-claude-program' to its full path)"
       seance-claude-program)))

(defun seance-claude--base-args (extra)
  "Streaming print-mode args + optional model + `seance-claude-extra-args' + EXTRA."
  (append (list "-p" "--output-format" "stream-json" "--verbose"
                "--include-partial-messages")
          (when seance-claude-lean (list "--setting-sources" "project"))
          (when seance-claude-model (list "--model" seance-claude-model))
          seance-claude-extra-args
          extra))

(defun seance-claude--emit (target text)
  "Append TEXT at the end of TARGET and keep its window scrolled to the bottom."
  (when (and (stringp text) (> (length text) 0) (buffer-live-p target))
    (with-current-buffer target
      (save-excursion (goto-char (point-max)) (insert text)))
    (let ((w (get-buffer-window target)))
      (when w (set-window-point w (point-max))))))

(defun seance-claude--handle-event (proc obj target)
  "Act on one parsed stream-json OBJ: text deltas go into TARGET.
PROC carries `seance-claude-got-text' so that a `result' arriving with no
deltas before it can still cough up the whole answer."
  (pcase (gethash "type" obj)
    ("stream_event"
     (let ((ev (gethash "event" obj)))
       (when (and ev (equal (gethash "type" ev) "content_block_delta"))
         (let ((delta (gethash "delta" ev)))
           (when (and delta (equal (gethash "type" delta) "text_delta"))
             (process-put proc 'seance-claude-got-text t)
             (seance-claude--emit target (gethash "text" delta)))))))
    ("result"
     (let ((res (gethash "result" obj)))
       (cond
        ((eq (gethash "is_error" obj) t)
         (seance-claude--emit target (format "\n;; claude error: %s\n"
                                             (or res (gethash "subtype" obj)))))
        ((and (not (process-get proc 'seance-claude-got-text)) (stringp res))
         (seance-claude--emit target res)))))))

(defun seance-claude--consume-line (proc line target)
  "Parse one stdout LINE of stream-json and do something with it.
Cheap prefix test first, so the enormous SessionStart/hook events (and any
stderr noise) get skipped without paying for a JSON parse."
  (when (or (string-prefix-p "{\"type\":\"stream_event\"" line)
            (string-prefix-p "{\"type\":\"result\"" line))
    (let ((obj (ignore-errors
                 (json-parse-string line :object-type 'hash-table
                                    :null-object nil :false-object nil))))
      (when obj (seance-claude--handle-event proc obj target)))))

(defun seance-claude--spawn (target prompt extra &optional finalize)
  "Run claude with EXTRA args and PROMPT on stdin; stream the answer back.
TARGET is where it lands. Output is `--output-format stream-json'; we pick the
text deltas out and insert them live.
FINALIZE, if you pass one, runs with no args in TARGET on exit."
  (let* ((default-directory (if seance-claude-lean
                                (file-name-as-directory temporary-file-directory)
                              default-directory))
         (exe  (seance-claude--executable))
         (proc (make-process
                :name "seance-claude"
                :buffer nil
                :noquery t
                :connection-type 'pipe
                :command (cons exe (seance-claude--base-args extra))
                :filter
                (lambda (proc chunk)
                  (when (buffer-live-p target)
                    (let* ((acc   (concat (process-get proc 'seance-claude-acc) chunk))
                           (lines (split-string acc "\n")))
                      ;; hang onto the trailing line, it's probably half a JSON object
                      (process-put proc 'seance-claude-acc (car (last lines)))
                      (dolist (line (butlast lines))
                        (seance-claude--consume-line proc line target)))))
                :sentinel
                (lambda (proc _event)
                  (when (and (memq (process-status proc) '(exit signal))
                             (buffer-live-p target))
                    (let ((rest (process-get proc 'seance-claude-acc)))
                      (when (and rest (> (length rest) 0))
                        (seance-claude--consume-line proc rest target)))
                    (with-current-buffer target
                      (unless (zerop (process-exit-status proc))
                        (save-excursion
                          (goto-char (point-max))
                          (insert (format "\n;; claude exited %d\n"
                                          (process-exit-status proc)))))
                      (when finalize (funcall finalize))))))))
    (process-send-string proc prompt)
    (process-send-eof proc)
    proc))


;;; Multi-turn chat. Keeps a real session via --session-id / --resume so the
;;; turns share history; re-running folds a fresh snapshot into the next message.

(defvar-local seance-claude--session nil "Claude session id for this chat buffer.")
(defvar-local seance-claude--started nil "Non-nil once the session has its first turn.")
(defvar-local seance-claude--refresh nil "Non-nil to ride a fresh snapshot next turn.")

(defvar seance-claude-chat-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'seance-claude-send)
    (define-key m (kbd "C-c C-r") #'seance-claude)
    m)
  "Keymap for `seance-claude-chat-mode'.")

(define-minor-mode seance-claude-chat-mode
  "Minor mode for a CLI-backed seance chat buffer.
\\<seance-claude-chat-mode-map>Type after the `## You' prompt and hit
\\[seance-claude-send] to send; \\[seance-claude] refreshes the snapshot."
  :lighter " Seance")

(defun seance-claude--uuid ()
  "A random v4-shaped UUID, good enough for a session id."
  (format "%04x%04x-%04x-4%03x-%x%03x-%04x%04x%04x"
          (random 65536) (random 65536) (random 65536) (random 4096)
          (+ 8 (random 4)) (random 4096)
          (random 65536) (random 65536) (random 65536)))

(defun seance-claude-send ()
  "Send the text after the last `## You' prompt as the next turn in this chat."
  (interactive)
  (unless seance-claude--session
    (user-error "seance-claude: not a chat buffer (use M-x seance-claude)"))
  (let* ((start (save-excursion
                  (goto-char (point-max))
                  (if (re-search-backward "^## You$" nil t)
                      (line-beginning-position 2)
                    (point-min))))
         (msg (string-trim (buffer-substring-no-properties start (point-max)))))
    (when (string-empty-p msg) (user-error "seance-claude: empty message"))
    (let* ((ctx   (when (or (not seance-claude--started) seance-claude--refresh)
                    ;; we're in the chat buffer, so focus comes from whatever
                    ;; CAPTURE stashed back in the Lisp buffer. see `seance--focus'
                    (seance-context-string (or seance-claude-profile seance-profile))))
           (full  (if ctx
                      (concat "Current live-image context:\n```\n" ctx "\n```\n\n" msg)
                    msg))
           (extra (if seance-claude--started
                      (list "--resume" seance-claude--session)
                    (list "--session-id" seance-claude--session
                          "--system-prompt" seance-claude-preamble)))
           (buf   (current-buffer)))
      (setq seance-claude--started t
            seance-claude--refresh nil)
      (goto-char (point-max))
      (insert "\n\n## Claude\n\n")
      (seance-claude--spawn buf full extra
                            (lambda ()
                              (goto-char (point-max))
                              (insert "\n\n## You\n\n")
                              (let ((w (get-buffer-window buf)))
                                (when w (set-window-point w (point-max)))))))))

;;;###autoload
(defun seance-claude ()
  "Open (or refresh) a CLI-backed chat buffer seeded with the image context.
Runs on your Claude Code subscription. Type after the `## You' prompt, then
\\[seance-claude-send] to send. Re-run it mid-conversation to fold a fresh
snapshot into your next message."
  (interactive)
  (seance-claude--executable)           ; bail now if claude isn't there
  (let* ((existing (get-buffer seance-claude-buffer-name))
         (buf (get-buffer-create seance-claude-buffer-name)))
    (with-current-buffer buf
      (if existing
          (progn
            (setq seance-claude--refresh t)
            (message "seance-claude: a fresh image snapshot will ride along with your next send"))
        (when (fboundp 'markdown-mode) (markdown-mode))
        (seance-claude-chat-mode 1)
        (setq seance-claude--session (seance-claude--uuid)
              seance-claude--started nil
              seance-claude--refresh nil)
        (insert "# seance-claude chat\n\n"
                "Type below, then `C-c C-c' to send. `C-c C-r' refreshes the "
                "image snapshot. Runs on your Claude Code subscription.\n\n"
                "## You\n\n")))
    (pop-to-buffer buf)
    (goto-char (point-max))))

(provide 'seance-claude)
;;; seance-claude.el ends here
