;; devops.el - Development target -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kyle S Passarelli

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

(defcustom devops-terminal-program 'ghostty
  "Terminal program to use for externally opening target locations"
  :type '(choice (const ghostty)))

(defun devops--parse-target-keyword (value)
  "Parse a #+TARGET value like \"target1 (source)\" into (TAG . TARGET)."
  (when (string-match "\\`\\([^ ]+\\) +(\\([^)]+\\))\\'" value)
    (cons (match-string 2 value) (match-string 1 value))))

(defun devops--org-keywords (key)
  "Return all values for keyword KEY as a list."
  (cdr (assoc key (org-collect-keywords (list key)))))

(defun devops-target-tag-alist ()
  "Return alist of (TAG . TARGET) from #+TARGET keywords in current buffer."
  (delq nil (mapcar #'devops--parse-target-keyword
                    (devops--org-keywords "TARGET"))))

(defun devops--resolve-target-for-tag (tag)
  "Look up TAG in #+TARGET keywords, return target name or nil."
  (cdr (assoc tag (devops-target-tag-alist))))

(defun devops--heading-target-tags ()
  "Return list of (TAG . TARGET) for all matching tags on current heading.
Searches heading's tags against all #+TARGET keywords."
  (let ((tags (org-get-tags nil nil)))
    (delq nil
          (mapcar (lambda (tag)
                    (when-let* ((target (devops--resolve-target-for-tag tag)))
                      (cons tag target)))
                  tags))))

(defun devops--heading-target-dir ()
  "Return :dir from the current heading's tags and #+TARGET mappings.
If there is more than one target, use completing-read, allowing the user to select one."
  (interactive)
  (let ((matches (devops--heading-target-tags)))
    (cond
     ((null matches)
      nil)
     ((= 1 (length matches))
      (cdr (car matches)))
     (t
      (let* ((options (mapcar (lambda (pair)
                                (cons (format "%s: %s" (car pair) (cdr pair))
                                      (cdr pair)))
                              matches))
             (selected (completing-read "Choose target: " (mapcar #'car options) nil t)))
        (cdr (assoc selected options)))))))

(defun devops-set-header-args-from-tags ()
  "Set :header-args: :dir from the current heading's tag and #+TARGET mappings."
  (interactive)
  (let ((dir (devops--heading-target-dir)))
    (org-entry-put nil "header-args" (format ":dir %s" dir))))

(defun devops--inject-header-args-from-tags (orig-fn &optional arg info params _babel-call)
  "Advise org-babel-execute-src-block to inject :dir"
  (let* ((dir (devops--heading-target-dir))
         (params (if dir
                     (cons (cons :dir dir) params)
                   params)))
    (funcall orig-fn arg info params)))

(advice-add 'org-babel-execute-src-block :around #'devops--inject-header-args-from-tags)

(defun devops--specialize-noweb-blocks (tag)
  "Rewrite #+name: FOO (TAG) blocks for server-specific noweb resolution.
Blocks matching TAG get renamed to #+name: FOO.
Blocks matching other tags get renamed to avoid resolution."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward
            "^\\([ \t]*#\\+name:[ \t]*\\)\\([^ \t\n]+\\) +(\\([^)]+\\))"
            nil t)
      (let ((prefix (match-string 1))
            (basename (match-string 2))
            (block-tag (match-string 3)))
        (replace-match
         (if (string= block-tag tag)
             (concat prefix basename)
           (concat prefix "_devops-excluded-" basename "-" block-tag)))))))

(defun devops--rewrite-tangle-paths (tramp-prefix)
  "Rewrite :tangle header args in buffer to include TRAMP-PREFIX.
Modifies buffer text. Skips :tangle no and paths already containing a TRAMP prefix."
  (save-excursion
    (goto-char (point-max))
    (while (re-search-backward
            ":tangle +\\([^ \t\n]+\\)"
            nil t)
      (let ((path (match-string 1)))
        (when (and (not (string= path "no"))
                   (not (tramp-tramp-file-p path)))
          (replace-match (concat ":tangle " tramp-prefix path)))))))

(defun devops--tangle-heading (source-buf heading-pos tag target)
  "Tangle subtree at HEADING-POS from SOURCE-BUF to TARGET.
TAG is the server tag used for per-server noweb resolution.
Returns number of files tangled, or nil."
  (let* ((tmp-file (make-temp-file "devops-tangle-" nil ".org"))
	 (tmp-buf  (find-file-noselect tmp-file)))
    (unwind-protect
        (with-current-buffer tmp-buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert-buffer-substring source-buf)
            (goto-char heading-pos)
            (org-narrow-to-subtree)
            (let* ((files (progn
                            (devops--specialize-noweb-blocks tag)
                            (devops--rewrite-tangle-paths target)
                            (org-babel-tangle))))
              (widen)
              (when files (length files)))))
      (with-current-buffer tmp-buf
        (set-buffer-modified-p nil)
	(kill-buffer tmp-buf)
	(delete-file tmp-file)))))

(defun devops--tangle-spec (&optional arg)
  "Return a tangle plan for the current buffer.
Each entry is a plist (:tag TAG :target TARGET :heading-pos POS).

With prefix ARG non-nil, include all target-tagged headings.
Otherwise include only the current heading."
  (if arg
      (let (specs)
        (org-map-entries
         (lambda ()
           (dolist (pair (devops--heading-target-tags))
             (push (list :tag (car pair)
                         :target (cdr pair)
                         :heading-pos (point))
                   specs))))
        (nreverse specs))
    (let ((pairs (devops--heading-target-tags)))
      (unless pairs
        (user-error "No #+TARGET match for tags on current heading"))
      (let ((pos (save-excursion (org-back-to-heading t) (point))))
        (mapcar (lambda (pair)
                  (list :tag (car pair)
                        :target (cdr pair)
                        :heading-pos pos))
                pairs)))))

;;;###autoload
(defun devops-tangle (&optional arg)
  "Tangle current heading's source blocks to remote target(s).
Resolves the heading's target tag to a TRAMP path and rewrites
:tangle header args before delegating to `org-babel-tangle'.

With prefix ARG, tangle all headings in the buffer that have
target tags."
  (interactive "P")
  (let ((source-buf (current-buffer))
        (spec (devops--tangle-spec arg))
        (results nil))
    (unwind-protect
        (dolist (entry spec)
          (let* ((tag (plist-get entry :tag))
                 (target (plist-get entry :target))
                 (heading-pos (plist-get entry :heading-pos))
                 (n (devops--tangle-heading
                     source-buf heading-pos tag target)))
            (when n
              (push (list tag target n) results)))))

    ;; Report
    (if results
        (message "%s"
                 (mapconcat
                  (lambda (r)
                    (format "Tangled %d file(s) to %s (%s)"
                            (nth 2 r) (nth 0 r) (nth 1 r)))
                  (nreverse results) "; "))
      (message "No files tangled"))))

(defun devops--tangle-paths ()
  "Return a list of file paths expanded with each target"
  (let* ((spec (devops--tangle-spec))
         (params (nth 2 (org-babel-get-src-block-info)))
         (path (cdr (assq :tangle params))))
    (if (or (not path)
            (string= path "no")
            (tramp-tramp-file-p path)) 
        nil
      (mapcar (lambda (entry)
                (let ((target (plist-get entry :target)))
                  (concat target path)))
              spec))))

(defun devops-visit-file (&optional arg)
  "Go to file at of source code block at point.
With a prefix arg, "
  (interactive "P")
  (let ((paths (devops--tangle-paths)))
    (cond
     ((= 1 (length paths))
      (find-file (car paths)))
     ((> (length paths) 1)
      (let ((chosen-file (completing-read "Visit: " paths nil t)))
        (if arg
	    (find-file-other-window chosen-file)
	  (find-file chosen-file))))
     (t
      (message "No tangle paths found.")))))

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

(defun devops--ghostty-command (dir &optional env-vars)
  (let ((env-exports (when env-vars
                       (mapconcat
                        (lambda (pair)
                          (format "export %s=%s"
                                  (car pair)
                                  (shell-quote-argument
                                   (format "%s" (cdr pair)))))
                        env-vars
                        " && "))))
    (if (file-remote-p dir)
        (let* ((shell "$SHELL")
               (tramp-vec (tramp-dissect-file-name dir))
               (user (tramp-file-name-user tramp-vec))
               (host (tramp-file-name-host tramp-vec))
               (remote-dir (tramp-file-name-localname tramp-vec))
               (ssh-target (if user (concat user "@" host) host))
               (remote-cmd (string-join
                            (delq nil
                                  (list
                                   (concat "cd " (shell-quote-argument remote-dir))
                                   env-exports
                                   shell))
                            " && ")))
          `("ghostty" "-e" "ssh" "-t" ,ssh-target ,remote-cmd))
      (if env-exports
          `("ghostty" ,(concat "--working-directory=" dir) "-e" "bash" "-c" ,(concat env-exports " && exec $SHELL"))
        `("ghostty" ,(concat "--working-directory=" dir))))))

(defun devops--open-terminal-at-dir (dir &optional env-vars)
  (pcase devops-terminal-program
    ('ghostty
     (let ((ghostty (devops--ghostty-command dir env-vars)))
       (message (format "Calling process:\n%s" (string-join ghostty " ")))
       (apply #'call-process (car ghostty) nil nil nil (cdr ghostty))))))

(defun devops-src-block-env-vars ()
  "Return alist of evaluated :var params from current src block."
  (when (derived-mode-p 'org-mode)
    (when-let* ((info (org-babel-get-src-block-info)))
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

(defun devops--src-block-tangle-header () 
  (let ((block-info (org-babel-get-src-block-info 'light)))
    (when block-info
      (let ((header-args (nth 2 block-info)))
	(cdr (assoc :tangle header-args))))))

(defun devops--src-block-body ()
  "Return the body of the current src block, or nil."
  (when (derived-mode-p 'org-mode)
    (when-let* ((info (org-babel-get-src-block-info 'light)))
      (let ((body (org-trim (nth 1 info))))
        (unless (string-empty-p body) body)))))

;;;###autoload
(defun devops-open-terminal-dwim ()
  "Open terminal at contextual directory.
In a src block, if the : copies body to clipboard and exports :var env vars."
  (interactive)
  (let* ((dir (devops--heading-target-dir))
         (env-vars (devops-src-block-env-vars))
	 (lang (org-element-property :language (org-element-at-point))))
    (when (or (string= lang "shell") (string= lang "sh"))
      (kill-new (devops--src-block-body))
      (message "Source block copied to kill ring."))
    (devops--open-terminal-at-dir dir env-vars)))

(provide 'devops)
