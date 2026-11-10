# Политика otus-policy для доступа к секрету otus/cred
# Применение (внутри пода vault-0):
#   kubectl cp otus-policy.hcl vault/vault-0:/tmp/otus-policy.hcl
#   kubectl exec -it vault-0 -n vault -- vault policy write otus-policy /tmp/otus-policy.hcl

path "otus/cred" {
  capabilities = ["read", "list"]
}
