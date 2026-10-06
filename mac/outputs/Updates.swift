import AppKit
import Foundation

struct CodeChangeRequest: Codable, Identifiable {
    let id: String
    let request: String
    let createdAt: String
}
struct CodeChangeResult: Codable {
    let id: String
    let status: String
    let message: String
    let updatedAt: String
    var buildVersion: String? = nil
}
struct UpdateRow: Identifiable {
    let id: String
    let request: String
    let status: String
    let message: String
}

enum UpdateRouting {
    static func isVoicePreference(_ input: String) -> Bool {
        input.range(of: #"^(?:(?:please|can you|could you)\s+)*(?:(?:use|switch to|choose)\s+(?:the\s+)?.+\s+voice|(?:change|switch|set)\s+(?:(?:your|the)\s+)?voice\s+to\s+.+)[.?!]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func isChangeRequest(_ input: String) -> Bool {
        let lower = input.lowercased()
        let explicit = ["feature request", "update your code", "change your code", "fix your code", "update yourself", "improve yourself", "fix yourself", "code change", "add a feature", "change your interface", "change your design", "change your appearance", "fix your microphone", "fix your voice"]
        if explicit.contains(where: { lower.contains($0) }) { return true }
        let asksForChange = input.range(of: #"^(?:(?:please|can you|could you|would you)\s+)*(?:i\s+(?:want|would like|need|don't like|dont like)|you\s+should|chef\s+(?:should|needs to)|make\s+(?:your|the)|let\s+me\s+interrupt|(?:improve|fix|change|add|enable)\b)"#, options: [.regularExpression, .caseInsensitive]) != nil
        let assistantFeature = ["acknowledg", "wake word", "hey chef", "hey chef", "your voice", "the voice", "human voice", "your design", "your interface", "talk back", "speak to me", "respond", "interrupt you", "listen to me", "listening", "microphone", "chef", "chef", "timer alert"].contains(where: { lower.contains($0) })
        return asksForChange && assistantFeature && !isVoicePreference(input)
    }
}

enum UpdateApplication {
    static func shouldApply(enabled: Bool, readyBuilds: [String], runningBuild: String, stagedBuild: String?, installedBuild: String?, busy: Bool, speaking: Bool, commandPending: Bool, idleSeconds: TimeInterval) -> Bool {
        guard enabled, !busy, !speaking, !commandPending, idleSeconds >= 8,
              let running = Int(runningBuild), let stagedBuild, let staged = Int(stagedBuild), staged > running,
              installedBuild == stagedBuild, readyBuilds.contains(stagedBuild) else { return false }
        return true
    }
}

final class UpdateStore {
    let directory: URL
    var inbox: URL { directory.appendingPathComponent("inbox") }
    var results: URL { directory.appendingPathComponent("results") }
    var bridgeStatus: URL { directory.appendingPathComponent("bridge.json") }
    var stagedBuild: String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("latest-build.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["buildVersion"] as? String
    }

    init(directory: URL? = nil) {
        if let directory { self.directory = directory }
        else {
            let root = Bundle.main.object(forInfoDictionaryKey: ChefCompatibility.key("ChefWorkspacePath")) as? String ?? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path
            self.directory = URL(fileURLWithPath: root).appendingPathComponent(ChefCompatibility.path("work/chef-updates"))
        }
    }
    func enqueue(_ text: String) throws -> String {
        guard text.count <= 6000 else { throw UpdateError.tooLong }
        guard !Safety.blocked(text) else { throw UpdateError.policy }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let waiting = rows().filter { ["Queued", "working"].contains($0.status) }
        guard waiting.count < 10 else { throw UpdateError.full }
        let request = CodeChangeRequest(id: UUID().uuidString, request: text, createdAt: ISO8601DateFormatter().string(from: Date()))
        try JSONEncoder().encode(request).write(to: inbox.appendingPathComponent(request.id + ".json"), options: .atomic)
        return request.id
    }
    func rows() -> [UpdateRow] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        var requests: [CodeChangeRequest] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let request = try? JSONDecoder().decode(CodeChangeRequest.self, from: data), UUID(uuidString: request.id) != nil else { continue }
            requests.append(request)
        }
        return requests.sorted { $0.createdAt > $1.createdAt }.prefix(30).map { request in
            let result = readResult(request.id)
            let resultVersion = Int(result?.buildVersion ?? "")
            let currentVersion = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            let installed = result?.status == "ready" && resultVersion != nil && currentVersion != nil && resultVersion! <= currentVersion!
            return UpdateRow(id: request.id, request: request.request, status: installed ? "Installed" : result?.status ?? "Queued", message: result?.message ?? "Waiting for the Codex update check.")
        }
    }
    func readResult(_ id: String) -> CodeChangeResult? {
        guard UUID(uuidString: id) != nil, let data = try? Data(contentsOf: results.appendingPathComponent(id + ".json")), let result = try? JSONDecoder().decode(CodeChangeResult.self, from: data), result.id == id else { return nil }
        return result
    }
    func bridgeDescription() -> String {
        guard let data = try? Data(contentsOf: bridgeStatus), let info = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return "Automatic code checks are off. Requests are saved locally." }
        if info["status"] == "paused" { return "Automatic Codex checks are paused, so they use no chat tokens. Requests are saved locally; resume checks in Codex Automations when needed." }
        guard info["status"] == "active" else { return "Automatic code checks are off. Requests are saved locally." }
        let interval = info["intervalMinutes"] ?? "60"
        let unit = interval == "1" ? "minute" : "minutes"
        return "Automatic Codex checks run about every \(interval) \(unit) while Codex is open and your Mac is awake. Local queue checks use no AI tokens."
    }
    enum UpdateError: LocalizedError {
        case policy, full, tooLong
        var errorDescription: String? {
            switch self {
            case .policy: return "Changes involving payments are not allowed."
            case .full: return "Ten requests are already waiting. Let those finish before adding more."
            case .tooLong: return "Please describe that change in fewer than 6,000 characters."
            }
        }
    }
}

enum WakeDecision: Equatable { case ignore, acknowledge, command(String) }
enum WakeGate {
    static func shouldDisableMicrophone(_ transcript: String) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 120,
              text.range(of: #"\b(?:don't|do not|never|avoid|without|can't|cannot|won't|will not)\b"#, options: [.regularExpression, .caseInsensitive]) == nil,
              text.range(of: #"(?is)(?:^|\s)[\"“‘][^\"”’]*[\"”’](?:$|\s)|(?:^|\s)'[^']*'(?:$|\s)"#, options: .regularExpression) == nil else { return false }
        var normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[.!?,]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.replacingOccurrences(of: #"^(?:(?:hi|hey|hello)[, ]+)?(?:hey\s+)?chef[\s,.:!?]+"#, with: "", options: .regularExpression)
        let turnOff = #"^(?:please\s+)?(?:(?:you can|can you|could you|would you)\s+)?(?:turn|switch|shut)(?:\s+it)?\s+off(?:\s+now)?$"#
        let stopListening = #"^(?:please\s+)?(?:(?:you can|can you|could you|would you)\s+)?stop listening(?:\s+now)?$"#
        return normalized.range(of: turnOff, options: .regularExpression) != nil
            || normalized.range(of: stopListening, options: .regularExpression) != nil
    }
    static func isSleepRequest(_ text: String) -> Bool {
        if shouldDisableMicrophone(text) { return true }
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:(?:hi|hey|hello)[, ]+)?chef[\s,.:!?]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .punctuationCharacters)
        return ["go to sleep", "sleep", "that's all", "that’s all", "stop listening", "end conversation"].contains(normalized)
    }
    static func decide(_ transcript: String, waitingForRequest: Bool) -> WakeDecision {
        let range = transcript.range(of: #"\b(?:(?:hey|hi)\s+)?chef\b[\s,.:!?]*"#, options: [.regularExpression, .caseInsensitive])
        if let range {
            let rest = String(transcript[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty || ["wake up", "wake", "are you awake", "wake up please"].contains(rest.lowercased().trimmingCharacters(in: .punctuationCharacters)) ? .acknowledge : .command(rest)
        }
        return waitingForRequest ? .command(transcript) : .ignore
    }
}
