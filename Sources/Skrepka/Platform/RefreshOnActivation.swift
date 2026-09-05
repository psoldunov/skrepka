import AppKit
import Combine
import SwiftUI

extension View {
    /// Runs `refresh` now, and again every time Skrepka comes forward.
    ///
    /// The shape every permission surface needs, and the reason it is one
    /// modifier rather than four copies. Permissions are granted in System
    /// Settings, so becoming active is the only moment one of these answers can
    /// have changed; and both the settings and welcome windows are cached and
    /// reused, so `onAppear` alone never fires a second time. Either half on its
    /// own is a stale tick on screen.
    func refreshOnActivation(_ refresh: @escaping () -> Void) -> some View {
        onAppear(perform: refresh)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                refresh()
            }
    }
}
