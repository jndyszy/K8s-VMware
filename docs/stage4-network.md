# 阶段 4：OpenWrt + FRR、Calico eBGP、LoadBalancer ECMP

> 目标：让集群外的路由器通过 BGP 学到 Pod 与 LoadBalancer 路由，Mac 直接访问服务 VIP（不再 `port-forward`），
> 同一 VIP 由多台 worker 等价分担，节点故障时路由在秒级收敛。
> 配置：[`network/openwrt/`](../network/openwrt/)（路由器）、[`platform/calico/`](../platform/calico/) 下的 `bgp-*.yaml`、`ippool-loadbalancer.yaml`，
> [`platform/monitoring/grafana-lb.yaml`](../platform/monitoring/grafana-lb.yaml)、[`platform/argocd/argocd-server-lb.yaml`](../platform/argocd/argocd-server-lb.yaml)，
> 验收资源 [`tests/stage4/`](../tests/stage4/)。

## 整体结构

```text
                    Mac 10.10.10.1 ── route add 10.200.0.0/24 → .20（一次性）
                          │
                          ▼
                 ┌──────────────────┐  AS 64500，单臂，只挂 vmnet2
                 │ frr-router  .20  │  只收不发：收 LB 地址池与 Pod 网段，不向集群宣告任何路由
                 └──┬──────┬─────┬──┘  maximum-paths 8 → ECMP；fib_multipath_hash_policy=1 → 按四元组哈希
           eBGP     │      │     │     timers 3 9 → 节点失联 9 秒内撤销路径
             worker-1 .11  worker-2 .12  worker-3 .13      AS 64512（Calico，节点间 iBGP 全互联）
             k8s-master .10：不与路由器建邻居，不进入 LB 数据路径
```

| 组件 | 版本 |
| --- | --- |
| OpenWrt | 25.12.6（armsr/armv8，包管理器 apk） |
| FRR | 10.4.1（OpenWrt 官方 routing 源） |
| Calico | v3.33.0（原生 LoadBalancer IPAM，未使用 MetalLB） |

| 地址 | 用途 |
| --- | --- |
| 10.200.0.0/24 | LoadBalancer 地址池（Calico IPPool，`allowedUses: [LoadBalancer]`） |
| 10.200.0.10 | Grafana（`externalTrafficPolicy: Cluster`） |
| 10.200.0.11 | ArgoCD（`Cluster`，仅 443） |
| 10.200.0.20 | lab-api 验收入口（`Local`，演示 ECMP 与故障收敛） |

## 4.1 OpenWrt 基础配置

出厂状态：`eth0` 进 `br-lan`（192.168.1.1），`eth1` 为 WAN（DHCP），LAN 开 DHCP 与 IPv6 RA。改为单臂（控制台执行）：

```bash
uci set system.@system[0].hostname='frr-router'
uci set network.lan.device='eth0'                 # 单网卡，不需要网桥
uci set network.lan.ipaddr='10.10.10.20/24'
uci set network.lan.gateway='10.10.10.2'          # 与节点一样经 Fusion NAT 出网
uci add_list network.lan.dns='10.10.10.2'
uci delete network.@device[0]                     # 删 br-lan
uci delete network.wan; uci delete network.wan6   # 单臂没有 WAN
uci delete network.lan.ip6assign; uci delete network.globals.ula_prefix
uci set dhcp.lan.ignore='1'                       # vmnet2 静态规划，不发 DHCP
uci set dhcp.lan.ra='disabled'; uci set dhcp.lan.dhcpv6='disabled'   # 否则节点会经 SLAAC 拿到 IPv6
uci commit
service system reload; service network restart; service dnsmasq restart; service odhcpd restart
```

- 接口留在 `lan` 防火墙区域（input ACCEPT）；`wan` 区域 input 默认 REJECT 会挡住 BGP 的 TCP 179。
- **dnsmasq 上游不能是 10.10.10.2**：直接 `nslookup ... 10.10.10.2` 正常，经 dnsmasq 却解析为空，日志
  `nameserver 10.10.10.2 refused to do a recursive query`。根因与阶段 2 相同：Fusion NAT 的 DNS 不是转发器，而是自己拼应答
  （flags 只有 `qr aa`、没有 `ra`；带 EDNS 时报文末尾多 16 字节），与 Mac 代理的 fake-ip 无关（对照实验：同一域名、同一服务器，只改 EDNS 一个变量）。
  上游改为 4 台节点上的 systemd-resolved：

  ```bash
  uci set dhcp.@dnsmasq[0].noresolv='1'
  for ip in 10.10.10.10 10.10.10.11 10.10.10.12 10.10.10.13; do uci add_list dhcp.@dnsmasq[0].server="$ip"; done
  uci commit dhcp; service dnsmasq restart
  ```

- SSH：dropbear，公钥放 `/etc/dropbear/authorized_keys`（不是 `~/.ssh/`），Mac 上 `ssh frr-router` 别名使用实验密钥；
  每台客户端设备用各自的密钥（如 Termius 单独生成），确认可登录后关闭密码认证：
  `uci set dropbear.@dropbear[0].PasswordAuth='off'; uci set dropbear.@dropbear[0].RootPasswordAuth='off'`。
  dropbear 没有 sftp-server，`scp` 需加 `-O`。

## 4.2 FRR 与 eBGP

内核参数 [`90-lab-router.conf`](../network/openwrt/90-lab-router.conf)：

- `net.ipv4.fib_multipath_hash_policy=1`：ECMP 按四元组哈希。默认 0 只看源/目的 IP，Mac 单一客户端永远落在同一台 worker。
- `send_redirects=0`：单臂转发进出同一接口，内核会给 Mac 发 ICMP 重定向，Mac 随后绕过路由器直连 worker，ECMP 失效。

```bash
apk add frr frr-bgpd frr-zebra frr-watchfrr
# 写入 network/openwrt/ 下的 frr.conf、vtysh.conf，daemons 中 bgpd=yes
/etc/init.d/frr enable; /etc/init.d/frr restart
printf '%s\n' /etc/frr/ /etc/sysctl.d/90-lab-router.conf >> /etc/sysupgrade.conf   # 固件升级时保留
```

OpenWrt 打包与 Ubuntu 的差异：zebra 不在 `daemons` 里（总是启动）；由 watchfrr 拉起并守护各进程；
自带 `frr.conf` 是含 `password zebra` 的旧示例，整份替换；没有 Python，因此没有 `frr-reload.py`，改配置用 vtysh + `write memory` 或改文件后重启。
启动时 `cannot start staticd: daemon binary not installed` 可忽略（静态路由由 netifd 管）。

[`frr.conf`](../network/openwrt/frr.conf) 要点（对照 H3C Comware）：

| FRR | Comware | 说明 |
| --- | --- | --- |
| `ip prefix-list K8S-LB ... 10.200.0.0/24 le 32` | `ip prefix-list ... less-equal 32` | LB 地址池及其中的 /32 |
| `ip prefix-list K8S-POD ... 10.244.0.0/16 le 32` | 同上 | Pod 地址块是 /26，借用地址时还会出现 /32 |
| `route-map K8S-IN permit 10/20` | `route-policy K8S-IN permit node 10/20` | 末尾隐含 deny；FRR 默认 `ebgp-requires-policy`，不配策略 eBGP 不收不发 |
| `route-map K8S-OUT deny 10` | `route-policy K8S-OUT deny node 10` | 路由器不向集群注入路由（节点默认网关是 .2） |
| `neighbor K8S peer-group` | `group K8S external` | 3 台 worker 共用配置 |
| `timers 3 9` | `timer keepalive 3 hold 9` | 双方取较小的保持时间，只改路由器侧即可把 Calico 默认 90 秒降到 9 秒 |
| `timers connect 10` | `timer connect-retry 10` | 默认 120 秒 |
| `maximum-paths 8` | `balance 8` | eBGP 负载分担 |

## 4.3 Calico 侧邻居

- [`bgp-configuration.yaml`](../platform/calico/bgp-configuration.yaml)：显式写出 `asNumber: 64512`、`nodeToNodeMeshEnabled: true`（此前全是默认值）。
- [`bgp-peer-frr-router.yaml`](../platform/calico/bgp-peer-frr-router.yaml)：`peerIP 10.10.10.20`、`asNumber 64500`、
  `nodeSelector: has(node-role.kubernetes.io/worker)`——只在 worker 上建邻居，master 不进入数据路径。
- [`bgp-filter-local-only.yaml`](../platform/calico/bgp-filter-local-only.yaml)：出口过滤 `Reject source: RemotePeers`，只宣告本节点自己产生的路由。

这个过滤器是排查出来的，过程值得记录：

1. 建邻居后，路由器上**每个 Pod 地址块都有 3 条等价下一跳**（.11/.12/.13），worker-3 的地址块 2/3 概率先送到别的 worker 再绕一跳。
   原因：Calico 会把经节点间 iBGP 学到的其他节点路由也转发给外部邻居，eBGP 下一跳改成了自己。
2. 先加 `keepOriginalNextHop: true`，下一跳变成真正的属主，看起来修好了。
3. 有了 LB 地址池后发现 `/24` 有 **4 个下一跳，含 master（.10）**。`show bgp ipv4 unicast 10.200.0.0/24` 显示 12 条路径：
   Calico 对外部邻居启用了 **ADD-PATH**，每台 worker 把自己和另外 3 台节点的路径全发了过来。
   后果不只是 master 进入数据路径：worker-3 失联时，另外两台仍在转发"下一跳 .13"的路径，要等节点间 iBGP 超时才撤销，
   路由器侧 9 秒保持时间形同虚设。
4. 改为出口过滤，只宣告本地路由。此后路由器上每条路径都只来自"下一跳本人"的 BGP 会话，会话断开即撤销。
   取舍：master 的 Pod 地址块不再出现在路由器上（master 只跑系统组件，可以接受）。

验证（路由器）：`ip route show 10.200.0.0/24` 为 .11/.12/.13 三个 `nexthop`；从路由器 `traceroute` 到 lab-api Pod 只经过所在 worker 一跳。

注意：**修改 BGPPeer 的 filters 会重置所有会话**。日志 `NOTIFICATION: received from neighbor ... 6/6 (Cease/Other Configuration Change)`，
1–2 秒后重建。BIRD 改出口策略不做软刷新，相当于 `reset bgp all` 而不是 `refresh bgp`，生产环境要放进变更窗口。

## 4.4 LoadBalancer：Calico 原生 IPAM（放弃 MetalLB）

原计划"MetalLB 只分配 IP、关闭 speaker，由 Calico 宣告"。实施前评估后改为 Calico 原生：

- MetalLB v0.16.2（2026-11-04）**默认启用 frr-k8s**，会在每台节点跑 FRR 抢占 TCP 179，仅关 speaker 不够，还要关 `frrk8s.enabled`，
  且以后升级要持续关注默认值变化。
- Calico 3.29 起自带 LoadBalancer IPAM，集群里 `calico-kube-controllers` 的 loadBalancer 控制器已在运行（`assignIPs: AllServices`），
  只缺一个地址池。分配与宣告在同一系统，少一个组件、一个 webhook、一套 CRD。

```bash
kubectl apply -f platform/calico/ippool-loadbalancer.yaml -f platform/calico/bgp-configuration.yaml   # 地址池 + serviceLoadBalancerIPs
kubectl apply -f platform/monitoring/grafana-lb.yaml -f platform/argocd/argocd-server-lb.yaml
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

- 单独建 `*-lb` Service，不改 chart / 上游 install.yaml 自带的 Service：升级或重新 apply 不会覆盖对外入口。
- 固定 IP 用注解 `projectcalico.org/loadBalancerIPs`，DNS 记录才能写死。
- `externalTrafficPolicy: Cluster`：所有节点宣告整个 `/24`（`serviceLoadBalancerAggregation: Enabled`），路由器 ECMP 到任一 worker，
  再由 kube-proxy 转到后端 Pod，Pod 看到的源 IP 是节点 IP。
- `externalTrafficPolicy: Local`：只有运行后端 Pod 的节点宣告该 IP 的 `/32`，最长匹配优先于 `/24`，保留客户端源 IP。

ArgoCD 初始密码：`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo`，
登录后在 User Info 修改，再按官方建议删除该 Secret。

## 4.5 Mac 访问、ECMP 与故障收敛

```bash
sudo route -n add -net 10.200.0.0/24 10.10.10.20   # Mac，一次性，关机失效
```

此后浏览器直接打开 http://10.200.0.10（Grafana）、https://10.200.0.11（ArgoCD）。路径不对称：
去程 Mac → 路由器 → worker，回程 worker → Mac 直达（同网段）。能工作的前提是路由器不丢单向流量（fw4 默认 `drop_invalid` 关闭）且已关重定向。

### ECMP 验证

路由器 `apk add ip-full`（BusyBox 的 `ip` 不显示多路径下一跳，也不支持 `ip route get` 的端口参数）：

```bash
ip route show 10.200.0.0/24
for p in 40001 40002 40003 40004 40005 40006; do
  ip route get 10.200.0.10 from 10.10.10.1 iif eth0 ipproto tcp sport $p dport 80 | head -1
done   # 只改源端口，选中的下一跳随之变化
```

[`tests/stage4/lab-api-lb-local.yaml`](../tests/stage4/lab-api-lb-local.yaml)：lab-api 两个副本在 worker-2、worker-3，
`10.200.0.20/32` 只有 .12、.13 两个下一跳（worker-1 没有 Pod，不宣告）。Local 模式下节点只交给本机 Pod，返回的 hostname 即 ECMP 选中的路径；
Mac 上循环 curl，两个 Pod 名都出现。

### 故障演练：worker-3 链路中断

方式：Fusion 中断开 worker-3 的网卡（模拟拔网线：对端不发 Notification，只能靠保持时间发现）。
观测：Mac 每 0.5 秒新建一次连接（`curl -m1 http://10.200.0.20/`，打印应答 Pod）；路由器 `ip -ts monitor route`、`logread -f -e bgpd`。

| 时间（UTC+8） | 事件 |
| --- | --- |
| 13:08:18 | 最后一次由 worker-3 上的 Pod（spf2b）应答 |
| ≈13:08:19 | 断开 worker-3 网卡 |
| 13:08:23–13:08:28 | 5 次请求中 4 次 `FAIL`（被哈希到 .13，1 秒超时） |
| 13:08:28 | 路由器 `Hold Timer Expired`，撤销经 .13 的全部路径 |
| 13:08:29 起 | 100% 由 worker-2 上的 Pod（fdbjd）应答，零失败 |
| 约 13:09 | 节点 `NodeNotReady`（控制平面检测明显慢于 BGP） |
| 13:09:28 | 恢复网卡后邻居 Up + End-of-RIB |
| 13:09:29 | worker-3 上的 Pod 重新出现在应答中 |

结论：

- **业务受影响窗口 ≈ 9 秒，正好是 BGP 保持时间**；窗口内约一半新连接失败（ECMP 一半流量哈希到故障节点），撤销后零失败。
- 对 `Local` 模式的 LB 服务，决定恢复时间的是 BGP 保持时间，不是 K8s 的节点检测（四五十秒）。这是把 timers 调到 `3 9` 的价值；
  要进一步缩短需上 BFD（亚秒级）。
- 正常关机时 BIRD 会主动发 Cease，路由 1 秒内撤销；拔线式故障只能等保持时间。
- 前提是 4.3 的出口过滤：如果其他 worker 仍转发"下一跳 .13"的路径，撤销时间会被拉长到节点间 iBGP 超时。

## 4.6 split DNS：lab.internal

```text
节点 resolved:  ~lab.internal ──(DNS delegate)──▶ 10.10.10.20 dnsmasq（本地记录应答，local=/lab.internal/ 永不转发）
               其他所有域名  ──(链路 DNS)──────▶ 10.10.10.2（不变）
CoreDNS:       lab.internal:53 { forward . 10.10.10.20 }
Mac:           /etc/resolver/lab.internal → nameserver 10.10.10.20
dnsmasq 上游:  4 台节点 resolved（仅路由器自身解析公网时用到）
```

| 名字 | 地址 |
| --- | --- |
| grafana / argocd / lab-api `.lab.internal` | 10.200.0.10 / .11 / .20 |
| frr-router、k8s-master、k8s-worker-1..3 `.lab.internal` | 10.10.10.20、.10–.13 |

### 先清理：Rogue RA 留下的 IPv6

OpenWrt 装好时 eth0 就在 vmnet2 上，出厂开着 RA 与 DHCPv6；节点 netplan 没关"接受 RA"，3 台节点拿到了 `fd45:d89:d86d::/64` 的地址和前缀委派，
还把路由器的 `fd45::1` 加进了 DNS 服务器列表。4.1 删掉 ULA 后这个 DNS 服务器不可达，resolved 偶尔选中它就要等超时。

- 路由器：`/etc/init.d/odhcpd stop; /etc/init.d/odhcpd disable`（DHCPv4 由 dnsmasq 负责，不受影响）。
- 节点：netplan 加 `dhcp6: false`、`accept-ra: false` 后 `netplan apply`（等同交换机上的 RA Guard，`clone-setup.sh` 已同步）。

### 路由器（dnsmasq）

```bash
uci set dhcp.@dnsmasq[0].local='/lab.internal/'    # 本地应答，查不到返回 NXDOMAIN，永不转发：防环路第二道保险
uci set dhcp.@dnsmasq[0].domain='lab.internal'
for r in grafana:10.200.0.10 argocd:10.200.0.11 lab-api:10.200.0.20 \
         frr-router:10.10.10.20 k8s-master:10.10.10.10 k8s-worker-1:10.10.10.11 k8s-worker-2:10.10.10.12 k8s-worker-3:10.10.10.13; do
  uci add dhcp domain >/dev/null
  uci set dhcp.@domain[-1].name="${r%%:*}.lab.internal"; uci set dhcp.@domain[-1].ip="${r##*:}"
done
uci commit dhcp; service dnsmasq restart
```

4.7 起记录改为 [`network/openwrt/lab-internal.hosts`](../network/openwrt/lab-internal.hosts)（dnsmasq `addn-hosts`），由 Ansible 推送，上面的 uci domain 段会被清理。

### 节点：DNS delegate，而不是 resolved.conf 的全局 DNS=

```bash
mkdir -p /etc/systemd/dns-delegate.d
printf '[Delegate]\nDNS=10.10.10.20\nDomains=~lab.internal\n' > /etc/systemd/dns-delegate.d/lab-internal.dns-delegate
systemctl restart systemd-resolved
```

在 `resolved.conf` 写全局 `DNS=10.10.10.20` + `Domains=~lab.internal` 看似等价，实则有坑：**resolved 的全局作用域永远是默认路由**，
公网查询也会发给 .20，而 dnsmasq 上游又是节点 resolved，形成环路。systemd 258 起的 DNS delegate 是独立于网卡的按域委派，
`DefaultRoute` 默认关闭，正好只接管 `lab.internal`（Ubuntu 26.04 为 systemd 259）。

`resolvectl query grafana.lab.internal` 输出里的 `-- link: enp2s0` 只表示应答从哪块网卡收回，不代表用了链路 DNS；
抓包确认查询发往 10.10.10.20。对照：直接问 10.10.10.2 得到 fake-ip——不做 split DNS，内部名字会被 Mac 代理当成公网域名。

### CoreDNS 与 Mac

- [`platform/coredns/configmap.yaml`](../platform/coredns/configmap.yaml) 增加 `lab.internal:53` 块，Pod 内可解析
  （`kubectl -n lab exec deploy/lab-api-loadgen -- nslookup grafana.lab.internal`）。
- Mac：`echo 'nameserver 10.10.10.20' | sudo tee /etc/resolver/lab.internal`。**`dig`/`nslookup` 不读 `/etc/resolver`**，
  用 `dscacheutil -q host -a name grafana.lab.internal`、`curl` 或浏览器验证。
- Mac 开着系统代理时，代理例外列表里有 `10.0.0.0/8`，但按 IP 匹配对域名访问无效：`curl https://argocd.lab.internal` 会先发给代理
  （返回 `200 Connection established`）。建议把 `*.lab.internal` 加入系统代理例外和 `NO_PROXY`，让内部服务始终直连。

### 验证路由器 DNS 故障的影响

路由器 `service dnsmasq stop` 后：节点 `resolvectl query github.com` 照常解析，`grafana.lab.internal` 失败；`service dnsmasq start` 恢复。
故障只影响内部域名——这是 split DNS 相对"主 .20、备 .2"的优势（后者还要等主 DNS 超时，且有环路）。

## 4.7 BGP 监控与告警

OpenWrt 没有 Python，原计划"Python 自写 exporter，SSH 登录路由器执行 vtysh"需要新镜像、Deployment，还要把路由器 root 私钥放进集群。
改为**在路由器上用设备原生能力实现 exporter**：uhttpd 以 CGI 方式执行 [`bgp-metrics.cgi`](../network/openwrt/bgp-metrics.cgi)
（ash + OpenWrt 自带的 jshn 解析 `show bgp ipv4 unicast summary json`），Prometheus 直接拉取。零新增组件，凭据不离开路由器，只执行只读 show 命令。

```bash
scp -O network/openwrt/bgp-metrics.cgi frr-router:/www/cgi-bin/bgp-metrics          # Mac
chmod 755 /www/cgi-bin/bgp-metrics && echo /www/cgi-bin/bgp-metrics >> /etc/sysupgrade.conf   # 路由器
kubectl apply -f platform/monitoring/frr-router-scrapeconfig.yaml \
  -f platform/monitoring/frr-bgp-rules.yaml -f platform/monitoring/frr-bgp-dashboard.yaml     # master
```

| 指标 | 含义 |
| --- | --- |
| `frr_bgp_up` | vtysh 是否返回 BGP 摘要（bgpd 是否存活） |
| `frr_bgp_peer_up{peer,remote_as}` | 会话是否 Established |
| `frr_bgp_peer_info{peer,remote_as,state}` | 会话状态（值恒为 1，状态在标签里） |
| `frr_bgp_peer_prefixes_received{peer}` | 经入方向策略后接受的前缀数 |
| `frr_bgp_peer_uptime_seconds{peer}` | 本次 Established 持续时间 |
| `frr_bgp_peer_connections_dropped_total{peer}` | 会话断开累计次数 |
| `frr_route_nexthops{prefix}` | 关键前缀在内核 FIB 中的下一跳数（ECMP 宽度） |

- [`frr-router-scrapeconfig.yaml`](../platform/monitoring/frr-router-scrapeconfig.yaml)：Prometheus Operator 的 `ScrapeConfig` 用于抓集群外静态目标，
  标签 `release: kps` 匹配现有 `scrapeConfigSelector`，不用改 Helm values。
- jshn 会把键名里的 `.` 换成 `_`（`10_10_10_11`），exporter 里还原成 IP。

| 告警 | 条件 | 级别 |
| --- | --- | --- |
| `FrrExporterDown` | 抓取失败或 `frr_bgp_up == 0`，持续 1 分钟 | critical |
| `FrrBgpPeerDown` | 邻居断开超过 30 秒（过滤改 BGPFilter 引起的 1–2 秒重建） | critical |
| `FrrBgpPeerNoPrefixes` | 会话正常但前缀数为 0，持续 2 分钟（策略写错） | warning |
| `FrrLoadBalancerEcmpDegraded` | `10.200.0.0/24` 下一跳少于 3，持续 1 分钟 | warning |
| `FrrBgpPeerFlapping` | 15 分钟内断开 ≥ 3 次 | warning |

规则测试 [`tests/stage4/frr-bgp-rules.test.yaml`](../tests/stage4/frr-bgp-rules.test.yaml)（1 组健康 + 4 组故障，含 pending → firing 时机），
`promtool test rules` 结果 SUCCESS。查看告警：Grafana → Alerting → Alert rules → Data source-managed → `monitoring/frr-bgp`
（列表显示规则定义，`{{ $labels.peer }}` 不展开；展开 Instances 看渲染后的内容），或 Explore 查询 `ALERTS{alertname=~"Frr.*"}`。

### 告警演练：管理性关闭 worker-1 邻居

`neighbor 10.10.10.11 shutdown`（等同 H3C `peer ... ignore`，只改运行配置不 `write memory`）。worker-1 上没有 Local 服务后端，业务无影响。

| 时间（UTC+8） | 事件 |
| --- | --- |
| 13:37:16 | 路由器发出 `Cease/Administrative Shutdown`，邻居 Down |
| ≈13:37:30 | 下一次抓取：`frr_bgp_peer_up=0`，`frr_route_nexthops=2` |
| 13:37:54 | 两条告警进入 pending |
| 13:38:24 | `FrrBgpPeerDown` firing（距故障约 68 秒） |
| 13:38:54 | `FrrLoadBalancerEcmpDegraded` firing |
| 13:47:22 | `no neighbor ... shutdown`，邻居 Up + End-of-RIB |
| 13:47:54 | 两条告警恢复 |

告警时延构成：抓取间隔 15 秒 + 规则评估间隔 30 秒（chart 默认）+ `for` 30 秒，约 1 分钟。BGP 自身 9 秒收敛，**告警是给人看的，不在业务恢复路径上**；
如需更快感知可缩短评估间隔，代价是 Prometheus 负载。

## 4.7 Ansible 管理路由器配置

[`network/ansible/`](../network/ansible/)：`group_vars/openwrt.yml` 描述期望状态（软件包、文件放哪里、uci 各项取值），
文件内容在 [`network/openwrt/`](../network/openwrt/)。DNS 记录从 8 条 `uci add` 改为 Git 里的
[`lab-internal.hosts`](../network/openwrt/lab-internal.hosts)（dnsmasq `addn-hosts`），新增服务只改一行。

**控制节点放在 k8s-master**（不是 Mac）：apt 安装 `ansible-core`，生成只授权给路由器的专用密钥，从 Mac 中转授权（路由器已关闭密码登录）：

```bash
apt-get install -y ansible-core                                                     # master
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_frr -N '' -C 'ansible@k8s-master -> frr-router'
# /root/.ssh/config 加 Host frr-router（HostName 10.10.10.20、User root、IdentityFile 上面的密钥）
ssh k8s-master 'cat /root/.ssh/id_ed25519_frr.pub' | ssh frr-router 'cat >> /etc/dropbear/authorized_keys'   # Mac

cd /root/K8s-VMware/network/ansible
ansible-playbook openwrt.yml --check     # 只报告差异
ansible-playbook openwrt.yml             # 应用；再执行一次应为 changed=0
```

| 选择 | 原因 |
| --- | --- |
| 全部用 `raw` 模块 | OpenWrt 没有 Python，copy/template/lineinfile 等模块都依赖远端 Python；文件用控制节点的 `scp -O` 上传 |
| 自己实现 check 模式 | `raw` 在 `--check` 下默认直接跳过，看不到任何差异；修改类任务在 check 模式下照常运行、只打印 `CHANGED:` 不修改 |
| 按需生效 | 只有 frr.conf 变了才重启 FRR（会重建全部 BGP 会话）；只有 hosts 文件变了只 `reload` dnsmasq |
| 不管理网络接口 | Ansible 依赖 10.10.10.20 连接路由器，改错地址会把自己锁在外面；接口在 4.1 由控制台完成 |
| 专用密钥 | 只授权给路由器，撤销时删 `authorized_keys` 一行即可，不影响其他访问 |

首次执行结果：上传 hosts 文件、`sysupgrade.conf` 加一行、uci 新增 `addnhosts`、删除 4.6 手工添加的 8 个 domain 段；
frr.conf 等文件无差异，BGP 未受影响（`established=3`、`lb_nexthops=3`）。第二次执行 `changed=0`。
Mac（`dscacheutil`）、节点（`resolvectl`）、路由器上 lab.internal 解析均正常。

配置漂移演示（可选，未在本次记录中执行）：路由器上手工 `uci set dropbear.@dropbear[0].PasswordAuth='on'; uci commit dropbear`，
`--check` 应报告 `CHANGED: dropbear.@dropbear[0].PasswordAuth 'on' -> 'off'`，正式执行即修正。

## 踩坑记录

1. **Fusion DNS 让 dnsmasq 解析为空**：见 4.1，上游改为节点 resolved。dnsmasq 日志里的 `refused to do a recursive query` 是线索。
2. **ADD-PATH 把 master 和别的节点路径带进路由器**：`keepOriginalNextHop` 只修正下一跳，不解决根因，改为 BGPFilter 出口过滤（见 4.3）。
3. **改 BGPFilter 会重置所有 BGP 会话**：见 4.3。
4. **路由器时钟慢了 3 分 25 秒**：sysntpd 在 dnsmasq 修好之前启动，域名解析失败后没有恢复同步，导致路由器日志与 Mac、节点的时间对不上，
   演练时间线一度无法对齐。`service sysntpd restart` 后同步。排障时日志时间不可信是大忌，路由器配好 DNS 后应重启一次 NTP。
5. **BusyBox `ip` 看不到 ECMP**：多路径路由只显示第一行，装 `ip-full`。
6. **Rogue RA**：OpenWrt 出厂 RA/DHCPv6 让节点拿到 IPv6 地址和失效的 DNS 服务器，见 4.6。
7. **resolved 全局 DNS 作用域总是默认路由**：split DNS 要用 DNS delegate，见 4.6。
8. **OpenWrt 的 BusyBox 没有 `stat`**：playbook 首次 `--check` 报告 5 个文件全有差异，其实哈希一致，是读权限的 `stat` 不存在；
   改用 `ls -l` 权限位换算八进制。连基础命令都可能被裁掉，脚本要在目标设备上实测。
9. **dnsmasq 重启后立即查询会失败**：验证步骤需要重试等待一两秒。
10. **在错误的机器上执行命令**：`vtysh` 在 k8s-master 上报 not found——看提示符（`root@frr-router` / `root@k8s-master`）。

## 改进项

- [ ] BFD：FRR 与 Calico（BIRD）都支持，链路故障检测可从 9 秒降到亚秒级。
- [ ] BGP 会话与前缀数接入 Prometheus 告警（4.7 自写 exporter）。
- [ ] 路由器配置由 Ansible 管理并纳入 CI 校验（4.7）。
- [ ] Grafana、argocd-server、Alertmanager 目前单副本且都在 worker-3 上，节点故障时管理界面全部不可用；可加副本或反亲和。
