;;; test-capi.el --- Tests for k8s-capi (Cluster API browser) -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'k8s-capi)

;;; ---------------------------------------------------------------------------
;;; Synthetic CAPI objects (a management cluster owning one workload cluster)

(defun capi-test--labels (&rest kvs)
  "Build a labels alist from KVS pairs of (STRING-KEY STRING-VAL ...).
CAPI label keys have dots and slashes, so they must be interned."
  (cl-loop for (k v) on kvs by #'cddr collect (cons (intern k) v)))

(defconst capi-test--cluster
  '((metadata . ((name . "prod") (namespace . "default")))
    (spec . ((infrastructureRef . ((kind . "DockerCluster")))))
    (status . ((phase . "Provisioned")))))

(defvar capi-test--kcp
  `((metadata . ((name . "prod-cp")
                 (labels . ,(capi-test--labels
                             "cluster.x-k8s.io/cluster-name" "prod"))))
    (spec . ((version . "v1.30.2") (replicas . 3)))
    (status . ((readyReplicas . 3)))))

(defvar capi-test--cp-machine
  `((metadata . ((name . "prod-cp-aaa")
                 (labels . ,(capi-test--labels
                             "cluster.x-k8s.io/cluster-name" "prod"
                             "cluster.x-k8s.io/control-plane" ""))))
    (spec . ((version . "v1.30.2")))
    (status . ((phase . "Running")
               (nodeRef . ((name . "prod-cp-node")))))))

(defvar capi-test--md
  `((metadata . ((name . "prod-workers")
                 (labels . ,(capi-test--labels
                             "cluster.x-k8s.io/cluster-name" "prod"))))
    (spec . ((replicas . 2)
             (template . ((spec . ((version . "v1.30.2")))))))
    (status . ((readyReplicas . 2) (phase . "Running")))))

(defvar capi-test--ms
  `((metadata . ((name . "prod-workers-abc")
                 (labels . ,(capi-test--labels
                             "cluster.x-k8s.io/cluster-name" "prod"
                             "cluster.x-k8s.io/deployment-name" "prod-workers"))))
    (spec . ((replicas . 2)))
    (status . ((readyReplicas . 2)))))

(defvar capi-test--worker
  `((metadata . ((name . "prod-workers-abc-1")
                 (labels . ,(capi-test--labels
                             "cluster.x-k8s.io/cluster-name" "prod"
                             "cluster.x-k8s.io/set-name" "prod-workers-abc"))))
    (spec . ((version . "v1.30.2")))
    (status . ((phase . "Running")
               (nodeRef . ((name . "worker-node-1")))))))

;;; ---------------------------------------------------------------------------
;;; Label / status accessors

(ert-deftest capi/cluster-of ()
  (should (equal "prod" (k8s-capi--cluster-of capi-test--kcp)))
  (should (equal "prod" (k8s-capi--cluster-of capi-test--worker)))
  (should-not (k8s-capi--cluster-of capi-test--cluster)))

(ert-deftest capi/control-plane-p ()
  (should (k8s-capi--control-plane-p capi-test--cp-machine))
  (should-not (k8s-capi--control-plane-p capi-test--worker)))

(ert-deftest capi/label-lookup ()
  (should (equal "prod-workers"
                 (k8s-capi--label capi-test--ms
                                  "cluster.x-k8s.io/deployment-name")))
  (should-not (k8s-capi--label capi-test--ms "no.such/label")))

(ert-deftest capi/phase-and-face ()
  (should (equal "Provisioned" (k8s-capi--phase capi-test--cluster)))
  (should (equal "Unknown" (k8s-capi--phase '((metadata . nil)))))
  (should (eq 'k8s-status-running (k8s-capi--phase-face "Running")))
  (should (eq 'k8s-status-pending (k8s-capi--phase-face "Provisioning")))
  (should (eq 'k8s-status-failed (k8s-capi--phase-face "Failed")))
  (should (eq 'k8s-status-other (k8s-capi--phase-face "Weird"))))

(ert-deftest capi/md-version ()
  (should (equal "v1.30.2" (k8s-capi--md-version capi-test--md)))
  (should-not (k8s-capi--md-version capi-test--cluster)))

(ert-deftest capi/replicas-str ()
  (let ((full (k8s-capi--replicas-str capi-test--kcp)))
    (should (equal "3/3 ready" (substring-no-properties full)))
    (should (eq 'k8s-status-running
                (get-text-property 0 'font-lock-face full))))
  ;; not-all-ready -> pending face
  (let* ((half '((spec . ((replicas . 3))) (status . ((readyReplicas . 1)))))
         (s (k8s-capi--replicas-str half)))
    (should (equal "1/3 ready" (substring-no-properties s)))
    (should (eq 'k8s-status-pending
                (get-text-property 0 'font-lock-face s)))))

;;; ---------------------------------------------------------------------------
;;; CRD discovery + fetch/group

(defun capi-test--crd (group kind plural)
  `((spec . ((group . ,group)
             (names . ((kind . ,kind) (plural . ,plural)))
             (versions . [((name . "v1beta1") (served . t) (storage . t))])))))

(defconst capi-test--crd-list
  (vector
   (capi-test--crd "cluster.x-k8s.io" "Cluster" "clusters")
   (capi-test--crd "controlplane.cluster.x-k8s.io"
                   "KubeadmControlPlane" "kubeadmcontrolplanes")
   (capi-test--crd "cluster.x-k8s.io" "MachineDeployment" "machinedeployments")
   (capi-test--crd "cluster.x-k8s.io" "MachineSet" "machinesets")
   (capi-test--crd "cluster.x-k8s.io" "Machine" "machines")))

(ert-deftest capi/find-crd ()
  (let ((crd (k8s-capi--find-crd capi-test--crd-list
                                 "cluster.x-k8s.io" "MachineSet")))
    (should crd)
    (should (equal "machinesets"
                   (cdr (assq 'plural (cdr (assq 'names (cdr (assq 'spec crd)))))))))
  (should-not (k8s-capi--find-crd capi-test--crd-list "apps" "Deployment")))

(defun capi-test--with-stubbed-api (fn)
  "Call FN with `k8s-crds-list' / `k8s-get' stubbed to the fixtures."
  (let ((path->items
         `(("/apis/cluster.x-k8s.io/v1beta1/clusters" . ,(vector capi-test--cluster))
           ("/apis/controlplane.cluster.x-k8s.io/v1beta1/kubeadmcontrolplanes"
            . ,(vector capi-test--kcp))
           ("/apis/cluster.x-k8s.io/v1beta1/machinedeployments" . ,(vector capi-test--md))
           ("/apis/cluster.x-k8s.io/v1beta1/machinesets" . ,(vector capi-test--ms))
           ("/apis/cluster.x-k8s.io/v1beta1/machines"
            . ,(vector capi-test--cp-machine capi-test--worker)))))
    (cl-letf (((symbol-function 'k8s-crds-list)
               (lambda (_conn) capi-test--crd-list))
              ((symbol-function 'k8s-get)
               (lambda (_conn path)
                 `((items . ,(or (cdr (assoc path path->items)) (vector)))))))
      (funcall fn))))

(ert-deftest capi/collect-groups ()
  (capi-test--with-stubbed-api
   (lambda ()
     (let ((data (k8s-capi--collect 'conn)))
       (should (= 1 (length (plist-get data :clusters))))
       (should (= 1 (length (plist-get data :kcps))))
       (should (= 1 (length (plist-get data :mds))))
       (should (= 1 (length (plist-get data :machinesets))))
       (should (= 2 (length (plist-get data :machines))))))))

(ert-deftest capi/collect-nil-without-cluster-crd ()
  "Without the Cluster CRD, collect returns nil (graceful empty state)."
  (cl-letf (((symbol-function 'k8s-crds-list)
             (lambda (_conn)
               (vector (capi-test--crd "apps" "Deployment" "deployments")))))
    (should-not (k8s-capi--collect 'conn))))

;;; ---------------------------------------------------------------------------
;;; Tree rendering

(ert-deftest capi/render-tree ()
  (capi-test--with-stubbed-api
   (lambda ()
     (let ((data (k8s-capi--collect 'conn)))
       (with-temp-buffer
         (magit-section-mode)
         (let ((inhibit-read-only t))
           (magit-insert-section (k8s-root)
             (dolist (c (plist-get data :clusters))
               (k8s-capi--insert-cluster c data))))
         (let ((s (substring-no-properties (buffer-string))))
           (dolist (want '("Cluster" "default/prod" "(Provisioned)"
                           "infra: DockerCluster"
                           "Control plane" "prod-cp" "3/3 ready"
                           "prod-cp-aaa" "node prod-cp-node"
                           "MachineDeployment" "prod-workers" "2/2 ready"
                           "MachineSet" "prod-workers-abc"
                           "prod-workers-abc-1" "node worker-node-1"))
             (should (string-match-p (regexp-quote want) s)))
           ;; the worker is nested under its MachineSet, which is under the MD
           (should (< (string-match "MachineDeployment" s)
                      (string-match "MachineSet" s)
                      (string-match "prod-workers-abc-1" s)))))))))

;;; ---------------------------------------------------------------------------
;;; Kubeconfig Secret decode (the pivot's payload)

(ert-deftest capi/fetch-kubeconfig-decodes-secret ()
  (let ((payload "apiVersion: v1\nkind: Config\ncurrent-context: prod\n"))
    (cl-letf (((symbol-function 'k8s-get-resource)
               (lambda (_conn _path)
                 `((data . ((value . ,(base64-encode-string payload))))))))
      (should (equal payload
                     (k8s-capi--fetch-kubeconfig 'conn "default" "prod"))))))

(ert-deftest capi/fetch-kubeconfig-errors-without-value ()
  (cl-letf (((symbol-function 'k8s-get-resource)
             (lambda (_conn _path) '((data . nil)))))
    (should-error (k8s-capi--fetch-kubeconfig 'conn "default" "prod")
                  :type 'user-error)))

(provide 'test-capi)
;;; test-capi.el ends here
