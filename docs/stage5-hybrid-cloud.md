# 阶段 5：Terraform + 混合云 BGP（阿里云）

> 目标：用 Terraform 管理云上网络资源，把本地实验网与阿里云 VPC 用 WireGuard 隧道 + eBGP 打通，
> 云主机直接访问本地 K8s 的 LoadBalancer 服务，隧道故障时路由自动撤销并告警。
> 配置：[`terraform/`](../terraform/)（bootstrap：OSS state 桶；hybrid：VPC 侧资源）、[`network/aliyun/`](../network/aliyun/)（ECS 上的 WireGuard 与 FRR）、
> [`network/openwrt/frr.conf`](../network/openwrt/frr.conf)（路由器侧新增云邻居），验收 [`scripts/verify-hybrid.sh`](../scripts/verify-hybrid.sh)。

## 整体结构

```text
   本地实验网（VMware Fusion）                                    阿里云 VPC 172.16.0.0/12（杭州）
┌────────────────────────────────┐   WireGuard（UDP 51820）   ┌─────────────────────────────────────┐
│ frr-router .20   AS 64500      │══ wg0 10.255.255.1/30 ════│ aliyun-edge（ECS）AS 64600            │
│  ├ eBGP 3 台 worker（3 9）     │   eBGP（10 30）            │  wg0 10.255.255.2/30                  │
│  │  向集群只宣告 172.16.0.0/12  │◀── 172.16.0.0/12 ──────────│  宣告 172.16.0.0/12                   │
│  └ 向云宣告 10.10.10.0/24、    │─── 10.10.10.0/24 ─────────▶│  内核路由 src = ECS 的 VPC 地址         │
│     10.200.0.0/24（及 /32）    │    10.200.0.0/24(+/32)     │                                       │
└────────────────────────────────┘                            │ VPC 路由表（Terraform）：               │
       主动发起 + keepalive 25s（两层 NAT 后）                │  10.10.10.0/24、10.200.0.0/24 → ECS    │
                                                              └─────────────────────────────────────┘
```

| 组件 | 版本 |
| --- | --- |
| Terraform | v1.17.2 |
| alicloud provider | 2.2.0（2026-10 刚升到 2.x 大版本） |
| ECS | 已有的年付 2c2g，Ubuntu 26.04 x86_64，内核 7.0（自带 wireguard 模块） |
| FRR（ECS） | 10.5.1（Ubuntu 源） |

| 地址 | 用途 |
| --- | --- |
| 172.16.0.0/12 | VPC 网段（ECS 所在交换机 172.28.48.0/20） |
| 10.255.255.0/30 | 隧道（路由器 .1，ECS .2） |
| AS 64600 | 云上边界路由器 |

ECS 公网 IP、阿里云账号 ID、实例 ID 不进仓库：文档写 `203.0.113.10`（RFC 5737 文档地址），Terraform 用 data source 查询或 `TF_VAR_*` 传入。

**为什么选这个范围**：复用年付 ECS 当云上边界路由器，几乎零额外费用；与 SD-WAN 的 overlay + 动态路由同构，
能同时展示 Terraform、隧道、跨域 eBGP 与 VPC 路由。托管 K8s（ACK）贴近云原生岗位但每天有固定费用，列为后续方向。

## 5.1 准备：RAM、凭据、远程 state

- **RAM 子用户** `terraform-lab`，只开 OpenAPI 访问，授予 `AliyunECSFullAccess`、`AliyunVPCFullAccess`、`AliyunOSSFullAccess`。
  这三个系统策略偏宽，**不是**最小权限，收紧为自定义策略列入改进项。不要用控制台"快速创建"里的"程序访问超级用户"模板。
- **凭据只在环境变量里**，交互输入不进 shell 历史、不进文件：

  ```bash
  read -rs "ALIBABA_CLOUD_ACCESS_KEY_ID?AccessKey ID: "; echo; read -rs "ALIBABA_CLOUD_ACCESS_KEY_SECRET?AccessKey Secret: "; echo
  export ALIBABA_CLOUD_ACCESS_KEY_ID ALIBABA_CLOUD_ACCESS_KEY_SECRET ALIBABA_CLOUD_REGION=cn-hangzhou \
         ALICLOUD_ACCESS_KEY="$ALIBABA_CLOUD_ACCESS_KEY_ID" ALICLOUD_SECRET_KEY="$ALIBABA_CLOUD_ACCESS_KEY_SECRET"
  ```

  provider 2.x 只认 `ALIBABA_CLOUD_*`（`ALICLOUD_*` 自 1.228 起弃用）；OSS backend 是 Terraform 核心代码，仍读 `ALICLOUD_*`，所以两套都导出。
- **[`terraform/bootstrap/`](../terraform/bootstrap/main.tf)**：state 桶 `k8s-vmware-tfstate-<账号ID>`（账号 ID 全局唯一，无需随机数 provider），
  私有 ACL + 阻止公共访问 + 版本控制 + AES256 加密 + `prevent_destroy`。先有鸡先有蛋：这个模块自己的 state 只能留在本地（已被 .gitignore 排除）。
  `.terraform.lock.hcl` 锁定 darwin_arm64 / linux_amd64 / linux_arm64 三个平台的哈希并提交。

## 5.2 Terraform：VPC 侧资源

[`terraform/hybrid/`](../terraform/hybrid/main.tf)：现有 VPC 与 ECS 只用 `data` 只读引用（不进 state，`terraform destroy` 删不掉年付机器），
Terraform 只拥有三个资源：ECS 安全组上放行 UDP 51820 的规则、VPC 路由表里 `10.10.10.0/24` 与 `10.200.0.0/24` → 下一跳 ECS 的两条路由。

```bash
cd terraform/hybrid
export TF_VAR_edge_instance_id=i-xxxxxxxx
B=$(terraform -chdir=../bootstrap output -raw bucket); echo "bucket=[$B]"
terraform init -reconfigure -backend-config="bucket=$B"
terraform plan -out=tfplan && terraform apply tfplan     # 审核过的计划文件原样执行；*.tfplan 已被 .gitignore 排除
```

审核 plan 的要点：`3 to add, 0 to destroy`；不出现 `alicloud_instance`；公网 IP 输出为 `(sensitive value)`。

## 5.3 WireGuard 隧道

| 决策 | 原因 |
| --- | --- |
| 路由器主动发起，`persistent_keepalive 25` | 路由器在 Fusion NAT + 家宽两层 NAT 后，云上连不进来；保活维持 NAT 映射 |
| `AllowedIPs = 0.0.0.0/0` 且不自动加路由 | 隧道里走哪些网段由 BGP 决定。ECS 侧 `Table = off`（否则 wg-quick 抢走默认路由、ECS 失联），路由器侧 `route_allowed_ips 0` |
| 私钥只留在本机 | 两端各自 `wg genkey`，只交换公钥；ECS 配置用 `PostUp = wg set %i private-key ...` 加载，[`wg0.conf`](../network/aliyun/wg0.conf) 不含私钥可以进仓库 |
| Mac 代理（Shadowrocket TUN）加 `IP-CIDR,<ECS 公网 IP>/32,DIRECT,no-resolve` 并置顶 | WireGuard UDP 经 Fusion NAT 从 Mac 出网，TUN 会把它送进代理节点 |

ECS：`apt-get install -y wireguard-tools`，生成密钥，`net.ipv4.ip_forward=1`（[`/etc/sysctl.d/90-hybrid-edge.conf`]），
`systemctl enable --now wg-quick@wg0`。路由器：`apk add wireguard-tools kmod-wireguard`，uci 配置 `network.wg0`（proto wireguard，
私钥用 `$(cat /etc/wireguard/privatekey)` 读入，不回显）与对端 `network.aliyun=wireguard_wg0`，wg0 加入 `lan` 防火墙区域。

**两个坑**：

1. **装完 WireGuard 后 `ifup wg0` 没反应**：`ifstatus wg0` 显示 `"proto": "none"`、`NO_DEVICE`。netifd 只在启动时加载协议处理脚本
   （`/lib/netifd/proto/wireguard.sh`），`apk add` 之后要 `service network restart`（会让 eth0 抖一下，BGP 约 10 秒恢复）。
2. **ping 隧道对端"通了"是假象**：路由器上根本没有 wg0，`ip route get 10.255.255.2` 走默认路由出了 Mac，**Shadowrocket 的 TUN 用户态协议栈
   对任意目的地址的 ICMP 都在本地应答**（9–20 ms）。验证隧道要看 `wg show` 的 `latest handshake` 与 `ip route get` 的出接口，不能只看 ping。

## 5.4 隧道上的 eBGP

[`network/aliyun/frr.conf`](../network/aliyun/frr.conf)（ECS）与 [`network/openwrt/frr.conf`](../network/openwrt/frr.conf)（路由器，经 Ansible 下发）：

| 决策 | 原因 |
| --- | --- |
| 路由器向云宣告 `10.10.10.0/24`（`network`）与 `10.200.0.0/24 le 32`；不宣告 Pod 网段 | 云上只需要访问节点与服务入口 |
| **路由器向集群宣告 `172.16.0.0/12`**（阶段 4"出方向全拒"的唯一例外） | 云主机访问 LB 时 worker 回包目的是 172.28.x；节点默认网关是 .2，没有这条路由回包会去 Fusion NAT，路径不对称。Calico 把它装进节点内核（`via 10.10.10.20 proto bird`） |
| 隧道邻居 `timers 10 30`，实验网内 `3 9` | 公网抖动大，WAN 计时器比 LAN 宽松，避免震荡；要更快检测应上 BFD |
| ECS 静态路由 `172.16.0.0/12 → 172.28.63.253` 后 `network 172.16.0.0/12` | `network` 宣告要求 RIB 里有该前缀；指向交换机网关（VPC vRouter），转发行为与默认路由相同 |
| **ECS 对 BGP 路由 `set src` 为 VPC 地址**（`ip protocol bgp route-map SET-SRC`） | 否则 ECS 主动访问实验网时源地址是 wg0 的 10.255.255.2，节点没有隧道网段的回程路由（实测：能 ping 通路由器，ping 不通 worker）。不把隧道网段宣告给集群，隧道地址是两台路由器之间的细节 |

ECS 上 FRR 有 `frr-reload.py`（需要 Python），改配置用 `systemctl reload frr` 只下发差异、不断会话；OpenWrt 没有 Python，只能重启。

**坑**：`ip protocol bgp route-map` 只对之后新下发到内核的路由生效，reload 后已有的 3 条路由没有带上 `src`，
需要 `clear ip bgp 10.255.255.1` 让路由重新下发（隧道会话重建约 10 秒）。

**坑**：master 上的仓库副本还在 `main` 分支，`git pull` 拉不到阶段 5 分支的 frr.conf，Ansible 比对无差异、什么都没改。
跨分支开发时，控制节点要先 `git switch` 到工作分支。

验证（[`verify-hybrid.sh`](../scripts/verify-hybrid.sh)）：路由器 4 个邻居 Established、`172.16.0.0/12 dev wg0`；ECS 有
`10.10.10.0/24`、`10.200.0.0/24`、`10.200.0.20` 三条 `src 172.28.x` 的路由；3 台 worker 有回程路由；**ECS 上 `curl http://10.200.0.20/`
返回本地 lab-api Pod 的 hostname，Grafana 返回 302**；worker ping 通 ECS 的 VPC 地址。

取舍：master 不与路由器建邻居，Calico 也不在节点间转发外部学到的路由，所以 master 没有 `172.16/12`，云 ↔ master 不通；LB 服务都在 worker 上，不影响业务。
需要时可让 master 也与路由器建邻居并配只收不发的过滤器。

## 5.5 监控、自动化与验收

- **BGP 监控零改动**：exporter 遍历所有邻居，自动输出 `frr_bgp_peer_up{peer="10.255.255.2",remote_as="64600"}`，告警与仪表盘同样自动覆盖。
- **Ansible**：增加 `firewall.@zone[0].network = [lan, wg0]` 与 `sysupgrade.conf` 保留 `/etc/wireguard/`；`network.wg0`（含私钥）仍不由 Ansible 管理。二次执行 `changed=0`。
- **[`verify-hybrid.sh`](../scripts/verify-hybrid.sh)** 18/18：隧道握手（< 180 秒）、出接口、ECS 默认路由未被抢、eBGP、双向路由、Pod 网段未泄露、`src`、
  3 台 worker 回程路由、端到端、监控；设置了凭据时额外执行 `terraform plan -detailed-exitcode` 检查云上配置漂移。
- **[`verify-network.sh`](../scripts/verify-network.sh)** 适配新拓扑（29/29）：只统计 AS 64512 的邻居；向集群只允许宣告 `172.16.0.0/12`。

## 5.6 故障演练：公网隧道中断

方式：ECS 上 `iptables` 同时丢弃入方向 `udp dport 51820` 与出方向 `udp sport 51820`（两端接口都在，报文过不去，等同运营商链路故障或 NAT 映射失效），
并设 4 分钟后自动解除的保护。观测：ECS 每秒访问一次 lab-api（10.200.0.20）、路由器 BGP 日志、Prometheus 告警。

| 时间（UTC） | 事件 |
| --- | --- |
| 08:08:10 | 阻断隧道 |
| 08:08:12 | ECS 访问开始失败（报文进了已不通的隧道） |
| 08:08:31 | 路由器保持时间到期，`Down BGP Notification send`；撤销 `172.16/12`，worker 上的回程路由同时消失 |
| 08:09:14 | `FrrBgpPeerDown{peer="10.255.255.2"}` pending |
| 08:09:44 | `FrrBgpPeerDown` firing（距故障约 94 秒） |
| 演练期间 | Mac 访问 Grafana（实验网内 LB）始终 302，3 个 worker 邻居与 ECMP 不受影响 |
| 08:10:05 | 解除阻断 |
| 08:10:09 | 会话重建（两端同时发起，`Cease/Connection Collision Resolution` 后保留一条），End-of-RIB |
| 08:10:12 | ECS 访问恢复（解除后 7 秒） |
| 08:10:39 | 告警恢复 |

结论：

- **路由撤销用了 21 秒而不是 30 秒**：保持时间从**最后一次收到报文**开始计算，不是从故障时刻开始；10 秒一次的 keepalive 意味着撤销时间在 20–30 秒之间。
- 故障域隔离符合设计：隧道断开只影响云 ↔ 实验网，实验网内部的 BGP、ECMP、LB 访问完全不受影响。
- 撤销前的约 20 秒，ECS 的流量被送进已经不通的隧道（黑洞）；要缩短需上 BFD。
- 演练后 `FrrBgpPeerFlapping`（15 分钟内断开 ≥ 3 次）触发：当天 `clear ip bgp`、演练、连接冲突各计一次，属于告警正确工作；15 分钟后自动恢复。

## 踩坑记录

1. **provider 2.x 不认 `ALICLOUD_*` 凭据变量**：报 `no valid credential sources`，改用 `ALIBABA_CLOUD_*`；OSS backend 仍读旧名字。
2. **OSS 未开通**：`403 UserDisable`（`0003-00000801`）与 RAM 权限无关，要用主账号在控制台开通 OSS（按量付费，state 费用可忽略）。
3. **OSS 不允许并发修改同一个桶的配置**：ACL、阻止公共访问、版本控制、加密并行创建报 `409 ConcurrentUpdateBucketFailed`，用 `depends_on` 串行化。
   云 API 的限制 Terraform 不知道，要显式写进依赖关系。
4. **ECS 重装后 SSH 报 `REMOTE HOST IDENTIFICATION HAS CHANGED`**：先在已登录的可信通道（Termius）里 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
   核对指纹，一致后再 `ssh-keygen -R`。不要看到警告就直接删记录——它和中间人攻击的表现一模一样。
5. **netifd 不认新装的 wireguard 协议**、**TUN 让 ping 隧道地址假通**、**`set src` 需要重新下发路由**、**控制节点分支不对**：见上文各节。

## 改进项

- [ ] RAM 权限收紧为自定义策略（只允许操作指定安全组规则、路由表条目与 state 桶）。
- [ ] BFD（FRR 两端都支持）把隧道故障检测从 20–30 秒降到秒级。
- [ ] OSS backend 加 Tablestore 状态锁（多人协作时防止并发 apply）。
- [ ] Terraform 在 CI 中执行 `fmt -check`、`validate` 与 `plan`（OIDC 角色扮演，不在 GitHub 存长期 AK）。
- [ ] WireGuard 隧道放入独立的 `cloud` 防火墙区域，只放行 BGP 与需要的转发。
- [ ] 第二条隧道（另一地域或另一台 ECS）做多出口 ECMP / 主备。
- [ ] 托管 K8s（ACK）+ ArgoCD 多集群，复用这条隧道。
