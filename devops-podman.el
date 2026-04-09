(defun devops-create-podman-secrets (secrets)
  "Create Podman secrets.
SECRETS is a list of (secret-name auth-user) rows."
  (dolist (pair (devops--resolve-secrets-table secrets))
    (let* ((secret-name (car pair))
           (password (nth 1 pair))
           (cmd (format "printf '%%s' %s | podman secret create --replace %s -"
                        (shell-quote-argument password)
                        (shell-quote-argument secret-name))))
      (message "Creating secret %s ..." secret-name)
      (shell-command cmd)
      (message "Creating secret %s ... done" secret-name))))

(provide 'devops-podman)
