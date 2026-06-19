# Deploy runbook — example-api + landing-web (throwaway AI-демо)

Всё, что нельзя зашить в Git (секреты с реальными паролями), создаётся **на VPS** и
запечатывается `kubeseal` → коммитится зашифрованным. Контроллер sealed-secrets живёт в
`kube-system` (release `sealed-secrets-controller`) — поэтому у kubeseal **всегда** флаги
`--controller-namespace=kube-system --controller-name=sealed-secrets-controller`
(они тянут публичный ключ прямо из кластера; никакого `sealed-secrets-pub.pem` не нужно —
это и была причина твоей ошибки `open sealed-secrets-pub.pem: no such file`).

Делается один раз. Все команды — на VPS (там, где есть `kubectl` + `kubeseal`).
Перейди в локальный клон gitops-репо, чтобы класть `*.sealed.yaml` сразу в дерево:
`cd <gitops-repo>/manifests/sealed-secrets`.

---

## 0. Хелпер: флаги kubeseal (вставь один раз в сессию)

```bash
SEAL="kubeseal --controller-namespace=kube-system --controller-name=sealed-secrets-controller --format yaml"
```

## 1. Роль/БД `example` в Postgres — секрет `example-db-app` (ns infra)

CNPG уже знает про роль `example` и базу `example` (в `cnpg-cluster.yaml`), но ждёт пароль
в секрете `example-db-app`. Генерируем пароль (без спецсимволов — чтобы не ломать URL):

```bash
EXAMPLE_PW=$(openssl rand -hex 24)

kubectl create secret generic example-db-app \
  --namespace infra \
  --type kubernetes.io/basic-auth \
  --from-literal=username=example \
  --from-literal=password="$EXAMPLE_PW" \
  --dry-run=client -o yaml \
| kubectl label --local -f - cnpg.io/reload=true -o yaml \
| $SEAL > example-db-app.sealed.yaml
```

> `cnpg.io/reload=true` обязателен — иначе CNPG не подхватит секрет роли.

## 2. Подключения example-api — секрет `example-api-env` (ns platform)

Тянем существующие пароли Redis/RabbitMQ из кластера и собираем три URL.
`$EXAMPLE_PW` — из шага 1 (та же сессия шелла).

```bash
REDIS_PW=$(kubectl -n infra get secret redis-credentials   -o jsonpath='{.data.redis-password}' | base64 -d)
RMQ_USER=$(kubectl -n infra get secret rabbitmq-default-user -o jsonpath='{.data.username}'     | base64 -d)
RMQ_PW=$(kubectl   -n infra get secret rabbitmq-default-user -o jsonpath='{.data.password}'     | base64 -d)

# URL-кодируем пароли (на случай спецсимволов в существующих секретах).
enc() { python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

DATABASE_URL="postgresql://example:$(enc "$EXAMPLE_PW")@outegro-rw.infra.svc.cluster.local:5432/example"
REDIS_URL="redis://:$(enc "$REDIS_PW")@redis-master.infra.svc.cluster.local:6379"
RABBITMQ_URL="amqp://$(enc "$RMQ_USER"):$(enc "$RMQ_PW")@rabbitmq.infra.svc.cluster.local:5672"

kubectl create secret generic example-api-env \
  --namespace platform \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --from-literal=REDIS_URL="$REDIS_URL" \
  --from-literal=RABBITMQ_URL="$RABBITMQ_URL" \
  --dry-run=client -o yaml \
| $SEAL > example-api-env.sealed.yaml
```

## 3. Ключ модели MiniMax — секрет `example-api-ai` (ns platform)

Вставь свой ключ вместо `<ВСТАВЬ_КЛЮЧ>` (он не уходит в чат, остаётся у тебя):

```bash
kubectl create secret generic example-api-ai \
  --namespace platform \
  --from-literal=MINIMAX_API_KEY='<ВСТАВЬ_КЛЮЧ>' \
  --dry-run=client -o yaml \
| $SEAL > example-api-ai.sealed.yaml
```

> Модель задаётся НЕ здесь, а env-переменной `MINIMAX_MODEL` в
> `values/services/example-api.yaml` (сейчас `MiniMax-M2.7`). Если твой ключ под другую
> модель из их `/v1/models` — поправь там это значение.

## 4. Закоммитить запечатанные секреты + всю обвязку

Три `*.sealed.yaml` зашифрованы → безопасны в Git. Коммить вместе с остальным
(чарт/чарт-values/apps/cnpg уже в этом пуше):

```bash
cd <gitops-repo>
git add manifests/sealed-secrets/example-*.sealed.yaml
git commit -m "secrets: example-api db/env/ai (sealed)"
git push
```

## 5. Дать Argo синкнуть, затем — миграция

`secrets` (wave 1) расшифрует секреты; CNPG создаст роль+БД; `example-api`/`landing-web`
(wave 8) подтянут образы из GHCR. example-api поднимется, но БД ещё пустая — таблицы нет.
Накатываем схему одноразовым Job'ом (идемпотентный, повторно безопасен):

```bash
# дождись, что секрет расшифрован (иначе Job не стартует):
kubectl -n platform get secret example-api-env

kubectl apply -f manifests/example-api-migration/job.yaml
kubectl -n platform wait --for=condition=complete job/example-api-migrate --timeout=120s
kubectl -n platform logs job/example-api-migrate          # → CREATE TABLE / CREATE INDEX

# перекатить example-api, чтобы readiness прошёл уже с таблицей:
kubectl -n platform rollout restart deploy/example-api
```

## 6. Проверка

```bash
# поды Ready (2/2 каждый):
kubectl -n platform get deploy example-api landing-web

# deep-health бэка (PG + Redis + RabbitMQ up):
kubectl -n platform exec deploy/example-api -- wget -qO- localhost:3000/health/deep

# снаружи — лендинг на outegro.com (HTML 200), генерация таглайнов через BFF:
curl -sS -o /dev/null -w '%{http_code}\n' https://outegro.com
```

Затем в браузере на **https://outegro.com**: ввести промпт → «Сгенерировать» →
job уходит в RabbitMQ → воркер зовёт MiniMax → 5 таглайнов появляются (поллинг 1.5s).
Бейдж статистики (`/api/taglines/stats`) обновляется каждые 5s.

---

### Если что-то не так
- **example-api CrashLoopBackOff** до шага 1–2: ожидаемо — Zod fail-fast без `example-api-env`.
  Появится секрет → `selfHeal` поднимет под сам (или `rollout restart`).
- **Job падает с `relation already exists`**: не должно (всё через `IF NOT EXISTS`/guard);
  если падает на роли — проверь, что CNPG создал роль `example` (`kubectl -n infra get role`
  в логах кластера) и что пароль в `example-db-app` совпал.
- **502/пустой ответ на outegro.com**: проверь `kubectl -n platform get ingress` и что
  `outegro-wildcard-tls` есть в `platform` (cert-manager его выпускает туда).
- **Образов нет в GHCR**: CI собирает их по пушу в `outegro/monorepo`. Проверь Actions;
  теги уже зафиксированы в `values/services/*.yaml` (полный SHA).
