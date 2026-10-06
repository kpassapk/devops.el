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
;; Write the entries of `devops-execution-log'.  `devops-mode' decides
;; when a block run is logged; this file decides what the line says.
;; It tells an agent when the user runs a block, by appending a JSON
;; line per run, and another when an async run's result arrives.

;;; Code:

(require 'devops)
(require 'devops-scripting)
(require 'json)

(defun devops-log--entry (event pos)
  "Return the log entry for EVENT on the src block at POS, an alist.
The block's `devops-scripting-block-output' answer, with the time, the
event, and where the block is.  A block that answer cannot be had for --
a heading with no target, or two -- is logged with the error and its
#+RESULTS."
  (let ((line (line-number-at-pos pos)))
    `((:time . ,(format-time-string "%FT%T%z"))
      (:event . ,event)
      (:file . ,(buffer-file-name (buffer-base-buffer)))
      (:buffer . ,(buffer-name))
      (:line . ,line)
      ,@(condition-case err
            (devops-scripting-block-output (current-buffer) line)
          (error `((:error . ,(error-message-string err))
                   (:result . ,(save-excursion
                                 (goto-char pos)
                                 (devops-scripting--results-text)))))))))

;;;###autoload
(defun devops-log-write (event pos)
  "Append the entry for EVENT on the src block at POS to the log.
The log is `devops-execution-log'; its directory is created on the
first write."
  (let ((file (expand-file-name devops-execution-log))
        (entry (concat (json-encode (devops-log--entry event pos)) "\n")))
    (make-directory (file-name-directory file) t)
    (write-region entry nil file t 'silent)))

(provide 'devops-log)

;;; devops-log.el ends here
