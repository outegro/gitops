# Budget deploy runbook (budget-backend + budget-web)

All the GitOps wiring is already written and `helm template`-verified. What remains needs
**cluster access** (sealing 2 secrets) and **pushes** (which you own). Follow in order.

## What's already wired (review these diffs)

| File | Change |
|---|---|
| `manifests/cnpg/cnpg-cluster.yaml` | added `budget` managed role + `budget` Database (owner=budget) |
| `values/services/budget-backend.yaml` | new — ClusterIP, migration Job, RabbitMQ egress, Traefik→:3000 for `/socket.io` |
| `values/services/budget-web.yaml` | new — ingress `budget.outegro.com`, `extraPaths` `/socket.io`→budget-backend |
| `apps/services.yaml` | added `budget-backend` + `budget-web` ArgoCD Applications (wave 8) |
| `charts/outegro-service/templates/ingress.yaml` | added optional `ingress.extraPaths` (same-host path→other service) |
| `charts/outegro-service/values.yaml` | documented `ingress.extraPaths: []` default |
| `../6-monorepo/.github/workflows/ci.yml` | added budget-backend + budget-web to the image matrix |
| `../6-monorepo/.github/workflows/deploy.yml` | added both to the gitops tag-bump loop |

**DNS/TLS:** nothing to do — `*.outegro.com` (proxied CF → VPS) + the wildcard `outegro-wildcard-tls`
already cover `budget.outegro.com`.

**No Redis:** budget is stateless-auth (JWKS) with no sessions/rate-limit → only Postgres + RabbitMQ.

---

## Step 1 — seal 2 secrets (on a machine with cluster + kubeseal)

Fetch the controller cert once (confirm the controller ns/name for this cluster):
```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system > /tmp/pub.pem
```

### 1a. `budget-db` — CNPG role password (namespace `infra`)
Generate a strong password, keep the **raw** value for the URLs in 1b (URL-encode it there):
```bash
BUDGET_PW="$(openssl rand -base64 24 | tr -d '/+=' )"   # keep this for step 1b
cat > /tmp/budget-db.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: budget-db
  namespace: infra
  labels:
    cnpg.io/reload: "true"          # CNPG picks up rotation
type: kubernetes.io/basic-auth
stringData:
  username: budget
  password: "${BUDGET_PW}"
EOF
kubeseal --cert /tmp/pub.pem --format yaml < /tmp/budget-db.yaml \
  > manifests/sealed-secrets/budget-db.sealed.yaml
rm /tmp/budget-db.yaml
```

### 1b. `budget-backend-env` — connection URLs (namespace `platform`)
- Postgres host = CNPG rw service `outegro-rw.infra.svc:5432`, db `budget`, user `budget`.
- RabbitMQ creds = the operator's default user (fetch + URL-encode the password).
```bash
# URL-encode the DB password (safe in a URL):
BUDGET_PW_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$BUDGET_PW")"

# RabbitMQ default user/pass from the operator secret (confirm the secret name):
RMQ_USER="$(kubectl -n infra get secret rabbitmq-default-user -o jsonpath='{.data.username}' | base64 -d)"
RMQ_PW="$(kubectl -n infra get secret rabbitmq-default-user -o jsonpath='{.data.password}' | base64 -d)"
RMQ_PW_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$RMQ_PW")"
# RabbitMQ service name — confirm (e.g. rabbitmq.infra.svc): kubectl -n infra get svc | grep rabbit

DB_URL="postgresql://budget:${BUDGET_PW_ENC}@outegro-rw.infra.svc:5432/budget"
RMQ_URL="amqp://${RMQ_USER}:${RMQ_PW_ENC}@rabbitmq.infra.svc:5672"

cat > /tmp/budget-backend-env.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: budget-backend-env
  namespace: platform
type: Opaque
stringData:
  DATABASE_URL: "${DB_URL}"
  DATABASE_URL_DIRECT: "${DB_URL}"   # single instance, no pooler → same as DATABASE_URL
  RABBITMQ_URL: "${RMQ_URL}"
EOF
kubeseal --cert /tmp/pub.pem --format yaml < /tmp/budget-backend-env.yaml \
  > manifests/sealed-secrets/budget-backend-env.sealed.yaml
rm /tmp/budget-backend-env.yaml
```

Both `*.sealed.yaml` are encrypted → safe to commit to the gitops repo.

---

## Step 2 — push the app code (monorepo) so CI builds the images
On the feature branch → PR → merge to `main`. On merge, CI builds
`ghcr.io/outegro/monorepo/budget-backend:<sha>` + `budget-web:<sha>`, then `deploy.yml`
opens a gitops bump PR setting `.app.image.tag` for both (replacing the `main` placeholder).

## Step 3 — push the gitops changes (gitops repo)
Commit to `outegro/gitops`: the two sealed secrets, `cnpg-cluster.yaml`, `apps/services.yaml`,
`values/services/budget-*.yaml`, `charts/outegro-service/*`. Argo CD then, in wave order:
1. `secrets` app → controller decrypts `budget-db` + `budget-backend-env`.
2. CNPG reconciles the `budget` role + Database.
3. `budget-backend` PreSync migration Job runs `prisma migrate deploy` (creates the tables).
4. budget-backend + budget-web roll out (2 replicas each).

> Merge the gitops bump PR from Step 2 so the images point at the real SHA (not `main`).

---

## Step 4 — verify
```bash
kubectl -n argocd get applications | grep budget          # both Synced/Healthy
kubectl -n infra get database budget                      # Ready
kubectl -n platform get pods | grep budget                # 2/2 each, migrate Job Completed
curl -sI https://budget.outegro.com/ | head -1            # 200 (login gate SSR)
curl -s "https://budget.outegro.com/socket.io/?EIO=4&transport=polling" | head -c 60  # engine.io handshake → backend
```
Then interactive (real login): open budget.outegro.com → sign in via Outegro ID → add a month;
open a 2nd tab → a change in one reflects in the other (live badge = "Онлайн"). Exceed a
cumulative cap → an "over budget" Telegram alert arrives (if Telegram is linked).

## Gotchas (from prior service deploys — CLAUDE.md)
- First pod start can log "rabbit not configured" if the sealed secret syncs *after* the pod →
  `kubectl -n platform rollout restart deploy/budget-backend` once the secret exists.
- The `/socket.io` path is the ONLY budget-backend path exposed publicly (deliberate: the WS
  gateway auth-gates every connection via the og_access cookie). The REST API stays BFF-only.
