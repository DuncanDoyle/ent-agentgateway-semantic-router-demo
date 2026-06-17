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

## Known issues

### vLLM Semantic Router OTEL tracing not emitting spans

OTEL tracing is correctly configured in the Semantic Router (`enabled: true`, correct OTLP endpoint) but no spans appear in Tempo. No OTEL initialization messages appear in the pod logs. Likely an upstream bug in the Semantic Router's OTEL SDK initialization.

**Workaround:** The structured JSON logs (`router_replay_complete`) contain all routing decision data (signals, decision block, selected model, confidence score) and are visible via `kubectl logs`.

**Track upstream:** https://github.com/vllm-project/semantic-router
