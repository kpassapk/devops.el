;; devops-test.el --- Tests for devops.el  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'ob-shell)
(require 'tramp)
(require 'devops)
(require 'devops-lob)
(require 'devops-drift)

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

(ert-deftest devops-tangle-custom-id-test ()
  "Tangle a heading selected by its CUSTOM_ID to a local target."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n"
                        ":PROPERTIES:\n:CUSTOM_ID: deploy-id\n:END:\n\n"
                        "#+begin_src json :tangle config.json\n"
                        "{\"name\": \"test\"}\n#+end_src\n")
                target)
      (let ((results (devops-tangle-custom-id (current-buffer) "deploy-id")))
        (should (equal results (list (list "local" target 1))))
        (should (file-exists-p (concat target "config.json")))))))

(ert-deftest devops-tangle-custom-id-trims-selector-test ()
  "A CUSTOM_ID selector with surrounding whitespace still matches.
Selectors passed straight from a `:results output' block carry a trailing
newline; the selector must be trimmed before matching."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n"
                        ":PROPERTIES:\n:CUSTOM_ID: deploy-id\n:END:\n\n"
                        "#+begin_src json :tangle config.json\n"
                        "{\"name\": \"test\"}\n#+end_src\n")
                target)
      (let ((results (devops-tangle-custom-id (current-buffer) "deploy-id\n")))
        (should (equal results (list (list "local" target 1))))
        (should (file-exists-p (concat target "config.json")))))))

(ert-deftest devops-tangle-headline-trims-selector-test ()
  "A headline selector with surrounding whitespace still matches."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+begin_src json :tangle config.json\n"
                        "{\"name\": \"test\"}\n#+end_src\n")
                target)
      (let ((results (devops-tangle-headline (current-buffer) "  Deploy\n")))
        (should (equal results (list (list "local" target 1))))
        (should (file-exists-p (concat target "config.json")))))))

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

;;; Multi-tag target selection

(ert-deftest devops--heading-target-dir-multi-test ()
  "With several matching tags, the completing-read choice wins."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n"
              "#+TARGET: /srv/two/ (t2)\n\n"
              "* Deploy\t\t:t1:t2:\n")
    (org-back-to-heading)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _) (cadr collection))))
      (should (equal (devops--heading-target-dir) "/srv/two/")))))

;;; Src block execution (README: blocks run at the heading's target)

(ert-deftest devops-execute-src-block-injects-dir-test ()
  "Executing a block under a target-tagged heading runs in the target dir."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Run\t\t:local:\n\n"
                        "#+begin_src sh\npwd\n#+end_src\n")
                target)
      (goto-char (point-min))
      (re-search-forward "begin_src")
      (let* ((org-confirm-babel-evaluate nil)
             (result (org-babel-execute-src-block)))
        (should (equal (file-name-as-directory (file-truename (org-trim result)))
                       (file-name-as-directory (file-truename target))))))))

(ert-deftest devops-execute-src-block-explicit-dir-wins-test ()
  "An explicit :dir on the block overrides the heading's target."
  (devops-test--with-local-target target
    (devops-test--with-local-target other
      (devops-test--with-org
          (format (concat "#+TARGET: %s (local)\n\n"
                          "* Run\t\t:local:\n\n"
                          "#+begin_src sh :dir %s\npwd\n#+end_src\n")
                  target other)
        (goto-char (point-min))
        (re-search-forward "begin_src")
        (let* ((org-confirm-babel-evaluate nil)
               (result (org-babel-execute-src-block)))
          (should (equal (file-name-as-directory (file-truename (org-trim result)))
                         (file-name-as-directory (file-truename other)))))))))

(ert-deftest devops-execute-src-block-explicit-dir-skips-prompt-test ()
  "With an explicit :dir, multiple target tags do not prompt for a target."
  (devops-test--with-local-target other
    (devops-test--with-org
        (format (concat "#+TARGET: /srv/one/ (t1)\n"
                        "#+TARGET: /srv/two/ (t2)\n\n"
                        "* Run\t\t:t1:t2:\n\n"
                        "#+begin_src sh :dir %s\npwd\n#+end_src\n")
                other)
      (goto-char (point-min))
      (re-search-forward "begin_src")
      (let ((org-confirm-babel-evaluate nil))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (error "Should not prompt for a target"))))
          (should (equal (file-name-as-directory
                          (file-truename (org-trim (org-babel-execute-src-block))))
                         (file-name-as-directory (file-truename other)))))))))

;;; Multi-target tangling (README: same file to several servers)

(ert-deftest devops-tangle-multi-target-test ()
  "One heading tagged for two targets tangles the file to both."
  (devops-test--with-local-target t1
    (devops-test--with-local-target t2
      (devops-test--with-org
          (format (concat "#+TARGET: %s (s1)\n"
                          "#+TARGET: %s (s2)\n\n"
                          "* Deploy\t\t:s1:s2:\n\n"
                          "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n")
                  t1 t2)
        (let ((results (devops-tangle-headline (current-buffer) "Deploy")))
          (should (equal results (list (list "s1" t1 1)
                                       (list "s2" t2 1))))
          (should (file-exists-p (concat t1 "foo.txt")))
          (should (file-exists-p (concat t2 "foo.txt"))))))))

;;; Noweb (README: secrets via <<NAME()>>, per-server blocks)

(ert-deftest devops-tangle-noweb-executes-block-test ()
  "Noweb <<NAME()>> executes the named block during tangling."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+name: SECRET\n"
                        "#+begin_src emacs-lisp\n\"s3cret\"\n#+end_src\n\n"
                        "#+begin_src yaml :tangle config.yaml :noweb yes\n"
                        "api-key: <<SECRET()>>\n#+end_src\n")
                target)
      (let ((org-confirm-babel-evaluate nil))
        (devops-tangle-headline (current-buffer) "Deploy"))
      (with-temp-buffer
        (insert-file-contents (concat target "config.yaml"))
        (should (search-forward "api-key: s3cret" nil t))))))

(ert-deftest devops-tangle-per-server-noweb-test ()
  "Server-tagged #+name blocks resolve per target during multi-target tangle."
  (devops-test--with-local-target t1
    (devops-test--with-local-target t2
      (devops-test--with-org
          (format (concat "#+TARGET: %s (server1)\n"
                          "#+TARGET: %s (server2)\n\n"
                          "* Deploy\t\t:server1:server2:\n\n"
                          "#+name: tier (server1)\n"
                          "#+begin_src text\none\n#+end_src\n\n"
                          "#+name: tier (server2)\n"
                          "#+begin_src text\ntwo\n#+end_src\n\n"
                          "#+begin_src conf :tangle app.conf :noweb yes\n"
                          "tier=<<tier>>\n#+end_src\n")
                  t1 t2)
        (devops-tangle-headline (current-buffer) "Deploy")
        (with-temp-buffer
          (insert-file-contents (concat t1 "app.conf"))
          (should (search-forward "tier=one" nil t)))
        (with-temp-buffer
          (insert-file-contents (concat t2 "app.conf"))
          (should (search-forward "tier=two" nil t)))))))

;;; Src block introspection

(ert-deftest devops-src-block-env-vars-test ()
  "Collect :var params as (NAME . VALUE) pairs."
  (devops-test--with-org
      (concat "* H\n\n"
              "#+begin_src sh :var name=\"val\" :var n=3\n"
              "echo $name\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "begin_src")
    (let ((vars (devops-src-block-env-vars)))
      (should (= 2 (length vars)))
      (should (equal (assoc "name" vars) '("name" . "val")))
      (should (equal (assoc "n" vars) '("n" . 3))))))

(ert-deftest devops--src-block-body-test ()
  "Return the trimmed body of the block at point."
  (devops-test--with-org
      "* H\n\n#+begin_src sh\n  echo hi\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src")
    (should (equal (devops--src-block-body) "echo hi"))))

(ert-deftest devops--src-block-tangle-header-test ()
  "Return the :tangle header of the block at point."
  (devops-test--with-org
      "* H\n\n#+begin_src sh :tangle foo.txt\necho hi\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src")
    (should (equal (devops--src-block-tangle-header) "foo.txt"))))

;;; Terminal command construction (README: devops-open-terminal-dwim)

(ert-deftest devops--ghostty-command-local-test ()
  "Local dir opens ghostty with a working directory."
  (should (equal (devops--ghostty-command "/tmp/work/")
                 '("ghostty" "--working-directory=/tmp/work/"))))

(ert-deftest devops--ghostty-command-local-env-test ()
  "Local dir with env vars exports them before the shell."
  (should (equal (devops--ghostty-command "/tmp/work/" '(("FOO" . "bar")))
                 '("ghostty" "--working-directory=/tmp/work/"
                   "-e" "bash" "-c" "export FOO=bar && exec $SHELL"))))

(ert-deftest devops--ghostty-command-remote-test ()
  "Remote TRAMP dir becomes an ssh -t invocation with cd."
  (should (equal (devops--ghostty-command "/ssh:deploy@example.com:/srv/app")
                 '("ghostty" "-e" "ssh" "-t" "deploy@example.com"
                   "cd /srv/app && $SHELL"))))

(ert-deftest devops--ghostty-command-remote-env-test ()
  "Remote dir with env vars exports them in the remote command."
  (should (equal (devops--ghostty-command "/ssh:deploy@example.com:/srv/app"
                                          '(("FOO" . "bar")))
                 '("ghostty" "-e" "ssh" "-t" "deploy@example.com"
                   "cd /srv/app && export FOO=bar && $SHELL"))))

(ert-deftest devops--ghostty-command-remote-no-user-test ()
  "Remote dir without a user part targets the bare host."
  (should (equal (devops--ghostty-command "/ssh:example.com:/srv/app")
                 '("ghostty" "-e" "ssh" "-t" "example.com"
                   "cd /srv/app && $SHELL"))))

;;; Drift detection (devops-drift.el)

(defmacro devops-test--with-drift-check (target org-fmt &rest body)
  "Run a whole-buffer drift check against a fresh local TARGET.
ORG-FMT is a format string receiving TARGET.  BODY runs with `entries'
bound to the drift entries and `root' to the temp tangle root (removed
afterwards), in an org buffer visiting the formatted text."
  (declare (indent 2))
  `(devops-test--with-local-target ,target
     (devops-test--with-org (format ,org-fmt ,target)
       (let* ((result (devops--drift-check (current-buffer) t))
              (root (car result))
              (entries (cdr result)))
         (unwind-protect
             (progn ,@body)
           (delete-directory root t))))))

(ert-deftest devops--drift-localize-path-test ()
  "Map :tangle paths to collision-free relative temp paths."
  (should (equal (devops--drift-localize-path "~/foo.txt") "home/foo.txt"))
  (should (equal (devops--drift-localize-path "~admin/foo.txt")
                 "home/admin/foo.txt"))
  (should (equal (devops--drift-localize-path "/etc/app.conf") "etc/app.conf"))
  (should (equal (devops--drift-localize-path "conf/app.conf") "conf/app.conf"))
  ;; TRAMP paths reduce to their remote-local part first.
  (should (equal (devops--drift-localize-path "/ssh:host:~/x.txt")
                 "home/x.txt"))
  (should (equal (devops--drift-localize-path "/ssh:host:/etc/x.conf")
                 "etc/x.conf")))

(ert-deftest devops--drift-rewrite-tangle-paths-test ()
  "Rewrite :tangle to temp paths and record (PATH LOCAL REMOTE)."
  (devops-test--with-org
      (concat "* Heading\n\n"
              "#+begin_src sh :tangle ~/foo.txt\n"
              "echo hi\n#+end_src\n\n"
              "#+begin_src sh :tangle no\n"
              "echo skip\n#+end_src\n\n"
              "#+begin_src sh :tangle /ssh:other:/etc/x.conf\n"
              "key=val\n#+end_src\n")
    (let ((mapping (devops--drift-rewrite-tangle-paths "/ssh:host1:" "/tmp/root")))
      (should (= 2 (length mapping)))
      ;; Buffer order; :tangle no untouched.
      (should (equal (car mapping)
                     '("~/foo.txt" "/tmp/root/home/foo.txt"
                       "/ssh:host1:~/foo.txt")))
      ;; An already-TRAMP path keeps itself as remote but tangles locally.
      (should (equal (cadr mapping)
                     '("/ssh:other:/etc/x.conf" "/tmp/root/etc/x.conf"
                       "/ssh:other:/etc/x.conf")))
      (goto-char (point-min))
      (should (search-forward ":tangle /tmp/root/home/foo.txt" nil t))
      (goto-char (point-min))
      (should (search-forward ":tangle no" nil t))
      (goto-char (point-min))
      (should-not (search-forward ":tangle /ssh:other:" nil t)))))

(ert-deftest devops-drift-check-in-sync-test ()
  "A target that matches its tangled output reports `same'."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n")
                target)
      (devops-tangle-headline (current-buffer) "Deploy")
      (let* ((result (devops--drift-check (current-buffer) t))
             (entries (cdr result)))
        (unwind-protect
            (progn
              (should (= 1 (length entries)))
              (let ((entry (car entries)))
                (should (eq (plist-get entry :status) :same))
                (should (equal (plist-get entry :remote)
                               (concat target "foo.txt")))
                (should (equal (plist-get entry :path) "foo.txt"))))
          (delete-directory (car result) t))))))

(ert-deftest devops-drift-check-drift-test ()
  "A target file that was changed out-of-band reports `drift'."
  (devops-test--with-drift-check target
      (concat "#+TARGET: %s (local)\n\n"
              "* Deploy\t\t:local:\n\n"
              "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n")
    (ignore entries root)
    (with-temp-file (concat target "foo.txt") (insert "changed on server\n"))
    ;; Re-run: previous check tangled but target now differs.
    (let ((again (devops--drift-check (current-buffer) t)))
      (unwind-protect
          (should (eq (plist-get (car (cdr again)) :status) :drift))
        (delete-directory (car again) t)))))

(ert-deftest devops-drift-check-missing-test ()
  "A target file that does not exist reports `missing'."
  (devops-test--with-drift-check target
      (concat "#+TARGET: %s (local)\n\n"
              "* Deploy\t\t:local:\n\n"
              "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n")
    (ignore root)
    (should (= 1 (length entries)))
    (should (eq (plist-get (car entries) :status) :missing))))

(ert-deftest devops-drift-check-per-server-noweb-test ()
  "Per-server noweb content lands in per-tag temp dirs; both stay in sync."
  (devops-test--with-local-target t1
    (devops-test--with-local-target t2
      (devops-test--with-org
          (format (concat "#+TARGET: %s (server1)\n"
                          "#+TARGET: %s (server2)\n\n"
                          "* Deploy\t\t:server1:server2:\n\n"
                          "#+name: tier (server1)\n"
                          "#+begin_src text\none\n#+end_src\n\n"
                          "#+name: tier (server2)\n"
                          "#+begin_src text\ntwo\n#+end_src\n\n"
                          "#+begin_src conf :tangle app.conf :noweb yes\n"
                          "tier=<<tier>>\n#+end_src\n")
                  t1 t2)
        (devops-tangle-headline (current-buffer) "Deploy")
        (let* ((result (devops--drift-check (current-buffer) t))
               (entries (cdr result)))
          (unwind-protect
              (progn
                (should (= 2 (length entries)))
                (dolist (entry entries)
                  (should (eq (plist-get entry :status) :same)))
                ;; Same :tangle path, distinct per-tag local files.
                (should-not (equal (plist-get (nth 0 entries) :local)
                                   (plist-get (nth 1 entries) :local))))
            (delete-directory (car result) t)))))))

(ert-deftest devops-drift-check-current-heading-test ()
  "Without ALL, only the heading at point is checked."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* One\t\t:local:\n\n"
                        "#+begin_src txt :tangle a.txt\nAAA\n#+end_src\n\n"
                        "* Two\t\t:local:\n\n"
                        "#+begin_src txt :tangle b.txt\nBBB\n#+end_src\n")
                target)
      (goto-char (point-min))
      (re-search-forward "^\\* One")
      (let ((result (devops--drift-check (current-buffer))))
        (unwind-protect
            (progn
              (should (= 1 (length (cdr result))))
              (should (equal (plist-get (car (cdr result)) :path) "a.txt")))
          (delete-directory (car result) t))))))

;;; Drift detection, noninteractive (devops-drift.el)

(defvar devops-test--drift-org
  (concat "#+TARGET: %s (local)\n\n"
          "* One\t\t:local:\n"
          ":PROPERTIES:\n:CUSTOM_ID: one\n:END:\n\n"
          "#+begin_src txt :tangle a.txt\nAAA\n#+end_src\n\n"
          "* Two\t\t:local:\n\n"
          "#+begin_src txt :tangle b.txt\nBBB\n#+end_src\n")
  "Two target-tagged headings, one file each.  Takes a target directory.")

(ert-deftest devops-drift-all-data-test ()
  "Entries are alists keyed by keywords, one per tangled file."
  (devops-test--with-local-target target
    (devops-test--with-org (format devops-test--drift-org target)
      (devops-tangle-all (current-buffer))
      (let ((entries (devops-drift-all (current-buffer))))
        (should (= 2 (length entries)))
        ;; An alist, not a plist: this is what cljbang reads as a map.
        (should (consp (car (car entries))))
        (let ((entry (car entries)))
          (should (eq (alist-get :status entry) :same))
          (should (equal (alist-get :tag entry) "local"))
          (should (equal (alist-get :path entry) "a.txt"))
          (should (equal (alist-get :remote entry) (concat target "a.txt")))
          (should (equal (alist-get :target entry) target))
          (should-not (alist-get :diff entry)))))))

(ert-deftest devops-drift-all-leaves-no-temp-tree-test ()
  "The noninteractive check owns its temp tangle tree and removes it."
  (devops-test--with-local-target target
    (devops-test--with-org (format devops-test--drift-org target)
      (let ((before (directory-files temporary-file-directory nil "\\`devops-drift-")))
        (devops-drift-all (current-buffer))
        (should (equal before
                       (directory-files temporary-file-directory
                                        nil "\\`devops-drift-")))))))

(ert-deftest devops-drift-headline-test ()
  "A headline selector checks that subtree only."
  (devops-test--with-local-target target
    (devops-test--with-org (format devops-test--drift-org target)
      (let ((entries (devops-drift-headline (current-buffer) "Two\n")))
        (should (= 1 (length entries)))
        (should (equal (alist-get :path (car entries)) "b.txt"))
        (should (eq (alist-get :status (car entries)) :missing))))))

(ert-deftest devops-drift-custom-id-test ()
  "A CUSTOM_ID selector checks that subtree only."
  (devops-test--with-local-target target
    (devops-test--with-org (format devops-test--drift-org target)
      (let ((entries (devops-drift-custom-id (current-buffer) " one ")))
        (should (= 1 (length entries)))
        (should (equal (alist-get :path (car entries)) "a.txt"))))))

(ert-deftest devops-drift-selector-not-found-test ()
  "An unknown selector is an error, not an empty result."
  (devops-test--with-local-target target
    (devops-test--with-org (format devops-test--drift-org target)
      (should-error (devops-drift-headline (current-buffer) "Three"))
      (should-error (devops-drift-custom-id (current-buffer) "three")))))

(ert-deftest devops-drift-file-source-test ()
  "SOURCE may be a file name; a non-org file is refused."
  (devops-test--with-local-target target
    (let ((org (make-temp-file "devops-drift-src-" nil ".org"))
          (txt (make-temp-file "devops-drift-src-" nil ".txt")))
      (unwind-protect
          (progn
            (with-temp-file org (insert (format devops-test--drift-org target)))
            (let ((entries (devops-drift-all org)))
              (should (= 2 (length entries)))
              (should (eq (alist-get :status (car entries)) :missing)))
            (should-error (devops-drift-all txt)))
        (dolist (file (list org txt))
          (let ((buf (get-file-buffer file)))
            (when buf (kill-buffer buf)))
          (delete-file file))))))

(ert-deftest devops-drift-diff-test ()
  "A drifting file carries a unified diff labelled by remote and :tangle path."
  (devops-test--with-local-target target
    (devops-test--with-org (format devops-test--drift-org target)
      (devops-tangle-all (current-buffer))
      (with-temp-file (concat target "a.txt") (insert "changed on server\n"))
      (let* ((entries (devops-drift-all (current-buffer)))
             (entry (car entries))
             (diff (alist-get :diff entry)))
        (should (eq (alist-get :status entry) :drift))
        (should (string-match-p (concat "^--- " (regexp-quote (concat target "a.txt")))
                                diff))
        (should (string-match-p "^\\+\\+\\+ a\\.txt (local)" diff))
        (should (string-match-p "^-changed on server$" diff))
        (should (string-match-p "^\\+AAA$" diff))))))

(ert-deftest devops-drift-ok-p-test ()
  "Everything in sync is ok; a single drift, or no entries at all, is not."
  (should (devops-drift-ok-p '(((:status . :same)) ((:status . :same)))))
  (should-not (devops-drift-ok-p '(((:status . :same)) ((:status . :drift)))))
  (should-not (devops-drift-ok-p nil)))

(ert-deftest devops-drift-summary-test ()
  "The summary lists a line per entry, then the diffs."
  (let ((text (devops-drift-summary
               '(((:status . :same) (:tag . "s1") (:path . "a.txt")
                  (:remote . "/ssh:h:a.txt") (:detail) (:diff))
                 ((:status . :drift) (:tag . "s1") (:path . "b.txt")
                  (:remote . "/ssh:h:b.txt") (:detail) (:diff . "@@ diff @@"))
                 ((:status . :error) (:tag . "s2") (:path . "c.txt")
                  (:remote . "/ssh:h2:c.txt") (:detail . "no route")
                  (:diff))))))
    (should (string-match-p "^ok +s1 +/ssh:h:a\\.txt$" text))
    (should (string-match-p "^DRIFT +s1 +/ssh:h:b\\.txt$" text))
    (should (string-match-p "^ERROR +s2 +/ssh:h2:c\\.txt (no route)$" text))
    (should (string-suffix-p "\n\n@@ diff @@" text))))

(ert-deftest devops-drift-table-test ()
  "The table has a header, an hline, and a row per entry."
  (let ((table (devops-drift-table
                '(((:status . :missing) (:tag . "s1") (:path . "a.txt")
                   (:remote . "/ssh:h:a.txt") (:detail) (:diff))))))
    (should (equal (nth 0 table) '("Status" "Tag" "Path" "Remote")))
    (should (eq (nth 1 table) 'hline))
    (should (equal (nth 2 table)
                   '("MISSING" "s1" "a.txt" "/ssh:h:a.txt")))))

(ert-deftest devops-drift-report-test ()
  "The report buffer renders statuses; RET jumps to the source block."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n")
                target)
      (let ((source (current-buffer)))
        (org-back-to-heading)
        (devops-drift)
        (let ((report (get-buffer "*Drift Report*")))
          (unwind-protect
              (with-current-buffer report
                (should (derived-mode-p 'devops-drift-report-mode))
                (goto-char (point-min))
                (should (search-forward "MISSING" nil t))
                (should (search-forward (concat target "foo.txt") nil t))
                ;; Temp tangle output exists while the report lives.
                (should (file-exists-p
                         (expand-file-name "local/foo.txt" devops-drift--root)))
                (goto-char (point-min))
                (devops-drift-report-visit)
                (should (eq (current-buffer) source))
                (should (looking-at "#\\+begin_src txt :tangle foo.txt")))
            (when (buffer-live-p report) (kill-buffer report))))))))

(ert-deftest devops-drift-report-cleanup-test ()
  "Killing the report buffer removes its temp tangle directory."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n")
                target)
      (org-back-to-heading)
      (devops-drift)
      (let* ((report (get-buffer "*Drift Report*"))
             (root (buffer-local-value 'devops-drift--root report)))
        (should (file-directory-p root))
        (kill-buffer report)
        (should-not (file-directory-p root))))))

;;; devops-lob (README: per-project tools.org)

(defvar devops-test--tools-org
  (concat "#+title: Tools\n\n"
          "#+name: deploy\n"
          "#+begin_src sh :var env=\"staging\"\n"
          "./deploy.sh $env\n#+end_src\n\n"
          "#+name: health-check\n"
          "#+begin_src sh :var host=\"localhost\"\n"
          "curl -sf http://$host/health\n#+end_src\n")
  "The README's tools.org example.")

(defmacro devops-test--with-project (root-var tools-content &rest body)
  "Run BODY with ROOT-VAR bound to a fresh project root (contains .git).
When TOOLS-CONTENT is non-nil, write it to tools.org at the root.
`default-directory' is the root; LOB globals and the devops registry are
isolated so tests never touch real state.  Everything is removed after."
  (declare (indent 2))
  `(let ((,root-var (file-name-as-directory (make-temp-file "devops-proj-" t)))
         (org-babel-library-of-babel nil)
         (devops--lob-project-registry nil)
         (project-list-file (make-temp-file "devops-projects-")))
     (unwind-protect
         (progn
           (make-directory (expand-file-name ".git" ,root-var))
           (when ,tools-content
             (with-temp-file (expand-file-name "tools.org" ,root-var)
               (insert ,tools-content)))
           (let ((default-directory ,root-var))
             ,@body))
       (delete-file project-list-file)
       (delete-directory ,root-var t))))

(ert-deftest devops--lob-names-in-file-test ()
  "Collect named src block symbols from a file."
  (devops-test--with-project root devops-test--tools-org
    (should (equal (devops--lob-names-in-file
                    (expand-file-name "tools.org" root))
                   '(deploy health-check)))))

(ert-deftest devops-lob-load-project-tools-test ()
  "Load tools.org into the LOB; loading twice doesn't duplicate."
  (devops-test--with-project root devops-test--tools-org
    (devops-lob-load-project-tools)
    (should (assq 'deploy org-babel-library-of-babel))
    (should (assq 'health-check org-babel-library-of-babel))
    (should (= 1 (length devops--lob-project-registry)))
    (devops-lob-load-project-tools)
    (should (= 1 (length devops--lob-project-registry)))))

(ert-deftest devops-lob-load-no-tools-file-test ()
  "A project without tools.org loads nothing."
  (devops-test--with-project root nil
    (devops-lob-load-project-tools)
    (should (null org-babel-library-of-babel))
    (should (null devops--lob-project-registry))))

(ert-deftest devops-lob-unload-project-tools-test ()
  "Unloading removes the project's LOB entries and registry row."
  (devops-test--with-project root devops-test--tools-org
    (devops-lob-load-project-tools)
    (devops-lob-unload-project-tools)
    (should (null org-babel-library-of-babel))
    (should (null devops--lob-project-registry))))

(ert-deftest devops-lob-reload-project-tools-test ()
  "Reload picks up edits to tools.org and drops removed entries."
  (devops-test--with-project root devops-test--tools-org
    (devops-lob-load-project-tools)
    (with-temp-file (expand-file-name "tools.org" root)
      (insert "#+name: rollback\n#+begin_src sh\n./rollback.sh\n#+end_src\n"))
    (devops-lob-reload-project-tools)
    (should (assq 'rollback org-babel-library-of-babel))
    (should-not (assq 'deploy org-babel-library-of-babel))))

(ert-deftest devops-lob-unload-all-test ()
  "Unload-all clears every tracked entry."
  (devops-test--with-project root devops-test--tools-org
    (devops-lob-load-project-tools)
    (devops-lob-unload-all)
    (should (null org-babel-library-of-babel))
    (should (null devops--lob-project-registry))))

(ert-deftest devops-org-tool-blocks-test ()
  "Summarize and filter loaded LOB entries (README inspect example)."
  (devops-test--with-project root devops-test--tools-org
    (devops-lob-load-project-tools)
    (should (= 2 (length (devops-org-tool-blocks))))
    (let ((filtered (devops-org-tool-blocks "deploy")))
      (should (= 1 (length filtered)))
      (let ((entry (car filtered)))
        (should (eq (nth 0 entry) 'deploy))
        (should (equal (nth 1 entry) "sh"))
        (should (eq (caar (nth 2 entry)) :var))))))

(ert-deftest devops-lob-auto-mode-hook-test ()
  "Enabling the mode installs the find-file hook; disabling removes it."
  (unwind-protect
      (progn
        (devops-lob-auto-mode 1)
        (should (memq #'devops--lob-maybe-load-on-find-file find-file-hook))
        (devops-lob-auto-mode -1)
        (should-not (memq #'devops--lob-maybe-load-on-find-file find-file-hook)))
    (devops-lob-auto-mode -1)))

(ert-deftest devops-lob-auto-load-on-find-file-test ()
  "With auto mode on, opening a file in a project loads its tools.org."
  (devops-test--with-project root devops-test--tools-org
    (let ((file (expand-file-name "notes.txt" root))
          buf)
      (with-temp-file file (insert "hi\n"))
      (unwind-protect
          (progn
            (devops-lob-auto-mode 1)
            (setq buf (find-file-noselect file))
            (should (assq 'deploy org-babel-library-of-babel))
            (should (= 1 (length devops--lob-project-registry))))
        (devops-lob-auto-mode -1)
        (when buf (kill-buffer buf))))))

(provide 'devops-test)
