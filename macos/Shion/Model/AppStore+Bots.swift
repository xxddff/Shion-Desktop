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
        // once connected: the pictures, and Hermes's own clean-up of names deleted earlier
        Task {
            loadPictures()
            settle()
        }
        return rosterBots()
    }

    /// 总秘书's assistant: her name and avatar go wherever you talk to her.
    var chief: Bot? { bot(chiefId) }
    var chiefName: String { chief?.name ?? "总秘书" }

    private func rosterBots() -> [Bot] {
        let chief = roster.chiefName
        var shown: [Bot] = []
        var hidden: [Bot] = []
        for (index, profile) in roster.profiles.enumerated() {
            let leads = profile.name == chief
            let usual = leads ? Palette.accent : Palette.hues[index % Palette.hues.count]
            let bot = Bot(
                id: profile.name,
                name: profile.shownName,
                title: leads ? "总秘书" : (profile.description.isEmpty ? profile.name : profile.description),
                chief: leads,
                // Bot Mode's colour and shape, where it set them
                hue: BotLook.color(profile.color) ?? usual,
                status: .idle,
                statusNote: "",
                shape: profile.shape.isEmpty ? nil : profile.shape,
                hasPicture: profile.hasAvatar
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
    /// load again from there, or go back to the demo where the plugin is not installed. One that
    /// was hidden is shown again, and its Bot Chat attached.
    func chooseChief(_ name: String) {
        guard live, name != chiefId, roster.profile(name) != nil else { return }
        roster.setChief(name)
        applyRoster()
        stopPluginData()
        Task {
            await loadPluginData()
            await attachAll()
        }
    }

    /// Settings: whether Shion shows this assistant. 总秘书 is always shown. A hidden one's Bot
    /// Chat is let go, so its approvals and questions stop coming; shown again, it is attached as
    /// on connecting.
    func setShown(_ name: String, _ shown: Bool) {
        guard live, name != chiefId else { return }
        roster.setHidden(name, !shown)
        applyRoster()
        guard !shown else {
            Task { await attachAll() }
            return
        }
        forgetChat(name)
        if case .chat(let id)? = route, id == name {
            route = .today
        }
        if case .botSettings(let id)? = route, id == name {
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
        loadPictures()
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
        guard !title.isEmpty else { return }
        do {
            try await setTitle(title, of: name)
        } catch {
            // the profile is there all the same: making it again would only be refused
            throw AssistantError.titleNotSet(error.localizedDescription)
        }
    }

    /// Bot Mode's title for a profile (ui_meta's `hermes-bots` section, which `profiles.list`
    /// shows and Shion names the assistant by), through `profiles.configure`: the section as it
    /// is with the title changed, written only if nobody changed it since it was read. Hermes
    /// replaces a ui_meta section whole, so the rest of what Bot Mode keeps there is sent back too.
    /// A section changed meanwhile is read again and written once more. A profile the list has not
    /// shown yet (just made) has no section: revision 0.
    func setTitle(_ title: String, of name: String) async throws {
        try await setBotsMeta(["title": title.isEmpty ? nil : .string(title)], of: name, what: "显示名")
    }

    /// Bot Mode's colour and avatar shape (nil goes back to its default), marked as chosen
    /// (`custom`), as Bot Mode marks an avatar you picked.
    func setLook(color: String?, shape: String?, of name: String) async throws {
        let chosen: JSONValue? = color == nil && shape == nil ? nil : .bool(true)
        try await setBotsMeta([
            "color": color.map { JSONValue.string($0) },
            "shape": shape.map { JSONValue.string($0) },
            "custom": chosen,
        ], of: name, what: "头像")
    }

    /// Keys of Bot Mode's section changed (nil removes one), the rest sent back as it is.
    func setBotsMeta(_ changes: [String: JSONValue?], of name: String, what: String) async throws {
        for attempt in 0..<2 {
            let profile = roster.profile(name)
            var section = profile?.botsMeta ?? [:]
            for (key, value) in changes {
                if let value {
                    section[key] = value
                } else {
                    section.removeValue(forKey: key)
                }
            }
            let written: JSONValue = section.isEmpty ? .null : .object(section)
            let revision: JSONValue = .number(Double(profile?.botsRevision ?? 0))
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
        throw AssistantError.notSaved(what)
    }

    /// Bot Mode's avatar pictures (`profiles.get_asset`) for the profiles that have one, each
    /// read once while connected.
    func loadPictures() {
        for profile in roster.profiles where profile.hasAvatar && AvatarPictures.shared.images[profile.name] == nil {
            let name = profile.name
            Task { await loadPicture(name) }
        }
    }

    private func loadPicture(_ name: String) async {
        guard live, let reply = try? await gateway.call("profiles.get_asset", [
            "name": .string(name), "asset": "avatar",
        ], timeout: 60) else { return }
        guard reply["found"]?.bool == true, let data = reply["data"]?.string else {
            AvatarPictures.shared.set(nil, for: name)
            return
        }
        AvatarPictures.shared.set(AvatarPictures.image(data), for: name)
    }

    /// A picture for the avatar (`profiles.set_asset`, a PNG data URL), or none (`clear`).
    func setPicture(_ dataURL: String?, of name: String) async throws {
        guard live else { throw AssistantError.offline }
        var params: [String: JSONValue] = ["name": .string(name), "asset": "avatar"]
        if let dataURL {
            params["data"] = .string(dataURL)
        } else {
            params["clear"] = true
        }
        let reply = try await gateway.call("profiles.set_asset", .object(params), timeout: 60)
        guard reply["ok"]?.bool != false else { throw AssistantError.notSaved("图片") }
        AvatarPictures.shared.set(nil, for: name)
        await refreshProfiles()
    }

    /// `DELETE /api/profiles/{name}`: the profile and everything in it, on the server. Hermes
    /// keeps the default profile (400); Shion offers neither it nor 总秘书. When Hermes could not
    /// clean up the name's session and routing records (`settlement_pending`), the name is kept
    /// back until it has: a profile made under it meanwhile would take the old records over.
    func deleteAssistant(_ name: String) async throws {
        guard let api else { throw AssistantError.offline }
        // the server stops the profile's gateway first, waiting up to ten seconds
        let reply = try await api.request("DELETE", HermesAPI.profilePath(name), timeout: 90)
        roster.forget(name)
        if reply["settlement_pending"]?.bool == true {
            roster.setCleaning(name, command: reply["retry_command"]?.string ?? "hermes profile purge-identity \(name)")
            settle()
        }
        forgetChat(name)
        if case .chat(let id)? = route, id == name {
            route = .today
        }
        if case .botSettings(let id)? = route, id == name {
            route = .today
        }
        await refreshProfiles()
    }

    /// Names still being cleaned up: Shion runs the retry Hermes asks for (`hermes profile
    /// purge-identity`, over `cli.exec`) while connected, sooner at first, until it goes through.
    func settle() {
        guard live, roster.settler == nil, !roster.cleaning.isEmpty else { return }
        roster.settler = Task { [weak self] in
            var wait = 5.0
            while let self, self.live, !self.roster.cleaning.isEmpty, !Task.isCancelled {
                for name in self.roster.cleaning.keys.sorted() {
                    await self.purge(name)
                }
                if self.roster.cleaning.isEmpty {
                    break
                }
                try? await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 120)
            }
            self?.roster.settler = nil
        }
    }

    private func purge(_ name: String) async {
        // the name is a profile again (made elsewhere): there is nothing left to keep it from
        guard roster.profile(name) == nil else {
            roster.setCleaning(name, command: nil)
            return
        }
        guard let reply = try? await gateway.call("cli.exec", [
            "argv": ["profile", "purge-identity", .string(name)], "timeout": 120,
        ], timeout: 150), reply["blocked"]?.bool != true else { return }
        if reply["code"]?.int == 0 {
            roster.setCleaning(name, command: nil)
        }
    }

    /// Settings: the name is clean on the server, by your word (Shion could not get there itself).
    func cleaned(_ name: String) {
        roster.setCleaning(name, command: nil)
    }

    /// The models a new assistant can start on: those of the profile it copies, or the server's.
    func modelOptions(copying source: String?) async -> [ModelProvider] {
        guard let api else { return [] }
        let reply = try? await api.get("/api/model/options", source.map { HermesAPI.scope($0) } ?? [], timeout: 60)
        return reply.map { ModelProvider.list($0) } ?? []
    }
}
