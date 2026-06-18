# RabbitMQ Cluster Operator (vendored)

`cluster-operator.yml` — **pinned** официальный манифест оператора (Namespace
`rabbitmq-system` + CRD `RabbitmqCluster` + Deployment + RBAC), вендоренный в репо
ради воспроизводимого GitOps (а не `latest` из сети).

Текущий пин: **v2.21.1**.

## Обновление версии

```bash
VER=v2.21.1   # подставь новую
curl -fsSL -o cluster-operator.yml \
  https://github.com/rabbitmq/cluster-operator/releases/download/${VER}/cluster-operator.yml
```

Коммит → Argo CD синкнет (app `rabbitmq-operator`, sync-wave 5). CRD большой →
в Application включён `ServerSideApply=true` (иначе упрётся в лимит размера
last-applied-аннотации).

Сам кластер (`RabbitmqCluster`) — в `../rabbitmq/rabbitmq.yaml` (sync-wave 7).
Ручная установка (вне GitOps) описана в `3-platform-core/MANUAL.md` шаг 9.
