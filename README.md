# Solo Enterprise for agentgateway — Basic Demo

A minimal demo environment for Solo Enterprise for agentgateway. Deploys agentgateway with a simple HTTPBin backend reachable at `http://api.example.com`.

## Prerequisites

- A Kubernetes cluster (e.g., kind, k3d, or GKE)
- `kubectl` configured against the target cluster
- `helm` v3
- A Solo Enterprise for agentgateway license key

## Setup

### Step 1 — Set the license key

```bash
export AGENTGATEWAY_LICENSE_KEY=<your-license-key>
```

### Step 2 — Install Solo Enterprise for agentgateway

```bash
cd install
./install-agentgateway-with-helm.sh
```

This installs:
- Kubernetes Gateway API CRDs (`v1.4.1`)
- Solo Enterprise for agentgateway CRDs and controller (`v2.3.0-rc.3`)

### Step 3 — Deploy the demo resources

```bash
./setup.sh
```

This deploys:
- `EnterpriseAgentgatewayParameters` and `Gateway` in `agentgateway-system`
- HTTPBin backend in the `httpbin` namespace
- `ReferenceGrant` allowing routing from `agentgateway-system` to `httpbin`
- `HTTPRoute` for `api.example.com`

## Testing

Add `api.example.com` to your `/etc/hosts` pointing to your gateway's external IP, or port-forward:

```bash
kubectl -n agentgateway-system port-forward service/gw 8080:80
```

Then test with the provided script:

```bash
./curl-request.sh
```

Or directly:

```bash
curl -v http://api.example.com/get
```

Expected response: `200 OK` with the HTTPBin echo payload.

## Structure

```
agentgateway-demo-2/
├── install/
│   ├── install-agentgateway-with-helm.sh   # Installs agentgateway via Helm
│   ├── agentgateway-helm-values.yaml        # Helm values
│   └── setup.sh                             # Deploys demo resources
├── gateways/
│   ├── gw-parameters.yaml                   # EnterpriseAgentgatewayParameters
│   └── gw.yaml                              # Gateway (enterprise-agentgateway class)
├── routes/
│   └── api-example-com-httproute.yaml       # HTTPRoute for api.example.com
├── apis/
│   └── httpbin.yaml                         # HTTPBin Deployment + Service
├── referencegrants/
│   └── httpbin-ns/
│       └── agentgateway-system-ns-httproute-service-rg.yaml
├── policies/                                # Placeholder for EnterpriseAgentgatewayPolicy resources
└── curl-request.sh                          # Test script
```

## Versions

| Component | Version |
|-----------|---------|
| Solo Enterprise for agentgateway | `v2.3.0-rc.3` |
| Kubernetes Gateway API | `v1.4.1` |
