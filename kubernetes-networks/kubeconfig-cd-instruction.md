
## Подготовка: подключиться к внешнему кластеру

```bash
# Подключаем базовый kubeconfig (admin-доступ к кластеру winona)
export KUBECONFIG=/Users/sergeisemenov/Downloads/winona.yaml

# Проверяем подключение к API-серверу внешнего кластера
kubectl cluster-info

# Убедиться, что активен нужный контекст
kubectl config current-context        # ожидаем: admin@winona

# Создать namespace homework (если ещё не создан)
kubectl apply -f namespace.yaml
```

## Создать SA `cd` и RoleBinding на роль admin

```bash
kubectl apply -f cd.yaml
```

### Проверка

```bash
# SA создан
kubectl get serviceaccount cd -n homework

# RoleBinding создан
kubectl get rolebinding cd-admin -n homework

# Роль admin — встроенная ClusterRole (должна существовать в кластере)
kubectl get clusterrole admin

# Кому назначена роль (describe показывает subjects и roleRef)
kubectl describe rolebinding cd-admin -n homework

# Проверка фактических прав от имени SA cd (ожидается yes)
kubectl auth can-i create deployments -n homework --as=system:serviceaccount:homework:cd

# Кластерные ресурсы недоступны (ожидается no)
kubectl auth can-i create namespaces --as=system:serviceaccount:homework:cd
```

## Собрать данные кластера из базового kubeconfig

> Важно: `kubectl config view` **без** `--flatten` маскирует сертификаты
> (`DATA+OMITTED`). Флаг `--flatten` обязателен — он встраивает реальные данные.

```bash
# Адрес API-сервера активного контекста
# (ожидаем: https://178.72.167.11:6443)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "$APISERVER"

# CA-сертификат кластера (base64, inline из winona.yaml)
CA_DATA=$(kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Проверка: длина должна быть ~1400+ символов, а не 12 ("DATA+OMITTED")
echo "CA length: ${#CA_DATA}"
```

## Получить токен SA `cd`

```bash
TOKEN=$(kubectl create token cd -n homework --duration=24h)
```
## Создать kubeconfig

```bash
cat > cd.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: homework-cluster
  cluster:
    server: ${APISERVER}
    certificate-authority-data: ${CA_DATA}
users:
- name: cd
  user:
    token: ${TOKEN}
contexts:
- name: cd@homework-cluster
  context:
    cluster: homework-cluster
    user: cd
    namespace: homework
current-context: cd@homework-cluster
EOF

# Файл содержит токен — ограничиваем права доступа
chmod 600 cd.kubeconfig
```

## Проверка kubeconfig (команды проверки по заданию)

### 5.1. Файл корректен и парсится

```bash
kubectl --kubeconfig cd.kubeconfig config view
kubectl --kubeconfig cd.kubeconfig config current-context   # cd@homework-cluster
kubectl --kubeconfig cd.kubeconfig config get-contexts     # активен контекст cd@homework-cluster
```

### Переключение на контекст в текущей сессии

```bash
# Переход на kubeconfig SA cd (внешний кластер winona, но уже без админских прав)
export KUBECONFIG=$(pwd)/cd.kubeconfig
kubectl auth whoami            # system:serviceaccount:homework:cd
kubectl get pods               # namespace по умолчанию — homework

# Вернуть базовый админский kubeconfig
export KUBECONFIG=/Users/sergeisemenov/Downloads/winona.yaml
```
