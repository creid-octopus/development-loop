# Kubernetes Manifests

Three approaches for deploying `developmentloop-demo` to Kubernetes. Each is independently renderable and deployable — different teams and tools prefer different paradigms.

## Quick Start

| Approach | Render | Apply |
|---|---|---|
| Raw YAML | `kubectl apply -f k8s/raw/<env>/` | `kubectl apply -k k8s/kustomize/<env>/` |
| Helm | `helm template -f values-<env>.yaml k8s/helm/` | `helm install -f values-<env>.yaml` |
| Kustomize | `kustomize build kustomize/<env>/` | `kubectl apply -k k8s/kustomize/<env>/` |

Replace `<env>` with `development`, `test`, or `production`.

## Directory Layout

```
k8s/
├── raw/                    # Per-environment YAML directories
│   ├── development/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── test/
│   └── production/
│
├── helm/                   # Single chart, environment-specific value files
│   ├── Chart.yaml
│   ├── values.yaml         # Shared defaults (replicas, probes, resources, etc.)
│   ├── values-development.yaml
│   ├── values-test.yaml
│   ├── values-production.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── configmap.yaml
│       ├── deployment.yaml
│       └── service.yaml
│
├── kustomize/              # Base manifests + per-environment overlays
│   ├── base/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── development/
│   ├── test/
│   └── production/
│
└── README.md
```

## Namespace Convention

Each environment lives in its own namespace:

| Environment | Namespace |
|---|---|
| Development | `developmentloop-demo-development` |
| Test | `developmentloop-demo-test` |
| Production | `developmentloop-demo-production` |

Resource names are identical across all approaches and environments (e.g. `developmentloop-demo` for both Deployment and Service). Namespace is the sole disambiguator.

## Changing the App

All three approaches represent the same application. A change to the app must be reflected in all three:

- **Raw YAML:** Edit the YAML file in each `k8s/raw/<env>/` directory.
- **Helm:** Edit `k8s/helm/templates/*.yaml` and update `k8s/helm/values.yaml` if adding new configurable fields.
- **Kustomize:** Edit `k8s/kustomize/base/*.yaml` (namespace/ConfigMap patches stay in the overlay).

## ArgoCD Integration

Three ApplicationSets live in `argocd/`, one per approach. Each iterates over the three environments:

```yaml
# argocd/helm-applications.yaml
source:
  path: k8s/helm
  helm:
    valueFiles:
      - values.yaml
      - values-{{ environment }}.yaml
```

Apply them to your ArgoCD instance:

```bash
kubectl apply -f argocd/
```

Each Application creates its namespace automatically (`CreateNamespace=true`).

## When to Use Which

| Approach | Best For | Learning Curve |
|---|---|---|
| Raw YAML | Simplicity, small apps, teams new to Kubernetes | Lowest |
| Helm | Apps with conditional logic, many environments, packaged distributions | Moderate |
| Kustomize | Many environments sharing the same base, heavy namespace/label patching | Moderate |

This repo keeps all three so you can prototype with one, migrate to another, or run them side-by-side while evaluating.
