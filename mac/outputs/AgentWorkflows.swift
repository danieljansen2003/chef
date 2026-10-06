import Foundation

/// Persistent, local-only daily workflows and explicitly learned worker guidance.
/// The store never executes model-authored actions. Callers decide how to run a
/// due briefing using the fixed public-information and personal-app surfaces.
enum AgentWorkflowCommand: Equatable {
    case scheduleBriefing(hour: Int, minute: Int)
    case scheduleBriefingOnce(at: Date)
    case cancelBriefing
    case setLocation(String)
    case rememberSkill(group: String, text: String)
}

/// The same bounded topic classifier controls worker selection and whether a
/// saved briefing may use the public Fish reply path.
struct AgentBriefingScope: Equatable {
    let weather: Bool
    let news: Bool
    let tasks: Bool
    let stockMarket: Bool
    let includesPrivateData: Bool

    init(request: String?, oneShot: Bool) {
        let text = (request ?? "").lowercased()
        let hasWeather = Self.matches(#"\b(weather|forecast)\w*\b"#, in: text)
        let hasStockMarket = Self.matches(#"\b(stock|market|invest)\w*\b"#, in: text)
        let hasNews = Self.matches(#"\b(stock|market|news|business|headline|invest)\w*\b"#, in: text)
        let hasTasks = Self.matches(#"\b(todo|to\s*-\s*do|to\s+do|task|reminder)\w*\b"#, in: text)
        let hasCalendar = Self.matches(#"\b(calendar|appointment)\w*\b"#, in: text)
        let hasExplicitScope = hasWeather || hasNews || hasTasks || hasCalendar
        let defaultsToFullBriefing = !oneShot || !hasExplicitScope
        weather = defaultsToFullBriefing || hasWeather
        news = defaultsToFullBriefing || hasNews
        tasks = defaultsToFullBriefing || hasTasks
        stockMarket = hasStockMarket
        includesPrivateData = tasks || hasCalendar
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func test() throws {
        let stocksAndTodos = Self(request: "Stocks and my to-do list", oneShot: true)
        guard stocksAndTodos.news, stocksAndTodos.tasks, stocksAndTodos.stockMarket, !stocksAndTodos.weather, stocksAndTodos.includesPrivateData else { throw AgentWorkflowStore.StoreError.invalid }
        let unspecified = Self(request: "Briefing in two minutes", oneShot: true)
        guard unspecified.weather, unspecified.news, unspecified.tasks, unspecified.includesPrivateData, !unspecified.stockMarket else { throw AgentWorkflowStore.StoreError.invalid }
        let publicOnly = Self(request: "Weather and business headlines", oneShot: true)
        guard publicOnly.weather, publicOnly.news, !publicOnly.tasks, !publicOnly.stockMarket, !publicOnly.includesPrivateData else { throw AgentWorkflowStore.StoreError.invalid }
        let forecastOnly = Self(request: "Tomorrow's forecast", oneShot: true)
        guard forecastOnly.weather, !forecastOnly.news, !forecastOnly.tasks, !forecastOnly.includesPrivateData else { throw AgentWorkflowStore.StoreError.invalid }
    }
}

enum AgentWorkflowRouting {
    /// Whitespace- and punctuation-tolerant parser for short spoken commands.
    /// It accepts only the four supported command families.
    static func parse(_ raw: String, existingBriefing: Bool = false, now: Date = Date(), timezone: String = "America/Chicago") -> AgentWorkflowCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 1200, !PersonalWorkspace.hasCredential(text), !Safety.blocked(text) else { return nil }
        guard text.range(of: #"\b(?:don't|do not|never)\b.{0,40}\b(?:schedule|reschedule|set|change|create|make|remind|remember|learn)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        guard text.range(of: #"(?is)[\"“‘][^\"”’]*(?:schedule|reschedule|set|change|create|make|brief(?:ing)?)[^\"”’]*[\"”’]"#, options: .regularExpression) == nil else { return nil }
        let lower = text.lowercased().replacingOccurrences(of: #"[^a-z0-9:,. ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let direct = lower.replacingOccurrences(of: #"^(?:(?:no[, ]*but|okay[, ]*then|ok[, ]*then)[, ]*)?(?:hey\s+chef[, ]*)?(?:please\s+)?(?:(?:can you|could you|would you)\s+)?"#, with: "", options: .regularExpression)
        let directVerb = direct.range(of: #"^(?:give|assign|schedule|reschedule|set|brief|make|create|cancel|stop|remove|unschedule|change|use|remember|learn|i want|i need)\b"#, options: .regularExpression) != nil
        let existingTimeFollowup = existingBriefing && direct.range(of: #"^at\s*\d{1,2}(?::\d{2})?"#, options: .regularExpression) != nil
        guard directVerb || existingTimeFollowup,
              !text.contains("\"") && !text.contains("“") && !text.contains("”") && !text.contains("‘") && !text.contains("’") else { return nil }
        if lower.range(of: #"\b(?:cancel|stop|remove|unschedule)\b.*\b(?:briefing|daily briefing)\b|\b(?:cancel|stop|remove|unschedule)\b.*\bbrief\b"#, options: .regularExpression) != nil {
            return .cancelBriefing
        }
        if lower.range(of: #"\b(?:remember|learn)\b"#, options: .regularExpression) != nil {
            guard lower.contains("agent") || lower.contains("playbook") || lower.hasPrefix("learn ") else { return nil }
            guard let range = lower.range(of: #"\b(?:remember|learn)(?:\s+(?:that|this|for\s+the\s+\w+\s+agent))?\s+"#, options: .regularExpression) else { return nil }
            let rawRange = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound), limitedBy: text.endIndex) ?? text.endIndex
            let lesson = String(text[rawRange...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !lesson.isEmpty else { return nil }
            let group: String
            if lower.contains("weather") { group = "Weather" }
            else if lower.contains("news") { group = "News" }
            else if lower.contains("todo") || lower.contains("task") { group = "Tasks" }
            else if lower.contains("app") || lower.contains("calendar") || lower.contains("email") || lower.contains("reminder") { group = "Apps" }
            else if lower.contains("code") || lower.contains("repository") || lower.contains("ecc") { group = "Code" }
            else if lower.contains("knowledge") || lower.contains("reference") || lower.contains("research") { group = "Knowledge" }
            else { group = "Briefing" }
            return .rememberSkill(group: group, text: String(lesson.prefix(500)))
        }
        if lower.range(of: #"\b(?:set|change|use)\s+(?:my\s+)?(?:briefing\s+)?location\b"#, options: .regularExpression) != nil {
            guard let r = lower.range(of: #"\b(?:to|in|for)\s+(.+)$"#, options: .regularExpression),
                  let city = lower[r].split(separator: " ").dropFirst().joined(separator: " ").removingPercentEncoding,
                  !city.isEmpty, city.count <= 100 else { return nil }
            return .setLocation(city.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let hasBriefing = lower.range(of: #"\b(?:briefing|breifing|brief)\b"#, options: .regularExpression) != nil
        let refersToExistingBriefing = existingBriefing && (lower.range(of: #"\bit\b"#, options: .regularExpression) != nil || existingTimeFollowup)
        let hasSchedule = lower.range(of: #"\b(?:give|want|schedule|reschedule|set|change|create|make|daily|every\s+day|remind|brief)\b"#, options: .regularExpression) != nil || existingTimeFollowup
        if (hasBriefing || refersToExistingBriefing) && hasSchedule,
           let relative = lower.range(of: #"\bin\s+(\d{1,4})\s+(mins?|minutes?|hrs?|hours?)\b"#, options: .regularExpression) {
            let pieces = lower[relative].split(separator: " ")
            guard pieces.count == 3, let amount = Int(pieces[1]), amount > 0,
                  let unit = pieces.last?.lowercased() else { return nil }
            let seconds = unit.hasPrefix("h") ? amount * 3600 : amount * 60
            guard seconds <= 7 * 24 * 60 * 60 else { return nil }
            return .scheduleBriefingOnce(at: now.addingTimeInterval(TimeInterval(seconds)))
        }
        guard (hasBriefing || refersToExistingBriefing) && hasSchedule,
              let match = lower.range(of: #"\b(?:(?:at|for|to)\s*)?(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?\b"#, options: .regularExpression) else { return nil }
        let parts = lower[match].replacingOccurrences(of: " ", with: "")
        guard let nums = parts.range(of: #"\d{1,2}(?::\d{2})?"#, options: .regularExpression) else { return nil }
        let time = String(parts[nums]).split(separator: ":")
        guard var hour = Int(time[0]), let minute = time.count == 2 ? Int(time[1]) : 0, minute < 60 else { return nil }
        let suffix = String(parts[nums.upperBound...]).lowercased()
        if suffix.contains("p") && hour < 12 { hour += 12 }
        if suffix.contains("a") && hour == 12 { hour = 0 }
        guard (0...23).contains(hour) else { return nil }
        if lower.range(of: #"\btomorrow\b"#, options: .regularExpression) != nil,
           lower.range(of: #"\b(?:daily|every\s+day|each\s+day)\b"#, options: .regularExpression) == nil {
            var calendar = Calendar(identifier: .gregorian)
            guard let zone = TimeZone(identifier: timezone) else { return nil }
            calendar.timeZone = zone
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  let due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow), due > now else { return nil }
            return .scheduleBriefingOnce(at: due)
        }
        return .scheduleBriefing(hour: hour, minute: minute)
    }
}

struct AgentWorkflowIdentity: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let group: String
    let colorKey: String
    let symbol: String
    static let briefingWorkers = [
        Self(id: "Nova", title: "Weather", group: "Briefing", colorKey: "Nova", symbol: "cloud.sun"),
        Self(id: "Iris", title: "News", group: "Briefing", colorKey: "Iris", symbol: "newspaper"),
        Self(id: "Atlas", title: "Tasks", group: "Briefing", colorKey: "Atlas", symbol: "checklist")
    ]
}

struct AgentWorkflow: Codable, Identifiable, Equatable {
    enum State: String, Codable { case scheduled, running, succeeded, failed, missed, cancelled }
    let id: String
    var title: String
    var group: String
    var workerIDs: [String]
    var hour: Int
    var minute: Int
    var timezone: String
    var location: String
    var state: State
    var createdAt: Date
    var lastRunDay: String?
    // Optional fields keep previously saved workflow documents decodable.
    var lastRunOccurrenceKey: String?
    var handledOccurrenceKeys: [String]?
    var lastStartedAt: Date?
    var lastFinishedAt: Date?
    var lastOutcome: String?
    var lastReport: String? = nil
    var workerResults: [String: String]? = nil
    var nextRun: Date?
    /// Non-nil only for user-requested one-shot briefings. Older daily files
    /// decode with nil and retain their existing recurrence behavior.
    var oneShotAt: Date? = nil
    var requestSummary: String? = nil
    var phoneConversationID: String? = nil
    var phoneRequestID: String? = nil
    var deliveryPending: Bool? = nil
    var deliveredAt: Date? = nil
}

struct AgentPlaybook: Codable, Equatable {
    var group: String
    var lessons: [String] = []
    var useCount = 0
    var successCount = 0
    var failureCount = 0
    var lastSuccess: Date?
    var lastFailure: Date?
    var objectives: [String] = []
}

final class AgentWorkflowStore {
    enum StoreError: Error { case invalid, unsafePath, full, missing, alreadyRunning }
    private struct Document: Codable { var workflows: [AgentWorkflow] = []; var playbooks: [AgentPlaybook] = [] }
    private let root: URL
    private let fm = FileManager.default
    private let lock = NSLock()
    private let calendar: Calendar
    private let maxBytes = 128 * 1024
    private let maxWorkflows = 16
    private let catchupWindow: TimeInterval = 2 * 60 * 60
    private let oneShotPreparationWindow: TimeInterval = 45

    init(root: URL? = nil, timezone: String = "America/Chicago") {
        let home = Bundle.main.object(forInfoDictionaryKey: ChefCompatibility.key("ChefWorkspacePath")) as? String ?? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path
        self.root = root ?? URL(fileURLWithPath: home).appendingPathComponent(ChefCompatibility.path("outputs/Chef Home/workflows"), isDirectory: true)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "America/Chicago")!; self.calendar = cal
    }

    func prepare() throws {
        try validateRoot(create: true)
        if !fm.fileExists(atPath: file.path) { try write(Document()) }
    }
    private var file: URL { root.appendingPathComponent("state.json") }
    private func validateRoot(create: Bool) throws {
        let canonical = root.standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == canonical.path else { throw StoreError.unsafePath }
        if create { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == canonical.path else { throw StoreError.unsafePath }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { throw StoreError.unsafePath }
        let attrs = try fm.attributesOfItem(atPath: root.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.unsafePath }
        if let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw StoreError.unsafePath }
        if fm.fileExists(atPath: file.path), (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw StoreError.unsafePath }
    }
    private func read() throws -> Document {
        try validateRoot(create: true)
        guard let data = try? Data(contentsOf: file), data.count <= maxBytes, let doc = try? JSONDecoder.workflow.decode(Document.self, from: data), doc.workflows.count <= maxWorkflows, doc.playbooks.count <= 8 else { throw StoreError.invalid }
        return doc
    }
    private func write(_ doc: Document) throws {
        try validateRoot(create: true)
        let data = try JSONEncoder.workflow.encode(doc)
        guard data.count <= maxBytes else { throw StoreError.full }
        try data.write(to: file, options: .atomic)
    }
    func workflows() throws -> [AgentWorkflow] { lock.lock(); defer { lock.unlock() }; return try read().workflows.sorted { $0.createdAt > $1.createdAt } }
    func playbooks() throws -> [AgentPlaybook] { lock.lock(); defer { lock.unlock() }; return try read().playbooks }
    func lessons(for group: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let book = try read().playbooks.first(where: { $0.group == group }) else { return "" }
        return book.lessons.suffix(8).map { "- " + $0 }.joined(separator: "\n")
    }
    @discardableResult func scheduleBriefing(hour: Int, minute: Int, location: String = "", phoneConversationID: String? = nil, phoneRequestID: String? = nil, at now: Date = Date()) throws -> AgentWorkflow {
        guard (0...23).contains(hour), (0..<60).contains(minute), location.count <= 100,
              !PersonalWorkspace.hasCredential(location), !Safety.blocked(location),
              (phoneConversationID == nil && phoneRequestID == nil) || (phoneConversationID.flatMap(UUID.init(uuidString:)) != nil && phoneRequestID.flatMap(UUID.init(uuidString:)) != nil) else { throw StoreError.invalid }
        lock.lock(); defer { lock.unlock() }
        var doc = try read()
        guard doc.workflows.count < maxWorkflows else { throw StoreError.full }
        let next = nextOccurrence(hour: hour, minute: minute, after: now)
        if let index = doc.workflows.firstIndex(where: { $0.id == "daily-briefing" }) {
            var item = doc.workflows[index]
            guard item.state != .running else { throw StoreError.alreadyRunning }
            let today = Self.dayFormatter(calendar.timeZone).string(from: calendar.startOfDay(for: now))
            // Migrate the single legacy day claim to the exact clock it was
            // recorded against before applying a spoken time change.
            if item.lastRunDay == today, item.lastRunOccurrenceKey == nil {
                let oldKey = Self.occurrenceKey(day: today, hour: item.hour, minute: item.minute)
                Self.record(oldKey, in: &item); item.lastRunOccurrenceKey = oldKey
            }
            let newKey = Self.occurrenceKey(day: today, hour: hour, minute: minute)
            let alreadyHandled = (item.handledOccurrenceKeys ?? []).contains(newKey)
            item.hour = hour; item.minute = minute; item.location = location; item.timezone = calendar.timeZone.identifier
            if let phoneConversationID, let phoneRequestID { item.phoneConversationID = phoneConversationID; item.phoneRequestID = phoneRequestID }
            item.state = alreadyHandled ? item.state : .scheduled
            item.nextRun = next; doc.workflows[index] = item
            try write(doc); return item
        }
        let item = AgentWorkflow(id: "daily-briefing", title: "Daily Briefing", group: "Briefing", workerIDs: AgentWorkflowIdentity.briefingWorkers.map(\.id), hour: hour, minute: minute, timezone: calendar.timeZone.identifier, location: location, state: .scheduled, createdAt: now, lastRunDay: nil, lastRunOccurrenceKey: nil, handledOccurrenceKeys: nil, lastStartedAt: nil, lastFinishedAt: nil, lastOutcome: nil, nextRun: next, phoneConversationID: phoneConversationID, phoneRequestID: phoneRequestID)
        doc.workflows.append(item); try write(doc); return item
    }
    /// Adds a bounded one-time briefing to the same durable claim queue used by
    /// daily briefings. The app must be running and awake when it becomes due.
    @discardableResult func scheduleOneShotBriefing(at date: Date, location: String = "", request: String = "", phoneConversationID: String? = nil, phoneRequestID: String? = nil, now: Date = Date()) throws -> AgentWorkflow {
        let city = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard date > now, date.timeIntervalSince(now) <= 30 * 24 * 60 * 60,
              city.count <= 100, objective.count <= 500,
              !PersonalWorkspace.hasCredential(city), !Safety.blocked(city),
              !PersonalWorkspace.hasCredential(objective), !Safety.blocked(objective),
              (phoneConversationID == nil && phoneRequestID == nil) || (phoneConversationID.flatMap(UUID.init(uuidString:)) != nil && phoneRequestID.flatMap(UUID.init(uuidString:)) != nil) else { throw StoreError.invalid }
        lock.lock(); defer { lock.unlock() }
        var doc = try read()
        // Keep active jobs and the daily workflow. Completed one-shot history
        // can be discarded when capacity is needed; their claim is no longer
        // runnable, so removing it cannot cause duplicate delivery.
        if doc.workflows.count >= maxWorkflows {
            let removable = doc.workflows.indices.filter { doc.workflows[$0].oneShotAt != nil && doc.workflows[$0].state != .scheduled && doc.workflows[$0].state != .running && doc.workflows[$0].deliveryPending != true }
            for index in removable.reversed() where doc.workflows.count >= maxWorkflows { doc.workflows.remove(at: index) }
        }
        guard doc.workflows.count < maxWorkflows else { throw StoreError.full }
        let inheritedCity = city.isEmpty ? (doc.workflows.first(where: { $0.id == "daily-briefing" })?.location ?? "") : city
        var dateCalendar = Calendar(identifier: .gregorian)
        dateCalendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let parts = dateCalendar.dateComponents([.hour, .minute], from: date)
        let scope = AgentBriefingScope(request: objective.isEmpty ? nil : objective, oneShot: true)
        let requestedWorkers = zip(AgentWorkflowIdentity.briefingWorkers, [scope.weather, scope.news, scope.tasks]).filter { $0.1 }.map { $0.0.id }
        let item = AgentWorkflow(id: "briefing-once-" + UUID().uuidString.lowercased(), title: objective.isEmpty ? "One-time Briefing" : String(objective.prefix(80)), group: "Briefing", workerIDs: requestedWorkers, hour: parts.hour ?? 0, minute: parts.minute ?? 0, timezone: "America/Chicago", location: inheritedCity, state: .scheduled, createdAt: now, lastRunDay: nil, lastRunOccurrenceKey: nil, handledOccurrenceKeys: nil, lastStartedAt: nil, lastFinishedAt: nil, lastOutcome: nil, nextRun: date, oneShotAt: date, requestSummary: objective.isEmpty ? nil : objective, phoneConversationID: phoneConversationID, phoneRequestID: phoneRequestID)
        doc.workflows.append(item); try write(doc); return item
    }
    func cancelOneShotBriefing(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var doc = try read()
        guard let index = doc.workflows.firstIndex(where: { $0.id == id && $0.oneShotAt != nil }) else { throw StoreError.missing }
        guard doc.workflows[index].state == .scheduled else { throw StoreError.alreadyRunning }
        doc.workflows[index].state = .cancelled; doc.workflows[index].lastFinishedAt = Date()
        doc.workflows[index].lastOutcome = "Cancelled by the human before it ran."
        try write(doc)
    }
    func pendingDelivery(at now: Date = Date()) throws -> AgentWorkflow? {
        lock.lock(); defer { lock.unlock() }
        return try read().workflows.first(where: { $0.deliveryPending == true && $0.lastReport != nil && ($0.oneShotAt == nil || $0.oneShotAt! <= now) })
    }
    func markDelivered(id: String, at now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var doc = try read()
        guard let index = doc.workflows.firstIndex(where: { $0.id == id && $0.deliveryPending == true && $0.lastReport != nil && ($0.oneShotAt == nil || $0.oneShotAt! <= now) }) else { throw StoreError.missing }
        doc.workflows[index].deliveryPending = false; doc.workflows[index].deliveredAt = now
        try write(doc)
    }
    func cancelBriefing() throws {
        lock.lock(); defer { lock.unlock() }
        var doc = try read()
        if let item = doc.workflows.first(where: { $0.id == "daily-briefing" }), (item.state == .running || item.deliveryPending == true) {
            throw StoreError.alreadyRunning
        }
        doc.workflows.removeAll { $0.id == "daily-briefing" }; try write(doc)
    }
    func setLocation(_ location: String) throws {
        let value = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 100, !PersonalWorkspace.hasCredential(value), !Safety.blocked(value) else { throw StoreError.invalid }
        lock.lock(); defer { lock.unlock() }
        var doc = try read(); guard let index = doc.workflows.firstIndex(where: { $0.id == "daily-briefing" }) else { throw StoreError.missing }
        doc.workflows[index].location = value; try write(doc)
    }
    /// Atomically claims at most one run per local calendar day. A briefing up
    /// to two hours late is caught up; older occurrences become missed.
    func due(at now: Date = Date()) throws -> [AgentWorkflow] {
        lock.lock(); defer { lock.unlock() }
        var doc = try read(); var claimed: [AgentWorkflow] = []; var changed = false
        for i in doc.workflows.indices where claimed.isEmpty && doc.workflows[i].state != .cancelled && doc.workflows[i].state != .running {
            guard doc.workflows[i].deliveryPending != true else { continue }
            if let target = doc.workflows[i].oneShotAt {
                guard doc.workflows[i].state == .scheduled, now >= target.addingTimeInterval(-oneShotPreparationWindow) else { continue }
                if now.timeIntervalSince(target) > catchupWindow {
                    doc.workflows[i].state = .missed; doc.workflows[i].lastFinishedAt = now
                    doc.workflows[i].lastOutcome = "Missed; outside the two-hour catch-up window."
                    changed = true; continue
                }
                doc.workflows[i].state = .running; doc.workflows[i].lastStartedAt = now
                doc.workflows[i].lastRunDay = Self.dayFormatter(calendar.timeZone).string(from: calendar.startOfDay(for: target))
                doc.workflows[i].lastRunOccurrenceKey = doc.workflows[i].id
                doc.workflows[i].nextRun = nil; claimed.append(doc.workflows[i]); continue
            }
            let local = calendar.dateComponents([.year, .month, .day], from: now)
            guard let dayDate = calendar.date(from: local) else { continue }
            let day = Self.dayFormatter(calendar.timeZone).string(from: dayDate)
            guard let todayTarget = calendar.date(bySettingHour: doc.workflows[i].hour, minute: doc.workflows[i].minute, second: 0, of: dayDate) else { continue }
            let todayKey = Self.occurrenceKey(day: day, hour: doc.workflows[i].hour, minute: doc.workflows[i].minute)
            // Old files had only a day claim. Treat it as the current saved
            // clock unless scheduleBriefing already migrated it on edit.
            if doc.workflows[i].lastRunDay == day, doc.workflows[i].lastRunOccurrenceKey == nil {
                Self.record(todayKey, in: &doc.workflows[i]); doc.workflows[i].lastRunOccurrenceKey = todayKey
                changed = true; continue
            }
            if now < todayTarget, let yesterday = calendar.date(byAdding: .day, value: -1, to: dayDate) {
                let yesterdayKey = Self.dayFormatter(calendar.timeZone).string(from: yesterday)
                let missedKey = Self.occurrenceKey(day: yesterdayKey, hour: doc.workflows[i].hour, minute: doc.workflows[i].minute)
                if doc.workflows[i].lastRunDay == yesterdayKey, doc.workflows[i].lastRunOccurrenceKey == nil {
                    Self.record(missedKey, in: &doc.workflows[i]); doc.workflows[i].lastRunOccurrenceKey = missedKey
                    changed = true; continue
                }
                if let yesterdayTarget = calendar.date(bySettingHour: doc.workflows[i].hour, minute: doc.workflows[i].minute, second: 0, of: yesterday),
                   doc.workflows[i].createdAt <= yesterdayTarget, !(doc.workflows[i].handledOccurrenceKeys ?? []).contains(missedKey) {
                    doc.workflows[i].state = .missed; doc.workflows[i].lastRunDay = yesterdayKey; doc.workflows[i].lastRunOccurrenceKey = missedKey
                    Self.record(missedKey, in: &doc.workflows[i]); doc.workflows[i].lastFinishedAt = now
                    doc.workflows[i].lastOutcome = "Missed; the app was unavailable during the scheduled time."
                    changed = true
                }
                continue
            }
            guard !(doc.workflows[i].handledOccurrenceKeys ?? []).contains(todayKey), now >= todayTarget else { continue }
            let target = todayTarget
            if now.timeIntervalSince(target) > catchupWindow {
                doc.workflows[i].state = .missed; doc.workflows[i].lastRunDay = day; doc.workflows[i].lastRunOccurrenceKey = todayKey
                Self.record(todayKey, in: &doc.workflows[i]); doc.workflows[i].lastFinishedAt = now; doc.workflows[i].lastOutcome = "Missed; outside the daily catch-up window."
                doc.workflows[i].nextRun = nextOccurrence(hour: doc.workflows[i].hour, minute: doc.workflows[i].minute, after: now)
                changed = true
                continue
            }
            doc.workflows[i].state = .running; doc.workflows[i].lastRunDay = day; doc.workflows[i].lastRunOccurrenceKey = todayKey
            Self.record(todayKey, in: &doc.workflows[i]); doc.workflows[i].lastStartedAt = now
            doc.workflows[i].nextRun = nextOccurrence(hour: doc.workflows[i].hour, minute: doc.workflows[i].minute, after: now)
            claimed.append(doc.workflows[i])
        }
        if !claimed.isEmpty || changed { try write(doc) }
        return claimed
    }
    func complete(id: String, success: Bool, evidence: String, report: String? = nil, workers: [String: String]? = nil, at now: Date = Date()) throws {
        let summary = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 500, !PersonalWorkspace.hasCredential(summary) else { throw StoreError.invalid }
        lock.lock(); defer { lock.unlock() }
        var doc = try read(); guard let i = doc.workflows.firstIndex(where: { $0.id == id }), doc.workflows[i].state == .running else { throw StoreError.missing }
        doc.workflows[i].state = success ? .succeeded : .failed; doc.workflows[i].lastFinishedAt = now; doc.workflows[i].lastOutcome = summary
        doc.workflows[i].lastReport = report.map { String(AISecrets.redact($0).prefix(6000)) }
        doc.workflows[i].deliveryPending = report != nil
        doc.workflows[i].workerResults = workers
        for group in ["Weather", "News", "Tasks", "Apps", "Knowledge", "Code", "Briefing"] where doc.workflows[i].group == group {
            var book = doc.playbooks.first(where: { $0.group == group }) ?? AgentPlaybook(group: group)
            book.useCount += 1
            if success { book.successCount += 1; book.lastSuccess = now } else { book.failureCount += 1; book.lastFailure = now }
            if let index = doc.playbooks.firstIndex(where: { $0.group == group }) { doc.playbooks[index] = book } else { doc.playbooks.append(book) }
        }
        try write(doc)
    }
    /// Stores bounded outcome evidence for an individual worker. It updates
    /// playbook counters without treating outcomes as new human preferences.
    func recordOutcome(group: String, success: Bool, evidence: String, at now: Date = Date()) throws {
        let allowed = ["Briefing", "Weather", "News", "Tasks", "Apps", "Knowledge", "Code"]
        let summary = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowed.contains(group), !summary.isEmpty, summary.count <= 500, !PersonalWorkspace.hasCredential(summary) else { throw StoreError.invalid }
        lock.lock(); defer { lock.unlock() }
        var doc = try read(); var book = doc.playbooks.first(where: { $0.group == group }) ?? AgentPlaybook(group: group)
        book.useCount += 1
        if success { book.successCount += 1; book.lastSuccess = now } else { book.failureCount += 1; book.lastFailure = now }
        if let index = doc.playbooks.firstIndex(where: { $0.group == group }) { doc.playbooks[index] = book } else { doc.playbooks.append(book) }
        try write(doc)
    }
    /// A daily run left in `running` across restart fails without a duplicate
    /// same-day run. One-shot preparation is requeued while catch-up allows it.
    func recoverInterrupted(at now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var doc = try read(); var changed = false
        for i in doc.workflows.indices where doc.workflows[i].state == .running {
            if doc.workflows[i].lastReport != nil && doc.workflows[i].deliveryPending == true {
                doc.workflows[i].state = .succeeded
                doc.workflows[i].deliveryPending = true
                doc.workflows[i].lastFinishedAt = now
                doc.workflows[i].lastOutcome = "Research completed before restart; report queued for delivery."
                changed = true
                continue
            }
            if let target = doc.workflows[i].oneShotAt, doc.workflows[i].lastReport == nil, doc.workflows[i].deliveryPending != true {
                if now.timeIntervalSince(target) <= catchupWindow {
                    doc.workflows[i].state = .scheduled
                    doc.workflows[i].lastFinishedAt = now
                    doc.workflows[i].lastOutcome = "Research was interrupted by app restart; queued to retry within the catch-up window."
                    doc.workflows[i].nextRun = target
                } else {
                    doc.workflows[i].state = .missed
                    doc.workflows[i].lastFinishedAt = now
                    doc.workflows[i].lastOutcome = "Research was interrupted and the two-hour catch-up window expired."
                }
                changed = true
                continue
            }
            doc.workflows[i].state = .failed; doc.workflows[i].lastFinishedAt = now
            doc.workflows[i].lastOutcome = "Interrupted by app restart; not retried today."
            var book = doc.playbooks.first(where: { $0.group == doc.workflows[i].group }) ?? AgentPlaybook(group: doc.workflows[i].group)
            book.useCount += 1; book.failureCount += 1; book.lastFailure = now
            if let index = doc.playbooks.firstIndex(where: { $0.group == book.group }) { doc.playbooks[index] = book } else { doc.playbooks.append(book) }
            changed = true
        }
        if changed { try write(doc) }
    }
    func rememberSkill(group: String, text: String) throws {
        let allowed = ["Briefing", "Weather", "News", "Tasks", "Apps", "Knowledge", "Code"]
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowed.contains(group), !value.isEmpty, value.count <= 500, !PersonalWorkspace.hasCredential(value), !Safety.blocked(value) else { throw StoreError.invalid }
        lock.lock(); defer { lock.unlock() }
        var doc = try read(); var book = doc.playbooks.first(where: { $0.group == group }) ?? AgentPlaybook(group: group)
        guard book.lessons.count < 20 || book.lessons.contains(value) else { throw StoreError.full }
        if !book.lessons.contains(value) { book.lessons.append(value) }
        book.objectives = Array(book.lessons.suffix(5))
        if let index = doc.playbooks.firstIndex(where: { $0.group == group }) { doc.playbooks[index] = book } else { doc.playbooks.append(book) }
        try write(doc)
    }
    private func nextOccurrence(hour: Int, minute: Int, after date: Date) -> Date? {
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) else { return nil }
        return today > date ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
    private static func dayFormatter(_ zone: TimeZone) -> DateFormatter { let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"; return f }
    private static func occurrenceKey(day: String, hour: Int, minute: Int) -> String { "\(day)@\(String(format: "%02d:%02d", hour, minute))" }
    private static func record(_ key: String, in workflow: inout AgentWorkflow) {
        var history = workflow.handledOccurrenceKeys ?? []
        if !history.contains(key) { history.append(key) }
        workflow.handledOccurrenceKeys = Array(history.suffix(64))
    }
    private static func cDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, timezone: String) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: timezone)!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    static func test(at root: URL) throws {
        try AgentBriefingScope.test()
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let store = AgentWorkflowStore(root: base); try store.prepare()
        guard case .some(.scheduleBriefing(hour: 11, minute: 45)) = AgentWorkflowRouting.parse("Hey Chef, please assign an agent to schedule a daily briefing at 11:45 that will go over weather, market news, my todo list.") else { throw StoreError.invalid }
        let fixedNow = cDate(year: 2026, month: 10, day: 4, hour: 11, minute: 28, timezone: "America/Chicago")
        guard case .some(.scheduleBriefingOnce(let nearTerm)) = AgentWorkflowRouting.parse("give me a briefing about stocks and my to do list in 2 minutes", now: fixedNow),
              nearTerm == fixedNow.addingTimeInterval(120) else { throw StoreError.invalid }
        guard case .some(.scheduleBriefingOnce(let typoNearTerm)) = AgentWorkflowRouting.parse("give me a breifing in 2 mins", now: fixedNow),
              typoNearTerm == fixedNow.addingTimeInterval(120) else { throw StoreError.invalid }
        let tomorrowAt = cDate(year: 2026, month: 10, day: 5, hour: 11, minute: 30, timezone: "America/Chicago")
        guard case .some(.scheduleBriefingOnce(let tomorrow)) = AgentWorkflowRouting.parse("at11:30am tomorrow", existingBriefing: true, now: fixedNow),
              tomorrow == tomorrowAt else { throw StoreError.invalid }
        guard case .some(.scheduleBriefing(hour: 11, minute: 45)) = AgentWorkflowRouting.parse("brief daily 11:45") else { throw StoreError.invalid }
        guard case .some(.scheduleBriefing(hour: 12, minute: 25)) = AgentWorkflowRouting.parse("schedule briefing for12:25") else { throw StoreError.invalid }
        guard case .some(.scheduleBriefing(hour: 12, minute: 25)) = AgentWorkflowRouting.parse("change briefing to12:25") else { throw StoreError.invalid }
        guard case .some(.scheduleBriefing(hour: 12, minute: 25)) = AgentWorkflowRouting.parse("schedule it for12:25", existingBriefing: true) else { throw StoreError.invalid }
        guard case .some(.scheduleBriefing(hour: 12, minute: 25)) = AgentWorkflowRouting.parse("change it to12:25", existingBriefing: true) else { throw StoreError.invalid }
        guard AgentWorkflowRouting.parse("Don't change briefing to12:25") == nil,
              AgentWorkflowRouting.parse("Please say ‘change briefing to12:25’") == nil,
              AgentWorkflowRouting.parse("change it to12:25") == nil else { throw StoreError.invalid }
        guard case .some(.rememberSkill(group: "Apps", text: _)) = AgentWorkflowRouting.parse("remember for the app agent to check my calendar first") else { throw StoreError.invalid }
        guard case .some(.rememberSkill(group: "Knowledge", text: _)) = AgentWorkflowRouting.parse("remember for the knowledge agent to cite the source") else { throw StoreError.invalid }
        guard case .some(.rememberSkill(group: "Code", text: _)) = AgentWorkflowRouting.parse("remember for the code agent to run focused checks") else { throw StoreError.invalid }
        guard AgentWorkflowRouting.parse("Don't schedule a daily briefing at 11:45") == nil,
              AgentWorkflowRouting.parse("Don't cancel the briefing") == nil,
              AgentWorkflowRouting.parse("what does \"schedule a daily briefing at 11:45\" mean") == nil else { throw StoreError.invalid }
        guard case .some(.scheduleBriefing(hour: 12, minute: 25)) = AgentWorkflowRouting.parse("No but I want you to give me that briefing at 12:25") else { throw StoreError.invalid }
        guard AgentWorkflowRouting.parse("weather at 11:45") == nil else { throw StoreError.invalid }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!
        let nine = c.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9))!
        let now = c.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 11, minute: 46))!
        try store.scheduleBriefing(hour: 11, minute: 45, location: "Chicago, Illinois", at: nine)
        let newStore = AgentWorkflowStore(root: base.appendingPathComponent("newly-created"))
        try newStore.prepare()
        try newStore.scheduleBriefing(hour: 11, minute: 45, at: nine)
        let beforeSchedule = c.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9, minute: 1))!
        guard try newStore.due(at: beforeSchedule).isEmpty, try newStore.workflows().first?.state == .scheduled else { throw StoreError.invalid }
        let first = try store.due(at: now); guard first.count == 1 else { throw StoreError.invalid }
        guard try store.due(at: now).isEmpty else { throw StoreError.invalid }
        do { try store.scheduleBriefing(hour: 12, minute: 25, location: "Chicago, Illinois", at: now); throw StoreError.invalid }
        catch StoreError.alreadyRunning { }
        try store.complete(id: first[0].id, success: true, evidence: "Weather, headlines, and local tasks collected.", at: now)
        try store.scheduleBriefing(hour: 12, minute: 25, location: "Chicago, Illinois", at: now)
        let afterReschedule = c.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12, minute: 26))!
        let second = try store.due(at: afterReschedule); guard second.count == 1 else { throw StoreError.invalid }
        guard try store.due(at: afterReschedule).isEmpty else { throw StoreError.invalid }
        try store.complete(id: second[0].id, success: true, evidence: "The changed-clock briefing completed.", at: afterReschedule)
        try store.scheduleBriefing(hour: 12, minute: 25, location: "Chicago, Illinois", at: afterReschedule)
        let sameClockEdit = c.date(byAdding: .minute, value: 1, to: afterReschedule)!
        guard try store.due(at: sameClockEdit).isEmpty, try store.workflows().first?.lastRunDay == "2026-10-03" else { throw StoreError.invalid }
        let book = try store.playbooks().first(where: { $0.group == "Briefing" }); guard book?.successCount == 2 else { throw StoreError.invalid }
        let onceRoot = base.appendingPathComponent("one-shot")
        let onceStore = AgentWorkflowStore(root: onceRoot); try onceStore.prepare()
        let oneShotAt = cDate(year: 2026, month: 10, day: 4, hour: 11, minute: 30, timezone: "America/Chicago")
        let oneShotCreated = fixedNow
        let phoneConversationID = UUID().uuidString.lowercased(), phoneRequestID = UUID().uuidString.lowercased()
        let oneShot = try onceStore.scheduleOneShotBriefing(at: oneShotAt, location: "Columbia, Illinois", phoneConversationID: phoneConversationID, phoneRequestID: phoneRequestID, now: oneShotCreated)
        let secondOneShot = try onceStore.scheduleOneShotBriefing(at: oneShotAt, request: "Stocks and to-do list", now: oneShotCreated)
        guard oneShot.workerIDs == AgentWorkflowIdentity.briefingWorkers.map(\.id),
              secondOneShot.workerIDs == ["Iris", "Atlas"] else { throw StoreError.invalid }
        let reopenedOnce = AgentWorkflowStore(root: onceRoot); try reopenedOnce.prepare()
        guard try reopenedOnce.workflows().first(where: { $0.id == oneShot.id })?.phoneConversationID == phoneConversationID,
              try reopenedOnce.workflows().first(where: { $0.id == oneShot.id })?.phoneRequestID == phoneRequestID,
              try reopenedOnce.due(at: oneShotCreated).isEmpty else { throw StoreError.invalid }
        let preparationAt = oneShotAt.addingTimeInterval(-45)
        let claimedOnce = try reopenedOnce.due(at: preparationAt)
        guard claimedOnce.map(\.id) == [oneShot.id] else { throw StoreError.invalid }
        let claimedSecond = try reopenedOnce.due(at: preparationAt)
        guard claimedSecond.map(\.id) == [secondOneShot.id] else { throw StoreError.invalid }
        try reopenedOnce.complete(id: oneShot.id, success: true, evidence: "One-time briefing prepared.", report: "One-time briefing report.", at: preparationAt)
        guard try reopenedOnce.pendingDelivery(at: preparationAt) == nil,
              try reopenedOnce.pendingDelivery(at: oneShotAt)?.id == oneShot.id else { throw StoreError.invalid }
        try reopenedOnce.markDelivered(id: oneShot.id, at: oneShotAt)
        try reopenedOnce.complete(id: secondOneShot.id, success: true, evidence: "Second one-time briefing prepared.", report: "Second one-time briefing report.", at: preparationAt)
        guard try reopenedOnce.pendingDelivery(at: oneShotAt)?.id == secondOneShot.id else { throw StoreError.invalid }
        try reopenedOnce.markDelivered(id: secondOneShot.id, at: oneShotAt)
        guard try reopenedOnce.pendingDelivery() == nil else { throw StoreError.invalid }
        guard try reopenedOnce.due(at: oneShotAt.addingTimeInterval(1)).isEmpty else { throw StoreError.invalid }
        let lateRoot = base.appendingPathComponent("one-shot-late")
        let lateStore = AgentWorkflowStore(root: lateRoot); try lateStore.prepare()
        let late = try lateStore.scheduleOneShotBriefing(at: oneShotAt, now: oneShotCreated)
        guard try lateStore.due(at: oneShotAt.addingTimeInterval(2 * 60 * 60 + 1)).isEmpty,
              try lateStore.workflows().first(where: { $0.id == late.id })?.state == .missed else { throw StoreError.invalid }
        let restartRoot = base.appendingPathComponent("one-shot-restart")
        let restartStore = AgentWorkflowStore(root: restartRoot); try restartStore.prepare()
        let interrupted = try restartStore.scheduleOneShotBriefing(at: oneShotAt, request: "Stocks and to-do list", now: oneShotCreated)
        guard try restartStore.due(at: preparationAt).first?.id == interrupted.id else { throw StoreError.invalid }
        let restartedStore = AgentWorkflowStore(root: restartRoot); try restartedStore.prepare()
        try restartedStore.recoverInterrupted(at: preparationAt.addingTimeInterval(10))
        guard try restartedStore.workflows().first(where: { $0.id == interrupted.id })?.state == .scheduled,
              try restartedStore.due(at: preparationAt.addingTimeInterval(10)).first?.id == interrupted.id else { throw StoreError.invalid }
        let runningDailyRoot = base.appendingPathComponent("running-daily-cancel")
        let runningDaily = AgentWorkflowStore(root: runningDailyRoot); try runningDaily.prepare()
        try runningDaily.scheduleBriefing(hour: 11, minute: 30, at: oneShotCreated)
        guard try runningDaily.due(at: oneShotAt).first?.id == "daily-briefing" else { throw StoreError.invalid }
        do { try runningDaily.cancelBriefing(); throw StoreError.invalid }
        catch StoreError.alreadyRunning { }
        let pendingDailyRoot = base.appendingPathComponent("pending-daily-cancel")
        let pendingDaily = AgentWorkflowStore(root: pendingDailyRoot); try pendingDaily.prepare()
        try pendingDaily.scheduleBriefing(hour: 11, minute: 30, at: oneShotCreated)
        let pendingJob = try pendingDaily.due(at: oneShotAt).first!
        try pendingDaily.complete(id: pendingJob.id, success: true, evidence: "Briefing ready.", report: "Saved report.", at: oneShotAt)
        do { try pendingDaily.cancelBriefing(); throw StoreError.invalid }
        catch StoreError.alreadyRunning { }
        let nextMorning = cDate(year: 2026, month: 10, day: 5, hour: 11, minute: 31, timezone: "America/Chicago")
        guard try pendingDaily.due(at: nextMorning).isEmpty,
              try pendingDaily.workflows().first(where: { $0.id == "daily-briefing" })?.lastReport == "Saved report." else { throw StoreError.invalid }
        try store.rememberSkill(group: "Weather", text: "Use Fahrenheit.")
        guard try store.lessons(for: "Weather").contains("Fahrenheit") else { throw StoreError.invalid }
        try store.cancelBriefing(); guard try store.workflows().isEmpty else { throw StoreError.invalid }
        let link = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
        defer { try? FileManager.default.removeItem(at: link) }
        do { try AgentWorkflowStore(root: link.appendingPathComponent("unsafe")).prepare(); throw StoreError.invalid }
        catch StoreError.unsafePath { }
        print("Persistent briefing, catch-up, reschedule, explicit playbook, and symlink-safety checks passed.")
    }
}

private extension JSONEncoder {
    static var workflow: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
}
private extension JSONDecoder {
    static var workflow: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
