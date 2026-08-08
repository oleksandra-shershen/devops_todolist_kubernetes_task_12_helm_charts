#!/bin/bash
set -e

kind create cluster --config cluster.yml

kubectl taint nodes -l app=mysql app=mysql:NoSchedule --overwrite

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

helm dependency update .infrastructure/helm-chart/todoapp

helm upgrade --install todoapp-release .infrastructure/helm-chart/todoapp
