;;; devops.el --- Infrastructure as an org file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kyle S Passarelli

;; Author: Kyle S Passarelli <kyle.passarelli@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; Maintainer: Kyle S Passarelli <kyle.passarelli@gmail.com>
;; URL: https://github.com/kpassapk/devops.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
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
;; `devops.el' adds TARGET syntax for running org-babel commands
;; on remote servers.
;;
;; Example: 
;;
;; #+TARGET: /ssh:example1.com: (server1)
;; #+TARGET: /ssh:example2.com: (server2)
;;
;; * Do something on server1               :server1:
;; 
;; #+BEGIN_SRC sh
;; hostname
;; #+END_SRC
;;
;; #+RESULTS:
;; : example1.com
;; 
;; * Do something on server2               :server2:
;; 
;; #+BEGIN_SRC sh
;; hostname
;; #+END_SRC
;;
;; #+RESULTS:
;; : example2.com
;;
;; This helps separate "what to run" and "where to run it".
;;
;; Building on this syntax, `devops.el' supports
;; - multiple targets
;; - async execution
;; - tangling (uploading) files to remote servers
;; - drift detection
;; - DWIM shell commands

;;; Code:

(require 'cl-lib)  ; cl-progv
(require 'org)
(require 'org-element)  ; org-element-property / org-element-at-point
(require 'ob-tangle)    ; advised below: org-babel-tangle-collect-blocks
(require 'tramp)  ; tramp-tramp-file-p / tramp-dissect-file-name etc. are used
                  ; below; autoloaded interactively but not under `emacs -Q'.

(defgroup devops nil
  "Manage infrastructure as org files."
  :group 'tools
  :prefix "devops-")

(defcustom devops-terminal-program 'ghostty
  "Terminal program to use for externally opening target locations."
  :type '(choice (const ghostty))
  :group 'devops)

(defcustom devops-enable-session-async nil
  "When non-nil, run blocks under a target-tagged heading in an async session.
A src block then gets `:session' and `:async' injected alongside its
`:dir', so Emacs returns immediately with a placeholder and the output
lands in the results block when the command finishes.  A command that
asks a question waits in the session buffer instead of hanging Emacs;
`devops-goto-session' goes there.

Off by default, because a session makes blocks stateful: `cd', `export',
an activated virtualenv and `ssh-agent' survive from one block to the
next, which is useful but costs idempotency.  A block that passed in a
dirty session may fail in a fresh one, so prefer blocks that do not
depend on the ones above them, and use `devops-restart-session' to get
back to a known state.

A shell block with
`:results value' — whose result is its exit status — runs synchronously
too, because under `:async' ob-shell returns the whole output instead."
  :type 'boolean
  :group 'devops)

(defcustom devops-session-name-function
  (lambda (tag target) (format "devops:%s %s" tag target))
  "Function mapping a target TAG and TARGET to a session name.
A shell session name is a buffer name in a single global namespace, so a
bare tag like \"web\" would collide with anything else that picked the
same word — including another org file whose \"web\" tag points at a
different host.  Sending commands to the wrong machine is the worst
failure this package can have, so the default prefixes `devops:' and
folds in the resolved TARGET: a session is a shell on one host, and a
tag whose target moves — a dynamic target, or two files reusing a tag —
must not reuse a shell that was started somewhere else.

TARGET is used verbatim.  Buffer names take any characters, and two
TRAMP prefixes that differ textually are two different connections, so
nothing is gained by normalising it.  Two tags on the identical target
share a session, which is the same host and directory anyway."
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
a UUID placeholder.  Anything that reads that value — a `:var' or
`#+call:' argument naming a block, a noweb reference that executes one,
`devops-tangle-headline', a drift check — needs the real thing, so it
runs inside this macro.  Interactive \\[org-ctrl-c-ctrl-c]
gets async; everything scripted gets synchronous evaluation unless it
asks otherwise."
  (declare (indent 0) (debug t))
  `(let ((devops--inhibit-async t))
     ,@body))

(defun devops--parse-target-keyword (value)
  "Parse a #+TARGET VALUE like \"target1 (source)\" into (TAG . TARGET).
TARGET is a directory, a TRAMP prefix, or a reference to a named block
written in noweb's brackets, `<<NAME>>' or `<<NAME(ARGS)>>'.  A reference
is kept as written: it is resolved when the tag is looked up, see
`devops--resolve-target-for-tag'."
  (when (string-match "\\`\\(<<.*>>\\|[^ ]+\\) +(\\([^)]+\\))\\'" value)
    (cons (match-string 2 value) (match-string 1 value))))

(defun devops--org-keywords (key)
  "Return all values for keyword KEY as a list."
  (cdr (assoc key (org-collect-keywords (list key)))))

(defun devops-target-tag-alist ()
  "Return alist of (TAG . TARGET) from #+TARGET keywords in current buffer."
  (delq nil (mapcar #'devops--parse-target-keyword
                    (devops--org-keywords "TARGET"))))

(defun devops-target-ref (target)
  "Return the reference inside TARGET, a #+TARGET value, or nil if literal.
For \"<<server-target()>>\" that is \"server-target()\", the form
`org-babel-ref-resolve' reads."
  (and (string-match "\\`<<\\(.+\\)>>\\'" target)
       (match-string 1 target)))

(defvar devops--resolving-tags nil
  "Tags whose target references are being resolved, innermost first.
Resolving a reference runs its block, and running a block resolves the
target of the heading it sits under.  A block under the tag it defines
would therefore ask for itself without end; the list lets that be an
error instead.")

(defun devops--target-value-string (value)
  "Return VALUE, a resolved reference, as a trimmed string, or nil.
A shell block with `:results value' hands its one line back as a
one-cell table, which is unwrapped; anything that is not text is nil."
  (while (and (consp value) (null (cdr value)))
    (setq value (car value)))
  (and (stringp value) (string-trim value)))

(defun devops--target-from-ref (tag ref)
  "Resolve REF, the reference in TAG's #+TARGET keyword, to a target.
REF is resolved by `org-babel-ref-resolve', so it names a block in this
buffer and honours whatever advises that function.  As in noweb, a bare
NAME is the text of a literal block -- an example or fixed-width block --
and NAME() runs a src block for its value.  A bare NAME that turns out to
be a src block is refused rather than run, so the keyword says what it
does.  The value must be one non-empty line: a target is a directory or
a TRAMP prefix, and anything longer is a block that printed more than
its answer."
  (when (member tag devops--resolving-tags)
    (user-error "Target %s: %s runs under its own tag" tag ref))
  (when (and (not (string-match-p "(" ref))
             (org-babel-find-named-block ref))
    (user-error "Target %s: %s is a src block; write <<%s()>> to run it"
                tag ref ref))
  (let* ((devops--resolving-tags (cons tag devops--resolving-tags))
         (value (devops--target-value-string
                 (save-excursion (org-babel-ref-resolve ref)))))
    (when (or (null value)
              (string-empty-p value)
              (string-match-p "\n" value))
      (user-error "Target %s: %s must yield one line, got %S" tag ref value))
    value))

(defun devops--resolve-target-for-tag (tag)
  "Look up TAG in #+TARGET keywords, return target name or nil.
A target written as a reference is resolved here, at lookup, so only the
tags a heading carries have their blocks run, and a value that changes
between runs -- a CLI input, a database row -- is read each time."
  (when-let* ((target (cdr (assoc tag (devops-target-tag-alist)))))
    (if-let* ((ref (devops-target-ref target)))
        (devops--target-from-ref tag ref)
      target)))

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
`completing-read', allowing the user to select one.  The tag is kept
alongside the target because both name the session, see
`devops-session-name-function': two tags on the same host mean two
directories, hence two targets and two sessions."
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
If there is more than one target, use `completing-read', allowing the
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
      (and (derived-mode-p 'org-mode)
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
         (lang-default (and sym (boundp sym) sym)))
    (cl-progv (cons 'org-babel-default-header-args
                    (and lang-default (list lang-default)))
        nil
      (and (derived-mode-p 'org-mode)
           (nth 2 (org-babel-get-src-block-info 'no-eval))))))

(defun devops--session-declared-p (params block-params lang)
  "Non-nil when the block, not org, decided its `:session'.
PARAMS are the merged header arguments, BLOCK-PARAMS the block's own
and LANG its language.
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

(defun devops--result-params (params)
  "Return the list of result parameters in PARAMS, or nil.
Processed header arguments carry `:result-params' ready-made; the
unprocessed ones `org-babel-get-src-block-info' returns under `no-eval'
only have the `:results' string, which is split the way
`org-babel-process-params' would."
  (or (cdr (assq :result-params params))
      (when-let* ((results (cdr (assq :results params))))
        (split-string results))))

(defun devops--shell-value-p (lang params block-params)
  "Non-nil when a shell block's result is its exit status.
LANG is the block's language; PARAMS and BLOCK-PARAMS are as in
`devops--header-cell'.  Mirrors the `value-is-exit-status' test in
`org-babel-sh-evaluate': `:results value' asks for it outright, and a
bare `:results replace' means it when
`org-babel-shell-results-defaults-to-output' is off.

Under `:async' ob-shell gets this wrong.  The exit status is the last
line of the session's output, and the trim that keeps only that line
runs on the UUID placeholder returned at once, not on the output that
arrives later — so the results block fills with everything the block
printed, exit status last.  Such a block is run synchronously instead."
  (when (member lang '("sh" "bash" "shell"))
    (let ((result-params
           (or (devops--result-params params)
               (devops--result-params block-params))))
      (or (member "value" result-params)
          (and (equal '("replace") result-params)
               (not (bound-and-true-p
                     org-babel-shell-results-defaults-to-output)))))))

(defun devops--async-session-cells (params block-params lang tag target)
  "Return the :session and :async header cells to inject, or nil.
PARAMS and BLOCK-PARAMS are as in `devops--header-cell', LANG is the
block's language, and TAG and TARGET the heading's resolved target.
Nothing is injected unless `devops-enable-session-async' is on, LANG is
in `devops-async-session-languages', and we are executing on the user's
behalf rather than under `devops-with-sync'.  A shell block whose result
is its exit status is left alone too; see `devops--shell-value-p'.

What the block already says is left alone, so per-block escape hatches
need no new syntax: `:async no' runs one block synchronously in the
heading's session, `:session none' gives it neither a session nor async,
and `:session other' attaches it to a session of the user's choosing."
  (when (and devops-enable-session-async
             (not devops--inhibit-async)
             (member lang devops-async-session-languages)
             (not (devops--shell-value-p lang params block-params)))
    (let* ((declared (devops--session-declared-p params block-params lang))
           (session (cdr (devops--header-cell :session params block-params))))
      (unless (and declared (equal session "none"))
        (append
         (unless declared
           (list (cons :session (devops--session-name tag target))))
         (unless (devops--header-cell :async params block-params)
           (list (cons :async "yes"))))))))

(defun devops--inject-header-args-from-tags (args)
  "Advise `org-babel-execute-src-block' to inject :dir from #+TARGET tags.
An explicit :dir wins: the heading's target is neither resolved nor
prompted for when the block already carries one.  `:target nil' opts the
block out of the heading's target without naming a directory, leaving
:dir to org.

When the heading's target is what supplies :dir, the same lookup can also
supply :session and :async; see `devops--async-session-cells'.  A block
that named its own :dir is running somewhere devops did not choose, so it
gets no session either.

ARGS is the whole argument list of `org-babel-execute-src-block', of
which only PARAMS -- its third -- is rewritten.  A `:filter-args' advice
rather than an `:around' one because that is all this does: naming the
arguments to pass them on again couples devops to how many there are,
which is how a block ran without its EXECUTOR-TYPE on org 9.6."
  (let* ((info (nth 1 args))
         (params (nth 2 args))
         (block-info (devops--block-info info))
         (block-params (nth 2 block-info))
         (pair (unless (or (devops--target-opted-out-p params block-params)
                           (devops--header-cell :dir params block-params))
                 (devops--heading-target))))
    (if (not pair)
        args
      (let ((params
             ;; Ours first: within one alist `org-babel-merge-params'
             ;; lets a later pair overwrite an earlier one, so an
             ;; explicit PARAMS from the caller still wins.
             (append (cons (cons :dir (cdr pair))
                           (devops--async-session-cells
                            params block-params (nth 0 block-info)
                            (car pair) (cdr pair)))
                     params))
            ;; Called with fewer than three arguments -- the interactive
            ;; case passes none -- PARAMS still needs a slot to land in.
            ;; Pad, never truncate: an argument org adds later travels on
            ;; untouched.
            (args (append args (make-list (max 0 (- 3 (length args))) nil))))
        (append (list (nth 0 args) (nth 1 args) params) (nthcdr 3 args))))))

(defun devops--resolve-ref-sync (fn &rest args)
  "Run `org-babel-ref-resolve' (FN with ARGS) under `devops-with-sync'.
Resolving a reference -- a `:var' naming a block, a `#+call:' argument,
a noweb `<<name()>>' -- may execute that block, and the caller binds
whatever comes back.  Under `:async' that is a UUID placeholder, which a
shell block then prints as its own output, and the session's async
filter later mistakes the caller's result for the reference's."
  (devops-with-sync
    (apply fn args)))


;;;###autoload
(define-minor-mode devops-mode
  "Run org-babel blocks on the target their heading's tag names.
With the mode on, a block under a heading whose tag a #+TARGET keyword
maps gets that target as its :dir (and, see
`devops-enable-session-async', a session), and a reference to a block --
a `:var', a `#+call:' argument, a noweb `<<name()>>' -- is resolved
synchronously.  Off, org evaluates blocks as it would without devops.
The mode only adds and removes advice on org functions; `devops-tangle'
and `devops-drift' redirect files whether it is on or not."
  :global t
  :group 'devops
  (if devops-mode
      (progn
        (advice-add 'org-babel-execute-src-block :filter-args
                    #'devops--inject-header-args-from-tags)
        (advice-add 'org-babel-ref-resolve :around
                    #'devops--resolve-ref-sync))
    (advice-remove 'org-babel-execute-src-block
                   #'devops--inject-header-args-from-tags)
    (advice-remove 'org-babel-ref-resolve #'devops--resolve-ref-sync)))

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

(defvar devops--tangle-redirect nil
  "Function deciding where `org-babel-tangle' writes each block, or nil.
It is called with a block's :tangle value, its header arguments and
FILE, the file org would write the block to, and returns the file to
write instead, or nil to leave the block out (or (FILE . AS-IF), see
`devops--redirect-tangle-plan').  Bound only while devops
tangles, see `devops--tangle-subtree'; while it is nil, tangling is
org's own.")

(defun devops--relink (link from to)
  "Make LINK, relative to directory FROM, relative to directory TO.
LINK is the `:comments link' target org stored for a block.  Under
`org-babel-tangle-use-relative-file-links' it is a file: link relative
to the directory the block was going to be written to, FROM.  Written
to TO instead, the block needs it relative to TO; on another machine
`file-relative-name' yields an absolute name, the only one that works
there.  Any other LINK is returned unchanged."
  (if (and link (string-match "\\`file:\\(.*?\\)\\(::.*\\)?\\'" link))
      (let ((path (match-string 1 link))
            (search (or (match-string 2 link) "")))
        (if (file-name-absolute-p path)
            link
          (concat "file:"
                  (file-relative-name (expand-file-name path from) to)
                  search)))
    link))

(defun devops--redirect-tangle-plan (plan)
  "Send each block in PLAN where `devops--tangle-redirect' says.
PLAN is what `org-babel-tangle-collect-blocks' returns: a list of
\(FILE (LANG . SPEC) ...) that `org-babel-tangle' then writes out, one
FILE at a time.  It is the only place org looks for a destination, so
redirecting here changes where blocks land without touching the org
text, and leaves the writing itself (`:mkdirp', `:shebang',
`:tangle-mode', skipping an unchanged file) to org.  Blocks are regrouped
by their new file, in their original order, so several blocks bound for
one file still end up in it together.

A redirect may also return (FILE . AS-IF): the block is written to FILE
as though it were AS-IF, which only matters to a `:comments link'.  A
drift check uses this to tangle a stand-in copy whose link reads exactly
as the deployed file's does."
  (if (not devops--tangle-redirect)
      plan
    (let (out)
      (dolist (group plan)
        (dolist (block (cdr group))
          (let* ((spec (copy-sequence (cdr block)))
                 (params (nth 4 spec))
                 (path (cdr (assq :tangle params)))
                 (dest (funcall devops--tangle-redirect
                                path params (car group)))
                 (file (if (consp dest) (car dest) dest))
                 (as-if (if (consp dest) (cdr dest) dest)))
            (when file
              ;; Org made the link relative to where the block was headed,
              ;; the directory of PATH read from here.
              (setf (nth 2 spec)
                    (devops--relink (nth 2 spec)
                                    (file-name-directory (expand-file-name path))
                                    (file-name-directory as-if)))
              (let ((cell (assoc file out)))
                (unless cell
                  (push (setq cell (list file)) out))
                (push (cons (car block) spec) (cdr cell)))))))
      (mapcar (lambda (cell) (cons (car cell) (nreverse (cdr cell))))
              (nreverse out)))))

(defun devops--tangle-subtree (source-buf heading-pos redirect)
  "Tangle the subtree at HEADING-POS in SOURCE-BUF, sending blocks by REDIRECT.
REDIRECT is bound as `devops--tangle-redirect' for the duration.  Return
the files `org-babel-tangle' wrote.

The org buffer is tangled where it is, narrowed to the subtree, and is
neither changed nor saved: `save-buffer' is taken out of
`org-babel-pre-tangle-hook', and every other hook runs as usual.  Header
arguments resolve as they always do, inherited from parent headings and
#+PROPERTY lines outside the subtree; relative paths, `:tangle yes' and
`:comments link' resolve against the org file.

A buffer that visits no file is lent a file name meanwhile, because
`org-babel-tangle' resolves paths against one and fails without it.  The
name is in the buffer's directory, so blocks resolve against that, and
names no file, so no other buffer can be visiting it.

The plan is redirected by an advice on `org-babel-tangle-collect-blocks'
that is in place only while this runs, so an `org-babel-tangle' of the
user's own never passes through devops."
  (with-current-buffer source-buf
    (let ((org-babel-pre-tangle-hook
           (remq 'save-buffer org-babel-pre-tangle-hook))
          (devops--tangle-redirect redirect)
          (tangle (lambda ()
                    (org-with-wide-buffer
                     (goto-char heading-pos)
                     (org-narrow-to-subtree)
                     (org-babel-tangle)))))
      (advice-add 'org-babel-tangle-collect-blocks
                  :filter-return #'devops--redirect-tangle-plan)
      (unwind-protect
          ;; Not `org-base-buffer-file-name', which Org 9.7 lacks.
          (if (buffer-file-name (buffer-base-buffer))
              (funcall tangle)
            (let ((buffer-file-name
                   (make-temp-name (expand-file-name "devops-unsaved-"))))
              (funcall tangle)))
        (advice-remove 'org-babel-tangle-collect-blocks
                       #'devops--redirect-tangle-plan)))))

(defun devops--tangle-destination (target path params file)
  "Return the file a block with :tangle PATH is written to on TARGET.
PARAMS are the block's header arguments and FILE is where org itself
would write it.  A relative PATH lands under TARGET's directory, an
absolute one at that path on TARGET's machine, see `devops--join-target'.

FILE stands when there is no path to retarget: for `:tangle yes', which
names a file after the org file; for a PATH that already names its
machine; and for a block that opted out with `:target nil', since the
target is off for tangling exactly as it is for execution."
  (if (or (string= path "yes")
          (tramp-tramp-file-p path)
          (devops--target-opted-out-p nil params))
      file
    (devops--join-target target path)))

(defun devops--tangle-heading (source-buf heading-pos target)
  "Tangle subtree at HEADING-POS from SOURCE-BUF to TARGET.
Return the number of files tangled, or nil.

A relative local TARGET (e.g. \".\" or \"../foo\") is expanded against
SOURCE-BUF's directory, like the blocks' own relative paths.  TRAMP
targets are left untouched."
  (let* ((target (if (tramp-tramp-file-p target)
                     target
                   (expand-file-name
                    target (buffer-local-value 'default-directory source-buf))))
         (files (devops--tangle-subtree
                 source-buf heading-pos
                 (lambda (path params file)
                   (devops--tangle-destination target path params file)))))
    (when files (length files))))

(defun devops--tangle-spec (&optional arg)
  "Return a tangle plan for the current buffer.
Each entry is a plist (:tag TAG :target TARGET :heading-pos POS).

With prefix ARG non-nil, include all target-tagged headings.  A heading
is included for a tag only where its parent heading does not have the
tag: below that, the heading is already part of the subtree tangled for
it, and including it again would tangle it twice.  Matching only a
heading's own tags would not do, since a child may repeat its parent's
tag, and a tag from #+FILETAGS is no heading's own.

Otherwise include only the current heading."
  (if arg
      (let (specs)
        (org-map-entries
         (lambda ()
           (dolist (pair (let ((parent-tags (save-excursion
                                              (and (org-up-heading-safe)
                                                   (org-get-tags)))))
                           (seq-remove (lambda (pair)
                                         (member (car pair) parent-tags))
                                       (devops--heading-target-tags))))
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
               (n (devops--tangle-heading source-buf heading-pos target)))
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
Resolves the heading's target tag to a TRAMP path and has
`org-babel-tangle' write each block's :tangle path there.

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
of (TAG TARGET N) results.  SOURCE-BUF must be an `org-mode' buffer.

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
an `org-mode' buffer.

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
argument.  SOURCE-BUF must be an `org-mode' buffer."
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
  "Visit the file the source code block at point tangles to.
If the block tangles to several files, prompt for one; with prefix
ARG, visit it in another window."
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
  "Return a ghostty command line opening a shell in DIR.
DIR may be remote, in which case ghostty runs ssh to its host.  ENV-VARS
is an alist of (NAME . VALUE) exported in that shell."
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
  "Open `devops-terminal-program' in DIR with ENV-VARS exported."
  (pcase devops-terminal-program
    ('ghostty
     (let ((ghostty (devops--ghostty-command dir env-vars)))
       (message "Calling process:\n%s" (string-join ghostty " "))
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

(defun devops-unload-function ()
  "Turn `devops-mode' off, so `unload-feature' leaves no advice behind.
Return nil, so the rest of the unloading proceeds as usual."
  (devops-mode -1)
  nil)

(provide 'devops)

;;; devops.el ends here
