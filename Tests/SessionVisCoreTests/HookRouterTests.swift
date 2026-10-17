import Foundation
import Testing
@testable import SessionVisCore

@Suite struct HookRouterTests {
    let main = PathFolder(root: "/repo", worktrees: [Worktree(name: "feat", path: "/wt/feat")])
    /// A worktree of `main` opened as its own tab: a cwd at its root belongs to both.
    let wt = PathFolder(root: "/wt/feat")
    let other = PathFolder(root: "/other")
    let a = UUID(), b = UUID(), c = UUID()
    let base = Date(timeIntervalSince1970: 4_000_000)

    var tabs: [(id: UUID, folder: PathFolder)] { [(a, main), (b, wt), (c, other)] }

    actor Collector {
        var events: [HookEvent] = []
        func add(_ e: HookEvent) { events.append(e) }
    }

    func spoolDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func write(_ dir: URL, _ name: String, cwd: String, mtime: Date) throws {
        let u = dir.appendingPathComponent(name)
        try #"{"session_id":"s1","hook_event_name":"Stop","cwd":"\#(cwd)"}"#.write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: u.path)
    }

    @Test func targetsFollowFolderMembershipInRegistrationOrder() {
        #expect(HookRouter.targets(for: "/repo", in: tabs) == [a])
        #expect(HookRouter.targets(for: "/wt/feat/Sources", in: tabs) == [a])
        #expect(HookRouter.targets(for: "/wt/feat", in: tabs) == [a, b])
        #expect(HookRouter.targets(for: "/repo/Sources", in: tabs) == [])   // a subdirectory is not a checkout root
        #expect(HookRouter.targets(for: "/elsewhere", in: tabs) == [])
        #expect(HookRouter.targets(for: nil, in: tabs) == [])
    }

    @Test func drainDeliversEachEventOnceToEveryMatchingTab() async throws {
        let d = try spoolDir()
        try write(d, "ev.1", cwd: "/wt/feat", mtime: base.addingTimeInterval(1))
        try write(d, "ev.2", cwd: "/other", mtime: base.addingTimeInterval(2))
        try write(d, "ev.3", cwd: "/nowhere", mtime: base.addingTimeInterval(3))
        try "{broken".write(to: d.appendingPathComponent("ev.4"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(4)], ofItemAtPath: d.appendingPathComponent("ev.4").path)
        let router = HookRouter(spoolDirectory: d, clock: { base.addingTimeInterval(10) })
        let ca = Collector(), cb = Collector(), cc = Collector()
        await router.register(a, folder: main) { e in await ca.add(e) }
        await router.register(b, folder: wt) { e in await cb.add(e) }
        await router.register(c, folder: other) { e in await cc.add(e) }
        await router.tick()
        #expect(await ca.events.map(\.cwd) == ["/wt/feat"])
        #expect(await cb.events.map(\.cwd) == ["/wt/feat"])
        #expect(await cc.events.map(\.cwd) == ["/other"])
        #expect(await router.lastSeenAt == base.addingTimeInterval(3))   // stamped even for an event nobody wanted
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path).isEmpty)
        await router.tick()
        #expect(await ca.events.count == 1)
    }

    @Test func setFolderAndUnregisterChangeRouting() async throws {
        let d = try spoolDir()
        let router = HookRouter(spoolDirectory: d, clock: { base.addingTimeInterval(10) })
        let ca = Collector()
        await router.register(a, folder: other) { e in await ca.add(e) }
        try write(d, "ev.1", cwd: "/repo", mtime: base)
        await router.tick()
        #expect(await ca.events.isEmpty)
        await router.setFolder(main, for: a)
        try write(d, "ev.2", cwd: "/repo", mtime: base.addingTimeInterval(1))
        await router.tick()
        #expect(await ca.events.count == 1)
        await router.unregister(a)
        try write(d, "ev.3", cwd: "/repo", mtime: base.addingTimeInterval(2))
        await router.tick()
        #expect(await ca.events.count == 1)
        #expect(await router.registeredCount == 0)
    }

    @Test func unregisterWithAnOldGenerationLeavesTheNewRegistration() async throws {
        let d = try spoolDir()
        let router = HookRouter(spoolDirectory: d, clock: { base.addingTimeInterval(10) })
        let c1 = Collector(), c2 = Collector()
        await router.register(a, generation: 1, folder: main) { e in await c1.add(e) }
        await router.register(a, generation: 2, folder: main) { e in await c2.add(e) }
        #expect(await router.registeredCount == 1)
        await router.unregister(a, generation: 1)
        #expect(await router.registeredCount == 1)
        try write(d, "ev.1", cwd: "/repo", mtime: base)
        await router.tick()
        #expect(await c1.events.isEmpty)
        #expect(await c2.events.count == 1)
        await router.unregister(a, generation: 2)
        #expect(await router.registeredCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func startedRouterCreatesTheDirectoryAndPicksUpAPayload() async throws {
        let d = try spoolDir()
        try FileManager.default.removeItem(at: d)
        let router = HookRouter(spoolDirectory: d)
        let ca = Collector()
        await router.register(a, folder: main) { e in await ca.add(e) }
        await router.start()
        #expect(FileManager.default.fileExists(atPath: d.path))
        try write(d, "ev.1", cwd: "/repo", mtime: Date().addingTimeInterval(-1))
        var waited = 0
        while await ca.events.isEmpty, waited < 60 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(await ca.events.count == 1)
        await router.stop()
        try? FileManager.default.removeItem(at: d)
    }

    @Test func payloadsForATabRegisteredBeforeItFinishesOpeningAreDelivered() async throws {
        let d = try spoolDir()
        try write(d, "ev.1", cwd: "/repo", mtime: base)
        let router = HookRouter(spoolDirectory: d, clock: { base.addingTimeInterval(10) })
        let ca = Collector()
        await router.register(c, folder: other) { _ in }
        // The tab registers at the start of its open, then drains happen while it is still loading.
        await router.register(a, generation: 1, folder: main) { e in await ca.add(e) }
        await router.tick()
        #expect(await ca.events.count == 1)
    }

    @Test func unregisteringAnOpenThatLostARaceRemovesItsRegistrationButNotANewerOne() async {
        let router = HookRouter(spoolDirectory: URL(fileURLWithPath: "/nonexistent-router"))
        await router.register(a, generation: 3, folder: main) { _ in }
        await router.unregister(a, generation: 3)
        #expect(await router.registeredCount == 0)
        await router.register(a, generation: 4, folder: main) { _ in }
        await router.unregister(a, generation: 3)
        #expect(await router.registeredCount == 1)
    }
}
