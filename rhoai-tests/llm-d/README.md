# llm-d on RHOAI 3.4+ — Distributed Inference Automation

Automates deploying model serving with **llm-d** on Red Hat OpenShift AI 3.4+, following
[Deploy models using distributed inference with llm-d](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/deploy_models_using_distributed_inference_with_llm-d/index).

This is **plain llm-d only** — there is no Models-as-a-Service (MaaS) governance layer here
(no rate limiting, API key management, or usage metering). If you need that, see the sibling
`maas-rhoai` project. This project is for teams that just want distributed model serving with
a Gateway, optional request authentication, and GPU-aware scheduling.

## What it sets up

- **LeaderWorkerSet operator** — required by llm-d's `LLMInferenceService` CRD even for
  single-node models.
- **cert-manager operator** — LWS operator's own prerequisite.
- **Red Hat Connectivity Link (RHCL) / Kuadrant / Authorino** — optional request
  authentication in front of the Gateway. Skippable with `--skip-auth` for dev/test clusters;
  the upstream doc says production deployments should not skip it.
- **GatewayClass + Gateway** named exactly `openshift-ai-inference` in `openshift-ingress`
  (the name/namespace the llm-d controller specifically looks for).
- **MetalLB** (non-cloud platforms only, e.g. CRC/bare metal) so the Gateway gets a real
  LoadBalancer address. Skipped automatically on AWS/Azure/GCP/IBMCloud.
- A model namespace (`llm-d-models`) labeled for Gateway route binding.
- An example `LLMInferenceService` (Qwen3-8B-FP8-dynamic from Hugging Face). A scoped
  ServiceAccount/Role/RoleBinding for calling it is available too, but only created if you
  pass `--create-rbac-example` — see [Testing a deployed model](#testing-a-deployed-model).

## Prerequisites

- `oc` CLI logged in with cluster-admin privileges.
- RHOAI 3.4+ already installed, with a `DataScienceCluster` present (any management state —
  the scripts enable `kserve` for you if needed).
- OpenShift Service Mesh **v2** must NOT be installed (conflicts with the Gateway API path
  llm-d uses).
- OCP >= 4.19.9 recommended by the doc (checked and logged, not enforced).
- For GPU workloads: a node with schedulable `nvidia.com/gpu` capacity and a matching
  `HardwareProfile` (see [HardwareProfile and resources](#hardwareprofile-and-resources)
  below) — the NVIDIA GPU Operator stack itself is outside this project's scope.

## Quick start

```bash
# 1. Stand up the platform (operators, Gateway, auth, model namespace)
./setup-llm-d.sh

# 2. Deploy the example model
./deploy-example-workload.sh

# 3. Call it (your own user token — fine for a quick smoke test)
TOKEN=$(oc whoami -t)
curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  https://inference.apps-crc.testing/llm-d-models/qwen3-8b/v1/chat/completions \
  -d '{"model":"RedHatAI/Qwen3-8B-FP8-dynamic","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'

# 4. Tear it down when done
./teardown-llm-d.sh
```

All three scripts are **idempotent** — re-run any of them any time to reapply or reconcile
state; already-satisfied steps are detected and skipped.

### Optional: deploy with a custom vLLM image

To serve the same Qwen3 model with a different vLLM build instead of the controller's default
runtime image — for example, a Red Hat early-access image — pass `--image`:

```bash
./deploy-example-workload.sh \
  --image registry.redhat.io/rhaii-early-access/vllm-cuda-rhel9:3.5.0-ea.1-1780065492
```

This requires the cluster's global pull secret to already have credentials for
`registry.redhat.io` (check with `oc get secret/pull-secret -n openshift-config`). Confirmed
working on a live cluster — see [Known limitations](#known-limitations--unsupported-paths) for
the caveat that this flag is schema-valid but undocumented by Red Hat's own llm-d guide.

Re-running the command above against an already-deployed service updates it in place
(`llminferenceservice.serving.kserve.io/qwen3-8b configured`) rather than requiring a
teardown/redeploy cycle.

### Optional: deploy a Diffusers text-to-image model (e.g. Qwen-Image-2.1)

```bash
oc apply -f manifests/26-example-diffusion-llminferenceservice.yaml
```

Edit the `opendatahub.io/hardware-profile-name` and `security.opendatahub.io/enable-auth`
annotations at the top of the file first to match your cluster — this manifest is applied
directly with `oc apply`, not through `deploy-example-workload.sh`, so there's no sed/template
substitution step to fill them in for you.

This is a **separate manifest**, not a `deploy-example-workload.sh` flag combination, because
a Diffusers-format model (one with `model_index.json` + `text_encoder`/`transformer`/`vae`
subfolders, like `Qwen/Qwen-Image-2.1`, instead of a flat HF `config.json`) needs a
fundamentally different container command, not just an extra vLLM argument:

- It requires `vllm-omni` and the `--omni` flag — plain `vllm serve` only recognizes
  `config.json`/`params.json` and rejects the model outright ("Invalid repository ID or local
  directory specified").
- KServe's own Preset unconditionally appends `--shutdown-timeout 40` to the generated
  command for any vLLM ≥ 0.18.0, regardless of `--omni` — and vllm-omni's diffusion-stage
  config validator doesn't recognize that field, crashing the pod before it starts
  (`ValueError: Unknown diffusion config field(s) for stage 0: 'shutdown_timeout'`).
  `deploy-example-workload.sh`'s `--vllm-arg` only *appends* to the args list; it can't remove
  that Preset-injected flag, so `--vllm-arg --omni` alone would hit the same crash.

The manifest works around this by overriding the container's `command`/`args` entirely,
bypassing the Preset-generated script and reproducing everything it would otherwise provide
(TLS cert paths, port, served-model-name, access-log suppression) except
`--shutdown-timeout`. Confirmed live end-to-end on a CRC cluster (RHOAI 3.5.2): model weights
loaded (~30 GiB on a single NVIDIA L40S), the vLLM API server started in pure-diffusion mode,
and the `LLMInferenceService` reached `Ready=True` with every condition green. See the
manifest's own header comment for the full root-cause writeup.

Note the request payload for image generation differs from the chat-completions example in
[Testing a deployed model](#testing-a-deployed-model) below — consult vllm-omni's own docs for
the correct request shape for this model.

### Optional: configure observability

```bash
./setup-observability.sh
```

Sets up metrics + the built-in "LLM Traffic" / "LLM Performance" / "LLM Utilization"
dashboards (OpenShift AI dashboard → **Observe & monitor** → **Dashboard** → **Models** tab →
select your model) for the deployed model(s). Confirmed live on this project's own CRC
cluster — not just transcribed from the docs:

- Enables User Workload Monitoring (off by default; without it the PodMonitor/ServiceMonitor
  the KServe controller auto-creates per `LLMInferenceService` scrape nothing).
- Installs the Cluster Observability Operator, Red Hat build of OpenTelemetry, and Tempo — all
  three, even though tracing is never configured, because RHOAI 3.5's `Monitoring` platform
  resource hard-fails its reconciliation precondition without OpenTelemetry/Tempo present.
- Patches the `DSCInitialization`'s `spec.monitoring` (`managementState: Managed` +
  `metrics.storage.size`/`retention`) — the actual missing trigger for the Perses dashboard
  server to come up. Doc Ch 17.4's own prerequisite just says "enable the observability
  dashboard in the UI" and links out to a guide that doesn't fully spell this out.
- Smoke-tests that `vllm:*` and `llm_d_epp_*` metrics are actually flowing (via the in-cluster
  Thanos querier, authenticated with your own `oc` token) — not just that the right objects
  exist.
- `--download-grafana-dashboards` additionally fetches the community Grafana dashboard JSONs
  into `./grafana-dashboards/` (requires your own separately-deployed Grafana to import into —
  not installed by this script).

Not required for a model to work — purely for metrics/dashboards. See `./setup-observability.sh
--help` for all flags, and the script's own header comment for the full list of what was
confirmed live versus what the upstream docs say.

## Scripts

### `setup-llm-d.sh`

Platform bootstrap. Installs operators, configures auth, creates the Gateway, and labels the
model namespace. Auto-detects cloud vs. non-cloud platform (`oc get infrastructure cluster`)
to decide whether MetalLB and a passthrough Route are needed — never prompts for it.

```
./setup-llm-d.sh [OPTIONS]

  --skip-auth                   Skip RHCL/Kuadrant/Authorino install. Every
                                 LLMInferenceService deployed afterwards must then carry
                                 security.opendatahub.io/enable-auth: "false" — fine for
                                 dev/test, not for production per the upstream doc.
  --skip-lws                    Skip LeaderWorkerSet operator install.
  --skip-cert-manager            Skip cert-manager install.
  --skip-metallb                 Skip MetalLB install (non-cloud platforms only).
  --metallb-ip-range RANGE       Override the auto-derived MetalLB address pool.
  --extra-gateway-namespace NS   Label an additional namespace for Gateway route binding
                                 (repeatable). llm-d-models is always labeled.
  --help                         Show usage
```

Key environment variable overrides (all optional):
`RHOAI_OPERATOR_NS`, `RHOAI_APP_NS`, `CERT_MANAGER_NS`, `KUADRANT_NS`, `LWS_NS`, `MODEL_NS`,
`DSC_NAME`, `METALLB_NS`, `METALLB_IP_RANGE`, `OPERATOR_WAIT_TIMEOUT` (600s),
`POD_WAIT_TIMEOUT` (300s), `GATEWAY_WAIT_TIMEOUT` (120s).

The LeaderWorkerSet operator's exact OLM package name isn't fixed by Red Hat docs across
catalogs, so the script discovers it live (`oc get packagemanifest`) rather than hardcoding a
guess — same philosophy as GPU HardwareProfile auto-detection below.

### `deploy-example-workload.sh`

Deploys (or re-applies) the example `LLMInferenceService` on top of a platform `setup-llm-d.sh`
already configured.

```
./deploy-example-workload.sh [OPTIONS]

  --model-uri URI               Model storage URI (hf://, s3://, pvc://, oci://).
                                 Default: hf://RedHatAI/Qwen3-8B-FP8-dynamic
  --model-name NAME              Name clients use in chat-completion requests.
                                 Default: RedHatAI/Qwen3-8B-FP8-dynamic
  --service-name NAME             LLMInferenceService resource name. Default: qwen3-8b
  --namespace NS                  Namespace to deploy into. Default: llm-d-models
  --image IMAGE                   Override the "main" container's image with a custom vLLM
                                   build. UNDOCUMENTED by RHOAI's llm-d guide — confirmed
                                   schema-valid and working on a live cluster, but treat it
                                   as an unsupported path.
  --hardware-profile-name NAME    GPU HardwareProfile to annotate with. Overrides
                                   auto-detection.
  --vllm-arg ARG                  Extra vLLM server argument (repeatable), e.g.
                                   --vllm-arg --gpu-memory-utilization=0.85. Appended to the
                                   manifest's own default args (currently
                                   --max-model-len=16000 — see below).
  --enable-auth / --no-auth       Force the auth annotation either way. Without either flag,
                                   auto-detected from whether setup-llm-d.sh configured
                                   RHCL/Kuadrant/Authorino.
  --create-rbac-example            Also create a ServiceAccount/Role/RoleBinding scoped to
                                   exactly this LLMInferenceService, and print a scoped-token
                                   mint command.
  --help                           Show usage
```

Environment variables mirror the flags: `MODEL_URI`, `MODEL_NAME`, `SERVICE_NAME`, `MODEL_NS`,
`CUSTOM_IMAGE`, `HARDWARE_PROFILE_NAME`, plus `MODEL_WAIT_TIMEOUT` (600s).

### `teardown-llm-d.sh`

```
./teardown-llm-d.sh [--full] [--remove-observability] [--yes]
```

Default (no flags): removes the example `LLMInferenceService` + model namespace (which also
takes any PodMonitor/ServiceMonitor living in it, including the Ch 6.3 canary PodMonitor
`setup-observability.sh` may have applied, with it), reverts Authorino's `clusterWide`/TLS
config (Kuadrant CR deleted, which cascades the Authorino CR with it), and deletes the
Gateway/Route/ConfigMap. Operators (cert-manager, LWS, RHCL, COO/OpenTelemetry/Tempo),
MetalLB, the GatewayClass, `kserve`'s management state, User Workload Monitoring, and the
DSCI's monitoring config are all **left in place**, since they may be shared by other
workloads on the cluster.

`--full` additionally uninstalls cert-manager/LWS/RHCL, MetalLB, and the GatewayClass.
`--remove-observability` additionally reverts the DSCI's `monitoring.managementState` to
`Removed` and uninstalls COO/OpenTelemetry/Tempo (independent of `--full` — pass both if you
ran `setup-observability.sh` and want it fully undone). `--yes` skips the confirmation prompt.

### `setup-observability.sh` (optional)

Configures metrics collection + the built-in Perses dashboards for Distributed Inference with
llm-d, per RHOAI 3.5's doc Chapter 17 ("Monitor llm-d deployments") + Chapter 6.3 (per-version
canary metrics) + the Managing OpenShift AI guide's Chapter 12 (observability stack). Run after
`setup-llm-d.sh` + `deploy-example-workload.sh`.

```
./setup-observability.sh [OPTIONS]

  --skip-uwm                      Skip enabling User Workload Monitoring.
  --skip-dashboards                Skip installing COO/OpenTelemetry/Tempo and patching the
                                    DSCI's monitoring stack.
  --download-grafana-dashboards   Download the community Grafana dashboard JSONs (Ch 17.7)
                                   into ./grafana-dashboards/.
  --help                          Show usage
```

Environment variable overrides (all optional): `MODEL_NS`, `DSCI_NAME`,
`RHOAI_MONITORING_NS`, `METRICS_STORAGE_SIZE` (5Gi), `METRICS_STORAGE_RETENTION` (90d),
`OPERATOR_WAIT_TIMEOUT` (600s), `POD_WAIT_TIMEOUT` (300s), `METRICS_WAIT_TIMEOUT` (90s).

All steps are idempotent — re-running on an already-configured cluster detects and skips each
already-satisfied step. Also checks live whether the controller-created PodMonitor already
injects the `llm_isvc_name` per-version label (true on RHOAI 3.5.1) before deciding whether to
apply the doc's separate manual canary PodMonitor — avoids double-scraping the same pods.

Tracing and alerting are intentionally **not** configured (`spec.monitoring.traces`/`alerting`
on the DSCI are left untouched) — OpenTelemetry/Tempo are installed only because they're a
hard precondition for the dashboards to reconcile at all, not to enable tracing itself.

## HardwareProfile and resources

RHOAI's `hardwareprofile-llmisvc-injector` admission webhook validates that the profile named
in `opendatahub.io/hardware-profile-name` **actually exists** in the target namespace — it is
not purely informational. `deploy-example-workload.sh` resolves this in order:

1. `--hardware-profile-name` flag, if given.
2. The first HardwareProfile with an `nvidia.com/gpu` identifier (`detect_gpu_hardware_profile`
   in `lib/common.sh`).
3. Any HardwareProfile that exists at all (`detect_any_hardware_profile`), with a warning that
   it won't satisfy a real GPU request — just avoids the webhook rejection.
4. A literal `local-gpu` fallback (will likely fail the webhook if nothing exists).

`manifests/21-example-gpu-hardwareprofile.yaml` is an optional example GPU profile you can
`oc apply` on a cluster with real `nvidia.com/gpu` node capacity — it is **not** created by
`setup-llm-d.sh` or removed by `teardown-llm-d.sh`, since whether you want a GPU profile at all
is cluster-specific. Its identifiers (CPU default 1 / max 4, memory default 1Gi / max 16Gi,
GPU default/min/max 1) are tuned down for a single-VM dev cluster (e.g. CRC) — the companion
router/scheduler pod was previously seen `Pending` with "Insufficient memory" at a larger
16Gi-default/32Gi-max sizing. Raise the ceilings on a cluster with more headroom.

`manifests/19-example-llminferenceservice.yaml`'s container `resources` are set to match that
profile exactly: `requests` = each identifier's `defaultCount`, `limits` = each identifier's
`maxCount`. Keep them aligned with whatever HardwareProfile you actually use, or the webhook/
scheduler may reject or mis-size the pod.

The manifest also pins `--max-model-len=16000` as a default vLLM arg (down from the model's
own default of 40960) to keep KV-cache memory use proportionate to the scaled-down profile
above. Override or add to it with repeated `--vllm-arg` flags on `deploy-example-workload.sh`.

## Testing a deployed model

`--create-rbac-example` is **optional** — it's not required for a deployment to work, only
for how you authenticate against it when auth is enabled:

```bash
# Default: your own user token (fine for a quick smoke test)
TOKEN=$(oc whoami -t)

# Or, if you deployed with --create-rbac-example: a token scoped to only this
# LLMInferenceService (the docs' "recommended" least-privilege pattern)
TOKEN=$(oc create token qwen3-8b-caller -n llm-d-models --duration=1h)

curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  https://inference.apps-crc.testing/llm-d-models/qwen3-8b/v1/chat/completions \
  -d '{"model":"RedHatAI/Qwen3-8B-FP8-dynamic","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

- If auth is disabled (`--skip-auth` at setup, or `--no-auth` at deploy), drop the
  `Authorization` header entirely — no token is needed either way.
- Omit the `Authorization` header to confirm Authorino actually rejects unauthenticated
  requests (expect `401`/`403`) when auth is enabled.
- `oc get llminferenceservice <name> -n <namespace>` for overall `Ready` status.
- `oc logs -n <namespace> deploy/<service-name>-kserve` for vLLM server startup logs (confirms
  args like `--max-model-len` took effect).
- Qwen3 models emit a `<think>...</think>` reasoning block before the final answer by default
  — that's expected model behavior, not an error.

## Known limitations / unsupported paths

- `--image` (custom vLLM image override) and the `oci://`/`pvc://` model URI formats are
  schema-valid but not documented by Red Hat for this CRD version — treat as unsupported.
- The LWS Operator's singleton custom resource (if your version requires one explicitly) is
  not auto-created by this project; `setup-llm-d.sh` only installs the operator itself.
- GPU device access (CDI/OCI hooks, `RuntimeClass`) is entirely the NVIDIA GPU Operator's
  responsibility — this project assumes a cluster where GPU pods already get real device
  access without any extra `runtimeClassName` wiring on the `LLMInferenceService` pod spec.
  If your cluster's GPU Operator is configured to require an explicit `RuntimeClass` (not set
  as the cluster-wide default container runtime), you'll need to add
  `spec.template.runtimeClassName: <your-runtime-class>` to the `LLMInferenceService` yourself
  — `oc get runtimeclass` to check what's available.
