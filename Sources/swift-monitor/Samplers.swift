// Unprivileged system samplers: CPU utilization/pressure, memory, disk, network.

import Foundation

struct SystemSample: Sendable {
    var sampledAt: Double? = nil // Unix seconds; nil until the first complete sample
    var intervalSeconds = 2.0
    var cpuUsagePercent = 0
    var cpuPressure = 0.0 // PSI some.avg10: contention, not utilization
    var gpuBusy = 0
    var gpuAvailable = false
    var memoryPercent = 0
    var diskPercent = 0
    var diskPath = "/"
    var rxBytesPerSec = 0
    var txBytesPerSec = 0

    func json() -> String {
        """
        {"sampledAt":\(sampledAt.map { String($0) } ?? "null"),"intervalSeconds":\(intervalSeconds),\
        "cpu":{"usagePercent":\(cpuUsagePercent),"pressure":\(cpuPressure)},"gpu":{"busy":\(gpuBusy),"available":\(gpuAvailable)},\
        "memory":{"usedPercent":\(memoryPercent)},\
        "disk":{"path":"\(diskPath)","usedPercent":\(diskPercent)},\
        "network":{"rxBytesPerSec":\(rxBytesPerSec),"txBytesPerSec":\(txBytesPerSec)}}
        """
    }

    func plain() -> String {
        "cpu \(cpuUsagePercent)% gpu \(gpuAvailable ? "\(gpuBusy)%" : "n/a") mem \(memoryPercent)% disk \(diskPercent)% net \(rxBytesPerSec)B/s↓ \(txBytesPerSec)B/s↑"
    }
}

/// /proc/stat → deltas of user/nice/system/idle/iowait/irq/softirq/steal.
/// guest/guest_nice are already included in user/nice; don't count them twice.
struct CPUUsageSampler {
    private var previous: [UInt64]?

    mutating func sample(text: String? = try? String(contentsOfFile: "/proc/stat", encoding: .utf8)) -> Int {
        guard let line = text?.split(separator: "\n").first else { previous = nil; return 0 }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.first == "cpu", fields.count >= 9 else { previous = nil; return 0 }
        let ticks = fields.dropFirst().prefix(8).compactMap { UInt64($0) }
        guard ticks.count == 8 else { previous = nil; return 0 }
        defer { previous = ticks }
        guard let previous, zip(ticks, previous).allSatisfy({ $0 >= $1 }) else { return 0 }
        let delta = zip(ticks, previous).map { Double($0 - $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return 0 }
        return Int(((total - delta[3] - delta[4]) / total * 100).rounded())
    }
}

enum Samplers {
    static func cpuPressure(text: String? = try? String(contentsOfFile: "/proc/pressure/cpu", encoding: .utf8)) -> Double {
        guard let text else { return 0 }
        for line in text.split(separator: "\n") where line.hasPrefix("some ") {
            for field in line.split(separator: " ") where field.hasPrefix("avg10=") {
                guard let value = Double(field.dropFirst(6)), value.isFinite else { return 0 }
                return min(100, max(0, value))
            }
        }
        return 0
    }

    static func memoryPercent() -> Int {
        guard let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else { return 0 }
        var total = 0.0
        var available = 0.0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 2, let kb = Double(fields[1]) else { continue }
            if line.hasPrefix("MemTotal:") { total = kb }
            if line.hasPrefix("MemAvailable:") { available = kb }
        }
        guard total > 0 else { return 0 }
        return Int(((total - available) / total * 100).rounded())
    }

    static func diskPercent(path: String) -> Int {
        var stat = statvfs()
        guard statvfs(path, &stat) == 0 else { return 0 }
        return diskPercent(blocks: UInt64(stat.f_blocks), available: UInt64(stat.f_bavail))
    }

    static func diskPercent(blocks: UInt64, available: UInt64) -> Int {
        // The block size cancels out. Reject invalid/sentinel counts before subtracting.
        guard blocks > 0, available <= blocks else { return 0 }
        return Int((Double(blocks - available) / Double(blocks) * 100).rounded())
    }
}

/// Per-interface deltas: new/reset counters establish a baseline, removed ones
/// cannot cancel traffic on the remaining interfaces. Each sampler owns its state.
struct NetworkSampler {
    private struct Counters {
        let rx: UInt64
        let tx: UInt64
    }
    private var previous: (time: Double, interfaces: [String: Counters])?

    mutating func sample(
        text: String? = try? String(contentsOfFile: "/proc/net/dev", encoding: .utf8),
        now: Double = monotonicSeconds()
    ) -> (rx: Int, tx: Int) {
        guard let text, now.isFinite else { previous = nil; return (0, 0) }
        var interfaces: [String: Counters] = [:]
        for line in text.split(separator: "\n").dropFirst(2) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "lo" else { continue }
            let fields = parts[1].split(whereSeparator: \.isWhitespace)
            guard fields.count > 8, let rx = UInt64(fields[0]), let tx = UInt64(fields[8]) else { continue }
            interfaces[name] = Counters(rx: rx, tx: tx)
        }
        defer { previous = (now, interfaces) }
        guard let previous, now > previous.time else { return (0, 0) }
        var rx = 0.0
        var tx = 0.0
        for (name, current) in interfaces {
            guard let old = previous.interfaces[name] else { continue }
            if current.rx >= old.rx { rx += Double(current.rx - old.rx) }
            if current.tx >= old.tx { tx += Double(current.tx - old.tx) }
        }
        func rate(_ bytes: Double) -> Int {
            let value = bytes / (now - previous.time)
            return value >= Double(Int.max) ? Int.max : Int(value)
        }
        return (rate(rx), rate(tx))
    }
}

func monotonicSeconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
}
