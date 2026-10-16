#!/usr/bin/env bash
# deploy-example-workload.sh
# Deploys an example LLMInferenceService on top of a platform already configured by
# setup-llm-d.sh. Plain llm-d, no MaaS governance/API-key layer anywhere.
#
# This is a separate script from setup-llm-d.sh on purpose: the platform layer (operators,
# Gateway, Authorino) is close to one-shot, while a given model deployment is something
# you'll likely redeploy, tweak, or tear down independently many times — and is also the
# natural place to point at your own custom vLLM image instead of the documented default.
#
# Usage:
#   ./deploy-example-workload.sh [--model-uri URI] [--model-name NAME] [--service-name NAME]
#                                [--namespace NS] [--image IMAGE] [--hardware-profile-name NAME]
#                                [--vllm-arg ARG]... [--enable-auth|--no-auth]
#                                [--create-rbac-example] [--help]

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RHOAI_OPERATOR_NS="${RHOAI_OPERATOR_NS:-redhat-ods-operator}"
RHOAI_APP_NS="${RHOAI_APP_NS:-redhat-ods-applications}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
MODEL_NS="${MODEL_NS:-llm-d-models}"
DSC_NAME="${DSC_NAME:-default-dsc}"
GATEWAY_NS="openshift-ingress"
GATEWAY_NAME="openshift-ai-inference"

MODEL_WAIT_TIMEOUT="${MODEL_WAIT_TIMEOUT:-600}"   # seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

SERVICE_NAME="${SERVICE_NAME:-qwen3-8b}"
MODEL_URI="${MODEL_URI:-hf://RedHatAI/Qwen3-8B-FP8-dynamic}"
MODEL_NAME="${MODEL_NAME:-RedHatAI/Qwen3-8B-FP8-dynamic}"
CUSTOM_IMAGE="${CUSTOM_IMAGE:-}"
HARDWARE_PROFILE_NAME="${HARDWARE_PROFILE_NAME:-}"
RESOLVED_HW_PROFILE=""
VLLM_ARGS=()
AUTH_MODE=""          # "", "true", or "false" — "" means auto-detect
CREATE_RBAC_EXAMPLE=false

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model-uri)              MODEL_URI="$2"; shift 2 ;;
      --model-name)              MODEL_NAME="$2"; shift 2 ;;
      --service-name)            SERVICE_NAME="$2"; shift 2 ;;
      --namespace)               MODEL_NS="$2"; shift 2 ;;
      --image)                   CUSTOM_IMAGE="$2"; shift 2 ;;
      --hardware-profile-name)   HARDWARE_PROFILE_NAME="$2"; shift 2 ;;
      --vllm-arg)                VLLM_ARGS+=("$2"); shift 2 ;;
      --enable-auth)             AUTH_MODE="true"; shift ;;
      --no-auth)                 AUTH_MODE="false"; shift ;;
      --create-rbac-example)     CREATE_RBAC_EXAMPLE=true; shift ;;
      --help)
        cat <<'USAGE'
deploy-example-workload.sh — Deploys an example LLMInferenceService on top of a platform
configured by setup-llm-d.sh. No MaaS governance layer — plain llm-d only.

Usage:
  ./deploy-example-workload.sh [OPTIONS]

Options:
  --model-uri URI               Model storage URI (hf://, s3://, pvc://, oci://).
                                 Default: hf://RedHatAI/Qwen3-8B-FP8-dynamic
  --model-name NAME              Name clients use in chat-completion requests.
                                 Default: RedHatAI/Qwen3-8B-FP8-dynamic
  --service-name NAME             LLMInferenceService resource name. Default: qwen3-8b
  --namespace NS                  Namespace to deploy into. Default: llm-d-models
  --image IMAGE                   Override the "main" container's image with a custom vLLM
                                   build (e.g. a registry.redhat.io/rhaii-early-access/...
                                   image) instead of letting the controller pick its default
                                   runtime image. UNDOCUMENTED by RHOAI's own llm-d guide —
                                   confirmed schema-valid and seen working on a live cluster,
                                   but treat it as an unsupported path.
  --hardware-profile-name NAME    GPU HardwareProfile to annotate with. Overrides
                                   auto-detection.
  --vllm-arg ARG                  Extra vLLM server argument (repeatable), e.g.
                                   --vllm-arg --max-model-len=16000. Merged with the
                                   system's own default arguments per the upstream docs.
  --enable-auth                   Force security.opendatahub.io/enable-auth: "true".
  --no-auth                       Force security.opendatahub.io/enable-auth: "false".
                                   Without either flag, this script auto-detects: "true" if
                                   setup-llm-d.sh configured RHCL/Kuadrant/Authorino, "false"
                                   if it was run with --skip-auth.
  --create-rbac-example            Also create a ServiceAccount/Role/RoleBinding scoped to
                                   exactly this LLMInferenceService (the docs' "recommended"
                                   auth method) and print a scoped-token mint command. Only
                                   meaningful when auth is enabled.
  --help                           Show this message

Prerequisites (created by setup-llm-d.sh):
  - Namespace matching --namespace must exist and be labeled for Gateway route binding
  - Gateway 'openshift-ai-inference' must be Programmed in 'openshift-ingress'

Environment variables mirror the flags (MODEL_URI, MODEL_NAME, SERVICE_NAME, MODEL_NS,
CUSTOM_IMAGE, HARDWARE_PROFILE_NAME) plus MODEL_WAIT_TIMEOUT=600.
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

  if ! resource_exists namespace "$MODEL_NS"; then
    log_error "Namespace '${MODEL_NS}' not found. Run ./setup-llm-d.sh first (or pass --namespace)."
    exit 1
  fi

  if ! resource_exists gateway "$GATEWAY_NAME" "$GATEWAY_NS"; then
    log_error "Gateway '${GATEWAY_NAME}' not found in '${GATEWAY_NS}'. Run ./setup-llm-d.sh first."
    exit 1
  fi
  log_ok "llm-d platform prerequisites satisfied."

  if [[ ! -d "$MANIFESTS_DIR" ]]; then
    log_error "Manifests directory not found: ${MANIFESTS_DIR}"
    exit 1
  fi
}

resolve_auth_mode() {
  log_step "Step 2: Resolving authentication mode"

  if [[ -n "$AUTH_MODE" ]]; then
    log_ok "Auth mode explicitly set via flag: enable-auth=${AUTH_MODE}"
    return 0
  fi

  local kuadrant_ready authorino_cluster_wide
  kuadrant_ready=$(oc get kuadrant kuadrant -n "$KUADRANT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  authorino_cluster_wide=$(oc get authorino authorino -n "$KUADRANT_NS" \
    -o jsonpath='{.spec.clusterWide}' 2>/dev/null)

  if [[ "$kuadrant_ready" == "True" && "$authorino_cluster_wide" == "true" ]]; then
    AUTH_MODE="true"
    log_ok "Detected Kuadrant Ready + cluster-wide Authorino — enabling auth."
  else
    AUTH_MODE="false"
    log_warn "Kuadrant/Authorino not detected as configured — disabling auth"
    log_warn "(security.opendatahub.io/enable-auth: \"false\"). Pass --enable-auth to force"
    log_warn "it on anyway (will fail closed if RHCL/Kuadrant isn't actually set up)."
  fi
}

deploy_llminferenceservice() {
  log_step "Step 3: Deploying LLMInferenceService '${SERVICE_NAME}'"

  RESOLVED_HW_PROFILE="$HARDWARE_PROFILE_NAME"
  if [[ -n "$RESOLVED_HW_PROFILE" ]]; then
    log_ok "Using HardwareProfile '${RESOLVED_HW_PROFILE}' (explicitly provided)."
  else
    RESOLVED_HW_PROFILE=$(detect_gpu_hardware_profile "$RHOAI_APP_NS")
    if [[ -n "$RESOLVED_HW_PROFILE" ]]; then
      log_ok "Auto-detected GPU HardwareProfile '${RESOLVED_HW_PROFILE}' in '${RHOAI_APP_NS}'."
    else
      # Confirmed live on RHOAI 3.4.2 (CRC): the hardwareprofile-llmisvc-injector admission
      # webhook hard-REJECTS the apply outright if this annotation names a profile that
      # doesn't actually exist in the namespace — it is not purely informational the way the
      # sibling maas-rhoai project's manifests assume. Falling back to a guessed literal name
      # (e.g. "local-gpu") would just move the failure from "clear warning here" to "opaque
      # admission-webhook error later", so fall back to whatever profile genuinely exists
      # instead — even a non-GPU one — and say plainly that it won't actually satisfy the
      # nvidia.com/gpu resource request below.
      RESOLVED_HW_PROFILE=$(detect_any_hardware_profile "$RHOAI_APP_NS")
      if [[ -n "$RESOLVED_HW_PROFILE" ]]; then
        log_warn "No GPU HardwareProfile found in '${RHOAI_APP_NS}' — falling back to"
        log_warn "'${RESOLVED_HW_PROFILE}' (exists, but not GPU-capable) purely so the"
        log_warn "hardwareprofile-llmisvc-injector admission webhook doesn't reject the apply"
        log_warn "for naming a nonexistent profile. The pod will still request"
        log_warn "nvidia.com/gpu: \"1\" and stay Pending without real GPU capacity on this"
        log_warn "cluster — create a real GPU HardwareProfile and pass --hardware-profile-name"
        log_warn "once one exists."
      else
        log_error "No HardwareProfile exists in '${RHOAI_APP_NS}' at all, and none was"
        log_error "provided via --hardware-profile-name. The apply below will likely be"
        log_error "rejected by the hardwareprofile-llmisvc-injector admission webhook."
        log_error "Create a HardwareProfile first: oc get hardwareprofile -n ${RHOAI_APP_NS}"
        RESOLVED_HW_PROFILE="local-gpu"
      fi
    fi
  fi

  local rendered
  rendered=$(sed \
      -e "s|opendatahub.io/hardware-profile-name:.*|opendatahub.io/hardware-profile-name: ${RESOLVED_HW_PROFILE}|" \
      -e "s|ENABLE_AUTH_PLACEHOLDER|${AUTH_MODE}|" \
      -e "s|name: qwen3-8b|name: ${SERVICE_NAME}|" \
      -e "s|namespace: llm-d-models|namespace: ${MODEL_NS}|" \
      -e "s|name: RedHatAI/Qwen3-8B-FP8-dynamic|name: ${MODEL_NAME}|" \
      -e "s|uri: hf://RedHatAI/Qwen3-8B-FP8-dynamic|uri: ${MODEL_URI}|" \
    "${MANIFESTS_DIR}/19-example-llminferenceservice.yaml")

  if [[ -n "$CUSTOM_IMAGE" ]]; then
    log_warn "Overriding container image with '${CUSTOM_IMAGE}' — undocumented path, see --help."
    rendered=$(echo "$rendered" | sed "s|- name: main|- name: main\n      image: ${CUSTOM_IMAGE}|")
  fi

  if (( ${#VLLM_ARGS[@]} > 0 )); then
    # The manifest already ships a static "args:" list (see
    # 19-example-llminferenceservice.yaml's --max-model-len default), so extra args are
    # appended as further list items under that same key rather than inserted as a second
    # "args:" mapping — two "args:" keys on one container would be invalid YAML.
    local extra_items=""
    for a in "${VLLM_ARGS[@]}"; do
      extra_items="${extra_items}\n        - ${a}"
    done
    rendered=$(echo "$rendered" | sed "s|^      args:\$|      args:${extra_items}|")
  fi

  local out
  if ! out=$(echo "$rendered" | oc apply -f - 2>&1); then
    log_error "Failed to apply LLMInferenceService: ${out}"
    exit 1
  fi
  echo "$out"

  log_info "Waiting for LLMInferenceService to initialise (may take several minutes)…"
  local deadline=$(( $(date +%s) + MODEL_WAIT_TIMEOUT ))
  while true; do
    local ready
    ready=$(oc get llminferenceservice "$SERVICE_NAME" -n "$MODEL_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$ready" == "True" ]]; then
      log_ok "LLMInferenceService '${SERVICE_NAME}' is Ready."
      return 0
    fi
    if (( $(date +%s) > deadline )); then
      log_warn "LLMInferenceService not Ready within $((MODEL_WAIT_TIMEOUT / 60)) minutes — check pod status:"
      oc get pods -n "$MODEL_NS" 2>/dev/null
      log_warn "Continuing — the summary below reflects whatever state the resource is actually in."
      return 0
    fi
    sleep 15
  done
}

create_rbac_example() {
  if [[ "$CREATE_RBAC_EXAMPLE" != "true" ]]; then
    return 0
  fi
  log_step "Step 4: Creating scoped ServiceAccount/Role/RoleBinding for '${SERVICE_NAME}'"

  if [[ "$AUTH_MODE" != "true" ]]; then
    log_warn "Auth is disabled for this LLMInferenceService — creating the RBAC example anyway,"
    log_warn "but it won't be enforced until you re-deploy with --enable-auth."
  fi

  sed -e "s|SERVICE_NAME_PLACEHOLDER|${SERVICE_NAME}|g" \
      -e "s|MODEL_NS_PLACEHOLDER|${MODEL_NS}|g" \
    "${MANIFESTS_DIR}/20-example-sa-rbac.yaml.tmpl" | oc apply -f -
  log_ok "ServiceAccount '${SERVICE_NAME}-caller' + scoped Role/RoleBinding created in '${MODEL_NS}'."
}

print_summary() {
  log_step "Example workload deployment — Summary"

  local apps_domain inference_url
  apps_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "<apps-domain>")
  inference_url="https://inference.${apps_domain}"

  local model_ready
  model_ready=$(oc get llminferenceservice "$SERVICE_NAME" -n "$MODEL_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "N/A")

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║          llm-d Example Workload — Summary                     ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  LLMInferenceService '${SERVICE_NAME}' Ready   ${model_ready}"
  echo -e "  Namespace                                  ${MODEL_NS}"
  echo -e "  HardwareProfile used                       ${RESOLVED_HW_PROFILE}"
  echo -e "  Auth (enable-auth annotation)              ${AUTH_MODE}"
  [[ -n "$CUSTOM_IMAGE" ]] && echo -e "  Custom image                                ${CUSTOM_IMAGE}"
  echo
  echo -e "  ${BOLD}Inspect:${NC}"
  echo -e "     oc get llminferenceservice ${SERVICE_NAME} -n ${MODEL_NS}"
  echo -e "     oc get pods -n ${MODEL_NS}"
  echo
  echo -e "  ${BOLD}Call the model API:${NC}"
  if [[ "$AUTH_MODE" == "true" ]]; then
    if [[ "$CREATE_RBAC_EXAMPLE" == "true" ]]; then
      echo -e "     TOKEN=\$(oc create token ${SERVICE_NAME}-caller -n ${MODEL_NS} --duration=1h)"
    else
      echo -e "     TOKEN=\$(oc whoami -t)   # or re-run with --create-rbac-example for a scoped token"
    fi
    echo -e "     curl -sk -H \"Authorization: Bearer \$TOKEN\" -H \"Content-Type: application/json\" \\"
  else
    echo -e "     curl -sk -H \"Content-Type: application/json\" \\"
  fi
  echo -e "       ${inference_url}/${MODEL_NS}/${SERVICE_NAME}/v1/chat/completions \\"
  echo -e "       -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
  echo
  echo -e "  Re-run this script any time to reapply the workload (all steps are idempotent)."
  echo -e "  To remove it: oc delete llminferenceservice ${SERVICE_NAME} -n ${MODEL_NS}"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║     llm-d — Example Workload Deployment                       ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites
  resolve_auth_mode
  deploy_llminferenceservice
  create_rbac_example
  print_summary
}

main "$@"
