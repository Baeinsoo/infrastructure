# ArgoCD Install (local docker-desktop)

## Version
- ArgoCD **v2.13.2** (official upstream manifest, non-HA)
- Cluster: `docker-desktop` context
- Namespace: `argocd`

## Install

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
```

## Wait for readiness

```bash
kubectl wait --for=condition=available --timeout=300s deployment -n argocd \
  argocd-server argocd-repo-server argocd-applicationset-controller
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl get pods -n argocd
```

All 7 pods should reach `Running`:
`argocd-application-controller-0`, `argocd-applicationset-controller`,
`argocd-dex-server`, `argocd-notifications-controller`, `argocd-redis`,
`argocd-repo-server`, `argocd-server`.

## Access

ArgoCD API/UI is exposed via the `argocd-server` ClusterIP service
(ports 80/TCP, 443/TCP). For local access, port-forward:

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443
```

Then browse to https://localhost:8080 (self-signed cert) or check health:

```bash
curl -sk https://localhost:8080/healthz
# -> ok
```

Remember to kill the port-forward when done (`kill %1` or Ctrl-C) — it is
not meant to run persistently in this setup.

## Admin login

- Username: `admin`
- Initial password is auto-generated in the `argocd-initial-admin-secret`
  secret. Retrieve it with:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

This is a local dev cluster only; the initial password does not need to
be rotated for this environment, but can be changed via `argocd account
update-password` if desired.

## Notes
- This step only installs ArgoCD itself. No `Application`/`AppProject`
  CRs are created here — those are added in a later task, which will
  register the LOP apps against this ArgoCD instance.
- CRDs installed: `applications.argoproj.io`, `applicationsets.argoproj.io`,
  `appprojects.argoproj.io`.
