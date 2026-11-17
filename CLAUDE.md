# CLAUDE.md

本文件给 Claude Code 提供项目上下文。每次会话开始时自动读取。

## 项目目标

在 32GB Apple Silicon MacBook Air 上用 VMware Fusion 搭建 1 Master + 3 Worker 的 kubeadm 集群，
分阶段完成：容器网络 → CI/CD 与 GitOps → 可观测性与 SLO → BGP 与网络自动化 → Terraform 上云。
这是用于求职（运维 / 网络 / SRE / 云原生）的作品集项目，代码质量、README 和复盘文档都会被面试官看到。

仓库所有者有 H3C 路由交换认证和 SD-WAN 交付经验，网络是强项，K8s 是在补的短板。
解释 K8s 概念时可以类比传统网络设备，网络部分可以讲得更深。

## 环境事实（不要擅自改动）

| 项目 | 值 |
| --- | --- |
| 宿主机 | macOS，Apple Silicon，所有虚拟机为 ARM64 |
| 虚拟化 | VMware Fusion，自定义 NAT 网络 vmnet2 = 10.10.10.0/24，网关 10.10.10.2，Mac 为 10.10.10.1，无 DHCP |
| k8s-master | 10.10.10.10，Ubuntu Server 26.04 ARM64 |
| k8s-worker-1/2/3 | 10.10.10.11 / .12 / .13 |
| frr-router | 10.10.10.20，**OpenWrt**（不是 Ubuntu），单臂路由，只挂 vmnet2，不作为节点默认网关 |
| Pod CIDR | 10.244.0.0/16（kubeadm podSubnet 与 Calico IPPool 必须一致） |
| Service CIDR | 10.96.0.0/12 |
| DNS | 阶段 0–3：节点 DNS = 10.10.10.2（Fusion NAT），节点名由 `/etc/hosts` 解析；CoreDNS 上游 = 4 台节点 IP 上的 systemd-resolved（`DNSStubListenerExtra`，见 `platform/coredns/`）；阶段 4 起 split DNS：OpenWrt dnsmasq 只应答 `lab.internal`，节点 resolved 用 DNS delegate（`/etc/systemd/dns-delegate.d/lab-internal.dns-delegate`，`Domains=~lab.internal`）只把该域发给 10.10.10.20，其余仍走 10.10.10.2；Mac 用 `/etc/resolver/lab.internal`；dnsmasq 上游 = 4 台节点上的 resolved |
| LoadBalancer 池 | 10.200.0.0/24，Calico 原生 LB IPAM（IPPool `loadbalancer-ipv4`，`allowedUses: [LoadBalancer]`），由 `BGPConfiguration.serviceLoadBalancerIPs` 宣告；未使用 MetalLB；固定 IP 用注解 `projectcalico.org/loadBalancerIPs`（grafana .10、argocd .11、lab-api 验收 .20） |
| BGP 拓扑 | 只有 3 台 worker 与 frr-router 建 eBGP（BGPPeer `nodeSelector`），master 不进 LB 数据路径；BGPFilter `export-local-only` 只宣告本节点路由；FRR `timers 3 9`、`maximum-paths 8`、出方向全拒；Mac 访问需一次性 `sudo route -n add -net 10.200.0.0/24 10.10.10.20` |
| BGP | 集群 AS 64512，OpenWrt/FRR AS 64500 |
| 容器运行时 | containerd 2.x（Ubuntu 26.04 apt 自带），SystemdCgroup = true，certs.d 目录式配置；配置文件为 2.x 结构（pause 键名 `sandbox`，字符串用单引号），脚本需同时兼容 1.x |
| CNI | Calico（Tigera Operator），BGP 直接路由，encapsulation: None |
| 镜像仓库 | **公网** Harbor，域名访问，Let's Encrypt 证书（系统根证书即可信任，不分发 CA） |
| Harbor 项目 | `lab`（业务镜像）、`charts`（Helm OCI）、`dockerhub-proxy`（Docker Hub 代理缓存） |
| Harbor 账号 | `robot$lab-ci`（CI 推送）、`robot$k8s-pull`（集群只读） |
| CI | GitHub Actions，`ubuntu-24.04-arm` 托管 Runner，不在集群里跑 Runner |
| 监控 | kube-prometheus-stack（release `kps`，命名空间 `monitoring`，Helm 安装，values 在 `platform/monitoring/`）；lab-api 的 ServiceMonitor、SLO 规则、仪表盘、流量生成器在 `apps/lab-api/`；SLO 规则改动后用 `scripts/extract-prom-rules.sh` + `promtool test rules tests/stage3/slo-rules.test.yaml` 验证 |
| 日志 | Loki（release `loki`）+ Grafana Alloy DaemonSet（release `alloy`），命名空间 `logging`，Helm 安装，values 在 `platform/logging/`；Grafana 数据源 uid `loki`；Loki 标签只放 namespace/pod/container/node/app，请求级字段留在 JSON 内容里 |
| CD | ArgoCD，监听本仓库 `apps/`；Application 定义在 `platform/argocd/`；镜像 tag 由各应用 `kustomization.yaml` 的 `images.newTag` 决定 |
| 节点访问 | Mac 上 `ssh k8s-master` / `k8s-worker-1..3` 直接以 root 登录（`~/.ssh/config` 别名 + 实验专用密钥 `~/.ssh/id_ed25519_k8slab`）；节点网卡名 `enp2s0`；每台节点 `/root/K8s-VMware` 为本仓库副本 |
| 外网依赖 | 节点经 Fusion NAT 出网，DNS 最终由 Mac 上的代理软件以 fake-ip 模式应答（公网域名解析为 198.18.0.0/15）；Mac 代理关闭时拉镜像、访问 Harbor 会失败 |
| 仓库 | 本仓库 K8s-VMware = 基础设施与 GitOps；Go 服务另建仓库 lab-api |

Harbor 域名在脚本中通过环境变量 `HARBOR_HOST` 传入，**脚本、文档、测试资源里不要写死真实域名**（文档统一写 `harbor.example.com`）。
例外：`apps/` 下由 ArgoCD 部署的清单必须写出真实镜像地址（GitOps 的清单即集群实际运行内容），允许出现真实域名。

## 当前进度

- [x] 阶段 0：模板机、containerd、Harbor 接入（4 台节点 verify-node.sh 均 19/19，见 docs/stage0-template.md）
- [x] 阶段 1：kubeadm 集群、Calico、存储、DNS、NetworkPolicy（K8s v1.37.2、Calico v3.33.0，验收全部通过，见 docs/stage1-cluster.md）
- [x] 阶段 2：lab-api、GitHub Actions、ArgoCD（push lab-api → CI 构建推送 Harbor → 写回 newTag → ArgoCD 自动部署，见 docs/stage2-gitops.md）
- [x] 阶段 3：kube-prometheus-stack、告警、SLO、集中日志（可用性 99.5% / 延迟 99%@250ms，多窗口燃烧率告警，故障演练，Loki + Alloy，见 docs/stage3-observability.md）
- [x] 阶段 4：OpenWrt + FRR 与 Calico eBGP、ECMP、内部 DNS（lab.internal）、网络自动化（verify-network.sh 29/29，故障演练 9 秒收敛，见 docs/stage4-network.md）
- [ ] 阶段 5：Terraform 公有云

完成一个阶段后，更新这里和 README 的进度表。

## 关键设计决策（附原因）

- **LoadBalancer 用 Calico 原生 IPAM，不用 MetalLB**：两者的 BGP 都要监听 TCP 179；MetalLB v0.16 起默认启用 frr-k8s，
  仅关 speaker 不够。Calico 3.29+ 自带 LB IPAM，calico-kube-controllers 已在运行，分配与宣告在同一系统，少一个组件。
- **BGPFilter 只宣告本地路由**：Calico 对外部邻居启用 ADD-PATH，会把经 iBGP 学到的其他节点路径（含 master）转发给路由器，
  节点故障时撤销要等 iBGP 超时；过滤后路由器每条路径只来自"下一跳本人"的会话，9 秒内收敛。修改 BGPPeer filters 会重置所有会话。
- **OpenWrt 上的 FRR**：用 opkg 安装（25.x 起为 apk）。接口必须在 `lan` 防火墙区域（wan 区域 input 默认
  REJECT 会挡住 179）。`dhcp.lan.ignore=1`。需要 `net.ipv4.fib_multipath_hash_policy=1`（否则 ECMP 对单一
  客户端只走一条路径）和 `send_redirects=0`（单臂转发时防止 Mac 被重定向绕过路由器）。
- **OpenWrt 没有 Python（BusyBox 还缺 `stat` 等命令）**：Ansible 控制节点在 k8s-master（`network/ansible/`，专用密钥
  `/root/.ssh/id_ed25519_frr`），全部用 `raw` 模块并自己实现 check 模式，改动前先 `--check`，执行后应 `changed=0`。
  BGP 监控用路由器上的 uhttpd CGI（`network/openwrt/bgp-metrics.cgi`，ash + jshn），Prometheus 经 ScrapeConfig 拉取，凭据不出路由器。
  lab.internal 记录在 `network/openwrt/lab-internal.hosts`（dnsmasq addn-hosts），由 Ansible 推送。
- **代码与配置分两个仓库**：CI 回写本仓库更新镜像 tag，不会反向触发 lab-api 的流水线。
- **节点默认网关是 Fusion NAT（.2），不是 OpenWrt**：阶段 0–3 不依赖路由器。
- **Fusion NAT 的 DNS 不支持 EDNS**：它不是转发器，而是把查询交给 macOS 解析后自己拼应答（flags 只有 `qr aa`，没有 `ra`）。
  带 EDNS 的查询会收到畸形报文（末尾多 16 字节），且不支持 TCP；与 fake-ip 无关。systemd-resolved 会降级重试，CoreDNS 和
  dnsmasq 不会。所以 CoreDNS 不直接转发给 10.10.10.2，而是转发给各节点 IP 上的 resolved；`kubeadm upgrade` 后要重新应用
  `platform/coredns/configmap.yaml`；OpenWrt dnsmasq 同样不能以 10.10.10.2 为上游（实测解析为空，日志 `refused to do a recursive query`），上游改为 4 台节点上的 resolved（`noresolv=1` + 4 个 `server`）。
- **内部 DNS 只做增强，`/etc/hosts` 始终兜底**：`controlPlaneEndpoint` 是 `k8s-master:6443`，kubelet/kube-proxy 每次
  重连都要解析它，DNS 一挂节点就 NotReady。所以节点名永远写在 `/etc/hosts`（nsswitch `files dns`，本地优先），
  OpenWrt 的 dnsmasq 只提供额外名字（`*.lab.internal`，如 grafana/argocd 指向 LoadBalancer IP）。
  采用 split DNS 而不是"主 .20、备 .2"：dnsmasq 上游是节点 resolved，主备方案会形成 resolved → dnsmasq → resolved 环路；
  按域名分流后路由器宕机只影响 `*.lab.internal`，公网解析不经过路由器、也不用等主 DNS 超时。后缀用 `.internal`（ICANN 2024 年保留给内网），
  不用 `.local`（被 mDNS 占用，macOS 解析会出问题）。

## 编码约定

- Shell 脚本：`#!/usr/bin/env bash` + `set -euo pipefail`，必须能重复执行（幂等），关键配置写完要自检并
  在失败时给出清晰报错。提交前跑 `bash -n` 和 `shellcheck`。
- **在 Mac 上运行的脚本必须兼容 macOS 自带的 bash 3.2**：不用关联数组、`${var,,}`、`mapfile`、`readarray`。
- 在节点上运行的脚本注明"root，在哪台机器执行"。
- 版本号（Calico、local-path-provisioner、Helm chart 等）通过环境变量传入或在文件中显式固定，
  不使用 latest；写新版本号前先查官方 release 页面确认。
- 所有镜像必须有 ARM64 版本。
- YAML 文件头部用注释说明用途和所属阶段。
- 注释和文档用中文，代码标识符用英文。
- 每个阶段在 `tests/stageN/` 下放验收用资源，在 `scripts/verify-*.sh` 里自动化验收。

## 安全红线

- 不提交：kubeconfig / `admin.conf`、`kubeadm-init.log`、join 命令、任何私钥、`*.tfstate`、`*.tfvars`、
  Harbor token、云厂商 AK/SK、GitHub PAT。`.gitignore` 已覆盖，提交前仍要 `git status` 检查。
- K8s Secret 不以明文 YAML 进仓库；需要进 Git 时用 Sealed Secrets 或 SOPS。
- 凭据通过交互输入或环境变量获取，不写进脚本，不出现在命令行参数里（会进 shell 历史）。
- 对集群执行破坏性操作（删除命名空间、`kubeadm reset`、etcd 恢复、drain 节点）之前，先说明影响并等待确认，
  并提醒先在 Fusion 打快照。

## 目录说明

```text
scripts/      节点与集群的初始化、验收脚本
kubeadm/      kubeadm 配置
platform/     平台组件（calico、coredns、metrics-server、monitoring、logging、argocd）
apps/         ArgoCD 管理的应用（阶段 2 起）
network/      OpenWrt 配置（openwrt/）、Ansible（ansible/）（阶段 4）
terraform/    阶段 5
tests/        各阶段验收资源
docs/         实验手册 plan.md、复盘 postmortems/、截图 images/
```

## 参考

完整实验手册在 `docs/plan.md`（从 Claude Doc 导出）。故障演练清单、验收标准、简历条目都在里面。
