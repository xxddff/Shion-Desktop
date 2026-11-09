import Foundation
import Observation

/// Who leads and who Shion leaves out, chosen in Settings for one server and kept on this Mac.
nonisolated struct AssistantPrefs: Codable, Equatable, Sendable {
    /// The profile chosen as 总秘书; nil keeps the rule (`shion`, else the default profile).
    var chief: String?
    /// Profiles Shion does not show.
    var hidden: [String]

    init(chief: String? = nil, hidden: [String] = []) {
        self.chief = chief
        self.hidden = hidden
    }
}

/// What 新建助手 asks for: the fields Hermes's `profiles.create` takes, and Bot Mode's title.
struct NewAssistant: Equatable {
    /// The profile's id.
    var name = ""
    var title = ""
    var description = ""
    var soul = ""
    /// The profile to copy; nil for a fresh one.
    var cloneFrom: String?
    /// nil: the copied profile's model, or the server's for a fresh one.
    var model: ModelChoice?
}

/// The server's profiles, and this Mac's choices about them for that server (Settings → 助手).
@Observable
final class Roster {
    /// Every profile, in the order `profiles.list` gave them.
    private(set) var profiles: [ProfileRow] = []
    /// The choices for the server the profiles came from.
    private(set) var prefs = AssistantPrefs()
    /// The hidden assistants, kept apart from the sidebar's so their names still show on what they
    /// left behind (an ask, a card).
    var hiddenBots: [Bot] = []
    /// The main window's 新建助手 sheet is up.
    var composing = false
    @ObservationIgnored private var server = ""
    @ObservationIgnored private let persist: Bool
    /// Screenshot and test runs keep their choices in memory.
    @ObservationIgnored private var memory: [String: AssistantPrefs] = [:]

    private static let key = "AssistantPrefs"

    init(persist: Bool) {
        self.persist = persist
    }

    func profile(_ name: String) -> ProfileRow? { profiles.first { $0.name == name } }

    /// `profiles.list`'s rows for `server` (its sign-in address, which keys the choices).
    func load(_ rows: [JSONValue], server: String) {
        profiles = rows.compactMap { ProfileRow($0) }
        if server != self.server {
            self.server = server
            prefs = read(server)
        }
    }

    /// 总秘书: the profile chosen in Settings while it is still there, else the one named `shion`,
    /// else the default profile, else the first.
    var chiefName: String {
        let names = profiles.map(\.name)
        if let chosen = prefs.chief, names.contains(chosen) { return chosen }
        if names.contains("shion") { return "shion" }
        return profiles.first(where: \.isDefault)?.name ?? names.first ?? ""
    }

    /// Whether Shion leaves this profile out; never 总秘书.
    func isHidden(_ name: String) -> Bool {
        name != chiefName && prefs.hidden.contains(name)
    }

    /// 总秘书 cannot be hidden, so choosing one shows it again.
    func setChief(_ name: String) {
        prefs.chief = name
        prefs.hidden.removeAll { $0 == name }
        write()
    }

    func setHidden(_ name: String, _ hidden: Bool) {
        prefs.hidden.removeAll { $0 == name }
        if hidden {
            prefs.hidden.append(name)
        }
        write()
    }

    /// A profile deleted on the server takes its choices with it.
    func forget(_ name: String) {
        if prefs.chief == name {
            prefs.chief = nil
        }
        prefs.hidden.removeAll { $0 == name }
        write()
    }

    private func read(_ server: String) -> AssistantPrefs {
        guard persist else { return memory[server] ?? AssistantPrefs() }
        return Self.stored()[server] ?? AssistantPrefs()
    }

    private func write() {
        guard !server.isEmpty else { return }
        guard persist else {
            memory[server] = prefs
            return
        }
        var all = Self.stored()
        all[server] = prefs
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static func stored() -> [String: AssistantPrefs] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: AssistantPrefs].self, from: data)
        else { return [:] }
        return all
    }
}
