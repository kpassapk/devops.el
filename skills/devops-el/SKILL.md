---
name: devops-el
description: >
  Read what an org-babel block printed in its devops.el async session, and
  check whether a session is still running or waiting on a prompt. Use when
  a block in an org file with #+TARGET keywords left only a UUID or a
  truncated result in #+RESULTS, when the user says a block failed or "read
  the output", or before asking the user to run the next block.
---

# devops.el

devops.el runs org-babel blocks on the target that a heading's tag names
(`#+TARGET: /ssh:host: (tag)`). With `devops-enable-session-async` on, a
block runs in an async shell session in the user's Emacs. `#+RESULTS:`
holds a placeholder UUID while it runs. A block that fails can keep that
UUID or a cut-short result. The full output, stderr included, stays in the
session buffer.

You reach that Emacs with `emacsclient --eval`. The functions below are in
`devops-agentic.el`. They take arguments where the interactive
commands would ask, and they return data. Wrap a call in `json-encode`
to get JSON:

```
emacsclient --eval '(progn (require (quote devops-agentic))
  (json-encode (devops-block-output "<abs path>.org" <line>)))'
```

## Block output

`(devops-block-output FILE LINE &optional TAG)`. LINE can be any line of
the block. It returns:

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

## Sessions

`(devops-sessions)` lists the live async sessions: `name`, `directory`
(the target), `state` (`idle`, `running`, `waiting`), `prompt`, and `id`.

`waiting` means the session stopped at a prompt that is not its own:
`[sudo] password`, an ssh host key, an `apt` question. Never answer it.
Tell the user which session is waiting and what it asks. The user answers
it with `M-x devops-goto-session` on the block's heading.

## Rules

- Never write `#+RESULTS:` yourself. The user runs blocks.
- Read output; don't print secrets from it. If the output holds a
  credential, say that it does without quoting it.
