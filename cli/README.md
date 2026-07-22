# orgrun

A minimal [runme.dev](https://runme.dev)-style task runner for org-mode
files, built on [babashka](https://babashka.org) and the
[kpassapk/emacs](https://github.com/kpassapk/pod-kpassapk-emacs) pod.

All org parsing and block execution happens inside the pod (real org-mode +
org-babel in a batch Emacs); the script only formats output and dispatches
subcommands with `babashka.cli`.

## Usage

```
orgrun list  [--filename FILE] [--allow-unnamed] [--json]
orgrun run   <name>... | --index N | --all  [--filename FILE]
orgrun print <name>  [--filename FILE]
```

- `list` (alias `ls`) prints a runme-style table: `NAME FILE FIRST COMMAND
  DESCRIPTION NAMED`. The description is the enclosing heading's title.
  Blocks without a `#+name:` are hidden unless `--allow-unnamed`.
- `run` executes blocks through org-babel (`org/execute`), so header args
  like `:dir` — including TRAMP remotes — behave exactly as in Emacs.
  Multiple names run sequentially; a failing block makes orgrun exit 1.
- `print` shows a block's body without running it.

Unnamed blocks get a name derived from their first command
(`echo hello` → `echo-hello`, duplicates get `-2`, `-3` …), matching
runme's convention; `run`/`print` fall back to these names when a lookup
by explicit name fails.

Default file is `README.org` (runme defaults to `README.md`).

## Pod resolution

`ORGRUN_POD` may point at a pod binary. Otherwise a repo checkout at
`~/src/github.com/kpassapk/pod-kpassapk-emacs/target/release/` is preferred
(it serves its `resources/*.el` live, so unreleased pod changes apply),
falling back to registry pod `kpassapk/emacs` 0.3.1.

Note: exit-code propagation for failing blocks relies on an unreleased pod
change (`org/execute` throwing on non-zero exit); with the registry 0.3.1
pod, failing shell blocks are reported as successful with empty output.

## Example

```
$ cli/orgrun list -f cli/example.org --allow-unnamed
NAME          FILE             FIRST COMMAND     DESCRIPTION  NAMED
hello         cli/example.org  echo hello world  Greetings    Yes
echo-unnamed  cli/example.org  echo unnamed one  Greetings    No
add           cli/example.org  (+ 40 2)          Math         Yes
echo-dup      cli/example.org  echo dup          Math         No
echo-dup-2    cli/example.org  echo dup          Math         No
boom          cli/example.org  exit 3            Failing      Yes

$ cli/orgrun run hello -f cli/example.org
► Running task hello...
hello world
► ✓ Task hello exited with code 0

$ cli/orgrun run boom -f cli/example.org; echo $?
► Running task boom...
► ✗ Task boom exited with code 3
1
```
