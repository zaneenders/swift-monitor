// GPU wall-time occupancy from paired DRM scheduler tracefs events.

import Foundation
import Synchronization

final class GPUTracker: Sendable {
    let tracingDir: String
    private let traceFS: TraceInstanceFileSystem

    struct State {
        var jobs: [String: Double] = [:]
        var completed: [(start: Double, end: Double)] = []
        var lastSampleTime: Double
        var available = false
    }

    let state: Mutex<State>
    private let stopped = Mutex(false)

    init(tracingDir: String, now: Double = monotonicSeconds(), traceFS: TraceInstanceFileSystem = .init()) {
        self.traceFS = traceFS
        self.tracingDir = tracingDir
        self.state = Mutex(State(lastSampleTime: now))
    }

    /// A dedicated I/O thread; nonblocking reads + bounded poll make cancellation joinable.
    func readEvents() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let thread = Thread {
                    self.readLoop()
                    continuation.resume()
                }
                thread.name = "trace-reader"
                thread.start()
            }
        } onCancel: {
            self.stopped.withLock { $0 = true }
        }
    }

    private func readLoop() {
        guard !stopped.withLock({ $0 }) else { return }
        defer {
            state.withLock {
                $0.available = false
                $0.jobs.removeAll()
                $0.completed.removeAll()
            }
        }
        do {
            try withGPUTrace(tracingDir: tracingDir, fileSystem: traceFS) { fd in
                state.withLock {
                    $0.lastSampleTime = monotonicSeconds()
                    $0.available = true
                }
                consume(fd: fd)
                if !stopped.withLock({ $0 }) {
                    logError("GPU trace reader stopped (GPU stats unavailable)")
                }
            }
        } catch {
            logError("GPU tracing unavailable: \(error)")
        }
    }

    private func consume(fd: Int32) {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while !stopped.withLock({ $0 }) {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { break }
            let count = read(fd, &bytes, bytes.count)
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            buffer.append(contentsOf: bytes.prefix(count))
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                ingest(line: line)
            }
            if buffer.count > 1 << 20 { buffer.removeAll() }
        }
    }

    func ingest(line: String) {
        if line.contains("LOST"), line.contains("EVENTS") {
            state.withLock { $0.jobs.removeAll(); $0.completed.removeAll() }
            return
        }
        guard let colon = line.range(of: ": drm_sched_job_") else { return }
        let prefix = line[..<colon.lowerBound]
        guard let token = prefix.split(whereSeparator: \.isWhitespace).last,
              let timestamp = Double(token), timestamp.isFinite, timestamp >= 0 else { return }
        let suffix = line[colon.upperBound...]
        guard let separator = suffix.firstIndex(of: ":") else { return }
        let event = suffix[..<separator]
        // Modern kernels pair by fence=context:seqno; older kernels expose a job pointer.
        let fields = suffix[suffix.index(after: separator)...].split(whereSeparator: \.isWhitespace)
        guard let field = fields.first(where: { $0.hasPrefix("fence=") })
                ?? fields.first(where: { $0.hasPrefix("job=") }) else { return }
        let job = String(field.trimmingCharacters(in: CharacterSet(charactersIn: ",")))
        state.withLock { s in
            // Late trace data cannot revise an already published sampling window.
            let time = max(timestamp, s.lastSampleTime)
            if event == "run" {
                if s.jobs[job] == nil { s.jobs[job] = time }
            } else if event == "done", let start = s.jobs.removeValue(forKey: job) {
                s.completed.append((start, max(start, time)))
            }
        }
    }

    /// Union of completed/ongoing busy intervals, clipped to [lastSample, now].
    func sample(now: Double = monotonicSeconds()) -> (busy: Int, available: Bool) {
        state.withLock { s in
            guard now > s.lastSampleTime else { return (0, s.available) }
            let intervals = (s.completed + s.jobs.values.map { (start: $0, end: now) })
                .map { (start: max($0.start, s.lastSampleTime), end: min($0.end, now)) }
                .filter { $0.end > $0.start }
                .sorted { $0.start < $1.start }
            var busy = 0.0
            var end = s.lastSampleTime
            for interval in intervals {
                busy += max(0, interval.end - max(end, interval.start))
                end = max(end, interval.end)
            }
            let percent = Int((min(1, max(0, busy / (now - s.lastSampleTime))) * 100).rounded())
            s.completed.removeAll { $0.end <= now }
            s.lastSampleTime = now
            return (percent, s.available)
        }
    }
}

/// mkdir on tracefs populates the instance's control files. Only this instance is
/// configured/consumed; every exit path closes the reader and removes the instance.
/// Directory operations are injectable so tests can populate a regular-files fixture.
struct TraceInstanceFileSystem: Sendable {
    var create: @Sendable (String) throws -> Void = { path in
        guard mkdir(path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    var remove: @Sendable (String) throws -> Void = { path in
        guard rmdir(path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

func withGPUTrace(
    tracingDir: String, fileSystem: TraceInstanceFileSystem = .init(), body: (Int32) throws -> Void
) throws {
    let path = "\(tracingDir)/instances/swift-monitor-\(UUID().uuidString)"
    try fileSystem.create(path)
    defer {
        try? writeTraceSetting("\(path)/tracing_on", "0")
        for event in ["run", "done"] {
            try? writeTraceSetting("\(path)/events/gpu_scheduler/drm_sched_job_\(event)/enable", "0")
        }
        do { try fileSystem.remove(path) }
        catch { logError("removing GPU trace instance \(path) failed: \(error)") }
    }
    try writeTraceSetting("\(path)/tracing_on", "0")
    // This clock shares CLOCK_MONOTONIC's epoch, but does not change the global clock.
    try writeTraceSetting("\(path)/trace_clock", "mono")
    for event in ["run", "done"] {
        try writeTraceSetting("\(path)/events/gpu_scheduler/drm_sched_job_\(event)/enable", "1")
    }
    let fd = open("\(path)/trace_pipe", O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    try writeTraceSetting("\(path)/tracing_on", "1")
    try body(fd)
}

private func writeTraceSetting(_ path: String, _ value: String) throws {
    let fd = open(path, O_WRONLY | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    let bytes = Array(value.utf8)
    var count: Int
    repeat { count = write(fd, bytes, bytes.count) } while count < 0 && errno == EINTR
    guard count == bytes.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
