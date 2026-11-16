# 阶段 3：可观测性、SLI/SLO、错误预算与燃烧率告警

> 目标：回答 SRE 的三个核心问题——服务现在好不好？还能承受多少故障？出问题时谁会第一时间知道？
> 配置：[`platform/monitoring/values.yaml`](../platform/monitoring/values.yaml)（kube-prometheus-stack）、[`apps/lab-api/`](../apps/lab-api/) 下的 ServiceMonitor、SLO 规则、流量生成器、仪表盘（由 ArgoCD 管理）。

## 整体结构

```text
lab-api /metrics ──(ServiceMonitor, 15s)──▶ Prometheus ──记录规则──▶ SLI / 错误预算
      ▲                                         │
      │ ~4.9 req/s                              ├─ 告警规则（多窗口燃烧率）──▶ Alertmanager（静默、路由）
lab-api-loadgen                                 └─ Grafana：lab-api / SLO 仪表盘
```

| 组件 | 版本 |
| --- | --- |
| kube-prometheus-stack chart | 93.3.0（Prometheus Operator v0.95.2） |
| Prometheus / Alertmanager / Grafana | v3.16.0 / v0.35.0 / 13.3.1 |
| Helm | v4.3.2 |

## 1. 安装 kube-prometheus-stack

```bash
# Helm：官方二进制 + SHA256 校验
cd /tmp && curl -fsSLO https://get.helm.sh/helm-v4.3.2-linux-arm64.tar.gz \
  && curl -fsSL https://get.helm.sh/helm-v4.3.2-linux-arm64.tar.gz.sha256sum -o helm.sha256 \
  && sha256sum -c helm.sha256 && tar xzf helm-v4.3.2-linux-arm64.tar.gz \
  && install -m 755 linux-arm64/helm /usr/local/bin/helm

# Grafana 管理员凭据：随机密码，经管道传给 kubectl，不进命令行参数、不进 Git
kubectl create namespace monitoring
P=$(openssl rand -base64 18); printf '%s' "$P" | kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-file=admin-password=/dev/stdin && echo "Grafana 密码：$P"; unset P

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version 93.3.0 \
  -n monitoring -f platform/monitoring/values.yaml --wait --timeout 10m
```

values 的关键决定：

| 设置 | 原因 |
| --- | --- |
| 关闭 controller-manager / scheduler / etcd / kube-proxy 监控及其告警规则 | kubeadm 默认让它们的指标端口只监听 127.0.0.1，Prometheus 抓不到，会一直报 TargetDown。告警系统的第一原则是不能有长期误报，否则大家会习惯性忽略告警 |
| `*SelectorNilUsesHelmValues: false` | 默认只发现带本 release 标签的 ServiceMonitor / PrometheusRule；改为发现所有命名空间，应用的监控配置才能和应用清单放在一起由 ArgoCD 管理 |
| 保留 30 天、上限 8 GB，local-path 10Gi | 覆盖 30 天的 SLO 周期；`retentionSize` 兜底，先到哪个上限按哪个删 |
| Grafana 用 Secret `grafana-admin` | chart 默认密码 `prom-operator` 人尽皆知 |
| 每个组件设 requests 与内存 limit | worker 只有 3.3 GiB 可分配内存，不设上限时 Prometheus 可能吃光整台节点 |

安装后：26 个采集目标全部 up；告警只有 `Watchdog`——它**故意永远在响**，下游收不到它就说明告警链路断了（dead man's switch）。

## 2. 采集 lab-api 指标

[`apps/lab-api/servicemonitor.yaml`](../apps/lab-api/servicemonitor.yaml)：按 `app: lab-api` 选中 Service，经端口 `http` 采集 `/metrics`，间隔 15 秒。

- Prometheus Operator 把 ServiceMonitor 翻译成 Prometheus 采集配置；Prometheus 通过 Endpoints **逐个 Pod** 采集，而不是走 Service 虚拟 IP（否则每次随机落到一个 Pod，数据会乱）。
- 采集间隔 15 秒比全局 30 秒更密，短窗口的 SLI 更准、故障发现更早。

## 3. SLI 与 SLO

| | SLI | SLO（30 天） | 错误预算 |
| --- | --- | --- | --- |
| 可用性 | 非 5xx 请求占比 | 99.5% | 0.5% ≈ 3.6 小时 |
| 延迟 | 250 ms 内完成的请求占比 | 99% | 1% 的请求允许超过 250 ms |

- **只统计业务接口 `/`**：探针和 `/metrics` 不是用户请求，计入会掩盖问题。
- **阈值取直方图桶边界**：Prometheus 只知道每个桶里有多少请求；250 ms 正好是 `le="0.25"`，可以精确计算达标率。
- **记录规则**（[`slo-rules.yaml`](../apps/lab-api/slo-rules.yaml)）：5m、30m、1h、2h、6h、1d、3d、30d 共 8 个窗口的错误率与慢请求率预先算好，仪表盘和告警直接引用，查询快且口径统一。
- **剩余错误预算** = `1 − 错误率(30d) ÷ (1 − SLO)`：1 表示一点没用，0 表示刚好用完，负数表示超支。
- **没有流量时 SLI 是 NaN**（0 ÷ 0），这是正确的：没有请求就无从谈论成功率，不能当成 100%。NaN 参与的比较为 false，不会误报。

### lab-api 的配合改动

- `FAIL_RATE` / `LATENCY_MS` 环境变量：`/` 按比例返回 500、增加延迟，用于故障演练；在 [`deployment.yaml`](../apps/lab-api/deployment.yaml) 中声明，通过 Git 修改生效（`kubectl set env` 会被 ArgoCD selfHeal 恢复）。
- 启动时预先创建 `code="200"` 与 `code="500"` 两个计数序列：带标签的计数器只在某个标签组合第一次出现时才创建序列，从没出过 500 的副本会让错误率查询缺数据。
- 路由提取为 `newMux`，补了 6 个单元测试，CI 中的 `go test` 不再是空跑。

### 流量生成器

[`loadgen.yaml`](../apps/lab-api/loadgen.yaml)：busybox 循环 `wget http://lab-api/` + `sleep 0.2`，实测约 4.9 req/s。失败也继续发（失败本身要被统计）；标签用 `app: lab-api-loadgen`，不能与 lab-api Service 的选择器重叠。

### 仪表盘

[`dashboard.yaml`](../apps/lab-api/dashboard.yaml)：带 `grafana_dashboard: "1"` 标签的 ConfigMap，Grafana sidecar 自动加载，仪表盘即代码。`lab-api / SLO` 共 12 个面板：

| 行 | 内容 |
| --- | --- |
| SLO 概览 | 30 天可用性、延迟达标率及各自剩余错误预算（低于目标变红） |
| 燃烧率 | 可用性 / 延迟的 5m、1h、6h 燃烧率，虚线标出 6 与 14.4 |
| 流量与延迟 | 按状态码的请求速率、错误率（虚线 0.5%）、p50/p90/p99（虚线 250 ms） |

**燃烧率** = 当前错误率 ÷ 错误预算比例。1 表示按此速度 30 天正好用完；14.4 表示 1 小时消耗 2%。同样 1% 的错误率，对 99.5% 的 SLO 是燃烧率 2，对 99.9% 是 10——燃烧率比错误率更能反映紧急程度。

## 错误预算燃烧告警

> 本节是告警注解中 `runbook_url` 指向的处置手册。

### 告警规则

可用性与延迟各 4 档（Google SRE Workbook 第 5 章，多窗口、多燃烧率）：

| 告警 | 燃烧率 | 长窗口 / 短窗口 | for | severity | 含义 |
| --- | --- | --- | --- | --- | --- |
| `LabApi*BudgetBurnFast` | 14.4 | 1h / 5m | 2m | critical | 1 小时耗 2% 预算 |
| `LabApi*BudgetBurnMedium` | 6 | 6h / 30m | 15m | critical | 6 小时耗 5% |
| `LabApi*BudgetBurnSlow` | 3 | 1d / 2h | 1h | warning | 1 天耗 10% |
| `LabApi*BudgetBurnTrend` | 1 | 3d / 6h | 3h | warning | 周期结束正好用完 |

- 阈值 = 燃烧率 × (1 − SLO)：可用性 × 0.5%，延迟 × 1%。
- **长短窗口同时超标才告警**：只看短窗口会被抖动误报；只看长窗口，修复后残留的错误会让告警多响很久。长窗口确认"确实严重"，短窗口确认"现在还在发生"。
- **分档**：严重故障几分钟内要发现（critical）；轻微但持续的问题不必半夜叫人（warning，次日排期）。

### 收到告警后怎么处理

1. **确认影响**：打开 Grafana `lab-api / SLO`，看错误率 / 慢请求率曲线从什么时候开始、按状态码的请求速率里是哪类错误。
2. **看最近的变更**：`git log` 查看 K8s-VMware 的 `apps/lab-api/`（镜像 tag、`FAIL_RATE` 等）与 lab-api 仓库的最近提交；ArgoCD 中查看最近一次同步。大多数故障由变更引起。
3. **止血优先**：若与最近一次发布相关，把 `kustomization.yaml` 的 `newTag` 改回上一个版本并提交，ArgoCD 自动回滚；先恢复服务，再查根因。
4. **看 Pod 与日志**：`kubectl -n lab get pods`、`kubectl -n lab describe pod`、`kubectl -n lab logs deploy/lab-api`（尚无集中日志系统，见改进项）。
5. **判断是否为误报**：新上线不久的服务，长窗口数据不足会放大短时故障（见演练"冷启动"）；确认为误报时在 Alertmanager 建带备注、有过期时间的静默，而不是改规则。
6. **事后**：按 [`docs/postmortems/TEMPLATE.md`](postmortems/TEMPLATE.md) 写复盘，记录消耗了多少错误预算。

### 规则测试

[`tests/stage3/slo-rules.test.yaml`](../tests/stage3/slo-rules.test.yaml)，用 promtool 运行：

```bash
./scripts/extract-prom-rules.sh apps/lab-api/slo-rules.yaml > tests/stage3/slo-rules.prom.yaml
promtool test rules tests/stage3/slo-rules.test.yaml
```

- 记录规则：两个副本中一个每分钟 2 个 500 → 错误率 1%；`/healthz` 的 500 不计入；慢请求 2%；错误率 1% 时剩余预算 −1。
- 告警：30 分钟正常后错误率 50% 持续 30 分钟，断言 `ALERTS` 序列——正常时不告警、故障约 20 分钟后 Fast firing、35 分钟时 Medium 未触发、延迟告警不受影响。用 `ALERTS` 而非 `alert_rule_test`，因为后者会比较注解，注解里的百分比是运行时计算值。
- `extract-prom-rules.sh` 把 PrometheusRule 的 `spec` 提取为 promtool 能读的规则文件；语法另由 Prometheus Operator 准入 Webhook 在 dry-run 时校验（故意写坏一条 PromQL 会被拒绝）。

## 4. 故障演练

通过 GitOps 注入故障：PR #13 把 `FAIL_RATE` 改为 `"0.5"`，告警触发后 PR #14 改回 `"0"`。

| 时间（UTC） | 距注入 | 事件 |
| --- | --- | --- |
| 06:29:33 | 0 | 合并 PR #13 |
| 06:29:46 | 13 s | ArgoCD 同步完成（合并后手动发送刷新请求） |
| 06:30:26 | 53 s | 开始出现 500 |
| 06:30:47 | 1 m 14 s | Slow、Trend pending（冷启动，见下文） |
| 06:31:17 | 1 m 44 s | Medium pending |
| 06:32:27 | 2 m 54 s | **Fast pending**（5m 错误率 27%，1h 10%） |
| 06:34:17 | **4 m 44 s** | **Fast firing**，Alertmanager 收到 |
| 06:39:49 | 10 m 16 s | 合并 PR #14 |
| 06:40:02 | 10 m 29 s | ArgoCD 同步完成 |
| 06:40:23 | 10 m 50 s | 不再有新的 500 |
| 06:41:48 | — | 为 Slow、Trend 建 18 小时静默 |
| 06:44:48 | 15 m 15 s | **Fast 自动解除**（恢复后 4 m 46 s，取决于 5m 短窗口） |
| 06:46:17 | 16 m 44 s | **Medium firing**（pending 满 15 分钟；此时 30m 错误率仍有 19%） |

| 指标 | 数值 |
| --- | --- |
| 检测时间（故障开始 → Fast firing） | 约 4 分钟 |
| 恢复时间（Fast firing → 不再出错） | 约 6 分钟（含准备与审批恢复 PR） |
| 故障期间 500 总数 | 约 1540 个 |
| 5m / 1h 错误率峰值 | 53% / 25% |

告警渲染出的描述：

```text
错误率在 1h 窗口为 14.81%，SLO 允许 0.5%。1 小时消耗约 2% 的 30 天错误预算，约 2 天会全部用完。
```

### 观察与结论

- **Medium 在恢复之后才 firing 是设计如此**：它的短窗口是 30 分钟，要等故障期间的错误全部移出窗口才会回落。Medium 针对持续较长的问题，确认恢复也需要更久。
- **冷启动放大了长窗口**：流量生成器 06:19 才启动，1h、1d、3d、30d 窗口里实际只有 10 来分钟数据，"1 天错误率"约等于"最近 10 分钟错误率"。因此：
  - Fast 比按成熟系统估算的 8~10 分钟提前一倍触发；
  - Slow、Trend 在故障开始 1 分钟就进入 pending，按推算会在故障结束后继续 firing 数小时——在运行数周的系统里，10 分钟故障根本不会让它们超标；
  - 剩余错误预算一度显示 **−38.8**（30 天错误率被算成约 20%）。按真实 30 天计算，本次约 10 分钟、50% 失败，相当于 5 分钟完全不可用，约为 216 分钟月度预算的 2.3%。
  - 结论：**SLO 与错误预算需要足够长的历史数据才可靠**，新服务上线头几天的预算数字不能直接用于决策。
- **误报用静默处理，不改规则**：在 Alertmanager 为 Slow、Trend 建 18 小时静默，匹配 `alertname` + `service=lab-api`，备注写明原因与关联 PR。静默只屏蔽通知、不影响规则计算，到期自动失效。
- **告警尚未发给任何人**：Alertmanager 默认接收方为空，告警只能在网页上看到。

## 踩坑记录

1. **Grafana 被 OOMKilled**：凭经验给的 256 Mi 上限，Grafana 13 空载就用了 252 Mi，打开仪表盘时被内核杀掉（退出码 137），表现为 `port-forward` 报 `connection refused`。调到 512 Mi 后实测打开仪表盘约 322 Mi。资源配额应按实测数据调整——这也正是监控的价值。
2. **distroless 镜像里没有 `wget`**：Prometheus 容器无法 `kubectl exec` 调接口，改为经 API Server 代理访问：`kubectl get --raw /api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1/...`。
3. **浮点数不能直接判等**：promtool 测试期望 `0.02`，实际 `1 − 0.98 = 0.020000000000000018`。`fuzzy_compare: true` 的容差不足以覆盖；改为断言里先 `round(x, 0.001)` 再比较（`round` 会去掉指标名，期望标签写 `{}`）。
4. **`port-forward` 不是持久化访问**：它只是 kubectl 进程开的临时隧道。持久访问计划在阶段 4 用 LoadBalancer IP + `*.lab.internal` 解决。

## 改进项

- [ ] **集中日志**：Loki + Grafana Alloy（Elasticsearch 的堆内存需求超出 worker 容量），lab-api 改为 `slog` 结构化 JSON 日志，在 Grafana 中从指标尖峰跳到同时段日志。
- [ ] Alertmanager 配置通知渠道（邮件 / 飞书 / 钉钉 / Telegram Webhook），critical 与 warning 分路由；`Watchdog` 接入外部心跳检测。
- [ ] 控制平面组件指标改为监听节点 IP，恢复 controller-manager / scheduler / etcd / kube-proxy 监控。
- [ ] 压测验证滚动更新期间零失败（优雅退出的量化证据）。
- [ ] 链路追踪（OpenTelemetry + Tempo），多服务时再引入。

## 下一步

阶段 4：OpenWrt + FRR 与 Calico eBGP、ECMP，MetalLB 分配 LoadBalancer IP 并由 Calico 宣告，dnsmasq 提供 `lab.internal` 内部域名，替代 `port-forward`。
