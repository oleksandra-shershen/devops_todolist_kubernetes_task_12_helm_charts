# INSTRUCTION.md

Steps to validate the `todoapp` Helm chart (and its `mysql` sub-chart) on a
local `kind` cluster.

## 0. Prerequisites

- `docker`
- [`kind`](https://kind.sigs.k8s.io/)
- `kubectl`
- `helm` v3

## 1. Create the kind cluster

```bash
kind create cluster --name todoapp-cluster --config cluster.yml
```

This should bring up a control-plane node plus worker nodes, with one
worker labeled `app=todoapp` and one labeled `app=mysql` (see
`cluster.yml`).

## 2. Inspect node labels and taints

```bash
kubectl get nodes --show-labels
kubectl describe nodes | grep -E "Name:|Taints:|Labels:"
```

Confirm the `app=todoapp` and `app=mysql` labels are present, and that no
taints exist yet.

## 3. Taint the mysql node

```bash
for node in $(kubectl get nodes -l app=mysql -o jsonpath='{.items[*].metadata.name}'); do
  kubectl taint nodes "${node}" app=mysql:NoSchedule --overwrite
done
```

The `mysql` sub-chart's `StatefulSet` sets `tolerations` for
`app=mysql:NoSchedule` (`charts/mysql/templates/statefulset.yaml`,
driven by `charts/mysql/values.yaml` → `toleration`), combined with a
`required` `nodeAffinity`/`podAntiAffinity` on `app=mysql`, so its pods
land only on this node.

## 4. Install an ingress controller

The `todoapp` chart ships an `Ingress` resource
(`templates/ingress.yaml`), so a controller must exist for it to do
anything:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s
```

## 5. (Recommended) Install metrics-server

The `hpa.yaml` template creates a `HorizontalPodAutoscaler` that scales on
CPU/memory utilization (`values.yaml` → `hpa.cpuUtilization` /
`hpa.memoryUtilization`). Without `metrics-server`, `kubectl get hpa` will
show `<unknown>` for current utilization:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

(`--kubelet-insecure-tls` is needed because `kind` nodes use self-signed
kubelet certs.)

## 6. Build chart dependencies and lint

```bash
helm dependency build helm-chart/todoapp
helm lint helm-chart/todoapp
helm template todoapp helm-chart/todoapp | less   # optional: eyeball rendered manifests
```

`helm dependency build` reads the `dependencies:` block in
`helm-chart/todoapp/Chart.yaml` (`name: mysql`) and produces
`Chart.lock` plus a packaged `charts/mysql-0.1.0.tgz`. Do this **before**
the dry-run/install commands below — without it, the `mysql` sub-chart
manifests won't render (Helm will error that the dependency is declared
in `Chart.yaml` but not built/found).

You can preview the fully rendered manifests (with `values.yaml` already
merged in) without touching the cluster:

```bash
# todoapp chart (includes the mysql sub-chart's resources too)
helm install todoapp-release helm-chart/todoapp --dry-run

# mysql sub-chart in isolation
helm install todoapp-release helm-chart/todoapp/charts/mysql --dry-run
```

## 7. Deploy

Either run the bundled script (does steps 1–4 and this step):

```bash
chmod +x bootstrap.sh
./bootstrap.sh
```

or install manually:

```bash
helm upgrade --install todoapp-release helm-chart/todoapp \
  --create-namespace --namespace todoapp
```

Note: the chart's own `templates/namespace.yaml` (and the `mysql`
sub-chart's) also create the `todoapp` / `mysql` namespaces from
`values.yaml` → `namespace.name`. `--namespace todoapp
--create-namespace` on the Helm command just tells Helm which namespace
to install release *metadata* into; the actual workload namespaces come
from the templates.

You can inspect the release's upgrade/rollback history at any point:

```bash
helm history todoapp-release -n todoapp
```

(only useful once at least one `helm install`/`upgrade` has actually run
against the cluster — the `--dry-run` commands above don't create a
release, so they won't show up here.)

## 8. Wait for rollout

```bash
kubectl rollout status deployment/todoapp -n todoapp --timeout=180s
kubectl rollout status statefulset/mysql -n mysql --timeout=180s
```

## 9. Validate

```bash
kubectl get all,cm,secret,ing -A
```

Check specifically for:

- `namespace/todoapp` and `namespace/mysql` both `Active`
- `deployment.apps/todoapp` — `2/2` ready (from `values.yaml` →
  `replicaCount`)
- `statefulset.apps/mysql` — `2/2` ready, both pods scheduled **only** on
  the node labeled/tainted `app=mysql`:
  ```bash
  kubectl get pods -n mysql -o wide
  ```
- `horizontalpodautoscaler.autoscaling/todoapp` — targets `70%`/`70%`
  CPU/memory, `MINPODS 2`, `MAXPODS 5`
- `configmap/todoapp-config` (has `PYTHONUNBUFFERED`), `configmap/mysql`
  (has `init.sql`)
- `secret/todoapp-secret` (`SECRET_KEY`, `DB_NAME`, `DB_USER`,
  `DB_PASSWORD`, `DB_HOST`), `secret/mysql-secrets`
  (`MYSQL_ROOT_PASSWORD`, `MYSQL_USER`, `MYSQL_PASSWORD`)
- `ingress.networking.k8s.io/todoapp-ingress` — rule pointing at
  `todoapp-service:80`
- `serviceaccount/secrets-reader` in `todoapp` namespace, plus
  `role.rbac.authorization.k8s.io/secrets-reader` and
  `rolebinding.rbac.authorization.k8s.io/secrets-reader-binding`
- `pod/todoapp-*` scheduled preferentially on the node labeled
  `app=todoapp`, and running with `serviceAccountName: secrets-reader`:
  ```bash
  kubectl get pods -n todoapp -o wide
  kubectl get pod -n todoapp <pod-name> -o jsonpath='{.spec.serviceAccountName}'
  ```

Confirm the app pod actually receives its secrets as env vars:

```bash
kubectl exec -n todoapp deploy/todoapp -- env | grep -E "SECRET_KEY|DB_NAME|DB_USER|DB_PASSWORD|DB_HOST"
```

`DB_HOST` should decode to `mysql-0.mysql.mysql.svc.cluster.local`
(pod-name.service-name.namespace.svc.cluster.local, via the headless
`mysql` Service), confirming the app can resolve the MySQL StatefulSet
pod across namespaces.

Refresh the authoritative log file after a successful deploy:

```bash
kubectl get all,cm,secret,ing -A > output.log
```

## 10. Functional check

```bash
curl http://localhost:8080/     # via kind's ingress port mapping, see cluster.yml extraPortMappings
curl http://localhost:30007/    # via the NodePort service (values.yaml -> service.nodePort.nodePort)
```

Both should reach the ToDo app landing page; log in / register and add a
few list items to confirm the app can read and write through MySQL.

## 11. Tear down

```bash
helm uninstall todoapp-release -n todoapp
kind delete cluster --name todoapp-cluster
```
