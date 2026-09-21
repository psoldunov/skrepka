import Foundation
import SkrepkaCore
import os

/// Opening the history store — split from ``AppCoordinator``, which is the
/// file every feature touches.
extension AppCoordinator {
    /// Opens the on-disk history, or says why it could not.
    ///
    /// Lifted out of `init` because it is the one part of construction with a
    /// decision in it, and because a failure here is a thing the user is told
    /// about rather than a crash.
    ///
    /// An in-memory store keeps the app usable rather than dead on launch. If
    /// even that fails, SwiftData itself is unusable and failing loudly beats
    /// limping on with a broken object graph.
    static func openStore(
        retention: RetentionPolicy
    ) -> (store: HistoryStore, storage: DiagnosticsSnapshot.Storage, startupError: String?) {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.soldunov.skrepka"
        do {
            let url = try HistoryStore.defaultStoreURL(bundleID: bundleID)
            return (
                try HistoryStore(location: url, retention: retention),
                .onDisk(path: url.path(percentEncoded: false)),
                nil
            )
        } catch {
            SkrepkaLog.store.error("Falling back to in-memory history: \(error.localizedDescription)")
            guard let fallback = try? HistoryStore(location: nil) else {
                fatalError("SwiftData could not create an in-memory store; Skrepka cannot run.")
            }
            return (
                fallback,
                .inMemory(reason: error.localizedDescription),
                """
                Skrepka could not open its history database, so this session will not be saved. \
                \(error.localizedDescription)
                """
            )
        }
    }
}
