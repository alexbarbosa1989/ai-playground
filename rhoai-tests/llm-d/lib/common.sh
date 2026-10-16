# lib/common.sh
# Shared logging, colours, and oc-polling helpers for the llm-d scripts.
# Source this file; it defines functions and variables into the caller's shell,
# it does not execute anything on its own.
#
# Ported from the sibling maas-rhoai project's lib/common.sh (same helpers, same
# conventions) — kept identical on purpose so anyone familiar with that repo's
# scripts recognises this one immediately.

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
log_ok()    { echo -e "${GREEN}✔${NC} $*"; }

# approve_installplan_for_sub NAMESPACE SUBSCRIPTION_NAME
# Finds the InstallPlan referenced by a subscription and approves it if Manual.
# Handles clusters where OLM overrides Automatic to Manual (e.g. via admission webhooks).
approve_installplan_for_sub() {
  local ns="$1" sub="$2"
  local deadline=$(( $(date +%s) + 120 ))
  log_info "Checking InstallPlan approval for subscription '${sub}' in '${ns}'…"
  while true; do
    local plan_name
    plan_name=$(oc get subscription "$sub" -n "$ns" \
      -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null)
    if [[ -n "$plan_name" ]]; then
      local approved
      approved=$(oc get installplan "$plan_name" -n "$ns" \
        -o jsonpath='{.spec.approved}' 2>/dev/null)
      if [[ "$approved" != "true" ]]; then
        local csvs
        csvs=$(oc get installplan "$plan_name" -n "$ns" \
          -o jsonpath='{.spec.clusterServiceVersionNames}' 2>/dev/null)
        log_info "Approving InstallPlan '${plan_name}' (CSVs: ${csvs})…"
        oc patch installplan "$plan_name" -n "$ns" \
          --type=merge -p '{"spec":{"approved":true}}'
        log_ok "InstallPlan '${plan_name}' approved."
      else
        log_ok "InstallPlan '${plan_name}' already approved."
      fi
      return 0
    fi
    if (( $(date +%s) > deadline )); then
      log_warn "No InstallPlan found for subscription '${sub}' in '${ns}' after 120s — continuing."
      return 0
    fi
    sleep 5
  done
}

# wait_for_csv NAMESPACE PACKAGE TIMEOUT_SECS
# Polls until an operator's ClusterServiceVersion reaches Succeeded phase.
wait_for_csv() {
  local ns="$1" pkg="$2" timeout="$3"
  local deadline=$(( $(date +%s) + timeout ))
  log_info "Waiting for CSV '${pkg}' in namespace '${ns}' (timeout: ${timeout}s)…"
  while true; do
    local phase
    phase=$(oc get csv -n "$ns" 2>/dev/null \
      | awk -v p="$pkg" '$1 ~ p {print $NF}' | head -1)
    if [[ "$phase" == "Succeeded" ]]; then
      log_ok "CSV '${pkg}' is Succeeded."
      return 0
    fi
    if (( $(date +%s) > deadline )); then
      log_error "Timed out waiting for CSV '${pkg}' (last phase: '${phase:-not found}')."
      oc get csv -n "$ns" 2>/dev/null
      return 1
    fi
    sleep 10
  done
}

# wait_for_condition RESOURCE NAMESPACE CONDITION TIMEOUT_SECS
# Waits until a resource's .status.conditions contains condition=True.
wait_for_condition() {
  local resource="$1" ns="$2" condition="$3" timeout="$4"
  local deadline=$(( $(date +%s) + timeout ))
  log_info "Waiting for '${resource}' in '${ns}' to reach condition '${condition}'…"
  while true; do
    local status
    status=$(oc get "$resource" -n "$ns" \
      -o jsonpath="{.status.conditions[?(@.type==\"${condition}\")].status}" 2>/dev/null)
    if [[ "$status" == "True" ]]; then
      log_ok "'${resource}' condition '${condition}' is True."
      return 0
    fi
    if (( $(date +%s) > deadline )); then
      log_error "Timed out waiting for '${resource}' condition '${condition}' (status='${status}')."
      oc describe "$resource" -n "$ns" 2>/dev/null | tail -20
      return 1
    fi
    sleep 10
  done
}

# wait_for_pods NAMESPACE LABEL TIMEOUT_SECS
# Waits until at least one pod matching the label selector is Running.
wait_for_pods() {
  local ns="$1" selector="$2" timeout="$3"
  local deadline=$(( $(date +%s) + timeout ))
  log_info "Waiting for pods (selector='${selector}') in '${ns}'…"
  while true; do
    local running
    running=$(oc get pods -n "$ns" -l "$selector" \
      --field-selector=status.phase=Running 2>/dev/null | grep -c Running || true)
    if (( running > 0 )); then
      log_ok "${running} pod(s) Running in '${ns}' (selector='${selector}')."
      return 0
    fi
    # Fail fast on unrecoverable image pull errors rather than waiting the full timeout.
    local pull_err
    pull_err=$(oc get pods -n "$ns" -l "$selector" 2>/dev/null \
      | grep -c "ImagePullBackOff\|ErrImagePull" || true)
    if (( pull_err > 0 )); then
      log_error "Image pull failed for pods (selector='${selector}') in '${ns}':"
      oc get pods -n "$ns" -l "$selector" 2>/dev/null
      oc describe pod -n "$ns" -l "$selector" 2>/dev/null \
        | grep -A5 "Events:" | tail -10
      return 1
    fi
    if (( $(date +%s) > deadline )); then
      log_error "Timed out waiting for pods (selector='${selector}') in '${ns}'."
      oc get pods -n "$ns" -l "$selector" 2>/dev/null
      return 1
    fi
    sleep 10
  done
}

# apply_manifest FILE
# Applies a manifest. Silences "already exists" warnings (idempotent).
apply_manifest() {
  local file="$1"
  local out
  if out=$(oc apply -f "$file" 2>&1); then
    echo "$out"
    return 0
  fi
  if echo "$out" | grep -q "already exists"; then
    log_warn "Already exists (skipping): ${file##*/}"
    return 0
  fi
  log_error "Failed to apply '${file##*/}': ${out}"
  return 1
}

# resource_exists KIND NAME NAMESPACE
resource_exists() {
  oc get "$1" "$2" ${3:+-n "$3"} &>/dev/null
}

# detect_gpu_hardware_profile NAMESPACE
# Prints the name of the first HardwareProfile with an nvidia.com/gpu identifier
# in the given namespace, or nothing if none is found.
detect_gpu_hardware_profile() {
  local ns="$1"
  oc get hardwareprofile -n "$ns" -o json 2>/dev/null \
    | python3 -c "
import json,sys
profiles = json.load(sys.stdin).get('items', [])
for p in profiles:
    ids = p.get('spec', {}).get('identifiers', [])
    if any(i.get('identifier') == 'nvidia.com/gpu' for i in ids):
        print(p['metadata']['name'])
        break
" 2>/dev/null
}

# detect_any_hardware_profile NAMESPACE
# Prints the name of the first HardwareProfile found in the namespace, GPU or not — used as
# a fallback when no GPU profile exists. Unlike a literal guessed name, this always points at
# something that actually exists, which matters because (confirmed live on RHOAI 3.4.2) the
# hardwareprofile-llmisvc-injector admission webhook hard-rejects an LLMInferenceService
# whose opendatahub.io/hardware-profile-name annotation names a profile that doesn't exist in
# that namespace — the annotation is NOT purely informational on every RHOAI version/config,
# despite the sibling maas-rhoai project's manifests assuming so.
detect_any_hardware_profile() {
  local ns="$1"
  oc get hardwareprofile -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# detect_platform_class
# Prints "cloud" or "non-cloud" based on oc get infrastructure cluster's platform field.
detect_platform_class() {
  local platform
  platform=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null)
  case "$platform" in
    AWS|Azure|GCP|IBMCloud) echo "cloud" ;;
    *) echo "non-cloud" ;;
  esac
}

# discover_olm_package SEARCH_REGEX [CATALOG_NAMESPACE]
# Prints the first packagemanifest name matching SEARCH_REGEX (case-insensitive) in the
# given catalog namespace (default openshift-marketplace), or nothing if none found.
# Used instead of hardcoding a guessed OLM package name for operators whose exact
# subscription `name` field could not be confirmed against docs at script-writing time
# (see setup-llm-d.sh's LeaderWorkerSet install step) — same spirit as
# detect_gpu_hardware_profile above: ask the live cluster rather than trust a guess.
discover_olm_package() {
  local pattern="$1" catalog_ns="${2:-openshift-marketplace}"
  oc get packagemanifest -n "$catalog_ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -i -E "$pattern" | sort -u | head -1
}
