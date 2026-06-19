# Глава 5 — GitOps (Argo CD app-of-apps)

Переводит ручную установку глав 3–4 под Argo CD. Содержимое этой папки (`apps/`, `bootstrap/`, `manifests/`, `values/`, `.gitignore`) = **корень приватного репо** `outegro/gitops`.

Argo усыновляет уже стоящие ресурсы — поэтому release-name / namespace / values тут совпадают с главами 3–4.

## Как устроено

- `bootstrap/root.yaml` — `AppProject outegro` + корневой Application, рекурсивно тянет `apps/*.yaml`.
- `apps/*.yaml` — по одному Application на компонент, порядок через `sync-wave`.
- Helm-компоненты: внешний чарт + `$values` из gitops-репо (multi-source). Не-Helm (Redis, RabbitMQ-оператор, barman-plugin, CRD) — plain/вендоренные манифесты.

## Инварианты (уже зашиты в файлы — проверь перед bootstrap)

| Application | Настройка | Зачем |
|-------------|-----------|-------|
| `sealed-secrets` | `helm.releaseName: sealed-secrets-controller` | совпасть с ручным релизом — иначе immutable-селектор |
| `cnpg-crds` | `ServerSideApply=true`, `prune:false` | CRD ~1МБ не лезет в client-side |
| `cnpg-operator` | `helm.releaseName: cnpg`, `crds.create:false`, ns `cnpg-system`, `ServerSideApply=true` | совпасть с ручным релизом; ns = где живёт barman-plugin |
| `cnpg-cluster` | `ServerSideApply=true` + аннотация `compare-options: ServerSideDiff=true` | оператор раздувает `Cluster.spec` (~8→35 параметров) → без SSDiff вечный ложный OutOfSync |
| `prometheus` | `ServerSideApply=true` + аннотация `compare-options: ServerSideDiff=true` | большие CRD дают ложный OutOfSync на client-side diff |
| `traefik-default-tls` | Certificate + `TLSStore default` в `kube-system` (ns Traefik) | дефолтный origin-серт; иначе self-signed → Cloudflare Full-strict 526 |
| `argocd` | без блока `automated` | авто-self-heal Argo по себе ронял контрол-плейн |
| argocd values | controller/repoServer 2Gi + GOMEMLIMIT | OOM на больших манифестах |

## 1. Подготовить репо (перед commit)

```bash
cd ~/outegro-minimax/5-gitops

# запечатанные секреты из главы 3 должны лежать тут (а не только README):
ls manifests/sealed-secrets/*.sealed.yaml   # cloudflare, app-password, r2, redis, grafana, ghcr-pull
```

Залей содержимое в приватный репо `git@github.com:outegro/gitops.git` (в корень — `apps/ bootstrap/ manifests/ values/`).

## 2. Repo-credential для Argo

Заведён в главе 4 (deploy key + OCI-репо). Проверка:

```bash
kubectl -n argocd get secret outegro-gitops-repo -o jsonpath='{.metadata.labels}'; echo
kubectl -n argocd get secret repo-jetstack-oci
kubectl -n argocd get configmap argocd-ssh-known-hosts-cm \
  -o jsonpath='{.data.ssh_known_hosts}' | grep github.com
```

## 3. Применить root app

```bash
kubectl apply -f bootstrap/root.yaml
kubectl -n argocd get appproject outegro
kubectl -n argocd get applications
```

## 4. Дождаться конвергенции (~19 apps, все Synced/Healthy)

```bash
watch -n5 'kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

```text
outegro-root  sealed-secrets  secrets  cert-manager  cluster-issuers  traefik-default-tls
certificates  cnpg-crds  cnpg-operator  barman-cloud-plugin  cnpg-cluster  redis
rabbitmq-operator  rabbitmq  prometheus  loki  alloy  prometheus-rules  argocd
```

> `traefik-default-tls` (wave 3) выпускает wildcard в `kube-system` и ставит `TLSStore default` →
> Traefik отдаёт `*.outegro.com` как **дефолтный** серт origin'а. Без него любой хост без своего Ingress
> (апекс `outegro.com`, ещё-не-задеплоенные сабдомены) отдаёт self-signed → Cloudflare Full(strict) = **526**.
> Проверка: `echo | openssl s_client -connect <IP>:443 -servername outegro.com 2>/dev/null | openssl x509 -noout -subject`
> → `CN=*.outegro.com`; снаружи `curl -sI https://outegro.com` → 404 от Traefik (не 526).

## 5. Если что-то OutOfSync

```bash
# какие ресурсы дрейфуют:
kubectl -n argocd get application <app> \
  -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}{.kind}/{.name}{"\n"}{end}'
# залипшая операция:
kubectl -n argocd patch application <app> --type merge -p '{"operation":null}'
# ручной sync без force; force несовместим с ServerSideApply:
kubectl -n argocd patch application <app> --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{}}}}}'
```

### `argocd` self-app остаётся OutOfSync после bootstrap — это НОРМА, нужен разовый adopt

Argo CD ставился руками `helm` (глава 4) → live ConfigMap'ы/Secret'ы несут helm-метаданные ≠ rendered,
а у app `argocd` намеренно НЕТ `automated` sync (авто-self-heal по себе ронял argocd). Усынови **разово**
(стратегия `apply` = 3-way merge, НЕ replace/force — runtime-ключи `argocd-secret` server.secretkey/admin
сохраняются, поды не рестартят в краш):

```bash
kubectl -n argocd patch application argocd --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{}}}}}'
# через ~15с → Synced/Healthy
```

## Готово, когда

```bash
kubectl -n argocd get applications | awk 'NR==1 || $2!="Synced" || $3!="Healthy"'   # только заголовок
kubectl get pods -A | awk 'NR==1 || ($4!="Running" && $4!="Completed")'             # пусто
```

Rollback = `git revert` в gitops-репо. Image-теги в `main` не пушим руками — это делает CI монорепо через PR.

> R2-бэкап Postgres **включён**: `barman-cloud-plugin` (wave 4) → `cnpg-backup.yaml` (ObjectStore + ScheduledBackup) + `plugins`-блок в `cnpg-cluster.yaml`, бакет `s3://outegro-backups`. Нужен sealed-secret `r2-credentials` в `infra` (из главы 3). Проверка архивации — `kubectl -n infra get cluster outegro -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'` → True.
