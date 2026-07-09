.POSIX:
.PHONY: test test-lisp test-elisp compile clean

EMACS ?= emacs
SBCL  ?= sbcl

# Where sly's elisp lives. Override if yours is elsewhere:
#   make test SLY_DIR=/path/to/sly
SLY_DIR ?= $(firstword $(wildcard \
	$(HOME)/.config/emacs/.local/straight/repos/sly \
	$(HOME)/.emacs.d/.local/straight/repos/sly \
	$(HOME)/.emacs.d/straight/repos/sly))

test: test-lisp test-elisp

## Image side: image-context, callers/callees, the conditions ring.
test-lisp:
	$(SBCL) --dynamic-space-size 2048 --script test/run-tests.lisp

## Emacs side: capture, assemble, and both transports' argument handling.
## Needs sly on the load-path.
test-elisp: guard-sly
	$(EMACS) -Q --batch \
	  -L . -L test -L "$(SLY_DIR)" -L "$(SLY_DIR)/lib" \
	  -l test/seance-test.el \
	  -l test/seance-claude-test.el \
	  -l test/seance-gptel-test.el \
	  -f ert-run-tests-batch-and-exit

## Byte-compile every package; warnings are failures. Core first.
compile: guard-sly
	$(EMACS) -Q --batch \
	  -L . -L "$(SLY_DIR)" -L "$(SLY_DIR)/lib" \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile seance.el seance-claude.el seance-gptel.el

guard-sly:
	@test -n "$(SLY_DIR)" || { \
	  echo "SLY_DIR is unset and sly was not found. Try: make test SLY_DIR=/path/to/sly"; \
	  exit 1; }

clean:
	rm -f *.elc test/*.elc test/*.fasl
