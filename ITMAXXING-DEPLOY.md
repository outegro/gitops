# itmaxxing deploy runbook (itmaxxing-backend + itmaxxing-web)

Mirrors `BUDGET-DEPLOY.md`. All GitOps wiring is already written and `helm template`-verified.
What remains needs **cluster access** (sealing 2 secrets) and **pushes** (which you own).

## What's already wired (review these diffs)

| File | Change |
|---|---|
| `manifests/cnpg/cnpg-cluster.yaml` | added `itmaxxing` managed role + `itmaxxing` Database (owner=itmaxxing) |
| `values/services/itmaxxing-backend.yaml` | new — ClusterIP, migration Job, LLM egress (MiniMax) |
| `values/services/itmaxxing-web.yaml` | new — ingress `itmaxxing.outegro.com`, plain host (no WS, no extraPaths) |
| `apps/services.yaml` | added `itmaxxing-backend` + `itmaxxing-web` ArgoCD Applications (wave 8) |
| `../6-monorepo/.github/workflows/ci.yml` | added itmaxxing-backend + itmaxxing-web to the image matrix |
| `../6-monorepo/.github/workflows/deploy.yml` | added both to the gitops tag-bump loop |

**DNS/TLS:** nothing to do — `*.outegro.com` (proxied CF → VPS) + the wildcard `outegro-wildcard-tls`
already cover `itmaxxing.outegro.com`.

**No Redis, no RabbitMQ:** itmaxxing is stateless-auth (JWKS) with no sessions/rate-limit/events →
only Postgres + an outbound call to MiniMax over the internet.

---

## Step 1 — seal 2 secrets (on a machine with cluster + kubeseal)

Fetch the controller cert once (skip if you still have `/tmp/pub.pem` from the budget deploy):
```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system > /tmp/pub.pem
```

### 1a. `itmaxxing-db` — CNPG role password (namespace `infra`)
```bash
ITMAXXING_PW="$(openssl rand -base64 24 | tr -d '/+=')"   # keep this for step 1b
cat > /tmp/itmaxxing-db.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: itmaxxing-db
  namespace: infra
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: itmaxxing
  password: "${ITMAXXING_PW}"
EOF
kubeseal --cert /tmp/pub.pem --format yaml < /tmp/itmaxxing-db.yaml \
  > manifests/sealed-secrets/itmaxxing-db.sealed.yaml
rm /tmp/itmaxxing-db.yaml
```

### 1b. `itmaxxing-backend-env` — connection URL + LLM key (namespace `platform`)
- Postgres host = CNPG rw service `outegro-rw.infra.svc:5432`, db `itmaxxing`, user `itmaxxing`.
- `LLM_API_KEY` = the **same MiniMax key already used by edu-backend** — fetch it rather than
  re-typing:
```bash
kubectl -n platform get secret edu-backend-env -o jsonpath='{.data.LLM_API_KEY}' | base64 -d
```
```bash
ITMAXXING_PW_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$ITMAXXING_PW")"
DB_URL="postgresql://itmaxxing:${ITMAXXING_PW_ENC}@outegro-rw.infra.svc:5432/itmaxxing"
LLM_KEY="$(kubectl -n platform get secret edu-backend-env -o jsonpath='{.data.LLM_API_KEY}' | base64 -d)"

cat > /tmp/itmaxxing-backend-env.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: itmaxxing-backend-env
  namespace: platform
type: Opaque
stringData:
  DATABASE_URL: "${DB_URL}"
  DATABASE_URL_DIRECT: "${DB_URL}"   # single instance, no pooler → same as DATABASE_URL
  LLM_API_KEY: "${LLM_KEY}"
EOF
kubeseal --cert /tmp/pub.pem --format yaml < /tmp/itmaxxing-backend-env.yaml \
  > manifests/sealed-secrets/itmaxxing-backend-env.sealed.yaml
rm /tmp/itmaxxing-backend-env.yaml
```
> ⚠️ CLAUDE.md invariant: API keys in env must be `.trim()`'d on the app side (already done in
> `itmaxxing-backend/src/config/env.validation.ts`) — but also make sure you didn't paste a
> trailing newline when copying `$LLM_KEY` manually if you deviate from the command above.

No plaintext secret is committed — both `*.sealed.yaml` are encrypted, safe to commit.

---

## Step 2 — push the app code (monorepo) so CI builds the images
On the feature branch → PR → merge to `main`. On merge, CI builds
`ghcr.io/outegro/monorepo/itmaxxing-backend:<sha>` + `itmaxxing-web:<sha>`, then `deploy.yml`
opens a gitops bump PR setting `.app.image.tag` for both (replacing the `main` placeholder).

## Step 3 — push the gitops changes (gitops repo)
Commit to `outegro/gitops`: the two sealed secrets, `cnpg-cluster.yaml`, `apps/services.yaml`,
`values/services/itmaxxing-*.yaml`. Argo CD then, in wave order:
1. `secrets` app → controller decrypts `itmaxxing-db` + `itmaxxing-backend-env`.
2. CNPG reconciles the `itmaxxing` role + Database.
3. `itmaxxing-backend` PreSync migration Job runs `prisma migrate deploy` (creates
   `profiles`/`lore_entries`/`generations`).
4. itmaxxing-backend + itmaxxing-web roll out (2 replicas each).

> Merge the gitops bump PR from Step 2 so the images point at the real SHA (not `main`).

---

## Step 4 — verify
```bash
kubectl -n argocd get applications | grep itmaxxing       # both Synced/Healthy
kubectl -n infra get database itmaxxing                   # Ready
kubectl -n platform get pods | grep itmaxxing              # 2/2 each, migrate Job Completed
curl -sI https://itmaxxing.outegro.com/ | head -1          # 200 (login gate SSR)
curl -s https://itmaxxing.outegro.com/api/itmaxxing/lore/status  # 401 without cookie (BFF proxy alive)
```
Then interactive (real login): open itmaxxing.outegro.com → sign in via Outegro ID → paste a
career brain-dump → "Review with AI" → split view (sharpened text + red flags) should return
within `maxDuration=120` → accept → structured entries land on `/lore`.

## Gotchas (from prior service deploys — CLAUDE.md)
- First pod start can log `LLM disabled`/`llm_disabled` if the sealed secret syncs *after* the
  pod → `kubectl -n platform rollout restart deploy/itmaxxing-backend` once the secret exists.
- `LLM_MODEL=MiniMax-M2` is a reasoning model (`<think>…</think>` wrapper stripped in
  `llm.service.ts`) — if MiniMax ever serves a different model under the same key, verify
  `POST /v1/chat/completions` responds before assuming the deploy is broken.
- itmaxxing-backend has **zero unit tests** right now — deploy is verified by the manual browser
  flow above, not by CI green (unlike auth-backend).
