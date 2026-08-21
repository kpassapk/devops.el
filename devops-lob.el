;;; devops-lob.el --- Per-project Library-of-Babel management -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kyle S Passarelli

;; Author: Kyle S Passarelli <kyle.passarelli@gmail.com>
;; URL: https://github.com/kpassapk/devops.el

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Load a project's `tools.org' into the Library of Babel, so its named
;; src blocks are callable from any org file in that project, and unload
;; them again when the project is left.

;;; Code:

(require 'ob-lob)
(require 'project)

(defvar devops--lob-project-registry nil
  "Alist of (ROOT-STRING . (SYMBOL...)) for loaded project LOB tools.")

(defun devops--lob-names-in-file (file)
  "Return symbols of named src blocks in FILE without modifying LOB."
  (let (names)
    (org-babel-map-src-blocks file
      (when-let* ((name (nth 4 (org-babel-get-src-block-info 'no-eval))))
        (push (intern name) names)))
    (nreverse names)))

(defvar devops--lob-loading nil
  "Non-nil while a tools.org load is in progress.
Reading tools.org visits it, which fires `find-file-hook' before the
project is registered; without this guard `devops-lob-auto-mode' would
re-enter the load and register the project twice.")

(defun devops--lob-do-load (root tools-file)
  "Ingest TOOLS-FILE and register entry names under ROOT."
  (let* ((devops--lob-loading t)
         (names (devops--lob-names-in-file tools-file)))
    (org-babel-lob-ingest tools-file)
    (push (cons root names) devops--lob-project-registry)
    (message "devops: loaded %d LOB entries from %s" (length names) tools-file)))

;;;###autoload
(defun devops-lob-load-project-tools ()
  "Load tools.org from current project root into the org-babel LOB."
  (interactive)
  (if-let* ((proj (project-current nil))
            (root (project-root proj))
            (file (expand-file-name "tools.org" root)))
      (cond
       ((assoc root devops--lob-project-registry)
        (message "devops: already loaded for %s" root))
       ((not (file-readable-p file))
        (message "devops: no tools.org in %s" root))
       (t (devops--lob-do-load root file)))
    (message "devops: no project at current buffer")))

;;;###autoload
(defun devops-lob-unload-project-tools ()
  "Remove org-babel LOB entries loaded from current project's tools.org."
  (interactive)
  (if-let* ((proj (project-current nil))
            (root (project-root proj))
            (entry (assoc root devops--lob-project-registry)))
      (let ((names (cdr entry)))
        (dolist (sym names)
          (setq org-babel-library-of-babel
                (assq-delete-all sym org-babel-library-of-babel)))
        (setq devops--lob-project-registry
              (assoc-delete-all root devops--lob-project-registry))
        (message "devops: unloaded %d LOB entries for %s" (length names) root))
    (message "devops: nothing to unload for current project")))

;;;###autoload
(defun devops-lob-reload-project-tools ()
  "Unload then reload tools.org for current project."
  (interactive)
  (devops-lob-unload-project-tools)
  (devops-lob-load-project-tools))

;;;###autoload
(defun devops-lob-unload-all ()
  "Unload all project LOB entries tracked by devops."
  (interactive)
  (dolist (entry devops--lob-project-registry)
    (dolist (sym (cdr entry))
      (setq org-babel-library-of-babel
            (assq-delete-all sym org-babel-library-of-babel))))
  (setq devops--lob-project-registry nil)
  (message "devops: all project LOB entries unloaded"))

(defun devops--lob-maybe-load-on-find-file ()
  "Auto-load tools.org for current project if not yet loaded.
Skips TRAMP remote paths."
  (when (and (not devops--lob-loading)
             (not (file-remote-p default-directory)))
    (when-let* ((proj (project-current nil))
                (root (project-root proj))
                (file (expand-file-name "tools.org" root)))
      (when (and (file-readable-p file)
                 (not (assoc root devops--lob-project-registry)))
        (devops--lob-do-load root file)))))

;;;###autoload
(define-minor-mode devops-lob-auto-mode
  "Automatically load tools.org LOB entries when opening files in a project."
  :global t
  :lighter " dLOB"
  :group 'tools
  (if devops-lob-auto-mode
      (add-hook 'find-file-hook #'devops--lob-maybe-load-on-find-file)
    (remove-hook 'find-file-hook #'devops--lob-maybe-load-on-find-file)))

(provide 'devops-lob)

;;; devops-lob.el ends here
