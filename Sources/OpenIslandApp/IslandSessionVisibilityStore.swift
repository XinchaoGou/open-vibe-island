import Foundation

struct HiddenIslandSession: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var hiddenAt: Date
}

struct IslandSessionVisibilityStore {
    private static let defaultsKey = "island.hiddenSessions"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [HiddenIslandSession] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([HiddenIslandSession].self, from: data) else {
            return []
        }
        return entries.sorted { $0.hiddenAt > $1.hiddenAt }
    }

    func save(_ entries: [HiddenIslandSession]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
