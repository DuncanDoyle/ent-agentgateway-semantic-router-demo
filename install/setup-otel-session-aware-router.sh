#!/bin/sh

# Enables OTEL tracing in the session-aware-router Semantic Router release by upgrading it
# with the tracing overlay.
#
# Run from the install/ directory AFTER:
#   ./setup-session-aware-router.sh   (installs the `session-aware-router` release)
#   ./setup-otel-stack.sh             (installs the OTEL stack + gateway tracing policy)
#
# Overlays are re-applied in the SAME order as the base install so the upgrade does not drop
# config: upstream values FIRST, then the session-aware-router overlay
# (providers/decisions/complexity/strategy/resources), then the tracing overlay, then the
# image pin LAST so it wins. Helm upgrade replaces the value set, so every overlay MUST be
# re-passed here.
#
# CRITICAL: the upstream values.yaml is pulled from commit 8000843c (NOT refs/heads/main),
# matching setup-session-aware-router.sh and the pinned image. Using main would move this
# release onto a post-2026-06-20 build that removed the `algorithm.type: session_aware`
# surface this demo's config uses, breaking startup.

printf "\nUpgrade session-aware-router (Semantic Router) with tracing enabled ...\n"
helm upgrade session-aware-router oci://ghcr.io/vllm-project/charts/semantic-router \
  --version v0.0.0-latest \
  --namespace agentgateway-system \
  -f https://raw.githubusercontent.com/vllm-project/semantic-router/8000843cc8de0b7195318998225a14caa43c314d/deploy/kubernetes/agentgateway/semantic-router-values/values.yaml \
  -f session-aware-router-values.yaml \
  -f session-aware-router-tracing-values.yaml \
  -f session-aware-router-pin-values.yaml

printf "\nWaiting for session-aware-router to be ready ...\n"
kubectl wait --for=condition=Available deployment/session-aware-router \
  -n agentgateway-system \
  --timeout=600s

printf "\nTracing enabled for session-aware-router. Traces appear in Grafana/Tempo as\n"
printf "service 'session-aware-router' alongside the agentgateway spans.\n"
printf "NOTE: SR spans may not reach Tempo (known demo bug) — use JSON logs + the Prometheus\n"
printf "      metrics / Grafana dashboard (install/telemetry/) as the reliable channel.\n"
