import SwiftUI
import AppKit
import SessionVisCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created with the delegate so start-up never waits for a window to appear.
    let workspace = Workspace()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { await workspace.handleLaunch() }
        NSApp.activate(ignoringOtherApps: true)
        let candidates = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/AppIcon.icns"),
        ].compactMap { $0 }
        if let iconURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }), let image = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = image
        }
        // SIGTERM/SIGINT (kill, Ctrl-C) skip applicationWillTerminate; remove the hook marker on those too.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { HookSnippet.removeMarker(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
    }

    /// A Dock click with no window open brings the main window back.
    /// Closing the window leaves the app, its tabs, sessions and hook marker running; a Dock click brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    /// The hook command only spools while the marker exists.
    func applicationWillTerminate(_ notification: Notification) { HookSnippet.removeMarker() }
}

/// Raises the soft open-file limit to the hard limit (capped at OPEN_MAX): one vnode watcher per live transcript.
private func raiseOpenFileLimit() {
    var lim = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return }
    let target = min(lim.rlim_max, rlim_t(OPEN_MAX))
    guard lim.rlim_cur < target else { return }
    lim.rlim_cur = target
    _ = setrlimit(RLIMIT_NOFILE, &lim)
}

private struct MainWorkspaceKey: FocusedValueKey { typealias Value = Workspace }

extension FocusedValues {
    /// Set while the main window is key, so tab commands know the Settings window is not the target.
    var mainWorkspace: Workspace? {
        get { self[MainWorkspaceKey.self] }
        set { self[MainWorkspaceKey.self] = newValue }
    }
}

/// One always-enabled ⌘W item (a disabled item would still swallow the shortcut): Close Tab while the main window
/// is key and has a tab, otherwise the key window's own Close, so Settings still closes with ⌘W. ⌘⇧W closes the window.
private struct TabCloseCommands: View {
    @FocusedValue(\.mainWorkspace) private var workspace

    private var closesTab: Bool { !(workspace?.tabs.isEmpty ?? true) }

    var body: some View {
        Button(closesTab ? "Close Tab" : "Close") {
            if closesTab { workspace?.closeSelected() } else { NSApp.keyWindow?.performClose(nil) }
        }
        .keyboardShortcut("w")
        Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
            .keyboardShortcut("w", modifiers: [.command, .shift])
    }
}

@main
struct SessionVisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var workspace: Workspace { appDelegate.workspace }

    init() {
        raiseOpenFileLimit()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)   // dark-only
    }

    var body: some Scene {
        Window("SessionVis", id: "main") {
            ContentView(workspace: workspace)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: Constants.defaultWindowWidth, height: Constants.defaultWindowHeight)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab…") { workspace.presentOpenPanel(replacing: nil) }.keyboardShortcut("t")
                Button("Open in This Tab…") { workspace.presentOpenPanel(replacing: workspace.tabs.selectedID) }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                TabCloseCommands()
            }
            CommandGroup(after: .toolbar) {
                Button(workspace.selected?.listCollapsed == true ? "Show Session List" : "Collapse Session List") { workspace.selected?.listCollapsed.toggle() }
                    .keyboardShortcut("l")
                    .disabled(workspace.tabs.isEmpty)
                Button("Open Terminal") { if let m = workspace.selected, let id = m.selectedAgent { m.openTerminal(for: id) } }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!(workspace.selected?.canOpenSelectedTerminal ?? false))
                Toggle("Focus Mode", isOn: Binding(get: { workspace.selected?.focusMode ?? false }, set: { workspace.selected?.setFocusMode($0) }))
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(workspace.selected == nil)
                Divider()
                Button("Show Next Tab") { workspace.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Show Previous Tab") { workspace.selectPrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Move Tab Right") { workspace.moveSelected(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Move Tab Left") { workspace.moveSelected(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Tab \(n)") { workspace.select(index: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                        .disabled(n > workspace.tabs.entries.count)
                }
            }
            CommandMenu("Session") {
                Button("Follow Next Session") { workspace.selected?.followNext() }
                    .keyboardShortcut("]")
                    .disabled(!(workspace.selected?.hasLiveMain ?? false) || (workspace.selected?.isLoading ?? true))
                Button("Follow Previous Session") { workspace.selected?.followPrevious() }
                    .keyboardShortcut("[")
                    .disabled(!(workspace.selected?.hasLiveMain ?? false) || (workspace.selected?.isLoading ?? true))
                Divider()
                Button("Stop Following") { workspace.selected?.stopFollowing() }
                    .keyboardShortcut(".")
                    .disabled(!(workspace.selected?.isFollowing ?? false))
            }
        }
        Settings {
            SettingsSheet(workspace: workspace)
        }
    }
}
