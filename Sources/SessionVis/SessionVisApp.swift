import SwiftUI
import AppKit
import SessionVisCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // SIGTERM/SIGINT (kill, Ctrl-C) skip applicationWillTerminate; remove the hook marker on those too.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { HookSnippet.removeMarker(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
    }

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

@main
struct SessionVisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        raiseOpenFileLimit()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)   // dark-only
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 500)
                .task { await model.handleLaunch() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }.keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button(model.listCollapsed ? "Show Session List" : "Collapse Session List") { model.listCollapsed.toggle() }
                    .keyboardShortcut("l")
            }
        }
        Settings {
            SettingsSheet(model: model)
        }
    }
}
