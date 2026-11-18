#!/usr/bin/env bash
# =============================================================================
# verify-network.sh —— 阶段 4 验收，在 Mac 上执行（兼容 macOS 自带 bash 3.2）
#   BGP 邻居与路由策略、ECMP（Cluster / Local）、LoadBalancer IP、BGP 监控与告警、
#   split DNS（路由器、节点、Pod、Mac）、节点无 RA 残留、Ansible 无配置漂移、Mac 端到端访问
#
# 前提：
#   - ~/.ssh/config 中有 k8s-master、k8s-worker-1..3、frr-router 别名，均可免密登录
#   - Mac 已加路由：sudo route -n add -net 10.200.0.0/24 10.10.10.20（一次性，重启失效）
#   - Mac 已配置 /etc/resolver/lab.internal（nameserver 10.10.10.20）
# 用法（在仓库根目录）：./scripts/verify-network.sh
# 会 apply tests/stage4/lab-api-lb-local.yaml（若不存在）并保留，用于 Local 模式 ECMP 检查。
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
WORKERS="k8s-worker-1 k8s-worker-2 k8s-worker-3"
NODES="k8s-master ${WORKERS}"
PROM=/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1

pass=0; fail=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
rt() { $SSH frr-router "$1"; }
km() { $SSH k8s-master "$1"; }
# Mac 上开着系统代理时，访问内部地址必须绕过代理
mcurl() { curl -s --noproxy '*' -m 5 "$@"; }

for h in frr-router $NODES; do
  $SSH "$h" true 2>/dev/null || { echo "无法 SSH 到 ${h}，请先检查 ~/.ssh/config 与密钥" >&2; exit 1; }
done

echo "== 路由器：BGP =="
# 只统计与集群（AS 64512）的邻居；阶段 5 的云上邻居（AS 64600）由 verify-hybrid.sh 检查
n=$(rt "vtysh -c 'show bgp ipv4 unicast summary json' | jsonfilter -e '@.peers[@.remoteAs=64512].state' | grep -c Established")
if [ "$n" = "3" ]; then ok "与 3 台 worker 的 eBGP 邻居 Established"; else bad "worker 邻居 Established ${n}/3"; fi
zero=$(rt "vtysh -c 'show bgp ipv4 unicast summary json' | jsonfilter -e '@.peers[*].pfxRcd' | grep -cx 0")
if [ "$zero" = "0" ]; then ok "每个邻居都收到前缀"; else bad "${zero} 个邻居收到 0 条前缀（检查 BGPFilter 与 route-map K8S-IN）"; fi
nh=$(rt "ip route show 10.200.0.0/24 | awk '/nexthop via/ {print \$3}' | sort | tr '\n' ' '")
if [ "$nh" = "10.10.10.11 10.10.10.12 10.10.10.13 " ]; then ok "LB 地址池 3 路 ECMP，下一跳只有 3 台 worker"
else bad "10.200.0.0/24 下一跳为 [${nh}]，期望 [10.10.10.11 10.10.10.12 10.10.10.13]"; fi
# 阶段 5 起路由器向集群只宣告云上 VPC 网段（172.16.0.0/12）；隧道未建时什么都不宣告
leak=""
for w in 10.10.10.11 10.10.10.12 10.10.10.13; do
  adv=$(rt "vtysh -c 'show bgp ipv4 unicast neighbors $w advertised-routes' | awk '/^ *\\*>/ {print \$2}'" | grep -vx '172.16.0.0/12' | tr '\n' ' ')
  [ -n "$adv" ] && leak="${leak}${w}: ${adv}; "
done
if [ -z "$leak" ]; then ok "路由器向集群只宣告云上网段（或不宣告）"; else bad "路由器向集群宣告了多余的路由：${leak}（检查 route-map K8S-OUT）"; fi
check "ECMP 按四元组哈希（fib_multipath_hash_policy=1）" \
  bash -c "$SSH frr-router 'sysctl -n net.ipv4.fib_multipath_hash_policy' | grep -qx 1"
check "已关闭 ICMP 重定向（eth0 send_redirects=0）" \
  bash -c "$SSH frr-router 'sysctl -n net.ipv4.conf.eth0.send_redirects' | grep -qx 0"

echo "== LoadBalancer =="
lb=$(km "kubectl get svc -A --field-selector spec.type=LoadBalancer -o jsonpath='{range .items[*]}{.metadata.name}={.status.loadBalancer.ingress[0].ip} {end}'")
case "$lb" in *grafana-lb=10.200.0.10*) ok "grafana-lb = 10.200.0.10";; *) bad "grafana-lb 地址不对：${lb}";; esac
case "$lb" in *argocd-server-lb=10.200.0.11*) ok "argocd-server-lb = 10.200.0.11";; *) bad "argocd-server-lb 地址不对：${lb}";; esac
km "kubectl -n lab get svc lab-api-lb-local" >/dev/null 2>&1 \
  || $SSH k8s-master "kubectl apply -f -" < "${REPO_ROOT}/tests/stage4/lab-api-lb-local.yaml" >/dev/null
sleep 3
# Local 模式：10.200.0.20/32 的下一跳 = 运行 lab-api Pod 的节点 IP
want=$(km "for n in \$(kubectl -n lab get pod -l app=lab-api -o jsonpath='{.items[*].spec.nodeName}'); do kubectl get node \$n -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'; echo; done | sort -u | tr '\n' ' '")
got=$(rt "ip route show 10.200.0.20 | awk '/nexthop via/ {print \$3} / via / && !/nexthop/ {print \$3}' | sort -u | tr '\n' ' '")
if [ -n "$want" ] && [ "$want" = "$got" ]; then ok "Local 服务 10.200.0.20 只由有 Pod 的节点宣告（${got% }）"
else bad "10.200.0.20 下一跳 [${got}]，期望 [${want}]"; fi

echo "== BGP 监控 =="
check "路由器 exporter 正常（frr_bgp_up 1）" bash -c "curl -s --noproxy '*' -m 5 http://10.10.10.20/cgi-bin/bgp-metrics | grep -qx 'frr_bgp_up 1'"
check "Prometheus 抓取 frr-router 成功" \
  bash -c "$SSH k8s-master \"kubectl get --raw '${PROM}/query?query=up%7Bjob%3D%22frr-router%22%7D'\" | grep -q '\"1\"\]'"
firing=$(km "kubectl get --raw '${PROM}/query?query=ALERTS%7Balertname%3D~%22Frr.%2A%22%2Calertstate%3D%22firing%22%7D'" | grep -o '"alertname":"[^"]*"' | tr '\n' ' ')
if [ -z "$firing" ]; then ok "没有正在触发的 FRR 告警"; else bad "正在触发：${firing}"; fi

echo "== split DNS =="
check "路由器：grafana.lab.internal → 10.200.0.10" \
  bash -c "$SSH frr-router 'nslookup grafana.lab.internal 127.0.0.1' | grep -q 'Address: 10.200.0.10'"
check "路由器：未知名字返回 NXDOMAIN（lab.internal 不转发）" \
  bash -c "$SSH frr-router 'nslookup nosuch.lab.internal 127.0.0.1 2>&1' | grep -q NXDOMAIN"
for h in $NODES; do
  check "${h}：lab.internal 走 delegate，公网走链路 DNS" bash -c "
    $SSH $h 'resolvectl query grafana.lab.internal' | grep -q 10.200.0.10 &&
    $SSH $h 'resolvectl query github.com' | grep -q 'github.com:'"
  v6=$($SSH "$h" "ip -6 addr show dev enp2s0 scope global | grep -c inet6")
  if [ "$v6" = "0" ]; then ok "${h}：没有 RA/DHCPv6 残留地址"; else bad "${h}：enp2s0 上有 ${v6} 个全局 IPv6 地址（检查 netplan accept-ra/dhcp6）"; fi
done
check "Pod 内：grafana.lab.internal → 10.200.0.10（CoreDNS）" \
  bash -c "$SSH k8s-master 'kubectl -n lab exec deploy/lab-api-loadgen -- nslookup grafana.lab.internal' | grep -q 10.200.0.10"
if [ -f /etc/resolver/lab.internal ]; then
  check "Mac：grafana.lab.internal → 10.200.0.10（/etc/resolver）" \
    bash -c "dscacheutil -q host -a name grafana.lab.internal | grep -q 'ip_address: 10.200.0.10'"
else
  bad "Mac 没有 /etc/resolver/lab.internal（echo 'nameserver 10.10.10.20' | sudo tee /etc/resolver/lab.internal）"
fi

echo "== Mac 端到端 =="
if route -n get 10.200.0.10 2>/dev/null | grep -q 'gateway: 10.10.10.20'; then
  ok "Mac 路由 10.200.0.0/24 → 10.10.10.20"
  check "Grafana http://10.200.0.10/api/health" bash -c "curl -s --noproxy '*' -m 5 http://10.200.0.10/api/health | grep -q '\"database\": \"ok\"'"
  check "ArgoCD https://10.200.0.11/healthz" bash -c "curl -sk --noproxy '*' -m 5 https://10.200.0.11/healthz | grep -qx ok"
  pods=$(for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
           mcurl http://10.200.0.20/ | grep -o '"hostname":"[^"]*"'; echo; done | sort -u | grep -c hostname)
  if [ "$pods" -ge 2 ]; then ok "20 次请求分布到 ${pods} 个 lab-api Pod（ECMP 生效）"; else bad "20 次请求只到达 ${pods} 个 Pod"; fi
else
  bad "Mac 没有 10.200.0.0/24 的路由（sudo route -n add -net 10.200.0.0/24 10.10.10.20），跳过端到端检查"
fi

echo "== Ansible：无配置漂移 =="
recap=$(km "cd /root/K8s-VMware/network/ansible && ansible-playbook openwrt.yml --check 2>&1 | grep -A1 'PLAY RECAP' | tail -1")
case "$recap" in
  *changed=0*failed=0*) ok "ansible-playbook --check：changed=0";;
  *) bad "路由器配置与仓库不一致：${recap:-无输出}（在 k8s-master 上执行 --check 查看变更明细）";;
esac

echo
echo "结果：${pass} 通过，${fail} 失败"
[ "$fail" -eq 0 ]
