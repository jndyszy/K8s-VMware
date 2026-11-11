#!/usr/bin/env bash
# shellcheck disable=SC2016  # bash -c 里的单引号是有意为之，交给子 shell 展开
# =============================================================================
# verify-node.sh —— 检查单个节点是否满足加入集群的条件
#
# 用法（root）：
#   HARBOR_HOST=harbor.example.com ./verify-node.sh
# =============================================================================
set -uo pipefail

: "${HARBOR_HOST:?请设置 HARBOR_HOST}"

pass=0; fail=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "== 系统 =="
check "swap 已关闭"                   bash -c '[[ -z "$(swapon --show)" ]]'
check "overlay 模块已加载"            bash -c 'lsmod | grep -q "^overlay"'
check "br_netfilter 模块已加载"       bash -c 'lsmod | grep -q "^br_netfilter"'
check "net.ipv4.ip_forward = 1"       bash -c '[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]'
check "bridge-nf-call-iptables = 1"   bash -c '[[ $(sysctl -n net.bridge.bridge-nf-call-iptables) == 1 ]]'
check "machine-id 非空"               bash -c '[[ -s /etc/machine-id ]]'

echo "== containerd =="
check "containerd 运行中"             systemctl is-active --quiet containerd
check "SystemdCgroup = true"          grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
check "config_path 指向 certs.d"      bash -c 'containerd config dump | grep -q "config_path = \"/etc/containerd/certs.d"'
check "docker.io 代理 hosts.toml 存在" test -f /etc/containerd/certs.d/docker.io/hosts.toml
check "pause 镜像与 kubeadm 期望一致"  bash -c 'p=$(kubeadm config images list --kubernetes-version "$(kubeadm version -o short)" 2>/dev/null | grep /pause:) && [[ -n $p ]] && grep -Eq "(sandbox_image|sandbox) = \"$p\"" /etc/containerd/config.toml'

echo "== Kubernetes 组件 =="
check "kubeadm 已安装"                command -v kubeadm
check "kubelet 已安装"                command -v kubelet
check "kubelet 已 enable"             systemctl is-enabled --quiet kubelet

echo "== 网络与 Harbor =="
check "解析 ${HARBOR_HOST}"           getent hosts "${HARBOR_HOST}"
check "HTTPS 访问 Harbor（证书可信）"  curl -fsS --max-time 10 "https://${HARBOR_HOST}/api/v2.0/ping"
check "经代理拉取 docker.io 镜像"     crictl pull docker.io/library/busybox:1.36

echo
echo "machine-id:   $(cat /etc/machine-id)"
echo "product_uuid: $(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo '需要 root')"
echo
echo "结果：${pass} 通过，${fail} 失败"
[[ $fail -eq 0 ]]
