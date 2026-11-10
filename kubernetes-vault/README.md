# Репозиторий для выполнения домашних заданий курса "Инфраструктурная платформа на основе Kubernetes-2026-08" 

# ДЗ: Kubernetes + HashiCorp Vault (Consul storage backend)

Развертывание managed Kubernetes в Yandex Cloud, установка Consul (3 реплики) и Vault в HA-режиме с хранением в Consul, инициализация, настройка auth/kubernetes и политик.

## Содержимое

| Файл | Назначение |
|---|---|
| `consul-values.yaml` | Параметры установки Consul (3 реплики сервера) |
| `vault-values.yaml` | Параметры установки Vault в HA-режиме с Consul storage |
| `vault-auth.yaml` | ServiceAccount `vault-auth`, ClusterRoleBinding `system:auth-delegator`, Secret с токеном |
| `otus-policy.hcl` | Политика Vault для секрета `otus/cred` |
| `eso-values.yaml` | Параметры установки External Secrets Operator |
| `secretstore.yaml` | SecretStore — подключение ESO к Vault через kubernetes auth |
| `externalsecret.yaml` | ExternalSecret — синхронизация `otus/cred` в Secret `otus-cred` |

## 1. Managed Kubernetes cluster в Yandex Cloud (3 ноды)

```bash
# Создать кластер
yc managed-kubernetes cluster create otus-vault-cluster \
  --network-id=<network-id> --zone ru-central1-a \
  --public-ip \
  --service-account-name <sa-name> --node-service-account-name <sa-name> \
  --version 1.30

# Создать группу из 3 нод
yc managed-kubernetes node-group create otus-vault-ng \
  --cluster-name otus-vault-cluster --zone ru-central1-a \
  --network-interface security-group-ids=<sg-id>,subnets=<subnet-id> \
  --cores 4 --memory 8 --core-fraction 100 \
  --disk-type network-ssd --disk-size 100 \
  --fixed-size 3

# Получить kubeconfig для kubectl
yc managed-kubernetes cluster get-credentials otus-vault-cluster --external
```

## 2. Установка Consul (namespace `consul`, 3 реплики сервера)

Чарт: https://github.com/hashicorp/consul-k8s

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install consul hashicorp/consul \
  --namespace consul --create-namespace \
  -f consul-values.yaml
```

Проверка:

```bash
kubectl get pods -n consul
# consul-server-0  consul-server-1  consul-server-2 — Running, 1/1
```

## 3. Установка Vault (namespace `vault`, HA + Consul storage)

Чарт: https://github.com/hashicorp/vault-helm

```bash
helm install vault hashicorp/vault \
  --namespace vault --create-namespace \
  -f vault-values.yaml
```

Проверка:

```bash
kubectl get pods -n vault
# vault-0  vault-1  vault-2 — Running, 0/1 (Sealed)

kubectl exec -it vault-0 -n vault -- vault status
```

## 4. Инициализация Vault и unseal всех подов

```bash
# Инициализация (выполняется один раз, на vault-0)
kubectl exec -it vault-0 -n vault -- vault operator init -key-shares=1 -key-threshold=1
# Сохранить Unseal Key и Root Token!

# Распечатать каждый под (unseal-ключ общий, т.к. общее хранилище Consul)
kubectl exec -it vault-0 -n vault -- vault operator unseal <UNSEAL_KEY>
kubectl exec -it vault-1 -n vault -- vault operator unseal <UNSEAL_KEY>
kubectl exec -it vault-2 -n vault -- vault operator unseal <UNSEAL_KEY>

# Войти root-токеном (на каждом поде, где нужно выполнять команды)
kubectl exec -it vault-0 -n vault -- vault login <ROOT_TOKEN>
```

## 5. Secret Engine KV и секрет `otus/cred`

```bash
# Включить KV-движок по пути otus/
kubectl exec -it vault-0 -n vault -- vault secrets enable -path=otus kv

# Создать секрет otus/cred
kubectl exec -it vault-0 -n vault -- \
  vault kv put otus/cred username='otus' password='asajkjkahs'

# Проверить
kubectl exec -it vault-0 -n vault -- vault kv get otus/cred
```

## 6. ServiceAccount `vault-auth` и ClusterRoleBinding

Манифест — `vault-auth.yaml`:

```bash
kubectl apply -f vault-auth.yaml
```

Содержит:
- `ServiceAccount/vault-auth` в namespace `vault`;
- `ClusterRoleBinding/role-tokenreview-binding` с ролью `system:auth-delegator` (даёт Vault право проверять токены через TokenReview API);
- `Secret/vault-auth-token` — долгоживущий токен SA (с Kubernetes 1.24 токены автоматически не генерируются).

## 7. Настройка auth/kubernetes

```bash
# Извлечь токен и сертификат CA из Secret'а ServiceAccount
export SA_JWT_TOKEN=$(kubectl get secret vault-auth-token -n vault \
  -o jsonpath="{.data.token}" | base64 --decode)
export SA_CA_CRT=$(kubectl get secret vault-auth-token -n vault \
  -o jsonpath="{.data['ca\.crt']}" | base64 --decode)

# Адрес API-сервера кластера
export K8S_HOST=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# Включить метод аутентификации kubernetes
kubectl exec -it vault-0 -n vault -- vault auth enable kubernetes

# Сконфигурировать его токеном и сертификатом ServiceAccount vault-auth
kubectl exec -i vault-0 -n vault -- sh -c \
  "vault write auth/kubernetes/config \
    token_reviewer_jwt='$SA_JWT_TOKEN' \
    kubernetes_host='$K8S_HOST' \
    kubernetes_ca_cert='$SA_CA_CRT'"
```

> Конфигурация auth/kubernetes хранится в Consul storage — поэтому общая для `vault-0`, `vault-1` и `vault-2`, отдельно настраивать их не нужно.

## 8. Политика `otus-policy`

Файл — `otus-policy.hcl`. Применение:

```bash
kubectl cp otus-policy.hcl vault/vault-0:/tmp/otus-policy.hcl
kubectl exec -it vault-0 -n vault -- vault policy write otus-policy /tmp/otus-policy.hcl

# Проверить
kubectl exec -it vault-0 -n vault -- vault policy read otus-policy
```

## 9. Роль `auth/kubernetes/role/otus`

Роль связывает SA `vault-auth` из ns `vault` с политикой `otus-policy`:

```bash
kubectl exec -it vault-0 -n vault -- sh -c \
  "vault write auth/kubernetes/role/otus \
    bound_service_account_names=vault-auth \
    bound_service_account_namespaces=vault \
    policies=otus-policy ttl=24h"

# Проверить
kubectl exec -it vault-0 -n vault -- vault read auth/kubernetes/role/otus
```

## 10. Установка External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace vault --create-namespace \
  -f eso-values.yaml
```

Проверка (CRD устанавливаются чартом автоматически):

```bash
kubectl get pods -n vault | grep external-secrets
kubectl get crd | grep external-secrets
# external-secrets, clustersecretstores, secretstores, ...
```

## 11. SecretStore

Манифест — `secretstore.yaml`:

```bash
kubectl apply -f secretstore.yaml
```

Конфигурация:
- `server: http://vault.vault.svc:8200` — endpoint Vault (TLS отключён);
- `path: otus`, `version: v1` — KV v1 Secret Engine, созданный в шаге 5
  (`vault secrets enable -path=otus kv` создаёт именно KV **версии 1**);
- `auth.kubernetes.role: otus` — роль из шага 9;
- `serviceAccountRef: vault-auth` — SA из шага 6 (реализует вход через auth/kubernetes).

Проверка, что SecretStore успешно подключился к Vault:

```bash
kubectl get secretstore vault-backend -n vault
# NAME           AGE   READY   CAPABILITIES
# vault-backend  30s   True    Read

kubectl describe secretstore vault-backend -n vault
# в Events не должно быть ошибок авторизации
```

Если `READY False` — `kubectl describe secretstore` покажет причину
(обычно неверный `version` KV или ошибка роли/SA в Vault).

> Примечание: для `serviceAccountRef` контроллер ESO запрашивает токен
> для SA через TokenRequest API. Если у контроллера нет права `create`
> на `serviceaccounts/token` (в актуальных версиях чарта есть по умолчанию),
> можно указать статический токен из Secret `vault-auth-token` вместо
> `serviceAccountRef`:
>
> ```yaml
> # вместо serviceAccountRef:
> tokenSecretRef:
>   name: vault-auth-token
>   key: token
> ```

## 12. ExternalSecret `otus-cred`

Манифест — `externalsecret.yaml`:

```bash
kubectl apply -f externalsecret.yaml
```

Проверка:

```bash
kubectl get externalsecret otus-cred -n vault
# NAME       STORE           REFRESH INTERVAL  READY
# otus-cred  vault-backend   1h                True

kubectl get secret otus-cred -n vault
# NAME       TYPE     DATA
# otus-cred  Opaque   2

kubectl get secret otus-cred -n vault -o jsonpath='{.data}' | jq .
# {
#   "password": "YXNhamtqa2Focw==",
#   "username": "b3R1cw=="
# }
echo 'b3R1cw==' | base64 -d      # otus
echo 'YXNhamtqa2Focw==' | base64 -d   # asajkjkahs
```

После применения ExternalSecret в ns `vault` создан Secret `otus-cred`
с ключами `username=otus` и `password=asajkjkahs` — теми же значениями,
что сохранены в Vault по пути `otus/cred`.

### Быстрая проверка входа через kubernetes auth (из тестового пода)

```bash
kubectl run test-vault --image=alpine:3 -n vault \
  --serviceaccount=vault-auth --restart=Never -it --rm -- sh
```

```sh
# внутри пода:
 apk add curl jq
 VAULT_ADDR=http://vault.vault.svc:8200
 TOKEN=$(curl -s --request POST --data \
   '{"jwt":"'"$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"'","role":"otus"}' \
   $VAULT_ADDR/v1/auth/kubernetes/login | jq -r .auth.client_token)
 curl -s -H "X-Vault-Token: $TOKEN" $VAULT_ADDR/v1/otus/cred
```

Ожидаемый результат — JSON с `username: otus` и `password: asajkjkahs`.