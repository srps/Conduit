// SPDX-License-Identifier: Apache-2.0
import NIOCore

/// Shared established-tunnel relay; only the NIO handler protocol crosses
/// the module boundary. The simulator attaches the same implementation.
package func makeTunnelRelay(
    peer: Channel, diagnostics: TunnelRelayDiagnostics, side: TunnelRelayDiagnostics.Side,
    onClose: (@Sendable () -> Void)? = nil
) -> any ChannelHandler & Sendable {
    TunnelRelayHandler(peer: peer, diagnostics: diagnostics, side: side, onClose: onClose)
}

final class TunnelRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel
    /// Shared across both event loops so a tunnel reports its first failure once.
    private let diagnostics: TunnelRelayDiagnostics
    private let side: TunnelRelayDiagnostics.Side
    private let onClose: (@Sendable () -> Void)?
    // Handler state is confined to its channel's event loop. Peer-channel
    // futures hop back before touching it or the handler context.
    private var closing = false
    private var notifiedClose = false

    init(peer: Channel, diagnostics: TunnelRelayDiagnostics, side: TunnelRelayDiagnostics.Side, onClose: (@Sendable () -> Void)? = nil) {
        self.peer = peer
        self.diagnostics = diagnostics
        self.side = side
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        diagnostics.read(buffer.readableBytes, from: side)
        observe(peer.writeAndFlush(buffer), context: context, destination: otherSide, operation: .write)
        if !peer.isWritable {
            observe(context.channel.setOption(ChannelOptions.autoRead, value: false), context: context,
                    destination: side, operation: .flowControl)
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            observe(peer.setOption(ChannelOptions.autoRead, value: true), context: context,
                    destination: otherSide, operation: .flowControl)
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !notifiedClose { notifiedClose = true; onClose?() }
        if !closing {
            closing = true
            if side == .client {
                // The recipient is gone. Retire the remote socket and its
                // pool slot even if client-to-remote writes cannot drain.
                peer.close(mode: .all, promise: nil)
            } else {
                // Preserve queued response bytes after an orderly remote FIN.
                gracefulClosePeer()
            }
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        abort(context: context, error: error, destination: side, operation: .read)
    }

    private var otherSide: TunnelRelayDiagnostics.Side { side == .client ? .remote : .client }

    private func observe(_ future: EventLoopFuture<Void>, context: ChannelHandlerContext,
                         destination: TunnelRelayDiagnostics.Side, operation: TunnelRelayDiagnostics.Operation) {
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        future.hop(to: context.eventLoop).whenFailure { [self] error in
            guard !closing, bound.value.channel.isActive else { return }
            // An orderly peer close (EOF, or a write or read-flow change issued
            // after it) is the peer's own `channelInactive` to handle; aborting
            // here would truncate a response still draining to the client. A
            // failed socket syscall fails the promise with an `IOError` instead.
            if error is ChannelError, destination == otherSide, !peer.isActive { return }
            abort(context: bound.value, error: error, destination: destination, operation: operation)
        }
    }

    private func abort(context: ChannelHandlerContext, error: Error,
                       destination: TunnelRelayDiagnostics.Side, operation: TunnelRelayDiagnostics.Operation) {
        guard !closing else { return }
        closing = true
        diagnostics.failed(error, on: destination, operation: operation)
        // A failed socket cannot preserve the encrypted stream. Do not wait
        // behind an unflushable queue or replay opaque bytes on a new socket:
        // surface EOF so the client can perform its own reconnect/retry.
        context.close(promise: nil)
        peer.close(mode: .all, promise: nil)
    }

    private func gracefulClosePeer() {
        let peer = self.peer
        guard peer.isActive else {
            peer.close(mode: .all, promise: nil)
            return
        }
        // Write 0 bytes then flush; the future fires when all previously-queued writes
        // have been dispatched to the kernel send buffer. Then close cleanly.
        peer.writeAndFlush(peer.allocator.buffer(capacity: 0)).whenComplete { _ in
            peer.close(mode: .all, promise: nil)
        }
    }
}
