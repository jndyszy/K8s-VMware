#!/usr/bin/env bash
# =============================================================================
# post-install.sh —— 阶段 1.4 / 1.6：4 个节点都加入后，在 Mac 上执行
#   - 给 Worker 打角色标签
#   - 安装 local-path-provisioner 并设为默认 StorageClass
#   - 安装 metrics-server
#   - 创建 lab 命名空间和 Harbor 拉取凭据
#
# 依赖：kubectl、helm（brew install kubectl helm），~/.kube/config 已指向集群
#
# 用法（在仓库根目录）：
#   HARBOR_HOST=harbor.example.com LOCAL_PATH_VER=v0.0.37 ./scripts/post-install.sh
#
# LOCAL_PATH_VER 以 https://github.com/rancher/local-path-provisioner/releases 为准
# 兼容 macOS 自带的 bash 3.2
# =============================================================================
set -euo pipefail

: "${HARBOR_HOST:?请设置 HARBOR_HOST}"
: "${LOCAL_PATH_VER:?请设置 LOCAL_PATH_VER，例如 v0.0.37}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

command -v kubectl >/dev/null || { echo "缺少 kubectl" >&2; exit 1; }
command -v helm    >/dev/null || { echo "缺少 helm" >&2; exit 1; }

log "检查节点"
kubectl get nodes -o wide
NOT_READY=$(kubectl get nodes --no-headers | awk '$2!="Ready"' | wc -l | tr -d ' ')
if [ "$NOT_READY" != "0" ]; then
  echo "有 ${NOT_READY} 个节点未 Ready，先排查再继续" >&2
  exit 1
fi

log "Worker 角色标签"
for n in k8s-worker-1 k8s-worker-2 k8s-worker-3; do
  kubectl label node "$n" node-role.kubernetes.io/worker= --overwrite
done

log "local-path-provisioner ${LOCAL_PATH_VER}"
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VER}/deploy/local-path-storage.yaml"
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

log "metrics-server"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system -f "${REPO_ROOT}/platform/metrics-server/values.yaml" --wait

log "lab 命名空间与 Harbor 拉取凭据"
kubectl create namespace lab --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n lab get secret harbor-pull >/dev/null 2>&1; then
  echo "harbor-pull 已存在，跳过（需要更新请先删除）"
else
  # 交互输入，不留在 shell 历史里
  printf "Harbor 机器人账号用户名（如 robot\$k8s-pull）: "
  read -r PULL_USER
  printf "Token: "
  read -rs PULL_TOKEN
  echo
  # Token 只经过 shell 内建 printf 和管道传给 kubectl，不出现在任何进程的命令行参数里
  # （kubectl create secret docker-registry --docker-password=... 会被 ps 看到）
  PULL_AUTH=$(printf '%s:%s' "$PULL_USER" "$PULL_TOKEN" | base64 | tr -d '\n')
  DOCKER_CFG=$(printf '{"auths":{"%s":{"username":"%s","password":"%s","auth":"%s"}}}' \
    "$HARBOR_HOST" "$PULL_USER" "$PULL_TOKEN" "$PULL_AUTH" | base64 | tr -d '\n')
  printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"harbor-pull","namespace":"lab"},"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":"%s"}}' \
    "$DOCKER_CFG" | kubectl create -f -
  unset PULL_TOKEN PULL_AUTH DOCKER_CFG
fi
kubectl -n lab patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"harbor-pull"}]}'

log "完成"
kubectl get storageclass
echo
echo "约 1 分钟后可执行：kubectl top nodes"
echo "然后运行 ./scripts/verify-cluster.sh 做阶段 1 验收"
