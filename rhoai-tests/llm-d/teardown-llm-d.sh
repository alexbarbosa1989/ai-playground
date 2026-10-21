#!/usr/bin/env bash
# teardown-llm-d.sh
# Removes all resources created by setup-llm-d.sh and deploy-example-workload.sh.
#
# Usage:
#   ./teardown-llm-d.sh [--full] [--remove-observability] [--yes]
#
# Options:
#   --full                    Also uninstall cert-manager, LWS, RHCL/Kuadrant operators, the
#                              openshift-default GatewayClass, and MetalLB
#   --remove-observability    Also undo setup-observability.sh: revert the DSCI's
#                              monitoring.managementState to Removed, and uninstall the
#                              Cluster Observability Operator, Red Hat build of OpenTelemetry,
#                              and Tempo operators. NOT part of --full, and not on by default —
#                              these are cluster-wide and may be relied on by other workloads
#                              (MaaS dashboards, other model-serving projects, etc.) on a
#                              shared cluster, same reasoning as kserve's managementState below.
#   --yes                     Skip the confirmation prompt
#   --help                    Show this message

set -uo pipefail

# ─── Configuration (must match setup-llm-d.sh / setup-observability.sh) ───────
RHOAI_OPERATOR_NS="${RHOAI_OPERATOR_NS:-redhat-ods-operator}"
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
CERT_MANAGER_NS="${CERT_MANAGER_NS:-cert-manager-operator}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
LWS_NS="${LWS_NS:-openshift-lws-operator}"
MODEL_NS="${MODEL_NS:-llm-d-models}"
DSC_NAME="${DSC_NAME:-default-dsc}"
DSCI_NAME="${DSCI_NAME:-default-dsci}"
COO_NS="${COO_NS:-openshift-cluster-observability-operator}"
OTEL_NS="${OTEL_NS:-openshift-opentelemetry-operator}"
TEMPO_NS="${TEMPO_NS:-openshift-tempo-operator}"
GATEWAY_NS="openshift-ingress"
GATEWAY_NAME="openshift-ai-inference"

FULL=false
REMOVE_OBSERVABILITY=false
YES=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --full)                  FULL=true ;;
      --remove-observability)  REMOVE_OBSERVABILITY=true ;;
      --yes)                   YES=true ;;
      --help)
        cat <<'USAGE'
teardown-llm-d.sh — Removes all resources created by setup-llm-d.sh and
deploy-example-workload.sh.

Usage:
  ./teardown-llm-d.sh [--full] [--remove-observability] [--yes]

Options:
  --full                   Also uninstall cert-manager, LeaderWorkerSet, and RHCL/Kuadrant
                            operators, the openshift-default GatewayClass, and MetalLB
                            (Subscriptions, CSVs, OperatorGroups, namespaces)
  --remove-observability   Also undo setup-observability.sh: revert the DSCI's
                            monitoring.managementState to Removed, and uninstall the Cluster
                            Observability Operator, Red Hat build of OpenTelemetry, and Tempo
                            operators. Independent of --full — pass it explicitly even with
                            --full if you want the observability stack gone too.
  --yes                    Skip the confirmation prompt
  --help                   Show this message

Without --full the following are removed:
  - All LLMInferenceService resources in the model namespace
  - Namespace llm-d-models (this also removes any PodMonitor/ServiceMonitor living in it,
    including the Ch 6.3 canary PodMonitor setup-observability.sh may have applied)
  - kserve managementState left as-is (NOT reverted — likely shared with other, non-llm-d
    model-serving workloads on this cluster; revert manually if you're sure nothing else
    depends on it: oc patch dsc <name> --type=merge -p
    '{"spec":{"components":{"kserve":{"managementState":"Removed"}}}}')
  - Authorino clusterWide/TLS config reverted (CR left in place — may be relied on by other
    Kuadrant consumers on this cluster)
  - Kuadrant CR deleted
  - Gateway openshift-ai-inference, its Route (openshift-ai-inference-https), and its
    ConfigMap (llm-d-gateway-options), all in openshift-ingress

Only with --full:
  - cert-manager, LeaderWorkerSet, and RHCL/Kuadrant operators
  - openshift-default GatewayClass
  - MetalLB (IPAddressPool/L2Advertisement, MetalLB CR, operator) — harmless no-op on cloud
    platforms, where it was never installed

Only with --remove-observability:
  - DSCI monitoring.managementState reverted to Removed (User Workload Monitoring itself is
    left ON — too broadly relied upon cluster-wide to safely auto-disable; see
    setup-observability.sh's own comments)
  - Cluster Observability Operator, Red Hat build of OpenTelemetry, and Tempo operators
    uninstalled

Not removed in any mode:
  - RHOAI operator and DataScienceCluster/DSCInitialization (pre-existing)
  - User Workload Monitoring enablement (cluster-monitoring-config ConfigMap) — too broadly
    shared to auto-revert; disable manually if you're sure nothing else on the cluster needs it
  - kuadrant-system / openshift-lws-operator namespaces' shared operands if other workloads
    on this cluster still reference them (see per-step warnings above)
USAGE
        exit 0 ;;
      *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
  done
}

# ─── Confirmation ─────────────────────────────────────────────────────────────
confirm() {
  if [[ "$YES" == "true" ]]; then return 0; fi
  echo
  echo -e "${YELLOW}${BOLD}WARNING: This will permanently delete llm-d resources.${NC}"
  echo -e "  Cluster : $(oc whoami --show-server 2>/dev/null || echo '<unknown>')"
  echo -e "  User    : $(oc whoami 2>/dev/null || echo '<unknown>')"
  if [[ "$FULL" == "true" ]]; then
    echo -e "  ${RED}--full: cert-manager, LWS, RHCL, GatewayClass, and MetalLB will also be uninstalled.${NC}"
  fi
  if [[ "$REMOVE_OBSERVABILITY" == "true" ]]; then
    echo -e "  ${RED}--remove-observability: DSCI monitoring reverted; COO/OpenTelemetry/Tempo uninstalled.${NC}"
  fi
  echo
  read -rp "Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || { echo "Aborted."; exit 0; }
}

# ─── Teardown steps ───────────────────────────────────────────────────────────

delete_model_workloads() {
  log_step "Deleting model workloads in '${MODEL_NS}'"
  if ! oc get namespace "$MODEL_NS" &>/dev/null; then
    log_warn "Namespace '${MODEL_NS}' not found — skipping."
    return 0
  fi
  oc delete llminferenceservice --all -n "$MODEL_NS" --ignore-not-found 2>/dev/null || true

  log_info "Waiting 15 s for controller to clean up dependent resources (HTTPRoutes, certs)…"
  sleep 15
  oc delete namespace "$MODEL_NS" --ignore-not-found 2>/dev/null || true
  log_ok "Namespace '${MODEL_NS}' deleted."
}

revert_authorino_and_kuadrant() {
  log_step "Reverting Authorino cluster-wide/TLS config and deleting Kuadrant CR"
  if oc get authorino authorino -n "$KUADRANT_NS" &>/dev/null; then
    oc patch authorino authorino -n "$KUADRANT_NS" --type=merge \
      -p '{"spec":{"clusterWide":false,"listener":{"tls":{"enabled":false,"certSecretRef":null}}}}' \
      2>/dev/null || log_warn "Could not patch Authorino — check manually."
    log_ok "Authorino clusterWide/TLS reverted (CR left in place)."
  else
    log_warn "Authorino CR not found — skipping."
  fi
  oc annotate svc authorino-authorino-authorization -n "$KUADRANT_NS" \
    service.beta.openshift.io/serving-cert-secret-name- 2>/dev/null || true
  oc delete secret authorino-server-cert -n "$KUADRANT_NS" --ignore-not-found 2>/dev/null || true
  oc delete kuadrant kuadrant -n "$KUADRANT_NS" --ignore-not-found 2>/dev/null || true
  log_ok "Kuadrant CR deleted."
}

delete_gateway() {
  log_step "Deleting the '${GATEWAY_NAME}' Gateway"
  oc delete route "${GATEWAY_NAME}-https" -n "$GATEWAY_NS" --ignore-not-found 2>/dev/null || true
  oc delete gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" --ignore-not-found 2>/dev/null || true
  oc delete configmap llm-d-gateway-options -n "$GATEWAY_NS" --ignore-not-found 2>/dev/null || true
  log_ok "Gateway '${GATEWAY_NAME}' and its Route/ConfigMap deleted."
}

delete_gatewayclass() {
  log_step "Removing openshift-default GatewayClass"
  oc delete gatewayclass openshift-default --ignore-not-found 2>/dev/null || true
  log_ok "GatewayClass 'openshift-default' removed."
}

delete_metallb() {
  log_step "Removing MetalLB (non-cloud platforms only — no-op if never installed)"
  oc delete l2advertisement llm-d-gateway-pool -n metallb-system --ignore-not-found 2>/dev/null || true
  oc delete ipaddresspool llm-d-gateway-pool -n metallb-system --ignore-not-found 2>/dev/null || true
  oc delete metallb metallb -n metallb-system --ignore-not-found 2>/dev/null || true
  local csv
  csv=$(oc get csv -n metallb-system 2>/dev/null | awk '/metallb-operator/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n metallb-system --ignore-not-found 2>/dev/null || true
  oc delete subscription metallb-operator -n metallb-system --ignore-not-found 2>/dev/null || true
  oc delete namespace metallb-system --ignore-not-found 2>/dev/null || true
  log_ok "MetalLB removed."
}

delete_rhcl() {
  log_step "Removing RHCL/Kuadrant operator"
  local csv
  csv=$(oc get csv -n openshift-operators 2>/dev/null | awk '/rhcl/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n openshift-operators --ignore-not-found 2>/dev/null || true
  oc delete subscription rhcl-operator -n openshift-operators --ignore-not-found 2>/dev/null || true
  oc delete namespace "$KUADRANT_NS" --ignore-not-found 2>/dev/null || true
  log_ok "RHCL/Kuadrant operator removed."
}

delete_lws() {
  log_step "Removing LeaderWorkerSet operator"
  local csv
  csv=$(oc get csv -n "$LWS_NS" 2>/dev/null | awk '/lws|leader-worker-set/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n "$LWS_NS" --ignore-not-found 2>/dev/null || true
  oc get subscription -n "$LWS_NS" -o name 2>/dev/null | xargs -r -n1 oc delete -n "$LWS_NS" --ignore-not-found 2>/dev/null || true
  oc delete namespace "$LWS_NS" --ignore-not-found 2>/dev/null || true
  log_ok "LeaderWorkerSet operator removed."
}

delete_cert_manager() {
  log_step "Removing cert-manager operator"
  local csv
  csv=$(oc get csv -n "$CERT_MANAGER_NS" 2>/dev/null | awk '/cert-manager/{print $1}' | head -1)
  [[ -n "$csv" ]] && oc delete csv "$csv" -n "$CERT_MANAGER_NS" --ignore-not-found 2>/dev/null || true
  oc delete subscription openshift-cert-manager-operator -n "$CERT_MANAGER_NS" --ignore-not-found 2>/dev/null || true
  oc delete operatorgroup -n "$CERT_MANAGER_NS" --all --ignore-not-found 2>/dev/null || true
  oc delete namespace "$CERT_MANAGER_NS" --ignore-not-found 2>/dev/null || true
  log_ok "cert-manager operator removed."
}

delete_observability() {
  log_step "Reverting DSCI monitoring and removing COO/OpenTelemetry/Tempo operators"

  if oc get dscinitialization "$DSCI_NAME" &>/dev/null; then
    oc patch dscinitialization "$DSCI_NAME" --type=merge \
      -p '{"spec":{"monitoring":{"managementState":"Removed"}}}' 2>/dev/null \
      || log_warn "Could not patch DSCI '${DSCI_NAME}' — check manually."
    log_ok "DSCI '${DSCI_NAME}' monitoring.managementState reverted to Removed."
  else
    log_warn "DSCI '${DSCI_NAME}' not found — skipping."
  fi

  # CSV display names don't always match the Subscription package name (confirmed live:
  # package "opentelemetry-product"/"tempo-product" install CSVs named
  # "opentelemetry-operator.vX"/"tempo-operator.vX") — match on CSV name, not package name.
  local ns csv_pattern
  for entry in "${COO_NS}:cluster-observability-operator" "${OTEL_NS}:opentelemetry-operator" "${TEMPO_NS}:tempo-operator"; do
    ns="${entry%%:*}"
    csv_pattern="${entry##*:}"
    local csv
    csv=$(oc get csv -n "$ns" 2>/dev/null | awk -v p="$csv_pattern" '$1 ~ p {print $1}' | head -1)
    [[ -n "$csv" ]] && oc delete csv "$csv" -n "$ns" --ignore-not-found 2>/dev/null || true
    oc get subscription -n "$ns" -o name 2>/dev/null | xargs -r -n1 oc delete -n "$ns" --ignore-not-found 2>/dev/null || true
    oc delete namespace "$ns" --ignore-not-found 2>/dev/null || true
  done
  log_ok "COO, OpenTelemetry, and Tempo operators removed."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║          Distributed Inference with llm-d — Teardown          ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

  confirm

  delete_model_workloads
  revert_authorino_and_kuadrant
  delete_gateway

  if [[ "$FULL" == "true" ]]; then
    delete_cert_manager
    delete_lws
    delete_rhcl
    delete_gatewayclass
    delete_metallb
  fi

  if [[ "$REMOVE_OBSERVABILITY" == "true" ]]; then
    delete_observability
  fi

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║                    Teardown complete                          ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  if [[ "$FULL" != "true" ]]; then
    log_info "cert-manager, LWS, and RHCL operators were left in place (pass --full to remove them)."
  fi
  if [[ "$REMOVE_OBSERVABILITY" != "true" ]]; then
    log_info "Observability stack (COO/OpenTelemetry/Tempo, DSCI monitoring) was left in place"
    log_info "(pass --remove-observability to remove it)."
  fi
  log_warn "kserve managementState in the DataScienceCluster was NOT reverted — see --help for why."
}

main "$@"
