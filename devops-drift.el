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
;; byte-for-byte with its remote counterpart.  Results land in a
;; *Drift Report* buffer; see `devops-drift-report-mode' for keys.

;;; Code:

(require 'devops)
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

(defun devops--drift-status (local remote)
  "Compare LOCAL tangle output with REMOTE; return (STATUS . DETAIL).
STATUS is `same', `drift', `missing' (no remote file) or `error'
\(remote unreachable, DETAIL holds the message)."
  (condition-case err
      (cond
       ((not (file-exists-p remote)) (cons 'missing nil))
       ((string= (devops--drift-file-contents local)
                 (devops--drift-file-contents remote))
        (cons 'same nil))
       (t (cons 'drift nil)))
    (error (cons 'error (error-message-string err)))))

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

;;; Report buffer

(defvar-local devops-drift--source-buffer nil
  "Org buffer this drift report was generated from.")

(defvar-local devops-drift--all nil
  "Non-nil if this report covers all headings, not just one.")

(defvar-local devops-drift--root nil
  "Temp directory holding this report's tangled files.")

(defconst devops-drift--status-display
  '((same . ("ok" . success))
    (drift . ("DRIFT" . warning))
    (missing . ("MISSING" . error))
    (error . ("ERROR" . error)))
  "Alist mapping a drift status symbol to (LABEL . FACE).")

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

;;; State checks

(defun devops-drift--set-lines (value)
  "Normalize VALUE to a list of trimmed, non-empty lines.
VALUE is a string (split on newlines) or a possibly nested list, the
two shapes org-babel passes for :var references to blocks and tables."
  (cond
   ((stringp value)
    (seq-remove #'string-empty-p
                (mapcar #'string-trim (split-string value "\n"))))
   ((listp value) (mapcan #'devops-drift--set-lines value))
   (t (list (string-trim (format "%s" value))))))

;;;###autoload
(defun devops-drift-set (actual expected)
  "Compare ACTUAL and EXPECTED as unordered sets of lines.
Each argument is a string or a list, as org-babel passes :var values;
lines are trimmed and blanks dropped.  Return \"ok (N lines)\" when the
sets match, otherwise a DRIFT report listing expected lines missing
from ACTUAL and extra lines not in EXPECTED.  Meant for state-check
blocks that compare live command output against a declared expectation:

  #+begin_src elisp :var actual=live-cmd() expected=expected-block
  (devops-drift-set actual expected)
  #+end_src"
  (let* ((actual (devops-drift--set-lines actual))
         (expected (devops-drift--set-lines expected))
         (missing (seq-difference expected actual))
         (extra (seq-difference actual expected)))
    (if (not (or missing extra))
        (format "ok (%d lines)" (length expected))
      (string-join
       (cons "DRIFT"
             (nconc (mapcar (lambda (l) (concat "missing: " l)) missing)
                    (mapcar (lambda (l) (concat "extra: " l)) extra)))
       "\n"))))

(provide 'devops-drift)
