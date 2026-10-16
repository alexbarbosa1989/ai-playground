#!/usr/bin/env bash
# setup-llm-d.sh
# Platform bootstrap for plain Distributed Inference with llm-d on RHOAI 3.4+ — NO
# Models-as-a-Service (MaaS) component anywhere in this script or project. Sibling of
# ../maas-rhoai, which this borrows its scripting conventions from, but llm-d and MaaS are
# two independent, co-installable features of the same KServe/LLMInferenceService stack —
# this project only ever touches the plain llm-d path.
#
# Based on RHOAI 3.4's official doc:
#   https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/deploy_models_using_distributed_inference_with_llm-d/index
#
# CONFIRMED FROM THAT DOC (Ch 1.1 prerequisites):
#   - OpenShift >= 4.19.9, OpenShift Service Mesh v2 NOT installed
#   - A GatewayClass + a Gateway named exactly "openshift-ai-inference" in "openshift-ingress"
#   - The LeaderWorkerSet Operator installed (used for multi-node/disaggregated deployments;
#     the doc lists it as a blanket prerequisite, not conditional on actually using it)
#   - Authentication enabled via Red Hat Connectivity Link (RHCL/Kuadrant/Authorino) UNLESS
#     every LLMInferenceService instead carries security.opendatahub.io/enable-auth: "false"
#     (the doc's own words: "Production deployments should not set this annotation")
#
# UNCONFIRMED AT WRITING TIME: the LeaderWorkerSet Operator's exact OLM Subscription `name`/
# package. docs.redhat.com returned 503/timeout on that specific chapter for both a pinned
# version and the "latest" alias while this script was written. install_lws_operator() below
# discovers the package name live from `oc get packagemanifest` instead of hardcoding a guess
# (same approach as lib/common.sh's detect_gpu_hardware_profile) — channel (stable-v1.0) and
# recommended namespace (openshift-lws-operator) ARE confirmed, from a web search result
# quoting that same doc chapter, just not the exact package string.
#
# Usage:
#   ./setup-llm-d.sh [--skip-auth] [--skip-lws] [--skip-cert-manager] [--skip-metallb]
#                     [--metallb-ip-range RANGE] [--extra-gateway-namespace NS] [--help]

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RHOAI_OPERATOR_NS="${RHOAI_OPERATOR_NS:-redhat-ods-operator}"
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
CERT_MANAGER_NS="${CERT_MANAGER_NS:-cert-manager-operator}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
LWS_NS="${LWS_NS:-openshift-lws-operator}"
MODEL_NS="${MODEL_NS:-llm-d-models}"
DSC_NAME="${DSC_NAME:-default-dsc}"
GATEWAY_NS="openshift-ingress"
GATEWAY_NAME="openshift-ai-inference"

OPERATOR_WAIT_TIMEOUT="${OPERATOR_WAIT_TIMEOUT:-600}"   # seconds
POD_WAIT_TIMEOUT="${POD_WAIT_TIMEOUT:-300}"             # seconds
GATEWAY_WAIT_TIMEOUT="${GATEWAY_WAIT_TIMEOUT:-120}"      # seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

METALLB_NS="${METALLB_NS:-metallb-system}"
METALLB_IP_RANGE="${METALLB_IP_RANGE:-}"

SKIP_AUTH=false
SKIP_LWS=false
SKIP_CERT_MANAGER=false
SKIP_METALLB=false
EXTRA_GATEWAY_NAMESPACES=()

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-auth)          SKIP_AUTH=true; shift ;;
      --skip-lws)           SKIP_LWS=true; shift ;;
      --skip-cert-manager)  SKIP_CERT_MANAGER=true; shift ;;
      --skip-metallb)       SKIP_METALLB=true; shift ;;
      --metallb-ip-range)
        if [[ $# -lt 2 ]]; then
          log_error "--metallb-ip-range requires a value (e.g. 192.168.130.99-192.168.130.99)"
          exit 1
        fi
        METALLB_IP_RANGE="$2"; shift 2 ;;
      --extra-gateway-namespace)
        EXTRA_GATEWAY_NAMESPACES+=("$2"); shift 2 ;;
      --help)
        cat <<'USAGE'
setup-llm-d.sh — Platform bootstrap for plain Distributed Inference with llm-d on RHOAI 3.4+
(NO Models-as-a-Service). Installs everything needed: LeaderWorkerSet operator, optionally
RHCL/Kuadrant/Authorino for Gateway authentication, the openshift-ai-inference Gateway, and
the model namespace.

Usage:
  ./setup-llm-d.sh [OPTIONS]

Options:
  --skip-auth                   Do NOT install RHCL/Kuadrant/Authorino. Every
                                 LLMInferenceService you deploy afterwards MUST then carry
                                 security.opendatahub.io/enable-auth: "false" (deploy-
                                 example-workload.sh does this automatically when it detects
                                 auth wasn't configured) — fine for a dev/test cluster, but
                                 the upstream doc explicitly says production deployments
                                 should not run this way.
  --skip-lws                    Skip LeaderWorkerSet operator install (use if already
                                 installed, or if you only ever deploy single-node models and
                                 are fine ignoring this prerequisite).
  --skip-cert-manager            Skip cert-manager install (LWS operator's own prerequisite) —
                                 use if already installed.
  --skip-metallb                 Skip MetalLB install (non-cloud platforms only; use if
                                 already installed, or a different LoadBalancer provider
                                 exists).
  --metallb-ip-range RANGE       Override the auto-derived MetalLB address pool (e.g.
                                 192.168.130.99-192.168.130.99). Default: first node's own
                                 InternalIP + 1 on the last octet (single address).
  --extra-gateway-namespace NS   Label an additional namespace
                                 llm-d.opendatahub.io/gateway-access=true (repeatable). The
                                 model namespace (llm-d-models) is always labeled.
  --help                         Show this message

Platform (cloud vs. non-cloud) is auto-detected via
`oc get infrastructure cluster -o jsonpath='{.status.platform}'` — never prompted for.

Environment variables (all optional, shown with defaults):
  RHOAI_OPERATOR_NS=redhat-ods-operator   RHOAI_APP_NS=redhat-ods-applications
  CERT_MANAGER_NS=cert-manager-operator   KUADRANT_NS=kuadrant-system
  LWS_NS=openshift-lws-operator           MODEL_NS=llm-d-models
  DSC_NAME=default-dsc                    METALLB_NS=metallb-system
  METALLB_IP_RANGE=<auto-derived>         OPERATOR_WAIT_TIMEOUT=600
  POD_WAIT_TIMEOUT=300                    GATEWAY_WAIT_TIMEOUT=120
USAGE
        exit 0 ;;
      *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

# ─── Steps ────────────────────────────────────────────────────────────────────

check_prerequisites() {
  log_step "Step 1: Checking prerequisites"

  if ! command -v oc &>/dev/null; then
    log_error "'oc' CLI not found. Install OpenShift CLI and retry."
    exit 1
  fi
  log_ok "oc CLI found: $(oc version --client 2>/dev/null | head -1)"

  if ! oc whoami &>/dev/null; then
    log_error "Not logged in to an OpenShift cluster. Run 'oc login …' first."
    exit 1
  fi
  log_ok "Logged in as: $(oc whoami) on $(oc whoami --show-server)"

  if ! oc auth can-i create clusterrole --all-namespaces &>/dev/null; then
    log_error "Current user does not have cluster-admin privileges."
    exit 1
  fi
  log_ok "cluster-admin privileges confirmed."

  local ocp_version
  ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
  if [[ -n "$ocp_version" ]]; then
    log_info "OpenShift version: ${ocp_version} (llm-d on RHOAI 3.4 requires >= 4.19.9 per the docs — not enforced here, informational only)."
  fi

  if oc get csv -A 2>/dev/null | grep -qi "servicemeshoperator\s.*v2\."; then
    log_error "OpenShift Service Mesh v2 appears to be installed — the llm-d docs require it NOT be present."
    log_error "Check: oc get csv -A | grep -i servicemeshoperator"
    exit 1
  fi
  log_ok "OpenShift Service Mesh v2 not detected."

  local rhoai_csv
  rhoai_csv=$(oc get csv -n "$RHOAI_OPERATOR_NS" 2>/dev/null \
    | awk '/rhods-operator/{print $1}' | head -1)
  if [[ -z "$rhoai_csv" ]]; then
    log_error "Red Hat OpenShift AI operator not found in namespace '${RHOAI_OPERATOR_NS}'."
    log_error "Install RHOAI before running this script."
    exit 1
  fi
  local rhoai_version
  rhoai_version=$(echo "$rhoai_csv" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  RHOAI_MAJOR=$(echo "$rhoai_version" | cut -d. -f1)
  RHOAI_MINOR=$(echo "$rhoai_version" | cut -d. -f2)
  log_ok "RHOAI operator found: ${rhoai_csv} (version ${rhoai_version})"

  if (( RHOAI_MAJOR < 3 || (RHOAI_MAJOR == 3 && RHOAI_MINOR < 4) )); then
    log_error "Distributed Inference with llm-d requires RHOAI >= 3.4 (found ${rhoai_version})."
    exit 1
  fi

  if ! resource_exists dsc "$DSC_NAME" "$RHOAI_OPERATOR_NS"; then
    log_error "DataScienceCluster '${DSC_NAME}' not found in '${RHOAI_OPERATOR_NS}'."
    exit 1
  fi
  log_ok "DataScienceCluster '${DSC_NAME}' exists."

  if [[ ! -d "$MANIFESTS_DIR" ]]; then
    log_error "Manifests directory not found: ${MANIFESTS_DIR}"
    exit 1
  fi
  log_ok "Manifests directory found."
}

install_cert_manager() {
  if [[ "$SKIP_CERT_MANAGER" == "true" ]]; then
    log_step "Step 2: Installing cert-manager operator (LWS operator prerequisite)"
    log_warn "--skip-cert-manager: skipping."
    return 0
  fi

  log_step "Step 2: Installing cert-manager operator (LWS operator prerequisite)"

  local phase
  phase=$(oc get csv -A 2>/dev/null | awk '/cert-manager-operator/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "cert-manager already installed and CSV is Succeeded — skipping."
    return 0
  fi
  [[ -n "$phase" ]] && log_warn "cert-manager CSV found but phase is '${phase}' — reinstalling."

  apply_manifest "${MANIFESTS_DIR}/01-cert-manager-namespace.yaml"
  apply_manifest "${MANIFESTS_DIR}/02-cert-manager-operatorgroup.yaml"
  apply_manifest "${MANIFESTS_DIR}/03-cert-manager-subscription.yaml"

  approve_installplan_for_sub "$CERT_MANAGER_NS" "openshift-cert-manager-operator"

  wait_for_csv "$CERT_MANAGER_NS" "cert-manager-operator" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "cert-manager CSV failed. Aborting."; exit 1; }

  wait_for_pods "cert-manager" "app.kubernetes.io/instance=cert-manager" "$POD_WAIT_TIMEOUT" \
    || { log_error "cert-manager pods not running. Aborting."; exit 1; }
  log_ok "cert-manager operator is ready."
}

install_lws_operator() {
  if [[ "$SKIP_LWS" == "true" ]]; then
    log_step "Step 3: Installing LeaderWorkerSet operator"
    log_warn "--skip-lws: skipping. Multi-node/disaggregated llm-d deployments will not work without it."
    return 0
  fi

  log_step "Step 3: Installing LeaderWorkerSet operator"

  local phase
  phase=$(oc get csv -n "$LWS_NS" 2>/dev/null | awk '/lws|leader-worker-set/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "LeaderWorkerSet operator already installed and CSV is Succeeded — skipping."
    return 0
  fi

  local pkg
  pkg=$(discover_olm_package 'leader-worker-set|lws-operator|^lws$')
  if [[ -z "$pkg" ]]; then
    log_error "Could not discover the LeaderWorkerSet operator's package name via"
    log_error "'oc get packagemanifest -n openshift-marketplace'. This operator may not be"
    log_error "mirrored into this cluster's catalog, or its naming differs from what this"
    log_error "script searches for (patterns tried: leader-worker-set, lws-operator, lws)."
    log_error "Check manually: oc get packagemanifest -n openshift-marketplace | grep -i lws"
    log_error "Then either install it yourself or re-run with --skip-lws."
    exit 1
  fi
  log_ok "Discovered LeaderWorkerSet operator package: '${pkg}'"

  apply_manifest "${MANIFESTS_DIR}/04-lws-namespace.yaml"
  sed "s|LWS_PACKAGE_NAME_PLACEHOLDER|${pkg}|g" \
    "${MANIFESTS_DIR}/05-lws-subscription.yaml.tmpl" | oc apply -f -

  approve_installplan_for_sub "$LWS_NS" "$pkg"
  wait_for_csv "$LWS_NS" "$pkg" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "LeaderWorkerSet operator CSV failed. Aborting."; exit 1; }
  log_ok "LeaderWorkerSet operator CSV is Succeeded."

  create_lws_singleton_if_needed
}

# Best-effort: some OpenShift layered operators need a singleton instance CR (named
# "cluster") created after the operator itself installs, in addition to its own CSV/pod
# being Running — this couldn't be confirmed for LWS specifically (see the file header), so
# this looks for a plausible operator-config CRD (excluding the upstream workload CRD,
# leaderworkersets.leaderworkerset.x-k8s.io, which is per-workload, not per-cluster) and
# creates a minimal instance only if exactly one unambiguous candidate exists.
create_lws_singleton_if_needed() {
  local candidate_crds
  candidate_crds=$(oc get crd -o name 2>/dev/null \
    | grep -i leaderworkerset | grep -v '^crd.*/leaderworkersets\.leaderworkerset\.x-k8s\.io$')
  if [[ -z "$candidate_crds" ]]; then
    log_info "No separate LeaderWorkerSet operator-config CRD found — assuming none is needed."
    return 0
  fi
  local count
  count=$(echo "$candidate_crds" | wc -l)
  if (( count != 1 )); then
    log_warn "Found ${count} candidate LeaderWorkerSet operator CRDs — not auto-creating an"
    log_warn "instance (ambiguous). Check manually and create one if the operator doesn't"
    log_warn "reconcile anything on its own:"
    echo "$candidate_crds"
    return 0
  fi

  local crd_name group kind version
  crd_name="${candidate_crds#crd.apiextensions.k8s.io/}"
  group=$(oc get crd "$crd_name" -o jsonpath='{.spec.group}' 2>/dev/null)
  kind=$(oc get crd "$crd_name" -o jsonpath='{.spec.names.kind}' 2>/dev/null)
  version=$(oc get crd "$crd_name" -o jsonpath='{.spec.versions[?(@.served==true)].name}' 2>/dev/null | awk '{print $1}')
  if [[ -z "$group" || -z "$kind" || -z "$version" ]]; then
    log_warn "Found CRD '${crd_name}' but couldn't resolve group/kind/version — skipping auto-create."
    return 0
  fi

  if resource_exists "${kind,,}.${group}" cluster; then
    log_ok "Singleton '${kind}/cluster' already exists — skipping."
    return 0
  fi

  log_info "Creating singleton '${kind}/cluster' (${group}/${version}) for the LeaderWorkerSet operator…"
  cat <<EOF | oc apply -f -
apiVersion: ${group}/${version}
kind: ${kind}
metadata:
  name: cluster
EOF
  log_ok "Singleton '${kind}/cluster' created."
}

install_rhcl_operator() {
  log_step "Step 4: Installing Red Hat Connectivity Link (RHCL) operator"

  local phase
  phase=$(oc get csv -n openshift-operators 2>/dev/null | awk '/rhcl/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "RHCL already installed and CSV is Succeeded — skipping."
    return 0
  fi
  [[ -n "$phase" ]] && log_warn "RHCL CSV found but phase is '${phase}' — reinstalling."

  apply_manifest "${MANIFESTS_DIR}/06-rhcl-subscription.yaml"
  approve_installplan_for_sub "openshift-operators" "rhcl-operator"
  wait_for_csv "openshift-operators" "rhcl-operator" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "RHCL CSV failed. Aborting."; exit 1; }
  log_ok "RHCL operator CSV is Succeeded."

  log_info "Waiting for Kuadrant CRD to be registered…"
  local crd_deadline=$(( $(date +%s) + 120 ))
  until oc get crd kuadrants.kuadrant.io &>/dev/null; do
    if (( $(date +%s) > crd_deadline )); then
      log_error "Kuadrant CRD not available after 120s. RHCL may not have installed correctly."
      oc get csv -n openshift-operators 2>/dev/null | grep -E "rhcl|kuadrant|authorino|limitador"
      exit 1
    fi
    sleep 5
  done
  log_ok "Kuadrant CRD is available."
}

configure_kuadrant_and_authorino() {
  log_step "Step 5: Configuring Kuadrant and a cluster-wide Authorino"

  apply_manifest "${MANIFESTS_DIR}/07-kuadrant-namespace.yaml"

  if resource_exists kuadrant kuadrant "$KUADRANT_NS"; then
    log_warn "Kuadrant CR already exists — skipping creation."
  else
    apply_manifest "${MANIFESTS_DIR}/08-kuadrant-cr.yaml"
  fi

  if ! wait_for_condition "kuadrant/kuadrant" "$KUADRANT_NS" "Ready" 120; then
    log_warn "Kuadrant not Ready after 120s — checking for MissingDependency (a known"
    log_warn "transient state fixed by restarting the operator pod once)…"
    local op_pod
    op_pod=$(oc get pods -n openshift-operators --no-headers 2>/dev/null \
      | awk '/kuadrant-operator/{print $1}' | head -1)
    if [[ -n "$op_pod" ]]; then
      log_info "Restarting kuadrant-operator pod '${op_pod}'…"
      oc delete pod -n openshift-operators "$op_pod" &>/dev/null || true
      wait_for_condition "kuadrant/kuadrant" "$KUADRANT_NS" "Ready" 180 \
        || { log_error "Kuadrant still not Ready after operator restart. Aborting."; exit 1; }
    else
      log_error "kuadrant-operator pod not found in openshift-operators. Aborting."
      exit 1
    fi
  fi
  log_ok "Kuadrant is Ready in '${KUADRANT_NS}'."

  apply_manifest "${MANIFESTS_DIR}/09-authorino-service-annotation.yaml"

  log_info "Waiting for Authorino TLS Secret to be issued by the service-ca operator…"
  local deadline=$(( $(date +%s) + 120 ))
  until oc get secret authorino-server-cert -n "$KUADRANT_NS" &>/dev/null; do
    if (( $(date +%s) > deadline )); then
      log_error "Authorino TLS Secret not issued after 120s."
      oc describe service authorino-authorino-authorization -n "$KUADRANT_NS" 2>/dev/null | tail -10
      exit 1
    fi
    sleep 5
  done
  log_ok "Authorino TLS Secret issued."
  sleep 2   # matches the doc's own procedure — lets the Secret fully propagate before Authorino reads it

  # Unlike the sibling maas-rhoai project (which lets Kuadrant auto-provision a namespace-
  # scoped Authorino and only patches its TLS config), RHOAI 3.4's llm-d docs explicitly
  # create this CR with clusterWide: true — llm-d models can land in any namespace, so
  # Authorino needs to watch the whole cluster, not just kuadrant-system.
  if resource_exists authorino authorino "$KUADRANT_NS"; then
    local already_cluster_wide
    already_cluster_wide=$(oc get authorino authorino -n "$KUADRANT_NS" \
      -o jsonpath='{.spec.clusterWide}' 2>/dev/null)
    if [[ "$already_cluster_wide" == "true" ]]; then
      log_warn "Authorino CR already exists and is clusterWide — skipping."
    else
      log_info "Authorino CR exists but clusterWide is '${already_cluster_wide:-unset}' — patching to true."
      oc patch authorino authorino -n "$KUADRANT_NS" --type=merge --patch '{
        "spec": {
          "clusterWide": true,
          "listener": {"tls": {"enabled": true, "certSecretRef": {"name": "authorino-server-cert"}}},
          "oidcServer": {"tls": {"enabled": false}}
        }
      }'
    fi
  else
    apply_manifest "${MANIFESTS_DIR}/10-authorino-cr.yaml"
  fi

  wait_for_pods "$KUADRANT_NS" "authorino-resource=authorino" "$POD_WAIT_TIMEOUT" \
    || { log_error "Authorino pod not Running. Aborting."; exit 1; }
  log_ok "Authorino is Running (cluster-wide, TLS enabled)."

  # Doc's own troubleshooting note: if OpenShift AI was installed before RHCL/Kuadrant, the
  # odh-model-controller and kserve-controller-manager pods may need a restart to pick up the
  # now-available AuthPolicy CRD. Cheap and idempotent — always run it rather than trying to
  # detect install order.
  log_info "Restarting odh-model-controller and kserve-controller-manager to pick up AuthPolicy CRD…"
  oc delete pod -n "$RHOAI_APP_NS" -l app=odh-model-controller &>/dev/null || true
  oc delete pod -n "$RHOAI_APP_NS" -l control-plane=kserve-controller-manager &>/dev/null || true
}

enable_kserve_in_dsc() {
  log_step "Step 6: Enabling the model serving platform (kserve) in the DataScienceCluster"

  local current_state
  current_state=$(oc get dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
    -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null)

  if [[ "$current_state" == "Managed" ]]; then
    log_ok "kserve is already Managed — skipping patch."
  else
    log_info "Current kserve.managementState: '${current_state:-unset}' → Managed"
    oc patch dsc "$DSC_NAME" -n "$RHOAI_OPERATOR_NS" \
      --type=merge \
      -p '{"spec":{"components":{"kserve":{"managementState":"Managed"}}}}'
  fi

  log_info "Waiting for DataScienceCluster to reconcile…"
  wait_for_condition "dsc/${DSC_NAME}" "$RHOAI_OPERATOR_NS" "Ready" "$OPERATOR_WAIT_TIMEOUT" \
    || log_warn "DSC Ready condition not confirmed — continuing (pod waits below will surface real failures)."

  wait_for_pods "$RHOAI_APP_NS" "control-plane=llmisvc-controller-manager" "$POD_WAIT_TIMEOUT" \
    || { log_error "llmisvc-controller-manager pod not Running. Aborting."; exit 1; }
  log_ok "llmisvc-controller-manager is Running in '${RHOAI_APP_NS}'."
}

install_metallb() {
  log_step "Step 7: Installing MetalLB (non-cloud platforms only)"

  local platform_class
  platform_class=$(detect_platform_class)
  if [[ "$platform_class" == "cloud" ]]; then
    log_ok "Cloud platform detected ($(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null)) — MetalLB not needed, skipping."
    return 0
  fi

  if [[ "$SKIP_METALLB" == "true" ]]; then
    log_warn "--skip-metallb: skipping MetalLB install. The Gateway's LoadBalancer Service"
    log_warn "will stay <pending> unless an equivalent LoadBalancer provider already exists."
    return 0
  fi

  local phase
  phase=$(oc get csv -n "$METALLB_NS" 2>/dev/null | awk '/metallb-operator/{print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "MetalLB operator already installed and CSV is Succeeded — skipping install."
  else
    [[ -n "$phase" ]] && log_warn "MetalLB operator CSV found but phase is '${phase}' — reinstalling."
    apply_manifest "${MANIFESTS_DIR}/15-metallb-namespace.yaml"
    approve_installplan_for_sub "$METALLB_NS" "metallb-operator"
    wait_for_csv "$METALLB_NS" "metallb-operator" "$OPERATOR_WAIT_TIMEOUT" \
      || { log_error "MetalLB operator CSV failed. Aborting."; exit 1; }
    log_ok "MetalLB operator CSV is Succeeded."
  fi

  if resource_exists deployment controller "$METALLB_NS"; then
    log_warn "MetalLB controller already deployed — skipping MetalLB CR creation."
  else
    apply_manifest "${MANIFESTS_DIR}/16-metallb-instance.yaml"
    wait_for_condition "deployment/controller" "$METALLB_NS" "Available" "$POD_WAIT_TIMEOUT" \
      || { log_error "MetalLB controller deployment did not become Available. Aborting."; exit 1; }
    log_ok "MetalLB controller is Available."
  fi

  if resource_exists ipaddresspool llm-d-gateway-pool "$METALLB_NS"; then
    log_warn "IPAddressPool 'llm-d-gateway-pool' already exists — skipping."
    return 0
  fi

  if [[ -z "$METALLB_IP_RANGE" ]]; then
    local node_ip
    node_ip=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [[ -z "$node_ip" ]]; then
      log_error "Could not determine a node InternalIP to derive a MetalLB address pool from."
      log_error "Pass --metallb-ip-range <range> explicitly."
      exit 1
    fi
    local derived_ip
    derived_ip=$(echo "$node_ip" | awk -F. '{printf "%s.%s.%s.%d", $1, $2, $3, $4+1}')
    METALLB_IP_RANGE="${derived_ip}-${derived_ip}"
    log_warn "No --metallb-ip-range given — auto-derived '${METALLB_IP_RANGE}' from node IP"
    log_warn "'${node_ip}' + 1. Confirm it's actually unused on your network before trusting"
    log_warn "this on anything but a simple single-node/CRC setup."
  else
    log_info "Using explicit MetalLB address range: ${METALLB_IP_RANGE}"
  fi

  sed "s|METALLB_IP_RANGE_PLACEHOLDER|${METALLB_IP_RANGE}|g" \
    "${MANIFESTS_DIR}/17-metallb-pool.yaml.tmpl" | oc apply -f -
  log_ok "MetalLB IPAddressPool + L2Advertisement created (${METALLB_IP_RANGE})."
}

install_gatewayclass() {
  log_step "Step 8: Installing the openshift-default GatewayClass"

  if resource_exists gatewayclass openshift-default; then
    log_warn "GatewayClass 'openshift-default' already exists — skipping."
  else
    apply_manifest "${MANIFESTS_DIR}/11-gatewayclass.yaml"
  fi

  wait_for_condition "gatewayclass/openshift-default" "$GATEWAY_NS" "Accepted" 120 \
    || { log_error "GatewayClass 'openshift-default' not Accepted. Aborting."; exit 1; }
  log_ok "GatewayClass 'openshift-default' is Accepted."
}

configure_gateway() {
  log_step "Step 9: Creating the '${GATEWAY_NAME}' Gateway"

  local platform_class
  platform_class=$(detect_platform_class)
  log_info "Cluster platform class: ${platform_class} ($(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null))"

  resource_exists configmap llm-d-gateway-options "$GATEWAY_NS" \
    || apply_manifest "${MANIFESTS_DIR}/12-gateway-resources-configmap.yaml"

  if resource_exists gateway "$GATEWAY_NAME" "$GATEWAY_NS"; then
    log_warn "Gateway '${GATEWAY_NAME}' already exists — skipping creation."
  else
    local cluster_domain cert_name
    cluster_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    cert_name=$(oc get ingresscontroller default -n openshift-ingress-operator \
      -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
    cert_name="${cert_name:-router-certs-default}"
    log_info "CLUSTER_DOMAIN=${cluster_domain}  CERT_NAME=${cert_name}"

    sed -e "s|CLUSTER_DOMAIN_PLACEHOLDER|${cluster_domain}|g" \
        -e "s|CERT_NAME_PLACEHOLDER|${cert_name}|g" \
      "${MANIFESTS_DIR}/13-gateway.yaml.tmpl" | oc apply -f -
  fi

  log_info "Waiting for Gateway '${GATEWAY_NAME}' to be Programmed (timeout: ${GATEWAY_WAIT_TIMEOUT}s)…"
  local deadline=$(( $(date +%s) + GATEWAY_WAIT_TIMEOUT ))
  until [[ "$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]]; do
    if (( $(date +%s) > deadline )); then
      log_error "Gateway '${GATEWAY_NAME}' not Programmed after ${GATEWAY_WAIT_TIMEOUT}s."
      if [[ "$platform_class" == "non-cloud" ]]; then
        log_error "Check the backing Service for a stuck <pending> LoadBalancer address:"
        log_error "  oc get svc -n ${GATEWAY_NS} -l gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}"
      fi
      oc describe gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" 2>/dev/null | tail -15
      exit 1
    fi
    sleep 5
  done
  log_ok "Gateway '${GATEWAY_NAME}' is Programmed."
}

label_gateway_namespaces() {
  log_step "Step 10: Labeling namespaces for Gateway route binding"

  apply_manifest "${MANIFESTS_DIR}/18-model-namespace.yaml"
  log_ok "Namespace '${MODEL_NS}' created/labeled llm-d.opendatahub.io/gateway-access=true."

  if (( ${#EXTRA_GATEWAY_NAMESPACES[@]} > 0 )); then
    for ns in "${EXTRA_GATEWAY_NAMESPACES[@]}"; do
      oc label namespace "$ns" llm-d.opendatahub.io/gateway-access="true" --overwrite &>/dev/null
      log_ok "Namespace '${ns}' labeled llm-d.opendatahub.io/gateway-access=true."
    done
  fi
}

create_passthrough_route() {
  local platform_class
  platform_class=$(detect_platform_class)
  if [[ "$platform_class" != "non-cloud" ]]; then
    log_step "Step 11: Passthrough Route (skipped — cloud platform, Gateway has a direct LoadBalancer address)"
    return 0
  fi

  log_step "Step 11: Creating passthrough Route (non-cloud platform)"

  if resource_exists route "${GATEWAY_NAME}-https" "$GATEWAY_NS"; then
    log_warn "Route '${GATEWAY_NAME}-https' already exists — skipping."
  else
    local cluster_domain
    cluster_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    sed "s|CLUSTER_DOMAIN_PLACEHOLDER|${cluster_domain}|g" \
      "${MANIFESTS_DIR}/14-route.yaml.tmpl" | oc apply -f -
  fi

  log_info "Waiting for Route '${GATEWAY_NAME}-https' to be admitted…"
  local deadline=$(( $(date +%s) + 60 ))
  until [[ "$(oc get route "${GATEWAY_NAME}-https" -n "$GATEWAY_NS" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null)" == "True" ]]; do
    if (( $(date +%s) > deadline )); then
      log_error "Route '${GATEWAY_NAME}-https' not admitted after 60s."
      oc describe route "${GATEWAY_NAME}-https" -n "$GATEWAY_NS" 2>/dev/null | tail -15
      exit 1
    fi
    sleep 5
  done
  log_ok "Route '${GATEWAY_NAME}-https' admitted."
}

print_summary() {
  log_step "llm-d platform setup — Summary"

  local apps_domain inference_host
  apps_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "<apps-domain>")
  inference_host="inference.${apps_domain}"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║        Distributed Inference with llm-d — Platform Ready      ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  Gateway        ${GATEWAY_NAME}.${GATEWAY_NS} → https://${inference_host}"
  echo -e "  Model namespace ${MODEL_NS}"
  if [[ "$SKIP_AUTH" == "true" ]]; then
    echo -e "  Auth           ${YELLOW}skipped (--skip-auth)${NC} — deploy every LLMInferenceService with"
    echo -e "                 security.opendatahub.io/enable-auth: \"false\""
  else
    echo -e "  Auth           RHCL/Kuadrant/Authorino configured, cluster-wide"
  fi
  echo
  echo -e "  ${BOLD}Next step:${NC} ./deploy-example-workload.sh"
  echo
  echo -e "  Re-run this script any time to reapply the platform (all steps are idempotent)."
  echo -e "  To remove it: ./teardown-llm-d.sh"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║     RHOAI 3.4+ Distributed Inference with llm-d — Setup       ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites
  install_cert_manager
  install_lws_operator
  if [[ "$SKIP_AUTH" == "true" ]]; then
    log_step "Steps 4-5: RHCL/Kuadrant/Authorino (skipped — --skip-auth)"
  else
    install_rhcl_operator
    configure_kuadrant_and_authorino
  fi
  enable_kserve_in_dsc
  install_metallb
  install_gatewayclass
  configure_gateway
  label_gateway_namespaces
  create_passthrough_route
  print_summary
}

main "$@"
