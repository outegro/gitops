# Sealed Secrets (GitOps-managed)

Сюда кладутся **запечатанные** секреты (`*.sealed.yaml`) — они зашифрованы публичным
ключом контроллера и **безопасны в Git** (CLAUDE.md: «Sealed Secrets — единственный
способ передать секрет в кластер; никаких plaintext Secret в Git»).

Контроллер (Argo app `sealed-secrets`, sync-wave 0) расшифровывает их в обычные
`Secret` в целевых namespace'ах. Argo app `secrets` (wave 1) держит их
синхронизированными — это single-source-of-truth и disaster-recovery.

## Что сюда положить

После шага 5 главы 3 (где ты их запечатал) скопируй сюда `*.sealed.yaml`:

| Файл | Namespace | Потребитель |
|---|---|---|
| `cloudflare-api-token.sealed.yaml` | cert-manager | ClusterIssuer (DNS-01) |
| `app-password.sealed.yaml` | infra | CNPG роль `app` |
| `r2-credentials.sealed.yaml` | infra | CNPG → бэкап в R2 (`outegro-backups`) |
| `redis-credentials.sealed.yaml` | infra | Redis auth |
| `grafana-credentials.sealed.yaml` | observability | Grafana admin |
| `ghcr-pull.sealed.yaml` | platform | pull приватных образов `ghcr.io/outegro/*` |
| `example-db-app.sealed.yaml` | infra | CNPG роль `example` (throwaway example-api) |
| `example-api-env.sealed.yaml` | platform | example-api: DATABASE_URL/REDIS_URL/RABBITMQ_URL |
| `example-api-ai.sealed.yaml` | platform | example-api: `MINIMAX_API_KEY` (ключ модели) |

> RabbitMQ-секрета здесь нет — его генерит оператор (`rabbitmq-default-user`).
> Три `example-*` секрета — для throwaway-демо (глава 6). Как их запечатать —
> в `manifests/example-api-migration/RUNBOOK.md`.

## Bootstrap vs GitOps

Глава 3 применяет эти секреты **вручную** (`kubectl apply`) — потому что они нужны
ДО того, как существует Argo CD (cert-manager/CNPG поднимаются в главе 3). Когда
позже синкнется app `secrets`, он просто **усыновит** уже существующие SealedSecret
(оба применения декларативны и сходятся). Поэтому здесь `prune: false` — удаление
файла НЕ удаляет живой секрет автоматически (защита от случайного сноса).

⚠️ Plaintext-шаблоны (`*.template.yaml`) лежат в `docs/secrets/templates/` скаффолда и сюда НЕ копируются — только запечатанные `*.sealed.yaml`.
