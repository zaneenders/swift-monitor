import Foundation
import NIOPosix
import Synchronization

final class MetricsStore: Sendable {
    private let mutex: Mutex<SystemSample>
    init(sample: SystemSample = SystemSample()) { mutex = Mutex(sample) }
    var sample: SystemSample {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}

struct Configuration {
    let interval: Double
    let port: UInt16

    init(arguments: [String]) throws {
        guard arguments.count <= 2 else { throw ConfigurationError.usage }
        let interval = arguments.first.flatMap(Double.init) ?? (arguments.isEmpty ? 2 : .nan)
        guard interval.isFinite, interval >= 0.1, interval <= 86_400 else { throw ConfigurationError.usage }
        let port = arguments.count > 1 ? UInt16(arguments[1]) : 6420
        guard let port, port > 0 else { throw ConfigurationError.usage }
        self.interval = interval
        self.port = port
    }

    enum ConfigurationError: Error { case usage }
}

/// mkstemp + rename: readers see either the old complete snapshot or the new one.
func publishFile(_ sample: SystemSample, path: String = "/run/swift-monitor/metrics.json") throws {
    var template = Array((path + ".XXXXXX").utf8CString)
    let fd = mkstemp(&template)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let temporary = String(decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var isOpen = true
    defer { if isOpen { close(fd) }; unlink(temporary) }
    guard fchmod(fd, 0o644) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    try Data(sample.json().utf8).withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += count
        }
    }
    let closeResult = close(fd)
    isOpen = false
    guard closeResult == 0, rename(temporary, path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

func sampleLoop(
    interval: Double, gpu: GPUTracker, store: MetricsStore,
    snapshotPath: String = "/run/swift-monitor/metrics.json"
) async throws {
    var cpu = CPUUsageSampler()
    var network = NetworkSampler()
    _ = cpu.sample()
    _ = network.sample()
    var sample = SystemSample(intervalSeconds: interval)
    var publishFailed = false
    while true {
        // Replace any old file immediately with an explicit startup snapshot.
        store.sample = sample
        do {
            try publishFile(sample, path: snapshotPath)
            publishFailed = false
        } catch {
            if !publishFailed { logError("publishing snapshot failed: \(error)") }
            publishFailed = true
        }
        try await Task.sleep(for: .seconds(interval))
        sample = SystemSample(intervalSeconds: interval)
        sample.cpuUsagePercent = cpu.sample()
        sample.cpuPressure = Samplers.cpuPressure()
        (sample.gpuBusy, sample.gpuAvailable) = gpu.sample()
        sample.memoryPercent = Samplers.memoryPercent()
        sample.diskPercent = Samplers.diskPercent(path: "/")
        (sample.rxBytesPerSec, sample.txBytesPerSec) = network.sample()
        sample.sampledAt = Date().timeIntervalSince1970
    }
}

func logError(_ message: String) {
    FileHandle.standardError.write(Data("swift-monitor: \(message)\n".utf8))
}

@main
struct Monitor {
    static func main() async {
        let configuration: Configuration
        do {
            configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            logError("usage: swift-monitor [interval_sec=2 (0.1...86400)] [port=6420 (1...65535)]")
            exit(2)
        }

        // Dispatch owns signal delivery; handlers themselves never touch Swift shared state.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let (signals, continuation) = AsyncStream<Void>.makeStream()
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.yield(()) }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() }; continuation.finish() }

        let eventLoops = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        do {
            let store = MetricsStore(sample: SystemSample(intervalSeconds: configuration.interval))
            let server = MetricsServer(store: store)
            let listener = try await server.bind(port: Int(configuration.port), group: eventLoops)
            let gpu = GPUTracker(tracingDir: "/sys/kernel/tracing")
            try await withThrowingTaskGroup(of: Bool.self) { tasks in
                tasks.addTask { try await server.serve(listener); return true }
                tasks.addTask {
                    try await sampleLoop(interval: configuration.interval, gpu: gpu, store: store)
                    return true
                }
                tasks.addTask { await gpu.readEvents(); return false }
                tasks.addTask {
                    for await _ in signals { return true }
                    return true
                }
                defer { tasks.cancelAll() }
                // Trace-reader EOF doesn't stop CPU/memory/disk/network sampling.
                while let shouldStop = try await tasks.next() {
                    if shouldStop { break }
                }
            }
        } catch is CancellationError {
        } catch {
            logError("server failed: \(error)")
            try? await eventLoops.shutdownGracefully()
            exit(1)
        }
        try? await eventLoops.shutdownGracefully()
    }
}
