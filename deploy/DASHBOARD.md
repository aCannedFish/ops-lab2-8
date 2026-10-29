# O3：Prometheus 原生三行九格看板

实现：`deploy/consoles/enrolld.html`，由 Prometheus 的 console 模板引擎直接执行 PromQL，九格数值每 5 秒刷新；每格的链接打开 Prometheus 原生时间序列图，展开「PromQL」可见查询。无需 Grafana 或 CDN。

## 访问

远程本次实际启动目录为 `/home/ubuntu/ops-lab2-8`，命令为：

```bash
taskset -c 0 tools/prometheus \
  --config.file=deploy/prometheus.yml \
  --storage.tsdb.path=/dev/shm/lab2-prom \
  --web.listen-address=127.0.0.1:9090 \
  --web.console.templates=deploy/consoles
```

保留原来的 TSDB，仅重启进程加载规则和 console 路径；不要同时运行两个 Prometheus 使用同一 TSDB。另一份工作树 `/home/ubuntu/lab2` 用于运行 enrolld、loadgen 和采集脚本（源码一致性记录：`runs/optional-checks/source-sha256.json`）。

本机建立隧道：

```bash
ssh -N -L 19090:127.0.0.1:9090 se-devops
```

打开 <http://127.0.0.1:19090/consoles/enrolld.html>；告警页面为 <http://127.0.0.1:19090/alerts>。不用开放安全组端口。

## 九格查询

第一行看服务 RED；第二行看资源 USE（本次绑核 CPU 1，503 在本示例读路径中表示连接池超时）；第三行看 SLO、燃烧率和告警。窗口固定为 1m，只有预算燃烧率使用 5m。将服务迁移到别的核时需要修改 CPU 选择器。

| 位置 | 标题与单位 | PromQL |
|---|---|---|
| 1 行 1 列：服务 · Rate | 读请求完成率；req/s | `sum(rate(http_requests_total{job="enrolld",route="/api/courses/{id}"}[1m]))` |
| 1 行 2 列：服务 · Errors | 读请求 5xx 比例；%（不含慢请求） | `100 * (sum(rate(http_requests_total{job="enrolld",route="/api/courses/{id}",code=~"5.."}[1m])) or vector(0)) / sum(rate(http_requests_total{job="enrolld",route="/api/courses/{id}"}[1m]))` |
| 1 行 3 列：服务 · Duration | 服务端读请求 p99；ms（直方图估计） | `1000 * histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{job="enrolld",route="/api/courses/{id}"}[1m])))` |
| 2 行 1 列：资源 · Utilization | 服务核 CPU 忙碌；%（CPU 1，排除 idle/iowait） | `100 * sum(rate(node_cpu_seconds_total{job="node",cpu="1",mode!~"idle\|iowait"}[1m]))` |
| 2 行 2 列：资源 · Saturation | 连接池等待 p99；ms | `1000 * histogram_quantile(0.99, sum by (le) (rate(db_pool_wait_seconds_bucket{job="enrolld"}[1m])))` |
| 2 行 3 列：资源 · Errors | 读路径连接池超时；req/s（503；本示例对应池超时） | `sum(rate(http_requests_total{job="enrolld",route="/api/courses/{id}",code="503"}[1m])) or vector(0)` |
| 3 行 1 列：SLO · Good | 读请求成功且 ≤50 ms；%（1m） | `100 * (sum(rate(http_request_duration_seconds_bucket{job="enrolld",route="/api/courses/{id}",code="200",le="0.05"}[1m])) or vector(0)) / sum(rate(http_requests_total{job="enrolld",route="/api/courses/{id}"}[1m]))` |
| 3 行 2 列：SLO · Burn | 错误预算燃烧率；倍（5m；阈值 14.4） | `(1 - (sum(rate(http_request_duration_seconds_bucket{job="enrolld",route="/api/courses/{id}",code="200",le="0.05"}[5m])) or vector(0)) / sum(rate(http_requests_total{job="enrolld",route="/api/courses/{id}"}[5m]))) / 0.01` |
| 3 行 3 列：SLO · Alert | 当前 firing 告警；0=未触发，1=触发 | `sum(ALERTS{alertname="EnrolldReadSLOBurnRateHigh",alertstate="firing"}) or vector(0)` |

## 语义与边界

- SLO：99% 的读请求以 200 且在 50ms 内完成，预算 1%。不良率 = 1 − good / total，燃烧率 = 不良率 / 0.01；慢 200、503、499 都消耗预算，而不仅是 5xx。
- `deploy/rules.yml` 要求 5m 和 1m 燃烧率均 >14.4 且持续 15s；告警的 value 是 **5m 燃烧率**。短窗口是实验缩短版；生产需要按响应时间、流量与误报率选窗口。
- 没有 good 序列时将 good 补 0；没有流量时不告警。该规则不负责宕机/抓取失败告警，生产应另配 `up == 0`，不能将无请求/无数据当成健康证明。
- 这是服务端 SLI，漏掉进入 handler 前的调度、网络、建连及没有到达服务端的请求；对外承诺的 SLO 应使用入口/客户端端到端观测。
- p99 是直方图桶插值；无请求时 `NaN` 保留，不伪造 100% 成功。当前告警卡在没有 firing 序列时显示 0。
- 控制台可访问、实际执行查询的 HTML 证据见 `runs/optional-checks/console-*.html`；完整触发和解除证据见同目录的 `alerts.jsonl`、`rules-*.json`。

## 规则校验

```bash
tools/prometheus-3.13.4.linux-amd64/promtool check config deploy/prometheus.yml
tools/prometheus-3.13.4.linux-amd64/promtool test rules deploy/rules.test.yml
```

六个用例覆盖健康请求、慢 200、仅 503 且缺失 good 桶、零流量、目标序列缺失、短窗口恢复，以及 `for: 15s` 尚未满足时不触发。
