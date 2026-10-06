import Foundation

enum Specialist: String {
    case timers = "Timers"
    case apps = "Apps & web"
    case clock = "Time & date"
    case mail = "Gmail"
    case calendar = "Calendar"
    case reminders = "Reminders"
    case conversation = "Conversation"
    case policy = "Safety"
    case maintenance = "Code updates"
    case voice = "Voice settings"
    case usage = "Codex usage"
}

enum TimerOperation { case pause, resume, cancel }
enum AgentAction {
    case startTimer(seconds: Double, name: String)
    case controlTimer(TimerOperation, name: String?)
    case open(String)
    case playYouTube(String), stopYouTube
    case desktop(String)
    case search(String)
    case lookup(LiveQuery)
    case time, date, greeting, help
    case chat(String)
    case agenda(Int), reminder(String, dueText: String), clarify(String)
    case unavailable(Specialist)
    case invalidTimer
    case blocked(String)
    case changeRequest(String), voicePreference(String), acknowledgment(String)
    case updateStatus, applyUpdate, usage

    var publicVoiceEligible: Bool {
        switch self {
        case .chat, .lookup, .time, .date, .greeting, .help, .clarify, .open, .playYouTube, .stopYouTube, .search,
             .startTimer, .controlTimer, .invalidTimer: return true
        default: return false
        }
    }
    var protectsConversationContext: Bool {
        switch self { case .agenda, .reminder, .usage, .unavailable, .desktop: return true; default: return false }
    }
    var usesConversationContext: Bool {
        if case .chat = self { return true }
        return false
    }
    var specialist: Specialist {
        switch self {
        case .startTimer, .controlTimer, .invalidTimer: return .timers
        case .open, .search, .lookup, .playYouTube, .stopYouTube, .desktop: return .apps
        case .time, .date: return .clock
        case .unavailable(let specialist): return specialist
        case .blocked: return .policy
        case .agenda: return .calendar
        case .reminder: return .reminders
        case .chat, .clarify, .greeting, .help: return .conversation
        case .changeRequest, .updateStatus, .applyUpdate: return .maintenance
        case .voicePreference, .acknowledgment: return .voice
        case .usage: return .usage
        }
    }
}

struct AgentTask: Identifiable {
    let id = UUID()
    let request: String
    let action: AgentAction
}

enum OutcomeState: String {
    case complete = "Complete"
    case needsInput = "Needs input"
    case needsConnection = "Not connected"
    case blocked = "Blocked"
    case failed = "Failed"
}

struct AgentOutcome: Identifiable {
    let id = UUID()
    let task: AgentTask
    let state: OutcomeState
    let evidence: String
}

struct TaskProgress: Identifiable {
    let id: UUID
    let specialist: Specialist
    let request: String
    var status: String
}

// The supervisor produces bounded typed actions, never arbitrary commands.
// Domain workers live in this process; distributed agents are unnecessary here.
enum Supervisor {
    static let maximumTasks = 6
    static let financialRefusal = "Payments, purchases, subscriptions, and money transfers are permanently disabled. No part of this request was executed."

    static func plan(_ raw: String) -> [AgentTask] {
        let input = Safety.normalize(raw)
        if Safety.blocked(input) { return [AgentTask(request: raw, action: .blocked(financialRefusal))] }
        if UpdateRouting.isChangeRequest(raw) || UpdateRouting.isChangeRequest(input) {
            return [AgentTask(request: raw, action: .changeRequest(raw))]
        }
        let parts = split(input)
        guard parts.count <= maximumTasks else {
            return [AgentTask(request: raw, action: .blocked("Please split that request into six tasks or fewer. Nothing was executed."))]
        }
        return parts.map { AgentTask(request: $0, action: route($0)) }
    }

    static func split(_ text: String) -> [String] {
        // Preserve quoted names/searches and duration phrases such as
        // "one hour and fifteen minutes". Split only at an explicit next verb.
        let pattern = #"(?:\s+(?:and\s+then|and|then)\s+|\s*[,;]\s*(?:(?:and|then)\s+)?)(?=(?:please\s+)?(?:set|start|open|launch|pause|resume|cancel|stop|google|search|what|tell|help|plan|summari[sz]e|read|check|play|send|compose|click|type|scroll)\b)"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let ns = text as NSString
        var start = 0
        var parts: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let prefix = ns.substring(to: match.range.location)
            // Only double-quoted spans are protected; apostrophes in "what's"
            // are ordinary text and cannot suppress task splitting.
            guard prefix.filter({ $0 == "\"" }).count % 2 == 0 else { continue }
            let part = ns.substring(with: NSRange(location: start, length: match.range.location - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { parts.append(part) }
            start = match.range.location + match.range.length
        }
        let last = ns.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }
        return parts.isEmpty ? [""] : parts
    }

    static func route(_ spoken: String) -> AgentAction {
        let raw = spoken.replacingOccurrences(of: "’", with: "\'")
        // Speech often includes a polite lead-in or a correction. Peel those
        // wrappers before classifying, but never execute a command that is
        // itself quoted or explicitly negated.
        let quotedCommand = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if quotedCommand.range(of: #"^(?:please\s+)?[\"'“‘].*[\"'”’]$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .chat(raw)
        }
        let canceled = raw.replacingOccurrences(of: #"^(?:(?:okay|ok|all right|alright|sure|yes)[\s,.!]+)*(?:(?:never mind|nevermind|forget that|cancel that)[\s,.!]+)"#, with: "", options: [.regularExpression, .caseInsensitive])
        let cleaned = canceled.replacingOccurrences(of: #"^(?:(?:okay|ok|all right|alright|sure|yes)[\s,.!]+)*(?:then\s+)?(?:don't|do not)\s+(?:and\s+)(?:just\s+)?"#, with: "", options: [.regularExpression, .caseInsensitive])
        var input = cleaned.replacingOccurrences(of: #"^(?:(?:okay|ok|all right|alright|sure|please|but|would you mind|i'd like you to|i need you to|i want you to|go ahead and|can you|could you|would you|will you|just)[\s,.!]+)+"#, with: "", options: [.regularExpression, .caseInsensitive])
        input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
        if lower.range(of: #"^(?:please\s+)?(?:don't|do not|never)\s+(?:open|launch|go to|show|find|play)\b"#, options: .regularExpression) != nil { return .chat(input) }
        if lower.range(of: #"^(?:say|repeat|quote|what does|what is)\b.*\b(?:open|launch|go to|play)\b"#, options: .regularExpression) != nil { return .chat(input) }
        if Safety.blocked(input) { return .blocked(financialRefusal) }
        if UpdateRouting.isChangeRequest(input) { return .changeRequest(input) }
        if UpdateRouting.isVoicePreference(input) { return .voicePreference(input) }
        if ["apply update", "apply the update", "install the update", "restart chef"].contains(lower) { return .applyUpdate }
        if lower.contains("update status") || lower.contains("my update request") || lower == "check updates" { return .updateStatus }
        if let range = input.range(of: #"(?:acknowledgment|acknowledgement|wake response)\s+to\s+"#, options: [.regularExpression, .caseInsensitive]) {
            return .acknowledgment(String(input[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        if lower.contains("shortcut") && (lower.contains("run") || lower.contains("execute")) {
            return .blocked("Arbitrary shortcuts cannot run because they could make payments. That task was blocked.")
        }
        if ["token", "usage", "allowance", "percentage", "limit", "quota"].contains(where: { lower.contains($0) }) && ["left", "remaining", "reset", "my ", "do i have", "have i used", "usage"].contains(where: { lower.contains($0) }) { return .usage }
        if lower.contains("stop saying") && (lower.contains("what's up") || lower.contains("whats up") || lower.contains("yeah")) { return .acknowledgment("") }
        if lower.range(of: #"^(?:open|opening|launch|go to|go over to|head to|take me to|bring me to|bring up|bringing up|pull up|visit)\b"#, options: .regularExpression) != nil {
            // Keep a target's actual leading article/title intact (for example,
            // The Unarchiver). Only remove the spoken possessive when it is a
            // known web-service alias; app-name resolution handles other cases.
            let target = input.replacingOccurrences(of: #"^(?:open(?:ing)?|launch|go to|go over to|head to|take me to|bring me to|bring(?:ing)? up|pull up|visit)\s+(?:up\s+)?"#, with: "", options: [.regularExpression, .caseInsensitive])
            let spokenName = target.trimmingCharacters(in: CharacterSet(charactersIn: " .?!\"'“”‘’"))
            let name = canonicalKnownAppAlias(spokenName)
            let targetLower = name.lowercased()
            if targetLower.range(of: #"^(?:my\s+)?(?:files|folders|documents|downloads|desktop|documents folder|downloads folder|desktop folder)$"#, options: .regularExpression) != nil {
                return .open("Finder")
            }
            return .open(name)
        }
        if lower == "google" || lower == "the google homepage" { return .open("Google") }
        if ["weather", "the weather", "weather app"].contains(lower) { return .open("Weather") }
        if ["notes", "my notes", "the notes app"].contains(lower) { return .open("Notes") }
        if ["finder", "my files", "file browser"].contains(lower) { return .open("Finder") }
        if let lookup = LiveQuery.parse(input) { return .lookup(lookup) }
        if lower.hasPrefix("google ") || lower.hasPrefix("search google for ") {
            let query = String(input.dropFirst(lower.hasPrefix("google ") ? 7 : 18)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .search(query)
        }
        if (lower.contains("timer") && ["set", "start", "pause", "resume", "cancel", "stop", "timer"].contains(where: { lower.hasPrefix($0) })) || TimerParser.parse(input) != nil {
            let name = timerName(input)
            if lower.hasPrefix("pause") { return .controlTimer(.pause, name: name) }
            if lower.hasPrefix("resume") { return .controlTimer(.resume, name: name) }
            if lower.hasPrefix("cancel") || lower.hasPrefix("stop") { return .controlTimer(.cancel, name: name) }
            if let timer = TimerParser.parse(input) { return .startTimer(seconds: timer.seconds, name: timer.name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
            return .invalidTimer
        }
        if lower.contains("what time") || lower == "time" || lower == "tell me the time" { return .time }
        if lower.contains("what day") || lower.contains("today's date") || lower == "date" { return .date }
        if lower.isEmpty || ["hello", "hi", "hey", "hello chef", "hi chef"].contains(lower) { return .greeting }
        if lower == "help" || lower.contains("what can you do") { return .help }
        if ["read", "check", "summarize", "show"].contains(where: { lower.hasPrefix($0) }) && ["my email", "my gmail", "my inbox", "gmail inbox", "my messages"].contains(where: { lower.contains($0) }) { return .unavailable(.mail) }
        if ["what's on my calendar", "whats on my calendar", "what is on my calendar", "read my calendar", "check my calendar", "show my agenda", "my agenda"].contains(lower) { return .agenda(0) }
        if ["stop music", "stop playback", "stop youtube", "pause music"].contains(lower) { return .stopYouTube }
        if lower.range(of: #"^(?:send\b[^\n]{0,120}\bemail|email\s+[A-Z0-9._%+-]+)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .desktop(input) }
        if lower.range(of: #"^(?:take control|control my computer|use my computer|show (?:my |the )?screen|look at (?:my |the )?screen|move (?:my |the )?(?:mouse|cursor)|click|scroll|type|press|send (?:an? |the |this |my )?email|compose (?:an? |the )?email|reply to (?:this |the |my )?email)\b"#, options: .regularExpression) != nil { return .desktop(input) }
        if lower == "play music" || lower == "play youtube music" { return .clarify("Which song or artist would you like me to play?") }
        if lower.hasPrefix("play ") {
            var query = String(input.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " .?!\"'“”‘’"))
            for _ in 0..<3 { query = query.replacingOccurrences(of: #"\s+(?:(?:on|in)\s+youtube|for\s+me|please)$"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !query.isEmpty, query.count <= 180, !PersonalWorkspace.hasCredential(query), !FishFreeVoice.sensitive(query) else { return .clarify("Give me a song title and artist without private information.") }
            return .playYouTube(query)
        }
        return .chat(input)
    }

    private static func timerName(_ text: String) -> String? {
        if text.range(of: #"^(?:pause|resume|cancel|stop)\s+(?:(?:my|the)\s+)?timer[.?!]*$"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        if let range = text.range(of: " called ", options: .caseInsensitive) {
            return String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .?!\""))
        }
        let pattern = #"^(?:pause|resume|cancel|stop)\s+(?:my\s+|the\s+)?(.+?)\s+timer[.?!]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return name.isEmpty ? nil : name
    }

    private static func canonicalKnownAppAlias(_ raw: String) -> String {
        var candidate = raw
        for _ in 0..<2 {
            let trimmed = candidate.replacingOccurrences(of: #"\s+(?:for\s+me|please)$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == candidate { break }
            candidate = trimmed
        }
        candidate = candidate.replacingOccurrences(of: #"\s+(?:app|application)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        candidate = candidate.replacingOccurrences(of: #"^(?:my|the)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        let aliases = webServices.map(\.name) + ["Finder", "Weather", "Notes"]
        return aliases.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) ?? raw
    }
}

// Completion is judged from actual worker outcomes, not an LLM's confidence.
// No automatic retries: completed actions are never run again by reflection.
enum CompletionChecker {
    static func summarize(tasks: [AgentTask], outcomes: [AgentOutcome]) -> String {
        let covered = Set(outcomes.map { $0.task.id })
        let missing = tasks.filter { !covered.contains($0.id) }
        let details = outcomes.map(\.evidence).joined(separator: " ")
        if !missing.isEmpty { return details + " I didn't complete every step. Please retry the unfinished tasks only." }
        if tasks.count == 1 { return details }
        let completed = outcomes.filter { $0.state == .complete }.count
        return "Completed \(completed) of \(tasks.count) tasks. " + details
    }
}

enum WorkflowTests {
    static func run() {
        precondition(AgentAction.time.publicVoiceEligible)
        precondition(AgentAction.lookup(LiveQuery(kind: .weather, query: "Columbia, Illinois")).publicVoiceEligible)
        precondition(!AgentAction.usage.publicVoiceEligible && !AgentAction.agenda(1).publicVoiceEligible)
        precondition(!AgentAction.time.usesConversationContext && AgentAction.chat("hello").usesConversationContext)

        for question in ["How many tokens do I have left?", "What percentage do I have left?", "When will my tokens reset?", "How much Codex usage is remaining?"] {
            if case .usage = Supervisor.route(question) {} else { preconditionFailure("Usage question wasn't routed") }
        }
        let music = Supervisor.plan("open YouTube and then play My All by Mariah Carey")
        precondition(music.count == 2)
        if case .playYouTube("My All by Mariah Carey") = music[1].action {} else { preconditionFailure("Song playback step was lost") }
        if case .playYouTube("My All by Mariah Carey") = Supervisor.route("can you play My All by Mariah Carey on YouTube") {} else { preconditionFailure("Follow-up song wasn't routed") }
        for phrase in ["don't play My All", "Please say 'play My All'"] { if case .chat = Supervisor.route(phrase) {} else { preconditionFailure("Negated or quoted playback was executed") } }
        YouTubePlayback.test()
        if case .desktop = Supervisor.route("can you send an email to Morgan") {} else { preconditionFailure("Email desktop intent was lost") }
        if case .desktop = Supervisor.route("click the compose button") {} else { preconditionFailure("Click intent was lost") }
        let mailSteps = Supervisor.plan("open Gmail and then send an email to Morgan")
        precondition(mailSteps.count == 2)
        precondition(!AgentAction.desktop("send an email").publicVoiceEligible)
        precondition(AgentAction.desktop("click Compose").protectsConversationContext)
        let desktopHistory = [ConversationLine(role: "CHEF", text: "Draft recipient and body", privateContent: AgentAction.desktop("click Compose").protectsConversationContext), ConversationLine(role: "CHEF", text: "Public weather", privateContent: AgentAction.time.protectsConversationContext)]
        precondition(FishFreeVoice.publicConversationHistory(desktopHistory).map(\.text) == ["Public weather"])
        let combo = Supervisor.plan("Set a timer for five minutes and then open Gmail")
        precondition(combo.count == 2)
        if case .startTimer(let seconds, _) = combo[0].action { precondition(seconds == 300) } else { preconditionFailure("Timer wasn't routed") }
        if case .open(let name) = combo[1].action { precondition(name == "Gmail") } else { preconditionFailure("Gmail wasn't routed") }
        for spoken in ["open up my Gmail", "Could you please open my Gmail?", "can you open gmail for me", "can you open Gmail for me please", "open my Gmail for me", "open the Gmail app for me", "Okay, go ahead and open Gmail", "Okay then don't and just go to Google", "Okay then don’t and just go to Google", "please bring up Notes", "would you mind opening Finder", "go to the Weather app", "open my downloads folder"] {
            let expected: String
            if spoken.lowercased().contains("google") { expected = "Google" }
            else if spoken.lowercased().contains("notes") { expected = "Notes" }
            else if spoken.lowercased().contains("finder") || spoken.lowercased().contains("folder") { expected = "Finder" }
            else if spoken.lowercased().contains("weather") { expected = "Weather" }
            else { expected = "Gmail" }
            if case .open(let name) = Supervisor.route(spoken) { precondition(name == expected, "Wrong app for: \(spoken)") }
            else { preconditionFailure("Spoken app request wasn't routed directly: \(spoken)") }
        }
        for nonAction in ["don't open Gmail", "Please say 'open Gmail'", "What does \"open Notes\" mean?"] {
            if case .chat = Supervisor.route(nonAction) {} else { preconditionFailure("Quoted or negated action was executed: \(nonAction)") }
        }
        if case .open("The Unarchiver") = Supervisor.route("open The Unarchiver") {} else { preconditionFailure("Installed app title was changed while routing") }
        if case .open("A Friend for Me") = Supervisor.route("open A Friend for Me") {} else { preconditionFailure("Installed app title was changed by courtesy trimming") }
        if case .open("Finder") = Supervisor.route("open my files") {} else { preconditionFailure("Files request wasn't routed to approved Finder launch") }
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("chef-installed-app-fixture-" + UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try! InstalledAppCatalog.test(at: fixtureRoot)
        let stale = AIAdapterPrompt.prepare("Objective: Open Google\nRelevant context:\nYOU: I tried opening Gmail\nCHEF: I can't access that account.")
        precondition(stale.contains("Objective: Open Google") && stale.contains("YOU: I tried opening Gmail"))
        precondition(!stale.contains("CHEF: I can't access that account."))
        precondition(stale.contains("Gmail inbox contents are not connected"))
        let outcomes = [AgentOutcome(task: combo[0], state: .complete, evidence: "Started timer."), AgentOutcome(task: combo[1], state: .failed, evidence: "Couldn't open Gmail.")]
        let summary = CompletionChecker.summarize(tasks: combo, outcomes: outcomes)
        precondition(summary.contains("Completed 1 of 2"))
        precondition(summary.contains("Couldn't open Gmail"))
        precondition(CompletionChecker.summarize(tasks: combo, outcomes: [outcomes[0]]).contains("didn't complete every step"))
        let noPartialPayments = Supervisor.plan("Set a timer for five minutes and then pay my rent")
        precondition(noPartialPayments.count == 1)
        if case .blocked = noPartialPayments[0].action {} else { preconditionFailure("Mixed financial request wasn't blocked before execution") }
        precondition(Supervisor.split("timer 1 hour and 15 minutes called Dinner").count == 1)
        precondition(Supervisor.split("google \"open Notes and then open Gmail\"").count == 1)
        precondition(Supervisor.split("set a timer for 5 minutes called \"Read and then open Notes\" and then open Gmail").count == 2)
        let limited = Supervisor.plan(Array(repeating: "open Gmail", count: 7).joined(separator: " and then "))
        precondition(limited.count == 1)
        if case .blocked = limited[0].action {} else { preconditionFailure("Unbounded workflow accepted") }
        if case .controlTimer(.pause, let name) = Supervisor.route("pause my timer") { precondition(name == nil) } else { preconditionFailure("Pause wasn't routed") }
        if case .controlTimer(.resume, let name) = Supervisor.route("resume the Laundry timer") { precondition(name == "Laundry") } else { preconditionFailure("Named timer wasn't routed") }
        if case .unavailable(.mail) = Supervisor.route("summarize my Gmail inbox") {} else { preconditionFailure("Unavailable Gmail data was treated as connected") }
        if case .agenda(0) = Supervisor.route("what's on my calendar") {} else { preconditionFailure("Unavailable calendar data was treated as connected") }
        if case .blocked = Supervisor.route("run shortcut Morning") {} else { preconditionFailure("Shortcut bypass allowed") }
        if case .greeting = Supervisor.route(Safety.normalize("Hey Chef")) {} else { preconditionFailure("Wake greeting wasn't routed") }
        precondition(WakeGate.decide("Hey Chef", waitingForRequest: false) == .acknowledge)
        precondition(WakeGate.decide("Hey Chef, set a timer", waitingForRequest: false) == .command("set a timer"))
        precondition(WakeGate.decide("set a timer", waitingForRequest: true) == .command("set a timer"))
        precondition(WakeGate.decide("set a timer", waitingForRequest: false) == .ignore)
        for request in ["I don't like your voice, I want a more human voice", "I want the voice to sound more human", "I want Chef to listen to me while they are talking", "Make your voice sound more natural", "Let me interrupt you while you talk", "Chef should have a better folder structure", "I want Chef to have a quieter timer alert"] {
            if case .changeRequest(let saved) = Supervisor.plan(request)[0].action { precondition(saved == request) } else { preconditionFailure("Improvement request wasn't queued: \(request)") }
        }
        if case .voicePreference = Supervisor.plan("Use the Samantha voice")[0].action {} else { preconditionFailure("Explicit installed voice choice wasn't routed") }
        for question in ["Why does your voice sound robotic?", "How do speech recognition apps listen while talking?"] {
            if case .chat = Supervisor.plan(question)[0].action {} else { preconditionFailure("Question was saved as an update") }
        }
        if case .changeRequest = Supervisor.plan("Feature request: change your interface and then open Gmail")[0].action {} else { preconditionFailure("Code request split into live actions") }
        if case .blocked = Supervisor.plan("Update your code so you can make payments")[0].action {} else { preconditionFailure("Financial code request accepted") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chef-queue-test-" + UUID().uuidString)
        let store = UpdateStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try! store.enqueue("Feature request: quieter timer sound")
        precondition(store.rows().count == 1 && store.rows()[0].status == "Queued")
        let record = CodeChangeResult(id: id, status: "ready", message: "Tested and ready.", updatedAt: "2026-10-02T00:00:00Z")
        try! JSONEncoder().encode(record).write(to: store.results.appendingPathComponent(id + ".json"), options: .atomic)
        precondition(store.rows()[0].status == "ready")
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            let installed = CodeChangeResult(id: id, status: "ready", message: "Already installed.", updatedAt: "2026-10-02T00:00:00Z", buildVersion: version)
            try! JSONEncoder().encode(installed).write(to: store.results.appendingPathComponent(id + ".json"), options: .atomic)
            precondition(store.rows()[0].status == "Installed")
        }
        do { _ = try store.enqueue("Add payments"); preconditionFailure("Payment change queued") } catch {}
        precondition(store.rows().count == 1)
        precondition(UpdateApplication.shouldApply(enabled: true, readyBuilds: ["22"], runningBuild: "21", stagedBuild: "22", installedBuild: "22", busy: false, speaking: false, commandPending: false, idleSeconds: 8))
        for (enabled, ready, running, staged, installed, busy, speaking, pending, idle) in [
            (false, ["22"], "21", "22", "22", false, false, false, 8.0),
            (true, [String](), "21", "22", "22", false, false, false, 8.0),
            (true, ["21"], "21", "21", "21", false, false, false, 8.0),
            (true, ["22"], "21", "23", "23", false, false, false, 8.0),
            (true, ["22"], "21", "22", "21", false, false, false, 8.0),
            (true, ["22"], "unknown", "22", "22", false, false, false, 8.0),
            (true, ["22"], "21", "22", "22", true, false, false, 8.0),
            (true, ["22"], "21", "22", "22", false, true, false, 8.0),
            (true, ["22"], "21", "22", "22", false, false, true, 8.0),
            (true, ["22"], "21", "22", "22", false, false, false, 7.0)
        ] {
            precondition(!UpdateApplication.shouldApply(enabled: enabled, readyBuilds: ready, runningBuild: running, stagedBuild: staged, installedBuild: installed, busy: busy, speaking: speaking, commandPending: pending, idleSeconds: idle))
        }
        print("Improvement routing and automatic application gating for idle, busy, speaking, pending input, disabled, stale and mismatched builds passed.")
        print("Supervisor routing, compound tasks, named timers, incomplete outcomes, unavailable accounts, and no-partial-payment workflow checks passed.")
        print("Two-stage wake, voice preferences, queued code requests, result polling, and financial-change rejection checks passed.")
    }
}
