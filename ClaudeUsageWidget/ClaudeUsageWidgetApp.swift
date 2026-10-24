import SwiftUI
import Combine
import ServiceManagement

@main
struct ClaudeUsageWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore.shared
    @AppStorage(MenuBarKeys.enabled) private var showInMenuBar = false

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarPanel().environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Claude & Codex Usage", id: "settings") {
            ContentView()
        }
        // In menu bar mode, only show settings on launch until credentials are configured.
        .defaultLaunchBehavior(MenuBarMode.isEnabled && UsageStore.hasConfig ? .suppressed : .presented)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarEnabled = MenuBarMode.isEnabled

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(menuBarEnabled ? .accessory : .regular)
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuBarModeChanged() }
        }
    }

    // Hide the Dock icon while the menu bar item is shown, including when it is
    // removed by Command-dragging it out of the menu bar.
    @MainActor private func menuBarModeChanged() {
        let enabled = MenuBarMode.isEnabled
        guard enabled != menuBarEnabled else { return }
        menuBarEnabled = enabled
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if enabled { Task { await UsageStore.shared.refresh() } }
    }

    // SwiftUI otherwise quits once the last window closes, and the menu bar panel
    // counts as one: closing the panel or the settings window would quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    static var hasConfig: Bool { FileManager.default.fileExists(atPath: ConfigLocation.url.path) }

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false

    private init() {
        Task {
            while !Task.isCancelled {
                if MenuBarMode.isEnabled { await refresh() }
                try? await Task.sleep(for: .seconds(300))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                if MenuBarMode.isEnabled { await UsageStore.shared.refresh() }
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let config = (try? WidgetConfig.load()) ?? WidgetConfig()
        snapshot = await UsageClient.hostApp.fetch(config: config)
    }
}

extension UsageClient {
    /// The host app may read Claude Code's login from the Keychain and share it with the widget.
    static var hostApp: UsageClient { UsageClient(claudeCodeAuth: ClaudeCodeAuth(readsKeychain: true)) }
}

struct MenuBarPanel: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = store.snapshot {
                UsageDashboardView(snapshot: snapshot, large: true)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Divider()
            MenuBarSettingsView()
            Divider()
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            HStack {
                Button { Task { await store.refresh() } } label: {
                    Label(store.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                Button("Settings…") {
                    NSApp.activate()
                    openWindow(id: "settings")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .task {
            if let date = store.snapshot?.date, date.timeIntervalSinceNow > -60 { return }
            await store.refresh()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
