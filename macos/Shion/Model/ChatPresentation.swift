import Foundation

/// Presentation-only control markers. Never discard prose which mentions a marker.
nonisolated enum ChatPresentation {
    static let markers: Set<String> = ["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY", "[静默]", "静默", "[沉默]", "沉默"]
    static func canonical(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.uppercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func silent(_ text: String) -> Bool {
        let value = canonical(text)
        guard value.count <= 64 else { return false }
        if markers.contains(value) { return true }
        let edge = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "[]"))
        return markers.contains(value.trimmingCharacters(in: edge).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @MainActor static func visible(_ item: ChatItem) -> Bool {
        guard item.role == .assistant else { return true }
        if silent(item.text) { return false }
        let value = canonical(item.text)
        return !item.streaming || value.isEmpty || !markers.contains(where: { $0.hasPrefix(value) })
    }
}

nonisolated enum SendMode: String, CaseIterable {
    case queue, steer, interrupt
    var label: String {
        switch self { case .queue: "排队"; case .steer: "引导"; case .interrupt: "打断后发送" }
    }
}
