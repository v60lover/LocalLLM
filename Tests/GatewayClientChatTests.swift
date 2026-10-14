import Foundation
import XCTest
@testable import LocalLLMChat

// The chat half of `GatewayClient`: starting and stopping a generation, and the stream its
// output arrives on. The Gateway is a scripted link that answers from a closure, so each test
// decides exactly what the Gateway says; time does not move (`SupervisorFakeClock`).

private struct ScriptedLinkGone: Error {}

/// A link that records what was sent and answers from a closure; `failNext` loses one reply.
private final class ScriptedLink: GatewayLink, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: @Sendable (GatewayRequestEnvelope) -> GatewayReply
    private var _sent: [GatewayRequestEnvelope] = []
    private var loseNextMutating = false
    private var _invalidated = false

    init(reply: @escaping @Sendable (GatewayRequestEnvelope) -> GatewayReply) { self.reply = reply }

    var sent: [GatewayRequestEnvelope] { lock.withLock { _sent } }
    var isInvalidated: Bool { lock.withLock { _invalidated } }
    func loseTheNextMutatingReply() { lock.withLock { loseNextMutating = true } }

    func send(_ request: Data) async throws -> Data {
        let envelope = try GatewayWire.decoder.decode(GatewayRequestEnvelope.self, from: request)
        let lose = lock.withLock { () -> Bool in
            if _invalidated { return true }
            _sent.append(envelope)
            defer { if envelope.request.isMutating { loseNextMutating = false } }
            return loseNextMutating && envelope.request.isMutating
        }
        if lose { throw ScriptedLinkGone() }
        return try GatewayWire.encoder.encode(GatewayReplyEnvelope(reply: reply(envelope)))
    }

    func invalidate() { lock.withLock { _invalidated = true } }
}

private final class ScriptedConnector: GatewayConnecting, @unchecked Sendable {
    struct Connection {
        var link: ScriptedLink
        var receiver: any GatewayClientEventReceiving
        var terminate: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var _connections: [Connection] = []
    private let reply: @Sendable (GatewayRequestEnvelope) -> GatewayReply

    init(reply: @escaping @Sendable (GatewayRequestEnvelope) -> GatewayReply) { self.reply = reply }

    var connections: [Connection] { lock.withLock { _connections } }
    var last: Connection { connections[connections.count - 1] }

    func connect(
        events: any GatewayClientEventReceiving, onTermination: @escaping @Sendable () -> Void
    ) async throws -> any GatewayLink {
        let link = ScriptedLink(reply: reply)
        lock.withLock { _connections.append(Connection(link: link, receiver: events, terminate: onTermination)) }
        return link
    }
}

/// Collects the chat stream so a test can wait on it.
private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _signals: [GatewayChatSignal] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<GatewayChatSignal>) {
        task = Task { [weak self] in
            for await signal in stream { self?.lock.withLock { self?._signals.append(signal) } }
        }
    }

    deinit { task?.cancel() }

    var signals: [GatewayChatSignal] { lock.withLock { _signals } }
}

final class GatewayClientChatTests: XCTestCase {
    private let instance = UUID()
    private let policy = GatewayClientPolicy(
        connectTimeout: .seconds(11), requestTimeout: .seconds(13), pingInterval: .seconds(5),
        pingTimeout: .seconds(7), retryInterval: .seconds(2), recoveryPolls: 2, recoveryPollInterval: .seconds(1)
    )

    private struct Rig {
        var client: GatewayClient
        var connector: ScriptedConnector
        var recorder: SignalRecorder
    }

    /// `answer` decides the reply to everything except `hello`, which always succeeds.
    private func makeRig(
        answer: @escaping @Sendable (GatewayRequest) -> GatewayReply = { _ in .accepted }
    ) -> Rig {
        let instance = instance
        let connector = ScriptedConnector { envelope in
            switch envelope.request {
            case .hello(let version): .hello(version: version, instanceID: instance)
            case .ping: .pong
            default: answer(envelope.request)
            }
        }
        let client = GatewayClient(connector: connector, clock: SupervisorFakeClock(), policy: policy)
        return Rig(client: client, connector: connector, recorder: SignalRecorder(client.chatSignals))
    }

    private func pollUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), message)
    }

    private let request = ChatGenerateRequest(
        model: testModel, prompt: "hi", instructions: nil, transcript: nil,
        maximumResponseTokens: nil
    )

    /// The generation ID is the envelope's request ID, because the events carry it back. A client
    /// that invented its own ID would never match a reply to its output.
    func testGenerateSendsTheCallersIDAndReturnsNilWhenAccepted() async throws {
        let rig = makeRig()
        let id = UUID()
        let refusal = try await rig.client.generate(request, id: id)
        XCTAssertNil(refusal)
        let sent = rig.connector.last.link.sent
        XCTAssertEqual(sent.last?.requestID, id)
        XCTAssertEqual(sent.last?.request, .chatGenerate(request))
    }

    /// A typed refusal is an answer the caller branches on (model not downloaded), not a
    /// transport error.
    func testARefusalIsReturnedNotThrown() async throws {
        let failure = GatewayFailure(kind: .modelNotDownloaded, message: "not here")
        let rig = makeRig { _ in .failure(failure) }
        let refusal = try await rig.client.generate(request, id: UUID())
        XCTAssertEqual(refusal, failure)
    }

    /// Stop is a request of its own and names the generation it targets.
    func testCancelSendsTheTargetID() async throws {
        let rig = makeRig()
        let target = UUID()
        try await rig.client.cancel(target)
        XCTAssertEqual(rig.connector.last.link.sent.last?.request, .chatCancel(target: target))
    }

    /// Deltas, the end of a reply and a failure all reach the consumer in the order they were
    /// pushed, with an event type from a newer Gateway skipped between them.
    func testChatEventsReachTheStreamInOrder() async throws {
        let rig = makeRig()
        _ = try await rig.client.generate(request, id: UUID())
        let id = UUID()
        let failure = GatewayFailure(kind: .cancelled, message: "Stopped.")
        await rig.connector.last.receiver.deliver(GatewayEventBatch(sequence: 0, events: [
            .chatDelta(requestID: id, text: "Hel", usedTokens: nil),
            .unknown(type: "someFutureEvent"),
            .chatDelta(requestID: id, text: "lo", usedTokens: 7),
            .chatFinished(requestID: id, transcript: Data([1]), usedTokens: 9),
            .chatFailed(requestID: id, failure: failure),
        ]))
        try await pollUntil("all four signals") { rig.recorder.signals.count == 4 }
        XCTAssertEqual(rig.recorder.signals, [
            .delta(requestID: id, text: "Hel", usedTokens: nil),
            .delta(requestID: id, text: "lo", usedTokens: 7),
            .finished(requestID: id, transcript: Data([1]), usedTokens: 9),
            .failed(requestID: id, failure: failure),
        ])
    }

    /// A gap means deltas were lost, and unlike a status a delta cannot be repaired by reading
    /// the latest one. The consumer is told the generation is over and the text after the gap
    /// is not delivered.
    func testAGapInTheSequenceEndsGenerationsInFlight() async throws {
        let rig = makeRig()
        _ = try await rig.client.generate(request, id: UUID())
        let connection = rig.connector.last
        let id = UUID()
        await connection.receiver.deliver(GatewayEventBatch(sequence: 0, events: [
            .chatDelta(requestID: id, text: "a", usedTokens: nil),
        ]))
        await connection.receiver.deliver(GatewayEventBatch(sequence: 2, events: [
            .chatDelta(requestID: id, text: "AFTER-GAP", usedTokens: nil),
        ]))
        try await pollUntil("connection lost") { rig.recorder.signals.contains(.connectionLost) }
        XCTAssertEqual(rig.recorder.signals, [
            .delta(requestID: id, text: "a", usedTokens: nil), .connectionLost,
        ])
        XCTAssertTrue(connection.link.isInvalidated)
    }

    /// The Gateway going away (or being restarted by launchd) is the same event for the chat
    /// consumer: nothing more will arrive for what was running.
    func testAnInterruptedConnectionEndsGenerationsInFlight() async throws {
        let rig = makeRig()
        _ = try await rig.client.generate(request, id: UUID())
        rig.connector.last.terminate()
        try await pollUntil("connection lost") { rig.recorder.signals == [.connectionLost] }
    }

    /// A chat request is mutating: when its reply is lost the client asks what became of it and
    /// never sends it again, so one tap on Send cannot start two generations.
    func testALostReplyToGenerateIsNotSentAgain() async throws {
        let rig = makeRig { request in
            // The Gateway never heard of it: the connection died before the request arrived.
            if case .requestStatus = request { return .requestState(.unknown) }
            return .accepted
        }
        // Any accepted request opens the connection the next reply is lost on.
        try await rig.client.cancel(UUID())
        rig.connector.last.link.loseTheNextMutatingReply()
        do {
            _ = try await rig.client.generate(request, id: UUID())
            XCTFail("the outcome is unknown, so this must throw")
        } catch {
            XCTAssertEqual(error as? GatewayError, .connectionLost)
        }
        let generates = rig.connector.connections.flatMap(\.link.sent).filter {
            if case .chatGenerate = $0.request { true } else { false }
        }
        XCTAssertEqual(generates.count, 1)
    }
}
