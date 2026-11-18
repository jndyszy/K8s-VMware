#!/usr/bin/env bash
# =============================================================================
# verify-hybrid.sh —— 阶段 5 验收，在 Mac 上执行（兼容 macOS 自带 bash 3.2）
#   WireGuard 隧道、隧道上的 eBGP、双向路由、源地址、云 ↔ 实验网端到端、BGP 监控、Terraform 无漂移
#
# 前提：~/.ssh/config 中有 frr-router、aliyun-edge、k8s-master、k8s-worker-1..3 别名，均可免密登录
# 可选：设置了 ALIBABA_CLOUD_ACCESS_KEY_ID/SECRET 与 TF_VAR_edge_instance_id 时，额外检查 terraform plan 无变更
# 用法（在仓库根目录）：./scripts/verify-hybrid.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
WORKERS="k8s-worker-1 k8s-worker-2 k8s-worker-3"
TUN_LOCAL=10.255.255.1
TUN_CLOUD=10.255.255.2
VPC_CIDR=172.16.0.0/12
PROM=/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1

pass=0; fail=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
rt()  { $SSH frr-router "$1"; }
ecs() { $SSH aliyun-edge "$1"; }

for h in frr-router aliyun-edge k8s-master $WORKERS; do
  $SSH "$h" true 2>/dev/null || { echo "无法 SSH 到 ${h}，请先检查 ~/.ssh/config 与密钥" >&2; exit 1; }
done
# ECS 的 VPC 地址：从 eth0 读取，不写死在脚本里
ECS_VPC_IP=$(ecs "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1")

echo "== WireGuard 隧道 =="
# 有流量（含 25 秒保活）时约每 2 分钟重新握手一次；超过 3 分钟没有握手说明隧道断了
age=$(rt "now=\$(date +%s); hs=\$(wg show wg0 latest-handshakes | awk '{print \$2}'); [ -n \"\$hs\" ] && [ \"\$hs\" -gt 0 ] && echo \$((now-hs)) || echo -1")
if [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -lt 180 ]; then ok "最近一次握手 ${age} 秒前"; else bad "隧道没有有效握手（latest handshake: ${age}）"; fi
check "路由器经 wg0 到达隧道对端（不是被默认路由送走）" \
  bash -c "$SSH frr-router 'ip route get ${TUN_CLOUD}' | grep -q 'dev wg0'"
check "隧道内 ping 通 ${TUN_CLOUD}" bash -c "$SSH frr-router 'ping -c2 -W2 ${TUN_CLOUD}'"
check "ECS 的 wg-quick@wg0 开机自启" bash -c "$SSH aliyun-edge 'systemctl is-enabled wg-quick@wg0' | grep -qx enabled"
check "ECS 没有被 WireGuard 抢走默认路由（Table = off）" \
  bash -c "$SSH aliyun-edge 'ip route show default' | grep -q 'dev eth0'"

echo "== 隧道上的 eBGP =="
st=$(rt "vtysh -c 'show bgp ipv4 unicast summary json' | jsonfilter -e '@.peers[\"${TUN_CLOUD}\"].state'")
if [ "$st" = "Established" ]; then ok "路由器 ↔ aliyun-edge（AS 64600）Established"; else bad "云上邻居状态：${st:-无}"; fi
check "路由器学到 ${VPC_CIDR}，下一跳在 wg0" \
  bash -c "$SSH frr-router 'ip route show ${VPC_CIDR}' | grep -q 'dev wg0'"
cloud_rx=$(ecs "vtysh -c 'show bgp ipv4 unicast' | awk '/^ *\\*>/ {print \$2}' | sort | tr '\n' ' '")
case "$cloud_rx" in
  *10.10.10.0/24*10.200.0.0/24*) ok "ECS 学到实验网与 LB 地址池（${cloud_rx% }）";;
  *) bad "ECS 学到的前缀：[${cloud_rx}]";;
esac
case "$cloud_rx" in *10.244.*) bad "Pod 网段泄露到云上：${cloud_rx}";; *) ok "Pod 网段没有宣告到云上";; esac
check "ECS 经隧道的路由源地址为 VPC 地址 ${ECS_VPC_IP}（SET-SRC）" \
  bash -c "$SSH aliyun-edge 'ip route show 10.200.0.0/24' | grep -q 'src ${ECS_VPC_IP}'"
for w in $WORKERS; do
  check "${w}：回程路由 ${VPC_CIDR} via 10.10.10.20（Calico 从路由器学到）" \
    bash -c "$SSH $w 'ip route show ${VPC_CIDR}' | grep -q 'via 10.10.10.20'"
done

echo "== 端到端 =="
check "worker-1 → ECS VPC 地址（实验网访问云）" bash -c "$SSH k8s-worker-1 'ping -c2 -W3 ${ECS_VPC_IP}'"
host=$(ecs "curl -s -m5 http://10.200.0.20/" | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4)
if [ -n "$host" ]; then ok "ECS → lab-api 10.200.0.20（Local 服务，应答 Pod ${host}）"; else bad "ECS 访问 10.200.0.20 失败"; fi
code=$(ecs "curl -s -m5 -o /dev/null -w '%{http_code}' http://10.200.0.10/")
if [ "$code" = "302" ] || [ "$code" = "200" ]; then ok "ECS → Grafana 10.200.0.10（Cluster 服务，HTTP ${code}）"; else bad "ECS 访问 Grafana 失败（HTTP ${code}）"; fi

echo "== 监控 =="
check "exporter：frr_bgp_peer_up{peer=\"${TUN_CLOUD}\"} 1" \
  bash -c "curl -s --noproxy '*' -m5 http://10.10.10.20/cgi-bin/bgp-metrics | grep -q 'frr_bgp_peer_up{peer=\"${TUN_CLOUD}\",remote_as=\"64600\"} 1'"
firing=$($SSH k8s-master "kubectl get --raw '${PROM}/query?query=ALERTS%7Balertname%3D~%22Frr.%2A%22%2Calertstate%3D%22firing%22%7D'" | grep -o '"alertname":"[^"]*"' | tr '\n' ' ')
if [ -z "$firing" ]; then ok "没有正在触发的 FRR 告警"; else bad "正在触发：${firing}"; fi

echo "== Terraform =="
if [ -n "${ALIBABA_CLOUD_ACCESS_KEY_ID:-}" ] && [ -n "${TF_VAR_edge_instance_id:-}" ]; then
  # -detailed-exitcode：0 = 无变更，2 = 有变更（云上配置被手工改过），1 = 出错
  ( cd "${REPO_ROOT}/terraform/hybrid" && terraform plan -detailed-exitcode -input=false -lock=false >/dev/null 2>&1 ); rc=$?
  case $rc in
    0) ok "terraform plan 无变更（云上资源与代码一致）";;
    2) bad "terraform plan 有变更：云上安全组规则或路由被手工修改过";;
    *) bad "terraform plan 执行失败（检查凭据与 terraform init）";;
  esac
else
  echo "  [SKIP] 未设置 ALIBABA_CLOUD_ACCESS_KEY_ID / TF_VAR_edge_instance_id，跳过 terraform plan 漂移检查"
fi

echo
echo "结果：${pass} 通过，${fail} 失败"
[ "$fail" -eq 0 ]
