;;; devops.el --- Infrastructure as an org file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kyle S Passarelli

;; Author: Kyle S Passarelli <kyle.passarelli@gmail.com>
;; Maintainer: Kyle S Passarelli <kyle.passarelli@gmail.com>
;; URL: https://github.com/kpassapk/devops.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes, outlines

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
;;
;; The package itself needs nothing newer than the org bundled with Emacs
;; 29.  `devops-enable-session-async' is the exception: running shell
;; blocks asynchronously needs the `:async' support `ob-shell' gained in
;; Org 9.7 (Emacs 30.1), and turns itself off under an older org rather
;; than putting blocks in a session it cannot drive.  Hence no (org "9.7")
;; in Package-Requires: an optional feature should not force everyone to
;; replace their built-in org.

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

(defcustom devops-enable-session-async nil
  "When non-nil, run blocks under a target-tagged heading in an async session.
A src block then gets `:session' and `:async' injected alongside its
`:dir', so emacs returns immediately with a placeholder and the output
lands in the results block when the command finishes.  A command that
asks a question waits in the session buffer instead of hanging emacs;
`devops-goto-session' goes there.

Off by default, because a session makes blocks stateful: `cd', `export',
an activated virtualenv and `ssh-agent' survive from one block to the
next, which is useful but costs idempotency.  A block that passed in a
dirty session may fail in a fresh one, so prefer blocks that do not
depend on the ones above them, and use `devops-restart-session' to get
back to a known state.

Shell blocks need Org 9.7 or newer, where `ob-shell' learned `:async';
under an older org this option leaves them alone rather than putting
them in a session it cannot run asynchronously."
  :type 'boolean
  :group 'devops)

(defcustom devops-session-name-function
  (lambda (tag _target) (format "devops:%s" tag))
  "Function mapping a target TAG and TARGET to a session name.
A shell session name is a buffer name in a single global namespace, so a
bare tag like \"web\" would collide with anything else that picked the
same word — including another org file whose \"web\" tag points at a
different host.  Sending commands to the wrong machine is the worst
failure this package can have, so the default prefixes `devops:'.

That removes accidental collisions, not deliberate ones.  If two org
files reuse a tag for different hosts, set this to a function that also
folds in the target or the buffer name."
  :type 'function
  :group 'devops)

(defcustom devops-async-session-languages '("sh" "bash" "shell" "python")
  "Languages that get a `:session' and `:async' injected.
`:session' is not a neutral header argument: for `emacs-lisp' it means an
ielm buffer, and for the non-executable blocks that carry `:tangle' it is
meaningless.  Only languages that support `org-babel-comint-async-register'
belong here; blocks in any other language keep getting `:dir' and nothing
else."
  :type '(repeat string)
  :group 'devops)

(defvar devops--inhibit-async nil
  "When non-nil, do not inject `:session' or `:async'.
Bound by `devops-with-sync' around tangling and drift checks.")

(defmacro devops-with-sync (&rest body)
  "Run BODY with async injection inhibited.
Async breaks the contract that the return value of
`org-babel-execute-src-block' is the block's result: under `:async' it is
a UUID placeholder.  Anything that reads that value — a noweb reference
that executes a block, `devops-tangle-headline', a drift check — needs
the real thing, so it runs inside this macro.  Interactive \\[org-ctrl-c-ctrl-c]
gets async; everything scripted gets synchronous evaluation unless it
asks otherwise."
  (declare (indent 0) (debug t))
  `(let ((devops--inhibit-async t))
     ,@body))

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

(defun devops--heading-target ()
  "Return the (TAG . TARGET) in effect for the current heading, or nil.
If more than one of the heading's tags names a target, use
completing-read, allowing the user to select one.  The tag is kept
alongside the target because it, not the directory, is what names the
session: a tag maps 1:1 to a target, and two tags on the same host mean
two directories, hence two sessions."
  (let ((matches (devops--heading-target-tags)))
    (cond
     ((null matches)
      nil)
     ((= 1 (length matches))
      (car matches))
     (t
      (let* ((options (mapcar (lambda (pair)
                                (cons (format "%s: %s" (car pair) (cdr pair))
                                      pair))
                              matches))
             (selected (completing-read "Choose target: " (mapcar #'car options) nil t)))
        (cdr (assoc selected options)))))))

(defun devops--heading-target-dir ()
  "Return :dir from the current heading's tags and #+TARGET mappings.
If there is more than one target, use completing-read, allowing the
user to select one."
  (cdr (devops--heading-target)))

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

(defun devops--block-info (info)
  "Return the src block info for the block being executed.
INFO is the info given to `org-babel-execute-src-block', or nil when
point is on the block."
  (or info
      (ignore-errors
        (org-babel-get-src-block-info 'no-eval))))

(defun devops--block-params (info)
  "Return the header arguments of the src block being executed.
INFO is the src block info given to `org-babel-execute-src-block', or nil
when point is on the block.  Covers header arguments on the block itself,
on a #+header: line, inherited from a `header-args' property, and the
defaults in `org-babel-default-header-args'."
  (nth 2 (devops--block-info info)))

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

(defun devops--session-name (tag target)
  "Return the session name for TAG and TARGET."
  (funcall devops-session-name-function tag target))

(defun devops--user-header-args (lang)
  "Return the header arguments written on the src block at point.
Org's defaults are unbound while the block is read, so a `:session none'
in the result is one the user wrote rather than the one
`org-babel-default-header-args' hands to every block.  LANG names the
language-specific defaults to suppress along with the global ones.
Returns nil when point is not on a src block."
  (let* ((sym (and lang (intern-soft
                         (concat "org-babel-default-header-args:" lang))))
         (lang-default (and sym (boundp sym) sym))
         (saved (and lang-default (symbol-value lang-default)))
         (org-babel-default-header-args nil))
    (unwind-protect
        (progn
          (when lang-default (set lang-default nil))
          (nth 2 (ignore-errors (org-babel-get-src-block-info 'no-eval))))
      (when lang-default (set lang-default saved)))))

(defun devops--session-declared-p (params block-params lang)
  "Non-nil when the block, not org, decided its `:session'.
`org-babel-default-header-args' gives every block `:session none', so the
merged header arguments cannot tell a block that opted out of sessions
from one that never mentioned them.  Any other value had to be written by
hand; \"none\" is re-checked against the block's own header arguments
\(see `devops--user-header-args').

Unreadable cases count as declared.  A `#+call:' line, for instance, is
executed with an INFO built from the Library of Babel while point is not
on a src block, so nothing here can prove the block said nothing — and
attaching a block to a shared session it did not ask for is the error
worth avoiding."
  (let ((cell (devops--header-cell :session params block-params)))
    (and cell
         (or (not (equal (cdr cell) "none"))
             (assq :session params)
             (let ((own (devops--user-header-args lang)))
               (or (null own) (assq :session own)))))))

(defun devops--lang-async-p (lang)
  "Non-nil when org can evaluate LANG asynchronously in a session.
`ob-shell' gained `:async' in Org 9.7.  On older org the header argument
is not merely unsupported but silently ignored, and the block runs
synchronously in the comint session — worse than no session at all,
since a command that asks a question then blocks emacs inside a buffer
the user never sees.  Probing the feature rather than the org version
also keeps Emacs 29 working once org is upgraded from ELPA."
  (if (member lang '("sh" "bash" "shell"))
      (and (require 'ob-shell nil t)
           (boundp 'ob-shell-async-indicator))
    t))

(defun devops--async-session-cells (params block-params lang tag target)
  "Return the :session and :async header cells to inject, or nil.
PARAMS and BLOCK-PARAMS are as in `devops--header-cell', LANG is the
block's language, and TAG and TARGET the heading's resolved target.
Nothing is injected unless `devops-enable-session-async' is on, LANG is
in `devops-async-session-languages' and supported by the running org
\(see `devops--lang-async-p'), and we are executing on the user's
behalf rather than under `devops-with-sync'.

What the block already says is left alone, so per-block escape hatches
need no new syntax: `:async no' runs one block synchronously in the
heading's session, `:session none' gives it neither a session nor async,
and `:session other' attaches it to a session of the user's choosing."
  (when (and devops-enable-session-async
             (not devops--inhibit-async)
             (member lang devops-async-session-languages)
             (devops--lang-async-p lang))
    (let* ((declared (devops--session-declared-p params block-params lang))
           (session (cdr (devops--header-cell :session params block-params))))
      (unless (and declared (equal session "none"))
        (append
         (unless declared
           (list (cons :session (devops--session-name tag target))))
         (unless (devops--header-cell :async params block-params)
           (list (cons :async "yes"))))))))

(defun devops--inject-header-args-from-tags (orig-fn &optional arg info params executor-type)
  "Advise org-babel-execute-src-block to inject :dir from #+TARGET tags.
An explicit :dir wins: the heading's target is neither resolved nor
prompted for when the block already carries one.  `:target nil' opts the
block out of the heading's target without naming a directory, leaving
:dir to org.

When the heading's target is what supplies :dir, the same lookup can also
supply :session and :async; see `devops--async-session-cells'.  A block
that named its own :dir is running somewhere devops did not choose, so it
gets no session either."
  (let* ((block-info (devops--block-info info))
         (block-params (nth 2 block-info))
         (pair (unless (or (devops--target-opted-out-p params block-params)
                           (devops--header-cell :dir params block-params))
                 (devops--heading-target)))
         (params (if pair
                     ;; Ours first: within one alist `org-babel-merge-params'
                     ;; lets a later pair overwrite an earlier one, so an
                     ;; explicit PARAMS from the caller still wins.
                     (append (cons (cons :dir (cdr pair))
                                   (devops--async-session-cells
                                    params block-params (nth 0 block-info)
                                    (car pair) (cdr pair)))
                             params)
                   params)))
    (apply orig-fn arg info params (and executor-type (list executor-type)))))

(advice-add 'org-babel-execute-src-block :around #'devops--inject-header-args-from-tags)

(defun devops--heading-session-name ()
  "Return the session name for the current heading's target.
Signal a `user-error' if no tag on the heading names a target."
  (let ((pair (or (devops--heading-target)
                  (user-error "No #+TARGET match for tags on current heading"))))
    (devops--session-name (car pair) (cdr pair))))

;;;###autoload
(defun devops-goto-session ()
  "Pop to the session buffer for the current heading's target.
Under `devops-enable-session-async' a command that asks a question — sudo,
an ssh host key confirmation, apt — no longer freezes emacs: the prompt
sits in the session buffer waiting for an answer.  This is how to get
there and answer it."
  (interactive)
  (let ((name (devops--heading-session-name)))
    (pop-to-buffer
     (or (get-buffer name)
         (user-error "No session %s yet; run a block under this heading" name)))))

;;;###autoload
(defun devops-restart-session ()
  "Kill the session buffer for the current heading's target.
The next block run under the heading starts a fresh shell, at the
target's directory and with none of the state — `cd', `export', an
activated virtualenv — that earlier blocks left behind."
  (interactive)
  (let* ((name (devops--heading-session-name))
         (buf (get-buffer name)))
    (if (not buf)
        (message "No session %s" name)
      ;; A live comint process would otherwise ask for confirmation, which
      ;; is the whole point of the command.
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf))
      (message "Killed session %s" name))))

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
driven noninteractively (e.g. from a pod or a test).

Runs under `devops-with-sync': a noweb reference that executes a block
must resolve to the block's output, and under `:async' it would resolve
to a UUID placeholder — which is then what gets written to the file on
the server."
  (devops-with-sync
    (let ((results nil))
      (dolist (entry spec)
        (let* ((tag (plist-get entry :tag))
               (target (plist-get entry :target))
               (heading-pos (plist-get entry :heading-pos))
               (n (devops--tangle-heading source-buf heading-pos tag target)))
          (when n
            (push (list tag target n) results))))
      (nreverse results))))

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

;;; devops.el ends here
