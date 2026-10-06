import Foundation

/// Stable legacy storage identifiers preserve existing settings, timers and Keychain access.
/// All assistant identity and source symbols use Chef; this adapter alone knows the old name.
enum ChefCompatibility {
    private static let legacyName = "Jarvis"
    static func key(_ name: String) -> String { name.replacingOccurrences(of: "Chef", with: legacyName) }
    static func path(_ name: String) -> String {
        name.replacingOccurrences(of: "Chef", with: legacyName)
            .replacingOccurrences(of: "chef", with: legacyName.lowercased())
    }
    static func test() {
        precondition(key("ChefFishVoiceID") == legacyName + "FishVoiceID")
        precondition(path("outputs/Chef Home/workflows") == "outputs/" + legacyName + " Home/workflows")
    }
}
