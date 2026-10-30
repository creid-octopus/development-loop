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
│   ├── development/        # local builds
│   ├── test/               # local builds
│   ├── production/         # local builds
│   └── octopus/            # Octopus only. #{...} tokens, one overlay for every environment
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

- **Raw YAML:** Edit the YAML file in each `k8s/raw/<env>/` directory, and in `k8s/raw/ephemeral/`. The ephemeral folder is a copy of `development/` with the namespace and environment name replaced by Octopus variables, so one folder serves every pull request environment. Argo CD never reads it.
- **Helm:** Edit `k8s/helm/templates/*.yaml` and update `k8s/helm/values.yaml` if adding new configurable fields. Pull request environments use `values-ephemeral.yaml`. The values that change per pull request come from `--set` arguments in `Project.Helm.UpgradeArgs`, because Octopus doesn't substitute variables in values files.
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

## Reaching the app locally

Each track has an Ingress. The Services are `ClusterIP`, so several tracks can share one port.

| Track | Host |
| --- | --- |
| Raw YAML | `raw-<env>.developmentloop.localtest.me` |
| Helm | `helm-<env>.developmentloop.localtest.me` |
| Kustomize | `kustomize-<env>.developmentloop.localtest.me` |

`localtest.me` resolves to 127.0.0.1. On the local Docker Desktop cluster the ingress controller is not reachable from the Mac, so run a port-forward and keep it open:

```bash
kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx
```

Then open `http://raw-development.developmentloop.localtest.me:8080`.

On a real cluster the same manifests apply. Change the ingress class and host for that cluster:

- **Raw YAML:** the `Project.Ingress.Domain`, `Project.Ingress.ClassName`, and `Project.Ingress.Port` variables. Clear the port when the controller uses 80 or 443.
- **Helm:** `ingress.className` and `ingress.host` in the values files.
- **Kustomize:** the Ingress host patch in each overlay.

The postdeploy Slack message and the "Show app URL" step print each project's URL.

### Rolling updates of the ingress controller can deadlock

The local ingress controller binds host ports. A rolling update starts the new pod before the old pod stops. The new pod then waits forever for the same host ports. The pod events show `didn't have free ports`.

Switch the controller to the `Recreate` strategy once. The old pod then stops before the new pod starts.

```bash
kubectl patch deployment ingress-nginx-controller -n ingress-nginx \
  --type merge \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
```

A Helm upgrade of the controller resets this patch. Set the strategy in the chart values to keep it. Recreate causes a short outage while the controller restarts.

### Checking every deployment

```bash
scripts/check-k8s-health.sh      # container tracks. Needs the port-forward.
scripts/check-server-health.sh   # Linux server path on ports 3101 to 3103
```
