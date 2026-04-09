;;;###autoload
(defun devops-incident (slug)
  "Create an incident worktree and notebook"
  (interactive "sSlug:")
  (let ((type "incident")
	(stamp (devops--new-timestamp)))
    (devops--create-worktree :type type :stamp stamp)))

