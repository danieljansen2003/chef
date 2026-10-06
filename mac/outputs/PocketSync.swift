import Foundation
import SwiftUI
import CryptoKit
import Security
import Darwin

struct PocketItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case todo, thought }
    var id: String
    var kind: Kind
    var text: String
    var done: Bool
    var createdAt: String
    var updatedAt: String

    var uuid: UUID? { UUID(uuidString: id) }
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
    }
    private struct Envelope: Codable {
        var v: Int = 1
        var op: String = "upsert"
        var item: PocketItem
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
        guard item.kind == .todo else { throw PocketError.invalidItem }
        item.done = done
        item.updatedAt = Self.timestamp(Date())
        try enqueue(item)
    }

    func importLocalItem(_ item: PocketItem) throws {
        guard Self.valid(item) else { throw PocketError.invalidItem }
        guard !state.items.contains(where: { $0.id == item.id && (Self.date($0.updatedAt) ?? .distantPast) >= (Self.date(item.updatedAt) ?? .distantPast) }) else { return }
        var candidate = state
        if let index = candidate.items.firstIndex(where: { $0.id == item.id }) { candidate.items[index] = item }
        else { candidate.items.append(item) }
        if let token {
            let payload = try Self.seal(Self.encode(item), token: token)
            candidate.pending.append(Pending(id: UUID().uuidString.lowercased(), itemID: item.id, payload: payload.base64EncodedString()))
        }
        try save(candidate)
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
            if notify { try onImportedItem?(item) }
            return
        }
        var candidate = state
        if let index = candidate.items.firstIndex(where: { $0.id == item.id }) { candidate.items[index] = item }
        else { candidate.items.append(item) }
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
                guard envelope.v == 1, envelope.op == "upsert", Self.valid(envelope.item) else { throw PocketError.invalidResponse }
                try merge(envelope.item, notify: true)
                var advanced = state
                advanced.cursor = event.seq
                try save(advanced)
            }
            var advanced = state
            advanced.cursor = max(advanced.cursor, response.cursor)
            try save(advanced)
            status = "Synced \(state.items.count) items. Last checked just now."
        } catch {
            guard enabled, self.token == token, generation == self.syncGeneration else { return }
            status = "Sync paused: \(error.localizedDescription). Local changes remain saved."
        }
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
              decoded.items.allSatisfy(Self.valid),
              decoded.pending.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.itemID) != nil && (Data(base64Encoded: $0.payload)?.count ?? 0) <= 16_384 }) else {
            throw PocketError.invalidState
        }
        state = decoded
        items = decoded.items.sorted { (Self.date($0.updatedAt) ?? .distantPast) > (Self.date($1.updatedAt) ?? .distantPast) }
    }

    private func save(_ candidate: State) throws {
        try Self.checkPath(root: root, file: stateURL, allowMissingLeaf: true)
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= 4_000_000 else { throw PocketError.invalidState }
        try data.write(to: stateURL, options: .atomic)
        state = candidate
        items = candidate.items.sorted { (Self.date($0.updatedAt) ?? .distantPast) > (Self.date($1.updatedAt) ?? .distantPast) }
    }

    private func persist() throws { try save(state) }

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

    private static func valid(_ item: PocketItem) -> Bool {
        guard UUID(uuidString: item.id) != nil, item.text.count <= maxText,
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.createdAt.count <= 40, item.updatedAt.count <= 40,
              let c = date(item.createdAt),
              let u = date(item.updatedAt), u >= c else { return false }
        return true
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
        }
        .padding()
        .frame(maxWidth: 520, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

enum PocketSyncTests {
    @MainActor static func run() throws {
        let token = String(repeating: "ab", count: 32)
        guard PocketSync.pairingURL(for: token)?.fragment == "pair=" + token,
              PocketSync.pairingURL(for: "not-a-secret") == nil else { throw PocketSync.PocketError.invalidState }
        let item = PocketItem(id: UUID().uuidString.lowercased(), kind: .todo, text: "offline fixture", done: false,
                              createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z")
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