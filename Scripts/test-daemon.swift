#!/usr/bin/env swift
// Host-side integration checks: Swift + Foundation, no Testing module required.
import Foundation
import Glibc

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message) }
}

func systemFailure(_ operation: String) -> Failure {
    Failure("\(operation): \(String(cString: strerror(errno)))")
}

final class Child {
    let process = Process()
    private let log: URL
    private let output: FileHandle

    init(binary: URL, arguments: [String]) throws {
        log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: log)
        output = try FileHandle(forWritingTo: log)
        process.executableURL = binary
        process.arguments = arguments
        // A file cannot fill up a pipe and deadlock a child that logs repeatedly.
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    deinit {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? output.close()
        try? FileManager.default.removeItem(at: log)
    }

    func wait(seconds: Double = 3, status: Int32) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try require(!process.isRunning, "child timed out: \(process.arguments ?? [])\n\(diagnostic)")
        process.waitUntilExit()
        try require(process.terminationReason == .exit && process.terminationStatus == status,
                    "expected exit \(status), got \(process.terminationStatus): \(process.arguments ?? [])\n\(diagnostic)")
    }
}

final class Client {
    private var fd: Int32

    init(port: UInt16) throws {
        // This runner is interpreted on the glibc host; the child may use glibc or musl.
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw systemFailure("socket") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let error = systemFailure("connect")
            close(fd)
            fd = -1
            throw error
        }
    }

    deinit { disconnect() }

    func disconnect(reset: Bool = false) {
        guard fd >= 0 else { return }
        if reset {
            var option = linger(l_onoff: 1, l_linger: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size))
        }
        close(fd)
        fd = -1
    }

    func ready(_ events: Int16, seconds: Double) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let result = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
            if result >= 0 { return result > 0 } // EOF/reset also counts as readiness.
            if errno != EINTR { throw systemFailure("poll") }
        }
    }

    func send(_ text: String) throws {
        try Array(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try require(try ready(Int16(POLLOUT), seconds: 2), "send timed out")
                let count = Glibc.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw systemFailure("send") }
                offset += count
            }
        }
    }

    func response(seconds: Double = 2, allowReset: Bool = false) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try require(try ready(Int16(POLLIN), seconds: max(0, deadline - ProcessInfo.processInfo.systemUptime)),
                        "response timed out")
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 || (count < 0 && allowReset && errno == ECONNRESET) { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw systemFailure("recv") }
            data.append(contentsOf: buffer.prefix(count))
            try require(data.count <= 64 * 1024, "response exceeded 64 KiB")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

func request(_ path: String, port: UInt16) throws -> String {
    let client = try Client(port: port)
    try client.send("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
    return try client.response()
}

func body(_ response: String) throws -> String {
    guard let separator = response.range(of: "\r\n\r\n") else { throw Failure("missing HTTP header terminator") }
    return String(response[separator.upperBound...])
}

func run(binary: URL) throws {
    for interval in ["0", "-1", "nan", "inf", "invalid"] {
        try Child(binary: binary, arguments: [interval]).wait(status: 2)
    }

    // Reserve an ephemeral port briefly, then pass it to the temporary daemon.
    let reservation = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard reservation >= 0 else { throw systemFailure("socket") }
    let port: UInt16 = try { () throws -> UInt16 in
        defer { close(reservation) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(reservation, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else { throw systemFailure("bind") }
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                guard getsockname(reservation, $0, &length) == 0 else { throw systemFailure("getsockname") }
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }()

    let daemon = try Child(binary: binary, arguments: ["0.2", String(port)])
    // Keep the child alive through every request; deinit kills/reaps it on failure.
    defer { withExtendedLifetime(daemon) {} }
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    var idle: Client?
    while idle == nil {
        do { idle = try Client(port: port) } catch {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw error }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    defer { idle?.disconnect() }
    try require(try request("/healthz", port: port).hasSuffix("ok"), "idle peer blocked health request")
    do {
        let client = try Client(port: port)
        try client.send("GET /hea")
        try require(try !client.ready(Int16(POLLIN), seconds: 0.1), "response sent before complete request")
        try client.send("lthz HTTP/1.1\r\nHost: localhost\r\n\r\n")
        try require(try client.response().hasPrefix("HTTP/1.1 200 OK\r\n"), "fragmented request failed")
    }
    do {
        let client = try Client(port: port)
        try client.send("GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
        client.disconnect(reset: true)
    }
    try require(try request("/healthz", port: port).hasSuffix("ok"), "disconnected peer killed daemon")
    do {
        let client = try Client(port: port)
        try client.send("GET / HTTP/1.1\r\nX-Large: " + String(repeating: "a", count: 17_000))
        try require(try client.response(allowReset: true).isEmpty, "oversized request accepted")
    }
    Thread.sleep(forTimeInterval: 0.25)
    struct Metrics: Decodable {
        struct CPU: Decodable { let usagePercent: Double; let pressure: Double }
        struct GPU: Decodable { let busy: Int; let available: Bool }
        let cpu: CPU
        let gpu: GPU
        let sampledAt: Double?
        let intervalSeconds: Double
    }
    let json = try body(request("/metrics", port: port))
    let metrics = try JSONDecoder().decode(Metrics.self, from: Data(json.utf8))
    try require((0...100).contains(metrics.cpu.usagePercent), "CPU usage out of range: \(json)")
    try require(metrics.sampledAt != nil, "snapshot never left startup state")
    try require(abs(Date().timeIntervalSince1970 - metrics.sampledAt!) < 3, "stale snapshot")
    try require(metrics.intervalSeconds == 0.2, "wrong sample interval")
    try require(!metrics.gpu.available && metrics.gpu.busy == 0, "unprivileged GPU must be unavailable")
    Thread.sleep(forTimeInterval: 0.25)
    let updated = try JSONDecoder().decode(Metrics.self, from: Data(try body(request("/metrics", port: port)).utf8))
    try require((updated.sampledAt ?? 0) > (metrics.sampledAt ?? 0), "sample timestamp did not advance")
    print("CPU snapshot: usagePercent=\(metrics.cpu.usagePercent), pressure=\(metrics.cpu.pressure)")
    try require(try body(request("/metrics.txt", port: port)).hasPrefix("cpu "), "invalid plain metrics")
    try require(try idle!.response(seconds: 7).isEmpty, "silent peer not reaped")
    idle?.disconnect()
    idle = try Client(port: port)
    try Child(binary: binary, arguments: ["2", String(port)]).wait(status: 1)
    daemon.process.terminate()
    try daemon.wait(status: 0)
    print("PASS: arguments, framing, isolation, disconnects, limits, deadlines, freshness, GPU availability, bind failure, SIGTERM")
}

do {
    try require(geteuid() != 0, "Run unprivileged: tests must not change tracefs or /run snapshots")
    try require(CommandLine.arguments.count == 2, "usage: swift Scripts/test-daemon.swift <swift-monitor-binary>")
    try run(binary: URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL)
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
