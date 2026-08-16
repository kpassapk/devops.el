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

;;; Code:

(require 'org)
(require 'org-element)  ; org-element-property / org-element-at-point
(require 'tramp)  ; tramp-tramp-file-p / tramp-dissect-file-name etc. are used
                  ; below; autoloaded interactively but not under `emacs -Q'.

(defgroup devops nil
  "Manage infrastructure as org files."
  :group 'tools
  :prefix "devops-")

(defcustom devops-terminal-program 'ghostty
  "Terminal program to use for externally opening target locations"
  :type '(choice (const ghostty))
  :group 'devops)

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
If there is more than one target, use completing-read, allowing the
user to select one."
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

(defconst devops--target-none-values '(nil "nil" "none")
  "Values of a :target header argument that mean \"no target\".
Org reads a header value as a string, so a block written `:target nil'
arrives as \"nil\".  A genuine nil is accepted too, for params passed to
`org-babel-execute-src-block' from Lisp.")

(defun devops--block-params (info)
  "Return the header arguments of the src block being executed.
INFO is the src block info given to `org-babel-execute-src-block', or nil
when point is on the block.  Covers header arguments on the block itself,
on a #+header: line, inherited from a `header-args' property, and the
defaults in `org-babel-default-header-args'."
  (nth 2 (or info
             (ignore-errors
               (org-babel-get-src-block-info 'no-eval)))))

(defun devops--header-cell (key params block-params)
  "Return the (KEY . VALUE) header argument in effect, or nil.
PARAMS is the override alist given to `org-babel-execute-src-block' and
BLOCK-PARAMS the block's own header arguments.  PARAMS wins, as it does
in `org-babel-merge-params'."
  (or (assq key params)
      (assq key block-params)))

(defun devops--target-opted-out-p (params block-params)
  "Return non-nil if a :target header opts the block out of its heading's target.
PARAMS and BLOCK-PARAMS are as in `devops--header-cell'.  Signal an error
for any :target value other than those in `devops--target-none-values':
running on the heading's target is the wrong answer when the block asked
for something else, and silence would hide the mistake until it landed on
a server."
  (when-let* ((cell (devops--header-cell :target params block-params)))
    (or (member (cdr cell) devops--target-none-values)
        (user-error "Unknown :target value %S (expected nil)" (cdr cell)))))

(defun devops--target-opted-out-regions ()
  "Return (BEG . END) for each src block that opts out of its heading's target.
Covers the accessible portion of the buffer, so a narrowed subtree yields
only its own blocks.  Header arguments are read with the same merge rules
as execution, so a `:target nil' inherited from a `header-args' property
counts.  The regions let a textual :tangle rewrite tell an opted-out
block's header from any other."
  (org-element-map (org-element-parse-buffer 'element) 'src-block
    (lambda (el)
      (save-excursion
        (goto-char (org-element-property :post-affiliated el))
        (when (devops--target-opted-out-p nil (devops--block-params nil))
          (cons (org-element-property :begin el)
                (org-element-property :end el)))))))

(defun devops--in-regions-p (pos regions)
  "Return non-nil if POS falls inside one of REGIONS, a list of (BEG . END)."
  (catch 'hit
    (dolist (region regions)
      (when (and (>= pos (car region)) (< pos (cdr region)))
        (throw 'hit t)))))

(defun devops--inject-header-args-from-tags (orig-fn &optional arg info params executor-type)
  "Advise org-babel-execute-src-block to inject :dir from #+TARGET tags.
An explicit :dir wins: the heading's target is neither resolved nor
prompted for when the block already carries one.  `:target nil' opts the
block out of the heading's target without naming a directory, leaving
:dir to org."
  (let* ((block-params (devops--block-params info))
         (dir (unless (or (devops--target-opted-out-p params block-params)
                          (devops--header-cell :dir params block-params))
                (devops--heading-target-dir)))
         (params (if dir
                     (cons (cons :dir dir) params)
                   params)))
    (apply orig-fn arg info params (and executor-type (list executor-type)))))

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

(defun devops--split-target (target)
  "Split TARGET into a (PREFIX . ROOT) cons.
PREFIX is the TRAMP method/host header and ROOT the directory part:
\"/ssh:host:\" splits into (\"/ssh:host:\" . \"\"), \"/ssh:host:/etc\" into
\(\"/ssh:host:\" . \"/etc\"), and a local \"/srv/app\" into
\(\"\" . \"/srv/app\").  The split goes through `tramp-dissect-file-name'
rather than `file-remote-p', which reports only the last hop of a
multi-hop target like \"/ssh:host|podman:box:\"."
  (if (tramp-tramp-file-p target)
      (let ((root (tramp-file-name-localname (tramp-dissect-file-name target))))
        (cons (substring target 0 (- (length target) (length root))) root))
    (cons "" target)))

(defun devops--join-target (target path)
  "Join TARGET onto a :tangle PATH, reading PATH as its machine would.
TARGET is a #+TARGET value: a TRAMP prefix, a directory, or both.

A relative PATH lands under TARGET's directory, with exactly one
separator between them.  This keeps awkward targets honest: \".\" yields
\"./PATH\" (not the hidden file \".PATH\") and \"/srv/app\" yields
\"/srv/app/PATH\" (not \"/srv/appPATH\").  A leading \"./\" is dropped, so
\"./dir/f\" and \"dir/f\" name one file rather than two spellings of it.

An absolute PATH (\"/etc/f\") or a home-relative one (\"~/f\") is already
absolute on TARGET's machine, so it replaces TARGET's directory and keeps
only its TRAMP prefix: at \"/ssh:host:/opt\", \"/etc/f\" is
\"/ssh:host:/etc/f\", not \"/ssh:host:/opt/etc/f\".  \"~\" is left for TRAMP
to expand when the file is written, on the machine it belongs to."
  (let* ((split (devops--split-target target))
         (prefix (car split))
         (root (cdr split))
         (path (if (string-prefix-p "./" path) (substring path 2) path)))
    (cond
     ((or (string-prefix-p "/" path)
          (string-prefix-p "~" path))
      (concat prefix path))
     ((or (string= "" root)
          (string-suffix-p "/" root))
      (concat prefix root path))
     (t
      (concat prefix root "/" path)))))

(defun devops--rewrite-tangle-paths (tramp-prefix &optional local-dir)
  "Rewrite :tangle header args in buffer to include TRAMP-PREFIX.
Modifies buffer text.  Skips :tangle no, :tangle yes, and paths already
containing a TRAMP prefix.

A block that opted out with `:target nil' keeps its own path: the target
is off for tangling exactly as it is for execution, so the file lands
locally.  Such a relative path is expanded against LOCAL-DIR, since
tangling runs in a temp buffer whose directory is the system temp dir and
`org-babel-tangle' would otherwise resolve it there."
  (let ((opted-out (devops--target-opted-out-regions)))
    (save-excursion
      (goto-char (point-max))
      (while (re-search-backward
              ":tangle +\\([^ \t\n]+\\)"
              nil t)
        (let ((path (match-string 1))
              (beg (match-beginning 0)))
          (when (and (not (member path '("no" "yes")))
                     (not (tramp-tramp-file-p path)))
            (replace-match
             (concat ":tangle "
                     (if (devops--in-regions-p beg opted-out)
                         (if local-dir (expand-file-name path local-dir) path)
                       (devops--join-target tramp-prefix path))))
            ;; Step before the rewrite so the backward search keeps making
            ;; progress.  Otherwise a local (non-TRAMP) prefix would leave the
            ;; rewritten path matchable and we'd re-prefix it forever.
            (goto-char beg)))))))

(defun devops--tangle-heading (source-buf heading-pos tag target)
  "Tangle subtree at HEADING-POS from SOURCE-BUF to TARGET.
TAG is the server tag used for per-server noweb resolution.
Returns number of files tangled, or nil.

A relative local TARGET (e.g. \".\" or \"../foo\") is expanded against
SOURCE-BUF's directory before tangling.  Tangling runs in a temp buffer
whose file lives in the system temp dir, so without this a relative
target would silently resolve against the temp dir instead of the org
file.  TRAMP targets are left untouched.  Blocks that opted out of the
target with `:target nil' resolve against that same directory."
  (let* ((local-dir (buffer-local-value 'default-directory source-buf))
         (target (if (tramp-tramp-file-p target)
                     target
                   (expand-file-name target local-dir)))
         (tmp-file (make-temp-file "devops-tangle-" nil ".org"))
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
                            (devops--rewrite-tangle-paths target local-dir)
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

(defun devops--tangle-spec-execute (source-buf spec)
  "Tangle each entry of SPEC from SOURCE-BUF.
SPEC is a list of plists as built by `devops--tangle-spec'.  Return a list
of (TAG TARGET N) results.  Free of interaction and messaging, so it can be
driven noninteractively (e.g. from a pod or a test)."
  (let ((results nil))
    (dolist (entry spec)
      (let* ((tag (plist-get entry :tag))
             (target (plist-get entry :target))
             (heading-pos (plist-get entry :heading-pos))
             (n (devops--tangle-heading source-buf heading-pos tag target)))
        (when n
          (push (list tag target n) results))))
    (nreverse results)))

(defun devops--tangle-report (results)
  "Format RESULTS from `devops--tangle-spec-execute' as a status string."
  (if results
      (mapconcat
       (lambda (r)
         (format "Tangled %d file(s) to %s (%s)"
                 (nth 2 r) (nth 0 r) (nth 1 r)))
       results "; ")
    "No files tangled"))

;;;###autoload
(defun devops-tangle (&optional arg)
  "Tangle current heading's source blocks to remote target(s).
Resolves the heading's target tag to a TRAMP path and rewrites
:tangle header args before delegating to `org-babel-tangle'.

With prefix ARG, tangle all headings in the buffer that have
target tags."
  (interactive "P")
  (message "%s"
           (devops--tangle-report
            (devops--tangle-spec-execute
             (current-buffer) (devops--tangle-spec arg)))))

(defun devops-tangle-headline (source-buf headline)
  "Tangle the subtree titled HEADLINE in SOURCE-BUF, noninteractively.
Locate HEADLINE with `org-find-exact-headline-in-buffer', then tangle it
exactly as `devops-tangle' would with point on that heading.  Return a list
of (TAG TARGET N) results.  SOURCE-BUF must be an org-mode buffer.

Surrounding whitespace in HEADLINE is ignored, so a selector taken straight
from a `:results output' block (which carries a trailing newline) still
matches."
  (with-current-buffer source-buf
    (save-excursion
      (let ((pos (org-find-exact-headline-in-buffer (string-trim headline) nil t)))
        (unless pos (error "No heading titled %S" headline))
        (goto-char pos)
        (devops--tangle-spec-execute source-buf (devops--tangle-spec nil))))))

(defun devops-tangle-custom-id (source-buf custom-id)
  "Tangle the subtree whose CUSTOM_ID property is CUSTOM-ID, in SOURCE-BUF.
Locate it with `org-find-property', then tangle it exactly as `devops-tangle'
would with point on that heading.  Unlike `devops-tangle-headline', the
selector is stable across title edits and unambiguous when several headings
share a title.  Return a list of (TAG TARGET N) results.  SOURCE-BUF must be
an org-mode buffer.

Surrounding whitespace in CUSTOM-ID is ignored, so a selector taken straight
from a `:results output' block (which carries a trailing newline) still
matches."
  (with-current-buffer source-buf
    (save-excursion
      (let ((pos (org-find-property "CUSTOM_ID" (string-trim custom-id))))
        (unless pos (error "No heading with CUSTOM_ID %S" custom-id))
        (goto-char pos)
        (devops--tangle-spec-execute source-buf (devops--tangle-spec nil))))))

(defun devops-tangle-all (source-buf)
  "Tangle every target-tagged heading in SOURCE-BUF, noninteractively.
Return a list of (TAG TARGET N) results, like `devops-tangle' with a prefix
argument.  SOURCE-BUF must be an org-mode buffer."
  (with-current-buffer source-buf
    (devops--tangle-spec-execute source-buf (devops--tangle-spec t))))

(defun devops--tangle-paths ()
  "Return a list of file paths expanded with each target.
A block that opted out with `:target nil' names one local file, resolved
like any other path in this buffer, rather than one file per target."
  (let* ((params (nth 2 (org-babel-get-src-block-info)))
         (path (cdr (assq :tangle params))))
    (cond
     ((or (not path)
          (member path '("no" "yes"))
          (tramp-tramp-file-p path))
      nil)
     ((devops--target-opted-out-p nil params)
      (list (expand-file-name path)))
     (t
      (mapcar (lambda (entry)
                (let ((target (plist-get entry :target)))
                  (devops--join-target target path)))
              (devops--tangle-spec))))))

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
       (apply #'start-process "devops-terminal" nil ghostty)))))

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
