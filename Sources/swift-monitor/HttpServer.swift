// HTTP/1 decoder → async per-connection task → immutable metrics snapshot.

import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

struct MetricsServer: Sendable {
    typealias ResponsePart = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias Connection = NIOAsyncChannel<HTTPServerRequestPart, ResponsePart>
    typealias Listener = NIOAsyncChannel<any Channel, Never>

    let store: MetricsStore

    private let channels = ActiveChannels()

    func bind(port: Int, group: MultiThreadedEventLoopGroup) async throws -> Listener {
        let channels = self.channels
        return try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)
            .childChannelOption(.autoRead, value: false)
            .bind(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    guard channels.insert(channel) else { throw ChannelError.ioOnClosedChannel }
                    channel.closeFuture.whenComplete { _ in channels.remove(channel) }
                    try channel.pipeline.syncOperations.addHandler(RequestGuard())
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
                    try channel.pipeline.syncOperations.addHandler(ResponseEncoderBridge())
                    // Wrap only after a child task owns the accepted channel. An async writer
                    // buffered in the accept stream could otherwise be dropped during shutdown.
                    return channel
                }
            }
    }

    func serve(_ listener: Listener) async throws {
        defer { channels.closeAll() }
        try await withTaskCancellationHandler {
            try await listener.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await channel in inbound {
                        group.addTask {
                            do {
                                let connection = try await channel.eventLoop.submit {
                                    try Connection(wrappingChannelSynchronously: channel)
                                }.get()
                                // executeThenClose owns the writer before enabling reads.
                                try await self.handle(connection)
                            } catch {
                                channel.close(promise: nil)
                            }
                        }
                    }
                }
            }
        } onCancel: {
            listener.channel.close(promise: nil)
            // Includes channels accepted/initialized but not yet yielded to a child task.
            channels.closeAll()
        }
    }

    private func handle(_ connection: Connection) async throws {
        try await withTaskCancellationHandler {
            try await connection.executeThenClose { inbound, outbound in
                try await connection.channel.setOption(.autoRead, value: true).get()
                var request: HTTPRequestHead?
                for try await part in inbound {
                    switch part {
                    case .head(let head): request = head
                    case .body: break // discarded; RequestGuard bounds total wire bytes
                    case .end:
                        guard let request else { return }
                        let (status, body) = response(to: request)
                        let headers = HTTPHeaders([
                            ("Content-Type", body.hasPrefix("{") ? "application/json" : "text/plain"),
                            ("Content-Length", String(body.utf8.count)),
                            ("Connection", "close"),
                        ])
                        try await outbound.write(contentsOf: [
                            .head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)),
                            .body(ByteBuffer(string: body)),
                            .end(nil),
                        ])
                        return
                    }
                }
            }
        } onCancel: {
            connection.channel.close(promise: nil)
        }
    }

    private func response(to request: HTTPRequestHead) -> (HTTPResponseStatus, String) {
        guard request.method == .GET else { return (.methodNotAllowed, "method not allowed") }
        switch request.uri {
        case "/", "/metrics": return (.ok, store.sample.json())
        case "/metrics.txt": return (.ok, store.sample.plain())
        case "/healthz": return (.ok, "ok")
        default: return (.notFound, "not found")
        }
    }
}

/// Tracks the accept → child-task handoff as well as active requests during shutdown.
private final class ActiveChannels: Sendable {
    private struct State {
        var stopped = false
        var channels: [ObjectIdentifier: any Channel] = [:]
    }
    private let state = Mutex(State())

    func insert(_ channel: any Channel) -> Bool {
        let accepted = state.withLock { s in
            guard !s.stopped else { return false }
            s.channels[ObjectIdentifier(channel)] = channel
            return true
        }
        if !accepted { channel.close(promise: nil) }
        return accepted
    }

    func remove(_ channel: any Channel) {
        state.withLock { _ = $0.channels.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    func closeAll() {
        let channels = state.withLock { s in
            s.stopped = true
            let channels = Array(s.channels.values)
            s.channels.removeAll()
            return channels
        }
        for channel in channels { channel.close(promise: nil) }
    }
}

/// Absolute connection deadline also stops slow trickles; no request exceeds 16 KiB.
final class RequestGuard: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var received = 0
    private var deadline: Scheduled<Void>?

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = context.eventLoop.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received += unwrapInboundIn(data).readableBytes
        guard received <= 16 * 1024 else { context.close(promise: nil); return }
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// IOData can contain FileRegion; keep the async boundary strictly ByteBuffer-based.
private final class ResponseEncoderBridge: ChannelOutboundHandler {
    typealias OutboundIn = MetricsServer.ResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case .head(let head): context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .body(let body): context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: promise)
        case .end(let trailers): context.write(wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}
