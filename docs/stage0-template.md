# 阶段 0：模板机与镜像加速

> 目标：做出一台"装好就能加入集群"的 Ubuntu 模板机，克隆出 4 个节点；所有 Docker Hub 镜像经自建 Harbor 代理缓存拉取。
> 自动化脚本：[`scripts/node-init.sh`](../scripts/node-init.sh)（一次做完下面 1–8 步）、[`scripts/verify-node.sh`](../scripts/verify-node.sh)（只检查，不修改）。
> 本文是手动逐步执行的版本，并解释每一步的作用。

## 整体链路

```text
节点 containerd ──拉 docker.io/xxx──▶ certs.d/docker.io/hosts.toml
                                        │ 改写到
                                        ▼
                          Harbor 项目 dockerhub-proxy（公开，镜像代理）
                                        │ 本地无缓存时回源
                                        ▼
                                   Docker Hub
```

出口：所有节点默认网关为 Fusion NAT `10.10.10.2`，不经过 OpenWrt（见 README「出口与 DNS 设计」）。

## 0. 虚拟机与系统

| 项目 | 取值 | 原因 |
| --- | --- | --- |
| CPU / 内存 / 硬盘 | 2 核 / 4 GB / 40 GB（NVMe，不预分配） | kubeadm 控制平面要求 ≥ 2 核；4 台共 16 GB，给 Mac 留余量 |
| 网卡 | 自定网络 vmnet2 | vmnet2 = 10.10.10.0/24，开启 NAT、关闭 DHCP |
| 系统 | Ubuntu Server 26.04 **ARM64**（live-server 镜像） | Apple Silicon 只能跑 ARM64；Server 版比桌面版省约 1 GB 内存 |
| 安装选项 | 静态 IP `10.10.10.100/24`，网关/DNS `10.10.10.2`；取消 LVM；装 OpenSSH；不装任何 snap | LVM 默认只分一半磁盘给根分区；docker snap 会与 containerd 冲突 |

以下命令均以 root 执行（`sudo -i`）。

## 1. 静态主机名解析 `/etc/hosts`

```bash
cat >>/etc/hosts <<'EOF'
10.10.10.10 k8s-master
10.10.10.11 k8s-worker-1
10.10.10.12 k8s-worker-2
10.10.10.13 k8s-worker-3
10.10.10.20 frr-router
EOF
```

- **作用**：节点之间用名字互访。`kubeadm.yaml` 的 `controlPlaneEndpoint` 是 `k8s-master:6443`，kubelet 每次重连都要解析它。
- **为什么不用 DNS**：解析在本地完成，不依赖任何服务；DNS 宕机也不会让节点 NotReady。阶段 4 的内部 DNS 只做增强。

## 2. 关闭 swap 和防火墙

```bash
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab && rm -f /swap.img
ufw disable
```

- **swap**：kubelet 默认在有 swap 时拒绝启动。K8s 按"请求的内存"调度、按"实际内存压力"驱逐 Pod，swap 会让这两个数都失真。
- **ufw**：实验环境关闭，避免挡住 6443（API Server）、10250（kubelet）、179（BGP）等端口；访问控制交给 NetworkPolicy。

## 3. 内核模块与转发参数

```bash
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay && modprobe br_netfilter

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
```

| 配置 | 作用 | 网络类比 |
| --- | --- | --- |
| `overlay` | 容器镜像分层存储使用的文件系统 | — |
| `br_netfilter` + `bridge-nf-call-iptables` | 让经过 Linux 网桥的二层流量也经过 iptables；kube-proxy 的 Service DNAT 依赖它 | 在二层交换的流量上也能套 ACL |
| `ip_forward` | 允许节点在网卡之间转发 Pod 流量 | 把主机变成一台路由器 |

写入 `/etc/modules-load.d` 和 `/etc/sysctl.d` 保证重启后仍生效。

## 4. 容器运行时 containerd

```bash
apt-get update && apt-get install -y containerd apt-transport-https ca-certificates curl gpg
mkdir -p /etc/containerd && containerd config default >/etc/containerd/config.toml

# cgroup 驱动改为 systemd，与 kubelet 一致
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 启用 certs.d 目录式仓库配置（1.x 默认值写作 ""，2.x 写作 ''，两处都要改）
sed -ri "s#^([[:space:]]*)config_path = (\"\"|'')#\1config_path = '/etc/containerd/certs.d'#" /etc/containerd/config.toml
```

- **containerd**：真正拉镜像、起容器的运行时；kubelet 通过 CRI 接口调用它。
- **SystemdCgroup**：Linux 上 systemd 已经在管理 cgroup，如果 containerd 再用另一套 cgroupfs 驱动，同一台机器上就有两个资源管理者，内存压力下节点会不稳定。
- **config_path**：指向 `/etc/containerd/certs.d`，containerd 才会读取下一步写的 `hosts.toml`。containerd 2.x 有两处 `config_path`（CRI 镜像插件与 transfer 服务），都要改。

## 5. docker.io 镜像经 Harbor 代理缓存

```bash
mkdir -p /etc/containerd/certs.d/docker.io
cat >/etc/containerd/certs.d/docker.io/hosts.toml <<'EOF'
server = "https://registry-1.docker.io"

[host."https://harbor.example.com/v2/dockerhub-proxy"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOF
systemctl restart containerd && systemctl enable containerd
```

- **作用**：拉 `docker.io/library/nginx` 时，containerd 先请求 `https://<Harbor>/v2/dockerhub-proxy/library/nginx`。Harbor 有缓存直接返回，没有就回源 Docker Hub 拉取并缓存。
- **好处**：4 个节点只回源一次；不受 Docker Hub 匿名拉取频率限制影响；配合 Harbor 的 Trivy 扫描。
- **`override_path = true`**：Harbor 的代理项目路径是 `/v2/<项目名>/...`，不是标准的 `/v2/...`，必须告诉 containerd 用写好的路径。
- **`server` 一行是回退地址**：Harbor 不可用时 containerd 会直连 Docker Hub。这保证了可用性，但也意味着**拉取成功不能证明走了代理**（见踩坑 3）。
- **Harbor 侧要求**：项目 `dockerhub-proxy` 必须**公开**（containerd 是匿名请求），且创建时打开「镜像代理」并关联 Docker Hub 上游。

## 6. kubeadm / kubelet / kubectl / cri-tools

```bash
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update && apt-get install -y kubelet kubeadm kubectl cri-tools
apt-mark hold kubelet kubeadm kubectl cri-tools && systemctl enable kubelet
```

| 组件 | 作用 |
| --- | --- |
| `kubeadm` | 初始化控制平面（`init`）、让节点加入集群（`join`）、证书和升级管理 |
| `kubelet` | 每个节点上的代理进程，按 API Server 的期望把 Pod 跑起来并上报状态 |
| `kubectl` | 命令行客户端 |
| `cri-tools` | 提供 `crictl`，直接对 containerd 排障（新版 kubeadm 包不再依赖它，需显式安装） |

- **`apt-mark hold`**：K8s 跨版本升级要走 `kubeadm upgrade` 流程，不能被 `apt upgrade` 顺带升级。
- 此时 kubelet 会反复重启，属正常：它在等 `kubeadm init/join` 下发配置。

## 7. 对齐 pause 镜像

```bash
kubeadm config images list --kubernetes-version "$(kubeadm version -o short)" | grep pause
# 输出示例：registry.k8s.io/pause:3.10.2，填入下面命令
sed -ri "s#^(\s*)sandbox = .*#\1sandbox = 'registry.k8s.io/pause:3.10.2'#" /etc/containerd/config.toml
systemctl restart containerd
```

- **pause 容器**：每个 Pod 里第一个启动的容器，只负责持有 Pod 的网络命名空间；同一 Pod 的其他容器共享这个命名空间，所以能用 `localhost` 互访。
- **为什么对齐**：apt 装的 containerd 默认 pause 版本与 kubeadm 期望不一致，kubeadm 会告警。containerd 1.x 的键名是 `sandbox_image`，2.x 改为 `sandbox`。

## 8. crictl 配置

```bash
cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 30
EOF
```

- **作用**：告诉 crictl 去哪个 socket 找 containerd。之后可以用 `crictl ps`、`crictl images`、`crictl logs` 绕过 K8s 直接查看容器，排查 kubelet 起不来之类的问题。

## 9. 克隆 4 台节点

模板机验收通过后关机，在 Fusion 中打快照 `base-ready`，再**完整克隆**（不是链接克隆）4 台。克隆机与模板机有 4 样东西完全相同，必须逐台改掉：

| 要改的 | 不改的后果 |
| --- | --- |
| IP | 4 台都是 `10.10.10.100`，同时开机地址冲突 |
| 主机名 | K8s 用主机名作节点名，重名无法加入集群 |
| machine-id | kubeadm / systemd 用它区分机器，重复会导致各种难查的问题 |
| SSH 主机密钥 | 4 台共用一把私钥，相当于多台设备共用同一张证书 |

[`scripts/clone-setup.sh`](../scripts/clone-setup.sh) 一次改完这 4 项，并禁止 cloud-init 接管网络配置。**一次只开一台**，做完一台再开下一台：

1. **Fusion 控制台**：克隆机开机后拿不到 IP（原因见踩坑 4），先临时配地址：

   ```bash
   ip addr add 10.10.10.10/24 dev enp2s0
   ip route add default via 10.10.10.2
   ```

   临时地址没有配置 DNS，此时 `git pull` 会失败；不需要拉代码，模板机上已有仓库。

2. **Mac**：SSH 登录后执行脚本并重启：

   ```bash
   ssh -t <用户名>@10.10.10.10 "sudo /root/K8s-VMware/scripts/clone-setup.sh k8s-master 10.10.10.10 && sudo reboot"
   ```

3. **Mac**：脚本重新生成了 SSH 主机密钥，先清掉旧记录再登录：

   ```bash
   ssh-keygen -R 10.10.10.10
   ```

依次对 `k8s-worker-1/2/3` → `.11/.12/.13` 重复以上步骤。

### Mac 免密登录节点

为日常运维和自动化，Mac 上生成一把实验专用密钥，授权给每台节点的 root：

```bash
ssh-keygen -t ed25519 -N "" -C "k8s-vmware-lab" -f ~/.ssh/id_ed25519_k8slab
```

`~/.ssh/config` 中为 4 台节点配置别名，之后可直接 `ssh k8s-master`：

```text
Host k8s-master
  HostName 10.10.10.10
# k8s-worker-1/2/3 同理 → .11/.12/.13
Host k8s-master k8s-worker-1 k8s-worker-2 k8s-worker-3 10.10.10.*
  User root
  IdentityFile ~/.ssh/id_ed25519_k8slab
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
```

把公钥追加到每台节点的 `/root/.ssh/authorized_keys`（权限 `700` / `600`）。Ubuntu 默认 `PermitRootLogin prohibit-password`：允许 root 用密钥登录，禁止用密码登录。

## 踩坑记录

1. **containerd 2.x 配置格式变化**：Ubuntu 26.04 自带 containerd 2.2，`config.toml` 的字符串用单引号，`config_path` 默认是 `''`，pause 键名改为 `sandbox`。按 1.x 写的 `sed 's|config_path = ""|...|'` 一行都没改到，而且不报错；结果 `hosts.toml` 不生效。修复：sed 同时匹配两种引号，检查脚本也不再假设双引号。
2. **没有 crictl**：v1.37 的 kubeadm 包不再依赖 `cri-tools`，需要显式安装。
3. **Harbor 项目建成了普通项目**：`dockerhub-proxy` 创建时没打开「镜像代理」。containerd 请求得到 404 后静默回退直连 Docker Hub，`crictl pull` 照样成功，Harbor 里却什么都没缓存。Harbor 不支持把普通项目改为代理项目，只能删掉重建。
   - 定位方法：模拟 containerd 匿名取 token 后请求 manifest，404 = 未开启代理，401 = 项目非公开，5xx = Harbor 连不上 Docker Hub。
   - 确认方法：Harbor 日志中出现 `harbor#proxy-cache-service` 的 push 记录（回源缓存）和 `anonymous` 的 pull 记录（节点拉取）。
   - 改进：`verify-node.sh` 新增「Harbor 代理缓存可回源 Docker Hub」检查，直接请求 manifest，不再只看 `crictl pull` 是否成功。
4. **克隆机没有 IPv4 地址**：网卡 `UP`，却只有 IPv6 链路本地地址。原因是 Ubuntu 安装程序（subiquity）生成的 `/etc/netplan/50-cloud-init.yaml` 用 `match: macaddress:` 绑定了模板机网卡的 MAC 地址；Fusion 完整克隆会生成新 MAC，配置匹配不上就被跳过。
   - 网络类比：配置绑在了板卡序列号上，换一块同型号板卡，配置不会自动套上。
   - 修复：`clone-setup.sh` 把安装程序生成的 netplan 文件移到 `/etc/netplan/backup/`，重新写一份**按网卡名**（`enp2s0`）匹配的静态配置，克隆后不受 MAC 变化影响。

## 验收

```bash
HARBOR_HOST=harbor.example.com ./scripts/verify-node.sh
```

模板机与 4 台克隆节点实测结果均为 19 通过，0 失败。

克隆后的节点另外确认：

| 节点 | IP | machine-id / product_uuid | 结果 |
| --- | --- | --- | --- |
| k8s-master | 10.10.10.10 | 互不重复 | ✅ |
| k8s-worker-1 | 10.10.10.11 | 互不重复 | ✅ |
| k8s-worker-2 | 10.10.10.12 | 互不重复 | ✅ |
| k8s-worker-3 | 10.10.10.13 | 互不重复 | ✅ |

- 每台都能按主机名 ping 通其余 3 台及网关 `10.10.10.2`，DNS 能解析公网域名。
- 每台只有一份 `50-static.yaml`，不含 MAC 匹配；cloud-init 网络管理已禁用，重启后 IP 保持。

| 分组 | 检查项 |
| --- | --- |
| 系统 | swap 关闭、overlay / br_netfilter 已加载、ip_forward 与 bridge-nf-call-iptables 为 1、machine-id 非空 |
| containerd | 运行中、SystemdCgroup = true、config_path 指向 certs.d、hosts.toml 存在、pause 与 kubeadm 一致 |
| Kubernetes 组件 | kubeadm / kubelet / crictl 已安装、kubelet 已 enable |
| 网络与 Harbor | 解析 Harbor 域名、HTTPS 证书可信、代理缓存可回源、containerd 可拉取 docker.io 镜像 |

## 下一步

1. 4 台节点各打快照 `stage0-done`：阶段 1 的 `kubeadm init` 出问题时可直接回滚，不必 `kubeadm reset`。
2. 进入阶段 1：在 k8s-master 上执行 `scripts/master-init.sh`。
