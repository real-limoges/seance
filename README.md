# seance

Come commune with the live image.

When you're twenty redefinitions deep at the REPL, the files on disk are fiction.
The image is the truth. So stop pasting source into a chat window. Relax, un-wind (the stack)
and send the image instead: the symbol at point, who calls it and what it calls, the last few
REPL values, whatever conditions blew up recently, and the evals you just ran.

It's a SLY contrib. It talks to Claude, or to whatever local model you've got warm.
It's half ELisp for integrating and half Common Lisp for working with the image.

## Two transports

- **`seance-claude`** — shells out to the `claude` CLI, headless. Runs on your
  Claude Code subscription, so no API key. That's the only reason it exists.
- **`seance-gptel`** — gptel, pointed at any OpenAI-compatible server. llama.cpp,
  Ollama, MLX, whatever. Nothing leaves the box.

gptel could talk to Claude too, but it wants an API key for the privilege. I'm cheap.

Load one or both. Loading both won't log your evals twice — there's one capture
ring and one connection hook in the core. So rest easy, multi-model native.

## You'll need

SBCL and SLY. Emacs 28.1+ (I use Emacs 30.2). You need `claude` CLI on your PATH for one transport,
or gptel plus something to point it at for the other. The image side leans on
`sb-introspect`, so SBCL is the only thing that's been tested.

## Install

```elisp
;; packages.el
(package! seance :recipe (:host github :repo "real-limoges/seance"
                          :files ("seance*.el" "slynk-seance.lisp")))
```

```elisp
;; config.el
(after! sly
  (when (require 'seance-claude nil t)
    (define-key sly-mode-map (kbd "C-c C-S-y") #'seance-claude))
  (when (require 'seance-gptel nil t)
    (define-key sly-mode-map (kbd "C-c C-S-l") #'seance-gptel)))
```

`slynk-seance.lisp` has to sit next to `seance.el` — that's how it gets found. Don't fight it.
Otherwise just clone it and shove the directory on your `load-path`.

Nothing to set up per session. On every SLY connection the core loads the image
side and starts capturing. If a `slynk-seance.lisp` you've been editing is
broken, you get a message in the echo area, not a faceful of SLDB. You're welcome.

## Using it

Point at a symbol, hit the key, a chat buffer opens. In the Claude one, `C-c C-c`
sends and `C-c C-r` folds a fresh snapshot into your next message. The gptel one
sends with whatever key gptel already uses, and re-snapshots every time.

The focus symbol comes from wherever you last evaluated something, not from where
your cursor happens to be. So asking a question from the chat buffer still asks
about the code you were working on, rather than about the word "slow".

For the gptel side you have to say where the model lives first:
`M-x seance-gptel-use-openai-compatible`, which prompts for a name, a host, and
a model.

Suspicious of an answer? `M-x seance-preview-context` shows you exactly what
would be sent, without sending it. Nine times out of ten the snapshot was wrong
before the model was.

Doom users (me!): `map!` the lot under your localleader and stop typing `M-x`.
Your wrists will thank you.

```elisp
(after! sly
  (map! :localleader :map lisp-mode-map
        (:prefix ("a" . "ask")
         :desc "Claude"             "a" #'seance-claude
         :desc "Local model"        "l" #'seance-gptel
         :desc "Preview context"    "p" #'seance-preview-context
         :desc "Pick local backend" "b" #'seance-gptel-use-openai-compatible
         :desc "Clear eval log"     "c" #'seance-clear-log)))
```

### Conditions

Slynk rebinds `*debugger-hook*` per request, so we can't grab conditions
automatically. Feed them in yourself:

```lisp
(handler-bind ((error #'slynk-seance:note-condition))
  (your-flaky-thing))
```

They show up in the next snapshot, newest first.

## Knobs

Everything's a defcustom; `C-h v seance-` will show you the lot. The ones you'll
actually touch:

- `seance-profile` — `:lean` or `:full`. Lean trims the snapshot down for small
  local models, which have small windows and big opinions. `seance-claude-profile`
  overrides it to `:full`, because Claude can take it.
- `seance-claude-extra-args` — `'("--disallowed-tools" "Edit" "Write" "Bash")` if
  you want it answering questions rather than rearranging your repo.
- `seance-claude-lean` — on by default. Runs the CLI in a neutral directory so it
  doesn't drag your whole project's `CLAUDE.md` and hooks along for the ride.

## Tests

```sh
make test
```

The Lisp suite loads the contrib into a real SBCL and checks the snapshot it
produces. The Emacs suite stubs out `sly-eval` and checks everything up to the
point where bytes leave the building. Nothing spends a token.

If `make` can't find sly, tell it: `make test SLY_DIR=/path/to/sly`.

## Gotcha!

You didn't think it would be this easy. `slynk-backend:calls-who` returns `:NOT-IMPLEMENTED` on SBCL. 
It doesn't signal, it just hands you a keyword and lets you find out the hard way. So `callees` asks
`sb-introspect` directly instead. Without that the callee list is silently always
empty, and the one-hop expansion — the whole point of `:full` — never runs.

Ask me how I know (plz don't)

## License 

BSD-2-Clause. See [LICENSE](LICENSE).
