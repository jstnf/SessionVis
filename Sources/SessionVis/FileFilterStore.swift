import Foundation
import SessionVisCore

/// Hidden-file rules per watched directory, kept in UserDefaults as one JSON dictionary keyed by the normalised path.
/// An entry that cannot be read loads as no rules and leaves the other directories' rules alone.
@MainActor
struct FileFilterStore {
    static let key = "fileFilters"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func filter(for directory: String) -> FileFilter {
        load()[PathFolder.normalize(directory)] ?? FileFilter()
    }

    func save(_ filter: FileFilter, for directory: String) {
        var all = load()
        let key = PathFolder.normalize(directory)
        if filter.rules.isEmpty { all.removeValue(forKey: key) } else { all[key] = filter }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }

    private func load() -> [String: FileFilter] {
        guard let data = defaults.data(forKey: Self.key),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        let decoder = JSONDecoder()
        return raw.compactMapValues { entry in
            guard JSONSerialization.isValidJSONObject(entry),
                  let bytes = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? decoder.decode(FileFilter.self, from: bytes)
        }
    }
}
