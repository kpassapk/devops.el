;;; devops-log.el --- Execution log for devops.el -*- lexical-binding: t; -*-

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
;; Write the entries of `devops-execution-log'.  devops.el decides when
;; something is logged; this file decides what the line says.  It tells
;; an agent what the user did -- ran a block, got an async result,
;; tangled, checked drift -- by appending a JSON line per event.
;;
;; A line is a notification, not a record: it says what happened and
;; where, and carries no output, #+RESULTS or diff.  The agent reads
;; those with `devops-scripting-block-output' or the drift functions.
;; That keeps lines short, so appends from several Emacsen don't
;; interleave and the file grows slowly, and keeps secrets out of it.

;;; Code:

(require 'devops)
(require 'devops-scripting)
(require 'json)

(defun devops-log-append (entry)
  "Append ENTRY, an alist, to `devops-execution-log' as a JSON line.
The log's directory is created on the first write."
  (let ((file (expand-file-name devops-execution-log))
        (line (concat (json-encode entry) "\n")))
    (make-directory (file-name-directory file) t)
    (write-region line nil file t 'silent)))

(defun devops-log--header (event)
  "Return the fields every entry for EVENT starts with, an alist."
  `((:time . ,(format-time-string "%FT%T%z"))
    (:event . ,event)
    (:file . ,(buffer-file-name (buffer-base-buffer)))
    (:buffer . ,(buffer-name))))

(defun devops-log--block-entry (event pos)
  "Return the log entry for EVENT on the src block at POS, an alist.
The block's line, and its session, status and id from
`devops-scripting-block-output'.  A block that answer cannot be had for
-- a heading with no target, or two -- is logged with the error."
  (let ((line (line-number-at-pos pos)))
    `(,@(devops-log--header event)
      (:line . ,line)
      ,@(condition-case err
            (let ((answer (devops-scripting-block-output
                           (current-buffer) line)))
              (delq nil (mapcar (lambda (key) (assq key answer))
                                '(:session :status :id))))
          (error `((:error . ,(error-message-string err))))))))

;;;###autoload
(defun devops-log-block (event pos)
  "Log EVENT on the src block at POS."
  (devops-log-append (devops-log--block-entry event pos)))

(defun devops-log--heading ()
  "Return the heading at point as (:heading . TITLE) and (:line . N).
Nil before the first heading."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t) t)
      `((:heading . ,(org-get-heading t t t t))
        (:line . ,(line-number-at-pos))))))

;;;###autoload
(defun devops-log-command (event all fields)
  "Log EVENT, a command on the heading at point, with FIELDS.
ALL non-nil means the command ran on every target-tagged heading, as
with a prefix argument, and no heading is logged.  FIELDS is an alist:
the command's results, or its error."
  (devops-log-append
   `(,@(devops-log--header event)
     (:all . ,(if all t :json-false))
     ,@(unless all (devops-log--heading))
     ,@fields)))

(provide 'devops-log)

;;; devops-log.el ends here
