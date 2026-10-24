import SwiftUI
import Combine
import ServiceManagement

@main
struct ClaudeUsageWidgetApp: App {
    @StateObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel().environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Claude & Codex Usage", id: "settings") {
            ContentView()
        }
        // Menu bar app: only show settings on launch until credentials are configured.
        .defaultLaunchBehavior(UsageStore.hasConfig ? .suppressed : .presented)
    }
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
                await refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await UsageStore.shared.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let config = (try? WidgetConfig.load()) ?? WidgetConfig()
        snapshot = await UsageClient().fetch(config: config)
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(MenuBarKeys.style) private var style = MenuBarStyle.rings
    @AppStorage(MenuBarKeys.metrics) private var metrics = MenuBarMetrics.session
    @AppStorage(MenuBarKeys.showPercent) private var showPercent = true
    @AppStorage(MenuBarKeys.colored) private var colored = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = store.snapshot {
                UsageDashboardView(snapshot: snapshot, large: true)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Divider()
            Text("Menu bar").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Style", selection: $style) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Values", selection: $metrics) {
                ForEach(MenuBarMetrics.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Percent", isOn: $showPercent)
                Toggle("Colored", isOn: $colored)
            }
            .disabled(style == .text)
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
