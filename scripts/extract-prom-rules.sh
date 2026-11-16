#!/usr/bin/env bash
# =============================================================================
# extract-prom-rules.sh —— 阶段 3：把 PrometheusRule 的 spec 提取成 promtool 能读的规则文件
#
# 用法（Mac 或任意节点，兼容 macOS 自带 bash 3.2）：
#   ./scripts/extract-prom-rules.sh apps/lab-api/slo-rules.yaml > tests/stage3/slo-rules.prom.yaml
#   promtool test rules tests/stage3/slo-rules.test.yaml
# =============================================================================
set -euo pipefail

src="${1:?用法: $0 <PrometheusRule 文件>}"
[ -f "$src" ] || { echo "找不到文件: $src" >&2; exit 1; }
grep -q '^kind: PrometheusRule' "$src" || { echo "$src 不是 PrometheusRule" >&2; exit 1; }

# 取 spec: 之后的内容，去掉 2 格缩进，得到以 groups: 开头的规则文件
awk 'found { sub(/^  /, ""); print } /^spec:/ { found = 1 }' "$src"
