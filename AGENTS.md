# AGENTS.md

devops.el runs and tangles org-babel source blocks on local and remote
machines. A `#+TARGET: /ssh:host: (tag)` keyword maps a heading tag to a
TRAMP prefix or directory, and blocks under a heading with that tag run
there (`:dir` is injected) or tangle there (`:tangle` paths are redirected).

## Layout

| File | What it is |
|---|---|
| `devops.el` | Core: `#+TARGET` parsing, `:dir`/`:session` injection, `devops-tangle`, terminal DWIM |
| `devops-drift.el` | `devops-drift`: tangles to a temp dir and compares with each target |
| `devops-lob.el` | Loads a project's `tools.org` into the Library of Babel |
| `devops-test.el` | The whole ERT suite |
| `decisions/` | Decision records (`NN-topic.org`). Read the relevant one before you change a design it covers. |
| `examples/` | Org files that show each feature. Keep them in step with behavior. |

## Commands

```sh
make test            # full ERT suite (same as CI)
make test-PATTERN    # tests whose name matches PATTERN, e.g. make test-drift
make compile         # byte-compile, warnings are errors
make clean           # remove .elc
```

Run `make compile` and `make test` before calling something done. CI runs
the suite on Emacs 29.4 and 30.1.

`make` puts batch Emacs under a watchdog (`perl -e 'alarm shift; exec
@ARGV' N`), because ERT in batch mode can hang on a stdin prompt or a loop.
macOS has no `timeout`, so wrap any ad-hoc `emacs --batch` run the same way.
Clean up stale `.elc` files with `make clean`. Emacs loads a stale `.elc`
in preference to the edited source.

## Compatibility

- `Package-Requires: ((emacs "29.1"))`, so the baseline is Org 9.6.
  Anything newer, such as `ob-shell` `:async` in Org 9.7, has to check for
  support and degrade (see `devops-enable-session-async`). Don't raise the
  requirement for an optional feature.
- `(require 'tramp)` is explicit because tests run under `emacs -Q`, where
  the autoloads aren't enough.

## How tangling works

`devops-tangle` narrows the org buffer to the heading and calls
`org-babel-tangle` there. It never edits the org text, and it never saves
the buffer: `save-buffer` is removed from `org-babel-pre-tangle-hook` for
the duration.

Paths are redirected at the data level. A `:filter-return` advice on
`org-babel-tangle-collect-blocks` rewrites each block's destination file in
org's write plan when `devops--tangle-redirect` is bound, and does nothing
otherwise. `devops--tangle-destination` (for tangling) and
`devops--drift-destination` (for the drift check) are pure functions that
decide each destination. Test new path rules there. Org still does the
writing itself (`:mkdirp`, `:shebang`, `:tangle-mode`). The background is in
`decisions/01-tangling.org`.

## Conventions

- **Org semantics are upstream's.** Don't reinterpret an org built-in
  header argument or keyword. Add a namespaced one instead, as `:target`
  does.
- **Delete dead code.** When code becomes unused, remove it and its tests.
  Don't shim or deprecate.
- **Docstrings explain why.** The existing style is full sentences that
  give the reason and the edge case, e.g. why a path is expanded, or what
  goes wrong without a step. Match it. checkdoc must stay clean (quote
  symbols as `` `sym' ``, first line a complete sentence). The package is
  headed for MELPA.
- **Advice changes as little as it can.** An advice on an org function
  should change only what devops needs. When that only matters inside a
  devops command, make it a no-op unless a dynamic variable is bound, as
  `devops--redirect-tangle-plan` does with `devops--tangle-redirect`.
- **Scripted evaluation is synchronous.** Anything that reads a block's
  result (tangling, drift, `:var` and noweb references) runs inside
  `devops-with-sync`, because under `:async` the result is a placeholder
  UUID.
- **Tests never touch a remote.** Use `devops-test--with-org` for buffer
  text and `devops-test--with-local-target` for a temp directory that
  stands in for a server. A test must not leave files in the working
  directory.
- New `.el` files carry the GPL header and an `Assisted-by:` line, like the
  existing ones.
