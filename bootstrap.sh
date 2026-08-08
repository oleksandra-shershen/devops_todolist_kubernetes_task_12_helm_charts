#!/bin/bash
set -e

CLUSTER_NAME="todoapp-cluster"

# 1. Create the kind cluster
kind create cluster --name "${CLUSTER_NAME}" --config cluster.yml
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# 2. Inspect node labels and taints
kubectl get nodes --show-labels
kubectl describe nodes | grep -E "Name:|Taints:|Labels:"

# 3. Taint nodes labeled app=mysql with app=mysql:NoSchedule
for node in $(kubectl get nodes -l app=mysql -o jsonpath='{.items[*].metadata.name}'); do
  kubectl taint nodes "${node}" app=mysql:NoSchedule --overwrite
done

# 4. Install Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

# 5. Build the mysql sub-chart dependency and deploy the todoapp Helm chart
helm dependency build helm-chart/todoapp
helm lint helm-chart/todoapp
helm upgrade --install todoapp helm-chart/todoapp --create-namespace --namespace todoapp

# 6. Wait for rollouts
kubectl rollout status deployment/todoapp -n todoapp --timeout=180s
kubectl rollout status statefulset/mysql -n mysql --timeout=180s

# 7. Dump cluster state
kubectl get all,cm,secret,ing -A > output.log
