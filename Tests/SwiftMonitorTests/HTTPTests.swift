import NIOCore
import NIOEmbedded
import NIOPosix
import Testing
@testable import swift_monitor

private typealias Client = NIOAsyncChannel<ByteBuffer, ByteBuffer>

private func connect(port: Int, group: MultiThreadedEventLoopGroup) async throws -> Client {
    try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port) { channel in
        channel.eventLoop.makeCompletedFuture {
            // Bound the tests too: a regression must fail, not hang the test runner.
            channel.eventLoop.scheduleTask(in: .seconds(3)) { channel.close(promise: nil) }
            return try Client(wrappingChannelSynchronously: channel)
        }
    }
}

private func request(_ client: Client, fragments: [String]) async throws -> String {
    try await client.executeThenClose { inbound, outbound in
        for fragment in fragments {
            try await outbound.write(ByteBuffer(string: fragment))
            try await Task.sleep(for: .milliseconds(20))
        }
        var response = ""
        for try await bytes in inbound { response += String(buffer: bytes) }
        return response
    }
}

@Test func fragmentedRequestsIdleClientsAndDisconnectsAreIsolated() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let store = MetricsStore()
        var sample = SystemSample()
        sample.cpuUsagePercent = 53
        store.sample = sample
        let server = MetricsServer(store: store)
        let listener = try await server.bind(port: 0, group: group)
        let port = try #require(listener.channel.localAddress?.port)
        let serving = Task { try await server.serve(listener) }
        do {
            let idle = try await connect(port: port, group: group)
            let client = try await connect(port: port, group: group)
            let response = try await request(client, fragments: ["GET /hea", "lthz HTTP/1.1\r\nHost: localhost\r\n\r\n"])
            #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(response.hasSuffix("ok"))
            try await idle.executeThenClose { _, _ in }

            let metrics = try await connect(port: port, group: group)
            let json = try await request(metrics, fragments: ["GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n"])
            #expect(json.contains("\"usagePercent\":53"))
            let disconnected = try await connect(port: port, group: group)
            try await disconnected.executeThenClose { _, outbound in
                try await outbound.write(ByteBuffer(string: "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n"))
            }
            let healthy = try await connect(port: port, group: group)
            #expect(try await request(healthy, fragments: ["GET /healthz HTTP/1.1\r\n\r\n"]).hasSuffix("ok"))
        } catch {
            serving.cancel()
            _ = await serving.result
            throw error
        }
        // Cancellation must close an accepted idle channel, not just the listener.
        let idleAtShutdown = try await connect(port: port, group: group)
        serving.cancel()
        _ = await serving.result
        try await idleAtShutdown.executeThenClose { inbound, _ in
            var iterator = inbound.makeAsyncIterator()
            let next = try await iterator.next()
            #expect(next == nil)
        }
        #expect(!listener.channel.isActive)
    } catch {
        try await group.shutdownGracefully()
        throw error
    }
    try await group.shutdownGracefully()
}

@Test func requestGuardBoundsWireBytesAndLifetime() throws {
    let oversized = EmbeddedChannel(handler: RequestGuard())
    try oversized.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    _ = try oversized.writeInbound(ByteBuffer(repeating: 65, count: 16 * 1024 + 1))
    #expect(!oversized.isActive)
    _ = try oversized.finish(acceptAlreadyClosed: true)

    let silent = EmbeddedChannel(handler: RequestGuard())
    try silent.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    silent.embeddedEventLoop.advanceTime(by: .seconds(5))
    #expect(!silent.isActive)
    _ = try silent.finish(acceptAlreadyClosed: true)
}
