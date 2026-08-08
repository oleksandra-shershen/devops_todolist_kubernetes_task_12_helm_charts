# Instruction

1. You can view the contents of all manifests with an already placed values in the todoapp chart using the command:
```bash
helm install todoapp-release .infrastructure/helm-chart/todoapp --dry-run
```

2. You can view the contents of all manifests with an already placed values in the mysql chart using the command:
```bash
helm install todoapp-release .infrastructure/helm-chart/todoapp/charts/mysql --dry-run
```

3. You can view information about the release update history:
```bash
helm history todoapp-release
```

## Validate deployed resources

```bash
kubectl get all -A
