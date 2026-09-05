// AppKit-only: this is the `NSPasteboard` conformance of ``ClipboardSource``.
// Linux gets its own conformances in Phase 5 — two Wayland data-control
// backends and one X11 XFixes backend — so the file is excluded here rather
// than abstracted.
#if canImport(AppKit)

    import AppKit
    import Foundation

    /// The thin AppKit shim between `NSPasteboard` and the pure capture rules.
    ///
    /// `NSPasteboard` carries no `NS_SWIFT_UI_ACTOR` annotation in the macOS 26
    /// SDK (verified against `NSPasteboard.h`), so reading it off the main actor
    /// is sanctioned rather than merely tolerated.
    ///
    /// Polls: macOS declares no clipboard notification, so
    /// ``ClipboardSource/changeNotifications()`` keeps its default of nil and
    /// ``ClipboardWatcher`` runs its timer.
    public struct PasteboardReader: ClipboardSource {
        /// Types Skrepka pulls data for. Reading every declared type would drag in
        /// megabytes of private app formats for no benefit.
        static let interestingTypes: Set<String> = Set(PasteboardType.readOrder)

        public init() {}

        /// Current change counter. Cheap — a single IPC round-trip.
        public func changeCount() -> Int {
            NSPasteboard.general.changeCount
        }

        /// Freezes the general pasteboard into a value.
        ///
        /// Returns ``PasteboardRead/unreadable`` rather than an empty snapshot when
        /// the pasteboard yields no item at all, so a denied read is reportable
        /// instead of silent.
        public func read(sourceBundleID: String?) -> PasteboardRead {
            let pasteboard = NSPasteboard.general
            guard let item = pasteboard.pasteboardItems?.first else { return .unreadable }

            let declaredTypes = item.types.map(\.rawValue)
            // Check the markers before reading a single byte of content.
            guard !PrivacyMarkers.isRejected(types: declaredTypes) else {
                return .contents(
                    PasteboardSnapshot(
                        representations: [:],
                        declaredTypes: declaredTypes,
                        sourceBundleID: sourceBundleID
                    )
                )
            }

            var representations: [String: Data] = [:]
            for type in item.types where Self.interestingTypes.contains(type.rawValue) {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                representations[type.rawValue] = data
            }

            return .contents(
                PasteboardSnapshot(
                    representations: representations,
                    declaredTypes: declaredTypes,
                    sourceBundleID: sourceBundleID
                )
            )
        }

        /// The system's current policy for programmatic reads of the general
        /// pasteboard. Reading the policy does not itself count as an access.
        public func accessBehavior() -> PasteboardAccess {
            PasteboardAccess(NSPasteboard.general.accessBehavior)
        }

        /// Writes a marker and reads it straight back, which is what provokes the
        /// system's pasteboard access alert on a first run.
        ///
        /// - Returns: true when the marker came back intact — direct proof that
        ///   programmatic reads are allowed. The policy cannot answer this: an
        ///   "Allow Once" leaves `accessBehavior` reporting `.ask`.
        ///
        /// The round trip is Skrepka's own content, so nothing of the user's is
        /// touched to provoke the prompt. Callers must pause the watcher around it;
        /// otherwise the marker is captured as a history entry.
        public func probeAccess() -> Bool {
            let marker = "Skrepka is ready"
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(marker, forType: .string)
            return pasteboard.pasteboardItems?.first?.string(forType: .string) == marker
        }
    }

#endif
