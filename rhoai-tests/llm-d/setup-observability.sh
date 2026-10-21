#!/usr/bin/env bash
# setup-observability.sh
# Configures observability for Distributed Inference with llm-d, per RHOAI 3.5's doc:
#   https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html-single/deploy_models_using_distributed_inference_with_llm-d/index
#   (the html-single page truncates before reaching it — the real content was read from the
#   per-chapter page: .../html/deploy_models_using_distributed_inference_with_llm-d/monitoring-llmd-deployments
#   = Chapter 17, "Monitor llm-d deployments")
# plus the Managing OpenShift AI guide's Ch 12 ("Enable the observability stack" /
# "Enable the observability dashboards"), which Ch 17.4's own prerequisites link out to and
# which turned out to hold the step that actually renders the dashboards (see step 5 below).
#
# Sibling of setup-llm-d.sh / deploy-example-workload.sh — run this AFTER you already have a
# working llm-d platform + at least one deployed LLMInferenceService.
#
# EVERY STEP BELOW WAS RUN LIVE AGAINST THIS PROJECT'S OWN CRC CLUSTER (RHOAI 3.5.1) BEFORE
# being written here — nothing in this script is guessed from the doc text alone:
#
#   1. User Workload Monitoring (UWM). Doc Ch 17.2 prerequisite: "On OpenShift, enable user
#      workload monitoring." CONFIRMED: UWM was NOT enabled on this cluster (no
#      `cluster-monitoring-config` ConfigMap, no `openshift-user-workload-monitoring` pods) —
#      and without it, the PodMonitor/ServiceMonitor the KServe controller auto-creates for
#      every LLMInferenceService (step 2) scrape NOTHING, because platform Prometheus only
#      scrapes namespaces explicitly labeled `openshift.io/cluster-monitoring: "true"`
#      (confirmed: that's exactly why DCGM/GPU metrics already worked without UWM — the
#      `nvidia-gpu-operator` namespace carries that label; `llm-d-models` does not, and
#      shouldn't — UWM is the doc-sanctioned mechanism for a regular workload namespace).
#
#   2. Verifying the controller-created PodMonitor/ServiceMonitor. Doc Ch 17.2: "On OpenShift,
#      the controller automatically creates PodMonitor and ServiceMonitor resources… when you
#      deploy an LLMInferenceService." CONFIRMED: `kserve-llm-isvc-vllm-engine*` (PodMonitor)
#      and `kserve-llm-isvc-scheduler*` (ServiceMonitor) already exist in the model namespace —
#      nothing to create here, this step only verifies they're present.
#
#   3. The Ch 6.3 canary PodMonitor (`llm_isvc_name` relabeling, for comparing metrics across
#      LLMInferenceService versions during a controlled/canary deployment). CONFIRMED: on
#      RHOAI 3.5.1 the controller-created PodMonitor from step 2 ALREADY contains this exact
#      relabeling rule, making the doc's manual Ch 6.3 PodMonitor redundant on this version —
#      applying it as well would double-scrape the same pods. This step checks live and only
#      applies manifests/25-canary-podmonitor.yaml.tmpl if the relabeling is actually missing.
#
#   4. Three OLM operators: Cluster Observability Operator (COO), Red Hat build of
#      OpenTelemetry, and Tempo. Doc Ch 17.3/17.4 only mentions COO ("You must install COO
#      manually from OperatorHub"), but CONFIRMED LIVE that installing COO alone is NOT
#      enough — see step 5.
#
#   5. Enabling the RHOAI monitoring stack on the DSCInitialization CR. This is the step the
#      llm-d doc doesn't itself describe (it just links to "Enable the observability dashboard
#      in the UI" in the Managing OpenShift AI guide) and is the one actually missing on a
#      freshly-installed cluster. CONFIRMED LIVE, step by step:
#        a. Even with COO installed, the cluster's `Monitoring` platform resource
#           (`default-monitoring`, group services.platform.opendatahub.io) hard-failed its
#           precondition check: "OpenTelemetryCollector operator must be installed for
#           OpenTelemetry configuration" — a blanket precondition that blocks EVERY downstream
#           condition (MonitoringStackAvailable, PersesAvailable, ThanosQuerierAvailable, …)
#           even though this script never configures tracing. This is why step 4 installs the
#           OpenTelemetry and Tempo operators too, matching the Managing OpenShift AI guide's
#           Ch 12.1 prerequisite list ("Cluster Observability Operator, Tempo Operator, Red Hat
#           build of OpenTelemetry") — even for the dashboards-only path, not just tracing.
#        b. Even after those operators were installed, the DSCInitialization's
#           `spec.monitoring` was already `managementState: Managed` but with an EMPTY
#           `metrics: {}` — and the `Monitoring` resource stayed stuck on
#           `MonitoringStackAvailable=False, reason=MetricsNotConfigured`. Patching in
#           `metrics.storage.size` + `metrics.storage.retention` (marked "Required" in the
#           Managing OpenShift AI guide's own example) is what actually triggers
#           provisioning.
#        c. After that patch, RHOAI's own `Monitoring` controller created a `MonitoringStack`
#           (Prometheus/Alertmanager/Thanos querier) AND a `Perses` CR + its server pod
#           (`*-perses-0` in the monitoring namespace, label `app.kubernetes.io/managed-by=
#           perses-operator`) — which is what actually renders the "LLM Traffic" / "LLM
#           Performance" / "LLM Utilization" dashboards the llm-d doc describes. RHOAI's
#           dashboard-operator had ALREADY created the `PersesDashboard` CRs for these three
#           dashboards ahead of time (confirmed: they existed before step 5b, just with
#           nowhere to render) — so nothing further is needed once the Perses server is up.
#
#   6. A PromQL smoke test (via the in-cluster Thanos querier, authenticated with the current
#      oc session's own token) for `vllm:...` and `llm_d_epp_...` metrics in the model
#      namespace — confirming the whole pipeline (UWM → PodMonitor/ServiceMonitor →
#      Prometheus → Thanos) works end to end, not just that the right objects exist.
#
# NOT automated (genuinely out of scope, not a doc gap):
#   - Distributed tracing itself (Ch 17.12) — this script installs OTel + Tempo only because
#     they're a hard precondition for the dashboards (see 5a); it does NOT configure
#     `spec.monitoring.traces` or `spec.monitoring.alerting` on the DSCI, so
#     TempoAvailable/AlertingAvailable/InstrumentationAvailable stay False — expected, not a
#     bug. Configure those yourself if you actually want tracing/alerting.
#   - Deploying Grafana itself (Ch 17.7: "Grafana is not included with OpenShift. You must
#     deploy Grafana separately") — this script only offers to download the dashboard JSON
#     files so they're ready to import once you have a Grafana instance.
#
# Usage:
#   ./setup-observability.sh [--skip-uwm] [--skip-dashboards] [--download-grafana-dashboards] [--help]

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
MODEL_NS="${MODEL_NS:-llm-d-models}"
COO_NS="${COO_NS:-openshift-cluster-observability-operator}"
OTEL_NS="${OTEL_NS:-openshift-opentelemetry-operator}"
TEMPO_NS="${TEMPO_NS:-openshift-tempo-operator}"

DSCI_NAME="${DSCI_NAME:-default-dsci}"
RHOAI_MONITORING_NS="${RHOAI_MONITORING_NS:-redhat-ods-monitoring}"
METRICS_STORAGE_SIZE="${METRICS_STORAGE_SIZE:-5Gi}"
METRICS_STORAGE_RETENTION="${METRICS_STORAGE_RETENTION:-90d}"

OPERATOR_WAIT_TIMEOUT="${OPERATOR_WAIT_TIMEOUT:-600}"   # seconds
POD_WAIT_TIMEOUT="${POD_WAIT_TIMEOUT:-300}"             # seconds
METRICS_WAIT_TIMEOUT="${METRICS_WAIT_TIMEOUT:-90}"      # seconds — doc: "may take up to 60s"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
GRAFANA_DASHBOARDS_DIR="${SCRIPT_DIR}/grafana-dashboards"

SKIP_UWM=false
SKIP_DASHBOARDS=false
DOWNLOAD_GRAFANA=false

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-uwm)                     SKIP_UWM=true; shift ;;
      --skip-dashboards)              SKIP_DASHBOARDS=true; shift ;;
      --download-grafana-dashboards)  DOWNLOAD_GRAFANA=true; shift ;;
      --help)
        cat <<'USAGE'
setup-observability.sh — Configures observability for Distributed Inference with llm-d,
per RHOAI 3.5 doc Chapter 17 ("Monitor llm-d deployments") + Chapter 6.3 (per-version
canary metrics) + the Managing OpenShift AI guide's Ch 12 (observability stack/dashboards).
Run this AFTER setup-llm-d.sh + deploy-example-workload.sh.

Usage:
  ./setup-observability.sh [OPTIONS]

Options:
  --skip-uwm                      Skip enabling User Workload Monitoring (use if already
                                   enabled, or managed outside this script).
  --skip-dashboards                Skip installing COO/OpenTelemetry/Tempo and patching the
                                    DSCI's monitoring stack (use if already configured, or you
                                    only want Prometheus metrics without the built-in Perses
                                    dashboards).
  --download-grafana-dashboards   Download the community Grafana dashboard JSON files (Ch
                                   17.7) into ./grafana-dashboards/, ready to import once you
                                   have a Grafana instance. Grafana itself is NOT installed by
                                   this script (the doc: "Grafana is not included with
                                   OpenShift. You must deploy Grafana separately").
  --help                          Show this message

Environment variables (all optional, shown with defaults):
  MODEL_NS=llm-d-models              DSCI_NAME=default-dsci
  RHOAI_MONITORING_NS=redhat-ods-monitoring
  METRICS_STORAGE_SIZE=5Gi           METRICS_STORAGE_RETENTION=90d
  OPERATOR_WAIT_TIMEOUT=600          POD_WAIT_TIMEOUT=300       METRICS_WAIT_TIMEOUT=90
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
  if ! oc whoami &>/dev/null; then
    log_error "Not logged in to an OpenShift cluster. Run 'oc login …' first."
    exit 1
  fi
  log_ok "Logged in as: $(oc whoami) on $(oc whoami --show-server)"

  if ! oc auth can-i create clusterrole --all-namespaces &>/dev/null; then
    log_error "Current user does not have cluster-admin privileges (needed for UWM + operator installs)."
    exit 1
  fi
  log_ok "cluster-admin privileges confirmed."

  if ! resource_exists namespace "$MODEL_NS"; then
    log_error "Model namespace '${MODEL_NS}' not found. Run setup-llm-d.sh first."
    exit 1
  fi

  local isvc_count
  isvc_count=$(oc get llminferenceservice -n "$MODEL_NS" --no-headers 2>/dev/null | wc -l)
  if (( isvc_count == 0 )); then
    log_warn "No LLMInferenceService found in '${MODEL_NS}' yet. The controller only creates"
    log_warn "PodMonitor/ServiceMonitor resources once a model is deployed — this script will"
    log_warn "still enable UWM + dashboards, but the verify/smoke-test steps below will show"
    log_warn "nothing until you run deploy-example-workload.sh."
  else
    log_ok "${isvc_count} LLMInferenceService(s) found in '${MODEL_NS}'."
  fi
}

enable_user_workload_monitoring() {
  if [[ "$SKIP_UWM" == "true" ]]; then
    log_step "Step 2: Enabling User Workload Monitoring"
    log_warn "--skip-uwm: skipping."
    return 0
  fi

  log_step "Step 2: Enabling User Workload Monitoring"

  if ! resource_exists configmap cluster-monitoring-config openshift-monitoring; then
    log_info "No 'cluster-monitoring-config' ConfigMap found — creating it with enableUserWorkload: true."
    cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    log_ok "'cluster-monitoring-config' created."
  else
    local current
    current=$(oc get configmap cluster-monitoring-config -n openshift-monitoring \
      -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
    if echo "$current" | grep -q "enableUserWorkload:[[:space:]]*true"; then
      log_ok "'cluster-monitoring-config' already has enableUserWorkload: true — skipping."
    else
      log_warn "'cluster-monitoring-config' already exists but doesn't clearly set"
      log_warn "enableUserWorkload: true — NOT overwriting it automatically (it may hold"
      log_warn "other cluster-wide monitoring settings this script shouldn't touch)."
      log_warn "Current content:"
      echo "$current" | sed 's/^/    /'
      log_warn "Add 'enableUserWorkload: true' to its config.yaml yourself, then re-run."
      return 0
    fi
  fi

  wait_for_pods "openshift-user-workload-monitoring" "app.kubernetes.io/name=prometheus" "$POD_WAIT_TIMEOUT" \
    || { log_error "User workload Prometheus did not come up. Aborting."; exit 1; }
  log_ok "User Workload Monitoring is running."
}

verify_llm_d_monitor_resources() {
  log_step "Step 3: Verifying controller-created PodMonitor/ServiceMonitor + canary relabeling"

  local podmonitors servicemonitors
  podmonitors=$(oc get podmonitors -n "$MODEL_NS" -l app.kubernetes.io/component=llm-monitoring -o name 2>/dev/null)
  servicemonitors=$(oc get servicemonitors -n "$MODEL_NS" -l app.kubernetes.io/component=llm-monitoring -o name 2>/dev/null)

  if [[ -z "$podmonitors" ]]; then
    log_warn "No controller-created PodMonitor found in '${MODEL_NS}' yet (expected once a model is deployed)."
  else
    log_ok "vLLM engine PodMonitor(s): $(echo "$podmonitors" | tr '\n' ' ')"
  fi
  if [[ -z "$servicemonitors" ]]; then
    log_warn "No controller-created ServiceMonitor found in '${MODEL_NS}' yet (expected once a model is deployed)."
  else
    log_ok "Inference scheduler ServiceMonitor(s): $(echo "$servicemonitors" | tr '\n' ' ')"
  fi

  if [[ -z "$podmonitors" ]]; then
    log_warn "Skipping canary-relabeling check (no PodMonitor to inspect)."
    return 0
  fi

  local first_pm has_relabel
  first_pm="${podmonitors%%$'\n'*}"
  has_relabel=$(oc get "$first_pm" -n "$MODEL_NS" -o json 2>/dev/null \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ep in d.get('spec', {}).get('podMetricsEndpoints', []):
    for r in ep.get('relabelings', []):
        if r.get('targetLabel') == 'llm_isvc_name':
            print('yes'); sys.exit(0)
print('no')
" 2>/dev/null)

  if [[ "$has_relabel" == "yes" ]]; then
    log_ok "Controller-created PodMonitor already injects 'llm_isvc_name' — per-version canary"
    log_ok "metrics (Ch 6.3) work out of the box. NOT applying the doc's separate manual"
    log_ok "PodMonitor (manifests/25-canary-podmonitor.yaml.tmpl) — it would be redundant and"
    log_ok "double-scrape the same pods."
  else
    log_warn "Controller-created PodMonitor does NOT inject 'llm_isvc_name' — applying the"
    log_warn "doc's Ch 6.3 manual PodMonitor as a supplement."
    sed "s|MODEL_NS_PLACEHOLDER|${MODEL_NS}|g" \
      "${MANIFESTS_DIR}/25-canary-podmonitor.yaml.tmpl" | oc apply -f -
    log_ok "Canary PodMonitor 'llmisvc-vllm' applied in '${MODEL_NS}'."
  fi
}

# install_namespaced_operator NS PKG_SEARCH_PATTERN CSV_MATCH_PATTERN
# Generic AllNamespaces OLM install, reused for COO/OpenTelemetry/Tempo. PKG_SEARCH_PATTERN is
# passed to discover_olm_package (regex over packagemanifest names). CSV_MATCH_PATTERN is a
# SEPARATE regex used only to check the installed CSV's phase — CONFIRMED LIVE these two can
# differ: package "opentelemetry-product" installs CSV "opentelemetry-operator.vX.Y.Z", and
# package "tempo-product" installs CSV "tempo-operator.vX.Y.Z".
install_namespaced_operator() {
  local ns="$1" pkg_pattern="$2" csv_match="$3"

  local phase
  phase=$(oc get csv -n "$ns" 2>/dev/null | awk -v p="$csv_match" '$1 ~ p {print $NF}' | head -1)
  if [[ "$phase" == "Succeeded" ]]; then
    log_ok "Operator matching '${csv_match}' already installed in '${ns}' — skipping."
    return 0
  fi
  [[ -n "$phase" ]] && log_warn "Operator matching '${csv_match}' CSV found but phase is '${phase}' — reinstalling."

  local pkg channel
  pkg=$(discover_olm_package "$pkg_pattern")
  if [[ -z "$pkg" ]]; then
    log_error "Could not discover an OLM package matching '${pkg_pattern}' via"
    log_error "'oc get packagemanifest -n openshift-marketplace'. Check manually."
    exit 1
  fi
  channel=$(oc get packagemanifest "$pkg" -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}' 2>/dev/null)
  channel="${channel:-stable}"
  log_ok "Discovered package '${pkg}' (channel: ${channel}) for namespace '${ns}'"

  sed "s|NS_PLACEHOLDER|${ns}|g" "${MANIFESTS_DIR}/22-operator-namespace.yaml.tmpl" | oc apply -f -
  sed "s|NS_PLACEHOLDER|${ns}|g" "${MANIFESTS_DIR}/23-operator-operatorgroup.yaml.tmpl" | oc apply -f -
  sed -e "s|NS_PLACEHOLDER|${ns}|g" -e "s|PKG_PLACEHOLDER|${pkg}|g" -e "s|CHANNEL_PLACEHOLDER|${channel}|g" \
    "${MANIFESTS_DIR}/24-operator-subscription.yaml.tmpl" | oc apply -f -

  approve_installplan_for_sub "$ns" "$pkg"
  wait_for_csv "$ns" "$csv_match" "$OPERATOR_WAIT_TIMEOUT" \
    || { log_error "Operator '${pkg}' CSV failed. Aborting."; exit 1; }
  log_ok "Operator '${pkg}' CSV is Succeeded."
}

install_observability_operators() {
  if [[ "$SKIP_DASHBOARDS" == "true" ]]; then
    log_step "Step 4: Installing observability operators (COO, OpenTelemetry, Tempo)"
    log_warn "--skip-dashboards: skipping."
    return 0
  fi

  log_step "Step 4: Installing observability operators (COO, OpenTelemetry, Tempo)"
  log_info "OpenTelemetry + Tempo are required even though this script doesn't configure"
  log_info "tracing — CONFIRMED LIVE: RHOAI 3.5.1's 'Monitoring' platform resource hard-fails"
  log_info "its reconciliation precondition check ('OpenTelemetryCollector operator must be"
  log_info "installed for OpenTelemetry configuration') without them, which blocks the Perses"
  log_info "dashboards along with everything else — see this script's header comment."

  install_namespaced_operator "$COO_NS" '^cluster-observability-operator$' 'cluster-observability-operator'
  install_namespaced_operator "$OTEL_NS" '^opentelemetry-product$' 'opentelemetry-operator'
  install_namespaced_operator "$TEMPO_NS" '^tempo-product$' 'tempo-operator'
}

enable_rhoai_monitoring_stack() {
  if [[ "$SKIP_DASHBOARDS" == "true" ]]; then
    log_step "Step 5: Enabling the RHOAI monitoring stack (Perses dashboards)"
    log_warn "--skip-dashboards: skipping."
    return 0
  fi

  log_step "Step 5: Enabling the RHOAI monitoring stack (Perses dashboards)"

  local managed storage_size
  managed=$(oc get dscinitialization "$DSCI_NAME" -o jsonpath='{.spec.monitoring.managementState}' 2>/dev/null)
  storage_size=$(oc get dscinitialization "$DSCI_NAME" -o jsonpath='{.spec.monitoring.metrics.storage.size}' 2>/dev/null)

  if [[ "$managed" == "Managed" && -n "$storage_size" ]]; then
    log_ok "DSCI '${DSCI_NAME}' already has monitoring.managementState=Managed and"
    log_ok "metrics.storage configured (size=${storage_size}) — skipping patch."
  else
    log_info "Patching DSCI '${DSCI_NAME}': monitoring.managementState=Managed,"
    log_info "metrics.storage={size: ${METRICS_STORAGE_SIZE}, retention: ${METRICS_STORAGE_RETENTION}}."
    log_info "(CONFIRMED LIVE: managementState=Managed alone with an empty metrics:{} leaves the"
    log_info "'Monitoring' platform resource stuck at MonitoringStackAvailable=False, reason"
    log_info "MetricsNotConfigured — storage.size + retention are what actually trigger it.)"
    log_info "This merge-patches only spec.monitoring's fields below; other DSCI fields"
    log_info "(trustedCABundle, applicationsNamespace, any existing alerting/traces config) are"
    log_info "left untouched."
    oc patch dscinitialization "$DSCI_NAME" --type=merge -p "{
      \"spec\": {
        \"monitoring\": {
          \"managementState\": \"Managed\",
          \"namespace\": \"${RHOAI_MONITORING_NS}\",
          \"metrics\": {
            \"storage\": {
              \"size\": \"${METRICS_STORAGE_SIZE}\",
              \"retention\": \"${METRICS_STORAGE_RETENTION}\"
            }
          }
        }
      }
    }"
  fi

  log_info "Waiting for the 'Monitoring' platform resource to report PersesAvailable=True and"
  log_info "MonitoringStackAvailable=True (timeout: ${OPERATOR_WAIT_TIMEOUT}s)…"
  local deadline=$(( $(date +%s) + OPERATOR_WAIT_TIMEOUT ))
  while true; do
    local perses_status stack_status
    perses_status=$(oc get monitoring default-monitoring \
      -o jsonpath='{.status.conditions[?(@.type=="PersesAvailable")].status}' 2>/dev/null)
    stack_status=$(oc get monitoring default-monitoring \
      -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null)
    if [[ "$perses_status" == "True" && "$stack_status" == "True" ]]; then
      log_ok "Monitoring platform resource: PersesAvailable=True, MonitoringStackAvailable=True."
      break
    fi
    if (( $(date +%s) > deadline )); then
      log_warn "Timed out waiting for PersesAvailable/MonitoringStackAvailable. Current conditions:"
      oc get monitoring default-monitoring \
        -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" ("}{.reason}{") "}{.message}{"\n"}{end}' 2>/dev/null \
        | sed 's/^/    /'
      break
    fi
    sleep 10
  done

  wait_for_pods "$RHOAI_MONITORING_NS" "app.kubernetes.io/managed-by=perses-operator" "$POD_WAIT_TIMEOUT" \
    || log_warn "Perses server pod not confirmed Running in '${RHOAI_MONITORING_NS}' — dashboards may show no data yet."
}

smoke_test_metrics() {
  log_step "Step 6: Smoke-testing the metrics pipeline (Thanos querier)"

  local deadline=$(( $(date +%s) + METRICS_WAIT_TIMEOUT ))
  local vllm_ok=false epp_ok=false

  log_info "Querying vllm:num_requests_running{namespace=\"${MODEL_NS}\"} and"
  log_info "llm_d_epp_request_total{namespace=\"${MODEL_NS}\"} (retrying up to ${METRICS_WAIT_TIMEOUT}s —"
  log_info "doc note: metrics may take up to 60s to appear after deploy)…"

  while (( $(date +%s) < deadline )); do
    if [[ "$vllm_ok" == "false" ]] && promql_has_results "vllm:num_requests_running{namespace=\"${MODEL_NS}\"}"; then
      vllm_ok=true
    fi
    if [[ "$epp_ok" == "false" ]] && promql_has_results "llm_d_epp_request_total{namespace=\"${MODEL_NS}\"}"; then
      epp_ok=true
    fi
    [[ "$vllm_ok" == "true" && "$epp_ok" == "true" ]] && break
    sleep 5
  done

  if [[ "$vllm_ok" == "true" ]]; then
    log_ok "vLLM engine metrics are flowing (vllm:num_requests_running)."
  else
    log_warn "vLLM engine metrics not seen yet. If a model is deployed and has served at least"
    log_warn "one request, check: oc get podmonitors -n ${MODEL_NS}; oc get pods -n openshift-user-workload-monitoring"
  fi
  if [[ "$epp_ok" == "true" ]]; then
    log_ok "Inference scheduler (EPP) metrics are flowing (llm_d_epp_request_total)."
  else
    log_warn "EPP metrics not seen yet (llm_d_epp_request_total only has data after at least one"
    log_warn "request has been routed — try sending a test request, then re-run this step)."
  fi
}

download_grafana_dashboards() {
  if [[ "$DOWNLOAD_GRAFANA" != "true" ]]; then
    return 0
  fi

  log_step "Step 7: Downloading community Grafana dashboards (Ch 17.7)"
  mkdir -p "$GRAFANA_DASHBOARDS_DIR"

  local -A dashboards=(
    [llm-d-vllm-overview.json]="https://raw.githubusercontent.com/llm-d/llm-d/main/guides/recipes/observability/grafana/dashboards/llm-d-vllm-overview.json"
    [llm-d-failure-saturation-dashboard.json]="https://raw.githubusercontent.com/llm-d/llm-d/main/guides/recipes/observability/grafana/dashboards/llm-d-failure-saturation-dashboard.json"
    [llm-d-diagnostic-drilldown-dashboard.json]="https://raw.githubusercontent.com/llm-d/llm-d/main/guides/recipes/observability/grafana/dashboards/llm-d-diagnostic-drilldown-dashboard.json"
    [llm-d-performance-kv-cache.json]="https://raw.githubusercontent.com/llm-d/llm-d/main/guides/recipes/observability/grafana/dashboards/llm-d-performance-kv-cache.json"
    [llm-d-pd-coordinator-metrics.json]="https://raw.githubusercontent.com/llm-d/llm-d/main/guides/recipes/observability/grafana/dashboards/llm-d-pd-coordinator-metrics.json"
    [wva-operational-dashboard.json]="https://raw.githubusercontent.com/red-hat-data-services/workload-variant-autoscaler/rhoai-3.5/deploy/grafana/operational-dashboard.json"
  )

  for name in "${!dashboards[@]}"; do
    if curl -sfL "${dashboards[$name]}" -o "${GRAFANA_DASHBOARDS_DIR}/${name}"; then
      log_ok "Downloaded ${name}"
    else
      log_warn "Failed to download ${name} from ${dashboards[$name]}"
    fi
  done

  log_info "Dashboards saved to: ${GRAFANA_DASHBOARDS_DIR}"
  log_info "Import them in Grafana: Dashboards > New > Import. For the WVA dashboard, set"
  log_info "namespace_label=exported_namespace after import (per Ch 17.7)."
}

print_summary() {
  log_step "Observability setup — Summary"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║           llm-d Observability — Setup Complete                 ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  ${BOLD}Built-in dashboards${NC} (OpenShift AI dashboard > Observe & Monitor > Dashboard):"
  echo -e "    LLM Traffic, LLM Performance, LLM Utilization — filter by namespace '${MODEL_NS}'."
  echo -e "    Rendered by the Perses server in '${RHOAI_MONITORING_NS}' (label"
  echo -e "    app.kubernetes.io/managed-by=perses-operator)."
  echo
  echo -e "  ${BOLD}Raw PromQL${NC} (OCP console > Observe > Metrics, or the Thanos querier route):"
  echo -e "    vllm:num_requests_running{namespace=\"${MODEL_NS}\"}"
  echo -e "    llm_d_epp_request_total{namespace=\"${MODEL_NS}\"}"
  echo -e "    See Ch 17.6 of the doc for the full failure/saturation + drill-down query set."
  echo
  echo -e "  ${BOLD}Note:${NC} tracing and alerting are intentionally NOT configured (TempoAvailable /"
  echo -e "  AlertingAvailable / InstrumentationAvailable will show False on the 'Monitoring'"
  echo -e "  resource — expected). A second Alertmanager replica may also sit Pending on a"
  echo -e "  single-node cluster (anti-affinity, harmless when alerting isn't in use)."
  echo
  if [[ "$DOWNLOAD_GRAFANA" != "true" ]]; then
    echo -e "  Re-run with --download-grafana-dashboards to fetch the community Grafana dashboards"
    echo -e "  (Ch 17.7) — requires your own separately-deployed Grafana instance to import into."
    echo
  fi
  echo -e "  Re-run this script any time — all steps are idempotent."
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║    RHOAI 3.5 Distributed Inference with llm-d — Observability ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites
  enable_user_workload_monitoring
  verify_llm_d_monitor_resources
  install_observability_operators
  enable_rhoai_monitoring_stack
  smoke_test_metrics
  download_grafana_dashboards
  print_summary
}

main "$@"
