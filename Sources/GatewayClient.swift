#if os(macOS)
import Foundation

// App side of the app <-> Gateway protocol. Layout of this file:
//   Seams            `GatewayConnecting` / `GatewayLink`: what tests replace instead of XPC
//   GatewayClient    the actor with all the logic: handshake, timeouts, recovery of a lost
//                    reply, heartbeat, reconnect, pushed events
//   XPC              the thin production adapters over NSXPCConnection
// The contract itself (requests, replies, the ledger) is in `Sources/Gateway/GatewayIPC.swift`.

// MARK: Seams

/// One connection to the Gateway.
protocol GatewayLink: Sendable {
    /// Throws when the connection is gone; a reply that never comes is the caller's timeout to handle.
    func send(_ request: Data) async throws -> Data
    /// Closes the connection. A `send` still waiting on it ends with an error.
    func invalidate()
}

/// What a connector reports to the client for one connection.
protocol GatewayClientEventReceiving: Sendable {
    /// Returns once the batch is processed; the transport acks to the Gateway only after that.
    func deliver(_ batch: GatewayEventBatch) async
    /// A batch arrived that could not be decoded, so output was lost.
    func protocolBroken() async
}

/// Opens connections to the Gateway. Production: `XPCGatewayConnector`; tests script a fake.
protocol GatewayConnecting: Sendable {
    /// `onTermination` fires when the connection is interrupted or invalidated without the client
    /// having asked for it.
    func connect(
        events: any GatewayClientEventReceiving, onTermination: @escaping @Sendable () -> Void
    ) async throws -> any GatewayLink
}

/// Every limit the client applies, in one place so tests can shrink them. All durations run on
/// the injected `SupervisorClock`.
struct GatewayClientPolicy: Sendable {
    /// Bounds connecting plus the hello round trip.
    var connectTimeout: Duration = .seconds(10)
    /// Bounds any single request. Requests are quick (`runNow` returns at once).
    var requestTimeout: Duration = .seconds(10)
    /// Heartbeat while connected. Also the longest wait before the first reconnect attempt,
    /// because the loop only looks at the connection once per interval.
    var pingInterval: Duration = .seconds(5)
    /// How long a `ping` may go unanswered before the Gateway counts as hung.
    var pingTimeout: Duration = .seconds(5)
    /// Pause between reconnect attempts while the Gateway is unreachable.
    var retryInterval: Duration = .seconds(2)
    /// After a lost reply to a mutating request: how often and how long to ask for its outcome
    /// while the Gateway still reports it as in progress.
    var recoveryPolls = 5
    var recoveryPollInterval: Duration = .seconds(1)
}

// MARK: Client

/// App-side client of the Gateway: one persistent connection with a version handshake, a
/// heartbeat, automatic reconnect and pushed status events.
///
/// - Every callback from a connection carries the `epoch` it belongs to; a callback from a
///   connection that is no longer current is ignored (the same idiom as `WorkerSupervisor`).
/// - A mutating request whose reply was lost is never re-sent. After reconnecting, its outcome
///   is looked up by `requestID`; if the Gateway no longer knows it, `connectionLost` is thrown
///   and the caller decides (the UI shows the fresh status).
/// - `events` has a single consumer.
/// - `stop()` is final: it closes the connection, finishes `events` and fails later requests,
///   so nothing can reopen a connection that nobody would close again.
/// - Cancelling the caller does not interrupt a request that is already on the wire: it ends
///   with the reply, the request timeout or `stop()`, whichever comes first.
/// - The connection does not keep the client alive (`EventRelay` and the maintain loop hold it
///   weakly); a client that is released without `stop()` closes its connection.
actor GatewayClient: GatewayControlling, GatewayChatControlling {
    nonisolated let events: AsyncStream<GatewayClientEvent>
    /// The writing end of `events`; finished in `stop()`.
    private let continuation: AsyncStream<GatewayClientEvent>.Continuation
    /// Chat output. Unbounded on purpose: a delta is not a snapshot, so dropping one corrupts
    /// the reply. Bounded in practice by what one reply can produce; finished in `stop()`.
    nonisolated let chatSignals: AsyncStream<GatewayChatSignal>
    private let chatContinuation: AsyncStream<GatewayChatSignal>.Continuation

    private let connector: any GatewayConnecting
    private let clock: any SupervisorClock
    private let policy: GatewayClientPolicy

    /// The current connection, set only after a successful hello. Nil means "down".
    private var link: (any GatewayLink)?
    /// Bumped for every new connection and every drop. Anything that waited across an await
    /// compares the epoch it started with against this one before touching the connection.
    private var epoch = 0
    /// Sequence of the last event batch accepted on the current connection; -1 before the first.
    private var lastSequence = -1
    /// The Gateway process behind the current connection, from its hello reply. A different
    /// value after a reconnect means the Gateway restarted and its request ledger is empty.
    private var instanceID: UUID?
    /// The connection attempt in progress, shared by every caller that needs a connection.
    private var connectTask: Task<Int, Error>?
    /// The heartbeat/reconnect loop; one stored task, cancelled in `stop()`.
    private var maintainTask: Task<Void, Never>?
    /// Whether the last thing reported to the consumer was a disconnect (avoids repeating it
    /// on every failed reconnect attempt).
    private var reportedDown = false
    /// Set once by `stop()` and never cleared.
    private var stopped = false

    init(
        connector: any GatewayConnecting = XPCGatewayConnector(),
        clock: any SupervisorClock = SystemSupervisorClock(), policy: GatewayClientPolicy = GatewayClientPolicy()
    ) {
        self.connector = connector
        self.clock = clock
        self.policy = policy
        // Bounded: if the consumer stops reading, the oldest events are discarded. Statuses are
        // snapshots, so the newest ones are the ones worth keeping.
        let stream = AsyncStream.makeStream(of: GatewayClientEvent.self, bufferingPolicy: .bufferingNewest(32))
        events = stream.stream
        continuation = stream.continuation
        let chat = AsyncStream.makeStream(of: GatewayChatSignal.self, bufferingPolicy: .unbounded)
        chatSignals = chat.stream
        chatContinuation = chat.continuation
    }

    var isConnected: Bool { link != nil }

    // MARK: GatewayControlling

    /// Sends one request and returns the status the Gateway answered with. Connects first if
    /// needed. Throws the Gateway's own refusal (`alreadyRunning`, `invalidConfig`),
    /// `gatewayUnavailable` when it cannot be reached, or `connectionLost` when a mutating
    /// request may or may not have been executed.
    func send(_ request: GatewayRequest) async throws -> GatewayStatus {
        switch try await perform(request) {
        case .status(let status): return status
        case .failure(let failure): throw Self.error(for: failure)
        // `hello`, `pong` and `requestState` are answers to requests this method never sends.
        default: throw GatewayError.remote("Unexpected reply from the Gateway.")
        }
    }

    // MARK: GatewayChatControlling

    func generate(_ request: ChatGenerateRequest, id: UUID) async throws -> GatewayFailure? {
        switch try await perform(.chatGenerate(request), id: id) {
        case .accepted: return nil
        case .failure(let failure): return failure
        default: throw GatewayError.remote("Unexpected reply from the Gateway.")
        }
    }

    func connect() async throws { _ = try await ensureConnected() }

    func cancel(_ id: UUID) async throws {
        switch try await perform(.chatCancel(target: id)) {
        case .accepted: return
        case .failure(let failure): throw Self.error(for: failure)
        default: throw GatewayError.remote("Unexpected reply from the Gateway.")
        }
    }

    /// Starts the heartbeat/reconnect loop. Idempotent; the loop is a single stored task.
    func start() {
        guard maintainTask == nil, !stopped else { return }
        // The loop holds the client only while a step runs, never across the sleep.
        maintainTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                // Nil when the client was released or stopped: the loop ends by itself.
                guard let pause = await self?.maintainStep() else { return }
                // The sleep throws on cancellation, which is how `stop()` ends the loop.
                do { try await clock.sleep(for: pause) } catch { return }
            }
        }
    }

    /// Final, see the type docstring. Safe to call more than once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        maintainTask?.cancel()
        maintainTask = nil
        // Also bumps the epoch, so a handshake still in flight does not install its connection.
        drop(reason: "stopped", report: false)
        // Ends the consumer's `for await` loop; nothing is yielded after this.
        continuation.finish()
        chatContinuation.finish()
    }

    // MARK: Requests

    /// One request from the caller's point of view: connect, exchange, and for a mutating
    /// request whose reply was lost, find out what happened instead of sending it again.
    private func perform(_ request: GatewayRequest, id: UUID = UUID()) async throws -> GatewayReply {
        // Checked before anything is sent. Once the request is on the wire, cancelling the
        // caller no longer interrupts it; see the type docstring.
        try Task.checkCancellation()
        // `id` is fixed before the first attempt: recovery asks about this same ID. A chat
        // generation supplies its own, because the ID is also what its events carry.
        let connectedEpoch = try await ensureConnected()
        // Remembered before sending, to tell a reconnect to the same Gateway process from a
        // reconnect to a restarted one.
        let instance = instanceID
        do {
            return try await exchange(request, id: id, epoch: connectedEpoch, timeout: policy.requestTimeout)
        } catch let failure as TransportFailure {
            // A read-only request can simply be asked again by the caller.
            guard request.isMutating else { throw GatewayError.gatewayUnavailable(failure.detail) }
            return try await recover(id, previousInstance: instance)
        }
    }

    /// The connection failed or timed out; the request may or may not have been executed.
    /// Internal to the client: `perform` and `recover` turn it into a `GatewayError`.
    private struct TransportFailure: Error { var detail: String }

    /// One request/reply round trip on the connection of `epoch`. On a transport error or a
    /// timeout it drops that connection and throws `TransportFailure`; a reply that arrives,
    /// even a refusal, is returned.
    private func exchange(
        _ request: GatewayRequest, id: UUID, epoch requestEpoch: Int, timeout: Duration
    ) async throws -> GatewayReply {
        // The connection the caller meant is already gone: nothing was sent.
        guard requestEpoch == epoch, let link else { throw TransportFailure(detail: "The connection was lost.") }
        let payload = try GatewayWire.encoder.encode(GatewayRequestEnvelope(requestID: id, request: request))
        // nil = the timeout won, a throw = the connection failed, a value = the reply.
        let data: Data?
        do {
            data = try await raceTimeout(clock: clock, timeout: timeout) { try await link.send(payload) }
        } catch {
            // `drop(epoch:)` is a no-op if something else replaced the connection meanwhile.
            drop(epoch: requestEpoch, reason: Self.unavailable(error).localizedDescription)
            throw TransportFailure(detail: error.localizedDescription)
        }
        guard let data else {
            // A hung Gateway never calls back: close the connection the call is stuck on.
            drop(epoch: requestEpoch, reason: "The Gateway did not answer in time.")
            throw TransportFailure(detail: "The request timed out.")
        }
        return try Self.decodeReply(data)
    }

    /// The reply to a mutating request was lost with its connection. Reconnect and ask the
    /// Gateway what became of it; never send it again.
    private func recover(_ id: UUID, previousInstance: UUID?) async throws -> GatewayReply {
        let recoveredEpoch: Int
        do { recoveredEpoch = try await ensureConnected() } catch { throw GatewayError.connectionLost }
        // A different Gateway process has no memory of the request.
        guard instanceID == previousInstance else { throw GatewayError.connectionLost }
        // One immediate question plus `recoveryPolls` more, a poll interval apart.
        for attempt in 0...policy.recoveryPolls {
            let reply: GatewayReply
            do {
                // `requestStatus` is read-only and gets its own ID; `id` is what it asks about.
                reply = try await exchange(
                    .requestStatus(id), id: UUID(), epoch: recoveredEpoch, timeout: policy.requestTimeout
                )
            } catch is TransportFailure {
                // The connection died a second time: give up rather than loop on reconnects.
                throw GatewayError.connectionLost
            }
            switch reply {
            // The Gateway finished it; this is the reply that got lost.
            case .requestState(.completed(let stored)): return stored
            case .requestState(.inProgress):
                // Still running there. Wait and ask again, except after the last attempt.
                if attempt < policy.recoveryPolls { try await clock.sleep(for: policy.recoveryPollInterval) }
            // `.unknown` (the request never arrived, or was evicted) or a reply that makes no
            // sense here. The outcome cannot be confirmed, and sending again could run it twice.
            default: throw GatewayError.connectionLost
            }
        }
        // Still in progress after the last poll.
        throw GatewayError.connectionLost
    }

    // MARK: Connection

    /// Returns the epoch of a live, greeted connection, connecting if needed. Concurrent callers
    /// share one attempt.
    private func ensureConnected() async throws -> Int {
        guard !stopped else { throw GatewayError.gatewayUnavailable("The connection was closed.") }
        if link != nil { return epoch }
        // Someone is already connecting: wait for that attempt instead of opening a second
        // connection (the actor is reentrant across the await below).
        if let task = connectTask { return try await task.value }
        // An unstructured task, so the attempt is not tied to the cancellation of whichever
        // caller happened to start it; the others are waiting on it too.
        let task = Task { try await self.establish() }
        connectTask = task
        defer { connectTask = nil }
        return try await task.value
    }

    /// Opens a connection and performs the hello handshake. The connection only becomes
    /// `link` once the Gateway answered with a matching version; until then nothing else is
    /// sent on it. Returns the new epoch.
    private func establish() async throws -> Int {
        epoch += 1
        // `mine` identifies this attempt; every callback below carries it.
        let mine = epoch
        // Sequences restart at 0 on every connection.
        lastSequence = -1
        let relay = EventRelay(client: self, epoch: mine)
        let newLink: any GatewayLink
        do {
            newLink = try await connector.connect(events: relay) { [weak self] in
                // Runs on an XPC queue, off the actor: hop back in a task.
                Task { await self?.drop(epoch: mine, reason: "The connection to the Gateway was interrupted.") }
            }
        } catch {
            // Retire the epoch of the failed attempt, unless a drop already moved past it.
            if epoch == mine { epoch += 1 }
            throw Self.unavailable(error)
        }
        do {
            let hello = GatewayRequest.hello(version: GatewayConstants.protocolVersion)
            let payload = try GatewayWire.encoder.encode(GatewayRequestEnvelope(request: hello))
            let data = try await raceTimeout(clock: clock, timeout: policy.connectTimeout) {
                try await newLink.send(payload)
            }
            guard let data else { throw GatewayError.gatewayUnavailable("The handshake timed out.") }
            let reply = try Self.decodeReply(data)
            guard case .hello(_, let instance) = reply else {
                // The Gateway refused the handshake (for example another protocol version).
                if case .failure(let failure) = reply { throw Self.error(for: failure) }
                throw GatewayError.remote("Unexpected reply to the handshake.")
            }
            // `stop()` or a termination callback ran while the hello was in flight: this
            // connection is no longer wanted and must not be installed.
            guard epoch == mine else { throw GatewayError.connectionLost }
            link = newLink
            instanceID = instance
            reportedDown = false
            continuation.yield(.connected(instanceID: instance))
            return mine
        } catch {
            // Every failure after `connect` succeeded leaves an open connection behind.
            newLink.invalidate()
            if epoch == mine { epoch += 1 }
            throw Self.unavailable(error)
        }
    }

    /// A transport error (the Gateway is not installed, not running, or gone) in the words the
    /// UI shows; protocol-level errors pass through.
    private static func unavailable(_ error: any Error) -> GatewayError {
        error as? GatewayError ?? .gatewayUnavailable(error.localizedDescription)
    }

    /// Drops the connection of `epoch` unless a newer one replaced it already.
    private func drop(epoch dropped: Int, reason: String) {
        guard dropped == epoch else { return }
        drop(reason: reason, report: true)
    }

    /// Closes the current connection, if any, and makes every callback from it stale.
    /// `reason` is shown to the user, so it is a full sentence.
    private func drop(reason: String, report: Bool) {
        epoch += 1
        let old = link
        link = nil
        old?.invalidate()
        // Whatever was generating on the old connection is cancelled by the Gateway and its
        // remaining output is gone, so the chat consumer must not wait for it.
        if old != nil { chatContinuation.yield(.connectionLost) }
        // Reported only when a working connection was actually lost, and only once per outage.
        if report, old != nil, !reportedDown {
            reportedDown = true
            continuation.yield(.disconnected(reason: reason))
        }
    }

    // MARK: Events

    /// A pushed batch from the connection of `batchEpoch`.
    fileprivate func receive(_ batch: GatewayEventBatch, epoch batchEpoch: Int) {
        // From a connection that was replaced or dropped: its statuses may be out of date.
        guard batchEpoch == epoch else { return }
        guard batch.version == GatewayConstants.protocolVersion, batch.sequence == lastSequence + 1 else {
            // Lost or reordered output. Status events are snapshots, so reconnecting repairs it.
            drop(reason: "A Gateway event was lost; reconnecting.", report: true)
            return
        }
        lastSequence = batch.sequence
        for event in batch.events {
            // `.unknown` events come from a newer Gateway and are skipped.
            switch event {
            case .status(let status):
                continuation.yield(.status(status))
            case .chatDelta(let id, let text, let usedTokens):
                chatContinuation.yield(.delta(requestID: id, text: text, usedTokens: usedTokens))
            case .chatFinished(let id, let transcript, let usedTokens):
                chatContinuation.yield(.finished(requestID: id, transcript: transcript, usedTokens: usedTokens))
            case .chatFailed(let id, let failure):
                chatContinuation.yield(.failed(requestID: id, failure: failure))
            case .unknown:
                break
            }
        }
    }

    /// The transport could not decode a batch from the connection of `brokenEpoch`.
    fileprivate func receiveBroken(epoch brokenEpoch: Int) {
        guard brokenEpoch == epoch else { return }
        drop(reason: "A Gateway event could not be read; reconnecting.", report: true)
    }

    /// What the connector calls for one connection. It stamps every callback with the epoch
    /// of that connection, so the client can tell a current callback from a stale one.
    private final class EventRelay: GatewayClientEventReceiving, @unchecked Sendable {
        // Safe: both are immutable `let`s; the actor reference is Sendable. Weak, because the
        // connection retains this relay as part of its exported object and the client retains
        // the connection.
        private weak let client: GatewayClient?
        private let epoch: Int

        init(client: GatewayClient, epoch: Int) {
            self.client = client
            self.epoch = epoch
        }

        func deliver(_ batch: GatewayEventBatch) async { await client?.receive(batch, epoch: epoch) }
        func protocolBroken() async { await client?.receiveBroken(epoch: epoch) }
    }

    // MARK: Heartbeat and reconnect

    /// One round of the loop: reconnect when down, ping when up. Returns how long to pause
    /// before the next round, or nil once the client is stopped.
    private func maintainStep() async -> Duration? {
        guard !stopped else { return nil }
        if link == nil {
            do { _ = try await ensureConnected() } catch {
                // Say why once; the following failed attempts stay silent until it connects.
                if !reportedDown, !stopped {
                    reportedDown = true
                    continuation.yield(.disconnected(reason: error.localizedDescription))
                }
            }
        } else {
            let current = epoch
            // A transport failure has already dropped the connection inside `exchange`.
            if let reply = try? await exchange(.ping, id: UUID(), epoch: current, timeout: policy.pingTimeout),
               reply != .pong {
                drop(epoch: current, reason: "Unexpected heartbeat reply from the Gateway.")
            }
        }
        // Down: try again soon. Up: next heartbeat.
        return link == nil ? policy.retryInterval : policy.pingInterval
    }

    // MARK: Decoding

    /// Mirrors `GatewayRequestHandler.handle`: read the version alone first, because a reply
    /// from another protocol version need not decode as this build's envelope.
    private static func decodeReply(_ data: Data) throws -> GatewayReply {
        struct VersionProbe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            throw GatewayError.remote("The Gateway sent a reply that could not be read.")
        }
        // A protocol 1 Gateway answers a v2 request with a v1-shaped failure; its version is the
        // useful part.
        guard probe.version == GatewayConstants.protocolVersion else {
            throw GatewayError.unsupportedProtocol(probe.version)
        }
        return try GatewayWire.decoder.decode(GatewayReplyEnvelope.self, from: data).reply
    }

    /// Maps a typed refusal back to the error the UI already knows how to show.
    private static func error(for failure: GatewayFailure) -> GatewayError {
        switch failure.kind {
        case .alreadyRunning: .alreadyRunning
        case .invalidConfig: .invalidConfig(failure.message)
        // Includes kinds a newer Gateway may add: its own message is the best text available.
        default: .remote(failure.message)
        }
    }
}

// MARK: XPC

/// Connects to the Gateway's mach service and exports the event sink on the same connection.
struct XPCGatewayConnector: GatewayConnecting {
    var machServiceName = GatewayConstants.machServiceName

    func connect(
        events: any GatewayClientEventReceiving, onTermination: @escaping @Sendable () -> Void
    ) async throws -> any GatewayLink {
        let connection = NSXPCConnection(machServiceName: machServiceName)
        // One connection, two directions: requests go out through the remote interface, and
        // the Gateway pushes events back into the exported object.
        connection.remoteObjectInterface = NSXPCInterface(with: GatewayXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: GatewayEventSinkXPC.self)
        connection.exportedObject = GatewayEventSinkAdapter(receiver: events)
        // Both handlers mean the Gateway is gone as far as this connection is concerned.
        connection.interruptionHandler = { onTermination() }
        connection.invalidationHandler = { onTermination() }
        connection.resume()
        // Nothing has reached the Gateway yet: launchd starts it on the first message, so a
        // Gateway that is not installed only shows up as an error on the hello.
        return XPCGatewayLink(connection: connection)
    }
}

/// Gateway -> app: decodes a batch, hands it to the client, acks once it is processed.
// Safe: the only stored property is an immutable `let` of a Sendable type; NSObject is only for @objc.
final class GatewayEventSinkAdapter: NSObject, GatewayEventSinkXPC, @unchecked Sendable {
    private let receiver: any GatewayClientEventReceiving

    init(receiver: any GatewayClientEventReceiving) { self.receiver = receiver }

    func deliver(_ batch: Data, ack: @escaping @Sendable () -> Void) {
        let receiver = receiver
        Task {
            if let decoded = try? GatewayWire.decoder.decode(GatewayEventBatch.self, from: batch) {
                await receiver.deliver(decoded)
            } else {
                await receiver.protocolBroken()
            }
            // Acked either way and only after processing: the Gateway holds its next batch
            // until this, and an unreadable one must not make it wait for the ack timeout.
            ack()
        }
    }
}

// Safe: `connection` is a `let` (NSXPCConnection is thread-safe).
private final class XPCGatewayLink: GatewayLink, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(connection: NSXPCConnection) { self.connection = connection }

    // A link released without `invalidate()` (its client went away) must not leave the
    // connection, and the Gateway's subscription behind it, open.
    deinit { connection.invalidate() }

    func send(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // The reply block and the error handler can both run: resume exactly once.
            let once = OnceResumer(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.resume(throwing: $0) }
            guard let gateway = proxy as? any GatewayXPCProtocol else {
                // Cannot happen with the interface set in `connect`, but the continuation must
                // be resumed on every path.
                once.resume(throwing: GatewayError.gatewayUnavailable(""))
                return
            }
            gateway.send(request) { once.resume(returning: $0) }
        }
    }

    func invalidate() { connection.invalidate() }
}
#endif
