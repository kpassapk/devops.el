;; devops-test.el --- Tests for devops.el  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'ob-shell)
(require 'tramp)
(require 'devops)
(require 'devops-lob)
(require 'devops-drift)

(devops-mode 1)

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

;;; Mode and advice

(ert-deftest devops-mode-advice-test ()
  "The mode adds the execution advice on, and removes it off."
  (unwind-protect
      (progn
        (devops-mode -1)
        (should-not (advice-member-p #'devops--inject-header-args-from-tags
                                     'org-babel-execute-src-block))
        (should-not (advice-member-p #'devops--resolve-ref-sync
                                     'org-babel-ref-resolve))
        (devops-mode 1)
        (should (advice-member-p #'devops--inject-header-args-from-tags
                                 'org-babel-execute-src-block))
        (should (advice-member-p #'devops--resolve-ref-sync
                                 'org-babel-ref-resolve)))
    (devops-mode 1)))

(ert-deftest devops-mode-off-no-target-test ()
  "With the mode off, a block under a target's tag runs where org says."
  (unwind-protect
      (devops-test--with-local-target target
        (devops-mode -1)
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
                           (file-name-as-directory
                            (file-truename default-directory)))))))
    (devops-mode 1)))

(ert-deftest devops--tangle-subtree-advice-scoped-test ()
  "The tangle plan advice is in place only while devops tangles."
  (let (during)
    (devops-test--with-org
        "* H\n#+begin_src sh :tangle a.sh\necho\n#+end_src\n"
      (devops--tangle-subtree
       (current-buffer) (point-min)
       (lambda (_path _params _file)
         (setq during (advice-member-p #'devops--redirect-tangle-plan
                                       'org-babel-tangle-collect-blocks))
         nil)))
    (should during)
    (should-not (advice-member-p #'devops--redirect-tangle-plan
                                 'org-babel-tangle-collect-blocks))))

(ert-deftest devops-unload-function-test ()
  "Unloading turns the mode off and lets the standard unload proceed."
  (unwind-protect
      (progn
        (should-not (devops-unload-function))
        (should-not devops-mode)
        (should-not (advice-member-p #'devops--inject-header-args-from-tags
                                     'org-babel-execute-src-block)))
    (devops-mode 1)))

;;; Keyword parsing

(ert-deftest devops--parse-target-keyword-test ()
  "Parse #+TARGET value into (TAG . TARGET)."
  (should (equal (devops--parse-target-keyword "/ssh:host1: (server1)")
                 '("server1" . "/ssh:host1:")))
  (should (equal (devops--parse-target-keyword "/srv/app/ (local)")
                 '("local" . "/srv/app/")))
  (should (null (devops--parse-target-keyword "malformed")))
  (should (null (devops--parse-target-keyword "/no/tag/here"))))

(ert-deftest devops--parse-target-keyword-ref-test ()
  "A #+TARGET value may be a noweb-style reference, kept as written."
  (should (equal (devops--parse-target-keyword "<<server-target()>> (server)")
                 '("server" . "<<server-target()>>")))
  (should (equal (devops--parse-target-keyword "<<input-target>> (server)")
                 '("server" . "<<input-target>>")))
  ;; Arguments may contain spaces; the tag is still the last parenthesis.
  (should (equal (devops--parse-target-keyword
                  "<<t(INSTANCE=\"a b\")>> (server)")
                 '("server" . "<<t(INSTANCE=\"a b\")>>"))))

(ert-deftest devops-target-ref-test ()
  "`devops-target-ref' tells a reference from a literal target."
  (should (equal (devops-target-ref "<<server-target()>>") "server-target()"))
  (should (equal (devops-target-ref "<<input-target>>") "input-target"))
  (should (null (devops-target-ref "/ssh:host:")))
  (should (null (devops-target-ref "..")))
  (should (null (devops-target-ref "<<>>"))))

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

(ert-deftest devops--resolve-target-for-tag-literal-ref-test ()
  "A bare <<NAME>> is the text of a fixed-width or example block."
  (devops-test--with-org
      (concat "#+TARGET: <<fw>> (t1)\n"
              "#+TARGET: <<ex>> (t2)\n\n"
              "#+name: fw\n: /srv/one/\n\n"
              "#+name: ex\n#+begin_example\n/srv/two/\n#+end_example\n\n"
              "* Heading\n")
    (should (equal (devops--resolve-target-for-tag "t1") "/srv/one/"))
    (should (equal (devops--resolve-target-for-tag "t2") "/srv/two/"))))

(ert-deftest devops--resolve-target-for-tag-src-ref-test ()
  "<<NAME()>> runs a src block and takes its one-line value."
  (devops-test--with-org
      (concat "#+TARGET: <<t()>> (t1)\n\n"
              "* Locate\n\n"
              "#+name: t\n#+begin_src sh :results output\n"
              "echo /srv/three/\n#+end_src\n\n"
              "#+name: v\n#+begin_src sh\n"
              "echo /srv/four/\n#+end_src\n")
    (let ((org-confirm-babel-evaluate nil))
      (should (equal (devops--resolve-target-for-tag "t1") "/srv/three/"))
      ;; :results value hands back a one-cell table; it is unwrapped.
      (should (equal (devops--target-from-ref "t1" "v()") "/srv/four/")))))

(ert-deftest devops--resolve-target-for-tag-src-ref-args-test ()
  "A reference may pass arguments, like a #+call: line."
  (devops-test--with-org
      (concat "#+TARGET: <<t(HOST=\"two\")>> (t1)\n\n"
              "* Locate\n\n"
              "#+name: t\n#+begin_src sh :results output :var HOST=\"one\"\n"
              "echo /ssh:$HOST:\n#+end_src\n")
    (let ((org-confirm-babel-evaluate nil))
      (should (equal (devops--resolve-target-for-tag "t1") "/ssh:two:")))))

(ert-deftest devops--resolve-target-for-tag-bare-src-ref-errors-test ()
  "A bare <<NAME>> naming a src block is refused, not run."
  (devops-test--with-org
      (concat "#+TARGET: <<t>> (t1)\n\n"
              "#+name: t\n#+begin_src sh :results output\n"
              "echo /srv/three/\n#+end_src\n")
    (let ((org-confirm-babel-evaluate nil))
      (should-error (devops--resolve-target-for-tag "t1") :type 'user-error))))

(ert-deftest devops--resolve-target-for-tag-multiline-errors-test ()
  "A reference that yields more than one line is not a target."
  (devops-test--with-org
      (concat "#+TARGET: <<t()>> (t1)\n\n"
              "#+name: t\n#+begin_src sh :results output\n"
              "echo /srv/a/; echo /srv/b/\n#+end_src\n")
    (let ((org-confirm-babel-evaluate nil))
      (should-error (devops--resolve-target-for-tag "t1") :type 'user-error))))

(ert-deftest devops--resolve-target-for-tag-missing-ref-errors-test ()
  "A reference to a block that does not exist is an error."
  (devops-test--with-org "#+TARGET: <<nowhere()>> (t1)\n\n* Heading\n"
    (should-error (devops--resolve-target-for-tag "t1"))))

(ert-deftest devops--resolve-target-for-tag-self-ref-errors-test ()
  "A reference block under the tag it defines errors instead of recursing."
  (devops-test--with-org
      (concat "#+TARGET: <<t()>> (t1)\n\n"
              "* Locate\t\t:t1:\n\n"
              "#+name: t\n#+begin_src sh :results output\n"
              "echo /srv/three/\n#+end_src\n")
    (let ((org-confirm-babel-evaluate nil))
      (should-error (devops--resolve-target-for-tag "t1") :type 'user-error))))

(ert-deftest devops--heading-target-tags-resolves-only-its-tags-test ()
  "Only the references of tags on the heading are resolved."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n"
              "#+TARGET: <<nowhere()>> (t2)\n\n"
              "* Heading\t\t:t1:\n")
    (should (equal (devops--heading-target-tags) '(("t1" . "/srv/one/"))))))

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
                 "/ssh:host:/etc/foo.txt"))
  ;; A relative subdirectory keeps its shape, spelled either way.
  (should (equal (devops--join-target "/ssh:host:" "dir/foo.txt")
                 "/ssh:host:dir/foo.txt"))
  (should (equal (devops--join-target "/ssh:host:" "./dir/foo.txt")
                 "/ssh:host:dir/foo.txt"))
  (should (equal (devops--join-target "/srv/app" "./dir/foo.txt")
                 "/srv/app/dir/foo.txt"))
  ;; "." as a target and "./" on the path collapse to one "./".
  (should (equal (devops--join-target "." "./foo.txt") "./foo.txt")))

(ert-deftest devops--split-target-test ()
  "Split a target into its TRAMP prefix and its directory part."
  (should (equal (devops--split-target "/srv/app") '("" . "/srv/app")))
  (should (equal (devops--split-target ".") '("" . ".")))
  (should (equal (devops--split-target "/ssh:host:") '("/ssh:host:" . "")))
  (should (equal (devops--split-target "/ssh:host:/etc") '("/ssh:host:" . "/etc")))
  ;; Multi-hop: the whole hop chain is the prefix (`file-remote-p' would
  ;; report only "/podman:box:").
  (should (equal (devops--split-target "/ssh:host|podman:box:")
                 '("/ssh:host|podman:box:" . ""))))

(ert-deftest devops--join-target-absolute-path-test ()
  "An absolute :tangle path is absolute on the target's machine."
  ;; The TRAMP prefix survives; the target's directory does not.
  (should (equal (devops--join-target "/ssh:host:" "/etc/app.conf")
                 "/ssh:host:/etc/app.conf"))
  (should (equal (devops--join-target "/ssh:host:/opt/app" "/etc/app.conf")
                 "/ssh:host:/etc/app.conf"))
  (should (equal (devops--join-target "/ssh:host|podman:box:/opt" "/etc/app.conf")
                 "/ssh:host|podman:box:/etc/app.conf"))
  ;; A local directory target has no prefix to keep, so the path stands alone.
  (should (equal (devops--join-target "/srv/app/" "/etc/app.conf")
                 "/etc/app.conf"))
  (should (equal (devops--join-target "." "/etc/app.conf") "/etc/app.conf")))

(ert-deftest devops--join-target-home-path-test ()
  "A \"~\" :tangle path is the home directory on the target's machine."
  (should (equal (devops--join-target "/ssh:host:" "~/foo.txt")
                 "/ssh:host:~/foo.txt"))
  ;; Not "/ssh:host:/opt/app/~/foo.txt", which names a directory called "~".
  (should (equal (devops--join-target "/ssh:host:/opt/app" "~/foo.txt")
                 "/ssh:host:~/foo.txt"))
  (should (equal (devops--join-target "/ssh:host:/opt/app" "~admin/foo.txt")
                 "/ssh:host:~admin/foo.txt"))
  (should (equal (devops--join-target "/srv/app/" "~/foo.txt") "~/foo.txt")))

;;; Tangle destinations

(defun devops-test--file-contents (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest devops--tangle-destination-test ()
  "A :tangle path is retargeted onto the target, as it reads there."
  (let ((dest (lambda (target path)
                (devops--tangle-destination target path nil "/org/ignored"))))
    (should (equal (funcall dest "/ssh:host1:" "~/foo.txt")
                   "/ssh:host1:~/foo.txt"))
    (should (equal (funcall dest "/srv/app" "foo.txt") "/srv/app/foo.txt"))
    (should (equal (funcall dest "/ssh:host1:" "./dir/bar.txt")
                   "/ssh:host1:dir/bar.txt"))
    (should (equal (funcall dest "/ssh:host1:/opt/app" "/etc/app.conf")
                   "/ssh:host1:/etc/app.conf"))))

(ert-deftest devops--tangle-destination-keeps-org-file-test ()
  "Org's own destination stands where there is no path to retarget."
  ;; `:tangle yes' names a file after the org file, not a path.
  (should (equal (devops--tangle-destination "/ssh:host1:" "yes" nil "/org/x.sh")
                 "/org/x.sh"))
  ;; Already names its machine: not double-prefixed.
  (should (equal (devops--tangle-destination
                  "/ssh:host1:" "/ssh:other:~/a" nil "/ssh:other:~/a")
                 "/ssh:other:~/a"))
  ;; Opted out with `:target nil': lands where org puts it, locally.
  (should (equal (devops--tangle-destination
                  "/ssh:host1:" "bar.txt" '((:target . "nil")) "/org/bar.txt")
                 "/org/bar.txt")))

(ert-deftest devops--redirect-tangle-plan-test ()
  "Blocks regroup by redirected file, in order; a nil destination drops one."
  (let* ((block (lambda (path body)
                  (cons "sh" (list 1 "x.org" nil "h:1"
                                   (list (cons :tangle path)) body nil))))
         (plan (list (list "/o/a" (funcall block "a" "1"))
                     (list "/o/b" (funcall block "b" "2") (funcall block "b" "3"))
                     (list "/o/c" (funcall block "c" "4"))))
         (devops--tangle-redirect
          (lambda (path _params _file)
            (pcase path ("a" "/t/ab") ("b" "/t/ab") ("c" nil)))))
    (let ((out (devops--redirect-tangle-plan plan)))
      (should (equal (mapcar #'car out) '("/t/ab")))
      (should (equal (mapcar (lambda (b) (nth 6 b)) (cdr (car out)))
                     '("1" "2" "3"))))))

(ert-deftest devops--redirect-tangle-plan-unbound-test ()
  "Without a redirect the plan is org's own, untouched."
  (let ((plan '(("/o/a" ("sh" 1 "x.org" nil "h:1" ((:tangle . "a")) "1" nil)))))
    (should (eq (devops--redirect-tangle-plan plan) plan))))

(ert-deftest devops--relink-test ()
  "A relative file: link is re-expressed from the block's new directory."
  (should (equal (devops--relink "file:../x.org::*Deploy" "/a/b/" "/a/")
                 "file:x.org::*Deploy"))
  (should (equal (devops--relink "file:x.org" "/a/" "/a/b/") "file:../x.org"))
  ;; Absolute and non-file links already work from anywhere.
  (should (equal (devops--relink "file:/abs/x.org::*D" "/a/" "/b/")
                 "file:/abs/x.org::*D"))
  (should (equal (devops--relink "id:123" "/a/" "/b/") "id:123"))
  (should-not (devops--relink nil "/a/" "/b/"))
  ;; On another machine only an absolute name leads back.
  (should (equal (devops--relink "file:x.org" "/a/" "/ssh:host:/srv/")
                 "file:/a/x.org")))

(ert-deftest devops-tangle-leaves-org-buffer-alone-test ()
  "Tangling neither edits nor saves the org buffer it tangles."
  (devops-test--with-local-target target
    (devops-test--with-local-target here
      (let ((org (expand-file-name "notes.org" here))
            (text (format (concat "#+TARGET: %s (local)\n\n"
                                  "* Deploy\t\t:local:\n\n"
                                  "#+begin_src txt :tangle out.txt\nhi\n#+end_src\n")
                          target))
            buf)
        (with-temp-file org (insert text))
        (unwind-protect
            (progn
              (setq buf (find-file-noselect org))
              (with-current-buffer buf
                (goto-char (point-max))
                (insert "# unsaved edit\n"))
              (devops-tangle-all buf)
              (should (file-exists-p (concat target "out.txt")))
              (with-current-buffer buf
                (should (buffer-modified-p))
                (should (equal (buffer-string) (concat text "# unsaved edit\n"))))
              ;; `org-babel-pre-tangle-hook' would have saved it.
              (should (equal (devops-test--file-contents org) text)))
          (when buf
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))))))

(ert-deftest devops-tangle-unsaved-buffer-leaves-no-files-test ()
  "A buffer visiting no file tangles without writing beside itself."
  (devops-test--with-local-target target
    (devops-test--with-local-target here
      (devops-test--with-org
          (format (concat "#+TARGET: %s (local)\n\n"
                          "* Deploy\t\t:local:\n\n"
                          "#+begin_src txt :tangle out.txt\nhi\n#+end_src\n")
                  target)
        (let ((default-directory here))
          (devops-tangle-headline (current-buffer) "Deploy"))
        (should-not (buffer-file-name))
        (should (file-exists-p (concat target "out.txt")))
        (should-not (directory-files here nil "\\`[^.]"))))))

(ert-deftest devops-tangle-inherited-tangle-test ()
  "A :tangle inherited from a `header-args' property is retargeted too."
  (devops-test--with-local-target target
    (devops-test--with-local-target here
      (devops-test--with-org
          (format (concat "#+TARGET: %s (local)\n\n"
                          "* Deploy\t\t:local:\n"
                          ":PROPERTIES:\n"
                          ":header-args: :tangle inherited.txt\n"
                          ":END:\n\n"
                          "#+begin_src txt\nhi\n#+end_src\n")
                  target)
        (let ((default-directory here))
          (devops-tangle-headline (current-buffer) "Deploy"))
        (should (file-exists-p (concat target "inherited.txt")))
        (should-not (file-exists-p (expand-file-name "inherited.txt" here)))))))

(ert-deftest devops-tangle-comments-link-test ()
  "A `:comments link' leads from the tangled file back to the org file."
  (devops-test--with-local-target target
    (devops-test--with-local-target here
      (let ((org (expand-file-name "notes.org" here))
            buf)
        (with-temp-file org
          (insert (format (concat "#+TARGET: %s (local)\n\n"
                                  "* Deploy\t\t:local:\n\n"
                                  "#+begin_src sh :tangle out.sh :comments link\n"
                                  "echo hi\n#+end_src\n")
                          target)))
        (unwind-protect
            (let ((org-babel-tangle-use-relative-file-links t))
              (setq buf (find-file-noselect org))
              (devops-tangle-all buf)
              (let ((out (devops-test--file-contents (concat target "out.sh"))))
                (should (string-match "\\[\\[file:\\([^]:]+\\)::\\*Deploy" out))
                (should (equal (expand-file-name (match-string 1 out) target)
                               org))))
          (when buf (kill-buffer buf)))))))

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

(ert-deftest devops-tangle-all-inherited-tag-once-test ()
  "A child that inherits its parent's tag is tangled once, with the parent."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (srv)\n\n"
                        "* Parent\t\t:srv:\n"
                        "#+begin_src txt :tangle a.txt\na\n#+end_src\n"
                        "** Child\n"
                        "#+begin_src txt :tangle b.txt\nb\n#+end_src\n")
                target)
      (should (equal (devops-tangle-all (current-buffer))
                     (list (list "srv" target 2)))))))

(ert-deftest devops-tangle-all-repeated-tag-once-test ()
  "A child that repeats its parent's tag is still tangled only once."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (srv)\n\n"
                        "* Parent\t\t:srv:\n"
                        "#+begin_src txt :tangle a.txt\na\n#+end_src\n"
                        "** Child\t\t:srv:\n"
                        "#+begin_src txt :tangle b.txt\nb\n#+end_src\n")
                target)
      (should (equal (devops-tangle-all (current-buffer))
                     (list (list "srv" target 2)))))))

(ert-deftest devops-tangle-all-child-own-tag-test ()
  "A child's own extra tag tangles just the child to that target."
  (devops-test--with-local-target t1
    (devops-test--with-local-target t2
      (devops-test--with-org
          (format (concat "#+TARGET: %s (one)\n"
                          "#+TARGET: %s (two)\n\n"
                          "* Parent\t\t:one:\n"
                          "#+begin_src txt :tangle a.txt\na\n#+end_src\n"
                          "** Child\t\t:two:\n"
                          "#+begin_src txt :tangle b.txt\nb\n#+end_src\n")
                  t1 t2)
        (should (equal (devops-tangle-all (current-buffer))
                       (list (list "one" t1 2) (list "two" t2 1))))
        (should-not (file-exists-p (concat t2 "a.txt")))))))

(ert-deftest devops-tangle-all-filetags-test ()
  "A #+FILETAGS target tangles each top-level heading, once."
  (devops-test--with-local-target target
    (with-temp-buffer
      (insert (format (concat "#+FILETAGS: :srv:\n"
                              "#+TARGET: %s (srv)\n\n"
                              "* One\n"
                              "#+begin_src txt :tangle a.txt\na\n#+end_src\n"
                              "** Sub\n"
                              "#+begin_src txt :tangle c.txt\nc\n#+end_src\n"
                              "* Two\n"
                              "#+begin_src txt :tangle b.txt\nb\n#+end_src\n")
                      target))
      ;; After the text, so org reads #+FILETAGS.
      (org-mode)
      (should (equal (devops-tangle-all (current-buffer))
                     (list (list "srv" target 2) (list "srv" target 1)))))))

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

(ert-deftest devops-execute-src-block-target-nil-runs-locally-test ()
  "`:target nil' opts the block out of the heading's target."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Run\t\t:local:\n\n"
                        "#+begin_src sh :target nil\npwd\n#+end_src\n")
                target)
      (goto-char (point-min))
      (re-search-forward "begin_src")
      (let* ((here default-directory)
             (org-confirm-babel-evaluate nil)
             (result (file-name-as-directory
                      (file-truename (org-trim (org-babel-execute-src-block))))))
        (should (equal result (file-name-as-directory (file-truename here))))
        (should-not (equal result
                           (file-name-as-directory (file-truename target))))))))

(ert-deftest devops-execute-src-block-target-nil-skips-prompt-test ()
  "With `:target nil', multiple target tags do not prompt for a target."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n"
              "#+TARGET: /srv/two/ (t2)\n\n"
              "* Run\t\t:t1:t2:\n\n"
              "#+begin_src sh :target nil\npwd\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "begin_src")
    (let ((here default-directory)
          (org-confirm-babel-evaluate nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (error "Should not prompt for a target"))))
        (should (equal (file-name-as-directory
                        (file-truename (org-trim (org-babel-execute-src-block))))
                       (file-name-as-directory (file-truename here))))))))

(ert-deftest devops-execute-src-block-target-nil-from-property-test ()
  "`:target nil' works when inherited from a `header-args' property."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Run\t\t:local:\n"
                        ":PROPERTIES:\n"
                        ":header-args: :target nil\n"
                        ":END:\n\n"
                        "#+begin_src sh\npwd\n#+end_src\n")
                target)
      (goto-char (point-min))
      (re-search-forward "begin_src")
      (let ((here default-directory)
            (org-confirm-babel-evaluate nil))
        (should (equal (file-name-as-directory
                        (file-truename (org-trim (org-babel-execute-src-block))))
                       (file-name-as-directory (file-truename here))))))))

(ert-deftest devops-execute-src-block-unknown-target-errors-test ()
  "An unrecognized :target value errors rather than falling back to the tag."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Run\t\t:local:\n\n"
                        "#+begin_src sh :target elsewhere\npwd\n#+end_src\n")
                target)
      (goto-char (point-min))
      (re-search-forward "begin_src")
      (let ((org-confirm-babel-evaluate nil))
        (should-error (org-babel-execute-src-block) :type 'user-error)))))

(ert-deftest devops-execute-src-block-injects-dir-from-ref-test ()
  "A block under a tag whose target is a reference runs where it resolves."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: <<where()>> (local)\n\n"
                        "* Locate\n\n"
                        "#+name: where\n"
                        "#+begin_src sh :results output\necho %s\n#+end_src\n\n"
                        "* Run\t\t:local:\n\n"
                        "#+begin_src sh\npwd\n#+end_src\n")
                target)
      (goto-char (point-max))
      (re-search-backward "begin_src")
      (let* ((org-confirm-babel-evaluate nil)
             (result (org-babel-execute-src-block)))
        (should (equal (file-name-as-directory (file-truename (org-trim result)))
                       (file-name-as-directory (file-truename target))))))))

;;; Async sessions (decision 2: async execution in per-target sessions)

(defun devops-test--executor-params (lang)
  "Execute the src block at point with `org-babel-execute:LANG' stubbed out.
Return the header arguments the executor was handed, so an injected
`:session' or `:async' can be read without starting a shell."
  (let ((fn (intern (concat "org-babel-execute:" lang)))
        (seen nil))
    (cl-letf (((symbol-function fn)
               (lambda (_body params) (setq seen params) "")))
      (let ((org-confirm-babel-evaluate nil))
        (org-babel-execute-src-block)))
    seen))

(defmacro devops-test--with-session-org (header &rest body)
  "Run BODY on a sh block carrying HEADER, under a heading tagged `:local:'."
  (declare (indent 1))
  `(devops-test--with-org
       (concat "#+TARGET: /srv/app/ (local)\n\n"
               "* Run\t\t:local:\n\n"
               "#+begin_src sh " ,header "\npwd\n#+end_src\n")
     (goto-char (point-min))
     (re-search-forward "begin_src")
     ,@body))

(ert-deftest devops-session-async-off-by-default-test ()
  "Without `devops-enable-session-async', no session or async is injected."
  (devops-test--with-session-org ""
    (let ((params (devops-test--executor-params "sh")))
      (should (equal (cdr (assq :dir params)) "/srv/app/"))
      (should (equal (cdr (assq :session params)) "none"))
      (should-not (assq :async params)))))

(ert-deftest devops-session-async-injects-session-and-async-test ()
  "With the option on, a block gets `:session devops:TAG TARGET' and `:async yes'."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ""
      (let ((params (devops-test--executor-params "sh")))
        (should (equal (cdr (assq :dir params)) "/srv/app/"))
        (should (equal (cdr (assq :session params)) "devops:local /srv/app/"))
        (should (equal (cdr (assq :async params)) "yes"))))))

(ert-deftest devops-session-name-function-test ()
  "`devops-session-name-function' decides the session name."
  (let ((devops-enable-session-async t)
        (devops-session-name-function
         (lambda (tag target) (format "%s@%s" tag target))))
    (devops-test--with-session-org ""
      (should (equal (cdr (assq :session (devops-test--executor-params "sh")))
                     "local@/srv/app/")))))

(ert-deftest devops-session-async-explicit-session-wins-test ()
  "A `:session' on the block is not overwritten by the tag's session."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ":session other"
      (let ((params (devops-test--executor-params "sh")))
        (should (equal (cdr (assq :session params)) "other"))
        (should (equal (cdr (assq :async params)) "yes"))))))

(ert-deftest devops-session-async-session-none-test ()
  "`:session none' opts a block out of both the session and async."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ":session none"
      (let ((params (devops-test--executor-params "sh")))
        (should (equal (cdr (assq :session params)) "none"))
        (should-not (assq :async params))))))

(ert-deftest devops-session-async-explicit-async-no-test ()
  "`:async no' runs one block synchronously while keeping its session."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ":async no"
      (let ((params (devops-test--executor-params "sh")))
        (should (equal (cdr (assq :session params)) "devops:local /srv/app/"))
        (should (equal (cdr (assq :async params)) "no"))))))

(ert-deftest devops-session-async-results-value-stays-sync-test ()
  "A shell block with `:results value' gets :dir but no session or async.
Under `:async' ob-shell returns the whole output rather than the exit
status the block asked for; see `devops--shell-value-p'."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ":results value"
      (let ((params (devops-test--executor-params "sh")))
        (should (equal (cdr (assq :dir params)) "/srv/app/"))
        (should (equal (cdr (assq :session params)) "none"))
        (should-not (assq :async params))))))

(ert-deftest devops-session-async-results-output-injects-test ()
  "A shell block with `:results output' still gets its session and async."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ":results output"
      (let ((params (devops-test--executor-params "sh")))
        (should (equal (cdr (assq :session params)) "devops:local /srv/app/"))
        (should (equal (cdr (assq :async params)) "yes"))))))

(ert-deftest devops-session-async-default-results-follow-ob-shell-test ()
  "A bare `:results replace' is value or output as ob-shell decides.
`org-babel-shell-results-defaults-to-output' makes a shell block's default
result its output; off, the default is its exit status and the block
stays synchronous."
  (let ((devops-enable-session-async t))
    (let ((org-babel-shell-results-defaults-to-output t))
      (devops-test--with-session-org ""
        (should (equal (cdr (assq :async (devops-test--executor-params "sh")))
                       "yes"))))
    (let ((org-babel-shell-results-defaults-to-output nil))
      (devops-test--with-session-org ""
        (should-not (assq :async (devops-test--executor-params "sh")))))))

(ert-deftest devops--shell-value-p-test ()
  "Only shell languages have an exit-status result to protect."
  (should (devops--shell-value-p "sh" nil '((:result-params "value"))))
  (should (devops--shell-value-p "bash" '((:results . "value")) nil))
  (should (devops--shell-value-p "shell" '((:result-params "value" "replace"))
                                 nil))
  (should (devops--shell-value-p "sh" nil '((:results . "value replace"))))
  (should-not (devops--shell-value-p "sh" nil '((:result-params "output"))))
  (should-not (devops--shell-value-p "sh" nil '((:results . "output"))))
  (should-not (devops--shell-value-p "python" nil '((:result-params "value"))))
  (let ((org-babel-shell-results-defaults-to-output t))
    (should-not (devops--shell-value-p "sh" nil '((:result-params "replace")))))
  (let ((org-babel-shell-results-defaults-to-output nil))
    (should (devops--shell-value-p "sh" nil '((:result-params "replace"))))))

(ert-deftest devops-session-async-from-property-test ()
  "A `:session' inherited from a `header-args' property counts as explicit."
  (let ((devops-enable-session-async t))
    (devops-test--with-org
        (concat "#+TARGET: /srv/app/ (local)\n\n"
                "* Run\t\t:local:\n"
                ":PROPERTIES:\n"
                ":header-args: :session other\n"
                ":END:\n\n"
                "#+begin_src sh\npwd\n#+end_src\n")
      (goto-char (point-min))
      (re-search-forward "begin_src")
      (should (equal (cdr (assq :session (devops-test--executor-params "sh")))
                     "other")))))

(ert-deftest devops-session-async-language-restricted-test ()
  "Languages outside `devops-async-session-languages' get :dir and nothing else."
  (let ((devops-enable-session-async t))
    (devops-test--with-org
        (concat "#+TARGET: /srv/app/ (local)\n\n"
                "* Run\t\t:local:\n\n"
                "#+begin_src emacs-lisp\n\"hi\"\n#+end_src\n")
      (goto-char (point-min))
      (re-search-forward "begin_src")
      (let ((params (devops-test--executor-params "emacs-lisp")))
        (should (equal (cdr (assq :dir params)) "/srv/app/"))
        (should (equal (cdr (assq :session params)) "none"))
        (should-not (assq :async params))))))

(ert-deftest devops-session-async-explicit-dir-test ()
  "A block that names its own :dir gets no session either."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ":dir /srv/other/"
      (let ((params (devops-test--executor-params "sh")))
        (should (equal (cdr (assq :dir params)) "/srv/other/"))
        (should (equal (cdr (assq :session params)) "none"))
        (should-not (assq :async params))))))

(ert-deftest devops-session-async-target-nil-test ()
  "`:target nil' opts a block out of the session along with the target."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ":target nil"
      (let ((params (devops-test--executor-params "sh")))
        (should-not (assq :dir params))
        (should (equal (cdr (assq :session params)) "none"))
        (should-not (assq :async params))))))

(ert-deftest devops-with-sync-inhibits-async-test ()
  "`devops-with-sync' suppresses injection even with the option on."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ""
      (let ((params (devops-with-sync (devops-test--executor-params "sh"))))
        (should (equal (cdr (assq :dir params)) "/srv/app/"))
        (should (equal (cdr (assq :session params)) "none"))
        (should-not (assq :async params))))))

(ert-deftest devops-session-async-tangle-noweb-test ()
  "Tangling resolves an executing noweb reference to output, not a placeholder.
Under `:async' the return value of a block is a UUID, which is what would
land in the tangled file on the server."
  (let ((devops-enable-session-async t))
    (devops-test--with-local-target target
      (devops-test--with-org
          (format (concat "#+TARGET: %s (local)\n\n"
                          "* Deploy\t\t:local:\n\n"
                          "#+name: SECRET\n"
                          "#+begin_src sh\nprintf s3cret\n#+end_src\n\n"
                          "#+begin_src yaml :tangle config.yaml :noweb yes\n"
                          "api-key: <<SECRET()>>\n#+end_src\n")
                  target)
        (let ((org-confirm-babel-evaluate nil))
          (devops-tangle-headline (current-buffer) "Deploy"))
        (with-temp-buffer
          (insert-file-contents (concat target "config.yaml"))
          (should (search-forward "api-key: s3cret" nil t)))))))

(ert-deftest devops-session-async-executes-in-session-test ()
  "A block returns a placeholder, then its output arrives from the session.
The end-to-end path: the heading's tag names a shell session, the block
runs there at the target's directory, and `org-babel-comint-async-filter'
replaces the placeholder in the buffer when the command finishes."
  (let ((devops-enable-session-async t))
    (devops-test--with-local-target target
      (let ((session (devops--session-name "local" target)))
        (unwind-protect
            (devops-test--with-org
                (format (concat "#+TARGET: %s (local)\n\n"
                                "* Run\t\t:local:\n\n"
                                "#+begin_src sh\npwd\n#+end_src\n")
                        target)
              (goto-char (point-min))
              (re-search-forward "begin_src")
              (let* ((org-confirm-babel-evaluate nil)
                     (uuid (org-babel-execute-src-block))
                     (deadline (+ (float-time) 30)))
                (should (get-buffer session))
                (should (string-match-p "\\`[0-9a-f-]+\\'" uuid))
                (while (and (< (float-time) deadline)
                            (save-excursion
                              (goto-char (point-min))
                              (search-forward uuid nil t)))
                  (accept-process-output nil 0.2))
                (goto-char (point-min))
                (should-not (search-forward uuid nil t))
                (should (re-search-forward "^: \\(.+\\)$" nil t))
                (should (equal (file-name-as-directory
                                (file-truename (org-trim (match-string 1))))
                               (file-name-as-directory (file-truename target))))))
          (when-let* ((buf (get-buffer session)))
            (let ((kill-buffer-query-functions nil))
              (kill-buffer buf))))))))

(ert-deftest devops-session-async-var-reference-test ()
  "A `:var' naming another block gets that block's output, not a placeholder.
`org-babel-ref-resolve' executes the named block through
`org-babel-execute-src-block', which the advice turns async, so the
variable is bound to a UUID and the calling block prints it (issue #14).
Which wrong answer lands in the buffer depends on timing: \"hi UUID\"
when the reference's output arrives first, or the reference's own output
when it arrives second and `org-babel-comint-async-filter' finds its
UUID inside the caller's freshly inserted result."
  (let ((devops-enable-session-async t))
    (devops-test--with-local-target target
      (unwind-protect
          (devops-test--with-org
              (format (concat "#+TARGET: %s (local)\n\n"
                              "* Run\t\t:local:\n\n"
                              "#+name: name\n"
                              "#+begin_src sh :results output\necho Kyle\n#+end_src\n\n"
                              "#+begin_src sh :var NAME=name\necho \"hi $NAME\"\n#+end_src\n")
                      target)
            (goto-char (point-min))
            (re-search-forward "begin_src sh :var")
            (let* ((org-confirm-babel-evaluate nil)
                   (uuid (org-babel-execute-src-block))
                   (deadline (+ (float-time) 30)))
              (should (string-match-p "\\`[0-9a-f-]+\\'" uuid))
              (while (and (< (float-time) deadline)
                          (save-excursion
                            (goto-char (point-min))
                            (search-forward uuid nil t)))
                (accept-process-output nil 0.2))
              (goto-char (point-min))
              (should-not (search-forward uuid nil t))
              (goto-char (point-min))
              (re-search-forward "begin_src sh :var")
              (should (re-search-forward "^: \\(.+\\)$" nil t))
              (should (equal (org-trim (match-string 1)) "hi Kyle"))))
        (when-let* ((buf (get-buffer "devops:local /srv/app/")))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest devops-session-async-call-reference-test ()
  "A `#+call:' whose argument names a block gets its output, not a placeholder.
The call line itself runs synchronously -- `devops--session-declared-p'
counts a Library of Babel INFO as declared -- but resolving `name=name'
goes through `org-babel-ref-resolve' and executes the `name' block with
point on it, where the advice injects `:async'.  The same happens when
the called block's own `:var' names a block that the call does not
override (issue #14)."
  (let ((devops-enable-session-async t))
    (devops-test--with-local-target target
      (unwind-protect
          (devops-test--with-org
              (format (concat "#+TARGET: %s (local)\n\n"
                              "* Run\t\t:local:\n\n"
                              "#+name: name\n"
                              "#+begin_src sh :results output\necho Kyle\n#+end_src\n\n"
                              "#+name: say-hi\n"
                              "#+begin_src sh :var NAME=\"World\" :results output\n"
                              "echo \"hi $NAME\"\n#+end_src\n\n"
                              "#+call: say-hi(NAME=name)\n")
                      target)
            (goto-char (point-min))
            (re-search-forward "^#\\+call")
            (let ((org-confirm-babel-evaluate nil))
              (should (equal (org-trim (org-ctrl-c-ctrl-c)) "hi Kyle"))))
        (when-let* ((buf (get-buffer "devops:local /srv/app/")))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest devops-goto-session-test ()
  "`devops-goto-session' pops to the heading's session buffer."
  (let ((devops-enable-session-async t)
        (buf (get-buffer-create "devops:local /srv/app/")))
    (unwind-protect
        (devops-test--with-session-org ""
          (save-window-excursion
            (devops-goto-session)
            (should (eq (current-buffer) buf))))
      (kill-buffer buf))))

(ert-deftest devops-goto-session-without-buffer-errors-test ()
  "`devops-goto-session' says so when the session has not been started."
  (let ((devops-enable-session-async t))
    (devops-test--with-session-org ""
      (should-error (devops-goto-session) :type 'user-error))))

(ert-deftest devops-restart-session-test ()
  "`devops-restart-session' kills the heading's session buffer."
  (let ((devops-enable-session-async t)
        (buf (get-buffer-create "devops:local /srv/app/")))
    (unwind-protect
        (devops-test--with-session-org ""
          (devops-restart-session)
          (should-not (buffer-live-p buf)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest devops-session-no-target-errors-test ()
  "The session commands error on a heading with no target tag."
  (devops-test--with-org
      (concat "#+TARGET: /srv/app/ (local)\n\n"
              "* Run\n\n"
              "#+begin_src sh\npwd\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "begin_src")
    (should-error (devops-goto-session) :type 'user-error)
    (should-error (devops-restart-session) :type 'user-error)))

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

(ert-deftest devops-tangle-absolute-path-escapes-target-dir-test ()
  "An absolute :tangle path is not nested under a directory target."
  (devops-test--with-local-target target
    (devops-test--with-local-target elsewhere
      (devops-test--with-org
          (format (concat "#+TARGET: %s (local)\n\n"
                          "* Deploy\t\t:local:\n\n"
                          "#+begin_src txt :tangle %sapp.conf\n"
                          "key=val\n#+end_src\n")
                  target elsewhere)
        (devops-tangle-headline (current-buffer) "Deploy")
        (should (file-exists-p (concat elsewhere "app.conf")))
        ;; Not TARGET + ELSEWHERE glued together.
        (should-not (file-exists-p
                     (concat target (substring elsewhere 1) "app.conf")))))))

(ert-deftest devops-tangle-subdirectory-test ()
  "A relative subdirectory lands under the target, spelled either way."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+begin_src txt :tangle conf/a.txt :mkdirp yes\n"
                        "a\n#+end_src\n\n"
                        "#+begin_src txt :tangle ./conf/b.txt :mkdirp yes\n"
                        "b\n#+end_src\n")
                target)
      (devops-tangle-headline (current-buffer) "Deploy")
      (should (file-exists-p (concat target "conf/a.txt")))
      (should (file-exists-p (concat target "conf/b.txt"))))))

(ert-deftest devops-tangle-target-nil-tangles-locally-test ()
  "`:target nil' tangles beside the org file, leaving the target alone."
  (devops-test--with-local-target target
    (devops-test--with-local-target here
      (devops-test--with-org
          (format (concat "#+TARGET: %s (local)\n\n"
                          "* Deploy\t\t:local:\n\n"
                          "#+begin_src txt :tangle remote.txt\n"
                          "to the server\n#+end_src\n\n"
                          "#+begin_src txt :target nil :tangle local.txt\n"
                          "stays here\n#+end_src\n")
                  target)
        (let ((default-directory here))
          (devops-tangle-headline (current-buffer) "Deploy"))
        (should (file-exists-p (concat target "remote.txt")))
        (should (file-exists-p (concat here "local.txt")))
        ;; The opted-out block is not pushed to the target...
        (should-not (file-exists-p (concat target "local.txt")))
        ;; ...and the targeted one is not left behind locally.
        (should-not (file-exists-p (concat here "remote.txt")))))))

(ert-deftest devops-tangle-paths-target-nil-test ()
  "`devops--tangle-paths' names one local file for an opted-out block."
  (devops-test--with-org
      (concat "#+TARGET: /srv/one/ (t1)\n"
              "#+TARGET: /srv/two/ (t2)\n\n"
              "* Deploy\t\t:t1:t2:\n\n"
              "#+begin_src txt :target nil :tangle foo.txt\nhi\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "begin_src")
    (should (equal (devops--tangle-paths)
                   (list (expand-file-name "foo.txt"))))))

;;; Noweb (README: secrets via <<NAME()>>)

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
       (let* ((result (devops-drift--check (current-buffer) t))
              (root (car result))
              (entries (cdr result)))
         (unwind-protect
             (progn ,@body)
           (delete-directory root t))))))

(ert-deftest devops-drift--localize-path-test ()
  "Map :tangle paths to collision-free relative temp paths."
  (should (equal (devops-drift--localize-path "~/foo.txt") "home/foo.txt"))
  (should (equal (devops-drift--localize-path "~admin/foo.txt")
                 "home/admin/foo.txt"))
  (should (equal (devops-drift--localize-path "/etc/app.conf") "etc/app.conf"))
  (should (equal (devops-drift--localize-path "conf/app.conf") "conf/app.conf"))
  ;; TRAMP paths reduce to their remote-local part first.
  (should (equal (devops-drift--localize-path "/ssh:host:~/x.txt")
                 "home/x.txt"))
  (should (equal (devops-drift--localize-path "/ssh:host:/etc/x.conf")
                 "etc/x.conf")))

(ert-deftest devops-drift--destination-test ()
  "Map a :tangle path to (LOCAL . REMOTE)."
  (should (equal (devops-drift--destination "/ssh:host1:" "/tmp/root" "~/foo.txt" nil)
                 '("/tmp/root/home/foo.txt" . "/ssh:host1:~/foo.txt")))
  ;; An already-TRAMP path keeps itself as remote but tangles locally.
  (should (equal (devops-drift--destination
                  "/ssh:host1:" "/tmp/root" "/ssh:other:/etc/x.conf" nil)
                 '("/tmp/root/etc/x.conf" . "/ssh:other:/etc/x.conf"))))

(ert-deftest devops-drift--destination-skipped-test ()
  "Blocks with nothing to compare are left out, and so not tangled at all."
  (should-not (devops-drift--destination "/ssh:host1:" "/tmp/root" "yes" nil))
  (should-not (devops-drift--destination
               "/ssh:host1:" "/tmp/root" "~/bar.txt" '((:target . "nil")))))

(ert-deftest devops-drift-check-target-nil-skipped-test ()
  "A block that opted out of the target is not drift-checked."
  (devops-test--with-local-target target
    (devops-test--with-local-target here
      (devops-test--with-org
          (format (concat "#+TARGET: %s (local)\n\n"
                          "* Deploy\t\t:local:\n\n"
                          "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n\n"
                          "#+begin_src txt :target nil :tangle local.txt\n"
                          "stays here\n#+end_src\n")
                  target)
        (let ((default-directory here))
          (devops-tangle-headline (current-buffer) "Deploy"))
        (let* ((result (devops-drift--check (current-buffer) t))
               (entries (cdr result)))
          (unwind-protect
              (progn
                (should (= 1 (length entries)))
                (should (equal (plist-get (car entries) :path) "foo.txt")))
            (delete-directory (car result) t)))))))

(ert-deftest devops-drift-check-in-sync-test ()
  "A target that matches its tangled output reports `same'."
  (devops-test--with-local-target target
    (devops-test--with-org
        (format (concat "#+TARGET: %s (local)\n\n"
                        "* Deploy\t\t:local:\n\n"
                        "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n")
                target)
      (devops-tangle-headline (current-buffer) "Deploy")
      (let* ((result (devops-drift--check (current-buffer) t))
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

(ert-deftest devops-drift-check-comments-link-test ()
  "A freshly tangled block with `:comments link' is in sync, link and all."
  (devops-test--with-local-target target
    (devops-test--with-local-target here
      (let ((org (expand-file-name "notes.org" here))
            (org-babel-tangle-use-relative-file-links t)
            buf)
        (with-temp-file org
          (insert (format (concat "#+TARGET: %s (local)\n\n"
                                  "* Deploy\t\t:local:\n\n"
                                  "#+begin_src sh :tangle out.sh :comments link\n"
                                  "echo hi\n#+end_src\n")
                          target)))
        (unwind-protect
            (progn
              (setq buf (find-file-noselect org))
              (devops-tangle-all buf)
              (let* ((result (devops-drift--check buf t))
                     (entries (cdr result)))
                (unwind-protect
                    (should (equal (mapcar (lambda (e) (plist-get e :status))
                                           entries)
                                   '(:same)))
                  (delete-directory (car result) t))))
          (when buf (kill-buffer buf)))))))

(ert-deftest devops-drift-check-drift-test ()
  "A target file that was changed out-of-band reports `drift'."
  (devops-test--with-drift-check target
      (concat "#+TARGET: %s (local)\n\n"
              "* Deploy\t\t:local:\n\n"
              "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n")
    (ignore entries root)
    (with-temp-file (concat target "foo.txt") (insert "changed on server\n"))
    ;; Re-run: previous check tangled but target now differs.
    (let ((again (devops-drift--check (current-buffer) t)))
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
      (let ((result (devops-drift--check (current-buffer))))
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

(defun devops-test--indicator-overlays (pos)
  "Return drift indicator overlays on the line containing POS."
  (save-excursion
    (goto-char pos)
    (seq-filter (lambda (ov) (overlay-get ov 'devops-drift))
                ;; Bound past eol: `overlays-in' drops empty overlays
                ;; sitting exactly at its END position.
                (overlays-in (line-beginning-position)
                             (min (1+ (line-end-position)) (point-max))))))

(ert-deftest devops-drift-indicator-dots-test ()
  "A checked block gets one dot per target, in tag order, with status faces."
  (devops-test--with-local-target t1
    (devops-test--with-local-target t2
      (devops-test--with-org
          (format (concat "#+TARGET: %s (host1)\n"
                          "#+TARGET: %s (host2)\n\n"
                          "* Deploy\t\t:host1:host2:\n\n"
                          "#+begin_src txt :tangle foo.txt\nhello\n#+end_src\n")
                  t1 t2)
        (devops-tangle-headline (current-buffer) "Deploy")
        ;; host1 stays in sync; host2's copy disappears out-of-band.
        (delete-file (concat t2 "foo.txt"))
        (let ((result (devops-drift--check (current-buffer) t)))
          (unwind-protect
              (progn
                (devops-drift--decorate-source (current-buffer) (cdr result))
                (goto-char (point-min))
                (search-forward "#+begin_src txt")
                (let ((ovs (devops-test--indicator-overlays (point))))
                  (should (= 1 (length ovs)))
                  (let ((dots (overlay-get (car ovs) 'after-string)))
                    (should (equal (substring-no-properties dots) "  ●●"))
                    (should (eq (get-text-property 2 'face dots) 'success))
                    (should (eq (get-text-property 3 'face dots) 'error))
                    (should (string-prefix-p
                             "host1: ok" (get-text-property 2 'help-echo dots)))
                    (should (string-prefix-p
                             "host2: MISSING"
                             (get-text-property 3 'help-echo dots)))))
                (devops-drift-clear-indicators)
                (should-not (devops-test--indicator-overlays (point))))
            (delete-directory (car result) t)))))))

(ert-deftest devops-drift-indicator-via-command-test ()
  "`devops-drift' decorates the source; a re-run replaces the overlays."
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
              (progn
                (with-current-buffer source
                  (goto-char (point-min))
                  (search-forward "#+begin_src txt")
                  (should (= 1 (length
                                (devops-test--indicator-overlays (point)))))
                  ;; Second run must not stack a second overlay.
                  (org-back-to-heading)
                  (devops-drift))
                (with-current-buffer source
                  (goto-char (point-min))
                  (search-forward "#+begin_src txt")
                  (should (= 1 (length
                                (devops-test--indicator-overlays (point)))))))
            (when (buffer-live-p report) (kill-buffer report))))))))

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
