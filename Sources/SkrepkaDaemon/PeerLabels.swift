import SkrepkaSync

/// What a paired device is called wherever the daemon names one to a person.
///
/// The Sync pane lists a peer by name, so a sentence about that peer — "paired
/// but not on the network right now: …" — has to use the same name. A
/// fingerprint is how `skrepka unpair` selects a device, not how anyone
/// recognises one.
enum PeerLabels {
    /// The name `deviceID` goes by, or nil when it never gave one.
    ///
    /// The name from `hello` outranks the one stored at pairing: that arrived
    /// inside the tunnel, from the device whose certificate is pinned, and it
    /// follows a rename. Sanitised either way — a pinned peer still chose its
    /// own name.
    static func name(
        of deviceID: SyncDeviceID,
        progress: [SyncDeviceID: PeerProgress],
        paired: PairedPeer?
    ) -> String? {
        SafeText.oneLine(
            ifPresent: progress[deviceID]?.name ?? paired?.deviceName,
            limit: SafeText.nameLimit
        )
    }

    /// One label per device in `deviceIDs`, sorted so a sentence built from
    /// them reads the same on every report.
    ///
    /// A device with no name goes by its fingerprint. Devices that share a
    /// name — two Macs both called "MacBook Pro" — each carry their fingerprint
    /// after it, or the sentence would list one device twice.
    static func labels(
        for deviceIDs: some Sequence<SyncDeviceID>,
        progress: [SyncDeviceID: PeerProgress],
        paired: [SyncDeviceID: PairedPeer]
    ) -> [String] {
        let named = deviceIDs.map { deviceID in
            let name = name(of: deviceID, progress: progress, paired: paired[deviceID])
            return (deviceID: deviceID, name: name?.isEmpty == false ? name : nil)
        }
        let uses = Dictionary(named.compactMap(\.name).map { ($0, 1) }, uniquingKeysWith: +)
        return named.map { entry in
            guard let name = entry.name else { return entry.deviceID.fingerprint }
            return uses[name, default: 0] > 1 ? "\(name) (\(entry.deviceID.fingerprint))" : name
        }
        .sorted()
    }
}
