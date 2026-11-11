#!/usr/bin/env bash
# =============================================================================
# node-init.sh —— 阶段 0：在模板机上执行一次，完成所有节点共用的初始化
#
# 用法（root）：
#   HARBOR_HOST=harbor.example.com ./node-init.sh
#   HARBOR_HOST=harbor.example.com K8S_MINOR=v1.37 ./node-init.sh
#
# 做了什么：
#   1. 写入集群节点的 /etc/hosts（Harbor 走公网 DNS，不写）
#   2. 关闭 swap、ufw
#   3. 加载 overlay / br_netfilter，设置 sysctl
#   4. 安装并配置 containerd（SystemdCgroup、certs.d）
#   5. docker.io 镜像经 Harbor 的 dockerhub-proxy 项目代理缓存
#   6. 安装并锁定 kubeadm / kubelet / kubectl
#   7. containerd 的 pause 镜像与 kubeadm 期望版本对齐
#   8. 配置 crictl
# 脚本可重复执行。
# =============================================================================
set -euo pipefail

: "${HARBOR_HOST:?请设置 HARBOR_HOST，例如 HARBOR_HOST=harbor.example.com}"
K8S_MINOR="${K8S_MINOR:-v1.37}"              # 以 https://kubernetes.io/releases/ 当前稳定版为准
PROXY_PROJECT="${PROXY_PROJECT:-dockerhub-proxy}"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 执行"
[[ $(uname -m) == "aarch64" ]] || echo "提示：当前架构是 $(uname -m)，本实验默认 ARM64"

# ---------- 1. /etc/hosts ----------
log "1/8 写入 /etc/hosts"
sed -i '/# BEGIN k8s-lab/,/# END k8s-lab/d' /etc/hosts
cat >>/etc/hosts <<'EOF'
# BEGIN k8s-lab
10.10.10.10 k8s-master
10.10.10.11 k8s-worker-1
10.10.10.12 k8s-worker-2
10.10.10.13 k8s-worker-3
10.10.10.20 frr-router
# END k8s-lab
EOF

# ---------- 2. swap / ufw ----------
log "2/8 关闭 swap 与 ufw"
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
if [[ -f /swap.img ]]; then rm -f /swap.img; fi
ufw disable >/dev/null 2>&1 || true

# ---------- 3. 内核模块与 sysctl ----------
log "3/8 内核模块与 sysctl"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# ---------- 4. containerd ----------
log "4/8 安装并配置 containerd"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q containerd apt-transport-https ca-certificates curl gpg

mkdir -p /etc/containerd /etc/containerd/certs.d
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# containerd 1.x 默认 config_path = ""；2.x 默认已指向 certs.d，这条 sed 不会命中，属正常
sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml

grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
  || die "SystemdCgroup 未能设置为 true，请手动检查 /etc/containerd/config.toml"

# Harbor 使用 Let's Encrypt 证书，containerd 用系统根证书即可信任，无需单独配置。

# ---------- 5. docker.io 走 Harbor 代理缓存 ----------
log "5/8 docker.io -> https://${HARBOR_HOST}/v2/${PROXY_PROJECT}"
mkdir -p /etc/containerd/certs.d/docker.io
cat >/etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://registry-1.docker.io"

[host."https://${HARBOR_HOST}/v2/${PROXY_PROJECT}"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOF

systemctl restart containerd
systemctl enable containerd >/dev/null

containerd config dump 2>/dev/null | grep -q 'config_path = "/etc/containerd/certs.d' \
  || die "config_path 未指向 /etc/containerd/certs.d，镜像代理不会生效"

# ---------- 6. kubeadm / kubelet / kubectl ----------
log "6/8 安装 kubeadm / kubelet / kubectl (${K8S_MINOR})"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
apt-get install -y -q kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet >/dev/null

# ---------- 7. pause 镜像 ----------
# apt 装的 containerd 默认 pause 版本偏旧，kubeadm 会告警 sandbox image 不一致。
# 以已安装 kubeadm 的期望版本为准（containerd 1.x 键名 sandbox_image，2.x 为 sandbox）
log "7/8 对齐 containerd 的 pause 镜像"
K8S_VERSION="$(kubeadm version -o short)"
PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "$K8S_VERSION" 2>/dev/null | grep '/pause:' || true)"
[[ -n "$PAUSE_IMAGE" ]] || die "无法从 kubeadm 获取 pause 镜像版本"
sed -ri "s#^([[:space:]]*)(sandbox_image|sandbox) = .*#\\1\\2 = \"${PAUSE_IMAGE}\"#" /etc/containerd/config.toml
grep -Eq "(sandbox_image|sandbox) = \"${PAUSE_IMAGE}\"" /etc/containerd/config.toml \
  || die "pause 镜像未能设置为 ${PAUSE_IMAGE}，请手动检查 /etc/containerd/config.toml"
systemctl restart containerd
echo "    pause 镜像：${PAUSE_IMAGE}"

# ---------- 8. crictl ----------
log "8/8 配置 crictl"
cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 30
EOF

log "完成。下一步执行 scripts/verify-node.sh 检查"
