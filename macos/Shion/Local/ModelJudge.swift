import FoundationModels

/// The verdict as the model writes it: guided generation fills these two in directly.
@Generable
nonisolated struct FocusVerdict {
    @Guide(description: "前台窗口和此刻计划的关系：same 是正在做计划里的这件事；related 是和它有关的事，比如查资料、看相关的讲解、记这件事的笔记；unrelated 是和计划无关的事")
    var fit: VerdictFit
    @Guide(description: "前台窗口在做哪类事：study 学习，work 工作，life 生活琐事，fun 娱乐（视频、游戏、随便逛逛），social 聊天和社交网络，other 别的")
    var kind: VerdictKind
}

@Generable
nonisolated enum VerdictFit {
    case same, related, unrelated
}

@Generable
nonisolated enum VerdictKind {
    case study, work, life, fun, social, other
}

/// Apple's on-device model (Foundation Models) judges the window in front against the plan, on
/// this Mac: the title never leaves it. Needs Apple silicon with Apple Intelligence turned on;
/// without them the focus check waits and Settings says why.
final class SystemModelJudge: FocusJudge {
    var status: JudgeStatus {
        let availability = SystemLanguageModel.default.availability
        if case .available = availability { return .ready }
        if case .unavailable(.appleIntelligenceNotEnabled) = availability { return .unavailable("Apple 智能没有打开") }
        if case .unavailable(.deviceNotEligible) = availability { return .unavailable("这台 Mac 用不了 Apple 智能") }
        return .unavailable("本机模型还没准备好")
    }

    func judge(plan: String, app: String, title: String) async -> Judgement? {
        guard status == .ready else { return nil }
        // a new session each time: one window, one answer, nothing carried over
        let session = LanguageModelSession(instructions: """
            你帮用户做专注检查：判断他这台 Mac 前台的窗口，和他此刻计划要做的事对不对得上。\
            只根据计划、应用名和窗口标题判断。看不出是不是在做计划里的事时，选 related。
            """)
        let prompt = "计划：\(plan)\n前台应用：\(app)\n窗口标题：\(title.isEmpty ? "（读不到）" : title)"
        do {
            let verdict = try await session.respond(to: prompt, generating: FocusVerdict.self).content
            return Judgement(fit: verdict.fit.fit, kind: verdict.kind.kind)
        } catch {
            // refused or failed: LocalData asks again about this window in ten minutes
            return nil
        }
    }
}

nonisolated extension VerdictFit {
    var fit: Fit {
        switch self {
        case .same: return .same
        case .related: return .related
        case .unrelated: return .unrelated
        }
    }
}

nonisolated extension VerdictKind {
    var kind: ActivityKind {
        switch self {
        case .study: return .study
        case .work: return .work
        case .life: return .life
        case .fun: return .fun
        case .social: return .social
        case .other: return .other
        }
    }
}
