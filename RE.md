# Lab2 复现手册

本手册按指导书的操作顺序组织，使用仓库已有的 `run.sh`、`rates.sh`、`table.sh` 和 `promsteps`。统一在主机 A 的 `~/lab2` 操作，使用默认端口 8080、9090、9100；结束后停止实验进程。实验要求见 [指导书](lab-2.html)，本组结果见 [LAB2.md](LAB2.md)。

任务 1～4 分别由四位成员负责，可以按顺序交接服务和监控。每节说明接收状态、具体操作和交出状态。新结果使用 `re-` 前缀，避免覆盖已有证据；再次复现时换一个名字即可。

课件引用按 PDF 阅读器页码计算，包含封面。L-06 主要解释运行时、线程和连接池，L-07 主要解释资源上限、排队、存储与网络。

## 任务交接

| 任务 | 成员 | 接收什么 | 交出什么 |
|---|---|---|---|
| 任务 1 | CharonRyui | 已有仓库、工具和任务 0 基线 | 默认 enrolld、Prometheus、node_exporter；低负载数据 |
| 任务 2 | aCannedFish | 任务 1 的三个进程和每请求开销 | R1、pprof、R2 数据；`-pool 41` 的 enrolld，监控保持运行 |
| 任务 3 | 1JI0O | 监控进程；任务 0 的 fsync、任务 2 的 CPU 数据 | W1/W2/W3 数据；`-sync interval` 的 enrolld |
| 任务 4 | Mikujoker | 前三项保存的 CSV、日志和预测 | 四道分析题；分析本身不要求服务继续运行 |

服务器进程可以在成员之间继续使用。变量只属于设置它的 Shell：沿用同一个终端可以保留，重新 SSH 登录后需要重新设置。`GEN_CPUS=0` 在每个压测终端设置；写路径用 `SLO=0.02`，读路径用默认 0.05。

若某位成员单独复现任务 2 或 3，先按“任务 1”的启动命令启动三个进程，再从仓库读取已提交的前置数据即可，无需重做全部前置测量。

## 开始之前

### 主机与终端

| 名称 | 含义 |
|---|---|
| 主机 A：`se-devops` | 运行 enrolld、监控和必做压测；工作目录 `~/lab2` |
| 主机 B：`se-devops2` | 只在 O2 中运行 loadgen；工作目录 `~/lab2-o2` |
| 终端 A | SSH 到主机 A，前台运行 enrolld |
| 终端 B | SSH 到主机 A，运行 node_exporter 和 Prometheus |
| 终端 C | SSH 到主机 A，执行压测、查询和制表 |

“终端 B”仍在主机 A 上；“主机 B”是另一台服务器。必做实验的三个终端都连接 `se-devops`。

在三个终端各执行：

```bash
ssh se-devops
cd ~/lab2
export PATH=/home/ubuntu/apps/go/bin:$PATH
```

只在终端 C 执行一次准备：

```bash
git pull --ff-only
make build test
mkdir -p data
export GEN_CPUS=0
unset SLO
```

本组主机已经安装 sysstat 和监控工具。新环境缺少工具时，才执行 `sudo apt install -y sysstat` 和 `scripts/get-tools.sh`。

2026-11-03 整理后，主机 A 的 `~/lab2` 已同步默认配置，遗留实验进程已停止。首次启动前可检查：

```bash
pgrep -a 'enrolld|prometheus|node_exporter|loadgen'
```

没有输出就直接开始。有输出时先核对进程参数，避免同时运行两次压测或重复启动监控。无需改端口、创建新仓库或生成环境脚本。

### 默认配置

| 组件 | 地址或参数 |
|---|---|
| enrolld | `127.0.0.1:8080`，绑核 1 |
| Prometheus | `127.0.0.1:9090`，绑核 0 |
| node_exporter | `127.0.0.1:9100`，绑核 0 |
| loadgen | 绑核 0，默认泊松到达、每阶段 30 秒 |
| 应用数据 | `data/`，位于真实云盘 |
| 监控数据 | `/dev/shm/lab2-prom`，位于内存 |
| 读路径 | `-work 200000 -pool 4 -db-ms 10` |
| 写路径 | 默认 `-sync each` |

监控数据放在内存中，可减少 Prometheus 写盘对写路径实验的干扰。重启 Prometheus 并复用原路径会保留数据；主机重启会丢失 `/dev/shm` 中的数据。

## 任务 0

任务 0 建立环境与 fsync 基线，由 aCannedFish 完成。后面的成员可以直接使用仓库中的记录。

### 基线操作

终端 C 查看环境：

```bash
lscpu
lscpu -e
free -m
uname -r
cat /etc/os-release
findmnt -T data
lsblk
```

确认 `data/` 在 `/dev/vda1` 的 ext4 上，不能放在 tmpfs。连续测三次 fsync：

```bash
mkdir -p runs/re-t0
for i in 1 2 3; do
  bin/enrolld -bench-fsync 2000
done | tee runs/re-t0/bench-fsync-2000.txt
```

终端 A 运行 `vmstat -w 1`，终端 B 运行 `iostat -dx 1 vda`，先观察约 10 秒空载；随后在终端 C 执行：

```bash
bin/enrolld -bench-fsync 5000 | tee runs/re-t0/bench-fsync-5000.txt
```

比较负载期间与空载时的读数。完成后在终端 A、B 按 Ctrl-C，停止两个观察工具。需要保留工具输出时，在原命令后接 `| tee runs/re-t0/vmstat.log` 或 `| tee runs/re-t0/iostat.log`。

### 原理与追问

本组三次 fsync 均值为 1.304、1.379、1.406 ms，平均 1.363 ms。因此一个写者串行 fsync 的粗略上限为：

\[
C_{fsync}=1000/1.363\approx734\text{ 次/秒}
\]

L-07 第 13～16 页区分了 IOPS、吞吐量和延迟。一次小写入后的同步提交主要受同步延迟限制，不能仅用磁盘 MB/s 估算 TPS。

| 观测项 | 含义与本组现象 |
|---|---|
| `r` | 可运行任务数，用于观察等待 CPU 的压力 |
| `b`、`wa` | 不可中断睡眠任务和 I/O 等待时间；负载时约为 1、43%～46% |
| `us`、`sy` | 用户态与内核态 CPU 时间；本组 fsync 负载时合计约 6% |
| `w/s`、`wkB/s` | 每秒完成写请求数、写入速率 |
| `w_await`、`f_await` | 单个设备写请求、flush 请求的平均响应时间 |
| `aqu-sz` | 平均未完成 I/O 数，包含正在处理的请求 |
| `%util` | 设备忙碌时间比例；本组约 94% |

解释时注意：工具启动后的第一份报告通常是开机以来的统计，比较时取后续间隔样本。CPU 空闲仍可能吞吐受限，因为写者在等磁盘。`aqu-sz=1` 不等于一个请求纯粹在排队；高 `%util` 也要结合吞吐平台、延迟和工作负载判断。

## 任务 1

负责人：CharonRyui。目标是启动指标流水线，测出低负载下的每请求开销。接收任务 0 的环境与基线文件，本任务负责首次启动三个服务。

### 启动进程

终端 A：

```bash
taskset -c 1 bin/enrolld
```

启动日志应显示监听 `127.0.0.1:8080`、`GOMAXPROCS=1`、连接池大小 4。该进程保持前台运行。

终端 B：

```bash
taskset -c 0 tools/node_exporter --web.listen-address=127.0.0.1:9100 \
  > data/node_exporter.log 2>&1 &
NODE_PID=$!
taskset -c 0 tools/prometheus --config.file=deploy/prometheus.yml \
  --storage.tsdb.path=/dev/shm/lab2-prom \
  --web.listen-address=127.0.0.1:9090 \
  --web.console.templates=deploy/consoles
```

最后一个参数用于仓库已有的 O3 看板，其余与指导书一致。`NODE_PID` 只保存在终端 B，结束时用于停止后台 node_exporter。

终端 C 检查目标：

```bash
curl -s 127.0.0.1:9090/api/v1/targets | grep -o '"health":"[a-z]*"'
curl -s 127.0.0.1:8080/api/courses/1
curl -s 127.0.0.1:8080/metrics | grep -E '^(# TYPE )?http_request_duration_seconds'
```

两个目标都为 `up` 后再加压。刚启动时若显示 `unknown`，等几秒重查；若为 `down`，查看 `/api/v1/targets` 的 `lastError` 和实际抓取地址。

### 运行与制表

终端 C：

```bash
export GEN_CPUS=0
unset SLO
scripts/run.sh re-t1-light -url http://127.0.0.1:8080/api/courses/1 -rates 0,50,100
scripts/table.sh runs/re-t1-light \
  ok_rps mean_ms p99_ms server_rps server_mean_ms server_p99_ms \
  cpu_ms_per_req db_query_mean_ms
```

四条 RED/SLI 查询已经填写在 [queries-red.txt](deploy/queries-red.txt)，无需重新编写。`run.sh` 同时保存配置、客户端结果、服务与资源 CSV，以及 vmstat、mpstat、iostat、pidstat 原始日志。

### 应当会讲

| 概念 | 本实验中的解释 |
|---|---|
| RED | 请求速率、错误比例、耗时，从服务请求看问题 |
| USE | 利用率、饱和度、错误，从每项资源看问题 |
| Counter | 累计事件数，`rate()` 换算为每秒增长量 |
| Gauge | 当前状态，如连接池占用，对采样值取平均 |
| Histogram | `_bucket{le="…"}` 记录不超过边界的累计次数，`_sum` 是耗时总和 |
| 服务端平均耗时 | duration 的 sum 增量 ÷ count 增量 |
| 服务端 p99 | 先按 `le` 聚合各状态码的桶，再用 `histogram_quantile` 插值 |
| 服务端 SLI | 200 且不超过 50 ms 的计数 ÷ 全部请求计数 |

本组 T1 第 3 档测得：每请求 CPU 为 0.539766 ms，每次占连接为 10.4262 ms。CPU 时间是实际执行成本；占连接时间包含休眠等待，不能互换。L-06 第 16、19 页用同样的区分推算线程池和连接池上限。

零负载行出现 `NaN` 或 `+Inf`，表示零请求分母下该指标无定义。没有 5xx 时查询分子可能没有序列，`or vector(0)` 用来补零；没有流量时不能据此得出 100% 达标。

压测采用开环：按计划发送，不等待前一个请求返回。服务变慢时到达不会自动下降，能够暴露排队。泊松到达带来随机波动，因此实际发送率不必等于目标 RPS。

### 交给任务 2

保持终端 A、B 中的三个进程运行。交出 `runs/re-t1-light/`，特别是 `red.csv`、`steps.csv` 和 `meta.txt`。下一位成员若使用新终端 C，需要重新 SSH、进入 `~/lab2`、设置 Go 的 PATH、`export GEN_CPUS=0` 并 `unset SLO`。

## 任务 2

负责人：aCannedFish。接收默认的 enrolld、两个监控进程，以及任务 1 的每请求开销。开始前在终端 C 执行 `curl -s 127.0.0.1:8080/config`，确认 `pool=4`、`work=200000`、`db_ms=10`。若服务已停止，按任务 1 的命令启动；若池大小已改变，在终端 A 按 Ctrl-C 后执行 `taskset -c 1 bin/enrolld`。

### R1 预测

用任务 1 的测量值计算：

\[
C_{pool}=4/0.0104262\approx384\text{ req/s}
\]

\[
C_{CPU}=1/0.000539766\approx1853\text{ req/s}
\]

连接池先满。本组历史预测 p99 在约 290 请求/秒开始超过 50 ms，实际首次超过是在 342.4 请求/秒。复现前先记录本轮预测，保留已有历史预测。若本轮 T1 的开销明显变化，按同一公式替换下面的 384。

### R1 测量

终端 A 保持默认服务，终端 C：

```bash
export GEN_CPUS=0
unset SLO
RATES=$(scripts/rates.sh 384)
scripts/run.sh re-r1-pool4 -url http://127.0.0.1:8080/api/courses/1 -rates "$RATES"
scripts/table.sh runs/re-r1-pool4 \
  ok_rps error_rate p99_ms server_mean_ms inflight_avg cpu_ms_per_req \
  pool_in_use_avg pool_wait_p99_ms sched_wait_p99_ms svc_cpu_busy procs_running_avg
```

历史最大成功吞吐为 384.4 请求/秒，池平均占用为 4，等待 p99 约 994 ms，而服务核忙碌仅 20.25%。判断依据是池占满、等待增加、吞吐进入平台；低 CPU 利用率不能排除连接池饱和。

### CPU 剖析

按指导书在约 0.8 倍上限处采样。终端 C：

```bash
taskset -c "$GEN_CPUS" bin/loadgen -url http://127.0.0.1:8080/api/courses/1 \
  -rates "$(scripts/rates.sh 384 0.8)" -step 40s > /dev/null 2>&1 &
LG=$!
sleep 10
go tool pprof -top -nodecount=15 \
  'http://127.0.0.1:8080/debug/pprof/profile?seconds=20' \
  | tee runs/re-r1-pool4/pprof-top.txt
wait "$LG"
```

`main.spin` 是读路径上的纯计算。其余采样落在 HTTP、JSON、系统调用、内存分配和调度上。pprof 的百分比表示 CPU 样本分布，不表示端到端延迟占比。

可用相同目标负载阶段的每请求 CPU 乘以 spin 比例作近似拆分。本组历史比例为 82.54%；另有同一计数窗口内的补测，见 [profile 结果](runs/r1-profile-window/profile-summary.json)：6115 个请求消耗 3.332097 CPU 秒，每请求约 0.545 ms，其中 spin 约 0.450 ms、其余约 0.094 ms。

### R2 预测

从 R1 中选取尚未饱和、负载较高的阶段。本组采用第 6 档的 0.515729 CPU ms/请求和 10.5539 ms 连接占用，得到：

\[
C=1000/0.515729\approx1939\text{ req/s}
\]

\[
P_2=\lceil2\times1939\times0.0105539\rceil=41
\]

池容量设为预计 CPU 上限的约两倍，以便观察 CPU 先饱和。先写下 C、P2 和预测，再开始 R2；本轮数据不同时替换 1939 和 41。

### R2 测量

终端 A 按 Ctrl-C，等旧服务退出后启动：

```bash
taskset -c 1 bin/enrolld -pool 41
```

终端 C：

```bash
RATES=$(scripts/rates.sh 1939 0.3 0.6 0.8 0.9 1.0 1.1 1.25 1.5)
scripts/run.sh re-r2-pool41 -url http://127.0.0.1:8080/api/courses/1 -rates "$RATES"
scripts/table.sh runs/re-r2-pool41 \
  ok_rps error_rate p99_ms cpu_cores cpu_ms_per_req cpu_wait_threads \
  sched_wait_p99_ms pool_in_use_avg svc_cpu_busy procs_running_avg cpu_psi_some
```

历史最高健康阶段为 2130.8 请求/秒，服务核忙碌约 93.75%。目标升到 2424 后 CPU 接近满载，调度等待和错误率剧增，工具停止后续档位。

该过载档还出现 31.91 ms 的发送滞后，25 秒内只有三次 enrolld 指标抓取成功。因此服务端 `cpu_cores=0.128813` 失真，不能解释为 CPU 空闲；同期 pidstat、mpstat 显示满载。复现时同时检查 `steps.csv` 的 `warn`、目标 `up` 和原始工具日志。

### 课程联系

| 追问 | 回答 |
|---|---|
| 为什么不是线程池先满？ | L-06 第 31 页要求分别算上限。本例池容量约 384、CPU 约 1853，连接池更低。Go 的并发单位也不同于 Tomcat 平台线程。 |
| 扩大连接池为什么有效？ | R1 的等待发生在池前；扩池解除这层限制，之后由 CPU 限制。对应 L-06 第 32～33 页的瓶颈迁移。 |
| 真实数据库能一直扩池吗？ | 不能。L-06 第 19 页指出数据库自身并行能力有限。示例只休眠，没有模拟数据库 CPU、锁和磁盘竞争。 |
| `GOMAXPROCS=1` 是否只有一个线程？ | 它限制同时执行 Go 代码的线程数，进程仍可有多个 OS 线程。goroutine 在运行时内排队，内核队列不能反映全部积压。见 L-06 第 13、17～18 页。 |
| 为什么未到上限，p99 已上升？ | 随机到达会短时占满资源。L-07 第 6 页用排队模型说明接近满负载时等待增长，需要预留容量。 |
| 低负载开销能精确预测上限吗？ | 固定成本、缓存和调度随负载变化。本组每请求 CPU 随负载下降，所以低负载预测偏保守。 |

### 交给任务 3

保留 R2 服务和两个监控进程，交出 R1、R2、pprof 结果。明确告知下一位成员：当前 enrolld 是 `-pool 41`，仍为默认 each 模式；写路径需要停止它并按任务 3 的命令重启。

## 任务 3

负责人：1JI0O。接收监控进程、任务 0 的 fsync 基线和任务 2 的 CPU 拆分。可以使用仓库已提交的 `runs/t0-baseline/`、`runs/r1-pool4/` 数据，不依赖上一位成员的 Shell 变量。

若终端 C 是新开的，先执行“开始之前”的 SSH、目录和 PATH 命令。若监控已停止，按任务 1 的终端 B 命令启动。开始写实验前，终端 A 停止旧 enrolld。

### W1 预测

本组 fsync 平均 1.363 ms，each 粗略上限为 734 TPS。按非 spin 开销 0.0915 ms/请求估计 CPU 需求：

\[
734\times0.0915/1000\approx0.067\text{ 核}
\]

这个估计未充分包含 write/fsync 系统调用，实测约 0.130 核。预测应先写下，再讨论偏差。L-07 第 14 页给出按同步延迟和次数推算写上限的方法。

### W1 测量

下面的 `rm` 只清空用于压测的选课日志；需要保存旧日志时先另存。终端 A：

```bash
rm -f data/enroll.log
taskset -c 1 bin/enrolld -sync each
```

终端 C：

```bash
export GEN_CPUS=0
export SLO=0.02
B='{"student":"s{{seq}}","course":"c1"}'
RATES=$(scripts/rates.sh 734 0.2 0.4 0.6 0.8 0.9 1.0 1.1 1.2)
scripts/run.sh re-w1-each -url http://127.0.0.1:8080/api/enroll -body "$B" -rates "$RATES"
scripts/table.sh runs/re-w1-each \
  ok_rps error_rate p99_ms server_p99_ms cpu_cores \
  fsync_per_s fsync_mean_ms batch_mean svc_cpu_busy cpu_iowait \
  disk_w_per_s disk_w_await_ms disk_f_per_s disk_f_await_ms disk_aqu_sz disk_util
```

本组客户端最大成功吞吐为 729.5 TPS，服务端同期约 704 TPS，p99 已达 1175.70 ms。继续加压后 fsync 速率不再增加，客户端大量超时，说明串行同步提交达到上限。

### W2 测量

先预测 group 的吞吐、批量和 p99。本组在 734 TPS 目标下预测约 734 TPS、1.5 条/批、15 ms。一次 fsync 期间平均到来约 `734×0.001393≈1.02` 条新记录，等待期间的记录可合成下一批。

终端 A 按 Ctrl-C，等 each 服务退出后执行：

```bash
rm -f data/enroll.log
taskset -c 1 bin/enrolld -sync group
```

终端 C 沿用本任务的 `GEN_CPUS=0`、`SLO=0.02` 和请求体变量 `B`：

```bash
RATES=$(scripts/rates.sh 734 0.4 0.8 1.0 1.5 2 3 4)
scripts/run.sh re-w2-group -url http://127.0.0.1:8080/api/enroll -body "$B" -rates "$RATES"
scripts/table.sh runs/re-w2-group \
  ok_rps error_rate p99_ms fsync_per_s fsync_mean_ms batch_mean cpu_cores disk_util
```

同为 734 TPS 目标，本组 W2 实测批量 1.41283，p99 为 8.72 ms。最高档成功吞吐为 2927.5 TPS，p99 为 10.46 ms。group 将多条记录共享一次 fsync，仍在同步完成后确认。

### W3 测量

终端 A 按 Ctrl-C，等 group 服务退出后执行：

```bash
rm -f data/enroll.log
taskset -c 1 bin/enrolld -sync interval
```

终端 C 继续沿用本任务的三个变量：

```bash
RATES=$(scripts/rates.sh 734 0.4 1.5 4)
scripts/run.sh re-w3-interval -url http://127.0.0.1:8080/api/enroll -body "$B" -rates "$RATES"
scripts/table.sh runs/re-w3-interval \
  ok_rps error_rate mean_ms p99_ms fsync_per_s batch_mean cpu_cores disk_util
unset SLO
```

最后的 `unset SLO` 恢复读路径默认的 50 ms。最高同档下，本组 W3 p99 为 1.92 ms，W2 为 10.46 ms。W3 每秒约一次 fsync，成功响应时记录可能仍在页缓存。

### 课程联系

| 追问 | 回答 |
|---|---|
| each 的锁与磁盘有什么关系？ | each 在互斥锁内执行 write 和 fsync，持锁期间包含磁盘等待。对应 L-07 第 25 页“磁盘慢使锁持有时间延长”。 |
| 课件算出 250 TPS，本组为何约 734？ | L-07 第 14、25 页采用 2 ms、每事务两次 fsync 的设定；本组 each 每条一次，平均约 1.363 ms。输入条件不同。 |
| group 是否等于定时攒批？ | 本实现取走当前排队记录，没有额外攒批定时器，每批最多 1024 条；前一批同步期间到来的请求形成下一批。 |
| `%util` 相近，吞吐为什么相差四倍？ | 每次同步确认的记录数不同。忙碌时间不能直接换成业务 TPS。 |
| 应用 fsync 与设备 await 为什么不同？ | 应用同步包含文件系统处理和多次 I/O；await 按单个设备请求计。请求可能重叠，不能简单相加。 |
| interval 的一秒是否严格丢失上限？ | 默认周期是一秒，实际风险窗口还受调度、同步耗时和同步失败影响。本实验未模拟掉电。 |
| 选课记录应选哪种？ | 本组数据支持 group：同步后确认，同时减少排队。interval 适合允许近期数据丢失或可可靠重放的场景。 |

### 交给任务 4

交出 W1/W2/W3 的 CSV、日志和预测。当前 enrolld 为 interval、默认池大小 4，监控仍可保留给选做实验；终端 C 的 SLO 已恢复默认。任务 4 只分析已保存数据，不要求保留这些进程。

## 任务 4

负责人：Mikujoker。直接读取仓库中的结果，不需要继承上一位成员的变量，也不需要重新启动服务器。下面使用已提交的历史目录；分析本轮复现时，将目录换成三位成员交出的 `re-` 目录。

### 整理数据

在自己的 Mac 仓库执行：

```bash
cd ~/Documents/ops-lab2-8
git pull --ff-only
scripts/table.sh runs/r1-pool4 \
  ok_rps p99_ms server_rps server_mean_ms inflight_avg pool_in_use_avg svc_cpu_busy
scripts/table.sh runs/r2-pool41 \
  ok_rps p99_ms cpu_ms_per_req sched_wait_p99_ms svc_cpu_busy
scripts/table.sh runs/w1-each ok_rps p99_ms fsync_per_s batch_mean disk_util
scripts/table.sh runs/w2-group ok_rps p99_ms fsync_per_s batch_mean disk_util
scripts/table.sh runs/w3-interval ok_rps p99_ms fsync_per_s batch_mean disk_util
```

每题先明确数据出处、测量位置和窗口，再给出结论。需要额外查询时，只要原 Prometheus TSDB 仍在，可在主机 A 用 `scripts/requery.sh runs/<名字>` 重算；该命令会更新对应 CSV，修改前保留旧结果。

### 问题一

资源上限按“容量 ÷ 每请求占用”计算。L-06 第 31 页的资源表和 L-07 第 25 页的资源账都要求逐项比较，不能凭 CPU、内存、带宽三个百分比猜瓶颈。

| 资源 | 本组计算 | 实测与结论 |
|---|---|---|
| R1 连接池 | `4÷0.0104262≈384 req/s` | 最高成功吞吐 384.4，池先饱和 |
| R2 CPU | `1÷0.000515729≈1939 req/s` | 最高健康阶段 2130.8，实测单请求 CPU 降低 |
| W1 串行同步 | `1000÷1.363≈734 TPS` | 客户端最高 729.5，服务端同期约 704 |

L-07 第 6 页用 M/M/1 模型说明排队趋势：平均响应时间为 `服务时间÷(1−利用率)`。利用率从 0.5 升到 0.9 时，均值从两倍服务时间升到十倍。课件的“上限×0.7”用于预留余量。本例有四个连接和近似固定的休眠时间，不满足该模型的全部假设，不能直接用它计算 R1 的 p99。

R1 满足 p99≤50 ms 的最高阶段为 311.1 请求/秒，占预测上限约 81%。上限与满足延迟目标的容量不同；后者还取决于目标和到达波动。

### 问题二

L-06 第 16 页的 Little's Law 为：

\[
L=\lambda W
\]

三个量应对应相同系统边界和近似稳定窗口，W 必须取平均耗时。用 `server_rps×server_mean_ms÷1000` 计算 R1 的在途数：

| R1 阶段 | λW | inflight_avg | 相对实测差异 |
|---|---|---|---|
| 3 | 2.759 | 2.16 | +27.7% |
| 6 | 7.550 | 6.52 | +15.8% |
| 9 | 464.608 | 463.6 | +0.2% |

在途数较小、采样只有约 25 次时，瞬时采样均值容易波动；窗口切换和 rate 外推也会带来差异。p99 只描述尾部位置，代入后不再是平均在途数。

解释 R2 时区分两层排队：内核观察可运行 OS 线程，Go 还会在运行时队列中等待执行 goroutine。L-06 第 13、17～18 页说明并发模型改变等待位置，但 CPU、连接池和锁的上限仍然存在。

### 问题三

比较相同目标到达率下的各模式。历史 734 TPS 档，W1 p99=1175.70 ms，W2 p99=8.72 ms；W2 的批量约 1.41。更高负载下批量继续增加，从而摊薄同步开销。

L-07 第 14 页区分 write 返回与 fsync 返回，第 25 页进一步说明锁持有期间的 I/O 等待。group 保留同步后确认；interval 提前确认，代价是掉电时可能丢失尚未同步的记录。不能把 W3 的低延迟直接描述成无代价的优化。

### 问题四

| 口径 | 客户端 | 服务端 |
|---|---|---|
| 吞吐 | 成功 2xx 数 ÷ 阶段时长 | 完成计数的速率，含失败状态 |
| 延迟样本 | 只统计成功请求 | 直方图包含各状态码 |
| 计时 | 计划发送至读完响应体 | 进入 handler 至 handler 返回 |
| 窗口 | 完整阶段 | 去掉前 5 秒 |

客户端还包含发送滞后、网络传输、内核排队和进入 handler 前的等待。handler 内发生的调度等待仍在服务端计时中。

L-06 第 22 页强调平均值无法表示尾部。各阶段 p99 也不能直接平均：本组 R1 的阶段 p99 平均为 358.47 ms，总样本重新计算为 1011.35 ms。正确做法是合并原始样本，或合并相同桶边界、互不重叠窗口的桶计数增量后再算分位数。

服务端直方图 p99 有桶内插值误差。R1 第 9 档服务端为 1987.34 ms、客户端为 1012.18 ms，宽桶是主要原因；W1 的 5000 ms 对应 p99 落入 +Inf 桶后的有限边界返回值。

SLO=99% 时，预算比例为 1%。R1 第一个不达标阶段的客户端 SLI=0.9664，因此燃烧率为 `(1−0.9664)÷0.01=3.36`。若流量水平和不良率持续，30 天预算约 `30÷3.36=8.93` 天耗尽。端到端 SLI 应尽量靠近用户，服务端埋点用于评价本服务处理质量。

### 完成交接

把分析与引用整理进 LAB2，并核对数字能在 CSV 或日志中找到。原始输出、历史预测保持原样。若后面不再做选做实验，通知前面成员按“结束实验”停止服务；已保存的 CSV 不依赖进程继续运行。

## 选做实验

选做可接着任务 3 做，沿用两个监控进程；每次只在终端 A 停止并重启 enrolld。单独做选做时，先按任务 1 启动服务和监控。终端 C 重新设置 `export GEN_CPUS=0`、`unset SLO`，使用默认 50 ms 阈值。

### O1 内存

负责人：VigilLover。先记录预测：GOGC=400 允许更大的堆增长空间，预计 GC 次数和 GC CPU 减少、RSS 增加；p99 变化由实测判断。

终端 A 按 Ctrl-C 停止原服务，启动第一组：

```bash
GOGC=100 taskset -c 1 bin/enrolld
```

终端 C：

```bash
scripts/run.sh re-o1-gc100 -url 'http://127.0.0.1:8080/api/report?mb=4' -rates 100 -step 60s
```

第一组结束，终端 A 按 Ctrl-C，启动第二组：

```bash
GOGC=400 taskset -c 1 bin/enrolld
```

终端 C：

```bash
scripts/run.sh re-o1-gc400 -url 'http://127.0.0.1:8080/api/report?mb=4' -rates 100 -step 60s
for name in re-o1-gc100 re-o1-gc400; do
  bin/promsteps -steps "runs/$name/steps.csv" \
    -queries deploy/queries-o1-gc.txt -var route=/api/report -var slo=0.05 \
    > "runs/$name/red.csv"
  scripts/table.sh "runs/$name" ok_rps p99_ms rss_avg_mib
  grep -E '^go_gc_(cycles_total|cpu_seconds_total) ' "runs/$name/metrics-start.txt" "runs/$name/metrics-end.txt"
done
```

最后两项 GC 计数用结束值减开始值。RSS 用阶段均值，p99 用客户端结果。`queries-o1-gc.txt` 包含原 RED 查询，另外增加内存与 GC 查询；不需要改服务代码。若做反序复测，按 400→100 再运行一遍，结果目录增加 `-repeat` 后缀。

历史两轮均观察到 GC 次数减少约 75%、GC CPU 减少约 72%，RSS 从约 11 MiB 增至 25.4 MiB，p99 降低约 63%～65%。L-06 第 7、12 页说明堆只是进程内存的一部分，堆大小和 GC 成本需要权衡；本次 Go 实验体现相同的取舍，但 GC CPU 不等于 JVM 的 STW 暂停时间，也不能由 GOGC 推出 RSS 的固定倍数。

完成后终端 A 按 Ctrl-C。下一项直接启动普通 `taskset` 命令即可，前面的 `GOGC=400` 只作用于那次服务进程。

### O2 网络

目的：让 B 直接请求 A 的大响应接口，观察实际内网路径。先记录带宽需求和饱和预期，再开始测量。

两台主机内网地址为 A=`192.168.0.134`、B=`192.168.0.142`。在华为云控制台进入 A 关联的安全组，添加以下入方向规则，保存后再启动服务。

| 字段 | 配置 |
|---|---|
| 策略 | 允许 |
| 类型 | IPv4 |
| 协议 | TCP |
| 端口 | 8080 |
| 源地址 | `192.168.0.142/32` |
| 描述 | Lab2 O2，允许主机 B 访问 A |

终端 A 确认旧服务已退出，启动：

```bash
taskset -c 1 bin/enrolld -addr 0.0.0.0:8080
```

终端 C 保存 A 的网络采样：

```bash
mkdir -p runs/re-o2
sar -n DEV,ETCP 1 > runs/re-o2/sar.log &
SAR_PID=$!
```

另开一个终端登录主机 B。B 已有从 A 复制的 Linux loadgen，无需安装 Go 或从外网克隆仓库：

```bash
ssh se-devops2
cd ~/lab2-o2
mkdir -p runs/re-o2
taskset -c 0,1 ./loadgen -url 'http://192.168.0.134:8080/api/export?kb=256' \
  -rates 100,250,400,500,700,1000,1500,2500 -step 30s \
  -out runs/re-o2/steps.csv 2>&1 | tee runs/re-o2/loadgen.log
```

加压期间，在终端 C 查看并保存 TCP 状态：

```bash
ss -tin '( sport = :8080 and dst 192.168.0.142 )' | tee runs/re-o2/ss.txt
```

重点看发送队列、RTT 和 retrans。可以在低负载、高负载各执行一次，用不同文件名保存。O2 直接运行 loadgen，因为 `run.sh` 要求负载端与服务端在同一台主机。

B 完成后，在终端 C 执行 `kill "$SAR_PID"`，在终端 A 按 Ctrl-C 停止服务，随后在云控制台删除本次添加的 TCP 8080 规则。

需要双核对照时，在单核测量结束后记录预测，再将 A 的启动命令改为 `GOMAXPROCS=2 taskset -c 0,1 bin/enrolld -addr 0.0.0.0:8080`，B 使用 800、1000、1200 请求/秒，每档 45 秒，结果保存到新目录。两组均在上述安全组规则下测量，对照结束后统一删除临时放通。

L-07 第 18～21 页要求分开核算往返和字节数：

\[
\text{网络耗时}\approx\text{往返次数}\times RTT+\frac{\text{数据量}}{\text{带宽}}
\]

\[
\text{带宽需求}=r\times256\times1024\times8\text{ bit/s}
\]

1000 请求/秒仅响应体就需要约 2.097 Gbit/s。本轮安全组条件下的单核与双核测量均在约 2.1 Gbit/s 附近形成平台，随后队列、重传和延迟上升。高负载时 CPU 也达到上限。数据和配置见 `runs/o2-sg-single/`、`runs/o2-sg-dual/`，结论对应本次 A→B 路径及服务配置。

### O3 告警

负责人：CharonRyui。沿用默认端口的 Prometheus，配置和九格看板已经在仓库中。终端 A 停止上一服务后执行 `taskset -c 1 bin/enrolld`，恢复池大小 4、each 模式。终端 C 确认 `unset SLO`，预测告警经历 inactive→pending→firing→inactive。

若刚做过读路径过载，先让上一轮的 5 分钟窗口过去，并确认当前规则为 inactive。无需换端口、换 TSDB 或重启监控。

终端 C 校验规则：

```bash
tools/prometheus-3.13.4.linux-amd64/promtool check config deploy/prometheus.yml
tools/prometheus-3.13.4.linux-amd64/promtool test rules deploy/rules.test.yml
curl -s 127.0.0.1:9090/api/v1/rules
```

记录告警状态并压测：

```bash
while true; do
  date -Is
  curl -s 127.0.0.1:9090/api/v1/alerts
  printf '\n'
  sleep 5
done > runs/re-o3-alerts.log &
ALERT_PID=$!
scripts/run.sh re-o3 -url http://127.0.0.1:8080/api/courses/1 -rates 100,461,100 -step 90s
curl -s 127.0.0.1:9090/api/v1/alerts
```

最后确认告警解除，再执行 `kill "$ALERT_PID"`。若最后一阶段结束时还没解除，保留轮询，待短窗口恢复后再停。

在 Mac 用仓库默认端口建立隧道：

```bash
ssh -N -L 9090:127.0.0.1:9090 se-devops
```

浏览器访问 <http://127.0.0.1:9090/consoles/enrolld.html>，告警页为 <http://127.0.0.1:9090/alerts>。完整查询见 [看板说明](deploy/DASHBOARD.md)。

| 追问 | 回答 |
|---|---|
| 为什么慢 200 也告警？ | SLO 要求成功且不超过 50 ms，慢请求同样消耗错误预算。 |
| 为什么使用两个窗口？ | 长窗口判断影响，短窗口确认问题仍在发生；两个条件持续满足 15 秒才 firing。 |
| 14.4 倍代表什么？ | 不良率为允许比例的 14.4 倍；若持续，30 天预算约 50 小时耗尽。 |
| 解除是否代表预算恢复？ | 解除表示当前条件不再满足，之前的不良事件仍在其所属预算窗口中。 |
| 是否已经发送通知？ | 本实验验证的是 Prometheus 告警状态，没有部署 Alertmanager 通知链。 |

## 现场分工

默认按任务 1→2→3→4 顺序演示。每位成员先说明接收状态，再执行自己的命令；不用重新搭建环境。

| 成员 | 建议现场内容 | 讲解重点 |
|---|---|---|
| 任务 1 | 启动服务和监控，运行 0/50/100 三档 | 指标从哪里来、CPU 时间与连接占用的区别 |
| 任务 2 | R1 用 100/307/461，R2 用 1939/2133/2424；展示已有 pprof | 连接池饱和、扩池后的 CPU 饱和、采样异常 |
| 任务 3 | each、group、interval 各测 734 TPS 一档 | 相同到达率下的延迟、批量和持久性 |
| 任务 4 | 用前三项 CSV 计算资源账、Little's Law 和预算 | 数字出处、测量口径、结论成立条件 |

现场缩短阶段数量时仍保留每阶段 30 秒，只修改 `-rates` 和实验名。完整证据使用 LAB2 中已经保存的全阶段结果；老师指定重跑哪一档时，按对应 `meta.txt` 参数执行。

## 常见故障

| 现象 | 处理 |
|---|---|
| 新终端找不到 go | `export PATH=/home/ubuntu/apps/go/bin:$PATH` |
| 端口被占用 | 用 `pgrep -a` 或 `ss -ltnp` 核对已有进程，复用或停止后重启；保持默认端口 |
| 抓取目标 unknown/down | 等待首次抓取，随后检查 targets 的 scrapeUrl、lastError 和启动日志 |
| run.sh 报结果目录已存在 | 换实验名，保留原始数据 |
| 服务端数据突降但 CPU 很忙 | 检查抓取成功率，再与 pidstat、mpstat 对照 |
| 发送滞后警告 | 检查 loadgen 的 CPU、lag_p99_ms；该档尾延迟不宜用于精确容量推算 |
| 后续阶段没有执行 | 查看 `-stop-below` 保护是否触发，记录实际完成档位 |
| 从写路径切回读路径，SLI 异常 | 在压测终端 `unset SLO`，恢复 50 ms |
| B 无法访问 A:8080 | 检查 A 的监听地址、私网路由和安全组规则 |
| 新一轮数据与历史不同 | 核对参数、绑核、版本及其他负载，保留结果并解释波动 |

## 结束实验

完成所有测量后关闭本次进程即可，CSV 与原始日志已经保存。

1. 终端 A 按 Ctrl-C，等待 enrolld 显示已停止。
2. 终端 B 按 Ctrl-C 停止 Prometheus，再执行 `kill "$NODE_PID"` 停止 node_exporter。
3. 停止 O2/O3 的采集和轮询，删除 O2 临时安全组规则，关闭 Mac 上的 SSH 隧道。
4. 终端 C 检查 `pgrep -a 'enrolld|prometheus|node_exporter|loadgen'`，应没有本次遗留进程。

若终端 B 已关闭，`NODE_PID` 不会出现在新 Shell 中；先用 `pgrep -a -x node_exporter` 核对进程，再按实际 PID 执行 `kill`。不必删除 TSDB、工具或历史数据来释放端口。

整合人沿用 Mac 推送流程，从主机 A 取回新结果。例如：

```bash
cd ~/Documents/ops-lab2-8
scp -r se-devops:/home/ubuntu/lab2/runs/re-t1-light runs/
```

其他任务替换目录名即可。O2 的客户端结果另从 B 的 `~/lab2-o2/runs/re-o2/` 取回，与 A 的日志放在一起。主机 A 的仓库没有 GitHub 写凭据，不要求各成员在 A 上直接 push。

## 参考定位

| 材料 | 本手册使用的内容 |
|---|---|
| L-06 第 7、12～13 页 | RSS、堆与 GC、Go 的 M:N 调度 |
| L-06 第 16～19 页 | Little's Law、排队位置、连接池上限 |
| L-06 第 22、30～33 页 | 尾延迟、逐项计算上限、扩池后的瓶颈迁移 |
| L-07 第 5～6、9 页 | 资源三问、排队余量、CPU 容量换算 |
| L-07 第 13～16、25～27 页 | IOPS 与吞吐量、fsync、锁持有时间和持久性 |
| L-07 第 18～22 页 | RTT、带宽、PPS、连接、重传和最小实验设计 |
| [pool.go](cmd/enrolld/pool.go) | 等连接与占连接的分开计时 |
| [commit.go](cmd/enrolld/commit.go) | 三种提交模式及 fsync 基线 |
| [procstat.go](cmd/enrolld/procstat.go) | CPU、RSS、Go 调度与 GC 指标 |
| [loadgen](cmd/loadgen/main.go) | 开环到达、阶段归属、分位数与停止条件 |
| [run.sh](scripts/run.sh) | 配置记录、系统工具采集、阶段查询 |
| [rules.yml](deploy/rules.yml) | 燃烧率告警条件 |

课件中的 Tomcat、MySQL 数字是教学设定，本组的 384 req/s、1939 req/s、734 TPS 等数值来自实际测量，答辩时分别说明。分位数和 SLI 的补充解释可参阅 [Prometheus 直方图文档](https://prometheus.io/docs/practices/histograms/)与 [Google SRE](https://sre.google/workbook/implementing-slos/)。
