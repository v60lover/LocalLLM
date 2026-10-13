#if os(macOS)
import Foundation
import OSLog

// Pushed output, Gateway -> app. Nothing polls the status: the Gateway sends it whenever it
// changes. The pieces, from the wire inwards:
//   GatewayEventSinkXPC    the Objective-C method the app exports on its connection
//   GatewayEvent / Batch   what travels through it
//   GatewayEventQueue      pure per-subscriber queue: latest status only, one batch in flight
//   GatewayEventPublisher  reads the status on every change and feeds each subscriber's queue
// The request/reply direction lives in `GatewayIPC.swift`.

/// Gateway -> app. Exported by the client on its connection; the Gateway must not send the next
/// batch until `ack` has been called, which bounds what a slow or hung app can make it hold.
@objc protocol GatewayEventSinkXPC {
    /// `batch` is a JSON `GatewayEventBatch`.
    func deliver(_ batch: Data, ack: @escaping @Sendable () -> Void)
}

/// A pushed event. Encoded with an explicit `type` so a newer Gateway can add event types an
/// older app skips (`.unknown`) instead of failing to decode the whole batch.
enum GatewayEvent: Codable, Equatable, Sendable {
    case status(GatewayStatus)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey { case type, status }

    // Hand-written on purpose: the synthesized decoder throws on a case it does not know, and
    // one unknown event would then cost the app every event in the same batch.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "status": self = .status(try container.decode(GatewayStatus.self, forKey: .status))
        default: self = .unknown(type: type)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let status):
            try container.encode("status", forKey: .type)
            try container.encode(status, forKey: .status)
        case .unknown(let type):
            // Only the type survives a round trip; the payload was never decoded.
            try container.encode(type, forKey: .type)
        }
    }
}

/// What one `deliver` call carries.
struct GatewayEventBatch: Codable, Equatable, Sendable {
    var version = GatewayConstants.protocolVersion
    /// Strictly increasing per connection, so the receiver can detect loss or reordering.
    var sequence: Int
    var events: [GatewayEvent]
}

/// Pure outbound queue for one subscriber. Status events are snapshots, so only the latest one
/// is kept; together with a single batch in flight that bounds memory per subscriber at a
/// constant, however fast the state changes. The transport calls `acknowledge()` on the ack.
struct GatewayEventQueue: Sendable {
    /// The one status waiting to be sent; a newer one replaces it.
    private var pendingStatus: GatewayStatus?
    /// A batch was handed out and its ack has not come back yet.
    private var inFlight = false
    private var nextSequence = 0

    var isIdle: Bool { pendingStatus == nil && !inFlight }
    var hasPending: Bool { pendingStatus != nil }
    var isInFlight: Bool { inFlight }

    /// Overwrites whatever was waiting: once a newer snapshot exists the older one is useless.
    mutating func enqueue(status: GatewayStatus) { pendingStatus = status }

    /// The next batch to send, or nil when nothing is pending or the previous batch is unacked.
    mutating func takeBatch() -> GatewayEventBatch? {
        guard !inFlight, let status = pendingStatus else { return nil }
        // The sequence only advances for a batch that is actually handed out, so the receiver
        // sees no gaps for statuses that were replaced while waiting.
        defer { pendingStatus = nil; inFlight = true; nextSequence += 1 }
        return GatewayEventBatch(sequence: nextSequence, events: [.status(status)])
    }

    /// The app confirmed the batch in flight; the next one may go.
    mutating func acknowledge() { inFlight = false }
}

/// Delivers one batch to one app connection and returns once the app acknowledged it. Throws
/// when the connection is gone or the ack did not come in time; the publisher then drops the
/// subscriber.
protocol GatewayEventSending: Sendable {
    func deliver(_ batch: GatewayEventBatch) async throws
    /// Called when the subscriber is dropped; closes the connection it belongs to.
    func invalidate()
}

/// Told by the engine that its state changed. Synchronous and cheap: it must not block the engine.
protocol GatewayChangeObserver: Sendable {
    func gatewayDidChange()
}

/// Forwards engine changes to an observer attached after construction (the engine and the
/// publisher need each other).
// Safe: `target` is only accessed under `lock`.
final class GatewayChangeRelay: GatewayChangeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var target: (any GatewayChangeObserver)?

    func attach(_ observer: any GatewayChangeObserver) { lock.withLock { target = observer } }

    func gatewayDidChange() {
        // Copy under the lock, call after it: no callback runs while the lock is held.
        let observer = lock.withLock { target }
        observer?.gatewayDidChange()
    }
}

/// Fans the current status out to every subscribed connection.
///
/// `gatewayDidChange` only schedules a publish, and publishes never overlap: reading the status
/// suspends, so two overlapping publishes could enqueue their statuses in the wrong order. A
/// publish asked for while one is running makes that one read again instead, so the last status
/// enqueued is always the newest one read.
actor GatewayEventPublisher: GatewayChangeObserver {
    struct Policy: Sendable {
        /// How long an app gets to acknowledge a batch before it is considered hung.
        var ackTimeout: Duration = .seconds(10)
    }

    private struct Subscriber {
        var sink: any GatewayEventSending
        var queue = GatewayEventQueue()
        /// A pump task is running for this subscriber; guards against starting a second one.
        var pumping = false
    }

    private let source: GatewayStatusSource
    /// The suspending clock: an ack timeout must not expire just because the Mac slept.
    private let clock: any SupervisorClock
    private let policy: Policy
    private let log = Logger(subsystem: GatewayConstants.label, category: "events")
    /// Keyed by a per-connection ID the listener makes up. Bounded by the number of open app
    /// connections; an entry leaves on unsubscribe or on a missed ack.
    private var subscribers: [UUID: Subscriber] = [:]
    /// A publish is between its first read and its last enqueue (the single-flight gate).
    private var publishing = false
    /// Something changed while `publishing`; the running publish reads once more before it ends.
    private var publishAgain = false

    init(source: GatewayStatusSource, clock: any SupervisorClock = SystemSupervisorClock(), policy: Policy = Policy()) {
        self.source = source
        self.clock = clock
        self.policy = policy
    }

    var subscriberCount: Int { subscribers.count }

    /// A publish is reading the status or enqueueing it.
    var isPublishing: Bool { publishing }

    /// Nothing is being read, queued or awaiting an ack.
    var isIdle: Bool {
        !publishing && subscribers.values.allSatisfy { !$0.pumping && $0.queue.isIdle }
    }

    /// Registers a connection and pushes the current status to it right away.
    func subscribe(_ id: UUID, sink: any GatewayEventSending) async {
        subscribers[id] = Subscriber(sink: sink)
        // Publishes to everyone, not only the newcomer: one code path, and for the others it is
        // at worst a repeat of the status they already have.
        await publishCurrent()
    }

    /// The connection is gone. A pump still running for it notices on its next step and stops.
    func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    // Nonisolated so the engine can call it synchronously from inside its own actor; the
    // actual work hops onto this actor in a task and never blocks the engine.
    nonisolated func gatewayDidChange() {
        Task { await publishCurrent() }
    }

    /// Reads the current status and queues it for every subscriber. Single-flight: a call that
    /// arrives while another is running returns at once and makes the running one read again.
    func publishCurrent() async {
        guard !publishing else {
            publishAgain = true
            return
        }
        publishing = true
        defer { publishing = false }
        repeat {
            publishAgain = false
            guard !subscribers.isEmpty else { return }
            // Suspension point: the engine can change and other publishes can be asked for
            // while this waits. They set `publishAgain`, which sends the loop round once more.
            let status = await source.current()
            // A snapshot of the keys: `pump` writes to `subscribers` while this iterates.
            for id in Array(subscribers.keys) {
                subscribers[id]?.queue.enqueue(status: status)
                pump(id)
            }
        } while publishAgain
    }

    /// At most one pump per subscriber: it sends the pending batch, waits for the ack, repeats.
    private func pump(_ id: UUID) {
        guard var subscriber = subscribers[id], !subscriber.pumping else { return }
        subscriber.pumping = true
        subscribers[id] = subscriber
        Task { [weak self] in await self?.runPump(id) }
    }

    private func runPump(_ id: UUID) async {
        // Re-read the subscriber on every round: it can be removed during any await below.
        while let subscriber = subscribers[id] {
            var queue = subscriber.queue
            guard let batch = queue.takeBatch() else { break }
            // Store the queue back before suspending, so a publish that lands meanwhile sees
            // the batch as in flight and only replaces the pending status.
            subscribers[id]?.queue = queue
            let sink = subscriber.sink
            let acknowledged: Bool
            do {
                // A hung app never calls back: race the ack against the timeout instead of
                // waiting on it, then drop the subscriber and its connection.
                acknowledged = try await raceTimeout(clock: clock, timeout: policy.ackTimeout) {
                    try await sink.deliver(batch)
                    return true
                } ?? false
            } catch {
                // The connection failed; treated like a missed ack.
                acknowledged = false
            }
            // Unsubscribed while the batch was in flight: nothing left to update.
            guard subscribers[id] != nil else { return }
            if acknowledged {
                subscribers[id]?.queue.acknowledge()
            } else {
                log.info("dropping an event subscriber that did not acknowledge in time")
                subscribers[id] = nil
                // Closing the connection is what tells the app: it sees an invalidation,
                // reconnects, and gets a fresh status on subscribing again.
                sink.invalidate()
                return
            }
        }
        // Nothing left to send. A later publish starts a new pump.
        subscribers[id]?.pumping = false
    }
}
#endif
