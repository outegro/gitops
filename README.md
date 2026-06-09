# outegro/gitops

GitOps source of truth for the Outegro cluster. Reconciled by **ArgoCD** (running in
namespace `infra` on VPS1). Public repo — ArgoCD pulls it anonymously over HTTPS.

## Layout

```
bootstrap/        one-time root Application (app-of-apps), applied by hand once
apps/             ArgoCD Applications, one per platform component (auto-discovered, recursed)
infra/            raw manifests that some Applications point at (issuers, certs, sealed secrets)
```

## Conventions

- All infra components pin to VPS1: `nodeSelector: {role: infra}` + toleration for the
  `role=infra:NoSchedule` taint. App workloads live on VPS2 (`role=apps`).
- Ordering via `argocd.argoproj.io/sync-wave` annotations on the Applications.
- Secrets are **Sealed Secrets** only — never commit plaintext. Sealed with the controller
  in `infra` (`kubeseal --controller-namespace infra --controller-name sealed-secrets-controller`).

## Bootstrap

```bash
kubectl apply -f bootstrap/root.yaml      # creates the app-of-apps; ArgoCD does the rest
```
