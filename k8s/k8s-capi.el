;;; k8s-capi.el --- Cluster API (CAPI) workload-cluster browser -*- lexical-binding: t -*-
;;
;; Browse the workload clusters a CAPI *management cluster* owns, and
;; pivot eltainer into any one of them with a keystroke.
;;
;; Everything CAPI exposes is a CustomResource on the management
;; cluster's API server, so this view is built entirely on the existing
;; `k8s-get' transport and the CRD-version discovery in `k8s-crds.el' —
;; no `clusterctl', no `kubectl'.  The kinds we render:
;;
;;   Cluster                 cluster.x-k8s.io
;;   KubeadmControlPlane     controlplane.cluster.x-k8s.io
;;   MachineDeployment       cluster.x-k8s.io
;;   MachineSet              cluster.x-k8s.io
;;   Machine                 cluster.x-k8s.io
;;
;; The tree is assembled from the standard CAPI labels rather than by
;; walking ownerReferences:
;;
;;   cluster.x-k8s.io/cluster-name     groups everything under a Cluster
;;   cluster.x-k8s.io/control-plane    marks control-plane Machines
;;   cluster.x-k8s.io/deployment-name  groups MachineSets under their MD
;;   cluster.x-k8s.io/set-name         groups Machines under their MS
;;
;; v1 is read-only plus the pivot (RET on a Cluster row): fetch the
;; `<cluster>-kubeconfig' Secret CAPI writes to the management cluster,
;; decode it, cache it 0600, and hand it to the existing kubeconfig
;; switch path.  Lifecycle writes (scale / pause / delete / upgrade)
;; are v2 — see docs/capi-plan.md.

(require 'cl-lib)
(require 'seq)
(require 'magit-section)
(require 'eltainer-ui)
(require 'k8s-config)            ; k8s-config-load / -current-context
(require 'k8s-api)               ; k8s-get / k8s-get-resource
(require 'k8s-marks)             ; k8s-common-map
(require 'k8s-crds)              ; k8s-crds-list / k8s-crds--active-version
(require 'k8s)                   ; k8s--ensure-connection / -insert-header / faces

(declare-function eltainer--apply-context-switch "eltainer" (file ctx))

(defgroup k8s-capi nil
  "Browse and pivot into Cluster API workload clusters."
  :group 'k8s
  :prefix "k8s-capi-")

(defcustom k8s-capi-kubeconfig-cache-dir
  (expand-file-name "eltainer/capi"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name "~/.cache")))
  "Directory for workload-cluster kubeconfigs fetched during a pivot.
Each `<cluster>-kubeconfig' Secret is decoded and written here mode
0600 so the existing file-based kubeconfig switch can point at it.
These files carry cluster-admin credentials — keep the directory
private."
  :type 'directory
  :group 'k8s-capi)

(defconst k8s-capi--core-group "cluster.x-k8s.io"
  "API group for Cluster / MachineDeployment / MachineSet / Machine.")

(defconst k8s-capi--cp-group "controlplane.cluster.x-k8s.io"
  "API group for KubeadmControlPlane.")

;;; ---------------------------------------------------------------------------
;;; Accessors

(defun k8s-capi--labels (obj)
  "Return the `metadata.labels' alist of resource OBJ."
  (cdr (assq 'labels (cdr (assq 'metadata obj)))))

(defun k8s-capi--label (obj key)
  "Return label KEY (a string) on OBJ, or nil.
CAPI label keys contain dots and slashes, so look them up by interned
symbol rather than a quoted literal."
  (cdr (assq (intern key) (k8s-capi--labels obj))))

(defun k8s-capi--cluster-of (obj)
  "Return the `cluster.x-k8s.io/cluster-name' label of OBJ."
  (k8s-capi--label obj "cluster.x-k8s.io/cluster-name"))

(defun k8s-capi--control-plane-p (machine)
  "Return non-nil when MACHINE carries the control-plane label."
  (and (assq (intern "cluster.x-k8s.io/control-plane")
             (k8s-capi--labels machine))
       t))

(defun k8s-capi--phase (obj)
  "Return `status.phase' of OBJ, or \"Unknown\"."
  (or (cdr (assq 'phase (cdr (assq 'status obj)))) "Unknown"))

(defun k8s-capi--phase-face (phase)
  "Map a CAPI PHASE string to a face."
  (pcase phase
    ((or "Provisioned" "Running") 'k8s-status-running)
    ((or "Provisioning" "Pending" "ScalingUp" "ScalingDown" "Deleting")
     'k8s-status-pending)
    ("Failed" 'k8s-status-failed)
    (_ 'k8s-status-other)))

(defun k8s-capi--md-version (md)
  "Return `spec.template.spec.version' of MachineDeployment MD, or nil."
  (let* ((spec (cdr (assq 'spec md)))
         (tmpl (cdr (assq 'template spec)))
         (tspec (cdr (assq 'spec tmpl))))
    (cdr (assq 'version tspec))))

(defun k8s-capi--replicas-str (obj)
  "Return a `readyReplicas/replicas ready' string for OBJ, faced."
  (let* ((status (cdr (assq 'status obj)))
         (spec (cdr (assq 'spec obj)))
         (ready (or (cdr (assq 'readyReplicas status)) 0))
         (desired (or (cdr (assq 'replicas spec))
                      (cdr (assq 'replicas status))
                      0)))
    (propertize (format "%d/%d ready" ready desired)
                'font-lock-face (if (and (> desired 0) (= ready desired))
                                    'k8s-status-running
                                  'k8s-status-pending))))

;;; ---------------------------------------------------------------------------
;;; Fetch + group

(defun k8s-capi--find-crd (crds group kind)
  "Return the CRD alist in CRDS matching GROUP and KIND, or nil."
  (seq-find (lambda (c)
              (let ((spec (cdr (assq 'spec c))))
                (and (equal (cdr (assq 'group spec)) group)
                     (equal (cdr (assq 'kind (cdr (assq 'names spec))))
                            kind))))
            crds))

(defun k8s-capi--list (conn crd)
  "List every instance of CRD across all namespaces via CONN.
Returns a list (possibly empty); nil if CRD is nil or the GET fails."
  (when crd
    (let* ((spec (cdr (assq 'spec crd)))
           (group (cdr (assq 'group spec)))
           (plural (cdr (assq 'plural (cdr (assq 'names spec)))))
           (version (cdr (assq 'name (k8s-crds--active-version crd))))
           (path (format "/apis/%s/%s/%s" group version plural)))
      (condition-case err
          (append (cdr (assq 'items (k8s-get conn path))) nil)
        (error
         (message "k8s-capi: GET %s failed: %s"
                  path (error-message-string err))
         nil)))))

(defun k8s-capi--collect (conn)
  "Fetch all CAPI resources via CONN.
Returns a plist (:clusters :kcps :mds :machinesets :machines), each a
list, or nil when the management `Cluster' CRD is absent — i.e. this
isn't a CAPI management cluster."
  (let* ((crds (append (k8s-crds-list conn) nil))
         (cluster-crd (k8s-capi--find-crd crds k8s-capi--core-group "Cluster")))
    (when cluster-crd
      (list :clusters
            (k8s-capi--list conn cluster-crd)
            :kcps
            (k8s-capi--list conn (k8s-capi--find-crd
                                  crds k8s-capi--cp-group
                                  "KubeadmControlPlane"))
            :mds
            (k8s-capi--list conn (k8s-capi--find-crd
                                  crds k8s-capi--core-group
                                  "MachineDeployment"))
            :machinesets
            (k8s-capi--list conn (k8s-capi--find-crd
                                  crds k8s-capi--core-group "MachineSet"))
            :machines
            (k8s-capi--list conn (k8s-capi--find-crd
                                  crds k8s-capi--core-group "Machine"))))))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defun k8s-capi--insert-machine (machine)
  "Insert one Machine leaf row for MACHINE."
  (let* ((name (k8s--resource-name machine))
         (phase (k8s-capi--phase machine))
         (node (cdr (assq 'name (cdr (assq 'nodeRef
                                           (cdr (assq 'status machine)))))))
         (version (cdr (assq 'version (cdr (assq 'spec machine))))))
    (magit-insert-section (capi-machine machine t)
      (magit-insert-heading
        (format "      %-34s %-12s %-26s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize phase 'font-lock-face (k8s-capi--phase-face phase))
                (if node
                    (concat "node " node)
                  (propertize "(no node yet)" 'font-lock-face 'k8s-dim))
                (or version ""))))))

(defun k8s-capi--insert-machineset (ms machines)
  "Insert MachineSet MS and its Machines (filtered from MACHINES)."
  (let ((name (k8s--resource-name ms)))
    (magit-insert-section (capi-machineset ms)
      (magit-insert-heading
        (format "    %-16s %-32s %s\n"
                (propertize "MachineSet" 'font-lock-face 'k8s-dim)
                (propertize name 'font-lock-face 'k8s-resource-name)
                (k8s-capi--replicas-str ms)))
      (dolist (mc (cl-remove-if-not
                   (lambda (m)
                     (equal (k8s-capi--label m "cluster.x-k8s.io/set-name")
                            name))
                   machines))
        (k8s-capi--insert-machine mc)))))

(defun k8s-capi--insert-md (md data)
  "Insert MachineDeployment MD and its MachineSets, from collected DATA."
  (let ((name (k8s--resource-name md))
        (phase (k8s-capi--phase md)))
    (magit-insert-section (capi-md md)
      (magit-insert-heading
        (format "  %-18s %-30s %-14s %-12s %s\n"
                (propertize "MachineDeployment"
                            'font-lock-face 'k8s-section-heading)
                (propertize name 'font-lock-face 'k8s-resource-name)
                (k8s-capi--replicas-str md)
                (propertize phase 'font-lock-face (k8s-capi--phase-face phase))
                (or (k8s-capi--md-version md) "")))
      (dolist (ms (cl-remove-if-not
                   (lambda (o)
                     (equal (k8s-capi--label
                             o "cluster.x-k8s.io/deployment-name")
                            name))
                   (plist-get data :machinesets)))
        (k8s-capi--insert-machineset ms (plist-get data :machines))))))

(defun k8s-capi--insert-control-plane (kcp machines)
  "Insert KubeadmControlPlane KCP and its control-plane Machines."
  (let* ((name (k8s--resource-name kcp))
         (cluster (k8s-capi--cluster-of kcp))
         (version (cdr (assq 'version (cdr (assq 'spec kcp))))))
    (magit-insert-section (capi-controlplane kcp)
      (magit-insert-heading
        (format "  %-18s %-30s %-14s %-12s %s\n"
                (propertize "Control plane" 'font-lock-face 'k8s-section-heading)
                (propertize name 'font-lock-face 'k8s-resource-name)
                (k8s-capi--replicas-str kcp)
                ""
                (or version "")))
      (dolist (mc (cl-remove-if-not
                   (lambda (m)
                     (and (equal (k8s-capi--cluster-of m) cluster)
                          (k8s-capi--control-plane-p m)))
                   machines))
        (k8s-capi--insert-machine mc)))))

(defun k8s-capi--insert-cluster (cluster data)
  "Insert Cluster CLUSTER and its whole tree, from collected DATA."
  (let* ((name (k8s--resource-name cluster))
         (ns (k8s--resource-namespace cluster))
         (phase (k8s-capi--phase cluster))
         (infra (cdr (assq 'kind (cdr (assq 'infrastructureRef
                                            (cdr (assq 'spec cluster))))))))
    (magit-insert-section (capi-cluster cluster)
      (magit-insert-heading
        (format "%s %-32s %-16s infra: %s\n"
                (propertize "Cluster" 'font-lock-face 'k8s-section-heading)
                (propertize (format "%s/%s" ns name)
                            'font-lock-face 'k8s-resource-name)
                (propertize (format "(%s)" phase)
                            'font-lock-face (k8s-capi--phase-face phase))
                (propertize (or infra "—") 'font-lock-face 'k8s-dim)))
      (let ((kcp (cl-find name (plist-get data :kcps)
                          :key #'k8s-capi--cluster-of :test #'equal)))
        (when kcp
          (k8s-capi--insert-control-plane kcp (plist-get data :machines))))
      (dolist (md (cl-remove-if-not
                   (lambda (o) (equal (k8s-capi--cluster-of o) name))
                   (plist-get data :mds)))
        (k8s-capi--insert-md md data))
      (insert "\n"))))

(defun k8s-capi--refresh ()
  "Re-fetch and redraw the `*k8s:capi*' buffer."
  (let* ((inhibit-read-only t)
         (conn (k8s--ensure-connection))
         (data (k8s-capi--collect conn)))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (k8s-root)
      (k8s--insert-header "Clusters (CAPI)")
      (cond
       ((null data)
        (insert (propertize
                 "  Cluster API is not installed on this cluster.\n"
                 'font-lock-face 'k8s-dim))
        (insert (propertize
                 "  (no cluster.x-k8s.io/Cluster CRD — not a CAPI \
management cluster)\n"
                 'font-lock-face 'k8s-dim)))
       ((null (plist-get data :clusters))
        (insert (propertize "  (no Clusters found)\n"
                            'font-lock-face 'k8s-dim)))
       (t
        (insert (propertize
                 "  RET on a Cluster row switches eltainer into that \
workload cluster.\n\n"
                 'font-lock-face 'k8s-dim))
        (dolist (cluster (plist-get data :clusters))
          (k8s-capi--insert-cluster cluster data)))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))))

;;; ---------------------------------------------------------------------------
;;; Pivot into a workload cluster

(defun k8s-capi--cluster-at-point ()
  "Return the Cluster alist under point, or signal."
  (let ((sec (magit-current-section)))
    (unless (and sec (eq (oref sec type) 'capi-cluster))
      (user-error "Point is not on a Cluster row"))
    (oref sec value)))

(defun k8s-capi--fetch-kubeconfig (conn ns name)
  "Fetch and decode the `<NAME>-kubeconfig' Secret in NS via CONN.
Returns the kubeconfig as a string; signals if the Secret is missing."
  (let* ((path (format "/api/v1/namespaces/%s/secrets/%s-kubeconfig"
                       ns name))
         (secret (condition-case err
                     (k8s-get-resource conn path)
                   (error
                    (user-error "Could not read %s-kubeconfig in %s: %s"
                                name ns (error-message-string err)))))
         (value (cdr (assq 'value (cdr (assq 'data secret))))))
    (unless value
      (user-error "Secret %s-kubeconfig in %s has no `data.value'"
                  name ns))
    ;; Secret `data' values arrive base64-encoded over the API; the
    ;; CAPI kubeconfig Secret stores the plain kubeconfig, so one
    ;; decode (unlike Helm's base64+base64+gzip release blobs).
    (base64-decode-string value)))

(defun k8s-capi-pivot-at-point ()
  "Switch eltainer into the workload cluster under point.
Fetches the cluster's `<name>-kubeconfig' Secret, caches it 0600 under
`k8s-capi-kubeconfig-cache-dir', and points eltainer's k8s connection
at it via the existing kubeconfig switch."
  (interactive)
  (let* ((cluster (k8s-capi--cluster-at-point))
         (conn (k8s--ensure-connection))
         (name (k8s--resource-name cluster))
         (ns (k8s--resource-namespace cluster))
         (kubeconfig (k8s-capi--fetch-kubeconfig conn ns name))
         (file (expand-file-name (format "%s-%s.kubeconfig" ns name)
                                 k8s-capi-kubeconfig-cache-dir)))
    (make-directory k8s-capi-kubeconfig-cache-dir t)
    (with-temp-file file (insert kubeconfig))
    (set-file-modes file #o600)
    (let ((ctx (condition-case nil
                   (k8s-config-current-context (k8s-config-load file))
                 (error nil))))
      (eltainer--apply-context-switch file ctx))))

(defun k8s-capi-dwim ()
  "RET: pivot into the Cluster under point, else toggle the section."
  (interactive)
  (let ((sec (magit-current-section)))
    (if (and sec (eq (oref sec type) 'capi-cluster))
        (k8s-capi-pivot-at-point)
      (call-interactively #'magit-section-toggle))))

;;; ---------------------------------------------------------------------------
;;; Major mode + entry point

(defvar k8s-capi-mode-map (make-sparse-keymap)
  "Keymap for `k8s-capi-mode'.")
(set-keymap-parent k8s-capi-mode-map k8s-common-map)
(keymap-set k8s-capi-mode-map "RET" #'k8s-capi-dwim)

(define-derived-mode k8s-capi-mode magit-section-mode "K8s:CAPI"
  "Read-only browser for Cluster API workload clusters.

RET on a Cluster row switches eltainer into that workload cluster;
elsewhere it expands/collapses the section.

\\{k8s-capi-mode-map}"
  :interactive nil
  :group 'k8s-capi
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm) (k8s-capi--refresh))))

;;;###autoload
(defun k8s-capi ()
  "Browse the Cluster API workload clusters this management cluster owns."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:capi*")))
    (with-current-buffer buf
      (k8s-capi-mode)
      (k8s--ensure-connection)
      (k8s-capi--refresh))
    (pop-to-buffer buf)))

(provide 'k8s-capi)
;;; k8s-capi.el ends here
