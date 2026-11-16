#!/usr/bin/env bash
# =============================================================================
# verify-cluster.sh —— 阶段 1 验收，在 Mac 或 k8s-master 上执行
#   节点 Ready、跨节点 Pod 通信、DNS（含 EDNS 外部解析）、Service、NetworkPolicy、StorageClass
#
# 用法（在仓库根目录）：
#   HARBOR_HOST=harbor.example.com ./scripts/verify-cluster.sh
#   KEEP=1 ...   # 保留测试资源，方便手动排查
# 兼容 macOS 自带的 bash 3.2
# =============================================================================
set -uo pipefail

: "${HARBOR_HOST:?请设置 HARBOR_HOST}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="${REPO_ROOT}/tests/stage1"
NS=stage1-test
DIG_IMAGE="${DIG_IMAGE:-nicolaka/netshoot:v0.16}"

pass=0; fail=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); }
expect_ok()   { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
expect_fail() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
kx() { kubectl -n "$NS" exec "$@"; }

cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    echo; echo "清理测试资源（KEEP=1 可保留）"
    kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "== 节点 =="
NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
READY=$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l | tr -d ' ')
if [ "$NODES" = "4" ] && [ "$READY" = "4" ]; then ok "4 个节点全部 Ready"; else bad "节点 ${READY}/${NODES} Ready（期望 4/4）"; fi
expect_ok "Calico 状态 Available" \
  bash -c 'kubectl get tigerastatus calico -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" | grep -q True'
expect_ok "存在默认 StorageClass" \
  bash -c 'kubectl get sc -o jsonpath="{.items[*].metadata.annotations.storageclass\.kubernetes\.io/is-default-class}" | grep -q true'
expect_ok "metrics-server 可用（kubectl top）" kubectl top nodes

echo "== 部署测试负载 =="
# 上次运行的清理是异步的（--wait=false），命名空间还在 Terminating 时 apply 会失败
if kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; then
  echo "  等待上次的 ${NS} 删除完成..."
  kubectl wait --for=delete "ns/${NS}" --timeout=180s >/dev/null 2>&1 \
    || { echo "命名空间 ${NS} 3 分钟内未删除完成，请检查：kubectl get ns ${NS} -o yaml" >&2; exit 1; }
fi
kubectl apply -f "${T}/workloads.yaml" >/dev/null
kubectl -n "$NS" delete networkpolicy --all >/dev/null 2>&1 || true
kubectl -n "$NS" wait --for=condition=Ready pod/pod-a pod/pod-b --timeout=180s >/dev/null \
  || bad "测试 Pod 未就绪（检查镜像拉取：kubectl -n ${NS} describe pod pod-a）"
kubectl -n "$NS" rollout status deploy/web --timeout=180s >/dev/null || bad "web Deployment 未就绪"
# dig 默认带 EDNS，模拟 Go 程序（如 ArgoCD）的解析行为；busybox 的 nslookup 不带 EDNS，测不出问题
kubectl -n "$NS" run dnstest --image="$DIG_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null 2>&1 || true
kubectl -n "$NS" wait --for=condition=Ready pod/dnstest --timeout=180s >/dev/null \
  || bad "dnstest Pod 未就绪（镜像 ${DIG_IMAGE}）"

IP_B=$(kubectl -n "$NS" get pod pod-b -o jsonpath='{.status.podIP}')
echo "  pod-a@k8s-worker-1 -> pod-b@k8s-worker-2 (${IP_B})"

echo "== 网络 =="
expect_ok "跨节点 Pod 互通（ping）"           kx pod-a -- ping -c 3 -W 2 "$IP_B"
expect_ok "集群 DNS：kubernetes.default"       kx pod-a -- nslookup kubernetes.default.svc.cluster.local
expect_ok "外部 DNS：${HARBOR_HOST}"           kx pod-a -- nslookup "$HARBOR_HOST"
expect_ok "CoreDNS 上游不是 /etc/resolv.conf" \
  bash -c '! kubectl -n kube-system get cm coredns -o jsonpath="{.data.Corefile}" | grep -q "forward \. /etc/resolv.conf"'
expect_ok "外部 DNS（带 EDNS）：github.com" \
  bash -c "kubectl -n $NS exec dnstest -- dig +short +time=3 +tries=2 github.com A | grep -qE '^[0-9]+\.'"
expect_ok "Service 访问：web"                  kx pod-a -- wget -q -T 3 -O /dev/null http://web

echo "== NetworkPolicy =="
kubectl apply -f "${T}/netpol-default-deny.yaml" >/dev/null
sleep 5
expect_fail "default-deny 后 pod-a 访问被拒"   kx pod-a -- wget -q -T 3 -O /dev/null http://web
kubectl apply -f "${T}/netpol-allow-client.yaml" >/dev/null
sleep 5
expect_ok   "放行后 role=client 的 pod-a 可访问" kx pod-a -- wget -q -T 3 -O /dev/null http://web
expect_fail "role=other 的 pod-b 仍被拒"        kx pod-b -- wget -q -T 3 -O /dev/null http://web

echo "== 路由（Calico BGP） =="
echo "  可在任一节点执行 'ip route | grep 10.244'，应看到 proto bird 的 /26 路由"

echo
echo "结果：${pass} 通过，${fail} 失败"
[ "$fail" -eq 0 ]
