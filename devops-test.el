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
                   ":dir app@server1:"))))

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

(provide 'devops-test)
