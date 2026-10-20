// Mac Android Subsystem - the look of the settings window, inspired by the Mac's
// System Settings: a searchable sidebar with Android's status and coloured icon
// tiles in groups, and a banner offering to restart Android when a setting that
// applies at start has changed.
//
// Licensed under the GNU General Public License v3 or later.

import SwiftUI

// MARK: - Sections

extension SettingsSection {
    /// Groups in the sidebar, like System Settings' clusters.
    static let groups: [[SettingsSection]] = [
        [.system, .performance],
        [.apps, .privacy, .files],
        [.storage, .advanced],
        [.about],
    ]

    var tint: Color {
        switch self {
        case .system: return Color(red: 0.20, green: 0.70, blue: 0.42)
        case .performance: return .orange
        case .apps: return .blue
        case .privacy: return .indigo
        case .files: return .cyan
        case .storage: return .gray
        case .advanced: return .purple
        case .about: return Color(white: 0.55)
        }
    }

    var tileSymbol: String {
        switch self {
        case .system: return "cpu.fill"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .apps: return "square.grid.2x2.fill"
        case .privacy: return "hand.raised.fill"
        case .files: return "folder.fill"
        case .storage: return "internaldrive.fill"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "Start Android, keep it ready in the background, and choose what happens when the last app closes."
        case .performance: return "How much of your Mac Android may use, and game controllers."
        case .apps: return "Your Android apps, installing apps and app stores."
        case .privacy: return "Which Android apps may use the camera, microphone, location and more."
        case .files: return "Share files between your Mac and Android."
        case .storage: return "Space Android uses on your Mac, and automatic clean-up."
        case .advanced: return "Developer mode, ADB, the Android image, logs and reset."
        case .about: return "Version, licences and acknowledgements."
        }
    }

    /// Extra words the sidebar search matches.
    var keywords: [String] {
        switch self {
        case .system: return ["start", "stop", "always ready", "login", "resources", "notifications", "status"]
        case .performance: return ["mode", "power saver", "smart", "standard", "gaming", "battery", "cpu", "cores", "memory", "ram", "controller", "gamepad"]
        case .apps: return ["install", "apk", "f-droid", "launcher", "uninstall", "keyboard", "density"]
        case .privacy: return ["permissions", "camera", "microphone", "location", "contacts"]
        case .files: return ["share", "transfer", "downloads", "folder"]
        case .storage: return ["disk", "space", "clean", "cache", "compact"]
        case .advanced: return ["developer", "adb", "image", "log", "reset", "screen", "debug"]
        case .about: return ["version", "license", "website", "github"]
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([title, subtitle] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

// MARK: - Icon tiles

/// A white symbol on a coloured rounded square, like System Settings' icons.
struct SettingsTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: size * 0.03, y: size * 0.02)
    }
}

/// The Android robot in a green circle: the subsystem's "account picture".
struct AndroidBadge: View {
    let state: Subsystem.State
    var size: CGFloat = 34

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.86, blue: 0.54), Color(red: 0.13, green: 0.62, blue: 0.40)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(nsImage: MenuBarIcon.image(style: MenuBarIcon.style(for: state), size: size * 0.62))
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .offset(y: size * 0.04)
            )
            .frame(width: size, height: size)
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @EnvironmentObject private var subsystem: Subsystem
    @Binding var selection: SettingsSection
    @State private var query = ""

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { selection = value } })) {
            if query.isEmpty {
                Section {
                    Button { selection = .system } label: { DeviceCard() }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                }
            }
            ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group) { section in
                        HStack(spacing: 8) {
                            SettingsTile(symbol: section.tileSymbol, tint: section.tint)
                            Text(section.title)
                        }
                        .padding(.vertical, 1)
                        .help(section.subtitle)
                        .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .onSubmit(of: .search) {
            if let first = filteredGroups.first?.first { selection = first }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    }

    private var filteredGroups: [[SettingsSection]] {
        SettingsSection.groups
            .map { $0.filter { $0.matches(query) } }
            .filter { !$0.isEmpty }
    }
}

/// Top of the sidebar: Android at a glance, with a one-click start or stop.
struct DeviceCard: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings

    var body: some View {
        HStack(spacing: 10) {
            AndroidBadge(state: subsystem.state)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 1, y: 1)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            powerButton
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// "Android 16" once Android has started, otherwise "Android".
    private var title: String {
        guard let version = subsystem.androidVersion,
              let release = version.split(separator: "·").first?.trimmingCharacters(in: .whitespaces),
              !release.isEmpty else { return "Android" }
        return release
    }

    private var status: String {
        switch subsystem.state {
        case .running:
            if let level = subsystem.performanceLevel, settings.performanceMode == .smart {
                return "Running · \(level.title)"
            }
            return "Running · \(settings.performanceMode.title)"
        case .starting: return "Starting…"
        case .stopping: return "Turning off…"
        case .failed: return "Stopped with an error"
        case .off: return "Off"
        case .notInstalled: return "Not set up"
        }
    }

    private var statusColor: Color {
        switch subsystem.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .off, .notInstalled: return .gray
        }
    }

    @ViewBuilder private var powerButton: some View {
        switch subsystem.state {
        case .off, .failed:
            Button { subsystem.start() } label: { Image(systemName: "power") }
                .help("Start Android")
                .buttonStyle(.borderless)
        case .running, .starting:
            Button { subsystem.stop() } label: { Image(systemName: "stop.circle") }
                .help("Turn off Android")
                .buttonStyle(.borderless)
        default:
            EmptyView()
        }
    }
}

// MARK: - Restart suggestion

/// Offers to restart Android after a setting that applies at start has changed.
struct RestartBanner: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings
    @State private var dismissedFor: [String] = []

    var body: some View {
        let changes = subsystem.changesNeedingRestart
        if !changes.isEmpty, changes != dismissedFor {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.white, Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart Android to apply your changes")
                        .font(.headline)
                    Text("Changes to \(Self.list(changes)) take effect when Android restarts. Open Android apps close while it restarts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Later") { dismissedFor = changes }
                Button("Restart Now") { subsystem.restart() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
