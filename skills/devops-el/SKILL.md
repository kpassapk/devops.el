---
name: devops-el
description: >
  Work with the user through an org file with devops.el: you write org-babel
  blocks, the user edits and runs them in Emacs, you follow each run in the
  execution log, read its output, and write the next blocks. Use when the
  task is done by running blocks in an org file with #+TARGET keywords, when
  a block left only a UUID or a truncated result in #+RESULTS, when the user
  says "done", a block failed, or "read the output", before writing the next
  block, or to check whether tangled config drifted from a server.
---

# devops.el

devops.el runs org-babel blocks on the target that a heading's tag names
(`#+TARGET: /ssh:host: (tag)`). With `devops-enable-session-async` on, a
block runs in an async shell session in the user's Emacs. `#+RESULTS:`
holds a placeholder UUID while it runs. A block that fails can keep that
UUID or a cut-short result. The full output, stderr included, stays in the
session buffer.

## The loop

1. You write org-babel blocks into the org file, under a heading whose
   tag names the target (see "Writing blocks").
2. The user reads them, edits them if they want, and runs them. You
   don't run them.
3. You learn of each run from the execution log (see "Following runs")
   and read its output with `devops-scripting-block-output`.
4. You tell the user what happened and write the next blocks, or a fix.

The user's edits are theirs: read the block as it is in the file before
you reason about its output, and don't overwrite what they changed.

## Talking to Emacs

You reach the user's Emacs with `emacsclient --eval`. The functions below
are in `devops-scripting.el`, which is for noninteractive use. They never
prompt: they take arguments where the interactive commands would ask,
and they return data. Wrap a call in `json-encode` to get JSON.

`emacsclient` prints the return value as a Lisp string: wrapped in
quotes, inner quotes escaped. That is itself a JSON string, so unwrap it
with `jq 'fromjson'`:

```
emacsclient --eval '(progn (require (quote devops-scripting))
  (json-encode (devops-scripting-block-output "<abs path>.org" <line>)))' \
  | jq 'fromjson'
```

Keyword keys and values lose their colon: `:status :same` comes out as
`"status": "same"`.

If the call fails:

| Error | Meaning |
|---|---|
| `can't find socket` / `connection refused` | No Emacs server. Ask the user to run `M-x server-start`. |
| `Cannot open load file ... devops-scripting` | devops.el isn't on the `load-path` of that Emacs. Ask the user how it is installed. |
| `Not an org buffer` | The file isn't org, or opened in another mode. |

## Writing blocks

A minimal file. Targets go at the top; a heading tag picks one:

```org
#+TITLE: Upgrade web servers
#+PROPERTY: header-args:sh :results output
#+TARGET: /ssh:web1.example.com: (web1)
#+TARGET: /ssh:deploy@web2.example.com|sudo::/etc/nginx (web2)

* Check disk                                                  :web1:

#+begin_src sh
df -h /
#+end_src

* Process locally                                             :web1:

#+name: pkgs
#+begin_src sh
dpkg -l | awk '/^ii/ {print $2}'
#+end_src

#+begin_src sh :stdin pkgs :target nil
grep -c nginx
#+end_src
```

- **A target** is a TRAMP prefix, a directory, or both. Multi-hop
  (`|sudo:`, `|podman:box:`) works. The tag in parentheses is what
  headings use. Read the file's existing `#+TARGET` lines before adding
  one, and reuse their tags.
- **The tag is inherited.** Blocks under a tagged heading, or any
  heading below it, run on that target: devops.el injects `:dir`. Give
  every new heading a tag, or put it under a tagged parent. A heading
  with no target tag runs locally.
- **One target tag per heading, counting inherited ones.** A `:web2:`
  heading under a `:web1:` parent has both. With two, the user gets a prompt on
  every run and `devops-scripting-block-output` needs a TAG. Write one
  heading per target instead.
- **`:results output`.** Set it in `#+PROPERTY` (as above) or on each
  shell block. Without it, a shell block's result is its exit status,
  and it runs synchronously.
- **`:target nil`** runs one block locally under a tagged heading, for
  example to process a remote block's output with `:stdin`. An explicit
  `:dir` also wins over the tag.
- **Sessions are stateful.** With async sessions on, `cd`, `export` and
  activated virtualenvs carry over from one block to the next. Write
  blocks that don't depend on the ones above them, so a block that
  passes still passes after `M-x devops-restart-session`.
- **Tangling.** `:tangle PATH` under a tagged heading writes to the
  target when the user runs `devops-tangle`. A relative PATH lands under
  the target's directory; `/etc/f` and `~/f` are absolute on the target's
  machine. `:tangle yes`, a path with its own TRAMP prefix, or
  `:target nil` keep org's own destination. `:mkdirp`, `:shebang` and
  `:tangle-mode` work as in org.
- **References.** `:var x=name`, `:stdin name` and `<<name()>>` (with
  `:noweb yes`) work as in org, and run synchronously.
- **Dynamic targets.** `#+TARGET: <<server()>> (app)` names the host
  with the value of the `server` block, resolved when a block runs. Use
  it when the host is an input, not a constant.
- **Tools.** A project's `tools.org` can expose named blocks as tools
  for `#+call: name(arg="x")`. List the loaded ones with
  `(devops-org-tool-blocks)` (optional REGEXP) before writing your own.

Org's built-in header arguments mean what org's manual says. devops.el
adds only `:target`.

## Editing the org file

The user has the file open in Emacs. Before you write to it on disk,
check that the buffer has no unsaved edits:

```
emacsclient --eval '(let ((b (find-buffer-visiting "<abs path>.org")))
  (and b (buffer-modified-p b)))'
```

`t` means unsaved edits: ask the user to save, and don't write. After you
write, reload the buffer so it matches the disk:

```
emacsclient --eval '(let ((b (find-buffer-visiting "<abs path>.org")))
  (when b (with-current-buffer b (revert-buffer t t t))))'
```

Add blocks; don't rewrite blocks the user already ran or edited. Leave
`#+RESULTS:` alone.

## Block output

`(devops-scripting-block-output FILE LINE &optional TAG)`. LINE can be
any line of the block. It returns:

| Key | Meaning |
|---|---|
| `session` | the session buffer's name |
| `status` | `done`, `running`, `not-found` (the session never ran this block), `no-session` |
| `id` | the run's async ID |
| `source` | where `output` came from: `session`, `results`, or null |
| `output` | what the block printed |
| `result` | the block's `#+RESULTS:` as plain text |

The session is read first: it has the full output, stderr included. When
the session is gone or never ran the block (a synchronous block, a
restarted session), `output` comes from `#+RESULTS:` instead. A UUID
placeholder left there is not output, so `output` is null.

When the heading has more than one target tag, the call signals an error
that names the tags. Pass one as TAG.

Nothing is run, except that a dynamic target (`#+TARGET: <<name()>>`) runs
its block to resolve the session name, as the block itself did.

What to do next:

| You see | Do |
|---|---|
| `done`, output looks right | Say so in a line, write the next blocks. |
| `done`, output shows an error | Explain the cause, write a fixed block below (don't edit theirs unless asked). |
| `running` for a long time | Check `devops-scripting-sessions`: it may be `waiting` at a prompt. |
| `not-found` or `no-session`, `source` `results` | A synchronous run or a restarted session: read `output`. |
| `output` null, `result` a UUID | The run died before its result arrived. Ask the user to look at the session (`M-x devops-goto-session`). |
| error naming tags | Pass one as TAG, or ask which target the user meant. |

## Sessions

`(devops-scripting-sessions)` lists the live async sessions: `name`,
`directory` (the target), `state` (`idle`, `running`, `waiting`),
`prompt`, and `id`.

`waiting` means the session stopped at a prompt that is not its own:
`[sudo] password`, an ssh host key, an `apt` question. Never answer it.
Tell the user which session is waiting and what it asks. The user answers
it with `M-x devops-goto-session` on the block's heading.

## Following runs

With `devops-mode` on and `devops-execution-log` set to a file (usually
`~/.cache/devops/executions.jsonl`), Emacs appends a JSON line to that
file when the user runs a block, and once more when an async block's
result arrives. Watch that file instead of
waiting for the user to say "done".

Check that the mode is on, and where it logs:

```
emacsclient --eval '(progn (require (quote devops))
  (list devops-mode devops-execution-log))'
```

If either is nil, ask the user to turn on `devops-mode` and set
`devops-execution-log` (e.g. `M-x customize-variable`).
Don't turn it on yourself. Until it is on, wait for the user to say
"done", then call `devops-scripting-block-output` on the blocks you wrote.

Each line is the block's `devops-scripting-block-output` answer (above), plus:

| Key | Meaning |
|---|---|
| `event` | `execute` when the block ran, `result` when an async result arrived |
| `time` | when the line was written |
| `file` | the org file, or null for a buffer with no file |
| `buffer` | the org buffer's name |
| `line` | the block's `#+begin_src` line |
| `error` | why `devops-scripting-block-output` failed (no target, or two), with `result` from `#+RESULTS:` |

An async block logs `execute` with `status` `running`, then `result` with
`status` `done`. A synchronous block logs only `execute`. Runs that
devops.el makes on its own (references, dynamic targets, tangling) are
not logged.

The log is shared by every Emacs buffer, so filter on the files you
work on. Start a background monitor (in Claude Code, the Monitor tool)
that prints one short line per run:

```
tail -n0 -F ~/.cache/devops/executions.jsonl \
  | jq --unbuffered -rc --arg dir "$PWD/" \
      'select((.file // "") | startswith($dir))
       | "\(.event) \(.status // "error") \(.file):\(.line)"'
```

On each line, read the full entry or call
`devops-scripting-block-output` for that file and line, check the
output, tell the user what happened, and write the next blocks. Don't
print `output` into the monitor: it can be long and can hold secrets.

## Drift

Drift compares what the org file would tangle with what is on each
target. It is in `devops-drift.el`:

| Function | Checks |
|---|---|
| `(devops-drift-all FILE)` | every target-tagged heading |
| `(devops-drift-headline FILE "Heading title")` | one subtree, by title |
| `(devops-drift-custom-id FILE "id")` | one subtree, by `CUSTOM_ID` |

Each returns one entry per tangled file: `status` (`same`, `drift`,
`missing`, `error`), `tag`, `path`, `remote`, `target`, `detail`, and
`diff` (a unified diff when drifting). `(devops-drift-ok-p ENTRIES)` is
non-nil when all are `same`.

```
emacsclient --eval '(progn (require (quote devops-drift))
  (json-encode (devops-drift-all "<abs path>.org")))' | jq 'fromjson'
```

A drift check reads every target over TRAMP, and expanding `<<name()>>`
references runs those blocks. Ask the user before you run one. Tangling
(`devops-tangle`) writes to servers: that is the user's to run.

## Rules

- Never run blocks, tangle, or write `#+RESULTS:` yourself. The user
  runs blocks.
- Read output; don't print secrets from it. If the output holds a
  credential, say that it does without quoting it.
