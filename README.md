# devops.el: Infrastructure as an org file

By following some conventions, this package helps you to manage infrastructure as a set of org files. Infrastructure here may be servers, containers, serverless functions, DNS... up to you.

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

(Note the parenteses in `API-KEY()`).

## Limitations

There are some shortcomings and annoyances, however:

1. Long-running commands (like `apt-get update`) can lock up emacs for an extended period of time. In devops workflows, most of the work is remote, so the experience is... choppy. Even worse, if a command asks for input your emacs might become unresponsive.

2. When describing an actual production environment, it's easy to end up with duplicate `/ssh:someuser@someserver:somedirectory/...` `:dir` properties all over the file. This is extremely difficult to scan.

3. Each source block can only  have a single `:dir`. This makes the following typical use cases difficult:

  - Uploading the same content on multiple servers
  - Running the same command on multiple servers

4. Tangling socpe is either too small or to wide. The `org-babel-tangle` function tangles the entire buffer by default, or alternatively a single source code block. Tangling an entire buffer might be risky, and tangling a single block gets very annoying.

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

Tangling obeys the same target tags. This will create `~/foo.txt` in `server1`:

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

## Long-running commands

Long commands such as `apt-get update` can lock up emacs. There are several worakrounds, from 
using sessions and `:async yes` (built in), to [ob-async](https://github.com/astahlman/ob-async), and probably others. YMMV.

[ob-screen]: https://howardism.org/Technical/Emacs/literate-devops.html#fnr.4

I like using a separate terminal to run most commands, instead of emacs.  This package provides a `devops-open-terminal-dwim` command, which opens the current source block in a terminal. (Only `ghostty` supported at the moment, but more terminals planned.)

Any `var` references become environment variables loaded into the (usually remote) remote shell. The source block content is copied to the clipboard, so you can do `devops-open-terminal-dwim`, then 
paste, and you will be running the command at the correct location.

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

### tools.org format

```org
#+title: Tools

#+name: deploy
#+begin_src sh :var env="staging"
./deploy.sh $env
#+end_src

#+name: health-check
#+begin_src sh :var host="localhost"
curl -sf http://$host/health
#+end_src
```

Call tools from any org buffer:

```org
#+call: deploy(env="production")

#+call: health-check(host="app.example.com")
```

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
