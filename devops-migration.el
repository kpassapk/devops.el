;; devops-migration.el -- Provides commands for starting and locating a migration 
(require 'magit-worktree)

(cl-defun devops--create-worktree
    (&key
     (dir default-directory)
     (type "migration")
     (stamp (devops--new-timestamp)))
  "Creates a worktree and directory structure for an incident"
  (let* ((branch (concat type "-" stamp))
	 (target (devops--worktree-directory branch :dir dir)))
    (magit-worktree-branch target branch "main")
    target))

;;;###autoload
(defun devops-migration (slug)
  "Create a migration worktree and notebook"
  (interactive "sSlug:")
  (let* ((type "migration")
	(stamp (devops--new-timestamp))
	(target (devops--create-worktree :type type :stamp stamp))
	(notebook (expand-file-name (concat "migrations/" stamp "--" slug ".org") target)))
    (find-file notebook)))

;;;###autoload
(defun devops-current-migration (&optional absolute)
  "When in a migration branch like migration-20260313T111705,
find a file in the /migrations directory whose name starts with
that timestamp, and return the path."
  (let* ((branch (magit-get-current-branch))
         (timestamp (when (string-match "migration-\\([0-9T]+\\)" branch)
                      (match-string 1 branch)))
         (migrations-dir (expand-file-name "migrations" (magit-toplevel)))
         (match (when timestamp
                  (seq-find (lambda (d)
                              (string-prefix-p timestamp d))
                            (directory-files migrations-dir nil "^[^.]")))))
    (when match
      (if absolute
          (expand-file-name match migrations-dir)
        (concat "migrations/" match)))))

(provide 'devops-migration)
