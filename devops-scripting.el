;;; devops-scripting.el --- Noninteractive functions for devops.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kyle S Passarelli

;; Author: Kyle S Passarelli <kyle.passarelli@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
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
;; Noninteractive functions, for a program driving devops.el from
;; outside Emacs -- a script, a coding agent -- through `emacsclient
;; --eval'.  Nothing here is a command, and nothing prompts.
;;
;; The commands in devops.el are written for a person at the keyboard:
;; they pop to buffers, ask with `completing-read' when a heading has two
;; targets, and report with `message'.  Over `emacsclient' a question is
;; a hang nobody can see, and a popped buffer is nothing.  The functions
;; here take what they need as arguments, signal a `user-error' where a
;; command would ask, and return data -- alists keyed by keywords, which
;; `json-encode' turns into objects.
;;
;; `devops-scripting-block-output' answers what a block printed in its
;; async session, which the #+RESULTS of a failed block does not hold:
;; the placeholder UUID stays, or the result is cut short, and stderr is
;; only in the session buffer.  `devops-scripting-sessions' lists the
;; async sessions and which of them is waiting on a prompt -- sudo, an
;; ssh host key -- that only a person should answer.
;;
;; The execution log goes the other way: with `devops-execution-log'
;; set, devops-log.el tells the agent when the user runs a block.

;;; Code:

(require 'devops)
(require 'comint)
(require 'json)
(require 'ob-comint)
(require 'org-element)
(require 'subr-x)

(defconst devops-scripting--uuid-regexp
  "[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}"
  "A UUID as `org-id-uuid' writes it: the ID of one async run.")

(defun devops-scripting--marker (edge id)
  "Return a regexp for the async marker of EDGE, start or end, of run ID.
ID is a regexp, so `devops-scripting--uuid-regexp' in a group finds
every run.  The language is left open: ob-shell writes
ob_comint_async_shell_..., ob-python ob_comint_async_python_..."
  (format "ob_comint_async_[a-z]+_%s_%s" edge id))

;;; Source buffers

(defun devops-scripting--source-buffer (source)
  "Return SOURCE, an org buffer or file name, as a buffer to read.
A buffer already visiting the file is used, because `find-file-noselect'
on a file changed on disk asks whether to reread it, and over
`emacsclient' nobody answers.  An unmodified buffer whose file changed is
reverted first, so that line numbers taken from the file match it."
  (let ((buf (if (bufferp source)
                 source
               (let ((file (expand-file-name source)))
                 (or (find-buffer-visiting file)
                     (find-file-noselect file))))))
    (with-current-buffer buf
      (unless (derived-mode-p 'org-mode)
        (user-error "Not an org buffer: %s" (buffer-name buf)))
      (when (and buffer-file-name
                 (not (buffer-modified-p))
                 (not (verify-visited-file-modtime buf)))
        (revert-buffer t t t)))
    buf))

(defun devops-scripting--target (tag)
  "Return the (TAG . TARGET) of the current heading, without asking.
With TAG, that tag's target; otherwise the heading's only one.  Where
`devops--heading-target' would ask with `completing-read', signal a
`user-error' naming the tags to choose from instead."
  (let ((matches (devops--heading-target-tags)))
    (cond
     (tag (or (assoc tag matches)
              (user-error "No target %s on this heading; it has %s"
                          tag (mapconcat #'car matches ", "))))
     ((null matches)
      (user-error "No #+TARGET match for tags on current heading"))
     ((cdr matches)
      (user-error "This heading has targets %s; pass one as TAG"
                  (mapconcat #'car matches ", ")))
     (t (car matches)))))

;;; Session transcripts

(defun devops-scripting--unprompt (text prompt)
  "Return TEXT without the PROMPT regexp at the start of its lines.
A comint prompt that came back while output was arriving is left at the
start of the next output line, sometimes more than once."
  (let ((prev nil))
    (while (not (equal prev text))
      (setq prev text
            text (replace-regexp-in-string prompt "" text)))
    text))

(defun devops-scripting--quoted-p (pos)
  "Whether the marker starting at POS is quoted.
The command that prints a marker -- echo \\='...\\=' in a shell,
print (\\='...\\=') in python -- is echoed into the session ahead of the marker
it prints, and the quote is what tells the two apart."
  (eq (char-before pos) ?'))

(defun devops-scripting--search-marker (edge id quoted &optional bound)
  "Search forward for the EDGE marker of run ID; its start, or nil.
QUOTED selects the echoed command printing it rather than the marker
printed.  Point moves past the match.  BOUND limits the search."
  (let ((re (devops-scripting--marker edge (regexp-quote id)))
        found)
    (while (and (not found) (re-search-forward re bound t))
      (when (eq (and (devops-scripting--quoted-p (match-beginning 0)) t)
                quoted)
        (setq found (match-beginning 0))))
    found))

(defun devops-scripting--runs (session)
  "Return every async run in the buffer SESSION, oldest first.
Each run is an alist: :id, :input as the session echoed it, :output, and
:done, nil while the end marker has not been printed.  The output
starts after the start marker printed and ends at the end marker, with
the session's prompts removed."
  (with-current-buffer session
    (let ((prompt comint-prompt-regexp)
          ids runs)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward
                (devops-scripting--marker
                 "start" (concat "\\(" devops-scripting--uuid-regexp "\\)"))
                nil t)
          (when (devops-scripting--quoted-p (match-beginning 0))
            (push (match-string-no-properties 1) ids)))
        (dolist (id (nreverse ids))
          (goto-char (point-min))
          (devops-scripting--search-marker "start" id t)
          (let* ((in-beg (line-beginning-position 2))
                 (in-end (and (devops-scripting--search-marker "end" id t)
                              (line-beginning-position)))
                 (out-beg (and in-end
                               (devops-scripting--search-marker "start" id nil)
                               (line-beginning-position 2)))
                 (out-end (and out-beg
                               (devops-scripting--search-marker "end" id nil))))
            (push `((:id . ,id)
                    (:input . ,(if in-end
                                   (buffer-substring-no-properties in-beg in-end)
                                 ""))
                    (:output . ,(if out-beg
                                    (string-trim
                                     (devops-scripting--unprompt
                                      (buffer-substring-no-properties
                                       (min out-beg (point-max))
                                       (or out-end (point-max)))
                                      prompt))
                                  ""))
                    (:done . ,(and out-end t)))
                  runs))))
      (nreverse runs))))

(defun devops-scripting--sent-p (body input)
  "Whether INPUT, as a session echoed it, is BODY sent.
Lines holding a noweb reference are skipped, because what was sent is
their expansion."
  (seq-every-p (lambda (line) (string-search line input))
               (seq-remove (lambda (line)
                             (or (string-empty-p line)
                                 (string-search "<<" line)))
                           (mapcar #'string-trim (split-string body "\n")))))

(defun devops-scripting--block-run (runs result body)
  "Return the run in RUNS of the block with RESULT and BODY, or nil.
The run whose ID is still in RESULT, else the latest that sent BODY: once
a block finishes its ID gives way to the output in #+RESULTS, and the
body is what is left to know it by."
  (let ((id (and result
                 (string-match devops-scripting--uuid-regexp result)
                 (match-string 0 result))))
    (or (and id (seq-find (lambda (run) (equal id (alist-get :id run))) runs))
        (car (last (seq-filter
                    (lambda (run) (devops-scripting--sent-p
                                   body (alist-get :input run)))
                    runs))))))

;;; Results

(defun devops-scripting--results-text ()
  "Return the #+RESULTS of the src block at point as text, or nil.
The text as it reads, without org's markup: no colon prefixes on a
fixed-width result, no example block or drawer delimiters, a table as
its rows.  Not `org-babel-read-result', which hands a table back as a
list -- data for a block's :var, but noise to a reader."
  (when-let* ((pos (org-babel-where-is-src-block-result)))
    (save-excursion
      (goto-char pos)
      (let ((el (org-element-at-point)))
        (string-trim-right
         (pcase (org-element-type el)
           ;; A #+RESULTS: line with nothing under it.
           ('keyword "")
           ((or 'fixed-width 'example-block)
            (org-element-property :value el))
           (_ (buffer-substring-no-properties
               (or (org-element-property :contents-begin el)
                   (org-element-property :post-affiliated el))
               (or (org-element-property :contents-end el)
                   (org-babel-result-end))))))))))

(defun devops-scripting--placeholder-p (result)
  "Whether RESULT is only the UUID an async block leaves while it runs."
  (and result
       (string-match-p (concat "\\`" devops-scripting--uuid-regexp "\\'")
                       (string-trim result))))

;;; Blocks

(defun devops-scripting--src-block-at (line)
  "Move to LINE and return the src block there, or signal a `user-error'.
LINE may be any line of the block, its header or its body."
  (goto-char (point-min))
  (forward-line (1- line))
  (let ((el (org-element-at-point)))
    (unless (eq (org-element-type el) 'src-block)
      (user-error "No src block at line %d" line))
    (goto-char (org-element-property :post-affiliated el))
    el))

;;;###autoload
(defun devops-scripting-block-output (source line &optional tag)
  "Return what the src block at LINE of SOURCE printed.
SOURCE is an org buffer or file name, and LINE any line of the block.
TAG names the target when the block's heading has more than one.

The answer is an alist:

  :session  the session buffer's name
  :status   `:done', `:running', `:not-found' -- the session holds no
            run of this block -- or `:no-session'
  :id       the run's async ID, when found in the session
  :source   where :output came from: `:session', `:results', or nil
  :output   what the block printed
  :result   the block's #+RESULTS as text, or nil

The session is read first.  It holds what the command printed, stderr
included, and its run is known to be this block's by ID or by what was
sent, where #+RESULTS may be the placeholder a failed run never
replaced, or cut short.  Failing that, #+RESULTS is the answer: the
session was killed or restarted, or the block never ran in one -- async
off, `:results value', `:session none', a language with no session.  A
placeholder there is not output, and :output is nil.

The target has a pool of sessions, and the block may have run in any of
them.  The one holding the ID in #+RESULTS is read, else the first, in
slot order, that holds a run of the block.

Nothing is run.  The session names are the ones devops.el would use, so
a dynamic target is resolved, and that runs its block; see
`devops--resolve-target-for-tag'."
  (with-current-buffer (devops-scripting--source-buffer source)
    (save-excursion
      (let* ((el (devops-scripting--src-block-at line))
             (pair (devops-scripting--target tag))
             (names (or (mapcar #'buffer-name
                                (devops--pool-buffers (cdr pair)))
                        (list (devops--session-name (cdr pair)))))
             (answers (mapcar (lambda (name)
                                (devops-scripting--block-output el name))
                              names))
             (result (devops-scripting--results-text))
             (id (and result
                      (string-match devops-scripting--uuid-regexp result)
                      (match-string 0 result))))
        (or (and id (seq-find (lambda (answer)
                                (equal id (alist-get :id answer)))
                              answers))
            (seq-find (lambda (answer) (alist-get :id answer)) answers)
            (car answers))))))

(defun devops-scripting--block-output (el name)
  "Return what EL, the src block at point, printed in session NAME.
The answer is `devops-scripting-block-output's."
  (let* ((result (devops-scripting--results-text))
         (session (get-buffer name))
         (run (and session
                   (devops-scripting--block-run
                    (devops-scripting--runs session)
                    result
                    (org-element-property :value el))))
         (source (cond (run :session)
                       ((and result
                             (not (devops-scripting--placeholder-p result)))
                        :results))))
    `((:session . ,name)
      (:status . ,(cond ((not session) :no-session)
                        ((not run) :not-found)
                        ((alist-get :done run) :done)
                        (t :running)))
      (:id . ,(alist-get :id run))
      (:source . ,source)
      (:output . ,(pcase source
                    (:session (alist-get :output run))
                    (:results result)))
      (:result . ,result))))

;;;###autoload
(defun devops-scripting-run-output (session id)
  "Return what the run ID printed in SESSION, a session buffer's name.
SESSION and ID are as `devops-execution-log' records a run, so a log
line is answered for that run exactly, after its block has moved,
changed or run again.

The answer is an alist:

  :session  SESSION
  :status   `:done', `:running', `:not-found' -- the session holds no
            run with ID, say after a restart -- or `:no-session'
  :id       ID
  :input    what was sent, as the session echoed it, or nil
  :output   what the run printed, stderr included, or nil

Nothing is run, and no org buffer is read: for #+RESULTS, ask
`devops-scripting-block-output'."
  (let* ((buf (get-buffer session))
         (run (and buf (seq-find (lambda (run) (equal id (alist-get :id run)))
                                 (devops-scripting--runs buf)))))
    `((:session . ,session)
      (:status . ,(cond ((not buf) :no-session)
                        ((not run) :not-found)
                        ((alist-get :done run) :done)
                        (t :running)))
      (:id . ,id)
      (:input . ,(and run (string-trim-right (alist-get :input run))))
      (:output . ,(alist-get :output run)))))

;;; Sessions

(defun devops-scripting--session-p (buf)
  "Whether BUF is a babel session that has run async blocks.
`org-babel-comint-async-register' leaves the marker regexp buffer-local
in every session it attaches to; nothing else does."
  (local-variable-p 'org-babel-comint-async-indicator buf))

(defun devops-scripting--pending-prompt (buf)
  "Return the text BUF ends on when it waits for input, or nil.
Output arrives a line at a time, so a session that ends partway through
a line, on something that is not its own prompt, is a program asking --
\"[sudo] password for app: \", a host key confirmation."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-max))
      (let ((tail (buffer-substring-no-properties
                   (line-beginning-position) (point-max))))
        (unless (or (string-blank-p tail)
                    (string-empty-p
                     (string-trim (devops-scripting--unprompt
                                   tail comint-prompt-regexp))))
          (string-trim (devops-scripting--unprompt
                        tail comint-prompt-regexp)))))))

;;;###autoload
(defun devops-scripting-sessions ()
  "Return every live babel async session, as a list of alists.

  :name       the session buffer's name
  :directory  where it runs: the target, a TRAMP prefix or directory
  :state      `:idle', `:running', or `:waiting' -- running, and stopped
              at a prompt that is not the session's own
  :prompt     the prompt it waits at, when `:waiting'
  :id         the async ID of its latest run

Every session `org-babel-comint-async-register' set up is listed, not
only those devops.el named: a block's own `:session' names one too."
  (let (sessions)
    (dolist (buf (buffer-list))
      (when (and (devops-scripting--session-p buf)
                 (comint-check-proc buf))
        (let* ((last (car (last (devops-scripting--runs buf))))
               (running (and last (not (alist-get :done last))))
               (prompt (and running (devops-scripting--pending-prompt buf))))
          (push `((:name . ,(buffer-name buf))
                  (:directory . ,(buffer-local-value 'default-directory buf))
                  (:state . ,(cond (prompt :waiting)
                                   (running :running)
                                   (t :idle)))
                  (:prompt . ,prompt)
                  (:id . ,(alist-get :id last)))
                sessions))))
    (nreverse sessions)))

(provide 'devops-scripting)

;;; devops-scripting.el ends here
