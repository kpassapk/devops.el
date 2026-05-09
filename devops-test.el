;; devops-test.el --- Tests for devops.el  -*- lexical-binding: t; -*-

(require 'ert)
(require 'devops)

(ert-deftest devops--parse-server-keyword-test ()
  "Parse #+SERVER value into (TAG . SERVER)."
  (should (equal (devops--parse-server-keyword "server1 (source)")
                 '("source" . "server1")))
  (should (equal (devops--parse-server-keyword "server2 (target)")
                 '("target" . "server2")))
  (should (null (devops--parse-server-keyword "malformed"))))

(ert-deftest devops-server-tag-alist-test ()
  "Build tag->server alist from #+SERVER keywords."
  (with-temp-buffer
    (org-mode)
    (insert "#+SERVER: server1 (source)\n"
            "#+SERVER: server2 (target)\n"
            "#+TITLE: Test\n"
            "\n"
            "* Heading\n")
    (should (equal (devops-server-tag-alist)
                   '(("source" . "server1")
                     ("target" . "server2"))))))

(ert-deftest devops-resolve-server-for-tag-test ()
  "Resolve a tag to a server name."
  (with-temp-buffer
    (org-mode)
    (insert "#+SERVER: server1 (source)\n"
            "#+SERVER: server2 (target)\n"
            "#+TITLE: Test\n"
            "\n"
            "* Heading\n")
    (should (equal (devops-resolve-server-for-tag "source") "server1"))
    (should (equal (devops-resolve-server-for-tag "target") "server2"))
    (should (null (devops-resolve-server-for-tag "unknown")))))

(ert-deftest devops-set-header-args-from-tag-test ()
  "Set header-args property based on heading tag and #+SERVER."
  (with-temp-buffer
    (org-mode)
    (insert "#+SERVER: server1 (source)\n"
            "#+SERVER: server2 (target)\n"
            "#+TITLE: Test\n"
            "\n"
            "* Download file\t\t:source:\n")
    (goto-char (point-max))
    (org-back-to-heading)
    (devops-set-header-args-from-tag)
    (should (equal (org-entry-get nil "header-args")
                   ":dir /ssh:app@server1:"))))

(ert-deftest devops-set-header-args-from-tag-no-match-test ()
  "Error when no #+SERVER matches the heading's tags."
  (with-temp-buffer
    (org-mode)
    (insert "#+SERVER: server1 (source)\n"
            "\n"
            "* Heading\t\t:unknown:\n")
    (goto-char (point-max))
    (org-back-to-heading)
    (should-error (devops-set-header-args-from-tag)
                  :type 'user-error)))

(ert-deftest devops--heading-server-tag-test ()
  "Find matching server tag on current heading."
  (with-temp-buffer
    (org-mode)
    (insert "#+SERVER: server1 (source)\n"
            "\n"
            "* Deploy\t\t:source:\n")
    (goto-char (point-max))
    (org-back-to-heading)
    (should (equal (devops--heading-server-tag)
                   '("source" . "server1")))))

(ert-deftest devops--heading-server-tag-no-match-test ()
  "Return nil when heading tags don't match any server."
  (with-temp-buffer
    (org-mode)
    (insert "#+SERVER: server1 (source)\n"
            "\n"
            "* Heading\t\t:other:\n")
    (goto-char (point-max))
    (org-back-to-heading)
    (should (null (devops--heading-server-tag)))))

(ert-deftest devops--rewrite-tangle-paths-test ()
  "Rewrite :tangle paths to include TRAMP prefix."
  (with-temp-buffer
    (org-mode)
    (insert "#+TITLE: Test\n"
            "\n"
            "* Heading\n"
            "\n"
            "#+begin_src sh :tangle ~/foo.txt\n"
            "echo hello\n"
            "#+end_src\n"
            "\n"
            "#+begin_src sh :tangle ~/bar.conf\n"
            "key=val\n"
            "#+end_src\n"
            "\n"
            "#+begin_src sh\n"
            "echo no tangle\n"
            "#+end_src\n")
    (devops--rewrite-tangle-paths "/ssh:app@server1:")
    (goto-char (point-min))
    (should (search-forward ":tangle /ssh:app@server1:~/foo.txt" nil t))
    (should (search-forward ":tangle /ssh:app@server1:~/bar.conf" nil t))
    ;; Block without :tangle untouched
    (goto-char (point-min))
    (should-not (search-forward ":tangle /ssh:app@server1:no" nil t))))

(ert-deftest devops--rewrite-tangle-paths-skip-absolute-test ()
  "Don't rewrite :tangle paths that are already absolute."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\n"
            "\n"
            "#+begin_src sh :tangle /ssh:app@server1:~/already.txt\n"
            "echo hello\n"
            "#+end_src\n")
    (devops--rewrite-tangle-paths "/ssh:app@server1:")
    (goto-char (point-min))
    ;; Should not double-prefix
    (should-not (search-forward "/ssh:app@server1:/ssh:" nil t))))

(ert-deftest devops-tangle-no-server-tag-test ()
  "Error when current heading has no matching server tag."
  (with-temp-buffer
    (org-mode)
    (insert "#+SERVER: server1 (source)\n"
            "\n"
            "* Heading\t\t:unknown:\n"
            "\n"
            "#+begin_src sh :tangle ~/foo.txt\n"
            "echo hello\n"
            "#+end_src\n")
    (goto-char (point-max))
    (org-back-to-heading)
    (should-error (devops-tangle)
                  :type 'user-error)))

(provide 'devops-test)
