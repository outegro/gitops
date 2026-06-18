# outegro/gitops

Корень GitOps-репозитория Argo CD для платформы outegro (single-node k3s).

- `bootstrap/root.yaml` — app-of-apps (`kubectl apply -f bootstrap/root.yaml`).
- `apps/` — Application на каждый компонент (порядок через sync-wave).
- `manifests/` — plain/вендоренные манифесты + запечатанные секреты.
- `values/` — Helm values для внешних чартов.

Пошаговая установка и инварианты — в `MANUAL.md` (глава 5 скаффолда).
Rollback — `git revert`.
