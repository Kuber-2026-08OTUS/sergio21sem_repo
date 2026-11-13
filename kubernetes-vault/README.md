# ДЗ: Kubernetes + HashiCorp Vault (Consul storage backend)

Consul (3 реплики) → Vault HA (Consul storage) → init/unseal → секрет `otus/cred` → auth/kubernetes → политика и роль → External Secrets Operator (SecretStore + ExternalSecret).

Кластер managed K8s (3 ноды) в YC уже создан, `kubectl` настроен (`yc managed-kubernetes cluster get-credentials <cluster> --external`).

Все манифесты и values-файлы приложены: `consul-values.yaml`, `vault-values.yaml`, `vault-auth.yaml`, `otus-policy.hcl`, `eso-values.yaml`, `secretstore.yaml`, `externalsecret.yaml`.

## 1. Consul

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm install consul hashicorp/consul -n consul --create-namespace -f consul-values.yaml
kubectl get pods -n consul
```

## 2. Vault (HA, storage — Consul)

```bash
helm install vault hashicorp/vault -n vault --create-namespace -f vault-values.yaml
kubectl get pods -n vault
```

## 3. Init и unseal

```bash
kubectl exec -it vault-0 -n vault -- vault operator init -key-shares=1 -key-threshold=1   # сохранить ключи!
for p in vault-0 vault-1 vault-2; do kubectl exec -it $p -n vault -- vault operator unseal <UNSEAL_KEY>; done
kubectl exec -it vault-0 -n vault -- vault login <ROOT_TOKEN>
```

## 4. KV-движок `otus/` и секрет `otus/cred`

```bash
kubectl exec -it vault-0 -n vault -- vault secrets enable -path=otus kv
kubectl exec -it vault-0 -n vault -- vault kv put otus/cred username='otus' password='asajkjkahs'
kubectl exec -it vault-0 -n vault -- vault kv get otus/cred
```

## 5. ServiceAccount + ClusterRoleBinding

```bash
kubectl apply -f vault-auth.yaml   # SA vault-auth, role system:auth-delegator, Secret с токеном
```

## 6. auth/kubernetes

```bash
export SA_JWT_TOKEN=$(kubectl get secret vault-auth-token -n vault -o jsonpath="{.data.token}" | base64 --decode)
export SA_CA_CRT=$(kubectl get secret vault-auth-token -n vault -o jsonpath="{.data['ca\.crt']}" | base64 --decode)
export K8S_HOST=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

kubectl exec -it vault-0 -n vault -- vault auth enable kubernetes
kubectl exec -i vault-0 -n vault -- sh -c \
  "vault write auth/kubernetes/config token_reviewer_jwt='$SA_JWT_TOKEN' kubernetes_host='$K8S_HOST' kubernetes_ca_cert='$SA_CA_CRT'"
```

## 7. Политика `otus-policy` и 8. Роль `otus`

```bash
kubectl cp otus-policy.hcl vault/vault-0:/tmp/otus-policy.hcl
kubectl exec -it vault-0 -n vault -- vault policy write otus-policy /tmp/otus-policy.hcl

kubectl exec -it vault-0 -n vault -- sh -c \
  "vault write auth/kubernetes/role/otus bound_service_account_names=vault-auth \
   bound_service_account_namespaces=vault policies=otus-policy ttl=24h"
```

## 9. External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm install external-secrets external-secrets/external-secrets -n vault --create-namespace -f eso-values.yaml
kubectl get crd | grep external-secrets
```

## 10. SecretStore

```bash
kubectl apply -f secretstore.yaml
kubectl get secretstore vault-backend -n vault   # READY True
```

## 11. ExternalSecret

```bash
kubectl apply -f externalsecret.yaml
kubectl get externalsecret otus-cred -n vault     # READY True
kubectl get secret otus-cred -n vault -o jsonpath='{.data}' | jq .
# {"password":"YXNhamtqa2Focw==","username":"b3R1cw=="}  → otus / asajkjkahs
```

В результате в ns `vault` создан Secret `otus-cred` с ключами `username=otus` и `password=asajkjkahs` — значениями из Vault `otus/cred`.