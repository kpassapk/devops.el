;; devops-test.el --- Tests for devops.el  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'tramp)
(require 'devops)

;;; Helpers

(defmacro devops-test--with-org (text &rest body)
  "Run BODY in a temp `org-mode' buffer containing TEXT, point at end."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,text)
     (goto-char (point-max))
     ,@body))

(defmacro devops-test--with-local-target (dir-var &rest body)
  "Create a fresh local target directory bound to DIR-VAR for BODY.
DIR-VAR is bound to an absolute path ending in \"/\".  Used as a #+TARGET
value so tangling writes to the local filesystem (no remote/TRAMP).
The directory is removed afterwards."
  (declare (indent 1))
  `(let ((,dir-var (file-name-as-directory
                    (make-temp-file "devops-target-" t))))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,dir-var t))))

;;; Keyword parsing

(ert-deftest devops--parse-target-keyword-test ()
  "Parse #+TARGET value into (TAG . TARGET)."
  (should (equal (devops--parse-target-keyword "/ssh:host1: (server1)")
                 '("server1" . "/ssh:host1:")))
  (should (equal (devops--parse-target-keyword "/srv/app/ (local)")
                 '("local" . "/srv/app/")))
  (should (null (devops--parse-target-keyword "malformed")))
  (should (null (devops--parse-target-keyword "/no/tag/here"))))

(ert-deftest devops-target-tag-alist-test ()
  "Build tag->target alist from #+TARGET keywords."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n"
              "#+TARGET: /srv/two/ (t2)\n"
              "#+TITLE: Test\n\n"
              "* Heading\n")
    (should (equal (devops-target-tag-alist)
                   '(("t1" . "/srv/one/")
                     ("t2" . "/srv/two/"))))))

(ert-deftest devops--resolve-target-for-tag-test ()
  "Resolve a tag to its target."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n"
              "#+TARGET: /srv/two/ (t2)\n\n"
              "* Heading\n")
    (should (equal (devops--resolve-target-for-tag "t1") "/srv/one/"))
    (should (equal (devops--resolve-target-for-tag "t2") "/srv/two/"))
    (should (null (devops--resolve-target-for-tag "unknown")))))

;;; Heading tag resolution

(ert-deftest devops--heading-target-tags-test ()
  "Find matching target tags on the current heading."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n\n"
              "* Deploy\t\t:t1:\n")
    (org-back-to-heading)
    (should (equal (devops--heading-target-tags)
                   '(("t1" . "/srv/one/"))))))

(ert-deftest devops--heading-target-tags-no-match-test ()
  "Return nil when heading tags match no #+TARGET."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n\n"
              "* Heading\t\t:other:\n")
    (org-back-to-heading)
    (should (null (devops--heading-target-tags)))))

(ert-deftest devops--heading-target-dir-single-test ()
  "Return the target dir for a single matching tag."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n\n"
              "* Deploy\t\t:t1:\n")
    (org-back-to-heading)
    (should (equal (devops--heading-target-dir) "/srv/one/"))))

(ert-deftest devops--heading-target-dir-no-match-test ()
  "Return nil when no tag matches."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n\n"
              "* Heading\t\t:other:\n")
    (org-back-to-heading)
    (should (null (devops--heading-target-dir)))))

(ert-deftest devops-set-header-args-from-tags-test ()
  "Set :header-args :dir from heading tag and #+TARGET."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n\n"
              "* Download\t\t:t1:\n")
    (org-back-to-heading)
    (devops-set-header-args-from-tags)
    (should (equal (org-entry-get nil "header-args") ":dir /srv/one/"))))

;;; Target/path joining

(ert-deftest devops--join-target-test ()
  "Join a target prefix and a relative path with exactly one separator."
  ;; Directory targets with and without a trailing slash.
  (should (equal (devops--join-target "/srv/app/" "foo.txt") "/srv/app/foo.txt"))
  (should (equal (devops--join-target "/srv/app" "foo.txt") "/srv/app/foo.txt"))
  ;; Relative targets must not glue onto the filename ("." -> "./", not ".foo").
  (should (equal (devops--join-target "." "foo.txt") "./foo.txt"))
  (should (equal (devops--join-target ".." "foo.txt") "../foo.txt"))
  (should (equal (devops--join-target "./" "foo.txt") "./foo.txt"))
  (should (equal (devops--join-target "../" "foo.txt") "../foo.txt"))
  ;; TRAMP host prefix: a trailing ":" means the remote login dir, no slash.
  (should (equal (devops--join-target "/ssh:host:" "foo.txt") "/ssh:host:foo.txt"))
  ;; TRAMP path with an explicit directory still gets a single separator.
  (should (equal (devops--join-target "/ssh:host:/etc" "foo.txt")
                 "/ssh:host:/etc/foo.txt"))
  (should (equal (devops--join-target "/ssh:host:/etc/" "foo.txt")
                 "/ssh:host:/etc/foo.txt")))

;;; Tangle-path rewriting

(ert-deftest devops--rewrite-tangle-paths-test ()
  "Rewrite :tangle paths to include the target prefix."
  (devops-test--with-org
      (concat "* Heading\n\n"
              "#+begin_src sh :tangle ~/foo.txt\n"
              "echo hello\n#+end_src\n\n"
              "#+begin_src sh :tangle ~/bar.conf\n"
              "key=val\n#+end_src\n\n"
              "#+begin_src sh\n"
              "echo no tangle\n#+end_src\n")
    (devops--rewrite-tangle-paths "/ssh:host1:")
    (goto-char (point-min))
    (should (search-forward ":tangle /ssh:host1:~/foo.txt" nil t))
    (should (search-forward ":tangle /ssh:host1:~/bar.conf" nil t))))

(ert-deftest devops--rewrite-tangle-paths-skip-no-test ()
  "Don't rewrite :tangle no."
  (devops-test--with-org
      (concat "* Heading\n\n"
              "#+begin_src sh :tangle no\n"
              "echo hi\n#+end_src\n")
    (devops--rewrite-tangle-paths "/ssh:host1:")
    (goto-char (point-min))
    (should (search-forward ":tangle no" nil t))
    (goto-char (point-min))
    (should-not (search-forward ":tangle /ssh:host1:no" nil t))))

(ert-deftest devops--rewrite-tangle-paths-skip-tramp-test ()
  "Don't double-prefix a path that is already a TRAMP path."
  (devops-test--with-org
      (concat "* Heading\n\n"
              "#+begin_src sh :tangle /ssh:host1:~/already.txt\n"
              "echo hi\n#+end_src\n")
    (devops--rewrite-tangle-paths "/ssh:host1:")
    (goto-char (point-min))
    (should-not (search-forward "/ssh:host1:/ssh:" nil t))))

(ert-deftest devops--rewrite-tangle-paths-no-slash-target-test ()
  "A target without a trailing slash gets a separator inserted."
  (devops-test--with-org
      (concat "* Heading\n\n"
              "#+begin_src sh :tangle foo.txt\n"
              "echo hi\n#+end_src\n")
    (devops--rewrite-tangle-paths "/srv/app")
    (goto-char (point-min))
    (should (search-forward ":tangle /srv/app/foo.txt" nil t))))

(ert-deftest devops--rewrite-tangle-paths-relative-target-test ()
  "A \".\" target yields \"./foo.txt\", not the hidden file \".foo.txt\"."
  (devops-test--with-org
      (concat "* Heading\n\n"
              "#+begin_src sh :tangle foo.txt\n"
              "echo hi\n#+end_src\n")
    (devops--rewrite-tangle-paths ".")
    (goto-char (point-min))
    (should (search-forward ":tangle ./foo.txt" nil t))
    (goto-char (point-min))
    (should-not (search-forward ":tangle .foo.txt" nil t))))

(ert-deftest devops--rewrite-tangle-paths-skip-yes-test ()
  "Don't rewrite :tangle yes (the default-filename flag, not a path)."
  (devops-test--with-org
      (concat "* Heading\n\n"
              "#+begin_src sh :tangle yes\n"
              "echo hi\n#+end_src\n")
    (devops--rewrite-tangle-paths "/ssh:host1:")
    (goto-char (point-min))
    (should (search-forward ":tangle yes" nil t))
    (goto-char (point-min))
    (should-not (search-forward ":tangle /ssh:host1:" nil t))))

;;; Per-server noweb specialization

(ert-deftest devops--specialize-noweb-blocks-test ()
  "Keep blocks tagged with TAG, rename the others out of resolution."
  (devops-test--with-org
      (concat "* Heading\n\n"
              "#+name: tier (server1)\n"
              "#+begin_src text\n3\n#+end_src\n\n"
              "#+name: tier (server2)\n"
              "#+begin_src text\n2\n#+end_src\n")
    (devops--specialize-noweb-blocks "server1")
    (goto-char (point-min))
    (should (re-search-forward "^#\\+name: tier$" nil t))
    (goto-char (point-min))
    (should (search-forward "#+name: _devops-excluded-tier-server2" nil t))))

;;; Tangle spec

(ert-deftest devops--tangle-spec-current-heading-test ()
  "Build a one-entry spec for the current heading."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n\n"
              "* Deploy\t\t:t1:\n")
    (org-back-to-heading)
    (let ((spec (devops--tangle-spec)))
      (should (= 1 (length spec)))
      (should (equal (plist-get (car spec) :tag) "t1"))
      (should (equal (plist-get (car spec) :target) "/srv/one/")))))

(ert-deftest devops--tangle-spec-all-test ()
  "With prefix arg, build a spec covering every tagged heading."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n"
              "#+TARGET: /srv/two/ (t2)\n\n"
              "* First\t\t:t1:\n\n"
              "* Second\t\t:t2:\n")
    (let ((spec (devops--tangle-spec t)))
      (should (= 2 (length spec)))
      (should (equal (mapcar (lambda (e) (plist-get e :tag)) spec)
                     '("t1" "t2"))))))

;;; Reporting

(ert-deftest devops--tangle-report-test ()
  "Format tangle results into a status string."
  (should (equal (devops--tangle-report '(("t1" "/srv/one/" 2)))
                 "Tangled 2 file(s) to t1 (/srv/one/)"))
  (should (equal (devops--tangle-report '(("t1" "/srv/one/" 2)
                                          ("t2" "/srv/two/" 1)))
                 (concat "Tangled 2 file(s) to t1 (/srv/one/); "
                         "Tangled 1 file(s) to t2 (/srv/two/)")))
  (should (equal (devops--tangle-report nil) "No files tangled")))

;;; End-to-end tangling (local target, no remote)

(ert-deftest devops-tangle-headline-test ()
  "Tangle a named heading to a local target and check the file."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+begin_src json :tangle config.json\n"
                        "{\"name\": \"test\"}\n#+end_src\n")
                target)
      (let ((results (devops-tangle-headline (current-buffer) "Deploy")))
        (should (equal results (list (list "local" target 1))))
        (let ((out (concat target "config.json")))
          (should (file-exists-p out))
          (with-temp-buffer
            (insert-file-contents out)
            (should (search-forward "{\"name\": \"test\"}" nil t))))))))

(ert-deftest devops-tangle-all-test ()
  "Tangle every tagged heading to local targets."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* One\t\t:local:\n\n"
                        "#+begin_src txt :tangle a.txt\nAAA\n#+end_src\n\n"
                        "* Two\t\t:local:\n\n"
                        "#+begin_src txt :tangle b.txt\nBBB\n#+end_src\n")
                target)
      (let ((results (devops-tangle-all (current-buffer))))
        (should (equal results (list (list "local" target 1)
                                     (list "local" target 1))))
        (should (file-exists-p (concat target "a.txt")))
        (should (file-exists-p (concat target "b.txt")))))))

(ert-deftest devops-tangle-message-test ()
  "Interactive `devops-tangle' writes the file and reports it."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+begin_src txt :tangle out.txt\nhi\n#+end_src\n")
                target)
      (org-back-to-heading)
      (should (equal (devops-tangle)
                     (format "Tangled 1 file(s) to local (%s)" target)))
      (should (file-exists-p (concat target "out.txt"))))))

(ert-deftest devops-tangle-target-no-slash-test ()
  "A #+TARGET without a trailing slash still writes into that directory."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+begin_src txt :tangle out.txt\nhi\n#+end_src\n")
                ;; strip the trailing slash the helper added
                (directory-file-name target))
      (let ((results (devops-tangle-headline (current-buffer) "Deploy")))
        (should (equal results
                       (list (list "local" (directory-file-name target) 1))))
        (should (file-exists-p (concat target "out.txt")))))))

(ert-deftest devops-tangle-relative-target-test ()
  "A relative #+TARGET resolves against the source buffer's directory.
The actual tangling happens in a temp buffer; this guards that relative
targets land next to the org file rather than in the system temp dir."
  (devops-test--with-local-target target
    (devops-test--with-org
        (concat "#+TARGET: . (local)\n\n"
                "* Deploy\t\t:local:\n\n"
                "#+begin_src txt :tangle out.txt\nhi\n#+end_src\n")
      (setq default-directory target)
      (let ((results (devops-tangle-headline (current-buffer) "Deploy")))
        (should (equal results (list (list "local" "." 1))))
        (should (file-exists-p (concat target "out.txt")))))))

(ert-deftest devops-tangle-no-target-tag-test ()
  "Error when the current heading has no matching target tag."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n\n"
              "* Heading\t\t:unknown:\n\n"
              "#+begin_src sh :tangle foo.txt\n"
              "echo hi\n#+end_src\n")
    (org-back-to-heading)
    (should-error (devops-tangle) :type 'user-error)))

;;; Tangle paths

(ert-deftest devops--tangle-paths-test ()
  "Expand the current block's :tangle path against each target."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n\n"
              "* Deploy\t\t:t1:\n\n"
              "#+begin_src sh :tangle foo.txt\n"
              "echo hi\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "begin_src")
    (should (equal (devops--tangle-paths) '("/srv/one/foo.txt")))))

(ert-deftest devops--tangle-paths-no-slash-target-test ()
  "Visit-path expansion inserts a separator for a slash-less target."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one (t1)\n\n"
              "* Deploy\t\t:t1:\n\n"
              "#+begin_src sh :tangle foo.txt\n"
              "echo hi\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "begin_src")
    (should (equal (devops--tangle-paths) '("/srv/one/foo.txt")))))

(provide 'devops-test)
