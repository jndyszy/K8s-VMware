# 阶段 1：kubeadm 集群、Calico BGP、存储与 NetworkPolicy

> 目标：在阶段 0 的 4 台节点上建起 1 Master + 3 Worker 集群，Pod 网络用 Calico BGP 直接路由（不封装），补齐默认存储、资源监控、私有仓库凭据，并验收跨节点通信、DNS、Service 和 NetworkPolicy。
> 自动化脚本：[`scripts/master-init.sh`](../scripts/master-init.sh)（第 1–5 步）、[`scripts/post-install.sh`](../scripts/post-install.sh)（第 7–10 步）、[`scripts/verify-cluster.sh`](../scripts/verify-cluster.sh)（第 11 步）。
> 本文是手动逐步执行的版本。除特别说明外，命令都在 k8s-master 上以 root 执行，工作目录为 `/root/K8s-VMware`。

## 实际环境

| 项目 | 版本 / 取值 |
| --- | --- |
| Kubernetes | v1.37.2（kubeadm 安装） |
| 节点系统 | Ubuntu 26.04.1 LTS ARM64，内核 7.0，containerd 2.2.2 |
| CNI | Calico v3.33.0（Tigera Operator），BGP，`encapsulation: None` |
| Pod / Service 网段 | 10.244.0.0/16（每节点 /26 块）/ 10.96.0.0/12 |
| 存储 | local-path-provisioner v0.0.37（默认 StorageClass） |
| 资源监控 | metrics-server v0.9.1 |

## 1. kubeadm 配置文件

[`kubeadm/kubeadm.yaml`](../kubeadm/kubeadm.yaml) 描述的是**集群本身怎么搭**，只在 `kubeadm init` 时读取一次，类似新设备开局时的初始化配置。

| 字段 | 值 | 含义 |
| --- | --- | --- |
| `advertiseAddress` | 10.10.10.10 | API Server 对外监听的地址 |
| `controlPlaneEndpoint` | k8s-master:6443 | 所有组件连控制平面用的地址。写成名字而不是 IP，以后扩成多 master 时只改解析，相当于给控制平面预留了一个 VIP |
| `podSubnet` | 10.244.0.0/16 | Pod 地址池，必须与 Calico IPPool 一致 |
| `serviceSubnet` | 10.96.0.0/12 | Service 虚拟 IP 段。这段地址不在任何网卡上，只存在于 iptables 的 DNAT 规则里 |
| `cgroupDriver` | systemd | 与 containerd 一致（阶段 0 第 4 步） |

## 2. 预拉控制平面镜像

```bash
kubeadm config images pull --config kubeadm/kubeadm.yaml
```

拉取 kube-apiserver、controller-manager、scheduler、kube-proxy、etcd、coredns、pause。这些镜像来自 `registry.k8s.io`，不经过 Harbor（Harbor 只代理 docker.io）。预先拉好，init 时不会卡在下载上，出错也更容易判断是哪一环。

## 3. 初始化控制平面

```bash
kubeadm init --config kubeadm/kubeadm.yaml | tee /root/kubeadm-init.log
```

| 输出阶段 | 做了什么 |
| --- | --- |
| `[preflight]` | 检查 swap、内核参数、端口占用等，阶段 0 的准备工作就是为了通过这一步 |
| `[certs]` | 生成整套 PKI：集群 CA，以及 API Server、etcd、kubelet 之间通信用的证书。组件之间全部走双向 TLS |
| `[kubeconfig]` | 生成管理员和各组件连接 API Server 的凭据文件 |
| `[control-plane]` `[etcd]` | 把 API Server、controller-manager、scheduler、etcd 写成**静态 Pod**（`/etc/kubernetes/manifests/`），由 kubelet 直接拉起，不经过 API Server，解决"API Server 还没起来，谁来启动它"的问题 |
| `[bootstrap-token]` | 生成 worker 加入集群用的临时令牌 |
| `[addons]` | 安装 CoreDNS（集群 DNS）和 kube-proxy（Service 转发） |

`kubeadm-init.log` 含 join 令牌，已被 `.gitignore` 排除，不要提交。

## 4. 配置 kubectl

```bash
mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config
kubectl get nodes
```

此时 k8s-master 为 `NotReady`、CoreDNS 为 `Pending`，属正常：还没装 CNI，kubelet 不知道怎么给 Pod 分配 IP、接网络。好比交换机已上电，但端口还没划 VLAN。

## 5. 安装 Calico

Calico 用 operator 模式：先装管理程序（Tigera Operator），再提交一份"要什么样的网络"的声明（`Installation`），由 operator 负责部署并持续维护各组件。

```bash
# CRD：让 K8s 认识 Installation、IPPool、BGPPeer 等 Calico 资源类型
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/operator-crds.yaml
# Operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/tigera-operator.yaml
kubectl -n tigera-operator rollout status deploy/tigera-operator
# 网络声明
kubectl apply -f platform/calico/installation.yaml
watch kubectl get tigerastatus        # 全部 AVAILABLE=True 后 Ctrl+C
```

Calico v3.30 起 CRD 从 `tigera-operator.yaml` 中拆出，必须先装 `operator-crds.yaml`。

[`platform/calico/installation.yaml`](../platform/calico/installation.yaml) 的关键字段：

| 字段 | 值 | 含义 |
| --- | --- | --- |
| `bgp` | Enabled | 每个节点运行 BIRD，节点之间建 iBGP 全互联（AS 64512），互相通告各自的 Pod 网段 |
| `cidr` | 10.244.0.0/16 | Pod 地址池 |
| `blockSize` | 26 | 每个节点分到 /26（64 个地址）的地址块，按块通告路由，而不是每个 Pod 一条主机路由 |
| `encapsulation` | None | 不封装。4 台节点在同一个二层网段，下一跳直接可达，不需要 VXLAN / IPIP 隧道 |
| `natOutgoing` | Enabled | Pod 访问集群外时 SNAT 成节点 IP |

## 6. Worker 加入集群

在 k8s-master 上生成加入命令，到 3 台 worker 上分别以 root 执行：

```bash
kubeadm token create --print-join-command
# 输出：kubeadm join k8s-master:6443 --token <令牌> --discovery-token-ca-cert-hash sha256:<指纹>
```

- `--token`：临时口令，证明"我是被允许加入的节点"，默认 24 小时过期。
- `--discovery-token-ca-cert-hash`：集群 CA 证书指纹。worker 用它核对连上的确实是本集群的 API Server，相当于预先钉死对端证书，防中间人。

### 确认 BGP 路由

```bash
kubectl get nodes -o wide
ip route | grep bird
```

k8s-master 上的实际输出：

```text
10.244.69.192/26 via 10.10.10.13 dev enp2s0 proto bird   # worker-3 的 Pod 块
10.244.140.0/26  via 10.10.10.12 dev enp2s0 proto bird   # worker-2
10.244.230.0/26  via 10.10.10.11 dev enp2s0 proto bird   # worker-1
blackhole 10.244.235.192/26 proto bird                   # master 自己的块
```

- 前三条是 BIRD 经 iBGP 学到的：下一跳就是对应 worker 的节点 IP，没有任何隧道接口。
- `blackhole` 相当于 H3C 上做路由汇总时配的**指向 Null0 的汇总路由**：本机 Pod 各有更精确的 /32 主机路由（指向 veth），正常流量走主机路由；发往块内**尚未分配**地址的流量落到 blackhole 丢弃，防止被默认路由送出去形成环路。

## 7. Worker 角色标签

```bash
for n in k8s-worker-1 k8s-worker-2 k8s-worker-3; do
  kubectl label node $n node-role.kubernetes.io/worker= --overwrite
done
```

`kubectl get nodes` 的 ROLES 列读取的就是 `node-role.kubernetes.io/<角色>` 标签。只影响显示，但之后可以用它把 Pod 限定调度到 worker 上。

## 8. 默认存储 local-path-provisioner

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
kubectl -n local-path-storage rollout status deploy/local-path-provisioner
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

- **作用**：Pod 申请 PVC 时，自动在 Pod 所在节点的 `/opt/local-path-provisioner/` 下划一个目录给它。阶段 3 的 Prometheus、Grafana 依赖它存数据。
- **默认 StorageClass**：PVC 不写 `storageClassName` 时自动使用。
- **`WaitForFirstConsumer`**：等 Pod 被调度到某节点后才创建卷，保证卷和 Pod 在同一台节点上。
- **局限**：数据只在一台节点的本地盘上，节点宕机则数据不可访问、Pod 也无法漂移。生产环境应使用 Ceph、NFS 或云盘等共享存储。
- 镜像来自 `docker.io/rancher/...`，经 Harbor 代理缓存拉取。

## 9. 资源监控 metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.1/components.yaml
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deploy/metrics-server
kubectl top nodes
```

- **作用**：定期从各节点 kubelet 收集 CPU / 内存用量，供 `kubectl top` 和 HPA（自动扩缩容）使用。
- **`--kubelet-insecure-tls`**：kubeadm 默认情况下 kubelet 的服务端证书是自签名的，未经集群 CA 签发，metrics-server 校验失败会一直起不来。实验环境跳过校验；规范做法是开启 kubelet 的 `serverTLSBootstrap`，由集群 CA 签发正式证书（见改进项）。
- `scripts/post-install.sh` 用 Helm + [`platform/metrics-server/values.yaml`](../platform/metrics-server/values.yaml) 安装，效果相同；手动步骤用官方清单，省去安装 Helm。

实测（4 台节点空载）：

```text
k8s-master     178m   8%    1812Mi   53%
k8s-worker-1    49m   2%     805Mi   23%
k8s-worker-2    49m   2%     754Mi   22%
k8s-worker-3    49m   2%     752Mi   22%
```

## 10. lab 命名空间与 Harbor 拉取凭据

阶段 2 的业务镜像推送到 Harbor 的私有项目 `lab`，集群用只读机器人账号拉取。

**Harbor 侧**：新建私有项目 `lab`；在项目下新建机器人账户 `k8s-pull`，只授予拉取权限。Harbor 会自动加前缀，完整用户名形如 `robot$lab+k8s-pull`；token 只显示一次。

**集群侧**：

```bash
kubectl create namespace lab
read -rp "机器人用户名: " U; read -rsp "Token: " T; echo
H=harbor.example.com
A=$(printf '%s:%s' "$U" "$T" | base64 | tr -d '\n')
C=$(printf '{"auths":{"%s":{"username":"%s","password":"%s","auth":"%s"}}}' "$H" "$U" "$T" "$A" | base64 | tr -d '\n')
printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"harbor-pull","namespace":"lab"},"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":"%s"}}' "$C" \
  | kubectl create -f -
unset T A C
kubectl -n lab patch serviceaccount default -p '{"imagePullSecrets":[{"name":"harbor-pull"}]}'
```

- **为什么不用 `kubectl create secret docker-registry --docker-password=...`**：token 会出现在进程参数里，`ps` 可见。这里 token 只经过 shell 内建的 `read` / `printf` 和管道，不进命令行、不进 shell 历史。
- **挂到 default ServiceAccount**：Pod 未指定 ServiceAccount 时以 `default` 身份运行，挂上后命名空间内所有 Pod 拉镜像自动带凭据，不必每个 Deployment 都写 `imagePullSecrets`。
- **凭据按仓库域名匹配**：拉 `docker.io` 镜像时不会使用它，这也是 `dockerhub-proxy` 必须公开的原因。

## 11. 验收

测试资源在 [`tests/stage1/`](../tests/stage1/)：`pod-a`（固定 worker-1，`role=client`）、`pod-b`（固定 worker-2，`role=other`）、3 副本 nginx `web` 及同名 Service。

```bash
kubectl apply -f tests/stage1/workloads.yaml
kubectl -n stage1-test get pods -o wide
B=$(kubectl -n stage1-test get pod pod-b -o jsonpath='{.status.podIP}')
```

### 11.1 跨节点 Pod 互通

```bash
kubectl -n stage1-test exec pod-a -- ping -c 3 $B
# 64 bytes from 10.244.140.2: seq=0 ttl=62 time=0.460 ms
```

TTL 从 64 降到 62，说明经过两跳三层转发，节点本身就是路由器：

```text
pod-a 10.244.230.1
  → worker-1 查路由：10.244.140.0/26 via 10.10.10.12      TTL 64→63
  → worker-2 查路由：10.244.140.2 dev cali-xxx            TTL 63→62
  → pod-b 10.244.140.2
```

### 11.2 集群 DNS 与外部 DNS

```bash
kubectl -n stage1-test exec pod-a -- nslookup kubernetes.default.svc.cluster.local
# Server: 10.96.0.10 → Address: 10.96.0.1
kubectl -n stage1-test exec pod-a -- nslookup harbor.example.com
```

集群内名字由 CoreDNS（Service IP `10.96.0.10`）直接回答；集群外名字由 CoreDNS 转发给节点 DNS `10.10.10.2`。

### 11.3 Service 访问

```bash
kubectl -n stage1-test exec pod-a -- wget -q -T 3 -O - http://web
```

`web` 先被 CoreDNS 解析为 Service 的虚拟 IP（10.96.x.x），再由每台节点上 kube-proxy 写好的 iptables 规则 DNAT 到 3 个 nginx Pod 之一。相当于每台节点上都配了一份 NAT Server + 负载均衡。

### 11.4 NetworkPolicy

NetworkPolicy 是 Pod 级别的 ACL，由 Calico 在目标 Pod 所在节点上用 iptables 实现。

```bash
kubectl apply -f tests/stage1/netpol-default-deny.yaml   # 命名空间内入方向全部拒绝
kubectl -n stage1-test exec pod-a -- wget -q -T 3 -O - http://web   # 超时
kubectl apply -f tests/stage1/netpol-allow-client.yaml   # 放行 role=client → web:80
kubectl -n stage1-test exec pod-a -- wget -q -T 3 -O - http://web   # 成功
kubectl -n stage1-test exec pod-b -- wget -q -T 3 -O - http://web   # 超时
```

在 web Pod 所在的 worker-3 上，Calico 生成的规则（`iptables-save` 节选）：

```text
-A cali-tw-cali6a7d191fbde ... -m mark --mark 0x0/0x20000 -j cali-pi-_vMi11yVgLNNhBJX2Y_u
-A cali-tw-cali6a7d191fbde ... -m mark --mark 0x0/0x20000 -j cali-pi-_cI0TMZf9PKUKjwSQjyA
-A cali-pi-_vMi11yVgLNNhBJX2Y_u -p tcp ... "KubernetesNetworkPolicy stage1-test/allow-client-to-web ingress"
     -m set --match-set cali40s:x6eHatstp4DEJI7j9114Am4 src -m multiport --dports 80 -j MARK --set-xmark 0x10000/0x10000
-A cali-pi-_cI0TMZf9PKUKjwSQjyA ... "KubernetesNetworkPolicy stage1-test/default-deny-ingress ingress"
```

| 规则 | ACL 对照 |
| --- | --- |
| `cali-tw-<veth>` | ACL 应用在 web Pod 的 veth 接口入方向（`tw` = to workload） |
| `allow-client-to-web` 链 | `permit tcp object-group <role=client> any eq 80`，命中后打"放行"标记 `0x10000` |
| `cali40s:...` ipset | 对象组：成员是所有带 `role=client` 标签的 Pod IP（此处只有 pod-a）。Pod 增删时 Calico 实时更新成员，iptables 规则本身不变 |
| `default-deny-ingress` 链 | 链内没有任何匹配规则；未被打上放行标记的包走到链尾被丢弃，即隐含的 `deny any` |
| `--mark 0x0/0x20000` | 只有尚未被某一层策略判定为 pass 的包才继续检查，用于 Calico 多层策略（tier）之间传递结果 |

与传统 ACL 最大的区别：**匹配的是标签而不是 IP**。Pod 重建后 IP 会变，标签不变，规则持续有效。

另外可以看到一条 `calico-system/calico-system.default-deny`：这是 Calico 自动给自己的 `calico-system` 命名空间加的默认拒绝策略，并非本实验创建。

### 11.5 结果

| 检查项 | 结果 |
| --- | --- |
| 4 台节点 Ready，Calico 全部 Available | ✅ |
| worker-1 Pod → worker-2 Pod（ping，TTL 62） | ✅ |
| 集群 DNS / 外部 DNS | ✅ |
| Service 访问 | ✅ |
| default-deny 后 pod-a 被拒 | ✅ |
| 放行后 pod-a 可访问、pod-b 仍被拒 | ✅ |
| 默认 StorageClass、`kubectl top` | ✅ |

清理：`kubectl delete namespace stage1-test`。删除时 Pod 有 30 秒优雅退出期；busybox 的 `sleep` 作为 PID 1 不处理 SIGTERM，所以要等满 30 秒被 SIGKILL，命名空间会在 `Terminating` 停留约半分钟，属正常。

## 环境依赖：Mac 代理的 fake-ip

Pod 内解析 Harbor 域名得到 `198.18.0.31`。`198.18.0.0/15` 是 RFC 2544 保留给网络性能测试的地址段，不是真实公网 IP。原因是 Mac 上的代理软件以 **fake-ip** 模式接管了 DNS：

```text
Pod → CoreDNS → 节点 DNS 10.10.10.2（Fusion NAT）→ Mac 系统 DNS → 代理软件返回假 IP
连接时：节点 → Fusion NAT → Mac → 代理软件按域名转发到真实地址
```

- 代理运行时一切正常，也正是节点能直接访问 Docker Hub、registry.k8s.io 的原因。
- 代理关闭或切换模式后，已缓存的假 IP 无法连接，拉镜像、访问 Harbor 会大面积失败（`ImagePullBackOff`）。遇到此类故障先检查 Mac 代理。
- 可作为故障演练素材：关闭代理 → 观察现象 → 定位到 DNS 解析结果 → 恢复。

## 改进项

- [ ] 开启 kubelet `serverTLSBootstrap`，由集群 CA 签发 kubelet 服务端证书，去掉 metrics-server 的 `--kubelet-insecure-tls`。
- [ ] 把 Calico 节点间 iBGP 全互联与阶段 4 的 OpenWrt eBGP 对等一起规划（节点数增多时改为路由反射器）。

## 下一步

1. 4 台节点各打快照 `stage1-cluster-up`。
2. 进入阶段 2：Go 服务 lab-api、GitHub Actions 构建推送到 Harbor、ArgoCD GitOps。
