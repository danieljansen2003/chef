import Foundation
import Security

struct AllowanceWindow: Codable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
}
struct AllowanceBucket: Codable {
    let limitId: String?
    let limitName: String?
    let primary: AllowanceWindow?
    let secondary: AllowanceWindow?
}
struct AllowanceReply: Codable {
    let rateLimits: AllowanceBucket?
    let rateLimitsByLimitId: [String: AllowanceBucket]?
    var bucket: AllowanceBucket? { rateLimitsByLimitId?["codex"] ?? rateLimits }
}
struct AllowanceSnapshot: Codable {
    let fetchedAt: Date
    let limits: AllowanceReply
    func spoken(at now: Date = Date()) -> String {
        guard let bucket = limits.bucket else { return "Codex hasn't supplied usage limits for this account." }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = "EEE, MMM d 'at' h:mm a z"
        func describe(_ window: AllowanceWindow?, _ label: String) -> String? {
            guard let window else { return nil }
            let percent = window.usedPercent.flatMap { $0.isFinite ? max(0, min(100, 100 - $0)) : nil }
            var text = label + ": " + (percent.map { String(format: "%.0f%% remaining", $0) } ?? "remaining percentage unavailable")
            if let reset = window.resetsAt, reset.isFinite, reset > 0 {
                let date = Date(timeIntervalSince1970: reset)
                text += date <= now ? "; its recorded reset has passed, so refresh for the new allowance" : "; resets " + formatter.string(from: date)
            } else { text += "; reset time unavailable" }
            return text + "."
        }
        let windows = [describe(bucket.primary, bucket.primary?.windowDurationMins == 300 ? "Five-hour Codex allowance" : "Primary Codex allowance"), describe(bucket.secondary, bucket.secondary?.windowDurationMins == 10080 ? "Weekly Codex allowance" : "Secondary Codex allowance")].compactMap { $0 }
        guard !windows.isEmpty else { return "Codex hasn't supplied usage windows for this account." }
        return windows.joined(separator: " ") + " These are Codex limits, not regular ChatGPT chat limits or an exact number of tokens left. Checked " + formatter.string(from: fetchedAt) + "."
    }
}

// Fixed signed SDK executable, fixed arguments, fixed read-only protocol.
// Never pass user/model text to this process or add thread/turn/billing/reset methods.
enum CodexAllowance {
    static let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    static func trustedExecutable() -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple generic and identifier codex and certificate leaf[subject.OU] = \"2DC432GLL2\"" as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    static func fetch() async throws -> AllowanceSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try read()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func read() throws -> AllowanceSnapshot {
        guard trustedExecutable() else { throw UsageError.clientMissing }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func receive(_ id: Int) throws -> Data {
            for _ in 0..<64 {
                var line = Data()
                while line.count < 262144 {
                    let byte = output.fileHandleForReading.readData(ofLength: 1)
                    guard !byte.isEmpty else { throw UsageError.unavailable }
                    if byte.first == 10 { break }
                    line.append(byte)
                }
                guard line.count < 262144, let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw UsageError.unavailable }
                if value["id"] as? Int == id {
                    guard value["error"] == nil, let result = value["result"] else { throw UsageError.unavailable }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                // Notifications are ignored; unexpected server requests are never acted upon.
            }
            throw UsageError.unavailable
        }
        try send(["method": "initialize", "id": 0, "params": ["clientInfo": ["name": "chef_usage_reader", "version": "0.6.0"]]])
        _ = try receive(0)
        try send(["method": "initialized", "params": [:]])
        try send(["method": "account/rateLimits/read", "id": 1])
        let limits = try JSONDecoder().decode(AllowanceReply.self, from: receive(1))
        guard limits.bucket != nil else { throw UsageError.unavailable }
        return AllowanceSnapshot(fetchedAt: Date(), limits: limits)
    }
    enum UsageError: LocalizedError {
        case clientMissing, unavailable
        var errorDescription: String? {
            switch self {
            case .clientMissing: return "The approved signed Codex client wasn't found. Open Codex and ask this chat to refresh the usage connection."
            case .unavailable: return "I couldn't read live Codex usage. Make sure you're signed in to Codex with your ChatGPT account. No credits or resets were used."
            }
        }
    }
    static func test() {
        let window = AllowanceWindow(usedPercent: 39, windowDurationMins: 300, resetsAt: 1790965101)
        let limits = AllowanceReply(rateLimits: AllowanceBucket(limitId: "codex", limitName: nil, primary: window, secondary: nil), rateLimitsByLimitId: nil)
        let snapshot = AllowanceSnapshot(fetchedAt: Date(timeIntervalSince1970: 1790956800), limits: limits)
        precondition(snapshot.spoken(at: snapshot.fetchedAt).contains("61% remaining"))
        precondition(snapshot.spoken(at: snapshot.fetchedAt).contains("1:18 PM CDT"))
        precondition(snapshot.spoken(at: Date(timeIntervalSince1970: 1790965200)).contains("recorded reset has passed"))
        let missing = AllowanceSnapshot(fetchedAt: Date(), limits: AllowanceReply(rateLimits: nil, rateLimitsByLimitId: nil))
        precondition(missing.spoken().contains("hasn't supplied"))
        print("Usage percentage, Central-time resets, expired-reset and unavailable-data checks passed.")
    }
}
