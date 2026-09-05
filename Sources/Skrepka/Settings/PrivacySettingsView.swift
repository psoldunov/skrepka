import AppKit
import SkrepkaCore
import SwiftUI
import UniformTypeIdentifiers

/// The per-app exclusion list.
///
/// A backstop, not the main defence: Skrepka already skips anything carrying the
/// `org.nspasteboard.*` transient and concealed markers. Those are voluntary,
/// and not every password manager sets them.
struct PrivacySettingsView: View {
    let preferences: Preferences
    let onChange: () -> Void

    var body: some View {
        SettingsCard(title: "Always protected") {
            SettingsRow(
                title: "Password manager content",
                subtitle: "Anything marked transient or concealed is never recorded.",
                symbol: "lock.shield"
            ) {
                StatusIndicator(state: .good)
            }
        }

        SettingsCard(
            title: "Never record from",
            footer:
                "Add apps that do not mark their own content. Copies made while one of these is frontmost are ignored."
        ) {
            if preferences.excludedBundleIDs.isEmpty {
                ExclusionsEmptyState()
            } else {
                ForEach(Array(sortedExclusions.enumerated()), id: \.element) { index, bundleID in
                    if index > 0 {
                        SettingsRowSeparator()
                    }
                    ExcludedAppRow(bundleID: bundleID) { remove(bundleID) }
                }
            }

            SettingsRowSeparator()

            HStack(spacing: 8) {
                Button("Add App…", action: addApp)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                if !preferences.excludedBundleIDs.isEmpty {
                    Text(countLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
            .padding(.vertical, 10)
        }
    }

    private var countLabel: String {
        let count = preferences.excludedBundleIDs.count
        return count == 1 ? "1 app excluded" : "\(count) apps excluded"
    }

    private var sortedExclusions: [String] {
        preferences.excludedBundleIDs.sorted {
            displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending
        }
    }

    private func displayName(_ bundleID: String) -> String {
        AppNameCache.shared.displayName(forBundleID: bundleID) ?? bundleID
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"

        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !added.isEmpty else { return }
        preferences.excludedBundleIDs = preferences.excludedBundleIDs.union(added)
        onChange()
    }

    private func remove(_ bundleID: String) {
        preferences.excludedBundleIDs = preferences.excludedBundleIDs.subtracting([bundleID])
        onChange()
    }
}

/// One excluded app, removed by its own trailing button.
///
/// Checkboxes plus a separate Remove button were tried first; a per-row action
/// is one state fewer and one click fewer.
private struct ExcludedAppRow: View {
    let bundleID: String
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 11) {
            AppIconView(bundleID: bundleID)

            VStack(alignment: .leading, spacing: 1) {
                Text(AppNameCache.shared.displayName(forBundleID: bundleID) ?? bundleID)
                    .font(.system(size: 13))
                Text(bundleID)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isHovering ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop excluding \(bundleID)")
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

/// The app's real icon, so the list reads at a glance.
private struct AppIconView: View {
    let bundleID: String

    var body: some View {
        Group {
            if let icon = Self.icon(for: bundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
    }

    private static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct ExclusionsEmptyState: View {
    var body: some View {
        VStack(spacing: 5) {
            Text("No apps excluded")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Everything except password-manager content is recorded.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
