# devops.el: Org-based devops

"everything is an org file"
                - Socrates

By following some conventions, this package helps you to manage infrastructure as a set of org files. Infrastructure here may be servers, containers, serverless functions, DNS... up to you.

Org mode, built into emacs, provides support for literate programming via Org Babel. 
Org mode can also "tangle" its source code blocks, pushing them out as individual files in the file system. 
In both cases, the org mode notebook is the surce of truth, managing external effects.

This is precisely the devops philosophy: keep a single, versioned artifact, which reflects the state of external infrastructure. And three little-known features make org-babel work particularly well:

- code blocks run remotely by setting a remote `:dir` property.
- tangling works remotely when the `:tangle` header points to a server.
- noweb can call functions. This gives you a way to fetch secrets such as an `<<API_KEY()>>`s.

There are some shortcomings and annoyances, however:

1. Long-running commands (like `apt-get update`) can lock up emacs for an extended period of time. In devops workflows, most of the work is remote, so the experience is... choppy. Even worse, if a command asks for input your emacs might become unresponsive.

2. When describing an actual production environment, it's easy to end up with duplicate `/ssh:someuser@someserver:somedirectory/...` `:dir` properties all over the file. This is extremely difficult to scan.

3. Each source block can only  have a single `:dir`. This makes the following typical use cases difficult:

  - Uploading the same content on multiple servers
  - Running the same command on multiple servers

4. Tangling socpe is either too small or to wide. The `org-babel-tangle` function tangles the entire buffer by default, or alternatively a single source code block. Tangling an entire buffer might be risky, and tangling a single block gets very annoying.

This library provides functionality to better support devops-like workflows. It does this by applying some conventions on top of org mode.

## Target Tags

An org file can define "targets". These appear in heading tags:

```
#+TARGET: /ssh:example1.com: (server1)
#+TARGET: /ssh:example2.com: (server2)

* Do something on server1               :server1:
* Do something on server2               :server2:
```

Source code blocks under a heading tag that matches a target (a "target tag") execute in on the server, instead of locally.

Tangling obeys the same target tags. This will create `foo.txt` in `server1`:

```
* Do something on server1               :server1:

#+BEGIN_SRC txt :tangle "~/foo.txt"
...
#+END_SRC
```

## Terminal DWIM command

This package provides a `devops-open-terminal-dwim` command, which opens the current source block in a terminal.  `var` references become environment variables, and the source block content is copied to the clipboard.

## Requirements

- magit

## Installing

```elisp
(use-package devops
  :ensure t
  :vc (:url "https://github.com/unifica-ai/devops.el"))
```

## devops-lob

Any project with a `tools.org` at its root can expose named org-babel blocks as reusable tools. `devops-lob` loads and tracks these per-project so they don't pollute other projects.

### Setup

```elisp
(use-package devops
  :ensure t
  :vc (:url "https://github.com/unifica-ai/devops.el")
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

### Commands

| Command | Description |
|---------|-------------|
| `devops-lob-load-project-tools` | Load `tools.org` from current project root |
| `devops-lob-unload-project-tools` | Remove current project's tools from LOB |
| `devops-lob-reload-project-tools` | Unload then reload (pick up edits to `tools.org`) |
| `devops-lob-unload-all` | Remove all devops-tracked LOB entries |

Inspect loaded tools:

```elisp
(devops-org-tool-blocks)          ; all entries
(devops-org-tool-blocks "deploy") ; filtered by regexp
```
