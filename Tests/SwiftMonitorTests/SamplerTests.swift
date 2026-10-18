import Foundation
import Testing
@testable import swift_monitor

@Test func cpuDeltasExcludeGuestAndHandleResets() {
    var cpu = CPUUsageSampler()
    #expect(cpu.sample(text: "cpu 100 0 50 800 50 0 0 0 90 0") == 0)
    #expect(cpu.sample(text: "cpu 140 0 60 840 60 0 0 0 130 0") == 50)
    #expect(cpu.sample(text: "cpu 140 0 60 840 60 0 0 0 130 0") == 0)
    #expect(cpu.sample(text: "cpu 1 0 0 2 0 0 0 0") == 0)
    #expect(cpu.sample(text: "cpu 2 0 0 3 0 0 0 0") == 50)
    #expect(cpu.sample(text: "invalid") == 0)
    #expect(cpu.sample(text: nil) == 0)
    #expect(cpu.sample(text: "cpu 2 0 0 3 0 0 0 0") == 0)
}

@Test func psiPreservesDecimalsAndRemainsSeparateFromUsage() throws {
    #expect(Samplers.cpuPressure(text: "some avg10=0.99 avg60=1.00 total=42") == 0.99)
    #expect(Samplers.cpuPressure(text: "some avg10=nan") == 0)
    var sample = SystemSample()
    sample.cpuUsagePercent = 53
    sample.cpuPressure = 5.25
    let json = try #require(JSONSerialization.jsonObject(with: Data(sample.json().utf8)) as? [String: Any])
    let cpu = try #require(json["cpu"] as? [String: NSNumber])
    #expect(cpu["usagePercent"] == 53)
    #expect(cpu["pressure"] == 5.25)
    #expect(sample.plain().hasPrefix("cpu 53%"))
}

@Test func diskCountsCannotUnderflowOrOverflow() {
    #expect(Samplers.diskPercent(blocks: 100, available: 25) == 75)
    #expect(Samplers.diskPercent(blocks: 0, available: 0) == 0)
    #expect(Samplers.diskPercent(blocks: 100, available: .max) == 0)
    #expect(Samplers.diskPercent(blocks: .max, available: 0) == 100)
}

@Test func intervalAndPortValidation() throws {
    #expect(try Configuration(arguments: []).interval == 2)
    #expect(try Configuration(arguments: ["0.1", "6420"]).interval == 0.1)
    for invalid in ["0", "-1", "nan", "inf", "oops", "0.01", "86401"] {
        #expect(throws: Configuration.ConfigurationError.self) { try Configuration(arguments: [invalid]) }
    }
    for port in ["0", "-1", "65536", "oops"] {
        #expect(throws: Configuration.ConfigurationError.self) { try Configuration(arguments: ["2", port]) }
    }
}

@Test func publicationReplacesAtomicallyAndPreservesOldFileOnFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("sample.json").path
    try publishFile(SystemSample(), path: path)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask {
            for value in 0..<100 {
                var sample = SystemSample()
                sample.cpuUsagePercent = value
                try publishFile(sample, path: path)
            }
        }
        tasks.addTask {
            for _ in 0..<200 {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                _ = try JSONSerialization.jsonObject(with: data)
            }
        }
        try await tasks.waitForAll()
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
    // rename cannot replace a directory; its contents must survive and temp files must be cleaned up.
    let blocked = directory.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: blocked.appendingPathComponent("old"))
    #expect(throws: (any Error).self) { try publishFile(SystemSample(), path: blocked.path) }
    #expect(try String(contentsOf: blocked.appendingPathComponent("old"), encoding: .utf8) == "keep")
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["blocked", "sample.json"])
}

private func networkText(_ interfaces: [(String, UInt64, UInt64)]) -> String {
    "Inter-| Receive | Transmit\n face | bytes | bytes\n" + interfaces.map {
        "  \($0.0): \($0.1) 0 0 0 0 0 0 0 \($0.2) 0 0 0 0 0 0 0"
    }.joined(separator: "\n")
}

@Test func networkDeltasSurviveInterfaceChurnAndCounterResets() {
    var network = NetworkSampler()
    #expect(network.sample(text: networkText([("eth0", 100, 200), ("vpn", 1_000, 2_000)]), now: 0) == (0, 0))
    // vpn disappears; new already-used wlan must not count its historical traffic.
    #expect(network.sample(text: networkText([("eth0", 140, 260), ("wlan", 9_000, 8_000)]), now: 2) == (20, 30))
    // An RX reset does not discard valid TX traffic, nor traffic on other interfaces.
    #expect(network.sample(text: networkText([("eth0", 1, 280), ("wlan", 9_020, 8_030)]), now: 3) == (20, 50))
    // Reappearing vpn establishes a new baseline; loopback is always ignored.
    #expect(network.sample(text: networkText([("eth0", 11, 300), ("vpn", 90_000, 80_000), ("lo", 1_000, 1_000)]), now: 4) == (10, 20))
    #expect(network.sample(text: nil, now: 5) == (0, 0))
    #expect(network.sample(text: networkText([("eth0", 50, 400)]), now: 6) == (0, 0))
    // Invalid records drop only their own baseline, and samplers do not share state.
    #expect(network.sample(text: networkText([]) + "bad: nan\n", now: 7) == (0, 0))
    #expect(network.sample(text: networkText([("eth0", 60, 420)]), now: 8) == (0, 0))
    var other = NetworkSampler()
    #expect(other.sample(text: networkText([("eth0", 90, 490)]), now: 9) == (0, 0))
    #expect(network.sample(text: networkText([("eth0", 90, 490)]), now: 9) == (30, 70))
    #expect(network.sample(text: networkText([("eth0", 100, 500)]), now: 9) == (0, 0))
}

@Test func networkLargeCountersAndRatesDoNotOverflow() {
    var network = NetworkSampler()
    #expect(network.sample(text: networkText([("eth0", 0, 0), ("wlan", 0, 0)]), now: 0) == (0, 0))
    #expect(network.sample(text: networkText([("eth0", .max, .max), ("wlan", .max, .max)]), now: 0.1) == (Int.max, Int.max))
    #expect(network.sample(text: networkText([("eth0", 0, 0)]), now: 1) == (0, 0))
    #expect(network.sample(text: networkText([("eth0", 10, 20)]), now: .nan) == (0, 0))
}

@Test func snapshotDistinguishesStartupUnavailableAndIdle() throws {
    var sample = SystemSample(intervalSeconds: 0.25)
    let startup = try #require(JSONSerialization.jsonObject(with: Data(sample.json().utf8)) as? [String: Any])
    #expect(startup["sampledAt"] is NSNull)
    #expect(startup["intervalSeconds"] as? Double == 0.25)
    #expect(sample.plain().contains("gpu n/a"))
    sample.sampledAt = 1_800_000_000.125
    sample.gpuAvailable = true
    let measured = try #require(JSONSerialization.jsonObject(with: Data(sample.json().utf8)) as? [String: Any])
    let gpu = try #require(measured["gpu"] as? [String: Any])
    #expect(measured["sampledAt"] as? Double == sample.sampledAt)
    #expect(gpu["available"] as? Bool == true)
    #expect(gpu["busy"] as? Int == 0)
    #expect(sample.plain().contains("gpu 0%"))
}

@Test func samplerPublishesStartupAndFreshTimestamps() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("metrics.json").path
    var old = SystemSample()
    old.sampledAt = 1
    try publishFile(old, path: path)
    let store = MetricsStore()
    let sampler = Task {
        try await sampleLoop(interval: 0.1, gpu: GPUTracker(tracingDir: "/unused"), store: store, snapshotPath: path)
    }
    defer { sampler.cancel() }
    let deadline = ContinuousClock.now + .seconds(3)
    var sawStartup = false
    var timestamps = Set<Double>()
    while ContinuousClock.now < deadline, timestamps.count < 2 {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let snapshot = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if snapshot["sampledAt"] is NSNull { sawStartup = true }
        if let timestamp = snapshot["sampledAt"] as? Double, timestamp != 1 {
            timestamps.insert(timestamp)
            #expect(snapshot["intervalSeconds"] as? Double == 0.1)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    sampler.cancel()
    _ = await sampler.result
    #expect(sawStartup)
    #expect(timestamps.count == 2)
    #expect(store.sample.sampledAt != nil)
    #expect(!store.sample.gpuAvailable)
}
