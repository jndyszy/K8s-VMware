#!/usr/bin/env bash
# =============================================================================
# master-init.sh —— 阶段 1：在 k8s-master 上执行，初始化控制平面并安装 Calico
#
# 用法（root，在仓库根目录执行）：
#   CALICO_VER=v3.33.0 ./scripts/master-init.sh
#
# CALICO_VER 以 https://docs.tigera.io/calico/latest/release-notes/ 当前版本为准
# 输出的 join 命令保存在 /root/join-command.sh（已被 .gitignore 排除，不要提交）
# =============================================================================
set -euo pipefail

: "${CALICO_VER:?请设置 CALICO_VER，例如 CALICO_VER=v3.33.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || { echo "请用 root 执行" >&2; exit 1; }
[[ "$(hostname)" == "k8s-master" ]] || { echo "请在 k8s-master 上执行" >&2; exit 1; }

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  log "拉取控制平面镜像"
  kubeadm config images pull --config "${REPO_ROOT}/kubeadm/kubeadm.yaml"

  log "kubeadm init"
  kubeadm init --config "${REPO_ROOT}/kubeadm/kubeadm.yaml" | tee /root/kubeadm-init.log
else
  log "检测到 /etc/kubernetes/admin.conf，跳过 kubeadm init"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

CALICO_MANIFESTS="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests"

# Calico v3.30 起 CRD 从 tigera-operator.yaml 拆到单独的 operator-crds.yaml，必须先装
log "安装 Calico / Tigera Operator CRD ${CALICO_VER}"
if ! kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; then
  kubectl create -f "${CALICO_MANIFESTS}/operator-crds.yaml"
fi
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s \
  || die "CRD installations.operator.tigera.io 未就绪，检查 ${CALICO_MANIFESTS}/operator-crds.yaml 是否存在"

log "安装 Tigera Operator ${CALICO_VER}"
if ! kubectl get ns tigera-operator >/dev/null 2>&1; then
  kubectl create -f "${CALICO_MANIFESTS}/tigera-operator.yaml"
fi
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s \
  || die "tigera-operator 未就绪：kubectl -n tigera-operator describe pod"

log "应用 Calico Installation"
kubectl apply -f "${REPO_ROOT}/platform/calico/installation.yaml"

log "等待 Calico 就绪（最长 10 分钟）"
calico_ready=0
for _ in $(seq 1 60); do
  if kubectl get tigerastatus calico -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; then
    calico_ready=1
    break
  fi
  sleep 10
done
kubectl get tigerastatus || true
[[ $calico_ready -eq 1 ]] \
  || die "Calico 10 分钟内未就绪：kubectl get tigerastatus calico -o yaml；kubectl -n calico-system get pod"

log "生成 Worker join 命令 -> /root/join-command.sh"
kubeadm token create --print-join-command >/root/join-command.sh
chmod 600 /root/join-command.sh

kubectl get nodes -o wide
cat <<EOF

下一步：
  1. 把 /root/join-command.sh 的内容分别在三台 Worker 上用 root 执行
  2. 把 /etc/kubernetes/admin.conf 拷到 Mac 的 ~/.kube/config
  3. 在 Mac 上执行 scripts/post-install.sh
EOF
