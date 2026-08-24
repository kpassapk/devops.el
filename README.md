# devops.el: Infrastructure as an org file

By following some conventions, this package helps you to manage infrastructure with org mode. Infrastructure here may be servers, containers, serverless functions, DNS... up to you.

## Installation

```
(use-package devops
  :ensure t
  :vc (:url "https://github.com/kpassapk/devops.el"))
```

## Why?

Org mode, built into emacs, provides support for literate programming via Org Babel.  Org mode can also "tangle" its source code blocks, pushing them out as individual files in the file system.  This is a pretty good base for [literate devops](https://howardism.org/Technical/Emacs/literate-devops.html), especially if we use some little-known features of org mode:

### 1. Remote commands in org-babel

Emacs can run any command in a code block remotely, if it has a remote `:dir` property:

```
#+begin_src sh :dir /ssh:server-user@example.com:
whoami
#+end_src

: server-user
```

See the [org-babel-examples](https://github.com/dfeich/org-babel-examples/blob/master/shell/shell-babel.org#41-dir) repo for more.

### 2. Tangling remotely

Tangling also works remotely when the `:tangle` header points to a server.

### 3. Noweb can execute source blocks

This is not immediately obvious: Noweb, which allows you to splice in named blocks by referring to them in double angle brackets (`<< ... >>`), can also execute source code blocks and interpolate the result.

This is useful for handling secrets:

```
#+NAME: API-KEY
#+BEGIN_SRC sh
op item get "Some Item" --fields label=credential --reveal
#+END_SRC

#+BEGIN_SRC yaml :tangle /ssh:server-user@example.com:.config/file.yaml :noweb yes
---
api-key: <<API-KEY()>>
#+END_SRC

```

(Note the parentheses in `API-KEY()`).

## Limitations

There are some shortcomings and annoyances, however:

1. Long-running commands (like `apt-get update`) can lock up emacs for an extended period of time. In devops workflows, most of the work is remote, so the experience is... choppy. Even worse, if a command asks for input your emacs might become unresponsive.

2. When describing an actual production environment, it's easy to end up with duplicate `/ssh:someuser@someserver:somedirectory/...` `:dir` properties all over the file. This is difficult to scan.

3. Each source block can only have a single `:dir`. This makes the following typical use cases difficult:

  - Uploading the same content to multiple servers
  - Running the same command on multiple servers

4. Tangling ignores `:dir`. If you are uploading a file and then running a server command, now the server needs to go in two places. (`:dir` and `:tangle`)

5. tangling scope is either too small or to wide. The `org-babel-tangle` function tangles the entire buffer by default, or alternatively a single source code block. Tangling an entire buffer might be risky, and tangling a single block gets very annoying.

This library provides functionality to better support devops-like workflows. It does this by applying some conventions on top of org mode.

## Devops-flavored Org Mode

This package works with "targets" defined at the top of the file, which also appear in heading tags:

```
#+TARGET: /ssh:example1.com: (server1)
#+TARGET: /ssh:example2.com: (server2)

* Do something on server1               :server1:
* Do something on server2               :server2:
```

Source code blocks under a heading tag that matches a target (a "target tag") execute in on the server, instead of locally:

```
#+TARGET: /ssh:example1.com: (server1)
#+TARGET: /ssh:example2.com: (server2)

* Do something on server1               :server1:

#+BEGIN_SRC sh
hostname
#+END_SRC

: example1.com

* Do something on server2               :server2:

#+BEGIN_SRC sh
hostname
#+END_SRC

: example2.com
```

Note that the above source code blocks do not have a `:dir` property. It is set implicitly to the
target server (`example1.com` / `example2.com`) based on the heading tag (`server1` / `server2`).

You can use more than one tag, if a command has multiple targets.

```
* Do something on both server1 and server2             :server1:server2:

#+BEGIN_SRC sh
hostname
#+END_SRC
```

At the moment, if you have more than one server tag, and you press `C-c C-c`, you will be prompted
for the server using completing-read. In the future, it would be nice to run multiple commands in
parallel, though I haven't identified yet how to best do this.

### Tangling

Tangling obeys the same targets. This will create `~/foo.txt` in `server1`:

```
* Upload a file to server1                              :server1:

#+BEGIN_SRC txt :tangle "~/foo.txt"
... contents of foo.xt ...
#+END_SRC
```

You can tangle a file to multiple servers. This will create `~/foo.txt` on both
`server1` and `server2`:

```
* Upload a file to server1 and server2                  :server1:server2:

#+BEGIN_SRC txt :tangle "~/foo.txt"
... contents of foo.xt ...
#+END_SRC
```

Given

`#+TARGET: /ssh:example1.com:/opt/app (server1)`,

`:tangle` resolves to a path within the host:

| `:tangle`        | resolves to                               |
|------------------|-------------------------------------------|
| `foo.txt`        | `/ssh:example1.com:/opt/app/foo.txt`      |
| `conf/foo.txt`   | `/ssh:example1.com:/opt/app/conf/foo.txt` |
| `./conf/foo.txt` | same as above — the `./` is dropped       |
| `/etc/foo.txt`   | `/ssh:example1.com:/etc/foo.txt`          |
| `~/foo.txt`      | `/ssh:example1.com:~/foo.txt`             |

### Disabling with :target nil

Sometimes you may want to "turn off" the target for a single block. This is useful for locally
processing the output of the code block.

For example, let's say we have a `TARGET` that points to a Podman container in a server:

```
#+TARGET: /ssh:server.com|podman:my-container: (container)
```

We can chain together a remote command and a local processing step as follows:

```
* Service status                                      :container:

#+NAME: status
#+BEGIN_SRC sh
some-cli status --json
#+END_SRC

#+BEGIN_SRC sh :stdin status :target nil
jq -r '.services
  | to_entries[]
  | select(.value.state != "running")
  | "\(.key)\t\(.value.state)\t\(.value.health)"'
#+END_SRC
```

This will work even if the `jq` command is not installed in the container :)

## Drift detection

`devops-drift` shows a `*Drift Report*` buffer, telling you whtether code blocks and their 
tangle targets have identical content. 

```
  ok       server1   /ssh:example1.com:~/foo.txt
  DRIFT    server1   /ssh:example1.com:~/app.conf
  MISSING  server2   /ssh:example2.com:~/app.conf
```

The following keys are active in the diff report buffer:

| Key       | Action                                    |
|-----------|-------------------------------------------|
| `RET`     | jump to the source block behind the row   |
| `=`       | ediff the target against the tangled file |
| `d`       | diff them                                 |
| `g`       | re-run the check                          |

There are also noninteractive variants - `devops-drift-{all|headline|custom-id}`
for scripting.

## Long running commands

There are seveeral options for running background commands in emacs asynchronously:

1. [ob-async](https://github.com/astahlman/ob-async)
2. [ob-screen](https://howardism.org/Technical/Emacs/literate-devops.html#fnr.4)
3. [detached.el](https://sr.ht/~niklaseklund/detached.el)

To avoid dependnecies, `devops.el` uses built-in features and tries to make them more 
convenient.

### Shell async sessions (experimental)

In recent org mode versions, (Org 9.7+), executing source blocks with `:session foo :async yes` will print a placeholder. Once the background command finishes, the placehodler gets replaced with the output.

When `devops-enable-session-async` is enabled, blocks are executed as if you had written 
the `session` and `async` headers yourself. For example,

```
#+TARGET: /ssh:example.com: (example)

* Update packages :example:

#+begin_src sh :results output
  apt-get update
#+end_src
```

injects these `dir`, `session` and `async` headers:

```
#+begin_src sh :results output :dir /ssh:example.com: :session devops:example :async yes
  apt-get update
#+end_src
```

(Only works with `:results output` I think. You will probably want to set this at top of file.
See [](examples/1_commands.org))

This is off by default because it makes blocks stateful. Commands like `cd` now survive 
from one block to the next. To enable, set

```elisp
(setq devops-enable-session-async t)
```

Session names come from `devops-session-name-function`, which defaults to
`devops:<tag>`. A session name is a buffer name in a single global namespace, so
if two org files use the same tag for different hosts, set this to a function
that also folds in the project, target or buffer name.

### Terminal DWIM command

I often like using a separate terminal to run most commands, instead of emacs.
This package provides a `devops-open-terminal-dwim` command, which opens the current source block in a terminal. (Only `ghostty` supported at the moment, but more terminals planned.)

Any `var` references become environment variables loaded into the (usually remote) 
shell. The source block content is copied to the clipboard, so you can do 
`devops-open-terminal-dwim`, then paste, and you will be running the command at the correct location.

## devops-lob

`devops.el` uses org's Library of Babel (LOB) to save commonly used server commands. 

Any project with a `tools.org` at its root can expose named org-babel blocks as reusable tools. `devops-lob` loads and unloads these per-project.

```elisp
(use-package devops-lob
  :ensure t
  :vc (:url "https://github.com/kpasaspk/devops.el"
       :main-file "devops-lob.el")
  :hook
  (after-init . (lambda () (devops-lob-auto-mode 1))))
```

With `devops-lob-auto-mode` enabled, opening any file in a project that has `tools.org` automatically loads its named blocks into the org-babel Library of Babel.

### tools.org commands

| Command                           | Description                                       |
|-----------------------------------|---------------------------------------------------|
| `devops-lob-load-project-tools`   | Load `tools.org` from current project root        |
| `devops-lob-unload-project-tools` | Remove current project's tools from LOB           |
| `devops-lob-reload-project-tools` | Unload then reload (pick up edits to `tools.org`) |
| `devops-lob-unload-all`           | Remove all devops-tracked LOB entries             |

Inspect loaded tools:

```elisp
(devops-org-tool-blocks)          ; all entries
(devops-org-tool-blocks "deploy") ; filtered by regexp
```
