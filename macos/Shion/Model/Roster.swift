import Foundation
import Observation

/// Who leads and who Shion leaves out, chosen in Settings for one server and kept on this Mac.
nonisolated struct AssistantPrefs: Codable, Equatable, Sendable {
    /// The profile chosen as 总秘书; nil keeps the rule (`shion`, else the default profile).
    var chief: String?
    /// Profiles Shion does not show.
    var hidden: [String]
    /// Profiles this Mac has met on the server. Choices kept before this list was (nil) count
    /// every profile then there as met.
    var seen: [String]?
    /// Deleted profiles whose names Hermes has not finished cleaning up, with its command for it.
    var cleaning: [String: String]?

    init(chief: String? = nil, hidden: [String] = [], seen: [String]? = [], cleaning: [String: String]? = nil) {
        self.chief = chief
        self.hidden = hidden
        self.seen = seen
        self.cleaning = cleaning
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
    /// Hermes's clean-up of deleted names, run again now and then while connected.
    @ObservationIgnored var settler: Task<Void, Never>?
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
            // another server's pictures under the same profile names
            AvatarPictures.shared.clear()
            settler?.cancel()
            settler = nil
        }
        meet()
    }

    /// A profile this Mac meets for the first time starts shown or hidden as Bot Mode has it
    /// (`hidden` in its ui_meta); after that, this Mac's choice holds.
    private func meet() {
        let before = prefs.seen
        var seen = before ?? []
        for profile in profiles where !seen.contains(profile.name) {
            seen.append(profile.name)
            if before != nil, profile.botsMeta["hidden"]?.bool == true, !prefs.hidden.contains(profile.name) {
                prefs.hidden.append(profile.name)
            }
        }
        guard seen != before ?? [] || before == nil else { return }
        prefs.seen = seen
        write()
    }

    /// Names Hermes is still cleaning up after a delete, with its command for it.
    var cleaning: [String: String] { prefs.cleaning ?? [:] }

    func setCleaning(_ name: String, command: String?) {
        var names = prefs.cleaning ?? [:]
        names[name] = command
        prefs.cleaning = names.isEmpty ? nil : names
        write()
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
        prefs.seen?.removeAll { $0 == name }
        // gone from the list now, before it is read again: the clean-up's retry takes a name
        // still listed for one made again
        profiles.removeAll { $0.name == name }
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
