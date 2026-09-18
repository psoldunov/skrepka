/// Something the Settings window asks the daemon to do.
///
/// A value rather than a method call, for two reasons. The window marks it as
/// in flight the moment it is sent — a switch keeps the position the user put
/// it in, a button stays disabled — and clears it when the matching
/// ``SyncEvent/finished(_:_:refreshed:)`` arrives, so the two have to be
/// comparable. And ``SyncModel`` can ask for one as a consequence of another
/// without reaching for the daemon itself.
///
/// Devices are named by their full hex ID throughout. The daemon also accepts
/// a fingerprint or a prefix, which is right for a person typing and wrong for
/// a window that already knows exactly which device it means.
public enum SyncAction: Sendable, Hashable {
    /// Accept pairing dials for the daemon's default window.
    case openPairingWindow
    case closePairingWindow
    /// Dial a device on the network to pair with it.
    case pair(deviceID: String)
    /// Answer the proposal waiting for this device — after the user compared
    /// the code, or declined to.
    case answer(deviceID: String, accept: Bool)
    case unpair(deviceID: String)
    case setLivePush(deviceID: String, isOn: Bool)
    case syncNow
}
