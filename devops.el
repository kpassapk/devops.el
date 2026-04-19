;; devops.el - Development server -*- lexical-binding: t; -*-

;; Copyright (C) Kyle S Passarelli

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
;; `devops.el' offers utilities for running commands on local and remote
;; machines using org mode.

(require 'devops-migration.el)
(require 'devops-podman.el)
(require 'devops-lob.el)

(defun devops-org-keywords (key)
  "Return all values for keyword KEY as a list."
  (cdr (assoc key (org-collect-keywords (list key)))))

(defun devops--parse-server-keyword (value)
  "Parse a #+SERVER value like \"server1 (source)\" into (TAG . SERVER)."
  (when (string-match "\\`\\([^ ]+\\) +(\\([^)]+\\))\\'" value)
    (cons (match-string 2 value) (match-string 1 value))))

(defun devops-server-tag-alist ()
  "Return alist of (TAG . SERVER) from #+SERVER keywords in current buffer."
  (delq nil (mapcar #'devops--parse-server-keyword
                    (devops-org-keywords "SERVER"))))

(defun devops-resolve-server-for-tag (tag)
  "Look up TAG in #+SERVER keywords, return server name or nil."
  (cdr (assoc tag (devops-server-tag-alist))))

(defun devops-set-header-args-from-tag ()
  "Set :header-args: :dir from the current heading's tag and #+SERVER mappings."
  (interactive)
  (let* ((tags (org-get-tags nil t))
         (server (seq-some #'devops-resolve-server-for-tag tags)))
    (if server
        (org-entry-put nil "header-args" (format ":dir app@%s:" server))
      (user-error "No #+SERVER match for tags: %s" tags))))

(defun devops--tangle-resolve-target ()
  "Return (FILEPATH . BODY) for the source block at point."
  (let* ((element (org-element-at-point))
         (body (org-element-property :value element))
         (header (org-element-property :parameters element))
         (target (when (and header (string-match "target=\"\\([^\"]+\\)\"" header))
                   (match-string 1 header)))
         (info (org-babel-get-src-block-info 'light))
         (params (nth 2 info))
         (dir (cdr (assq :dir params))))
    (unless target
      (user-error "No target variable found in source block header"))
    (unless dir
      (user-error "No :dir property found"))
    (cons (concat dir target) body)))

(defun devops-tangle-to-target ()
  "Tangle source block at point to :dir + target path."
  (interactive)
  (pcase-let ((`(,filepath . ,body) (devops--tangle-resolve-target)))
    (write-region body nil filepath)
    (message "Wrote %s" filepath)))


(defun devops-exec-in-notebook (block-name)
  "Execute BLOCK-NAME in the source deployment org file."
  (with-current-buffer (find-file-noselect devops-notebook)
    (org-babel-goto-named-src-block block-name)
    (org-babel-execute-src-block)))

;;;###autoload
(defalias 'devops-ingest-tool-blocks 'devops-lob-load-project-tools
  "Load tools.org from current project root into the org-babel LOB.
Deprecated alias for `devops-lob-load-project-tools'.")

(defun devops-org-tool-blocks (&optional regexp)
  "Return a summary of org-babel library of babel entries.
Filter by REGEXP if provided."
  (mapcar (lambda (entry)
            (let* ((name (car entry))
                   (info (cdr entry))
                   (lang (nth 0 info))
                   (params (nth 2 info))
                   (filtered (seq-filter (lambda (p)
                                           (memq (car p) '(:var)))
                                         params)))
              (list name lang filtered)))
          (seq-filter (lambda (entry)
                        (or (null regexp)
                            (string-match-p regexp (symbol-name (car entry)))))
                      org-babel-library-of-babel)))

(defun devops-open-ghostty-at-dir (dir &optional env-vars body)
  "Open Ghostty terminal at current directory.
If directory is remote (TRAMP), SSH into that server.
ENV-VARS is an alist of (NAME . VALUE) to export.
BODY is the source block content to copy to clipboard."
  (when body
    (kill-new body)
    (message "Source block copied to kill ring."))
  (if (file-remote-p dir)
      (let* ((shell "$SHELL")
             (tramp-vec (tramp-dissect-file-name dir))
             (user (tramp-file-name-user tramp-vec))
             (host (tramp-file-name-host tramp-vec))
             (remote-dir (tramp-file-name-localname tramp-vec))
             (ssh-target (if user (concat user "@" host) host))
             (env-exports (if env-vars
                              (mapconcat
                               (lambda (pair)
                                 (format "export %s=%s"
                                         (car pair)
                                         (shell-quote-argument
                                          (format "%s" (cdr pair)))))
                               env-vars
                               " && ")
                            nil))
             (remote-cmd (string-join
                          (delq nil
                                (list
                                 (concat "cd " (shell-quote-argument remote-dir))
                                 env-exports
                                 shell))
                          " && ")))
        (call-process "ghostty" nil 0 nil
                      "-e" "ssh" "-t" ssh-target remote-cmd))
    (let ((env-exports (when env-vars
                         (mapconcat
                          (lambda (pair)
                            (format "export %s=%s"
                                    (car pair)
                                    (shell-quote-argument
                                     (format "%s" (cdr pair)))))
                          env-vars
                          " && "))))
      (if env-exports
          (call-process "ghostty" nil 0 nil
                        (concat "--working-directory=" dir)
                        "-e" "bash" "-c"
                        (concat env-exports " && exec $SHELL"))
        (call-process "ghostty" nil 0 nil
                      (concat "--working-directory=" dir))))))

(defun devops-context-directory ()
  "Return contextual directory: src block :dir, dired dir, or default."
  (cond
   ((derived-mode-p 'dired-mode)
    (dired-current-directory))
   ((derived-mode-p 'org-mode)
    (when-let ((info (org-babel-get-src-block-info 'light)))
      (let ((dir (cdr (assq :dir (nth 2 info)))))
        (when dir (expand-file-name dir)))))
   (buffer-file-name
    (file-name-directory buffer-file-name))))

(defun devops-src-block-env-vars ()
  "Return alist of evaluated :var params from current src block."
  (when (derived-mode-p 'org-mode)
    (when-let ((info (org-babel-get-src-block-info)))
      (let ((params (nth 2 info)))
        (delq nil
              (mapcar (lambda (p)
                        (when (eq (car p) :var)
                          (let* ((spec (cdr p))
                                 (name (if (consp spec) (car spec)
                                         (car (split-string (format "%s" spec) "="))))
                                 (value (if (consp spec) (cdr spec)
                                          (org-babel-ref-resolve
                                           (cadr (split-string (format "%s" spec) "="))))))
                            (cons (format "%s" name) value))))
                      params))))))

(defun devops-src-block-body ()
  "Return the body of the current src block, or nil."
  (when (derived-mode-p 'org-mode)
    (when-let ((info (org-babel-get-src-block-info 'light)))
      (let ((body (org-trim (nth 1 info))))
        (unless (string-empty-p body) body)))))

;;;###autoload
(defun devops-open-ghostty-dwim ()
  "Open Ghostty at contextual directory.
In a src block: copies body to clipboard and exports :var env vars."
  (interactive)
  (let ((dir (or (devops-context-directory) default-directory))
        (env-vars (devops-src-block-env-vars))
        (body (devops-src-block-body)))
    (devops-open-ghostty-at-dir dir env-vars body)))

(defun devops--new-timestamp ()
  "Creates a new timestamp by formatting the current time."
  (format-time-string "%Y%m%dT%H%M%S"))

(defun devops-create-incident-dir (slug)
  "Creates a new timestamped incident directory"
  (interactive "sSlug: ")
  (devops--create-notebook-dir slug :type "incidents"))

(cl-defun devops--worktree-directory (branch &key (dir default-directory))
  "Returns a sibling directory with _branch appended."
  (let* ((path (directory-file-name (file-name-directory dir)))
	 (name (file-name-nondirectory path))
	 (path (file-name-parent-directory path))
	 (wt (expand-file-name (concat name "_" branch) path)))
    wt))

(defun devops--resolve-secrets-table (rows)
  "Resolve auth-source passwords for ROWS against AUTH-HOST.
Each row is (KEY AUTH-USER). Returns ((KEY PASSWORD) ...).
Binds `default-directory' locally so auth-source (1password)
always runs `op' on the local server, not over TRAMP."
  (let ((default-directory "~"))
    (mapcar (lambda (row)
              (list (car row)
                    (auth-source-pick-first-password
                     :host (nth 1 row) :user (nth 2 row))))
            rows)))

(provide 'devops)
