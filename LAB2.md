# 实验 2 记录：第 8 组

评分时依据本文件和 `runs/` 中的原始数据核对。本文件中的每一个数值，都须能在某个 `runs/<名字>/` 的文件中找到：表格用 `scripts/table.sh` 生成后粘贴，其他数值注明出处（例如“`runs/r1-pool4/red.csv` 第 6 阶段”）。不要只贴截图。将 `<填写>` 替换为本组的内容。

第 4.1、4.4、5.1、5.3 节的预测须在对应的测量之前写好，写好后不要修改。预测错误不扣分，与实测不一致之处在分析中讨论。

## 1. 基本信息

| 项 | 内容 |
|---|---|
| 小组 | 第 8 组 |
| 仓库地址 | <https://github.com/aCannedFish/ops-lab2-8> |
| 主机 | 华为云 ECS 通用型 x1e（`x1e.2u.4g`），华东-上海一 `cn-east-3a`，2 vCPU / 4 GiB |
| CPU | `General Purpose Processor`（KVM 虚拟化，AMD 家族 25）；2 个 vCPU；来宾机的 `lscpu -e` 中 CPU 0 与 CPU 1 同属 CORE 0，呈现为同核双线程拓扑，但不能据此确认宿主机的实际物理核分配（原文见 `runs/t0-baseline/host.txt`） |
| 内存 | 3531 MiB（`free -m` 的 total，见 `runs/t0-baseline/host.txt`） |
| 数据目录所在的盘 | `findmnt -T data` 给出 `/dev/vda1`、`ext4`，即挂载在 `/` 的 40 GB 系统云盘（`runs/t0-baseline/host.txt`）；ROTA 为 1，但虚拟块设备的标志和 fsync 延迟都不足以判断后端介质，SSD/HDD 类型未确认 |
| 操作系统与内核 | Ubuntu 24.04.5 LTS；`6.8.0-146-generic` |
| Go、Prometheus、node_exporter | `go version go1.26.9 linux/amd64`；`prometheus, version 3.13.4 (branch: HEAD, revision: 007a9e9ba628f815ce83e1ba9f29b97981996c3c)`；`node_exporter, version 1.12.1 (branch: HEAD, revision: 6044da783597cc3b57aef7580ddcdcff58a4ee99)`（版本原文见 `runs/t1-light/environment.txt`） |
| 分核 | enrolld：1；loadgen、Prometheus、node_exporter：0（已按逻辑核分开，见 `runs/t1-light/meta.txt`、`environment.txt`；虚拟拓扑显示同核双线程，不能假设两者拥有独立的物理核资源） |

## 2. 任务 0：基线

`bin/enrolld -bench-fsync 2000` 连续运行三次的输出（原文见 `runs/t0-baseline/bench-fsync-2000.txt`）：

```text
fsync 次数 2000，总耗时 2.63 s，数据目录 data
fsync 耗时（毫秒）：mean 1.304  p50 1.145  p90 1.702  p99 3.497  max 12.295
按平均值推算，一个写者串行 fsync 每秒最多约 767 次（= 1000 / 1.304）
fsync 次数 2000，总耗时 2.78 s，数据目录 data
fsync 耗时（毫秒）：mean 1.379  p50 1.156  p90 1.830  p99 3.995  max 19.822
按平均值推算，一个写者串行 fsync 每秒最多约 725 次（= 1000 / 1.379）
fsync 次数 2000，总耗时 2.84 s，数据目录 data
fsync 耗时（毫秒）：mean 1.406  p50 1.172  p90 1.878  p99 4.547  max 10.569
按平均值推算，一个写者串行 fsync 每秒最多约 711 次（= 1000 / 1.406）
```

按平均值计算，单个写者串行 fsync 每秒最多约 734 次。三次之间相差多少？三次的平均耗时分别为 1.304、1.379、1.406 ms，其平均值为 1.363 ms，1000 ÷ 1.363 ≈ 734；换算后最高 767 次/秒、最低 711 次/秒，相差 56 次/秒，约 8%。差异主要来自尾部：p99 从 3.497 ms 升到 4.547 ms，max 在 10.569–19.822 ms 之间波动，而中位数几乎不动（1.145 → 1.172 ms），说明平均值被少量慢 fsync 抬高，本次同主机三次重复测量的极差约为均值的 8%，不能据此保证后续测量的波动范围。

空载和运行 fsync 测试时各工具的读数（各观察 5 秒以上，取典型值；原文见 `runs/t0-baseline/vmstat-idle.log`、`iostat-idle.log`、`vmstat-fsync.log`、`iostat-fsync.log`，空载观察 11 秒，负载观察覆盖 `bin/enrolld -bench-fsync 5000` 的 6.97 s）：

| 工具与列 | 空载 | 运行 `-bench-fsync` 时 | 该列的含义 |
|---|---|---|---|
| `vmstat -w 1`：r、b | 0、0 | 0、1 | r：可运行的进程数（含正在运行和等 CPU）；b：处于不可中断睡眠（D 状态，多在等 I/O）的进程数 |
| `vmstat -w 1`：us、sy、id、wa、st | 1、1、99、0、0 | 1、5、49、45、0 | us/sy：用户态与内核态 CPU 占比；id：空闲；wa：空闲但期间有未完成的 I/O；st：被 hypervisor 抢占、未分给本机的时间 |
| `iostat -dx 1 vda`：w/s、wkB/s | 0（偶有 1–4）、0–116 | 2200、12000 | 每秒完成的写请求数与写入量（KiB/s） |
| `iostat -dx 1 vda`：w_await、f/s、f_await | 无 I/O（偶发时为 0.5–1.0）、0–2、0.00 | 0.45、1450、0.04 | 写请求的平均响应时间（ms）；每秒 flush 次数及其平均耗时；fsync 与设备 flush 不一定一一对应，本次约为 1:2 |
| `iostat -dx 1 vda`：aqu-sz、%util | 0.00、0–0.2 | 1.0、94 | aqu-sz：平均未完成 I/O 请求数（含排队和正在处理）；%util：设备处于忙碌状态的时间占比 |

运行 fsync 测试时，CPU 是否繁忙？哪几列表明存在等待？CPU 不繁忙：us 与 sy 典型合计约 6%（两核平均，折合约 0.12 个逻辑核），id 仍约 49%。直接表明等待的是 `vmstat` 的 b 和 wa：负载期间 b 多数为 1，表示有进程处于不可中断睡眠；wa 约为 43–46%，表示约有这些比例的 CPU 时间记为 I/O 等待。`iostat` 同期 %util 为 91.5–95.5%，aqu-sz 为 0.99–1.27，说明设备持续有未完成的 I/O，但 aqu-sz 包含正在处理的请求，不能将其全部视为排队；仅凭高 %util 也不能断言云盘的最大吞吐已耗尽。w_await 为 0.41–0.50 ms，f_await 为 0.03–0.06 ms，均小于应用测得的 fsync 平均 1.381 ms，因为后者包含文件系统处理及一组 I/O 的等待，并非单个设备请求的耗时。`vmstat-fsync.log` 的 bo 约为 10904–13120 KiB/s，与 `iostat-fsync.log` 的 wkB/s 约 10936–13116 相符。该次 5000 次测试总耗时 6.97 s（`bench-fsync-5000.txt`），含循环开销的整体速率为 5000 ÷ 6.97 ≈ 717 次/秒；`iostat-fsync.log` 中间七个负载样本的 f/s 为 1335–1526，w/s 为 2002–2433，粗略对应每次 fsync 约两次 flush、三次写。该比例仅适用于本次 ext4/云盘组合与近似对齐的采样窗口，并非 fsync 的固定规则。

## 3. 任务 1：指标流水线

两个抓取目标的状态（`curl -s 127.0.0.1:9090/api/v1/targets` 中两处 `"health"` 的值）：`enrolld`（`127.0.0.1:8080`）为 `"up"`，`node`（`127.0.0.1:9100`）为 `"up"`，两者的 `lastError` 均为空；原始响应保存在 `runs/t1-light/targets.json`。

本组编写的四条查询（与 `deploy/queries-red.txt` 一致，实验时的副本见 `runs/t1-light/queries-red.txt`）：

```text
server_rps          sum(rate(http_requests_total{route="${route}"}[${window}]))
server_error_rate   (sum(rate(http_requests_total{route="${route}",code=~"5.."}[${window}])) or vector(0)) / sum(rate(http_requests_total{route="${route}"}[${window}]))
server_p99_ms       1000 * histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{route="${route}"}[${window}])))
server_slo_good     (sum(rate(http_request_duration_seconds_bucket{route="${route}",code="200",le="${slo}"}[${window}])) or vector(0)) / sum(rate(http_requests_total{route="${route}"}[${window}]))
```

分母包含该接口的全部状态码；错误率分子只计 5xx，没有对应序列时用 `or vector(0)` 补零。p99 先按 `le` 合并所有状态码的桶，再估计分位数并换算为毫秒。SLI 分子只计 `code="200"` 且耗时不超过 `${slo}` 的累计桶，本次 `${slo}=0.05`。空载时没有请求，比例和每请求开销没有定义，不将它们强行补为零。

实验使用默认参数 `-work 200000 -pool 4 -db-ms 10 -sync each`，`GOMAXPROCS=1`；enrolld 绑核 1，loadgen、Prometheus、node_exporter 绑核 0。Prometheus 仅监听 `127.0.0.1:9090`，TSDB 位于 `/dev/shm/lab2-prom`；服务配置、版本与绑核证据见 `runs/t1-light/meta.txt`、`enrolld.log`、`environment.txt`。执行 `GEN_CPUS=0 scripts/run.sh t1-light -url http://127.0.0.1:8080/api/courses/1 -rates 0,50,100`，每阶段 30 秒；`make build test` 全部通过，输出见 `runs/t1-light/build-test.txt`。

`runs/t1-light` 的数据（`scripts/table.sh runs/t1-light ok_rps mean_ms p99_ms server_rps server_mean_ms server_p99_ms cpu_ms_per_req db_query_mean_ms`）：

| step | target_rps | ok_rps | mean_ms | p99_ms | server_rps | server_mean_ms | server_p99_ms | cpu_ms_per_req | db_query_mean_ms |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 0 | 0.0 | - | - | 0 | NaN | NaN | +Inf | NaN |
| 2 | 50 | 50.5 | 11.44 | 12.63 | 51.6667 | 10.7216 | 19.9 | 0.540031 | 10.3144 |
| 3 | 100 | 97.8 | 11.60 | 14.05 | 95.4167 | 10.867 | 19.9 | 0.539766 | 10.4262 |
| all | - | 74.2 | 11.54 | 13.31 | - | - | - | - | - |

从这次实验读出：每次查询实际占用连接 **10.4262 ms**（`runs/t1-light/red.csv` 第 3 阶段的 `db_query_mean_ms`；第 2 阶段为 10.3144 ms）；每个请求消耗的 CPU **0.539766 ms**（同文件第 3 阶段的 `cpu_ms_per_req`，取目标 100 请求/秒阶段，约 0.540 ms）。查询占用时间略大于配置的 10 ms，是因为还包含睡眠结束后重新调度及连接释放等开销，而不是只有设定的休眠时长；CPU 指标包含整个 enrolld 进程的开销，并未扣除空载成本。

第 2、3 阶段的 `server_error_rate` 均为 0，`server_slo_good` 均为 1（`runs/t1-light/red.csv`），客户端也没有 HTTP 错误、超时、网络错误或丢弃（`steps.csv`）。表格保留工具原始输出：空载阶段以零请求为分母，产生 `NaN` 或 `+Inf`，不能解读为无限 CPU 开销；`all` 行仅汇总客户端有负载阶段，没有对应的服务端查询。客户端按完整阶段统计，Prometheus 查询去掉各阶段开头 5 秒，且 `rate()` 有抓取与外推误差，所以两侧 RPS 不必完全相等。服务端 p99 来自直方图桶内插值，而客户端使用实际样本，二者不应当作同一种精度的测量。

## 4. 任务 2：读路径

### 4.1 预测（R1 之前写）

| 资源 | 容量 | 每个请求占用（数据来源） | 推算的上限（请求/秒） |
|---|---|---|---|
| 连接池 | <`-pool`> 个连接 | <填写> ms | <填写> |
| CPU | enrolld 的 <填写> 个核 | <填写> ms | <填写> |

先达到上限的是：<填写>。预计从多少请求/秒起，客户端 p99 超过 50 ms：<填写>，理由：<填写>

R1 的到达率（`scripts/rates.sh <较小的上限>` 的输出）：<填写>

### 4.2 R1：`-pool 4`

`scripts/table.sh runs/r1-<…> ok_rps error_rate p99_ms server_p99_ms server_mean_ms inflight_avg cpu_ms_per_req pool_in_use_avg pool_wait_p99_ms sched_wait_p99_ms svc_cpu_busy procs_running_avg`：

<粘贴表格>

最大吞吐量 <填写> 请求/秒，出现在第 <填写> 阶段；客户端 p99 首次超过 50 ms 是在第 <填写> 阶段（<填写> 请求/秒）。

### 4.3 CPU 消耗在何处

在约 0.8 倍上限的负载下采集 20 秒 CPU 剖析，`go tool pprof -top` 的前 10 行（同时保存在 `runs/<填写>/pprof-top.txt`）：

```text
<粘贴>
```

`main.spin` 占 <填写>%；按本次的吞吐量和 enrolld 消耗的 CPU 计算，每个请求 <填写> ms，其中 spin 约 <填写> ms，其余 <填写> ms 消耗在：<填写>

### 4.4 R2：调大连接池（预测在 R2 之前写）

| 项 | 值与算法 |
|---|---|
| 每个请求占用的 CPU（取 R1 哪一阶段的 `cpu_ms_per_req`，选取理由） | <填写> |
| 推算的 CPU 上限 C | <填写> |
| R2 的池大小 P2 = ceil(2 × C × 每次查询的秒数) | <填写> |
| R2 的到达率（`scripts/rates.sh C 0.3 0.6 0.8 0.9 1.0 1.1 1.25 1.5`） | <填写> |
| 预测：R2 中先达到上限的是 | <填写> |

`scripts/table.sh runs/r2-<…> ok_rps error_rate p99_ms server_p99_ms inflight_avg cpu_cores cpu_ms_per_req cpu_wait_threads sched_wait_p99_ms pool_in_use_avg svc_cpu_busy procs_running_avg cpu_psi_some`：

<粘贴表格>

最大吞吐量 <填写> 请求/秒；与预测的 C 相差：<填写>

## 5. 任务 3：写路径

### 5.1 预测：`-sync each`（W1 之前写）

| 项 | 值与算法 |
|---|---|
| fsync 平均耗时（任务 0） | <填写> ms |
| 推算的最大 TPS | <填写> |
| 达到上限时 enrolld 大约使用几个核（写路径没有 spin，按 4.3 节拆分出的“spin 以外的开销”估计每个写请求的 CPU） | <填写> |
| W1 的到达率（`scripts/rates.sh <最大 TPS> 0.2 0.4 0.6 0.8 0.9 1.0 1.1 1.2`） | <填写> |

### 5.2 W1：`-sync each`

`scripts/table.sh runs/w1-<…> ok_rps error_rate p99_ms server_p99_ms cpu_cores fsync_per_s fsync_mean_ms batch_mean svc_cpu_busy cpu_iowait disk_w_per_s disk_w_await_ms disk_f_per_s disk_f_await_ms disk_aqu_sz disk_util`：

<粘贴表格>

### 5.3 预测：`-sync group`（W2 之前写）

在 W1 达到上限时的到达率下，改为组提交后：吞吐量 <填写>；平均每次 fsync 处理 <填写> 条记录；客户端 p99 约 <填写>。理由：<填写>

W2 的到达率：<填写>

### 5.4 W2：`-sync group`

（列与 5.2 相同）

<粘贴表格>

### 5.5 W3：`-sync interval`

（列与 5.2 相同）

<粘贴表格>

## 6. 分析问题

每题先列出所用数据（引用上面的表或 `runs/` 中的文件），再写结论，并说明结论的成立条件。每题 300～600 字。

**问题 1：上限由什么决定。** 按 L-07 第 25 页资源账的格式，为 enrolld 的读路径编制一份资源账：资源、每个请求占用（实测）、容量、推算的上限、实测的最大吞吐量、饱和观测项。预测与实测相差多少，差异来自何处？`cpu_ms_per_req` 随负载如何变化，原因是什么？这对“在低负载下测量每请求开销，再推算上限”的做法意味着什么？`db_query_mean_ms` 为什么大于 `-db-ms`？以“p99 ≤ 50 ms”为目标，R1 能承受的最大阶段相当于上限的多少比例？与 L-07 第 6 页“容量 = 上限 × 0.7”比较，为什么尚未达到上限延迟就已上升？R2 调大连接池后，瓶颈转移到了哪个资源？

<填写>

**问题 2：利用率不等于饱和。** R1 达到上限时，enrolld 所在核的 CPU 利用率是多少？哪个数值最先表明资源已经饱和？R2 中 CPU 利用率接近 100% 时，内核层的 `procs_running_avg`、`cpu_psi_some`、`cpu_wait_threads` 和 Go 运行时层的 `sched_wait_p99_ms` 分别如何变化？为什么内核层几乎观察不到排队，排队发生在哪里？这与 L-06 第 16、17 页 Tomcat 的线程池有何相同之处？最后用 Little's Law 核对：从 R1 选取三个阶段，用 `server_rps × server_mean_ms` 计算在途请求数，并与 `inflight_avg` 比较；W 为什么必须用平均值而不能用 p99？哪个阶段不一致，原因是什么？

<填写>

**问题 3：持久性以延迟为代价。** W1 实测的最大 TPS 与 1000 ÷ fsync 平均耗时相比如何？W1 达到上限时 CPU、内存、磁盘的指标各是多少，哪几列表明磁盘饱和？应用测得的 `fsync_mean_ms` 与 `disk_w_await_ms`、`disk_f_await_ms` 为什么不同？一次 fsync 大约对应几次写和几次 flush？W1 与 W2 在 `disk_util` 相近时吞吐量相差多少，`%util` 接近 100% 能否说明磁盘已经饱和？组提交的 `batch_mean` 如何随负载变化，低负载时是否有收益，本组的预测是否正确？W3 快了多少，代价是什么？选课记录应采用哪一种方式，在什么条件下 interval 可以接受？

<填写>

**问题 4：延迟数值的测量位置与方法。** 同一阶段中，客户端与服务端的平均值、p99 各相差多少？列出只计入客户端的时间组成。找出一个服务端 p99 大于客户端 p99 的阶段，并解释原因（L-08 第 10 页）。比较服务端的 `server_slo_good` 与客户端的 `slo_good`；若存在过载阶段，二者为何相差很大？SLI 应在何处测量（L-08 第 19 页）？用 R1 的 `steps.csv`，将各阶段的 p99 求平均，与 `all` 行的 p99 比较，说明百分位数为什么不能平均，以及正确的合并方法。最后计算错误预算：SLO 为“30 天内 99% 的读请求在 50 ms 内成功返回”，若 R1 中第一个不达标阶段的负载持续下去，燃烧率是多少，30 天的预算多久耗尽（L-08 第 21 页）？

<填写>

## 7. 选做记录

| 选做 | 完成情况与证据 |
|---|---|
| O1 内存与 GC | <未做 / 预测、`runs/` 目录、结论> |
| O2 网络 | <未做 / 两台主机的规格与拓扑、`runs/` 或日志、结论> |
| O3 告警与看板 | <未做 / 规则文件、触发记录、看板说明> |
| O4 迁移到小组项目 | <未做 / 仓库链接、测了哪个资源、结论> |

## 8. 成员分工

每位成员一行，只填写 GitHub 用户名，无需填写姓名；行数应与小组人数一致。

| GitHub 用户名 | 负责的部分 |
|---|---|
| <用户名> | <填写> |
