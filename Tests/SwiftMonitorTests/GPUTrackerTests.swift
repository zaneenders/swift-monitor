import Foundation
import Testing
@testable import swift_monitor

private func event(_ time: Double, _ kind: String, _ id: String = "1:1") -> String {
    "worker-1 [000] d..1. \(time): drm_sched_job_\(kind): fence=\(id), ring=gpu"
}

@Test func gpuEarlyBootBurstUsesWholeSampleWindow() {
    let gpu = GPUTracker(tracingDir: "/unused", now: 0)
    gpu.ingest(line: event(0, "run"))
    gpu.ingest(line: event(0.1, "done"))
    #expect(gpu.sample(now: 2).busy == 5)
    #expect(gpu.sample(now: 4).busy == 0)
}

@Test func gpuOngoingJobIsSplitAcrossWindows() {
    let gpu = GPUTracker(tracingDir: "/unused", now: 100)
    gpu.ingest(line: event(101, "run"))
    #expect(gpu.sample(now: 102).busy == 50)
    #expect(gpu.sample(now: 104).busy == 100)
    gpu.ingest(line: event(105, "done"))
    #expect(gpu.sample(now: 106).busy == 50)
    #expect(gpu.sample(now: 108).busy == 0)
}

@Test func gpuOverlapsDuplicatesAndUnmatchedEvents() {
    let gpu = GPUTracker(tracingDir: "/unused", now: 0)
    gpu.ingest(line: event(0.1, "done", "unknown"))
    gpu.ingest(line: event(0.5, "run", "1:1"))
    gpu.ingest(line: event(0.6, "run", "1:1"))
    gpu.ingest(line: event(1, "run", "2:1"))
    gpu.ingest(line: event(1.5, "done", "1:1"))
    gpu.ingest(line: event(1.75, "done", "1:1"))
    gpu.ingest(line: event(2, "done", "2:1"))
    #expect(gpu.sample(now: 3).busy == 50)
}

@Test func gpuLateAndMalformedEventsCannotRevisePublishedWindow() {
    let gpu = GPUTracker(tracingDir: "/unused", now: 0)
    #expect(gpu.sample(now: 2).busy == 0)
    gpu.ingest(line: event(0.1, "run"))
    gpu.ingest(line: event(0.2, "done"))
    gpu.ingest(line: event(.nan, "run"))
    gpu.ingest(line: "bad data")
    #expect(gpu.sample(now: 4).busy == 0)
}

@Test func gpuLostEventsResetOccupancyAndJobPointersCanPair() {
    let gpu = GPUTracker(tracingDir: "/unused", now: 0)
    gpu.ingest(line: "worker-1 [000] d..1. 0.25: drm_sched_job_run: dev=0 job=abc")
    gpu.ingest(line: "worker-1 [000] d..1. 0.75: drm_sched_job_done: dev=0 job=abc")
    #expect(gpu.sample(now: 1).busy == 50)
    gpu.ingest(line: event(1.1, "run"))
    gpu.ingest(line: "CPU:0 [LOST 10 EVENTS]")
    #expect(gpu.sample(now: 2).busy == 0)
}

// A regular-files model of tracefs: mkdir populates controls; rmdir removes them.
private struct TraceFixture: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("instances"), withIntermediateDirectories: true)
        // Global controls and another consumer's instance must remain untouched.
        try Data("global clock".utf8).write(to: root.appendingPathComponent("trace_clock"))
        try Data("global events".utf8).write(to: root.appendingPathComponent("trace_pipe"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("instances/other"), withIntermediateDirectories: true)
    }

    func fileSystem(omitting: String? = nil, eof: Bool = false) -> TraceInstanceFileSystem {
        TraceInstanceFileSystem(create: { path in
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            for name in ["tracing_on", "trace_clock", "events/gpu_scheduler/drm_sched_job_run/enable",
                         "events/gpu_scheduler/drm_sched_job_done/enable"] where name != omitting {
                let url = URL(fileURLWithPath: path).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("0".utf8).write(to: url)
            }
            if omitting != "trace_pipe" {
                if eof {
                    try Data().write(to: URL(fileURLWithPath: path).appendingPathComponent("trace_pipe"))
                } else {
                    guard mkfifo("\(path)/trace_pipe", 0o600) == 0 else { throw POSIXError(.EIO) }
                }
            }
        }, remove: { path in
            #expect(try String(contentsOfFile: "\(path)/tracing_on", encoding: .utf8) == "0")
            let run = "\(path)/events/gpu_scheduler/drm_sched_job_run/enable"
            #expect(try String(contentsOfFile: run, encoding: .utf8) == "0")
            try FileManager.default.removeItem(atPath: path)
        })
    }

    func expectClean() throws {
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("instances").path) == ["other"])
        #expect(try String(contentsOf: root.appendingPathComponent("trace_clock"), encoding: .utf8) == "global clock")
        #expect(try String(contentsOf: root.appendingPathComponent("trace_pipe"), encoding: .utf8) == "global events")
    }
}

@Test func gpuInstanceCleanupOnSuccessFailureAndPartialSetup() throws {
    let fixture = try TraceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var pipe: String?
    try withGPUTrace(tracingDir: fixture.root.path, fileSystem: fixture.fileSystem()) { descriptor in
        pipe = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(descriptor)")
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("instances").path)
        let name = try #require(entries.first(where: { $0 != "other" }))
        let instance = fixture.root.appendingPathComponent("instances/\(name)")
        #expect(try String(contentsOf: instance.appendingPathComponent("tracing_on"), encoding: .utf8) == "1")
        #expect(try String(contentsOf: instance.appendingPathComponent("trace_clock"), encoding: .utf8) == "mono")
    }
    // Other tests may reuse the fd number; check the unique pipe, not the number.
    let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
    #expect(!descriptors.contains {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\($0)")) == pipe
    })
    try fixture.expectClean()
    #expect(throws: POSIXError.self) {
        try withGPUTrace(tracingDir: fixture.root.path, fileSystem: fixture.fileSystem()) { _ in
            throw POSIXError(.EIO)
        }
    }
    for missing in ["events/gpu_scheduler/drm_sched_job_done/enable", "trace_pipe"] {
        #expect(throws: POSIXError.self) {
            try withGPUTrace(tracingDir: fixture.root.path, fileSystem: fixture.fileSystem(omitting: missing)) { _ in
                Issue.record("Reader must not run after partial setup")
            }
        }
        try fixture.expectClean()
    }
}

@Test func gpuTraceReaderCancellationReturnsAndMarksUnavailable() async throws {
    let fixture = try TraceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let gpu = GPUTracker(tracingDir: fixture.root.path, traceFS: fixture.fileSystem())
    #expect(!gpu.sample().available)
    let reader = Task { await gpu.readEvents() }
    defer { reader.cancel() }
    let deadline = ContinuousClock.now + .seconds(2)
    while !gpu.sample().available, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(gpu.sample().available)
    // The fixture FIFO has no writer: poll blocks until the bounded cancellation check.
    reader.cancel()
    await reader.value
    #expect(!gpu.sample().available)
    #expect(gpu.sample().busy == 0)
    try fixture.expectClean()
}

@Test func gpuReaderEOFAndSetupFailureAreUnavailable() async throws {
    let fixture = try TraceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let eof = GPUTracker(tracingDir: fixture.root.path, traceFS: fixture.fileSystem(eof: true))
    await eof.readEvents()
    #expect(!eof.sample().available)
    let failed = GPUTracker(tracingDir: fixture.root.path, traceFS: fixture.fileSystem(omitting: "trace_pipe"))
    await failed.readEvents()
    #expect(!failed.sample().available)
    try fixture.expectClean()
}

@Test func gpuCancelledBeforeStartingDoesNotLeakAnInstance() async throws {
    let fixture = try TraceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let gpu = GPUTracker(tracingDir: fixture.root.path, traceFS: fixture.fileSystem())
    let reader = Task { await gpu.readEvents() }
    reader.cancel()
    await reader.value
    #expect(!gpu.sample().available)
    try fixture.expectClean()
}

@Test func gpuFailedCreateDoesNotRemoveAnUnownedInstance() throws {
    let fixture = try TraceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fileSystem = TraceInstanceFileSystem(create: { _ in throw POSIXError(.EACCES) }, remove: { _ in
        Issue.record("Must not remove an instance we did not create")
    })
    #expect(throws: POSIXError.self) {
        try withGPUTrace(tracingDir: fixture.root.path, fileSystem: fileSystem) { _ in
            Issue.record("Must not open a reader after instance creation fails")
        }
    }
    try fixture.expectClean()
}
