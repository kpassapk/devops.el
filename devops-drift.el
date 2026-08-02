;; devops-drift.el - Drift detection for devops.el -*- lexical-binding: t; -*-

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
;; Detect drift between an org file's source blocks and the files they
;; tangle to on their targets.  Because blocks can contain noweb
;; references (including per-server ones), the org file is tangled to a
;; local temporary directory first, then each tangled file is compared
;; byte-for-byte with its remote counterpart.
;;
;; `devops-drift' shows the result in a *Drift Report* buffer; see
;; `devops-drift-report-mode' for its keys.  `devops-drift-all',
;; `devops-drift-headline' and `devops-drift-custom-id' run the same
;; check noninteractively and return the result as data, so a check can
;; live in a source block of the org file that documents it.

;;; Code:

(require 'devops)
(require 'diff)  ; diff-command
(require 'subr-x)
(require 'tabulated-list)

(defun devops--drift-localize-path (path)
  "Map a :tangle PATH to a relative path safe under a local temp root.
\"~/foo\" becomes \"home/foo\", \"~user/foo\" becomes \"home/user/foo\",
an absolute \"/etc/foo\" loses its leading slash, and a relative path is
returned unchanged.  A TRAMP PATH is first reduced to its remote-local
part, so \"/ssh:host:~/foo\" also becomes \"home/foo\"."
  (let ((path (if (tramp-tramp-file-p path)
                  (tramp-file-name-localname (tramp-dissect-file-name path))
                path)))
    (cond
     ((string-match "\\`~/\\(.*\\)\\'" path)
      (concat "home/" (match-string 1 path)))
     ((string-match "\\`~\\([^/]+\\)/\\(.*\\)\\'" path)
      (concat "home/" (match-string 1 path) "/" (match-string 2 path)))
     ((string-prefix-p "/" path)
      (substring path 1))
     (t path))))

(defun devops--drift-rewrite-tangle-paths (target local-root)
  "Rewrite :tangle paths in buffer to land under LOCAL-ROOT.
Return a list of (PATH LOCAL REMOTE) in buffer order, where PATH is the
original :tangle value, LOCAL the rewritten local file and REMOTE the
file the path denotes at TARGET.  A PATH that is already a TRAMP path
keeps itself as REMOTE but is still redirected to LOCAL-ROOT: a drift
check must never write to a remote.  Skips :tangle no and :tangle yes.
Modifies buffer text."
  (let (mapping)
    (save-excursion
      (goto-char (point-max))
      (while (re-search-backward ":tangle +\\([^ \t\n]+\\)" nil t)
        ;; Computing remote/local paths runs regexps of its own, so take
        ;; the match apart before touching them (`replace-match' would
        ;; see clobbered match data).
        (let ((beg (match-beginning 0))
              (end (match-end 0))
              (path (match-string 1)))
          (unless (member path '("no" "yes"))
            (let ((remote (if (tramp-tramp-file-p path)
                              path
                            (devops--join-target target path)))
                  (local (expand-file-name
                          (devops--drift-localize-path path) local-root)))
              (delete-region beg end)
              (goto-char beg)
              (insert ":tangle " local)
              ;; Step before the rewrite so the backward search keeps
              ;; making progress (the rewritten path matches the regexp).
              (goto-char beg)
              (push (list path local remote) mapping))))))
    mapping))

(defun devops--drift-tangle-heading (source-buf heading-pos tag target local-root)
  "Tangle subtree at HEADING-POS from SOURCE-BUF into LOCAL-ROOT.
TAG selects per-server noweb blocks, exactly as in `devops--tangle-heading'.
Files land under LOCAL-ROOT/TAG so the same :tangle path tangled for two
servers (with different noweb content) cannot collide.  Return a list of
drift entries, plists with :tag :target :path :local :remote :heading-pos."
  (let* ((target (if (tramp-tramp-file-p target)
                     target
                   (expand-file-name
                    target (buffer-local-value 'default-directory source-buf))))
         (root (expand-file-name tag local-root))
         (tmp-file (make-temp-file "devops-drift-" nil ".org"))
         (tmp-buf (find-file-noselect tmp-file))
         (mapping nil))
    (unwind-protect
        (with-current-buffer tmp-buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert-buffer-substring source-buf)
            (goto-char heading-pos)
            (org-narrow-to-subtree)
            (devops--specialize-noweb-blocks tag)
            (setq mapping (devops--drift-rewrite-tangle-paths target root))
            ;; Tangling doesn't create parent dirs (that's :mkdirp);
            ;; the temp tree needs them.
            (dolist (m mapping)
              (make-directory (file-name-directory (nth 1 m)) t))
            (org-babel-tangle)
            (widen)))
      (with-current-buffer tmp-buf
        (set-buffer-modified-p nil)
        (kill-buffer tmp-buf)
        (delete-file tmp-file)))
    (mapcar (lambda (m)
              (list :tag tag :target target
                    :path (nth 0 m) :local (nth 1 m) :remote (nth 2 m)
                    :heading-pos heading-pos))
            mapping)))

(defun devops--drift-file-contents (file)
  "Return FILE's contents as a raw string, without coding conversion."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (buffer-string)))

(defconst devops-drift--status-display
  '((:same . ("ok" . success))
    (:drift . ("DRIFT" . warning))
    (:missing . ("MISSING" . error))
    (:error . ("ERROR" . error)))
  "Alist mapping a drift status keyword to (LABEL . FACE).")

(defun devops-drift--label (status)
  "Display label for STATUS, one of the keys of `devops-drift--status-display'."
  (car (alist-get status devops-drift--status-display)))

(defun devops--drift-status (local remote)
  "Compare LOCAL tangle output with REMOTE; return (STATUS . DETAIL).
STATUS is `:same', `:drift', `:missing' (no remote file) or `:error'
\(remote unreachable, DETAIL holds the message)."
  (condition-case err
      (cond
       ((not (file-exists-p remote)) (cons :missing nil))
       ((string= (devops--drift-file-contents local)
                 (devops--drift-file-contents remote))
        (cons :same nil))
       (t (cons :drift nil)))
    (error (cons :error (error-message-string err)))))

(defun devops--drift-check (source-buf &optional all)
  "Tangle SOURCE-BUF to a temp dir and compare each file with its target.
With ALL non-nil check every target-tagged heading, otherwise only the
heading at point (mirroring `devops-tangle').  Return (LOCAL-ROOT . ENTRIES)
where ENTRIES are the plists of `devops--drift-tangle-heading', each with
:status and :detail added.  Unlike tangling to a remote, a drift check is
read-only, so a failing target yields an `error' entry instead of aborting.
The caller owns LOCAL-ROOT and must delete it."
  (with-current-buffer source-buf
    (let ((spec (devops--tangle-spec all))
          (root (make-temp-file "devops-drift-" t))
          (entries nil))
      (dolist (e spec)
        (setq entries
              (append entries
                      (devops--drift-tangle-heading
                       source-buf (plist-get e :heading-pos)
                       (plist-get e :tag) (plist-get e :target) root))))
      ;; Several blocks may append to one tangled file; one entry each.
      (setq entries (seq-uniq entries
                              (lambda (a b)
                                (equal (plist-get a :local)
                                       (plist-get b :local)))))
      (dolist (entry entries)
        (let ((status (devops--drift-status (plist-get entry :local)
                                            (plist-get entry :remote))))
          (plist-put entry :status (car status))
          (plist-put entry :detail (cdr status))))
      (cons root entries))))

;;; Noninteractive API

;; These return data rather than a report buffer, so a drift check can be
;; written down in the org file it checks, run with C-c C-c, and leave its
;; result in the file.  The shape is an alist keyed by keywords: what elisp
;; passes around, and what cljbang reads as a map, so
;;
;;   (require '[devops-drift :as drift])
;;   (->> (drift/all "servers/box.org")
;;        (remove #(= (:status %) :same))
;;        (map :path))
;;
;; works without this package knowing anything about cljbang.

(defun devops--drift-source-buffer (source)
  "Return SOURCE as an org buffer.  SOURCE is a buffer or a file name."
  (let ((buf (if (bufferp source)
                 source
               (find-file-noselect (expand-file-name source)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'org-mode)
        (error "Not an org buffer: %s" (buffer-name buf))))
    buf))

(defun devops--drift-diff (local remote path tag)
  "Unified diff of REMOTE (old) against the tangled LOCAL file (new).
PATH and TAG label the new side, so the output names the source block's
:tangle path rather than a temp file nobody will find again.  `diff' runs
locally, so a TRAMP REMOTE is copied down first.  Return nil if `diff'
fails outright (an exit status above 1)."
  (let* ((copy (file-local-copy remote))
         (old (or copy remote)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (call-process diff-command nil t nil "-u"
                                      "-L" remote
                                      "-L" (format "%s (%s)" path tag)
                                      old local)))
            (and (memq status '(0 1)) (buffer-string))))
      (when copy (delete-file copy)))))

(defun devops--drift-entry-data (entry)
  "Convert a drift ENTRY plist to an alist, resolving its diff.
Drops :local and :heading-pos: both point into a temp tree the caller
never sees, and the diff is what they were good for."
  (let ((status (plist-get entry :status)))
    (list (cons :status status)
          (cons :tag (plist-get entry :tag))
          (cons :path (plist-get entry :path))
          (cons :remote (plist-get entry :remote))
          (cons :target (plist-get entry :target))
          (cons :detail (plist-get entry :detail))
          (cons :diff (when (eq status :drift)
                        (devops--drift-diff (plist-get entry :local)
                                            (plist-get entry :remote)
                                            (plist-get entry :path)
                                            (plist-get entry :tag)))))))

(defun devops--drift-entries (source-buf &optional all)
  "Drift-check SOURCE-BUF and return entry alists, temp tree removed.
Point selects the heading unless ALL is non-nil, exactly as in
`devops--drift-check'.  Diffs are resolved while the tangled files are
still there, so the return value stands on its own afterwards."
  (let* ((result (devops--drift-check source-buf all))
         (root (car result)))
    (unwind-protect
        (mapcar #'devops--drift-entry-data (cdr result))
      (delete-directory root t))))

(defun devops-drift-all (source)
  "Drift-check every target-tagged heading in SOURCE, noninteractively.
SOURCE is an org buffer or a file name.  Return one alist per tangled
file, keyed :status :tag :path :remote :target :detail :diff, where
:status is `:same', `:drift', `:missing' or `:error', and :diff holds a
unified diff for a drifting file and nil otherwise."
  (let ((buf (devops--drift-source-buffer source)))
    (with-current-buffer buf
      (save-excursion
        (devops--drift-entries buf t)))))

(defun devops-drift-headline (source headline)
  "Drift-check the subtree titled HEADLINE in SOURCE, noninteractively.
Locate HEADLINE with `org-find-exact-headline-in-buffer', then check it
exactly as `devops-drift' would with point on that heading.  Return entry
alists as `devops-drift-all' does.

Surrounding whitespace in HEADLINE is ignored, so a selector taken
straight from a `:results output' block (which carries a trailing
newline) still matches."
  (let ((buf (devops--drift-source-buffer source)))
    (with-current-buffer buf
      (save-excursion
        (let ((pos (org-find-exact-headline-in-buffer (string-trim headline) nil t)))
          (unless pos (error "No heading titled %S" headline))
          (goto-char pos)
          (devops--drift-entries buf))))))

(defun devops-drift-custom-id (source custom-id)
  "Drift-check the subtree whose CUSTOM_ID property is CUSTOM-ID, in SOURCE.
Locate it with `org-find-property'.  Unlike `devops-drift-headline', the
selector survives title edits and is unambiguous when several headings
share a title.  Return entry alists as `devops-drift-all' does.

Surrounding whitespace in CUSTOM-ID is ignored."
  (let ((buf (devops--drift-source-buffer source)))
    (with-current-buffer buf
      (save-excursion
        (let ((pos (org-find-property "CUSTOM_ID" (string-trim custom-id))))
          (unless pos (error "No heading with CUSTOM_ID %S" custom-id))
          (goto-char pos)
          (devops--drift-entries buf))))))

(defun devops-drift-ok-p (entries)
  "Non-nil when every entry in ENTRIES is in sync.
Nil for an empty ENTRIES too: a check that found no files to compare has
not established that anything matches."
  (and entries
       (seq-every-p (lambda (entry) (eq (alist-get :status entry) :same))
                    entries)))

(defun devops-drift-summary (entries)
  "Format ENTRIES as text: one status line per file, then any diffs.
For an `emacs-lisp' block with `:results output'; print it with `princ'."
  (let ((lines (mapcar
                (lambda (entry)
                  (let ((detail (alist-get :detail entry))
                        (remote (alist-get :remote entry)))
                    (format "%-8s %-12s %s"
                            (devops-drift--label (alist-get :status entry))
                            (alist-get :tag entry)
                            (if detail (format "%s (%s)" remote detail) remote))))
                entries))
        (diffs (delq nil (mapcar (lambda (entry) (alist-get :diff entry)) entries))))
    (string-join (append lines (and diffs (cons "" diffs))) "\n")))

(defun devops-drift-table (entries)
  "Return ENTRIES as an org table: a header row, an hline, then a row each.
For an `emacs-lisp' block with `:results table'.  Diffs are left out;
they do not fit a table cell.  See `devops-drift-summary' for those."
  (append
   (list '("Status" "Tag" "Path" "Remote") 'hline)
   (mapcar (lambda (entry)
             (let ((detail (alist-get :detail entry))
                   (remote (alist-get :remote entry)))
               (list (devops-drift--label (alist-get :status entry))
                     (alist-get :tag entry)
                     (alist-get :path entry)
                     (if detail (format "%s (%s)" remote detail) remote))))
           entries)))

;;; Report buffer

(defvar-local devops-drift--source-buffer nil
  "Org buffer this drift report was generated from.")

(defvar-local devops-drift--all nil
  "Non-nil if this report covers all headings, not just one.")

(defvar-local devops-drift--root nil
  "Temp directory holding this report's tangled files.")

(defvar devops-drift-report-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'devops-drift-report-visit)
    (define-key map "=" #'devops-drift-report-ediff)
    (define-key map "d" #'devops-drift-report-diff)
    map)
  "Keymap for `devops-drift-report-mode'.")

(define-derived-mode devops-drift-report-mode tabulated-list-mode "DriftReport"
  "Major mode for devops drift reports.
\\<devops-drift-report-mode-map>Each row is one tangled file compared
against its target.  \\[devops-drift-report-visit] jumps to the source
block, \\[devops-drift-report-ediff] runs ediff against the remote,
\\[devops-drift-report-diff] shows a diff, and \\[revert-buffer]
re-runs the check."
  (setq tabulated-list-format [("Status" 8 t) ("Tag" 12 t) ("Remote" 48 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header)
  (add-hook 'tabulated-list-revert-hook #'devops-drift--report-refresh nil t)
  (add-hook 'kill-buffer-hook #'devops-drift--cleanup nil t))

(defun devops-drift--cleanup ()
  "Delete this report's temp tangle directory, if any."
  (when (and devops-drift--root (file-directory-p devops-drift--root))
    (delete-directory devops-drift--root t))
  (setq devops-drift--root nil))

(defun devops-drift--report-rows (entries)
  "Convert drift ENTRIES to `tabulated-list-entries' rows."
  (mapcar (lambda (entry)
            (let* ((status (plist-get entry :status))
                   (display (cdr (assq status devops-drift--status-display)))
                   (detail (plist-get entry :detail)))
              (list entry
                    (vector (propertize (car display) 'face (cdr display))
                            (plist-get entry :tag)
                            (if detail
                                (format "%s (%s)" (plist-get entry :remote) detail)
                              (plist-get entry :remote))))))
          entries))

(defun devops-drift--report-refresh ()
  "Re-run the drift check and rebuild the report's rows."
  (devops-drift--cleanup)
  (unless (buffer-live-p devops-drift--source-buffer)
    (user-error "Source buffer is gone"))
  (let ((result (devops--drift-check devops-drift--source-buffer
                                     devops-drift--all)))
    (setq devops-drift--root (car result))
    (setq tabulated-list-entries (devops-drift--report-rows (cdr result)))))

(defun devops-drift--entry-at-point ()
  "Return the drift entry for the report row at point, or signal."
  (or (tabulated-list-get-id)
      (user-error "No drift entry on this line")))

(defun devops-drift-report-visit ()
  "Jump to the source block behind the report row at point."
  (interactive)
  (let* ((entry (devops-drift--entry-at-point))
         (buf devops-drift--source-buffer)
         (path (plist-get entry :path)))
    (unless (buffer-live-p buf)
      (user-error "Source buffer is gone"))
    (pop-to-buffer buf)
    (goto-char (plist-get entry :heading-pos))
    (let ((end (save-excursion (org-end-of-subtree t t) (point))))
      (when (re-search-forward
             (concat ":tangle +" (regexp-quote path) "\\(?:[ \t]\\|$\\)")
             end t)
        (beginning-of-line)))))

(defun devops-drift-report-ediff ()
  "Ediff the tangled file at point against its remote counterpart."
  (interactive)
  (let ((entry (devops-drift--entry-at-point)))
    (ediff-files (plist-get entry :remote) (plist-get entry :local))))

(defun devops-drift-report-diff ()
  "Diff the remote file at point (old) against the tangled one (new)."
  (interactive)
  (let ((entry (devops-drift--entry-at-point)))
    (diff (plist-get entry :remote) (plist-get entry :local))))

;;;###autoload
(defun devops-drift (&optional arg)
  "Check whether the current heading's targets match its source blocks.
Tangles to a local temp directory (so noweb resolves exactly as a real
tangle would), compares each file with its target and shows a *Drift
Report* buffer.  With prefix ARG, check every target-tagged heading in
the buffer."
  (interactive "P")
  (let* ((source (current-buffer))
         (result (devops--drift-check source arg))
         (buf (get-buffer-create "*Drift Report*")))
    (with-current-buffer buf
      ;; Reusing the buffer: drop the previous run's temp dir before the
      ;; mode call resets the buffer-local pointing at it.
      (when (derived-mode-p 'devops-drift-report-mode)
        (devops-drift--cleanup))
      (devops-drift-report-mode)
      (setq devops-drift--source-buffer source
            devops-drift--all arg
            devops-drift--root (car result))
      (setq tabulated-list-entries (devops-drift--report-rows (cdr result)))
      (tabulated-list-print))
    (pop-to-buffer buf)))

(provide 'devops-drift)
