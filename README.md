# swift-monitor

System metrics sampler + localhost API for Asahi Linux (Apple Silicon).
Built with Swift 6.4 (strict concurrency, `Synchronization.Mutex`) and
shipped as a **fully static musl binary** — no runtime library dependencies.

```
tracefs (root) ──▶ GPUTracker ──┐
/proc/stat, pressure, meminfo,  ├─▶ MetricsStore ──▶ HTTP API 127.0.0.1:6420
statvfs, /proc/net/dev ─────────┘        │
                                         └─▶ /run/swift-monitor/metrics.json (0644)
```

## Metrics

| Metric | Source | Notes |
|--------|--------|-------|
| CPU utilization | `/proc/stat` deltas | `usagePercent = 100 × (Δtotal − Δidle − Δiowait) / Δtotal`, normalized across all cores. `total = user + nice + system + idle + iowait + irq + softirq + steal`; guest counters are not added again. |
| CPU pressure | `/proc/pressure/cpu` | `pressure = some.avg10` (decimal): CPU contention, **not utilization**. |
| GPU | `gpu_scheduler` tracefs | Union of paired run/done intervals, including ongoing jobs, clipped to each sample window. **Root required**; uses an owned tracefs instance with `trace_clock=mono` (`CLOCK_MONOTONIC`). Global trace controls/pipe are untouched. |
| Memory | `/proc/meminfo` | `(MemTotal − MemAvailable) / MemTotal` |
| Disk | `statvfs("/")` | used percent of the root filesystem |
| Network | `/proc/net/dev` deltas | Sum of per-interface deltas, excluding `lo`, bytes/sec. New/reset counters establish a baseline; removed interfaces cannot cancel other traffic. |

## API

- `GET /metrics` — JSON:
  `{"sampledAt":1800000000.125,"intervalSeconds":2.0,"cpu":{"usagePercent":53,"pressure":5.25},"gpu":{"busy":0,"available":true},"memory":{"usedPercent":27},"disk":{"path":"/","usedPercent":48},"network":{"rxBytesPerSec":110468,"txBytesPerSec":84363}}`
- `GET /metrics.txt` — `cpu 53% gpu 0% mem 27% disk 48% net 9182B/s↓ 10564B/s↑`
- `GET /healthz` — liveness

The server binds to `127.0.0.1` only. Every 2s the current snapshot is also
published via same-directory `mkstemp → write → close → rename` to
`/run/swift-monitor/metrics.json` (mode 0644). The systemd unit owns/removes the
runtime directory. File publication failure does not block HTTP snapshots.

```swift
// Additive JSON fields; existing numeric metrics are unchanged.
let sampledAt: Double?      // Unix seconds; nil (JSON null) until first full sample
let intervalSeconds: Double
let gpuAvailable: Bool      // JSON gpu.available; false => ignore gpu.busy

// Consumer freshness policy (wall clock must be synchronized):
let fresh = sampledAt.map { now - $0 >= 0 && now - $0 <= 3 * intervalSeconds } ?? false
```

`/healthz` reports liveness, not freshness. `/metrics.txt` renders unavailable
GPU data as `gpu n/a` instead of `gpu 0%`. All snapshots remain immutable between
sampling ticks; file consumers must check `sampledAt`, including after crashes.

**Path migration:** replace `/run/swift-monitor.json` with
`/run/swift-monitor/metrics.json` in file consumers. The old file is not updated.

```text
ServerBootstrap → HTTP decoder → NIOAsyncChannel → per-connection child task
                  16 KiB wire limit + 5s absolute connection deadline
tracefs/instances/swift-monitor-<UUID>/
    mkdir → tracing_off → mono clock → enable events → open pipe → tracing_on
    exit/setup failure → close pipe → tracing_off → disable events → rmdir
SIGINT/SIGTERM → cancel sampler/server/trace reader → join/cleanup → shutdown event loops
```

## Usage

```
swift-monitor [interval_sec=2 (0.1...86400)] [port=6420 (1...65535)]
```

Run as root for GPU stats; everything else works unprivileged. If tracefs
or tracefs instances are unavailable, the daemon logs a warning and continues
with `gpu.available = false`. Reader failure also marks GPU data unavailable.
There is no global tracing fallback. SIGKILL/power loss cannot run cleanup;
an orphan `instances/swift-monitor-<UUID>` may need administrator removal.
The first sample is published after one interval; before that `sampledAt = null`.
Invalid arguments exit with status 2; bind failures exit with status 1.

## Build

```bash
# glibc build (dynamic)
swift build -c release

# fully static musl build (recommended)
swift sdk install <path-to>/swift-6.4.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
swift build -c release \
  --swift-sdk swift-6.4.1-RELEASE_static-linux-0.1.0 \
  --triple aarch64-swift-linux-musl
strip .build/out/Products/Release-staticlinux-aarch64/swift-monitor
```

The static SDK tarball is linked from
[Static Linux SDK: Getting Started](https://www.swift.org/documentation/articles/static-linux-getting-started.html).

## Install (systemd, system service — root, enables GPU)

```bash
sudo systemctl stop swift-monitor 2>/dev/null   # if already running
sudo cp .build/out/Products/Release-staticlinux-aarch64/swift-monitor /usr/local/bin/
sudo cp swift-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now swift-monitor
```

The sandbox keeps host `/proc` and networking visible, but drops all Linux
capabilities, blocks privilege escalation/mounts, hides home directories/devices,
and makes the filesystem read-only except the runtime directory, private temp
storage, and `/sys/kernel/tracing/instances`. Only loopback IP traffic is allowed.
GPU support still requires root ownership permissions and a kernel that permits
tracefs access without extra capabilities (lockdown policies may deny it).

For a manual root launch, create `/run/swift-monitor` (0755) first if file snapshots
are needed. Unprivileged runs still serve HTTP without file publication.

Overwriting a running executable in place fails with `Text file busy` — stop,
copy, then start. The pre-migration `/run/swift-monitor.json` can be deleted once
all consumers have migrated.

## Consumer

The omarchy bar widget (`~/.config/omarchy/bar/modules/system-stats.sh`)
reads `cpu.usagePercent` from `/metrics`; falls back to `/proc/stat` deltas
when the daemon is down or an older daemon exposes only `cpu.pressure`.
It renders the stats in the bar's center section as a custom QML module
(`~/.config/omarchy/bar/modules/system-stats.qml`) with per-stat colors and
Nerd Font icons:

```
󰻠 3% │ 󰢮 7% │ 󰍛 28% │ 󰋊 49% │ 󰛳 86KiB↓ 915KiB↑
```

## Layout

```
Sources/swift-monitor/
├── Monitor.swift     — async entry, lifecycle, sampler loop, atomic publisher
├── GPUTracker.swift  — GPU busy% from DRM scheduler tracefs (root)
├── Samplers.swift    — CPU utilization + PSI, memory, disk, network rates
└── HttpServer.swift  — SwiftNIO HTTP/1.1 decoder + async connections
```

## Validation

```bash
swift test
swift build -c release
swift build -c release \
  --swift-sdk swift-6.4.1-RELEASE_static-linux-0.1.0 \
  --triple aarch64-swift-linux-musl
swift Scripts/test-daemon.swift .build/out/Products/Release-staticlinux-aarch64/swift-monitor
```

`SwiftMonitorTests`: CPU/network deltas and resets, interface churn, PSI precision,
GPU interval unions, instance isolation/partial setup/EOF/cancellation cleanup,
startup/fresh snapshots, publication/read races, HTTP fragmentation/isolation/limits.
The installed static SDK does not ship `Testing`; run the Swift suite on glibc.
`Scripts/test-daemon.swift` uses host Swift + Foundation (no `Testing`) to launch
and exercise either binary unprivileged on a temporary port. GPU tracefs writes and
real GPU workloads still require privileged validation. Trace data arriving after
a published window is clipped at its boundary; lost-event notifications reset
tracked jobs rather than leaving false permanent occupancy.

```text
trace_clock=mono → per-CPU buffers → trace_pipe → GPUTracker
    done(id) → run(id)          → completed interval, not a stranded job
    unmatched done(id)          → retained through the next sample
    unmatched run(id), too old  → ignored after completion history expires
    tracked run(id) → done(id)  → paired regardless of job duration
```

`mono` uses `ktime_get_mono_fast_ns`, which can move backwards across a
[timekeeper update](https://github.com/torvalds/linux/blob/master/kernel/time/timekeeping.c).
Timestamp-merged delivery therefore need not put `run` before `done`.
Completion history is bounded by sampling windows; existing running jobs are
not timed out.

### Privileged release validation (Asahi host)

```text
systemd-analyze verify swift-monitor.service
systemctl start swift-monitor
curl http://127.0.0.1:6420/metrics
    sampledAt advances; gpu.available == true
GPU workload → gpu.busy increases → idle → gpu.busy decreases
systemctl stop swift-monitor
    /run/swift-monitor removed
    owned tracefs instance removed
    global trace_clock / events / tracing_on unchanged
```

Run the same lifecycle while another tracefs consumer is active. The fixture
suite cannot validate kernel tracefs permissions, systemd mount namespaces, or
real GPU event delivery; these checks require the installed root service.
