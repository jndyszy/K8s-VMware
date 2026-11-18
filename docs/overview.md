# 项目总览：5 分钟读懂 K8s-VMware

一台 32GB Apple Silicon MacBook 上的 1 master + 3 worker kubeadm 集群，分 6 个阶段从节点初始化做到混合云：
每个阶段都有实验手册、自动化验收脚本和故障演练记录，所有变更经分支 + PR 合并（共 19 个 PR）。

## 全景

```text
                       GitHub ──(Actions, ARM64)──▶ Harbor（公网，LE 证书）
                         │  写回镜像 tag                    │ 拉取
                         ▼                                  ▼
   Mac ──route──▶ frr-router（OpenWrt + FRR，AS 64500）◀═eBGP═▶ k8s-worker-1/2/3（Calico，AS 64512）
   *.lab.internal   │  ECMP、BGP exporter、dnsmasq              │  ArgoCD · lab-api · Prometheus/Grafana/Loki
                    ║ WireGuard + eBGP（AS 64600）              k8s-master（控制平面）
                    ▼
            阿里云 ECS（杭州 VPC 172.16.0.0/12）── Terraform 管理安全组规则与 VPC 路由，OSS 远程 state
```

## 六个阶段

| 阶段 | 交付 | 验收 / 演练 | 手册 |
| --- | --- | --- | --- |
| 0 模板与节点 | Ubuntu 26.04 ARM64 模板机、containerd 2、Harbor Docker Hub 代理缓存、克隆脚本 | verify-node 19/19 × 4 | [stage0](stage0-template.md) |
| 1 集群 | kubeadm v1.37、Calico BGP 无封装、local-path、metrics-server、NetworkPolicy | verify-cluster 13/13 | [stage1](stage1-cluster.md) |
| 2 GitOps | Go 服务 lab-api、GitHub Actions → Harbor → ArgoCD 自动部署 | 提交到上线约 5.5 分钟 | [stage2](stage2-gitops.md) |
| 3 可观测性 | kube-prometheus-stack、SLO（99.5% / 99%@250ms）、多窗口燃烧率告警、Loki + Alloy | 注入 50% 错误，约 4 分钟告警 | [stage3](stage3-observability.md) |
| 4 网络 | OpenWrt + FRR eBGP、LoadBalancer ECMP、split DNS、BGP exporter、Ansible | verify-network 29/29；断网 9 秒收敛 | [stage4](stage4-network.md) |
| 5 混合云 | Terraform（alicloud）、WireGuard 隧道、隧道上 eBGP、云 ↔ 实验网互通 | verify-hybrid 18/18；隧道中断 21 秒撤销 | [stage5](stage5-hybrid-cloud.md) |

## 值得一看的设计决策

| 决策 | 为什么 | 详见 |
| --- | --- | --- |
| CoreDNS 转发给节点上的 systemd-resolved | Fusion NAT 的 DNS 自己拼应答、不支持 EDNS，Go 程序解析失败；resolved 会降级重试 | [stage2](stage2-gitops.md) |
| 代码与配置分两个仓库 | CI 回写镜像 tag 不会反向触发流水线；发布历史即配置仓 Git 历史 | [stage2](stage2-gitops.md) |
| 燃烧率告警分四档、冷启动误报用静默处理 | 长短窗口组合兼顾灵敏与准确；新服务长窗口数据不足，改规则会掩盖真实问题 | [stage3](stage3-observability.md) |
| Calico 原生 LB IPAM，不用 MetalLB | MetalLB v0.16 默认启用 frr-k8s 抢 TCP 179；少一个组件 | [stage4](stage4-network.md) |
| BGPFilter 只宣告本地路由 | Calico 对外 ADD-PATH 让节点故障撤销等 iBGP 超时；过滤后 9 秒收敛 | [stage4](stage4-network.md) |
| split DNS 用 systemd DNS delegate | 全局 DNS 作用域永远是默认路由，会形成 resolved ↔ dnsmasq 环路 | [stage4](stage4-network.md) |
| BGP exporter 跑在路由器 CGI 上 | OpenWrt 没有 Python；凭据不出路由器、零新增组件 | [stage4](stage4-network.md) |
| Terraform 只读引用现有 ECS/VPC | `terraform destroy` 删不掉年付机器；只管安全组规则与路由 | [stage5](stage5-hybrid-cloud.md) |
| 隧道路由 `set src` 为 VPC 地址 | 隧道网段不泄露进集群，回程路由只需 172.16/12 | [stage5](stage5-hybrid-cloud.md) |

## 怎么读这个仓库

1. 先看 [README](../README.md) 的架构与进度，再按兴趣挑一个阶段手册：每份都按"命令 → 为什么 → 踩坑 → 演练 → 改进项"组织。
2. 网络方向重点看 [stage4](stage4-network.md) 的 4.3（ADD-PATH 排查）与 4.5（故障演练），以及 [stage5](stage5-hybrid-cloud.md) 的 5.4。
3. SRE 方向重点看 [stage3](stage3-observability.md) 的 SLO、告警规则测试与演练复盘。
4. 自动化验收在 [`scripts/verify-*.sh`](../scripts/)，告警规则测试在 [`tests/`](../tests/)。

## 边界

单人实验环境：单 master（控制平面非高可用）、流量来自流量生成器、告警未接通知渠道、故障检测未上 BFD、
RAM 权限未收紧到最小。这些都列在各手册的"改进项"里。
