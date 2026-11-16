# 阶段 2：lab-api、GitHub Actions、Harbor、ArgoCD GitOps

> 目标：打通一条完整的发布流水线——改代码 → 自动构建镜像 → 推送到 Harbor → 集群自动部署，全程无人工操作。
> 代码仓库：[jndyszy/lab-api](https://github.com/jndyszy/lab-api)；部署配置：本仓库 [`apps/lab-api/`](../apps/lab-api/)、[`platform/argocd/`](../platform/argocd/)。

## 整体链路

```text
lab-api 仓库 ── git push ──▶ GitHub Actions（ubuntu-24.04-arm）
                               ├─ build：vet/test → 构建 arm64 镜像 → 推送 Harbor lab/lab-api:<commit 前 7 位>
                               └─ deploy：用部署密钥改 K8s-VMware 的 apps/lab-api/kustomization.yaml newTag
                                                     │
K8s-VMware 仓库 apps/lab-api/ ◀──────────────────────┘
        │ ArgoCD 每 3 分钟拉取，发现变化即同步
        ▼
集群 lab 命名空间：lab-api 滚动更新（凭 harbor-pull 从私有项目拉镜像）
```

代码与部署配置分两个仓库：CI 往 K8s-VMware 写回 tag，K8s-VMware 没有 CI，不会反向触发，避免循环。

| 组件 | 版本 |
| --- | --- |
| Go / Prometheus client_golang | 1.27 / v1.25.0 |
| 运行时基础镜像 | `gcr.io/distroless/static-debian13:nonroot` |
| ArgoCD | v3.6.1 |
| GitHub Actions | checkout v7.0.1、setup-go v7.0.0、setup-buildx v4.4.1、login v4.8.0、build-push v7.4.0 |

## 1. lab-api 服务

[`main.go`](https://github.com/jndyszy/lab-api/blob/main/main.go) 只用标准库 `net/http` 和 Prometheus 客户端：

| 接口 | 作用 |
| --- | --- |
| `GET /` | 返回 `service`、`version`（构建时注入的 commit）、`hostname`（Pod 名） |
| `GET /healthz` | 存活探针：进程能响应就返回 200 |
| `GET /readyz` | 就绪探针：收到 SIGTERM 后返回 503 |
| `GET /metrics` | `http_requests_total{path,code}`、`http_request_duration_seconds`，供阶段 3 计算可用性与延迟 SLI |

**优雅退出**：收到 SIGTERM 后先让 `/readyz` 返回 503（K8s 把 Pod 从 Service 后端摘除），等 5 秒让各节点 kube-proxy 更新完规则，再停止接收新连接、处理完存量请求后退出。对比阶段 1：busybox 不处理 SIGTERM，要等满 30 秒被强杀。

本地验证（Mac 上无需安装 Go，编译在容器里完成）：

```bash
docker run --rm -v "$PWD":/src -w /src golang:1.27 sh -c 'go mod tidy && go vet ./...'
docker build --build-arg VERSION=local -t lab-api:local .
docker run -d --name labapi -p 18080:8080 lab-api:local
curl -s localhost:18080/
docker stop labapi && docker logs labapi    # received shutdown signal 与 bye 相隔 5 秒
```

## 2. 镜像

[`Dockerfile`](https://github.com/jndyszy/lab-api/blob/main/Dockerfile) 要点：

- **多阶段构建**：Go 工具链只在构建阶段，最终镜像只有一个静态二进制，约 19.5 MB（压缩后 4.3 MB）。
- **distroless**：没有 shell 和包管理器，攻击面小，漏洞扫描结果干净。
- **`USER 65532:65532`**：必须写**数字** UID（见踩坑 1）。
- **`-ldflags "-X main.version=..."`**：构建时注入版本号，`/` 返回的 `version` 即 commit。
- **`--platform=$BUILDPLATFORM` + `TARGETARCH`**：交叉编译，构建机架构与目标架构解耦。

## 3. Harbor 与 GitHub 凭据

| 机器人账号 | 权限 | 使用者 | 存放位置 |
| --- | --- | --- | --- |
| `robot$lab+lab-ci` | `lab` 项目推送 + 拉取 | GitHub Actions | lab-api 仓库 secrets |
| `robot$lab+k8s-pull` | `lab` 项目只读 | 集群 | `lab` 命名空间 Secret `harbor-pull` |

最小权限：哪个凭据泄露，影响范围都被限定在各自用途内。

```bash
gh variable set HARBOR_HOST --repo jndyszy/lab-api --body harbor.example.com
gh secret set HARBOR_USERNAME --repo jndyszy/lab-api     # 交互输入，不进命令行和历史
gh secret set HARBOR_TOKEN --repo jndyszy/lab-api
```

域名存为 variable（不敏感，但不写进代码）；用户名和 token 存为 secret（加密，日志中自动打码）。

## 4. CI：构建并推送

[`.github/workflows/ci.yml`](https://github.com/jndyszy/lab-api/blob/main/.github/workflows/ci.yml) 的 `build` job：

- **`runs-on: ubuntu-24.04-arm`**：原生 ARM64 Runner，不需要 QEMU 模拟。
- **tag = commit 前 7 位，不用 `latest`**：可追溯、不可变、便于回滚；也是 GitOps 的前提——Git 里的 tag 变了 ArgoCD 才知道要部署。
- **PR 只构建不推送**：验证能编译和测试，但不登录 Harbor；fork 的 PR 拿不到 secrets，也避免未合并代码进入镜像仓库。
- **`cache-from/to: type=gha`**：Docker 分层缓存存到 GitHub，依赖不变时跳过 `go mod download`。

## 5. 手动部署验证

交给 ArgoCD 之前，先在 k8s-master 上手动 `kubectl apply` 一次，确认私有仓库拉取与清单本身没问题。清单即 [`apps/lab-api/deployment.yaml`](../apps/lab-api/deployment.yaml) 与 [`service.yaml`](../apps/lab-api/service.yaml)：

| 设计 | 说明 |
| --- | --- |
| readiness 每 2 秒、失败 1 次即摘除 | 摘得快，配合程序退出前等待的 5 秒 |
| liveness 每 10 秒、连续失败 3 次才重启 | 重启得慢，避免一次抖动误杀 |
| requests `cpu 10m / memory 16Mi`，limits 只设内存 `64Mi` | 内存超限 OOM 被杀，保护节点；不设 CPU limit，避免突发时被限流抬高延迟 |
| `runAsNonRoot`、`readOnlyRootFilesystem`、`drop: [ALL]`、`allowPrivilegeEscalation: false`、`seccompProfile: RuntimeDefault` | Pod Security `restricted` 基线 |
| `topologySpreadConstraints` | 两个副本尽量分散到不同节点 |
| Service `targetPort: http` | 用端口名而不是数字，容器端口改了 Service 不用跟着改 |

验证结果：镜像从私有项目拉取成功（`harbor-pull` 生效）；临时 Pod 访问 `http://lab-api` 6 次，两个 Pod 都收到请求。分布 5:1 而非 3:3，是因为 kube-proxy iptables 模式按概率随机选后端而非轮询，类似 ECMP 按流哈希：短时间不均匀，统计上均衡。

## 6. ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
kubectl apply -f platform/argocd/lab-api-application.yaml
```

- **`--server-side`**：ArgoCD 的 CRD 很大，客户端 apply 会把整份配置存进 `last-applied` 注解，超过 262 KB 上限。
- **[`kustomization.yaml`](../apps/lab-api/kustomization.yaml)**：镜像 tag 只在 `images.newTag` 一处，发布即改这一行。
- **[`lab-api-application.yaml`](../platform/argocd/lab-api-application.yaml)**：

| 开关 | 作用 | 网络类比 |
| --- | --- | --- |
| `automated` | Git 变化后自动部署 | 配置下发后自动生效 |
| `prune` | Git 里删掉的资源，集群里也删 | 删除的配置项真正从设备上移除 |
| `selfHeal` | 集群被手动改动后自动恢复成 Git 的样子 | 配置漂移后自动回到基线 |

`lab` 命名空间和 `harbor-pull` 凭据人工创建（凭据不进 Git），不交给 ArgoCD 管理。

网页访问（阶段 4 有 LoadBalancer IP 后改为 `argocd.lab.internal`）：

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8443:443   # Mac 打开 https://10.10.10.10:8443
```

## 7. CI 写回：打通全流程

`deploy` job 在镜像推送成功后检出 K8s-VMware，把 `newTag` 改成新 tag 并推送。

**凭据：部署密钥（Deploy Key）而非个人令牌**——只绑定 K8s-VMware 一个仓库的写权限，泄露影响面小，可单独吊销，不会过期。

```bash
ssh-keygen -t ed25519 -N "" -C "lab-api-ci-writeback" -f ~/lab-api-deploy-key
gh repo deploy-key add ~/lab-api-deploy-key.pub --repo jndyszy/K8s-VMware --allow-write --title "lab-api CI write-back"
gh secret set K8S_VMWARE_DEPLOY_KEY --repo jndyszy/lab-api < ~/lab-api-deploy-key
rm -P ~/lab-api-deploy-key ~/lab-api-deploy-key.pub      # 私钥只留在 GitHub secret 里
```

| 设计 | 作用 |
| --- | --- |
| `needs: build` | 镜像推送成功后才写回，不会出现"tag 改了镜像却不存在" |
| `concurrency: gitops-writeback` | 连续 push 时写回任务排队，不会同时改同一行 |
| 推送失败时 `git pull --rebase` 重试 3 次 | 期间有其他提交也能在最新版本上重放 |
| 提交正文附 lab-api commit 链接 | 从部署记录直接追溯到代码改动，审计和回滚方便 |

端到端实测：

| 环节 | 结果 |
| --- | --- |
| push lab-api `0bc6426` | build 1 分 8 秒，deploy 5 秒 |
| K8s-VMware | `github-actions[bot]` 提交 `0d24cbc`：`lab-api：部署 0bc6426` |
| ArgoCD | 同步到 `0d24cbc`，Synced / Healthy |
| 集群 | 镜像 `0bc6426`，`/` 返回 `"version":"0bc6426"` |

`version` 串起整条链路：lab-api commit = 镜像 tag = `newTag` = 运行中的镜像 = 接口返回值。滚动更新时旧 Pod 出现 `Readiness probe failed: 503` 事件，正是优雅退出"先摘流量、再下线"的证据。

## 踩坑记录

### 1. `runAsNonRoot` 无法校验非数字用户

现象：Pod 停在 `CreateContainerConfigError`；本地 `docker run` 一切正常。

```text
container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```

原因：kubelet 要在启动前确认容器不是 root，但不会进镜像查 `/etc/passwd` 把用户名换算成 UID。Dockerfile 写的是 `USER nonroot:nonroot`，无法校验就拒绝启动。Docker 不做这项检查，所以本地测不出来。类比：防火墙规则只认 IP，给它主机名不会替你解析。

修复（纵深防御，两处都改）：Dockerfile 改为 `USER 65532:65532`；Deployment 的 Pod `securityContext` 加 `runAsUser/runAsGroup: 65532`。

### 2. Fusion NAT 的 DNS 不支持 EDNS

现象：ArgoCD Application 的 `SYNC STATUS` 一直是 `Unknown`。

```text
lookup github.com on 10.96.0.10:53: no such host
```

而节点上 `apt`、拉镜像都正常，阶段 1 里 Pod 内 `nslookup` 外部域名也正常。

分层排查：

| 查询方式 | 结果 |
| --- | --- |
| 节点经 systemd-resolved 解析 | ✅ |
| `dig @10.10.10.2`（默认带 EDNS） | ❌ `malformed message packet` |
| `dig +noedns @10.10.10.2` | ✅ |
| `dig +bufsize=512/1232/4096 @10.10.10.2` | ❌ 全部畸形，与报文大小无关 |
| `dig +vc @10.10.10.2`（TCP） | ❌ `connection refused`，不支持 TCP |

结论：Fusion 的 DNS 转发器（vmnet-natd）只要查询带 EDNS（OPT 记录）就返回畸形报文。之前没暴露，是因为：

| 查询方 | 带 EDNS | 结果 |
| --- | --- | --- |
| systemd-resolved | 带，但收到坏报文会**自动降级**重试 | ✅ |
| busybox `nslookup` | 不带 | ✅ |
| ArgoCD（Go 1.21 起默认解析器带 EDNS0） | 带，经 CoreDNS 原样转发、不降级 | ❌ |

kubeadm 让 CoreDNS `forward . /etc/resolv.conf`，而 kubelet 给的是 `/run/systemd/resolve/resolv.conf`（上游直接是 10.10.10.2），所以 CoreDNS 不经过 resolved。

修复：让 resolved 在节点 IP 上也监听，CoreDNS 改为转发给 4 台节点。

```text
修复前：ArgoCD → CoreDNS ──EDNS──▶ 10.10.10.2                       ✗ 畸形报文
修复后：ArgoCD → CoreDNS ──EDNS──▶ 节点 IP 上的 resolved ──降级──▶ 10.10.10.2  ✓
```

```bash
# 每台节点（已写入 scripts/clone-setup.sh 第 6 步）
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListenerExtra=%s\n' <节点 IP> >/etc/systemd/resolved.conf.d/k8s-node-dns.conf
systemctl restart systemd-resolved

# CoreDNS（已写入 scripts/master-init.sh）
kubectl apply --server-side --force-conflicts -f platform/coredns/configmap.yaml
kubectl -n kube-system rollout restart deploy/coredns
```

- 保留 Mac 代理的 fake-ip 解析，其他网络行为不变；CoreDNS 对 4 个上游做健康检查，挂一台不影响。
- 没选的方案：CoreDNS 直连公网 DNS 会绕过 fake-ip，境外域名可能解析到被污染的地址；转发给 Mac 代理需改代理软件配置，耦合更深。
- `kubeadm upgrade` 可能重置 Corefile，升级后重新应用 [`platform/coredns/configmap.yaml`](../platform/coredns/configmap.yaml)。
- 阶段 4 改用 OpenWrt dnsmasq 时同样要规避：dnsmasq 也会把 EDNS 转发给 10.10.10.2。
- `scripts/verify-cluster.sh` 新增两项检查：CoreDNS 上游不是 `/etc/resolv.conf`；Pod 内用 `dig`（带 EDNS）解析 `github.com`。修复后验收 13/13 通过。

## 改进项

- [ ] ArgoCD 改为 GitHub Webhook 触发，替代 3 分钟轮询（需要从公网可达，阶段 5 或经隧道）。
- [x] lab-api 补单元测试（阶段 3 随故障注入一起补了 6 个）。
- [ ] 镜像签名（cosign）与 Harbor 漏洞扫描门禁：高危漏洞阻止部署。
- [ ] 部署密钥定期轮换。

## 下一步

阶段 3：kube-prometheus-stack 采集 lab-api 的 `/metrics`，定义可用性与延迟 SLO、错误预算和告警；压测验证滚动更新期间零失败。
