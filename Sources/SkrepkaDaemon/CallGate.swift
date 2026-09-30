import Logging

/// Holds the calls that reach the daemon between claiming its bus name and
/// exporting the object that answers them, and hands them over, in order, once
/// that object exists.
///
/// ## The gap this closes
///
/// ``DaemonRunner`` claims ``SkrepkaIPC/SkrepkaInterface/busName`` before it
/// builds anything, so that a second `skrepkad` loses before it opens the
/// store; the object that answers calls routes them to the daemon, so it can
/// only be exported after. The name is owned for that whole interval, and the
/// bus routes calls to a name's owner the moment it has one.
///
/// That interval is exactly when the first calls arrive. At login the tray app
/// starts beside the daemon, and its first calls are what D-Bus activation
/// starts the daemon *for*: the bus queues them and delivers them as soon as
/// the name is claimed. With no handler on the connection yet, `DBusClient`
/// logged `No handler set for message without replyTo` and dropped each one —
/// no reply and no error — so the caller waited out its whole timeout, and the
/// tray reported the service as not running until the app was relaunched.
///
/// So a gate is the connection's message handler from before `RequestName` goes
/// out. It holds what arrives, delivers it once ``open(_:)`` names the
/// receiver, and passes every later call straight through.
///
/// Generic over the call only so it can be tested: a `DBusMessage` has no
/// public initialiser, so a test cannot build one to hold.
public actor CallGate<Call: Sendable> {
    public typealias Receiver = @Sendable (Call) async -> Void

    /// How many calls are held before more are dropped.
    ///
    /// A bound rather than none because the gate holds whatever arrives for as
    /// long as bring-up takes. A handful of clients each make a handful of
    /// calls at login; a queue this long is a client looping, and dropping its
    /// calls is what happened to every call before the gate existed.
    public static var defaultCapacity: Int { 256 }

    private let capacity: Int
    private let logger: Logger
    private var held: [Call] = []
    private var receiver: Receiver?
    private var isOpening = false

    public init(capacity: Int = defaultCapacity, logger: Logger = Logger(label: "skrepka.daemon")) {
        self.capacity = capacity
        self.logger = logger
    }

    /// Delivers `call` if the gate is open and holds it if not.
    public func receive(_ call: Call) async {
        if let receiver {
            await receiver(call)
            return
        }
        guard held.count < capacity else {
            logger.warning(
                "dropped a call that arrived before the interface was exported",
                metadata: ["held": .stringConvertible(held.count)]
            )
            return
        }
        held.append(call)
    }

    /// Delivers everything held to `receiver` in the order it arrived, then
    /// passes every later call straight to it. Only the first call counts.
    ///
    /// The receiver is installed only once the queue is empty. A call that
    /// lands while an earlier one is being delivered — this actor is free to
    /// take it at every `await` below — is appended behind the rest rather
    /// than overtaking them, so the order the bus delivered in is the order
    /// the calls are answered in.
    public func open(_ receiver: @escaping Receiver) async {
        guard self.receiver == nil, !isOpening else { return }
        isOpening = true
        while !held.isEmpty {
            await receiver(held.removeFirst())
        }
        self.receiver = receiver
        isOpening = false
    }
}
