import Foundation

/// One change to what is visible on the local network.
///
/// A stream of changes rather than a snapshot of a set, because that is the
/// shape all three responders produce: `NWBrowser` reports
/// `NWBrowser.Result.Change` values, avahi's `ServiceBrowser` emits
/// `ItemNew`/`ItemRemove` signals, and a vendored mDNS responder sees
/// individual PTR records arrive and expire. A snapshot would make each
/// conformance rebuild a set it was never given.
public enum DiscoveryEvent: Sendable, Hashable {
    /// A peer became visible.
    case appeared(DiscoveredPeer)

    /// A peer that was already visible changed — in practice its TXT record.
    /// Same instance name, new contents.
    case changed(DiscoveredPeer)

    /// A peer stopped being visible: it withdrew its record, or the record
    /// expired.
    case disappeared(DiscoveredPeer)

    /// The browse is running and peers can arrive. Sent on the first success
    /// and again after every ``stalled(_:)`` the browse recovers from, which is
    /// what lets a caller take a "waiting for the local network" message back
    /// down again.
    case ready

    /// The browse cannot run at the moment, and is expected to recover by
    /// itself. Not the end of the stream: keep listening, and expect a
    /// ``ready`` when it comes back.
    ///
    /// `NWBrowser` sits here while there is no connectivity and, on macOS 15
    /// and later, while Local Network access has not been granted — neither of
    /// which is a failure the caller can do anything about except say so.
    case stalled(DiscoveryError)

    /// The browse failed and will not recover. **Terminal**: the stream
    /// finishes immediately after this, and a caller that wants to keep looking
    /// has to start a new browse.
    ///
    /// Terminal because the backends say so rather than as a convention.
    /// browser.h:68-72 on `nw_browser_state_failed`: "The browser has
    /// irrecoverably failed. You should not try to call nw_browser_start() on
    /// the browser to restart it. Instead, cancel the browser and create a new
    /// browser object."
    case failed(DiscoveryError)
}
