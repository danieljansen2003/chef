import Foundation
import Security

// This adapter has no model selector, billing operation, top-up or paid fallback.
enum FishFreeVoice {
    enum Delivery: Equatable { case fish, local, privateTextOnly, textOnly }
    static let model = "s2.1-pro-free"
    static let endpoint = URL(string: "https://api.fish.audio/v1/tts")!
    static let cutoff = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!
    static let privateReplyNotice = "Private reply stays on screen; Fish access to private reply text is not enabled."
    static func permitsReply(eligible: Bool, privateContent: Bool, text: String, approvedPlanningText: Bool = false) -> Bool {
        if approvedPlanningText {
            return !AISecrets.containsSecret(text) && text.range(of: #"\b(password|passcode|secret|credential|api\s*key|access\s*token|social\s*security)\b|\b\d{3}-\d{2}-\d{4}\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        }
        return eligible && !privateContent && !sensitive(text)
    }
    static func publicConversationHistory(_ turns: [ConversationLine]) -> [ConversationLine] {
        turns.filter { !$0.privateContent }
    }
    static func shouldUseFish(text: String, allowCloud: Bool, enabled: Bool, consent: Bool, approvedPlanningText: Bool = false, at date: Date = Date()) -> Bool {
        permitsReply(eligible: allowCloud, privateContent: false, text: text, approvedPlanningText: approvedPlanningText) && enabled && consent && date < cutoff
    }
    static func delivery(eligible: Bool, privateContent: Bool, text: String, enabled: Bool, consent: Bool, providerReady: Bool, approvedPlanningText: Bool = false, at date: Date = Date()) -> Delivery {
        guard enabled, consent else { return .local }
        guard permitsReply(eligible: eligible, privateContent: privateContent, text: text, approvedPlanningText: approvedPlanningText) else { return .privateTextOnly }
        guard providerReady, date < cutoff else { return .textOnly }
        return .fish
    }
    static func afterProviderFailure(_ delivery: Delivery) -> Delivery {
        delivery == .fish ? .textOnly : delivery
    }
    static func providerFailureNotice(for delivery: Delivery) -> String? {
        guard afterProviderFailure(delivery) == .textOnly else { return nil }
        return "Fish couldn't play this reply. It remains on screen. Check the connection, saved key, and voice ID, then retry. No local or paid fallback was used."
    }
    static func request(text: String, key: String, voiceID: String, at date: Date = Date()) throws -> URLRequest {
        guard date < cutoff else { throw VoiceError.freeWindowEnded }
        guard !text.isEmpty, text.utf8.count <= 12000,
              key.count >= 8, key.count <= 512, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              voiceID.range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil else { throw VoiceError.configuration }
        var request = URLRequest(url: endpoint, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(model, forHTTPHeaderField: "model")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "reference_id": voiceID, "format": "mp3", "latency": "balanced"])
        return request
    }
    static func audio(text: String, key: String, voiceID: String) async throws -> Data {
        let request = try request(text: text, key: key, voiceID: voiceID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoVoiceRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count > 128, data.count <= 12_000_000 else { throw VoiceError.unavailable }
        return data
    }
    static func sensitive(_ text: String) -> Bool {
        text.range(of: #"\b(password|passcode|secret|credential|api\s*key|access\s*token|social\s*security|email|inbox|calendar|appointment|remind(?:er)?|bank|account|credit\s*card|medical|medicine|medication|diagnosis|usage|playbook|profile)\b|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|\b\d{3}-\d{2}-\d{4}\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    enum VoiceError: LocalizedError {
        case configuration, freeWindowEnded, unavailable
        var errorDescription: String? {
            switch self {
            case .configuration: return "Fish needs a locally saved free API key and a voice's 32-character model ID."
            case .freeWindowEnded: return "Fish's verified free window has ended. The reply remains on screen; no local or paid fallback."
            case .unavailable: return "Fish free voice is unavailable. The reply remains on screen; no local or paid fallback."
            }
        }
    }
    static func test() {
        let request = try! request(text: "Hello Daniel", key: "test-key-only", voiceID: String(repeating: "a", count: 32), at: cutoff.addingTimeInterval(-1))
        precondition(request.url == endpoint && request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "model") == "s2.1-pro-free")
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(body["model"] == nil && body["format"] as? String == "mp3")
        do { _ = try self.request(text: "Hello", key: "test-key-only", voiceID: String(repeating: "a", count: 32), at: cutoff); preconditionFailure("Free cutoff wasn't enforced") } catch {}
        do { _ = try self.request(text: "Hello", key: "test-key-only", voiceID: "bad", at: cutoff.addingTimeInterval(-1)); preconditionFailure("Invalid voice accepted") } catch {}
        precondition(sensitive("My password is secret") && sensitive("Email daniel@example.com"))
        precondition(sensitive("When is my reminder? My account usage and playbook are private."))
        precondition(!sensitive("Tell me a joke"))
        precondition(!permitsReply(eligible: false, privateContent: true, text: "Calendar: dentist at 10"))
        precondition(permitsReply(eligible: false, privateContent: true, text: "Calendar: dentist at 10", approvedPlanningText: true))
        precondition(!permitsReply(eligible: false, privateContent: true, text: "password: example-secret", approvedPlanningText: true))
        let beforeCutoff = cutoff.addingTimeInterval(-1)
        precondition(delivery(eligible: true, privateContent: false, text: "Public reply", enabled: true, consent: true, providerReady: true, at: beforeCutoff) == .fish)
        precondition(afterProviderFailure(.fish) == .textOnly)
        precondition(providerFailureNotice(for: .fish)?.contains("No local or paid fallback") == true)
        precondition(providerFailureNotice(for: .local) == nil)
        precondition(delivery(eligible: true, privateContent: false, text: "Public reply", enabled: true, consent: true, providerReady: false, at: beforeCutoff) == .textOnly)
        precondition(delivery(eligible: true, privateContent: false, text: "Public reply", enabled: true, consent: true, providerReady: true, at: cutoff) == .textOnly)
        precondition(delivery(eligible: false, privateContent: true, text: "Private reply", enabled: true, consent: true, providerReady: true, at: beforeCutoff) == .privateTextOnly)
        precondition(delivery(eligible: true, privateContent: false, text: "My private account information", enabled: true, consent: true, providerReady: true, at: beforeCutoff) == .privateTextOnly)
        precondition(privateReplyNotice == "Private reply stays on screen; Fish access to private reply text is not enabled.")
        precondition(delivery(eligible: true, privateContent: false, text: "Public reply", enabled: false, consent: true, providerReady: true, at: beforeCutoff) == .local)
        precondition(delivery(eligible: true, privateContent: false, text: "Public reply", enabled: true, consent: false, providerReady: true, at: beforeCutoff) == .local)
        precondition(shouldUseFish(text: "Tell me a joke", allowCloud: true, enabled: true, consent: true, at: beforeCutoff))
        precondition(permitsReply(eligible: true, privateContent: false, text: "What's the weather like at home?"))
        precondition(!permitsReply(eligible: true, privateContent: true, text: "What's the weather like at home?"))
        precondition(!permitsReply(eligible: false, privateContent: false, text: "What's the weather like at home?"))
        precondition(!permitsReply(eligible: true, privateContent: false, text: "My calendar appointment is at 3 PM"))
        let multiTurn = [
            ConversationLine(role: "YOU", text: "My calendar appointment is at 3 PM", privateContent: true),
            ConversationLine(role: "CHEF", text: "Your appointment is saved.", privateContent: true),
            ConversationLine(role: "YOU", text: "What's the weather like at home?")
        ]
        let publicFollowUp = publicConversationHistory(multiTurn)
        precondition(publicFollowUp.count == 1 && publicFollowUp[0].text == "What's the weather like at home?")
        precondition(permitsReply(eligible: true, privateContent: false, text: "A public weather summary."))
        precondition(!shouldUseFish(text: "Calendar: dentist at 3 PM", allowCloud: true, enabled: true, consent: true, at: beforeCutoff))
        precondition(!shouldUseFish(text: "Tell me a joke", allowCloud: false, enabled: true, consent: true, at: beforeCutoff))
        precondition(!shouldUseFish(text: "Tell me a joke", allowCloud: true, enabled: false, consent: true, at: beforeCutoff))
        precondition(!shouldUseFish(text: "Tell me a joke", allowCloud: true, enabled: true, consent: false, at: beforeCutoff))
        precondition(!shouldUseFish(text: "Tell me a joke", allowCloud: true, enabled: true, consent: true, at: cutoff))
        print("Free Fish model header, fixed endpoint, expiry, invalid configuration and private-text safeguards passed. No cloud calls made.")
    }
}
private final class NoVoiceRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum FishCredential {
    private static let service = ChefCompatibility.path("local.daniel.chef.fish-free")
    static func save(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "voice"]
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw FishFreeVoice.VoiceError.configuration }
        } else if status != errSecSuccess { throw FishFreeVoice.VoiceError.configuration }
    }
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "voice", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct SpeechTurn {
    private var serial = 0
    private(set) var active: Int?
    mutating func begin() -> Int { serial += 1; active = serial; return serial }
    mutating func finish(_ id: Int) -> Bool {
        guard active == id else { return false }
        active = nil; return true
    }
    static func test() {
        var turn = SpeechTurn()
        let first = turn.begin(), second = turn.begin()
        precondition(!turn.finish(first))
        precondition(turn.active == second)
        precondition(turn.finish(second) && !turn.finish(second))
        var conversation = ConversationWindow()
        let start = Date(timeIntervalSince1970: 1000)
        conversation.engage(at: start)
        for exchange in 1...5 {
            let commandAt = start.addingTimeInterval(Double(exchange) * 120)
            precondition(conversation.active(at: commandAt))
            conversation.engage(at: commandAt) // User command accepted.
            let replyAt = commandAt.addingTimeInterval(10)
            conversation.engage(at: replyAt) // Voice completed and listening resumed.
            precondition(WakeGate.decide("yes, another question", waitingForRequest: conversation.active(at: replyAt.addingTimeInterval(1))) == .command("yes, another question"))
        }
        print("Speech replacement/stale callbacks and five consecutive no-wake exchanges passed.")
    }
}
