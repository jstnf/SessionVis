import Foundation

/// A replayed transcript shown in its own tab.
public struct ReplayRequest: Equatable, Sendable {
    public let transcript: String
    public let speed: Double
    public init(transcript: String, speed: Double) { self.transcript = transcript; self.speed = speed }
}

/// One tab: a watched directory, or a replay over one.
public struct TabEntry: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let directory: String
    public let replay: ReplayRequest?

    public init(id: UUID = UUID(), directory: String, replay: ReplayRequest? = nil) {
        self.id = id
        self.directory = PathFolder.canonical(directory)
        self.replay = replay
    }

    public var isReplay: Bool { replay != nil }
    public var name: String { (directory as NSString).lastPathComponent }
    /// A colour for the tab that survives reordering and relaunch.
    public var hueIndex: Int { Int(Geometry.stableHash(directory) % UInt64(HuePalette.count)) }
}

/// The ordered tabs and which one is selected. Live tabs are unique by directory; replay tabs are always their own entry.
public struct TabList: Equatable, Sendable {
    public private(set) var entries: [TabEntry] = []
    public private(set) var selectedID: UUID?

    public init() {}

    /// A selection that names no entry falls back to the first one.
    public init(entries: [TabEntry], selectedID: UUID?) {
        self.entries = entries
        self.selectedID = entries.contains { $0.id == selectedID } ? selectedID : entries.first?.id
    }

    public var selected: TabEntry? { selectedID.flatMap { id in entries.first { $0.id == id } } }
    public var isEmpty: Bool { entries.isEmpty }
    public func index(of id: UUID) -> Int? { entries.firstIndex { $0.id == id } }

    /// The live tab for a directory, if any.
    public func entry(forDirectory directory: String) -> TabEntry? {
        let d = PathFolder.canonical(directory)
        return entries.first { !$0.isReplay && PathFolder.canonical($0.directory) == d }
    }

    /// Re-spells a live tab's directory canonically, for a tab stored while its path was missing or dangling. When
    /// another live tab already has that canonical path, `id` is closed into it. Returns the surviving tab's id
    /// and whether the directory string changed (the caller restarts the session if so); nil for an unknown or replay tab.
    @discardableResult
    public mutating func recanonicalize(_ id: UUID) -> (id: UUID, changed: Bool)? {
        guard let i = index(of: id), !entries[i].isReplay else { return nil }
        let canonical = PathFolder.canonical(entries[i].directory)
        if let other = entries.first(where: { $0.id != id && !$0.isReplay && PathFolder.canonical($0.directory) == canonical }) {
            let wasSelected = selectedID == id
            close(id)
            if wasSelected { selectedID = other.id }
            return (other.id, true)
        }
        guard canonical != entries[i].directory else { return (id, false) }
        entries[i] = TabEntry(id: id, directory: canonical)
        return (id, true)
    }

    /// Selects the live tab for the directory, or appends one and selects it.
    @discardableResult
    public mutating func open(directory: String) -> UUID {
        if let e = entry(forDirectory: directory) {
            selectedID = e.id
            return e.id
        }
        let e = TabEntry(directory: directory)
        entries.append(e)
        selectedID = e.id
        return e.id
    }

    /// Opens the directory in place of the tab `id`: an existing live tab for it is selected and `id` closed;
    /// otherwise `id` is re-pointed at the directory, keeping its position and id (a replay tab becomes live).
    @discardableResult
    public mutating func open(directory: String, replacing id: UUID) -> UUID {
        guard let i = index(of: id) else { return open(directory: directory) }
        if let e = entry(forDirectory: directory) {
            if e.id != id { close(id) }
            selectedID = e.id
            return e.id
        }
        entries[i] = TabEntry(id: id, directory: directory)
        selectedID = id
        return id
    }

    @discardableResult
    public mutating func openReplay(directory: String, transcript: String, speed: Double) -> UUID {
        let e = TabEntry(directory: directory, replay: ReplayRequest(transcript: transcript, speed: speed))
        entries.append(e)
        selectedID = e.id
        return e.id
    }

    /// Removes the tab; a removed selection moves to the tab that followed it, else the one before it, else nothing.
    @discardableResult
    public mutating func close(_ id: UUID) -> Bool {
        guard let i = index(of: id) else { return false }
        entries.remove(at: i)
        if selectedID == id {
            selectedID = i < entries.count ? entries[i].id : entries.last?.id
        }
        return true
    }

    public mutating func select(_ id: UUID) {
        if index(of: id) != nil { selectedID = id }
    }

    public mutating func select(index: Int) {
        guard entries.indices.contains(index) else { return }
        selectedID = entries[index].id
    }

    public mutating func selectNext() { step(1) }
    public mutating func selectPrevious() { step(-1) }

    private mutating func step(_ by: Int) {
        guard !entries.isEmpty else { return }
        guard let sel = selectedID, let i = index(of: sel) else {
            selectedID = entries.first?.id
            return
        }
        selectedID = entries[(i + by + entries.count) % entries.count].id
    }

    /// Moves the tab by `offset` places, stopping at either end.
    public mutating func move(_ id: UUID, by offset: Int) {
        guard let i = index(of: id) else { return }
        let target = i.addingReportingOverflow(offset)
        let j = target.overflow ? (offset < 0 ? 0 : entries.count - 1) : max(0, min(entries.count - 1, target.partialValue))
        guard j != i else { return }
        let e = entries.remove(at: i)
        entries.insert(e, at: j)
    }
}

// MARK: - Persistence

extension TabList {
    public static let defaultsKey = "tabs"
    public static let formatVersion = 1

    private struct Persisted: Codable {
        struct Entry: Codable {
            var id: UUID
            var directory: String
        }
        var version: Int
        var selected: UUID?
        var tabs: [Entry]
    }

    /// The live tabs and, when it is one of them, the selection. nil when there is nothing to keep.
    public func encoded() -> Data? {
        let live = entries.filter { !$0.isReplay }
        guard !live.isEmpty else { return nil }
        let selected = live.contains { $0.id == selectedID } ? selectedID : nil
        let p = Persisted(version: Self.formatVersion, selected: selected, tabs: live.map { .init(id: $0.id, directory: $0.directory) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try? encoder.encode(p)
    }

    /// nil for missing or corrupt data, a version this build does not know, or no usable tab. Repeated ids or directories
    /// keep their first entry; a selection that names no entry falls to the first tab.
    public static func decode(_ data: Data?) -> TabList? {
        guard let data, let p = try? JSONDecoder().decode(Persisted.self, from: data), p.version == formatVersion else { return nil }
        var seenDirectories = Set<String>()
        var seenIDs = Set<UUID>()
        var entries: [TabEntry] = []
        for t in p.tabs where !t.directory.isEmpty {
            let e = TabEntry(id: t.id, directory: t.directory)
            guard !seenIDs.contains(e.id), seenDirectories.insert(e.directory).inserted else { continue }
            seenIDs.insert(e.id)
            entries.append(e)
        }
        guard !entries.isEmpty else { return nil }
        return TabList(entries: entries, selectedID: p.selected)
    }

    /// The list to start from when nothing is persisted: one tab for the directory the app last watched, or none.
    public static func migrated(lastDirectory: String?) -> TabList {
        var list = TabList()
        if let d = lastDirectory, !d.isEmpty { list.open(directory: d) }
        return list
    }
}

// MARK: - Launch

/// What the command line asks of the tab list at launch.
public enum LaunchAction: Equatable, Sendable {
    case replayNeedsDirectory
    case openReplay(directory: String, transcript: String, speed: Double)
    case open(directory: String)
    case restore
    case presentOpenPanel
}

extension TabList {
    public func launchAction(for options: LaunchOptions) -> LaunchAction {
        if let t = options.replayTranscript {
            guard let d = options.directory else { return .replayNeedsDirectory }
            return .openReplay(directory: d, transcript: t, speed: options.speed)
        }
        if let d = options.directory { return .open(directory: d) }
        return isEmpty ? .presentOpenPanel : .restore
    }
}
