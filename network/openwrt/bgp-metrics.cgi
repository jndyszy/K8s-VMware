#!/bin/sh
# 阶段 4.7：FRR BGP 指标 exporter（Prometheus 文本格式）
# 运行位置：frr-router（OpenWrt），由 uhttpd 以 CGI 方式执行，安装到 /www/cgi-bin/bgp-metrics（root，755）
# 访问：http://10.10.10.20/cgi-bin/bgp-metrics
#
# 为什么是 sh 而不是 bash/Python：OpenWrt 只有 BusyBox ash，没有 Python。
# JSON 用 OpenWrt 自带的 jshn（libubox）解析；只执行只读的 show 命令，凭据不离开路由器。
# 指标：
#   frr_bgp_up                                  vtysh 是否成功返回 BGP 摘要
#   frr_bgp_peer_up{peer,remote_as}             会话是否 Established
#   frr_bgp_peer_info{peer,remote_as,state}     会话状态（值恒为 1，状态在标签里）
#   frr_bgp_peer_prefixes_received{peer}        经入方向策略后收到的前缀数
#   frr_bgp_peer_uptime_seconds{peer}           本次 Established 持续时间
#   frr_bgp_peer_connections_dropped_total{peer} 会话断开累计次数（FRR 重启后归零）
#   frr_route_nexthops{prefix}                  关键前缀在内核 FIB 中的下一跳数（ECMP 宽度）

# shellcheck disable=SC1091
. /usr/share/libubox/jshn.sh

# 关键前缀：LB 地址池（externalTrafficPolicy: Cluster 时由所有 worker 宣告）
ECMP_PREFIXES="10.200.0.0/24"

printf 'Content-Type: text/plain; version=0.0.4\r\n\r\n'

json=$(vtysh -c 'show bgp ipv4 unicast summary json' 2>/dev/null)

echo "# HELP frr_bgp_up Whether vtysh returned the BGP summary."
echo "# TYPE frr_bgp_up gauge"
if [ -z "$json" ] || ! json_load "$json" 2>/dev/null; then
	echo "frr_bgp_up 0"
	exit 0
fi
echo "frr_bgp_up 1"

up_lines=""; info_lines=""; pfx_lines=""; uptime_lines=""; drop_lines=""
if json_select peers 2>/dev/null; then
	json_get_keys peers
	for key in $peers; do
		# jshn 把键名里的 "." 换成了 "_"，这里只有 IPv4 邻居，还原即可
		peer=$(echo "$key" | tr '_' '.')
		json_select "$key"
		state=""; ras=""; pfx=""; ms=""; dropped=""
		json_get_var state state
		json_get_var ras remoteAs
		json_get_var pfx pfxRcd
		json_get_var ms peerUptimeMsec
		json_get_var dropped connectionsDropped
		json_select ..
		up=0; [ "$state" = "Established" ] && up=1
		up_lines="${up_lines}frr_bgp_peer_up{peer=\"$peer\",remote_as=\"$ras\"} $up
"
		info_lines="${info_lines}frr_bgp_peer_info{peer=\"$peer\",remote_as=\"$ras\",state=\"${state:-unknown}\"} 1
"
		pfx_lines="${pfx_lines}frr_bgp_peer_prefixes_received{peer=\"$peer\"} ${pfx:-0}
"
		uptime_lines="${uptime_lines}frr_bgp_peer_uptime_seconds{peer=\"$peer\"} $(( ${ms:-0} / 1000 ))
"
		drop_lines="${drop_lines}frr_bgp_peer_connections_dropped_total{peer=\"$peer\"} ${dropped:-0}
"
	done
fi

echo "# HELP frr_bgp_peer_up Whether the BGP session is Established."
echo "# TYPE frr_bgp_peer_up gauge"
printf '%s' "$up_lines"
echo "# HELP frr_bgp_peer_info BGP session state as a label."
echo "# TYPE frr_bgp_peer_info gauge"
printf '%s' "$info_lines"
echo "# HELP frr_bgp_peer_prefixes_received Prefixes accepted from the peer after inbound policy."
echo "# TYPE frr_bgp_peer_prefixes_received gauge"
printf '%s' "$pfx_lines"
echo "# HELP frr_bgp_peer_uptime_seconds Seconds since the session became Established."
echo "# TYPE frr_bgp_peer_uptime_seconds gauge"
printf '%s' "$uptime_lines"
echo "# HELP frr_bgp_peer_connections_dropped_total Session drops since bgpd started."
echo "# TYPE frr_bgp_peer_connections_dropped_total counter"
printf '%s' "$drop_lines"

echo "# HELP frr_route_nexthops Number of kernel FIB next hops for a monitored prefix (ECMP width)."
echo "# TYPE frr_route_nexthops gauge"
for prefix in $ECMP_PREFIXES; do
	route=$(ip route show "$prefix" 2>/dev/null)
	# 完整版 iproute2（ip-full）多路径时每个下一跳一行 "nexthop via"；单路径时只有 "via"
	n=$(echo "$route" | grep -c 'nexthop via')
	if [ "$n" -eq 0 ] && echo "$route" | grep -q ' via '; then n=1; fi
	echo "frr_route_nexthops{prefix=\"$prefix\"} $n"
done
