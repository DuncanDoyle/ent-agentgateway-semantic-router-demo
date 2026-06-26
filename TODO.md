# TODO / RFEs

## Setup improvements

### Require HuggingFace token before installing Semantic Router

The Semantic Router downloads the mmBERT-32K intent classifier from HuggingFace Hub on first boot. Without a token it falls back to the unauthenticated free tier, which is heavily rate-limited and causes the pod to hang indefinitely during model download.

The `setup-semantic-router.sh` script should check for a `HF_TOKEN` environment variable and create the `hf-token-secret` before installing the Helm chart — similar to how `install-agentgateway-with-helm.sh` guards on `AGENTGATEWAY_LICENSE_KEY`.

```bash
if [ -z "$HF_TOKEN" ]; then
  echo "HF_TOKEN is not set. A HuggingFace token is required to download the Semantic Router models."
  echo "Create a free token at https://huggingface.co/settings/tokens"
  exit 1
fi

kubectl create secret generic hf-token-secret \
  -n agentgateway-system \
  --from-literal=token=$HF_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Demo stability

### Pin the Semantic Router image (and chart) version — currently floating on `latest`

The SR install uses a floating chart version **and** a floating image tag:

```bash
helm upgrade --install semantic-router oci://ghcr.io/vllm-project/charts/semantic-router \
  --version v0.0.0-latest \
  --namespace agentgateway-system \
  -f .../agentgateway/semantic-router-values/values.yaml
# image: ghcr.io/vllm-project/semantic-router/extproc:latest
```

**Investigated 2026-06-26.** The running pod is on:

| | |
|---|---|
| Image | `ghcr.io/vllm-project/semantic-router/extproc:latest` |
| Running digest | `sha256:687801890a026dceee18dd2073a0384e965eab34d9769a1bcd80a8a2272a5c54` |
| Built | **2026-06-17** (a `main`-branch rolling build, newer than `v0.3.0` = 2026-06-05) |
| `imagePullPolicy` | `IfNotPresent` |

The `latest` tag has **already drifted**: as of 2026-06-26 it points at a **2026-06-23** build (`sha256:b348c46…`), 6 days ahead of what we run. `IfNotPresent` keeps the cached June-17 image across container restarts, but a **pod reschedule onto a fresh node will pull whatever `latest` is that day** — so demo behaviour can change with no config change on our side.

**Action before demoing:** pin the image to the validated digest (most reproducible — freezes the exact bits we tested):

```yaml
# semantic-router values
image:
  repository: ghcr.io/vllm-project/semantic-router/extproc
  digest: sha256:687801890a026dceee18dd2073a0384e965eab34d9769a1bcd80a8a2272a5c54
  pullPolicy: IfNotPresent
```

Alternatively pin to the released tag `v0.3.0` (documented, shareable version number, known to contain the cost-aware `multi_factor` selector + `pricing` schema) and re-test — note this moves ~12 days back from the current build. Also pin the chart `--version` away from `v0.0.0-latest` to a concrete chart release if one is published (`helm show chart oci://ghcr.io/vllm-project/charts/semantic-router`), since the chart templates/values can change independently of the image.

> Both `model-tier-router` and `semantic-router` Helm releases must be pinned consistently if they share an image.

---

## Planned features

### Semantic Router-driven LLM provider selection — IMPLEMENTED (additive `/llm-tier`)

**Done (2026-06-26).** Implemented as the additive `model-tier-router` use-case on `/llm-tier` (the weighted `/llm` is left intact). The vLLM Semantic Router classifies each prompt by **complexity** (primary) and routes to the **cheapest capable model** across OpenAI + Gemini via the per-decision `multi_factor` cost selector. Install: `install/setup-model-tier-router.sh`; switch with `install/switch-to-{model-tier,semantic}-router.sh`; probes `curl-model-tier-*.sh`.

See `docs/design-semantic-router-llm-routing.md` (design) and `docs/superpowers/plans/2026-06-26-model-tier-router.md` (implementation plan).

**Phase 2 (not yet done):** cost-savings telemetry & explainability (capture per-prompt decision + selected model + price; compute savings vs. always-premium baseline). **Optional follow-ups:** enable the PII lane (needs the PII detector model bundled — see the commented block in `install/model-tier-router-values.yaml`); evaluate matching the route on the SR-emitted `x-vsr-model` header to drop the PreRouting transformation.

---

## Known issues

### vLLM Semantic Router OTEL tracing not emitting spans

OTEL tracing is correctly configured in the Semantic Router (`enabled: true`, correct OTLP endpoint) but no spans appear in Tempo. No OTEL initialization messages appear in the pod logs. Likely an upstream bug in the Semantic Router's OTEL SDK initialization.

**Workaround:** The structured JSON logs (`router_replay_complete`) contain all routing decision data (signals, decision block, selected model, confidence score) and are visible via `kubectl logs`.

**Track upstream:** https://github.com/vllm-project/semantic-router
