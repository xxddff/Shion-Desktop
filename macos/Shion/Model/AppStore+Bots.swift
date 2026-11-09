import Foundation
import SwiftUI

/// The assistants as profiles: 总秘书 and who Shion shows (this Mac's choices, per server, in
/// `roster`), new and deleted assistants, and Bot Mode's titles. Every write names the profile it
/// is for; Shion never switches the server's active profile (`POST /api/profiles/active`), which
/// other clients go by.
extension AppStore {
    /// The sidebar's assistants from `profiles.list`'s rows: 总秘书 first (the one chosen in
    /// Settings, else `shion`, else the default profile), then the others in the server's order,
    /// less the ones hidden in Settings.
    func assistants(from rows: [JSONValue]) -> [Bot] {
        roster.load(rows, server: serverSettings.signInServer)
        return rosterBots()
    }

    private func rosterBots() -> [Bot] {
        let chief = roster.chiefName
        var shown: [Bot] = []
        var hidden: [Bot] = []
        for (index, profile) in roster.profiles.enumerated() {
            let leads = profile.name == chief
            let bot = Bot(
                id: profile.name,
                name: profile.shownName,
                title: leads ? "总秘书" : (profile.description.isEmpty ? profile.name : profile.description),
                chief: leads,
                hue: leads ? Palette.accent : Palette.hues[index % Palette.hues.count],
                status: .idle,
                statusNote: ""
            )
            if roster.isHidden(profile.name) {
                hidden.append(bot)
            } else {
                shown.append(bot)
            }
        }
        roster.hiddenBots = hidden
        return shown.filter { $0.chief } + shown.filter { !$0.chief }
    }

    /// The sidebar again after a choice or a new list, each assistant keeping its busy state.
    private func applyRoster() {
        let before = bots
        var after = rosterBots()
        for index in after.indices {
            if let old = before.first(where: { $0.id == after[index].id }) {
                after[index].status = old.status
                after[index].statusNote = old.statusNote
            }
        }
        bots = after
        if case .chat(let id)? = route, bot(id) == nil {
            route = .today
        }
        if case .botSettings(let id)? = route, bot(id) == nil {
            route = .today
        }
    }

    /// Settings: 总秘书. The shion plugin is called in her profile, so today, todos and reports
    /// load again from there, or go back to the demo where the plugin is not installed.
    func chooseChief(_ name: String) {
        guard live, name != chiefId, roster.profile(name) != nil else { return }
        roster.setChief(name)
        applyRoster()
        stopPluginData()
        Task { await loadPluginData() }
    }

    /// Settings: whether Shion shows this assistant. 总秘书 is always shown.
    func setShown(_ name: String, _ shown: Bool) {
        guard live, name != chiefId else { return }
        roster.setHidden(name, !shown)
        applyRoster()
        if !shown, case .chat(let id)? = route, id == name {
            route = .today
        }
        if !shown, case .botSettings(let id)? = route, id == name {
            route = .today
        }
    }

    /// Hermes's REST routes on the server Shion is connected to, signed as the socket is.
    var api: HermesAPI? {
        guard live, let credential = gateway.credential else { return nil }
        return HermesAPI(settings: serverSettings, credential: credential)
    }

    /// `profiles.list` again after a create, a delete or a new title, keeping every open chat.
    func refreshProfiles() async {
        guard live, let result = try? await gateway.call("profiles.list", [:]) else { return }
        let rows = result["profiles"]?.array ?? []
        guard live, !rows.isEmpty else { return }
        roster.load(rows, server: serverSettings.signInServer)
        applyRoster()
    }

    /// `profiles.create` over the socket, as Bot Mode makes one: a fresh profile gets the
    /// bundled skills and the server's own keys and model (`mirror_credentials`, on unless sent
    /// false); a copy gets its source's model, keys, skills, plugins, MCP servers and memories,
    /// not its messaging channels. Then Bot Mode's title. The Bot Chat comes when the chat is
    /// first opened, as for every assistant.
    func createAssistant(_ new: NewAssistant) async throws {
        guard live else { throw AssistantError.offline }
        var params: [String: JSONValue] = ["name": .string(new.name)]
        let description = new.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            params["description"] = .string(description)
        }
        if let source = new.cloneFrom {
            params["clone_from"] = .string(source)
        }
        if !new.soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["soul"] = .string(new.soul)
        }
        if let model = new.model {
            params["model"] = .string(model.model)
            params["provider"] = .string(model.provider)
        }
        // seeding a fresh profile's skills runs a subprocess on the server
        let reply = try await gateway.call("profiles.create", .object(params), timeout: 180)
        let name = reply["name"]?.string ?? new.name
        await refreshProfiles()
        let title = new.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            try await setTitle(title, of: name)
        }
    }

    /// Bot Mode's title for a profile (ui_meta's `hermes-bots` section, which `profiles.list`
    /// shows and Shion names the assistant by), through `profiles.configure`: the section as it
    /// is with the title changed, written only if nobody changed it since it was read. Hermes
    /// replaces a ui_meta section whole, so the rest of what Bot Mode keeps there is sent back too.
    /// A section changed meanwhile is read again and written once more.
    func setTitle(_ title: String, of name: String) async throws {
        for attempt in 0..<2 {
            guard let profile = roster.profile(name) else { throw AssistantError.notSaved("显示名") }
            var section = profile.botsMeta
            if title.isEmpty {
                section.removeValue(forKey: "title")
            } else {
                section["title"] = .string(title)
            }
            let written: JSONValue = section.isEmpty ? .null : .object(section)
            let revision: JSONValue = .number(Double(profile.botsRevision))
            let reply = try await gateway.call("profiles.configure", [
                "name": .string(name),
                "ui_meta": ["hermes-bots": written],
                "ui_meta_expected_revisions": ["hermes-bots": revision],
            ])
            await refreshProfiles()
            if reply["applied"]?["ui_meta"]?.bool == true {
                return
            }
            var conflicted = false
            if case .object(_)? = reply["applied"]?["ui_meta_conflicts"] {
                conflicted = true
            }
            guard attempt == 0, conflicted else { break }
        }
        throw AssistantError.notSaved("显示名")
    }

    /// `DELETE /api/profiles/{name}`: the profile and everything in it, on the server. Hermes
    /// keeps the default profile (400); Shion offers neither it nor 总秘书.
    func deleteAssistant(_ name: String) async throws {
        guard let api else { throw AssistantError.offline }
        // the server stops the profile's gateway first, waiting up to ten seconds
        try await api.request("DELETE", HermesAPI.profilePath(name), timeout: 90)
        roster.forget(name)
        if case .chat(let id)? = route, id == name {
            route = .today
        }
        if case .botSettings(let id)? = route, id == name {
            route = .today
        }
        await refreshProfiles()
    }

    /// The models a new assistant can start on: those of the profile it copies, or the server's.
    func modelOptions(copying source: String?) async -> [ModelProvider] {
        guard let api else { return [] }
        let reply = try? await api.get("/api/model/options", source.map { HermesAPI.scope($0) } ?? [], timeout: 60)
        return reply.map { ModelProvider.list($0) } ?? []
    }
}
