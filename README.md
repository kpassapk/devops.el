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

(Note the parentheses in `API-KEY()`).

## Limitations

There are some shortcomings and annoyances, however:

1. Long-running commands (like `apt-get update`) can lock up emacs for an extended period of time. In devops workflows, most of the work is remote, so the experience is... choppy. Even worse, if a command asks for input your emacs might become unresponsive.

2. When describing an actual production environment, it's easy to end up with duplicate `/ssh:someuser@someserver:somedirectory/...` `:dir` properties all over the file. This is extremely difficult to scan.

3. Each source block can only have a single `:dir`. This makes the following typical use cases difficult:

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

### Disabling with :target nil

Sometimes you may want to "turn off" the target for a single block with `:target nil`.

As an example, let's say we have a container `TARGET`:

```
#+TARGET: /ssh:server.com|podman:my-container: (container)
```

We can run a command and then use filter the results locally:

```
* Tailscale status                                      :container:

#+NAME: status
#+BEGIN_SRC sh
some-cli status --json
#+END_SRC

#+BEGIN_SRC sh :stdin status :target nil
jq -r '.services | keys'
#+END_SRC
```

This will work even if the `jq` command was not installed in the container, since we added
`:target nil` to the second block.

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

## Drift detection

Tangling pushes the org file out to its targets. `devops-drift` asks the
opposite question: does what is on the target still match what the org file
says? The heading is tangled to a local temp directory first — so noweb, including
per-server noweb, resolves exactly as a real tangle would — and each tangled file
is compared byte-for-byte with its counterpart on the target. Nothing is written
to a target: a drift check is read-only.

`devops-drift` (`C-u` for the whole buffer) shows a `*Drift Report*` buffer, one
row per file:

```
  ok       server1   /ssh:example1.com:~/foo.txt
  DRIFT    server1   /ssh:example1.com:~/app.conf
  MISSING  server2   /ssh:example2.com:~/app.conf
```

| Key       | Action                                    |
|-----------|-------------------------------------------|
| `RET`     | jump to the source block behind the row   |
| `=`       | ediff the target against the tangled file |
| `d`       | diff them                                 |
| `g`       | re-run the check                          |

### Checking drift from a source block

The report is a buffer you read and then lose. A check written into the org file
stays with the notes explaining it, and its result is part of the document:

```org
#+begin_src emacs-lisp :results output
(princ (devops-drift-summary (devops-drift-headline "servers/box.org" "Caddy")))
#+end_src

#+RESULTS:
: DRIFT    server1   /ssh:example1.com:~/caddy_etc/Caddyfile
:
: --- /ssh:example1.com:~/caddy_etc/Caddyfile
: +++ ~/caddy_etc/Caddyfile (server1)
: @@ -78,6 +78,11 @@
: ...
```

| Function                              | Checks                                          |
|---------------------------------------|-------------------------------------------------|
| `(devops-drift-all source)`           | every target-tagged heading                     |
| `(devops-drift-headline source title)` | the subtree titled `title`                     |
| `(devops-drift-custom-id source id)`  | the subtree whose `CUSTOM_ID` is `id`           |

`source` is an org buffer or a file name. All three return the same data: one
alist per tangled file, and no temp directory left behind.

| Key       | Value                                                        |
|-----------|--------------------------------------------------------------|
| `:status` | `:same`, `:drift`, `:missing` (no file there) or `:error`     |
| `:tag`    | the target tag this file was tangled for                      |
| `:path`   | the block's `:tangle` value                                   |
| `:remote` | where that path lands on the target                           |
| `:target` | the `#+TARGET` value                                          |
| `:detail` | the error message, for `:error`                               |
| `:diff`   | unified diff, target first, for `:drift`                      |

`devops-drift-summary` formats that list as the text above,
`devops-drift-table` as an org table (for `:results table`), and
`devops-drift-ok-p` reduces it to a boolean — nil for an empty list, since a
check that compared nothing has shown nothing.

### cljbang.el

If you use [cljbang.el](https://github.com/borkdude/cljbang.el), the drift API returns maps:

```clojure
(require '[devops-drift :as drift])

(->> (drift/all "servers/box.org")
     (remove #(= (:status %) :same))
     (map (fn [{:keys [path status]}] [path status])))
;; => (["app.conf" :drift])
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
