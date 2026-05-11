;; devops-migration.el -- Provides commands for starting and locating a migration  -*- lexical-binding: t; -*- 
(require 'magit)

(cl-defun devops--create-worktree
    (&key
     (dir (project-root (project-current)))
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

(provide 'devops-migration)
