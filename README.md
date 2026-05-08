# devops.el: Org-based devops

This package allows you to provision and manage infra using org mode notebooks

## Requirements

- magit

## Installing

```elisp
(use-package devops
  :ensure t
  :vc (:url "https://github.com/unifica-ai/devops.el"))
```

## tools.org — Per-project Library of Babel

Any project with a `tools.org` at its root can expose named org-babel blocks as reusable tools. `devops-lob` loads and tracks these per-project so they don't pollute other projects.

### Setup

```elisp
(require 'devops-lob)
(devops-lob-auto-mode 1)  ; auto-load on find-file
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
