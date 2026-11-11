#!/usr/bin/env bash
# =============================================================================
# clone-setup.sh —— 阶段 0.4：每台克隆出来的虚拟机执行一次
# 重置 machine-id 和 SSH 主机密钥、设置主机名和静态 IP。执行后会断开 SSH，用新 IP 重新连接。
#
# 用法（root）：
#   ./clone-setup.sh k8s-worker-1 10.10.10.11
#
# 可选环境变量：
#   GATEWAY=10.10.10.2   DNS=10.10.10.2   IFACE=ens160
# =============================================================================
set -euo pipefail

HOST="${1:?用法: $0 <主机名> <IP>}"
IP="${2:?用法: $0 <主机名> <IP>}"
GATEWAY="${GATEWAY:-10.10.10.2}"
DNS="${DNS:-10.10.10.2}"
IFACE="${IFACE:-$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')}"

[[ $EUID -eq 0 ]] || { echo "请用 root 执行" >&2; exit 1; }
[[ -n "$IFACE" ]] || { echo "找不到网卡，请用 IFACE= 指定" >&2; exit 1; }

echo "==> 主机名 ${HOST}，网卡 ${IFACE}，IP ${IP}/24，网关 ${GATEWAY}"

# 1. 重置 machine-id（克隆机共用同一个 ID 会导致 kubeadm/DHCP 等问题）
truncate -s0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# 2. 重新生成 SSH 主机密钥（克隆机默认共用模板机的同一套密钥）
#    当前 SSH 会话不受影响；Mac 上重连时需先 ssh-keygen -R <IP> 清掉旧的 known_hosts 记录
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A >/dev/null
systemctl try-restart ssh >/dev/null 2>&1 || true

# 3. 主机名
hostnamectl set-hostname "$HOST"
sed -i "/^127\.0\.1\.1/d" /etc/hosts
echo "127.0.1.1 ${HOST}" >>/etc/hosts

# 4. 阻止 cloud-init 覆盖网络配置
mkdir -p /etc/cloud/cloud.cfg.d
echo 'network: {config: disabled}' >/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# 5. 静态 IP：其余 netplan 文件移到备份目录
mkdir -p /etc/netplan/backup
find /etc/netplan -maxdepth 1 -name '*.yaml' ! -name '50-static.yaml' -exec mv {} /etc/netplan/backup/ \;
cat >/etc/netplan/50-static.yaml <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses: [${IP}/24]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
EOF
chmod 600 /etc/netplan/50-static.yaml

echo "==> machine-id:   $(cat /etc/machine-id)"
echo "==> product_uuid: $(cat /sys/class/dmi/id/product_uuid)"
echo "==> SSH 主机密钥已重新生成，Mac 上先执行：ssh-keygen -R ${IP}"
echo "==> 应用网络配置，SSH 会断开，请用 ${IP} 重新连接"
netplan apply
