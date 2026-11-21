helm repo add bitnamicharts oci://registry-1.docker.io/bitnamicharts

helm upgrade --install kafka oci://registry-1.docker.io/bitnamicharts/kafka \
  --version 24.0.14 -n prod --create-namespace -f prod-values.yaml

helm upgrade --install kafka oci://registry-1.docker.io/bitnamicharts/kafka \
  --version 32.4.3 -n dev --create-namespace -f dev-values.yaml
