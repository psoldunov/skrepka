import Foundation
import SkrepkaCore

/// Picks a clipboard backend for this session and starts it.
///
/// The one place the probe's decision becomes a running object. Everything
/// above it — the watcher, the capture rules, the store — sees a
/// ``SkrepkaCore/ClipboardSource`` and never learns which one.
public enum ClipboardBackend {
    /// A started backend, and what the probe found on the way to choosing it.
    public struct Running: Sendable {
        public let source: any ClipboardSource
        public let report: SessionProbe.Report

        /// Puts a payload on the clipboard, keyed by MIME target on Wayland and
        /// by selection-target name on X11 — which are the same strings for
        /// every target that matters, because X11 toolkits have advertised MIME
        /// type names as atoms for twenty years.
        public func setSelection(_ payload: [String: Data]?) async {
            switch source {
            case let reader as DataControlReader: await reader.setSelection(payload)
            case let reader as XFixesReader: await reader.setSelection(payload)
            default: break
            }
        }

        public func stop() async {
            switch source {
            case let reader as DataControlReader: await reader.stop()
            case let reader as XFixesReader: await reader.stop()
            default: break
            }
        }
    }

    public enum StartError: Error {
        /// The session offers nothing to watch. Carries the probe's finding, so
        /// the caller can say *which* nothing — GNOME without its extension
        /// reads very differently from Weston.
        case unsupportedSession(SessionProbe.Report)
        /// A backend was chosen and would not start. Carries the report too,
        /// because "which backend" is the first question about the message.
        case backendFailed(SessionProbe.Report, any Error)
    }

    /// Probes the session, starts the backend it implies, and returns both.
    ///
    /// Deliberately no fallback chain. If `ext-data-control-v1` is advertised
    /// and then fails, that is a compositor bug worth reporting rather than a
    /// reason to quietly capture less through XWayland — the phase plan's rule
    /// for the last branch of the decision table applies to every branch:
    /// report the failure, do not fall back to nothing.
    public static func start(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> Running {
        let report = SessionProbe().run(environment: environment)
        guard let backend = report.backend else { throw StartError.unsupportedSession(report) }

        do {
            switch backend {
            case .extDataControl, .wlrDataControl:
                // The name the probe connected to, not the one in this
                // process's environment — they are the same in production and
                // deliberately different under test.
                let reader = DataControlReader(backend, displayName: report.waylandDisplay)
                try await reader.start()
                return Running(source: reader, report: report)
            case .xFixes:
                let reader = XFixesReader(displayName: report.x11Display)
                try await reader.start()
                return Running(source: reader, report: report)
            }
        } catch {
            throw StartError.backendFailed(report, error)
        }
    }
}
