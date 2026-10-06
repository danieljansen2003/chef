import Foundation
import SwiftUI
import CryptoKit
import Security
import Darwin

struct PocketItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case todo, thought, calendar }
    struct CalendarRequest: Codable, Equatable {
        var startAt: String
        var endAt: String
        var allDay: Bool
        var timeZone: String
    }
    var id: String
    var kind: Kind
    var text: String
    var done: Bool
    var createdAt: String
    var updatedAt: String
    var calendarRequest: CalendarRequest? = nil
    var deleted: Bool? = nil

    var uuid: UUID? { UUID(uuidString: id) }
}

struct PocketChatMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case user, chef }
    var id: String
    var conversationID: String
    var role: Role
    var text: String
    var createdAt: String
    var replyToID: String? = nil
}

struct PocketVoiceChunk: Codable, Equatable, Identifiable {
    var id: String
    var messageID: String
    var index: Int
    var count: Int
    var data: String
}

struct PocketBriefingRequest: Codable, Equatable, Identifiable {
    enum RequestType: String, Codable { case now, schedule }
    var id: String
    var conversationID: String
    var requestType: RequestType
    var request: String
    var createdAt: String
}

@MainActor
final class PocketSync: ObservableObject {
    static let origin = URL(string: "https://chef-pocket-daniel.sy-alejandri-0136.chatgpt.site")!
    private static let keychainService = "com.openai.chef.pocket-sync"
    private static let stateName = "pocket-sync-state.json"
    private static let maxText = 500
    private static let maxResponseBytes = 1_000_000

    @Published private(set) var items: [PocketItem] = []
    @Published private(set) var status = "Pocket sync is off."
    @Published private(set) var enabled = false
    @Published private(set) var pairingURL: URL?
    var onImportedItem: ((PocketItem) throws -> Void)?
    var onChatMessage: ((PocketChatMessage) -> Void)?
    var onBriefingRequest: ((PocketBriefingRequest) -> Void)?

    private struct Pending: Codable {
        var id: String
        var itemID: String
        var payload: String
    }
    private struct State: Codable {
        var cursor: Int = 0
        var items: [PocketItem] = []
        var pending: [Pending] = []
        var resumeEnabled: Bool = false
        var chatMessages: [PocketChatMessage] = []
        var pendingChatIDs: [String] = []
        var processedChatIDs: [String] = []
        var phoneBriefings: [PocketBriefingRequest] = []
        var pendingBriefingIDs: [String] = []
        var processedBriefingIDs: [String] = []

        private enum CodingKeys: String, CodingKey { case cursor, items, pending, resumeEnabled, chatMessages, pendingChatIDs, processedChatIDs, phoneBriefings, pendingBriefingIDs, processedBriefingIDs }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cursor = try c.decodeIfPresent(Int.self, forKey: .cursor) ?? 0
            items = try c.decodeIfPresent([PocketItem].self, forKey: .items) ?? []
            pending = try c.decodeIfPresent([Pending].self, forKey: .pending) ?? []
            resumeEnabled = try c.decodeIfPresent(Bool.self, forKey: .resumeEnabled) ?? false
            chatMessages = try c.decodeIfPresent([PocketChatMessage].self, forKey: .chatMessages) ?? []
            pendingChatIDs = try c.decodeIfPresent([String].self, forKey: .pendingChatIDs) ?? []
            processedChatIDs = try c.decodeIfPresent([String].self, forKey: .processedChatIDs) ?? []
            phoneBriefings = try c.decodeIfPresent([PocketBriefingRequest].self, forKey: .phoneBriefings) ?? []
            pendingBriefingIDs = try c.decodeIfPresent([String].self, forKey: .pendingBriefingIDs) ?? []
            processedBriefingIDs = try c.decodeIfPresent([String].self, forKey: .processedBriefingIDs) ?? []
        }
    }
    private struct Envelope: Codable {
        var v: Int = 1
        var op: String = "upsert"
        var item: PocketItem? = nil
        var message: PocketChatMessage? = nil
        var voice: PocketVoiceChunk? = nil
        var briefing: PocketBriefingRequest? = nil
    }
    private struct Event: Codable {
        var seq: Int
        var id: String
        var payload: String
    }
    private struct EventResponse: Codable {
        var events: [Event]
        var cursor: Int
    }

    private let root: URL
    private let stateURL: URL
    private let session: URLSession
    private var state = State()
    private var token: String?
    private var pollTask: Task<Void, Never>?
    private var showingPairing = false
    private var syncGeneration = 0
    private var dispatchedChatIDs = Set<String>()
    private var dispatchedBriefingIDs = Set<String>()

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        self.stateURL = root.appendingPathComponent(Self.stateName, isDirectory: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: PocketNoRedirectDelegate(), delegateQueue: nil)
        try Self.prepareRoot(root)
        try loadState()
        token = try Self.readToken()
        enabled = state.resumeEnabled && token != nil
        status = enabled ? "Connected. Resuming Pocket sync." : (token == nil ? "Connect your phone to create a private sync channel." : "Pocket sync is off. Choose Connect to resume.")
        if enabled { startPolling() }
    }

    deinit { pollTask?.cancel(); session.invalidateAndCancel() }

    func connect() {
        syncGeneration &+= 1
        do {
            if token == nil {
                let bytes = try Self.randomBytes(count: 32)
                let generated = bytes.map { String(format: "%02x", $0) }.joined()
                try Self.saveToken(generated)
                token = generated
            }
            for item in state.items where !state.pending.contains(where: { $0.itemID == item.id }) {
                let payload = try Self.seal(Self.encode(item), token: token!)
                state.pending.append(Pending(id: UUID().uuidString.lowercased(), itemID: item.id, payload: payload.base64EncodedString()))
            }
            state.resumeEnabled = true
            try persist()
            enabled = true
            status = "Connected locally. Open Show pairing on your phone to pair."
            startPolling()
        } catch {
            enabled = false
            status = "Could not save the pairing secret in Keychain: \(error.localizedDescription)"
        }
    }

    func showPairing() {
        guard enabled, let token, let url = Self.pairingURL(for: token) else {
            pairingURL = nil
            status = "Choose Connect before showing the phone pairing link."
            return
        }
        showingPairing = true
        pairingURL = url
        status = "Pairing link is visible. Treat it like a password."
    }

    func hidePairing() {
        showingPairing = false
        pairingURL = nil
    }

    func disable() {
        syncGeneration &+= 1
        enabled = false
        state.resumeEnabled = false
        hidePairing()
        pollTask?.cancel()
        pollTask = nil
        do {
            try persist()
            status = "Pocket sync is off. Local items and unsent changes are saved."
        } catch { status = "Pocket sync is off, but its setting could not be saved: \(error.localizedDescription)" }
    }

    func revokeAndRotate() {
        disable()
        do {
            let generated = try Self.randomBytes(count: 32).map { String(format: "%02x", $0) }.joined()
            try Self.saveToken(generated)
            token = generated
            state.cursor = 0
            state.pending = []
            try persist()
            status = "The Mac now uses a new channel. A phone that has the old link can still access its old channel; pair it again to sync here."
        } catch {
            token = nil
            try? Self.deleteToken()
            status = "Could not rotate the pairing secret: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func capture(text: String, kind: PocketItem.Kind) throws -> PocketItem {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= Self.maxText else { throw PocketError.invalidItem }
        let now = Self.timestamp(Date())
        let item = PocketItem(id: UUID().uuidString.lowercased(), kind: kind, text: clean, done: false, createdAt: now, updatedAt: now)
        try enqueue(item)
        return item
    }

    func setCompleted(id: String, done: Bool) throws {
        guard let index = state.items.firstIndex(where: { $0.id == id }) else { throw PocketError.missingItem }
        var item = state.items[index]
        guard item.kind == .todo, item.deleted != true else { throw PocketError.invalidItem }
        item.done = done
        item.updatedAt = Self.timestamp(Date())
        try enqueue(item)
    }

    func deleteTodo(id: String) throws {
        guard let index = state.items.firstIndex(where: { $0.id == id }) else { throw PocketError.missingItem }
        var item = state.items[index]
        guard item.kind == .todo else { throw PocketError.invalidItem }
        guard item.deleted != true else { return }
        item.deleted = true
        let previous = Self.date(item.updatedAt) ?? .distantPast
        item.updatedAt = Self.timestamp(max(Date(), previous.addingTimeInterval(0.001)))
        try enqueue(item)
    }

    func importLocalItem(_ item: PocketItem) throws {
        guard Self.valid(item) else { throw PocketError.invalidItem }
        guard !state.items.contains(where: { $0.id == item.id && (Self.date($0.updatedAt) ?? .distantPast) >= (Self.date(item.updatedAt) ?? .distantPast) }) else { return }
        var candidate = state
        candidate.items = Self.merging(candidate.items, item)
        if let token {
            let payload = try Self.seal(Self.encode(item), token: token)
            candidate.pending.append(Pending(id: UUID().uuidString.lowercased(), itemID: item.id, payload: payload.base64EncodedString()))
        }
        try save(candidate)
    }

    func pendingPhoneMessages() -> [PocketChatMessage] {
        state.pendingChatIDs.compactMap { id in state.chatMessages.first(where: { $0.id == id }) }
    }

    func chatHistory(conversationID: String, limit: Int = 8) -> [PocketChatMessage] {
        Array(state.chatMessages.filter { $0.conversationID == conversationID }.suffix(max(0, limit)))
    }

    func dispatchPendingChat() {
        for message in pendingPhoneMessages() where !dispatchedChatIDs.contains(message.id) {
            dispatchedChatIDs.insert(message.id)
            onChatMessage?(message)
        }
    }

    func dispatchPendingBriefings() {
        for request in state.pendingBriefingIDs.compactMap({ id in state.phoneBriefings.first(where: { $0.id == id }) })
            where !dispatchedBriefingIDs.contains(request.id) {
            dispatchedBriefingIDs.insert(request.id)
            onBriefingRequest?(request)
        }
    }

    func retryPhoneChat(_ id: String) { dispatchedChatIDs.remove(id) }

    func retryPhoneBriefing(_ id: String) { dispatchedBriefingIDs.remove(id) }

    func completePhoneBriefing(_ id: String, text: String, audio: Data? = nil) throws {
        guard let request = state.phoneBriefings.first(where: { $0.id == id }),
              state.pendingBriefingIDs.contains(id) else { throw PocketError.invalidResponse }
        var candidate = state
        try queuePhoneReply(conversationID: request.conversationID, replyToID: id, text: text, audio: audio, to: &candidate)
        candidate.pendingBriefingIDs.removeAll { $0 == id }
        candidate.processedBriefingIDs.append(id)
        candidate.processedBriefingIDs = Array(candidate.processedBriefingIDs.suffix(10_000))
        try save(candidate)
        dispatchedBriefingIDs.remove(id)
        if enabled { startPolling() }
    }

    func enqueuePhoneReply(conversationID: String, replyToID: String, text: String, audio: Data? = nil) throws {
        var candidate = state
        try queuePhoneReply(conversationID: conversationID, replyToID: replyToID, text: text, audio: audio, to: &candidate)
        try save(candidate)
        if enabled { startPolling() }
    }

    private func queuePhoneReply(conversationID: String, replyToID: String, text: String, audio: Data?, to candidate: inout State) throws {
        guard UUID(uuidString: conversationID) != nil, UUID(uuidString: replyToID) != nil,
              !text.isEmpty, text.count <= 400 else { throw PocketError.invalidResponse }
        let reply = PocketChatMessage(id: UUID().uuidString.lowercased(), conversationID: conversationID, role: .chef,
                                      text: text, createdAt: Self.timestamp(Date()), replyToID: replyToID)
        if let audio, !audio.isEmpty, audio.count <= 192_000 {
            let count = (audio.count + 5_999) / 6_000
            guard count <= 32 else { throw PocketError.invalidResponse }
            for index in 0..<count {
                let bytes = audio.subdata(in: (index * 6_000)..<min(audio.count, (index + 1) * 6_000))
                let chunk = PocketVoiceChunk(id: UUID().uuidString.lowercased(), messageID: reply.id, index: index, count: count, data: bytes.base64EncodedString())
                try appendOutbox(Envelope(v: 1, op: "voice", voice: chunk), id: chunk.id, to: &candidate)
            }
        }
        try appendOutbox(Envelope(v: 1, op: "chat", message: reply), id: reply.id, to: &candidate)
        candidate.chatMessages.append(reply)
        candidate.chatMessages = Array(candidate.chatMessages.suffix(400))
    }

    func completePhoneChat(userMessageID: String, text: String, audio: Data? = nil) throws {
        guard let incoming = state.chatMessages.first(where: { $0.id == userMessageID && $0.role == .user }),
              state.pendingChatIDs.contains(userMessageID), !text.isEmpty, text.count <= 400 else { throw PocketError.invalidResponse }
        try enqueuePhoneReply(conversationID: incoming.conversationID, replyToID: incoming.id, text: text, audio: audio)
        var candidate = state
        candidate.pendingChatIDs.removeAll { $0 == userMessageID }
        candidate.processedChatIDs.append(userMessageID)
        candidate.processedChatIDs = Array(candidate.processedChatIDs.suffix(10_000))
        try save(candidate)
        dispatchedChatIDs.remove(userMessageID)
        if enabled { startPolling() }
    }

    private func appendOutbox(_ envelope: Envelope, id: String, to candidate: inout State) throws {
        guard let token else { return }
        let clear = try JSONEncoder().encode(envelope)
        let sealed = try Self.seal(clear, token: token)
        candidate.pending.append(Pending(id: UUID().uuidString.lowercased(), itemID: id, payload: sealed.base64EncodedString()))
    }

    fileprivate static func merging(_ items: [PocketItem], _ item: PocketItem) -> [PocketItem] {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var result = items
            if (date(item.updatedAt) ?? .distantPast) > (date(result[index].updatedAt) ?? .distantPast) {
                result[index] = item
            }
            return result
        }
        return [item] + items
    }

    fileprivate static func visible(_ items: [PocketItem]) -> [PocketItem] {
        items.filter { $0.deleted != true }
            .sorted { (date($0.updatedAt) ?? .distantPast) > (date($1.updatedAt) ?? .distantPast) }
    }

    private func enqueue(_ item: PocketItem) throws {
        guard Self.valid(item) else { throw PocketError.invalidItem }
        var candidate = state
        if let i = candidate.items.firstIndex(where: { $0.id == item.id }) {
            guard (Self.date(item.updatedAt) ?? .distantPast) >= (Self.date(candidate.items[i].updatedAt) ?? .distantPast) else { throw PocketError.staleItem }
            candidate.items[i] = item
        } else {
            candidate.items.append(item)
        }
        if let token {
            let clear = try Self.encode(item)
            let sealed = try Self.seal(clear, token: token)
            candidate.pending.append(Pending(id: UUID().uuidString.lowercased(), itemID: item.id, payload: sealed.base64EncodedString()))
        }
        try save(candidate)
        if enabled { startPolling() }
    }

     private func merge(_ item: PocketItem, notify: Bool) throws {
        guard Self.valid(item) else { throw PocketError.invalidResponse }
        if let current = state.items.first(where: { $0.id == item.id }), (Self.date(current.updatedAt) ?? .distantPast) >= (Self.date(item.updatedAt) ?? .distantPast) {
            if notify { try onImportedItem?(current) }
            return
        }
        var candidate = state
        candidate.items = Self.merging(candidate.items, item)
        do {
            try save(candidate)
            if notify { try onImportedItem?(item) }
        } catch { throw error }
    }

    private func startPolling() {
        guard enabled, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.syncOnce()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await self.syncOnce()
            }
            self.pollTask = nil
        }
    }

    private func syncOnce() async {
        guard enabled, let token else { return }
        let generation = syncGeneration
        do {
            // POSTs reuse both event id and ciphertext across retries, preserving backend idempotency.
            while enabled, let next = state.pending.first {
                let body = try JSONSerialization.data(withJSONObject: ["id": next.id, "payload": next.payload])
                let data = try await request(path: "/api/channels/\(Self.channel(token))/events", method: "POST", token: token, body: body)
                guard enabled, self.token == token, generation == self.syncGeneration else { return }
                guard data.count <= Self.maxResponseBytes else { throw PocketError.responseTooLarge }
                var updated = state
                guard updated.pending.first?.id == next.id else { continue }
                updated.pending.removeFirst()
                try save(updated)
            }
            let path = "/api/channels/\(Self.channel(token))/events?after=\(state.cursor)"
            let data = try await request(path: path, method: "GET", token: token, body: nil)
            guard enabled, self.token == token, generation == self.syncGeneration else { return }
            guard data.count <= Self.maxResponseBytes else { throw PocketError.responseTooLarge }
            let response = try JSONDecoder().decode(EventResponse.self, from: data)
            guard response.events.count <= 200, response.cursor >= state.cursor else { throw PocketError.invalidResponse }
            for event in response.events.sorted(by: { $0.seq < $1.seq }) {
                guard event.seq > state.cursor, event.seq <= response.cursor,
                      let sealed = Data(base64Encoded: event.payload), sealed.count <= 16_384 else { throw PocketError.invalidResponse }
                let clear = try Self.open(sealed, token: token)
                let envelope = try JSONDecoder().decode(Envelope.self, from: clear)
                guard envelope.v == 1 else { throw PocketError.invalidResponse }
                switch envelope.op {
                case "upsert":
                    guard let item = envelope.item, Self.valid(item) else { throw PocketError.invalidResponse }
                    try merge(item, notify: true)
                case "chat":
                    guard let message = envelope.message, Self.valid(message) else { throw PocketError.invalidResponse }
                    if message.role == .user { try storePhoneMessage(message) }
                case "voice":
                    guard let voice = envelope.voice, Self.valid(voice) else { throw PocketError.invalidResponse }
                case "briefing":
                    guard let briefing = envelope.briefing, Self.valid(briefing) else { throw PocketError.invalidResponse }
                    try storePhoneBriefing(briefing)
                default: throw PocketError.invalidResponse
                }
                var advanced = state
                advanced.cursor = event.seq
                try save(advanced)
            }
            var advanced = state
            advanced.cursor = max(advanced.cursor, response.cursor)
            try save(advanced)
            status = "Synced \(state.items.count) items. Last checked just now."
            dispatchPendingChat()
            dispatchPendingBriefings()
        } catch {
            guard enabled, self.token == token, generation == self.syncGeneration else { return }
            status = "Sync paused: \(error.localizedDescription). Local changes remain saved."
        }
    }

    private func storePhoneMessage(_ message: PocketChatMessage) throws {
        if state.processedChatIDs.contains(message.id) { return }
        if let old = state.chatMessages.first(where: { $0.id == message.id }) {
            guard old == message else { throw PocketError.invalidResponse }
            return
        }
        guard state.pendingChatIDs.count < 200 else { throw PocketError.invalidState }
        var candidate = state
        while candidate.chatMessages.count >= 400 {
            guard let removable = candidate.chatMessages.firstIndex(where: { !candidate.pendingChatIDs.contains($0.id) }) else { throw PocketError.invalidState }
            candidate.chatMessages.remove(at: removable)
        }
        candidate.chatMessages.append(message)
        candidate.pendingChatIDs.append(message.id)
        try save(candidate)
    }

    private func storePhoneBriefing(_ request: PocketBriefingRequest) throws {
        if let old = state.phoneBriefings.first(where: { $0.id == request.id }) {
            guard old == request else { throw PocketError.invalidResponse }
            return
        }
        if state.processedBriefingIDs.contains(request.id) { return }
        guard state.pendingBriefingIDs.count < 200 else { throw PocketError.invalidState }
        var candidate = state
        while candidate.phoneBriefings.count >= 400 {
            guard let removable = candidate.phoneBriefings.firstIndex(where: { !candidate.pendingBriefingIDs.contains($0.id) }) else { throw PocketError.invalidState }
            candidate.phoneBriefings.remove(at: removable)
        }
        candidate.phoneBriefings.append(request)
        candidate.pendingBriefingIDs.append(request.id)
        try save(candidate)
    }

    private func request(path: String, method: String, token: String, body: Data?) async throws -> Data {
        guard path.hasPrefix("/api/channels/"), !path.contains(".."),
              let url = URL(string: path, relativeTo: Self.origin)?.absoluteURL,
              url.scheme == "https", url.host == Self.origin.host, url.port == nil else { throw PocketError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Self.authBearer(token))", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maxResponseBytes, let http = response as? HTTPURLResponse else { throw PocketError.responseTooLarge }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw PocketError.backendUnavailable("The Pocket service rejected access (HTTP \(http.statusCode)). Its public access may still need to be enabled.")
            }
            throw PocketError.backendUnavailable("Pocket service returned HTTP \(http.statusCode).")
        }
        return data
    }

    private func loadState() throws {
        try Self.checkPath(root: root, file: stateURL, allowMissingLeaf: true)
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        let data = try Data(contentsOf: stateURL, options: [.mappedIfSafe])
        guard data.count <= 4_000_000 else { throw PocketError.invalidState }
        let decoded = try JSONDecoder().decode(State.self, from: data)
        guard decoded.cursor >= 0, decoded.items.count <= 20_000, decoded.pending.count <= 20_000,
              decoded.chatMessages.count <= 400, decoded.pendingChatIDs.count <= 200, decoded.processedChatIDs.count <= 10_000,
              decoded.phoneBriefings.count <= 400, decoded.pendingBriefingIDs.count <= 200, decoded.processedBriefingIDs.count <= 10_000,
              decoded.items.allSatisfy(Self.valid), decoded.chatMessages.allSatisfy(Self.valid), decoded.phoneBriefings.allSatisfy(Self.valid),
              decoded.pendingChatIDs.allSatisfy({ UUID(uuidString: $0) != nil }), decoded.processedChatIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
              decoded.pendingBriefingIDs.allSatisfy({ UUID(uuidString: $0) != nil }), decoded.processedBriefingIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
              decoded.pending.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.itemID) != nil && (Data(base64Encoded: $0.payload)?.count ?? 0) <= 16_384 }) else {
            throw PocketError.invalidState
        }
        state = decoded
        items = Self.visible(decoded.items)
    }

    private func save(_ candidate: State) throws {
        try Self.checkPath(root: root, file: stateURL, allowMissingLeaf: true)
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= 4_000_000 else { throw PocketError.invalidState }
        try data.write(to: stateURL, options: .atomic)
        state = candidate
        items = Self.visible(candidate.items)
    }

    private func persist() throws { try save(state) }

    fileprivate static func legacyStateHasEmptyChat(_ data: Data) -> Bool {
        guard let legacy = try? JSONDecoder().decode(State.self, from: data) else { return false }
        return legacy.chatMessages.isEmpty && legacy.pendingChatIDs.isEmpty && legacy.processedChatIDs.isEmpty &&
            legacy.phoneBriefings.isEmpty && legacy.pendingBriefingIDs.isEmpty && legacy.processedBriefingIDs.isEmpty
    }

    private static func prepareRoot(_ root: URL) throws {
        let fm = FileManager.default
        try checkNoSymlinkAncestors(root.standardizedFileURL)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let attrs = try fm.attributesOfItem(atPath: root.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw PocketError.unsafePath }
        try checkPath(root: root.standardizedFileURL, file: root.appendingPathComponent(stateName), allowMissingLeaf: true)
    }

    private static func checkNoSymlinkAncestors(_ path: URL) throws {
        var current = URL(fileURLWithPath: "/")
        for component in path.standardizedFileURL.path.split(separator: "/").map(String.init) {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw PocketError.unsafePath }
        }
    }

    private static func checkPath(root: URL, file: URL, allowMissingLeaf: Bool) throws {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { throw PocketError.unsafePath }
        let fm = FileManager.default
        var current = URL(fileURLWithPath: "/")
        for component in filePath.split(separator: "/").map(String.init) {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw PocketError.unsafePath }
        }
        if !allowMissingLeaf && !fm.fileExists(atPath: filePath) { throw PocketError.unsafePath }
    }

    fileprivate static func valid(_ item: PocketItem) -> Bool {
        guard UUID(uuidString: item.id) != nil, item.text.count <= maxText,
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.createdAt.count <= 40, item.updatedAt.count <= 40,
              let c = date(item.createdAt),
              let u = date(item.updatedAt), u >= c else { return false }
        switch item.kind {
        case .todo:
            return item.calendarRequest == nil
        case .thought:
            return item.calendarRequest == nil && item.deleted != true
        case .calendar:
            guard item.deleted != true, let request = item.calendarRequest,
                  request.startAt.count <= 40, request.endAt.count <= 40,
                  let start = date(request.startAt), let end = date(request.endAt),
                  end > start, end.timeIntervalSince(start) <= 366 * 24 * 60 * 60,
                  TimeZone(identifier: request.timeZone) != nil else { return false }
            return true
        }
    }

    fileprivate static func valid(_ message: PocketChatMessage) -> Bool {
        guard UUID(uuidString: message.id) != nil, UUID(uuidString: message.conversationID) != nil,
              message.createdAt.count <= 40, date(message.createdAt) != nil,
              !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch message.role {
        case .user: return message.text.count <= 2000 && message.replyToID == nil
        case .chef: return message.text.count <= 400 && message.replyToID.flatMap(UUID.init(uuidString:)) != nil
        }
    }

    fileprivate static func valid(_ chunk: PocketVoiceChunk) -> Bool {
        guard UUID(uuidString: chunk.id) != nil, UUID(uuidString: chunk.messageID) != nil,
              (1...32).contains(chunk.count), (0..<chunk.count).contains(chunk.index),
              chunk.data.utf8.count <= 8000, let data = Data(base64Encoded: chunk.data),
              data.count <= 6000 else { return false }
        return true
    }

    fileprivate static func valid(_ request: PocketBriefingRequest) -> Bool {
        UUID(uuidString: request.id) != nil && UUID(uuidString: request.conversationID) != nil &&
            (1...1200).contains(request.request.count) && date(request.createdAt) != nil && request.createdAt.count <= 40 &&
            !PersonalWorkspace.hasCredential(request.request) && !Safety.blocked(request.request)
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: text)
    }

    private static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func encode(_ item: PocketItem) throws -> Data {
        try JSONEncoder().encode(Envelope(item: item))
    }

    private static func randomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard result == errSecSuccess else { throw PocketError.keychain(result) }
        return bytes
    }

    private static func saveToken(_ token: String) throws {
        guard token.count == 64, token.allSatisfy({ $0.isHexDigit }) else { throw PocketError.invalidState }
        try deleteToken()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "shared-token",
                                    kSecValueData as String: Data(token.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemAdd(query as CFDictionary, nil)
        guard result == errSecSuccess else { throw PocketError.keychain(result) }
    }

    private static func readToken() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "shared-token",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data,
              let token = String(data: data, encoding: .utf8), token.count == 64,
              token.allSatisfy({ $0.isHexDigit }) else { throw PocketError.keychain(result) }
        return token
    }

    private static func deleteToken() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "shared-token"]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw PocketError.keychain(result) }
    }

    private static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func channel(_ token: String) -> String { sha256(token) }
    private static func authBearer(_ token: String) -> String { sha256("chef-auth-v1:" + token) }

    static func seal(_ clear: Data, token: String) throws -> Data {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(("chef-pocket-v1:" + token).utf8))))
        let box = try AES.GCM.seal(clear, using: key)
        guard let combined = box.combined else { throw PocketError.crypto }
        return combined
    }

    static func open(_ combined: Data, token: String) throws -> Data {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(("chef-pocket-v1:" + token).utf8))))
        return try AES.GCM.open( try AES.GCM.SealedBox(combined: combined), using: key)
    }

    static func pairingURL(for token: String) -> URL? {
        guard token.count == 64, token.allSatisfy({ $0.isHexDigit }) else { return nil }
        return URL(string: origin.absoluteString + "/#pair=" + token)
    }

    enum PocketError: LocalizedError {
        case invalidItem, staleItem, missingItem, notConnected, crypto, invalidState, unsafePath, invalidResponse, responseTooLarge
        case backendUnavailable(String), keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalidItem: return "The Pocket item is not valid."
            case .staleItem: return "This item is older than the saved version."
            case .missingItem: return "That item is not saved in Pocket sync."
            case .notConnected: return "Choose Connect before adding a Pocket item."
            case .crypto: return "Pocket encryption failed."
            case .invalidState: return "Saved Pocket sync state is invalid or too large."
            case .unsafePath: return "Pocket sync storage contains an unsafe symbolic link."
            case .invalidResponse: return "Pocket service returned invalid data."
            case .responseTooLarge: return "Pocket service response exceeded the size limit."
            case .backendUnavailable(let message): return message
            case .keychain(let code): return "Keychain operation failed (\(code))."
            }
        }
    }
}

private final class PocketNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct PocketSyncPanel: View {
    @ObservedObject var sync: PocketSync
    @State private var confirmRotation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pocket sync").font(.headline)
                Spacer()
                Circle().fill(sync.enabled ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(sync.enabled ? "On" : "Off").font(.caption)
            }
            Text(sync.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(sync.enabled ? "Connected" : "Connect phone") { sync.connect() }
                    .disabled(sync.enabled)
                Button("Show pairing") { sync.showPairing() }.disabled(!sync.enabled)
                if sync.pairingURL != nil {
                    Button("Hide") { sync.hidePairing() }
                }
                if sync.enabled { Button("Turn off") { sync.disable() } }
            }
            if let pairingURL = sync.pairingURL {
                Text(pairingURL.absoluteString)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Text("Anyone with this link can access this phone pairing secret.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                Text("\(sync.items.count) saved items").font(.caption)
                Spacer()
                Button("Rotate pairing secret…") { confirmRotation = true }
                    .font(.caption)
                    .confirmationDialog("Rotate the Pocket pairing secret?", isPresented: $confirmRotation, titleVisibility: .visible) {
                        Button("Use a new channel on this Mac", role: .destructive) { sync.revokeAndRotate() }
                    } message: {
                        Text("This Mac will switch to a new channel. A phone holding the old link can still access that old channel and its history.")
                }
            }
            let calendarRequests = sync.items.filter { $0.kind == .calendar }
            if !calendarRequests.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calendar captures").font(.subheadline.weight(.semibold))
                    ForEach(calendarRequests) { request in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.text).font(.caption)
                                if let details = request.calendarRequest {
                                    Text(Self.calendarRequestSummary(details))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(request.done ? "Added on phone" : "Calendar request · pending")
                                    .font(.caption2).foregroundStyle(request.done ? .green : .orange)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: 520, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private static func calendarRequestSummary(_ request: PocketItem.CalendarRequest) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start: Date?
        if let fractionalStart = formatter.date(from: request.startAt) {
            start = fractionalStart
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            start = formatter.date(from: request.startAt)
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let end: Date?
        if let fractionalEnd = formatter.date(from: request.endAt) {
            end = fractionalEnd
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            end = formatter.date(from: request.endAt)
        }
        guard let start, let end else {
            return "Date details unavailable"
        }
        let zone = TimeZone(identifier: request.timeZone) ?? .current
        let dayFormatter = DateFormatter()
        dayFormatter.timeZone = zone
        dayFormatter.dateStyle = .medium
        dayFormatter.timeStyle = .none
        if request.allDay {
            return "All day · \(dayFormatter.string(from: start)) · \(request.timeZone)"
        }
        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = zone
        timeFormatter.dateStyle = .medium
        timeFormatter.timeStyle = .short
        let endFormatter = DateFormatter()
        endFormatter.timeZone = zone
        endFormatter.dateStyle = .none
        endFormatter.timeStyle = .short
        return "\(timeFormatter.string(from: start))–\(endFormatter.string(from: end)) · \(request.timeZone)"
    }
}

enum PocketSyncTests {
    @MainActor static func run() throws {
        let token = String(repeating: "ab", count: 32)
        guard PocketSync.pairingURL(for: token)?.fragment == "pair=" + token,
              PocketSync.pairingURL(for: "not-a-secret") == nil else { throw PocketSync.PocketError.invalidState }
        let item = PocketItem(id: UUID().uuidString.lowercased(), kind: .todo, text: "offline fixture", done: false,
                              createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z")
        let legacyJSON = Data(#"{"id":"E931B8D2-8A31-48A0-BD60-0131521383F5","kind":"todo","text":"legacy capture","done":false,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}"#.utf8)
        let legacyItem = try JSONDecoder().decode(PocketItem.self, from: legacyJSON)
        guard legacyItem.calendarRequest == nil else { throw PocketSync.PocketError.invalidItem }
        let calendarItem = PocketItem(id: UUID().uuidString.lowercased(), kind: .calendar, text: "Dentist", done: false,
                                      createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
                                      calendarRequest: .init(startAt: "2026-01-02T00:00:00.000Z", endAt: "2026-01-03T00:00:00.000Z", allDay: true, timeZone: "America/Chicago"))
        guard PocketSync.valid(calendarItem),
              !PocketSync.valid(PocketItem(id: calendarItem.id, kind: .calendar, text: calendarItem.text, done: false,
                                           createdAt: calendarItem.createdAt, updatedAt: calendarItem.updatedAt)),
              !PocketSync.valid(PocketItem(id: calendarItem.id, kind: .calendar, text: calendarItem.text, done: false,
                                           createdAt: calendarItem.createdAt, updatedAt: calendarItem.updatedAt,
                                           calendarRequest: .init(startAt: "2026-01-03T00:00:00.000Z", endAt: "2026-01-02T00:00:00.000Z", allDay: true, timeZone: "America/Chicago"))),
              !PocketSync.valid(PocketItem(id: calendarItem.id, kind: .calendar, text: calendarItem.text, done: false,
                                           createdAt: calendarItem.createdAt, updatedAt: calendarItem.updatedAt,
                                           calendarRequest: .init(startAt: "2026-01-02T00:00:00.000Z", endAt: "2027-01-04T00:00:00.000Z", allDay: true, timeZone: "America/Chicago"))),
              !PocketSync.valid(PocketItem(id: calendarItem.id, kind: .calendar, text: calendarItem.text, done: false,
                                           createdAt: calendarItem.createdAt, updatedAt: calendarItem.updatedAt,
                                           calendarRequest: .init(startAt: "2026-01-02T00:00:00.000Z", endAt: "2026-01-03T00:00:00.000Z", allDay: true, timeZone: "Nowhere/NotATimeZone"))),
              !PocketSync.valid(PocketItem(id: item.id, kind: .todo, text: item.text, done: false,
                                           createdAt: item.createdAt, updatedAt: item.updatedAt, calendarRequest: calendarItem.calendarRequest)) else {
            throw PocketSync.PocketError.invalidItem
        }
        let roundTrip = try JSONDecoder().decode(PocketItem.self, from: JSONEncoder().encode(calendarItem))
        guard roundTrip == calendarItem else { throw PocketSync.PocketError.invalidItem }
        let duplicateMerge = PocketSync.merging([calendarItem], calendarItem)
        guard duplicateMerge.count == 1, duplicateMerge[0] == calendarItem else { throw PocketSync.PocketError.invalidItem }
        var completedCalendarItem = calendarItem
        completedCalendarItem.done = true
        completedCalendarItem.updatedAt = "2026-01-01T00:00:01.000Z"
        let updatedMerge = PocketSync.merging([calendarItem], completedCalendarItem)
        guard updatedMerge.count == 1, updatedMerge[0].done else { throw PocketSync.PocketError.invalidItem }
        var deletedTodo = item
        deletedTodo.deleted = true
        deletedTodo.updatedAt = "2026-01-01T00:00:02.000Z"
        var newerTodo = item
        newerTodo.updatedAt = "2026-01-01T00:00:03.000Z"
        let staleDeleteMerge = PocketSync.merging([newerTodo], deletedTodo)
        guard PocketSync.valid(deletedTodo), staleDeleteMerge.count == 1,
              staleDeleteMerge[0].deleted != true,
              PocketSync.merging([deletedTodo], deletedTodo) == [deletedTodo],
              PocketSync.visible([item, deletedTodo]) == [item] else { throw PocketSync.PocketError.invalidItem }
        let deletedJSON = try JSONEncoder().encode(deletedTodo)
        let restoredDeleted = try JSONDecoder().decode(PocketItem.self, from: deletedJSON)
        guard restoredDeleted.deleted == true else { throw PocketSync.PocketError.invalidItem }
        let legacyJSONWithNoDeletion = try JSONEncoder().encode(legacyItem)
        let restoredLegacy = try JSONDecoder().decode(PocketItem.self, from: legacyJSONWithNoDeletion)
        guard restoredLegacy.deleted == nil else { throw PocketSync.PocketError.invalidItem }
        let phoneUser = PocketChatMessage(id: UUID().uuidString.lowercased(), conversationID: UUID().uuidString.lowercased(),
                                          role: .user, text: "What time is it?", createdAt: item.createdAt)
        let phoneChef = PocketChatMessage(id: UUID().uuidString.lowercased(), conversationID: phoneUser.conversationID,
                                          role: .chef, text: "I can help with that.", createdAt: item.updatedAt, replyToID: phoneUser.id)
        let phoneChunk = PocketVoiceChunk(id: UUID().uuidString.lowercased(), messageID: phoneChef.id, index: 0, count: 1,
                                          data: Data(repeating: 1, count: 6000).base64EncodedString())
        guard PocketSync.valid(phoneUser), PocketSync.valid(phoneChef), PocketSync.valid(phoneChunk),
              !PocketSync.valid(PocketChatMessage(id: "bad", conversationID: phoneUser.conversationID, role: .user, text: "hello", createdAt: item.createdAt)),
              !PocketSync.valid(PocketChatMessage(id: phoneChef.id, conversationID: phoneUser.conversationID, role: .chef, text: String(repeating: "x", count: 401), createdAt: item.updatedAt, replyToID: phoneUser.id)),
              !PocketSync.valid(PocketVoiceChunk(id: phoneChunk.id, messageID: phoneChef.id, index: 1, count: 1, data: phoneChunk.data)),
              !PocketSync.valid(PocketVoiceChunk(id: phoneChunk.id, messageID: phoneChef.id, index: 0, count: 1, data: String(repeating: "A", count: 8001))) else {
            throw PocketSync.PocketError.invalidResponse
        }
        let briefing = PocketBriefingRequest(id: UUID().uuidString.lowercased(), conversationID: phoneUser.conversationID,
                                             requestType: .now, request: "Give me a briefing", createdAt: item.createdAt)
        guard PocketSync.valid(briefing),
              !PocketSync.valid(PocketBriefingRequest(id: "bad", conversationID: briefing.conversationID, requestType: .now,
                                                       request: briefing.request, createdAt: briefing.createdAt)),
              !PocketSync.valid(PocketBriefingRequest(id: briefing.id, conversationID: briefing.conversationID, requestType: .schedule,
                                                       request: "Buy shares", createdAt: briefing.createdAt)) else { throw PocketSync.PocketError.invalidResponse }
        let legacyState = Data(#"{"cursor":0,"items":[],"pending":[],"resumeEnabled":false}"#.utf8)
        guard PocketSync.legacyStateHasEmptyChat(legacyState) else { throw PocketSync.PocketError.invalidState }
        guard !PocketSync.valid(PocketItem(id: UUID().uuidString.lowercased(), kind: .thought, text: "note", done: false,
                                           createdAt: item.createdAt, updatedAt: item.updatedAt, deleted: true)) else {
            throw PocketSync.PocketError.invalidItem
        }
        // Produced by WebCrypto AES-GCM with IV 000102030405060708090a0b, the key
        // derived from this fixture token, and the cleartext below. Combined form is IV || ciphertext || tag.
        let webCryptoCombined = Data(base64Encoded: "AAECAwQFBgcICQoLWkSf/dtOBGJ29NoZsT7Jk8dXnxls/d1czgw8fYhX3VFbHr/yNBFk4g==")!
        let webCryptoClear = Data("webcrypto pocket fixture".utf8)
        let nativeSealed = try PocketSync.seal(webCryptoClear, token: token)
        guard try PocketSync.open(webCryptoCombined, token: token) == webCryptoClear,
              try PocketSync.open(nativeSealed, token: token) == webCryptoClear else {
            throw PocketSync.PocketError.crypto
        }
        let itemJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
        let envelope = try JSONSerialization.data(withJSONObject: ["v": 1, "op": "upsert", "item": itemJSON], options: [.sortedKeys])
        guard let object = try JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              object["op"] as? String == "upsert", object["v"] as? Int == 1,
              let raw = object["item"] as? [String: Any], UUID(uuidString: raw["id"] as? String ?? "") != nil,
              raw["kind"] as? String == "todo" else { throw PocketSync.PocketError.invalidResponse }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PocketSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateFile = directory.appendingPathComponent("state.json")
        let pendingID = UUID().uuidString.lowercased()
        let pendingCiphertext = "AA=="
        let fixture = TestState(cursor: 7, items: [item],
                                pending: [PendingFixture(id: pendingID, itemID: item.id, payload: pendingCiphertext)],
                                resumeEnabled: false)
        let testState = try JSONEncoder().encode(fixture)
        try testState.write(to: stateFile, options: .atomic)
        let restored = try JSONDecoder().decode(TestState.self, from: Data(contentsOf: stateFile))
        guard restored.cursor == 7, restored.items.count == 1, restored.pending.count == 1,
              restored.pending[0].id == pendingID, restored.pending[0].itemID == item.id,
              restored.pending[0].payload == pendingCiphertext, !restored.resumeEnabled else {
            throw PocketSync.PocketError.invalidState
        }
    }
    private struct TestState: Codable {
        var cursor: Int
        var items: [PocketItem]
        var pending: [PendingFixture]
        var resumeEnabled: Bool
    }
    private struct PendingFixture: Codable { var id: String; var itemID: String; var payload: String }
}
