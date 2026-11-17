# 阶段 3：可观测性、SLI/SLO、错误预算与燃烧率告警

> 目标：回答 SRE 的三个核心问题——服务现在好不好？还能承受多少故障？出问题时谁会第一时间知道？
> 配置：[`platform/monitoring/values.yaml`](../platform/monitoring/values.yaml)（kube-prometheus-stack）、[`platform/logging/`](../platform/logging/)（Loki、Alloy）、[`apps/lab-api/`](../apps/lab-api/) 下的 ServiceMonitor、SLO 规则、流量生成器、仪表盘（由 ArgoCD 管理）。

## 整体结构

```text
lab-api /metrics ──(ServiceMonitor, 15s)──▶ Prometheus ──记录规则──▶ SLI / 错误预算
      ▲                                         │
      │ ~4.9 req/s                              ├─ 告警规则（多窗口燃烧率）──▶ Alertmanager（静默、路由）
lab-api-loadgen                                 └─▶ Grafana：lab-api / SLO 仪表盘
                                                       ▲
各节点 /var/log/pods ──Alloy（DaemonSet）──▶ Loki ──────┘（指标与日志在同一面板）
```

| 组件 | 版本 |
| --- | --- |
| kube-prometheus-stack chart | 93.3.0（Prometheus Operator v0.95.2） |
| Prometheus / Alertmanager / Grafana | v3.16.0 / v0.35.0 / 13.3.1 |
| Helm | v4.3.2 |
| Loki chart / Loki | 7.6.0 / 3.6 |
| Alloy chart / Alloy | 1.16.0 / v1.22.0 |

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
4. **看日志**：仪表盘底部「5xx 访问日志」面板，或 Grafana Explore 选 Loki 数据源执行 `{namespace="lab", app="lab-api"} | json | status >= 500`，看是哪些 Pod、什么时间、耗时多少；再配合 `kubectl -n lab get pods`、`kubectl -n lab describe pod` 看 Pod 状态。
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
| 07:08:58 | 39 m 25 s | **Medium 自动解除**（恢复后 28 m 56 s，30m 错误率降到 1.65%，低于 3%） |

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
- **短窗口决定了修复后多久解除**：Fast（5m）恢复后约 5 分钟解除，Medium（30m）约 29 分钟解除，与各自短窗口长度一致。
- **冷启动放大了长窗口**：流量生成器 06:19 才启动，1h、1d、3d、30d 窗口里实际只有 10 来分钟数据，"1 天错误率"约等于"最近 10 分钟错误率"。因此：
  - Fast 比按成熟系统估算的 8~10 分钟提前一倍触发；
  - Slow、Trend 在故障开始 1 分钟就进入 pending，按推算会在故障结束后继续 firing 数小时——在运行数周的系统里，10 分钟故障根本不会让它们超标；
  - 剩余错误预算一度显示 **−38.8**（30 天错误率被算成约 20%）。按真实 30 天计算，本次约 10 分钟、50% 失败，相当于 5 分钟完全不可用，约为 216 分钟月度预算的 2.3%。
  - 结论：**SLO 与错误预算需要足够长的历史数据才可靠**，新服务上线头几天的预算数字不能直接用于决策。
- **误报用静默处理，不改规则**：在 Alertmanager 为 Slow、Trend 建 18 小时静默，匹配 `alertname` + `service=lab-api`，备注写明原因与关联 PR。静默只屏蔽通知、不影响规则计算，到期自动失效。
- **告警尚未发给任何人**：Alertmanager 默认接收方为空，告警只能在网页上看到。

## 5. 集中日志：Loki + Alloy

告警告诉你"错误率 50%"，下一步要知道"具体哪些请求失败、报什么错"——这需要日志。指标（Metrics）、日志（Logs）、链路追踪（Traces）是可观测性的三大支柱，本节补上日志。

### 为什么选 Loki 而不是 ELK

| | ELK（Elasticsearch） | Loki + Alloy |
| --- | --- | --- |
| 内存 | Elasticsearch 堆内存通常 2~4 GB，worker 只有 3.3 GiB 可分配，装不下 | Loki 单进程实测约 120 Mi，Alloy 每节点几十 Mi |
| 索引 | 对日志全文建倒排索引 | 只给标签建索引，内容按需扫描 |
| 界面 | Kibana，另一套系统 | 直接接入现有 Grafana，指标和日志在同一面板 |
| 查询 | KQL / Lucene | LogQL，语法与 PromQL 相近 |

采集器用 **Grafana Alloy**：Promtail 已停止维护，官方推荐迁移到 Alloy。

### lab-api：结构化日志

改用 Go 标准库 `log/slog` 输出 JSON 到 stdout，每条带 `service`、`version`；每个业务请求记一行访问日志：

```json
{"level":"INFO","msg":"request","service":"lab-api","version":"6441dcf","method":"GET","path":"/","status":200,"duration_ms":0.029,"remote_addr":"10.244.140.29:50464"}
```

- 5xx 时 `level` 为 `ERROR`，其余为 `INFO`。
- 探针和 `/metrics` 不记访问日志（就绪探针每 2 秒一次，全是噪音）。
- 单元测试验证访问日志是合法 JSON、字段正确、探针不产生日志。

### 安装

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm upgrade --install loki grafana/loki --version 7.6.0 -n logging --create-namespace \
  -f platform/logging/loki-values.yaml --wait --timeout 10m
helm upgrade --install alloy grafana/alloy --version 1.16.0 -n logging \
  -f platform/logging/alloy-values.yaml --wait --timeout 5m
# Grafana 增加 Loki 数据源
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version 93.3.0 \
  -n monitoring -f platform/monitoring/values.yaml --wait --timeout 10m
```

[`loki-values.yaml`](../platform/logging/loki-values.yaml)：SingleBinary 单进程，filesystem 存储落到 local-path 10Gi，tsdb + schema v13，compactor 删除超过 7 天的日志；关闭 gateway、memcached 缓存、canary、minio 等单机用不到的组件；开启 ServiceMonitor 采集 Loki 自身指标。

> Helm 遇到写错的配置项不会报错，只会忽略。所以安装前用 `helm template` 渲染检查：确认只有 1 个 StatefulSet、没有 memcached、保留期等配置写进了 Loki 配置。Loki 的 ServiceMonitor 只在集群存在该 CRD 时才渲染，离线渲染需加 `--api-versions monitoring.coreos.com/v1/ServiceMonitor`。

[`alloy-values.yaml`](../platform/logging/alloy-values.yaml) 的采集流程：

```text
discovery.kubernetes（只发现本节点 Pod：spec.nodeName = HOSTNAME）
  → discovery.relabel（namespace / pod / container / node / app 设为标签，拼出 /var/log/pods/*<uid>/<container>/*.log）
  → local.file_match → loki.source.file（跟踪日志文件）
  → loki.process（stage.cri 解析 containerd 日志前缀）
  → loki.write（推送到 loki:3100）
```

- **DaemonSet、只采集本节点**：每台节点一个 Alloy；若都去发现全部 Pod，同一条日志会被采集 4 次。chart 已用 Downward API 把 `HOSTNAME` 设为节点名。
- **容忍所有污点**：master 上的 etcd、apiserver 等日志也要采集。
- **读宿主机 `/var/log`**：kubelet 把容器 stdout 写在 `/var/log/pods/` 下，采集器需要挂载 hostPath 并以 root 读取，这是日志采集器的常规做法。

### 标签设计：Loki 最重要的原则

Loki 只给标签建索引，**每一种标签取值组合就是一个独立的数据流（stream）**。标签只放取值种类少的字段（命名空间、应用、Pod、节点）；状态码、耗时、请求路径这类每条都可能不同的字段留在日志内容里，查询时用 `| json` 现场解析。把高基数字段做成标签会让索引膨胀、查询变慢——和 Prometheus 指标标签的原则相同。

### 验证

| 检查 | 结果 |
| --- | --- |
| Alloy | 4 个 Pod 全部 Running，最近 10 分钟零报错（采集配置语法正确） |
| 覆盖范围 | 4 台节点、8 个命名空间的日志均已入库 |
| lab-api 访问日志 | 每分钟约 292 条（≈ 4.9 req/s），与 Prometheus 指标中的请求速率吻合 |
| 仪表盘 LogQL | 两条查询均执行成功（`FAIL_RATE=0` 时结果为空，符合预期） |

### 常用查询

```logql
{namespace="lab", app="lab-api"}                                   # 全部日志
{namespace="lab", app="lab-api"} | json | status >= 500            # 5xx 明细
{namespace="lab", app="lab-api"} | json | duration_ms > 1          # 慢请求
sum by (pod) (count_over_time({namespace="lab", app="lab-api"} | json | msg="request" [1m]))   # 各 Pod 每分钟请求数
{namespace="kube-system"} |= "error"                               # 系统组件日志全文搜索
```

SLO 仪表盘底部新增「日志（Loki）」一行：每分钟 `level=ERROR` 日志数（应与指标中的 5xx 速率一致，可互相印证）和 5xx 访问日志明细。

## 踩坑记录

1. **Grafana 被 OOMKilled**：凭经验给的 256 Mi 上限，Grafana 13 空载就用了 252 Mi，打开仪表盘时被内核杀掉（退出码 137），表现为 `port-forward` 报 `connection refused`。调到 512 Mi 后实测打开仪表盘约 322 Mi。资源配额应按实测数据调整——这也正是监控的价值。
2. **distroless 镜像里没有 `wget`**：Prometheus 容器无法 `kubectl exec` 调接口，改为经 API Server 代理访问：`kubectl get --raw /api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1/...`。
3. **浮点数不能直接判等**：promtool 测试期望 `0.02`，实际 `1 − 0.98 = 0.020000000000000018`。`fuzzy_compare: true` 的容差不足以覆盖；改为断言里先 `round(x, 0.001)` 再比较（`round` 会去掉指标名，期望标签写 `{}`）。
4. **`port-forward` 不是持久化访问**：它只是 kubectl 进程开的临时隧道。阶段 4 已改为 LoadBalancer IP + `*.lab.internal`（http://grafana.lab.internal）。
5. **虚拟机重启后 Loki 短暂 1/2、重启计数增加**：容器上次退出码 `255`、原因 `Unknown`，是节点重启时容器被直接中断；Loki 启动时要先加入 memberlist，期间日志里有"解析不了 `loki-memberlist`"的警告、就绪探针返回 503，属正常启动过程。判断方法：`uptime -s` 看节点开机时间，`/ready` 接口返回 `ready` 即恢复。
6. **单台节点拉镜像 `connection reset by peer`**：`failed to copy` 说明已开始下载、中途被断开，是 Mac 代理或 Harbor 侧的偶发网络问题，不是配置问题（其他节点拉同一镜像正常）。kubelet 会按退避自动重试；也可在该节点 `crictl pull` 手动拉一次加快恢复。

## 改进项

- [x] **集中日志**：Loki + Grafana Alloy，lab-api 改为 `slog` 结构化 JSON 日志（见第 5 节）。
- [ ] Alloy 去掉默认的 `filename` 标签：文件名随日志轮转变化，增加不必要的数据流。
- [ ] Alertmanager 配置通知渠道（邮件 / 飞书 / 钉钉 / Telegram Webhook），critical 与 warning 分路由；`Watchdog` 接入外部心跳检测。
- [ ] 控制平面组件指标改为监听节点 IP，恢复 controller-manager / scheduler / etcd / kube-proxy 监控。
- [ ] 压测验证滚动更新期间零失败（优雅退出的量化证据）。
- [ ] 链路追踪（OpenTelemetry + Tempo），多服务时再引入。

## 下一步

阶段 4：OpenWrt + FRR 与 Calico eBGP、ECMP，Calico 原生 LB IPAM 分配并宣告 LoadBalancer IP，dnsmasq 提供 `lab.internal` 内部域名，替代 `port-forward`（见 [stage4-network.md](stage4-network.md)）。
