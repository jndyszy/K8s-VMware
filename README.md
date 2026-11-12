# K8s-VMware

在 32GB Apple Silicon MacBook 上用 **VMware Fusion** 搭建 1 Master + 3 Worker 的 kubeadm 集群，并把容器网络、CI/CD、GitOps、可观测性与 SLO、BGP 网络自动化、Terraform 串成一个完整的云原生实验项目。

## 架构

| 组件 | 说明 |
| --- | --- |
| 虚拟化 | VMware Fusion，自定义 NAT 网络 vmnet2（10.10.10.0/24） |
| 节点 | Ubuntu Server 26.04 ARM64：k8s-master `.10`，k8s-worker-1/2/3 `.11-.13`；frr-router `.20` 为 OpenWrt |
| Kubernetes | kubeadm + containerd，Pod 10.244.0.0/16，Service 10.96.0.0/12 |
| CNI | Calico，BGP 直接路由（AS 64512） |
| 镜像仓库 | 公网 Harbor（Let's Encrypt），Docker Hub 代理缓存、Trivy 扫描、机器人账号 |
| CI/CD | GitHub Actions（ARM64 Runner）→ Harbor → ArgoCD |
| 网络 | OpenWrt + FRR（AS 64500，单臂路由 `.20`）与集群 eBGP 对等，宣告 Pod 网段与 LoadBalancer IP（10.200.0.0/24），ECMP |
| DNS | 节点名由 `/etc/hosts` 解析（兜底）；阶段 4 起 OpenWrt dnsmasq 提供 `lab.internal` 内部域名 |

### 出口与 DNS 设计

- **出口走 Fusion NAT（`.2`），OpenWrt 不当网关**：OpenWrt 单臂旁挂，只负责与集群建 eBGP、学习 Pod / LoadBalancer 路由，
  供 Mac 访问集群服务。阶段 0–3 完全不依赖路由器，路由器故障只影响 BGP 实验。
- **内部 DNS 只做增强，不做单点**：控制平面地址 `k8s-master:6443` 由每台节点的 `/etc/hosts` 解析，DNS 宕机不会导致节点
  NotReady；dnsmasq 提供 `grafana.lab.internal`、`argocd.lab.internal` 等指向 LoadBalancer IP 的名字，上游转发 `.2`，
  节点 DNS 配主 `.20`、备 `.2`。

<!-- 拓扑图放到 docs/images/topology.png 后取消注释 -->
<!-- ![topology](docs/images/topology.png) -->

## 进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 0 | 模板机、containerd、Harbor 接入、Docker Hub 代理缓存（[手册](docs/stage0-template.md)） | ✅ |
| 1 | kubeadm 集群、Calico、存储、DNS、NetworkPolicy（[手册](docs/stage1-cluster.md)） | ✅ |
| 2 | Go 服务 lab-api、GitHub Actions、Harbor、ArgoCD GitOps | ⬜ |
| 3 | kube-prometheus-stack、告警、SLI/SLO、错误预算 | ⬜ |
| 4 | OpenWrt/FRR + Calico BGP、LoadBalancer IP 宣告、内部 DNS、网络自动化 | ⬜ |
| 5 | Terraform 公有云 VPC/ECS | ⬜ |
| — | 故障演练与复盘（[docs/postmortems](docs/postmortems)） | ⬜ |

## 目录结构

```text
.
├── scripts/
│   ├── node-init.sh        # 阶段 0：模板机初始化（root，节点上执行）
│   ├── verify-node.sh      # 阶段 0：单节点检查
│   ├── clone-setup.sh      # 阶段 0：克隆机设置主机名、静态 IP、machine-id
│   ├── master-init.sh      # 阶段 1：kubeadm init + Calico（master 上执行）
│   ├── post-install.sh     # 阶段 1：存储、metrics-server、拉取凭据（Mac 上执行）
│   └── verify-cluster.sh   # 阶段 1：集群验收（Mac 上执行）
├── kubeadm/                # kubeadm 配置
├── platform/               # 平台组件配置（Calico、metrics-server、监控、ArgoCD……）
├── tests/                  # 各阶段验收用的测试资源
├── apps/                   # ArgoCD 管理的应用（阶段 2）
├── network/                # OpenWrt/FRR 配置与网络自动化（阶段 4）
├── terraform/              # 阶段 5
└── docs/                   # 实验手册（stage0-template.md、stage1-cluster.md …）、复盘、截图

CLAUDE.md                   # 给 Claude Code 的项目上下文
```

## 快速开始（阶段 0–1）

**前置**：Harbor 已建好 `dockerhub-proxy` 项目（**公开**，创建时打开「镜像代理」并关联 Docker Hub）和只读机器人账号 `robot$k8s-pull`；Mac 上已安装 `kubectl`、`helm`。

```bash
# ---- 模板机（root）----
export HARBOR_HOST=harbor.example.com          # 换成你的 Harbor 域名
./scripts/node-init.sh
./scripts/verify-node.sh
# 关机 → 快照 base-ready → 克隆 4 台

# ---- 每台克隆机（root，一次只开一台）----
# 克隆机拿不到 IP（安装程序的 netplan 绑定了模板机 MAC），先在控制台临时配置：
#   ip addr add 10.10.10.10/24 dev enp2s0 && ip route add default via 10.10.10.2
./scripts/clone-setup.sh k8s-master   10.10.10.10   # 依次 worker-1/2/3 → .11/.12/.13
# 重启后在 Mac 上 ssh-keygen -R <IP>（SSH 主机密钥已重新生成）

# ---- k8s-master（root）----
CALICO_VER=v3.33.0 ./scripts/master-init.sh         # 版本以 Calico 官网为准
# 在三台 Worker 上执行 /root/join-command.sh 的内容

# ---- Mac ----
scp root@10.10.10.10:/etc/kubernetes/admin.conf ~/.kube/config
HARBOR_HOST=harbor.example.com LOCAL_PATH_VER=v0.0.37 ./scripts/post-install.sh
HARBOR_HOST=harbor.example.com ./scripts/verify-cluster.sh
```

## 安全说明

本仓库公开时，以下内容**绝不提交**（已在 `.gitignore` 中排除）：`admin.conf` / kubeconfig、`kubeadm-init.log` 与 join 命令、任何私钥、`*.tfstate`、`*.tfvars`、Harbor 机器人 token、云厂商 AK/SK。一旦误提交，立即作废并重新生成对应凭据。
