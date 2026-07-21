EMACS ?= emacs
# Watchdog: batch ERT can hang on stdin/loops. Kill after TIMEOUT seconds.
TIMEOUT ?= 120

EL := devops.el devops-lob.el devops-drift.el
TEST := devops-test.el

BATCH := $(EMACS) --batch -L .
WATCHDOG := perl -e 'alarm shift; exec @ARGV' $(TIMEOUT)

.PHONY: test test-% compile clean

## Run full ERT suite (mirrors CI)
test:
	$(WATCHDOG) $(BATCH) \
	  --eval "(require 'devops)" \
	  --eval "(require 'devops-test)" \
	  -f ert-run-tests-batch-and-exit

## Run tests matching a regex: make test-PATTERN
test-%:
	$(WATCHDOG) $(BATCH) \
	  --eval "(require 'devops)" \
	  --eval "(require 'devops-test)" \
	  --eval "(ert-run-tests-batch-and-exit \"$*\")"

## Byte-compile sources, treat warnings as errors
compile:
	$(BATCH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(EL) $(TEST)

clean:
	rm -f *.elc
