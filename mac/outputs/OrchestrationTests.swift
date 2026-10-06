import Foundation

enum AISimulation: String, CaseIterable {
    case success, timeout, rateLimit, serverError, invalidResponse, lowConfidence, partialSuccess, badOutput, providerOutage
}
actor AIMockState {
    var calls = 0, active = 0, peak = 0
    var scenarios: [AISimulation]
    init(_ scenarios: [AISimulation]) { self.scenarios = scenarios }
    func begin() -> AISimulation { calls += 1; active += 1; peak = max(peak, active); return scenarios.isEmpty ? .success : scenarios.removeFirst() }
    func end() { active -= 1 }
    func counts() -> (Int, Int) { (calls, peak) }
}
final class AIMockProvider: AIProviderAdapter {
    let maximumConcurrency = 4
    let id: String
    let supportsHardTokenLimit = true
    let state: AIMockState
    var available = true
    var failMatching: String?
    var delayMs = 20
    init(id: String = "mock", scenarios: [AISimulation] = []) { self.id = id; state = AIMockState(scenarios) }
    func healthCheck() async -> Bool { available }
    func cancel() async { available = false }
    func generate(prompt: String, model: AIModel, maxOutput: Int, requestID: UUID) async throws -> AIWorkerOutput {
        let selectedScenario = await state.begin()
        let scenario = failMatching.map { prompt.contains($0) } == true ? AISimulation.badOutput : selectedScenario
        try await Task.sleep(for: .milliseconds(delayMs))
        await state.end()
        switch scenario {
        case .timeout: throw AIError.timeout
        case .rateLimit: throw AIError.rateLimited(60)
        case .serverError: throw AIError.unavailable("Simulated server error")
        case .providerOutage: throw AIError.unavailable("Simulated provider outage")
        default: break
        }
        let text: String
        if scenario == .badOutput || scenario == .partialSuccess { text = "" }
        else if scenario == .invalidResponse { text = "not JSON" }
        else if prompt.contains("\"assumptions\"") && prompt.contains("\"tasks\"") {
            text = #"{"objective":"Draft an application","assumptions":["Text drafts only"],"risks":[],"tasks":[{"key":"a","objective":"Describe input validation","kind":"text","tier":0,"dependencies":[],"acceptance":["Explain validation"],"constraints":["Draft only"],"expectedOutput":"Text"},{"key":"b","objective":"Write a Python function for CSV parsing","kind":"coding","tier":1,"dependencies":[],"acceptance":["Return function draft"],"constraints":["No execution"],"expectedOutput":"Code draft"},{"key":"c","objective":"Analyze the multi-step integration of validation and CSV parsing","kind":"analysis","tier":2,"dependencies":["a","b"],"acceptance":["Use both prior results"],"constraints":["Draft only"],"expectedOutput":"Integration draft"}]}"#
        } else if prompt.contains("\"passed\":boolean") { text = #"{"passed":true,"issues":[],"summary":"Draft requirements satisfied; code not executed."}"# }
        else { text = "Verified synthetic worker draft for " + String(prompt.prefix(80)) }
        return AIWorkerOutput(text: text, confidence: scenario == .lowConfidence ? 0.4 : 0.92, usage: AITokenUsage(input: 100 + model.tier.rawValue * 20, output: 30 + model.tier.rawValue * 10, cached: 10), actualModel: model.model)
    }
}

enum OrchestrationTests {
    static func config(provider: String = "mock") -> AIConfiguration {
        var c = AIConfiguration(); c.authorizedProviders = [provider]
        c.models = AITier.allCases.map { tier in
            var model = AIModel.codexDefault
            model = AIModel(id: "\(provider):\(tier.label)", provider: provider, model: tier.label, tier: tier, capabilities: ["text", "code", "reasoning"], contextWindow: 32000, maxOutputTokens: 4000, supportsTools: false, supportsVision: false, supportsStructuredOutput: true, inputPrice: Double(tier.rawValue + 1), outputPrice: Double((tier.rawValue + 1) * 2), cachedInputPrice: 0.25, reliability: 0.95, priority: tier.rawValue, enabled: true, authorized: true, local: true, noMeteredCharge: true, latencyEstimateMs: 20)
            return model
        }
        c.budget.maxProjectCost = 1; c.budget.maxTaskCost = 1; c.budget.maxL3Cost = 1
        return c
    }
    @MainActor static func run() async throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("chef-orchestration-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func engine(_ name: String, _ configuration: AIConfiguration = config(), _ providers: [AIMockProvider]) -> AIEngine {
            let e = AIEngine(root: temporary.appendingPathComponent(name), configuration: configuration)
            for p in providers { e.register(p) }; return e
        }
        for (input, tier) in [("What is EBITDA?", AITier.l0), ("Write a Python function", .l1), ("Debug a complex concurrent algorithm", .l2), ("Redesign architecture", .l3)] {
            let c = AIClassifier.classify(input), route = try AIRouter.select(c, config: config(), health: [:], knownProviders: ["mock"])
            precondition(c.tier == tier && route.model.tier == tier)
        }
        let basic = AIClassifier.classify("Explain folders")
        var unauthorized = config(); unauthorized.authorizedProviders = []
        do { _ = try AIRouter.select(basic, config: unauthorized, health: [:], knownProviders: ["mock"]); preconditionFailure("Unauthorized provider accepted") } catch {}
        var sensitive = basic
        sensitive = AIClassifier.classify("my medical record")
        var cloud = config(); cloud.models = cloud.models.map { var m = $0; m.local = false; return m }
        do { _ = try AIRouter.select(sensitive, config: cloud, health: [:], knownProviders: ["mock"]); preconditionFailure("Privacy leak") } catch {}
        let pem = "-----BEGIN PRIVATE KEY-----\nBASE64SECRET\n-----END PRIVATE KEY-----"
        precondition(AISecrets.containsSecret(pem) && !AISecrets.redact(pem).contains("BASE64SECRET"))
        precondition(AISecrets.containsSecret("Bearer abcdefghijklmnop"))
        precondition(AIContext.bounded(["CSV validation", "CSV validation", "irrelevant flowers", "password=secret"], maxBytes: 500, objective: "CSV validation").count == 1)
        let unicode = AIContext.bounded(["folder " + String(repeating: "😀", count: 100)], maxBytes: 100, objective: "folder")
        precondition(unicode.first!.utf8.count <= 100 && !unicode.first!.contains("�"))
        let shortDraft = "Python draft " + String(repeating: "x", count: 1200) + " proposed boundary tests"
        precondition(AIContext.bounded([shortDraft], maxBytes: 6000 / 2, objective: "").first == shortDraft)
        let oversizedDraft = AIContext.bounded([String(repeating: "😀", count: 6000)], maxBytes: 6000 / 8, objective: "").first!
        precondition(oversizedDraft.utf8.count <= 750 && !oversizedDraft.contains("�"))
        let packet = AITaskPacket.single("Explain folders", project: UUID(), classification: basic)
        let bad = AIWorkerOutput(text: "", confidence: 0.9, usage: .unknown, actualModel: nil)
        precondition(!AIVerifier.verify(bad, packet: packet).passed)
        var claim = bad; claim.text = "I ran the tests and modified files."
        precondition(!AIVerifier.verify(claim, packet: packet).passed)
        var unauthorizedOutput = bad; unauthorizedOutput.text = "Done"; unauthorizedOutput.filesChanged = ["x.swift"]
        precondition(!AIVerifier.verify(unauthorizedOutput, packet: packet).passed)
        var localOnlyConfig = config()
        localOnlyConfig.models = localOnlyConfig.models.map { var m = $0; m.local = m.tier == .l0; return m }
        let localFailure = AIMockProvider(scenarios: [.badOutput, .success])
        let freeBasic = engine("free-basic", localOnlyConfig, [localFailure])
        do { _ = try await freeBasic.run("Explain folders", localOnly: true); preconditionFailure("Local basic failure escaped to cloud") } catch {}
        let basicCalls = await localFailure.state.counts()
        precondition(basicCalls.0 == 1 && freeBasic.attempts.count == 1 && freeBasic.attempts[0].tier == .l0)
        let lowBasicProvider = AIMockProvider(scenarios: [.lowConfidence])
        let lowBasic = engine("free-low-confidence", localOnlyConfig, [lowBasicProvider])
        do { _ = try await lowBasic.run("Explain folders", localOnly: true); preconditionFailure("Local-only review escaped to cloud") } catch {}
        let lowBasicCalls = await lowBasicProvider.state.counts(); precondition(lowBasicCalls.0 == 1)
        let mock = AIMockProvider(), simple = engine("simple", config(), [mock])
        _ = try await simple.run("What is EBITDA?")
        precondition(simple.attempts.count == 1 && simple.attempts[0].tier == .l0 && simple.projects[0].state == .completed)
        simple.dryRun("Redesign my architecture")
        let before = await mock.state.counts(); precondition(before.0 == 1 && simple.dryRunReport.contains("No AI request executed"))
        let projectMock = AIMockProvider(), project = engine("project", config(), [projectMock])
        _ = try await project.run("Build a CSV application architecture")
        let concurrent = await projectMock.state.counts()
        precondition(project.projects[0].tasks.count == 3 && project.projects[0].results.count == 3 && project.projects[0].state == .completed)
        precondition(concurrent.1 == 2 && project.attempts.count == 5)
        let levels = try AIGraph.levels(project.projects[0].tasks); precondition(levels.count == 2 && levels[0].count == 2)
        var cycle = project.projects[0].tasks; cycle[0].dependencies = [cycle[2].id]
        do { _ = try AIGraph.levels(cycle); preconditionFailure("Cycle accepted") } catch {}
        var missing = project.projects[0].tasks; missing[0].dependencies = [UUID()]
        do { _ = try AIGraph.levels(missing); preconditionFailure("Missing dependency accepted") } catch {}
        let failure = AIMockProvider(scenarios: [.badOutput, .success]), escalate = engine("escalate", config(), [failure])
        _ = try await escalate.run("Explain folders")
        precondition(escalate.attempts.count == 2 && escalate.attempts[0].tier == .l0 && escalate.attempts[1].tier == .l1)
        let low = AIMockProvider(scenarios: [.lowConfidence, .success]), review = engine("low", config(), [low])
        _ = try await review.run("Explain folders")
        precondition(review.attempts.count == 2 && review.attempts[1].tier == .l3)
        let providerA = AIMockProvider(id: "a", scenarios: [.rateLimit]), providerB = AIMockProvider(id: "b")
        var alternate = config(provider: "a"); alternate.models += config(provider: "b").models; alternate.authorizedProviders = ["a", "b"]
        let fallback = engine("fallback", alternate, [providerA, providerB]); _ = try await fallback.run("Explain folders")
        precondition(fallback.attempts.count == 2 && fallback.attempts.last?.provider == "b" && fallback.health["a"]?.available == false)
        var smallBudget = config(); smallBudget.budget.maxProjectCost = 0; smallBudget.budget.maxTaskCost = 0; smallBudget.models = smallBudget.models.map { var m = $0; m.noMeteredCharge = false; return m }
        let noSpend = AIMockProvider(), budget = engine("budget", smallBudget, [noSpend])
        do { _ = try await budget.run("Explain folders"); preconditionFailure("Budget exceeded") } catch {}
        let noSpendCounts = await noSpend.state.counts(); precondition(noSpendCounts.0 == 0)
        var noL3 = config(); noL3.budget.maxL3Requests = 0
        let l3Mock = AIMockProvider(), l3 = engine("l3-limit", noL3, [l3Mock])
        do { _ = try await l3.run("Redesign architecture"); preconditionFailure("L3 limit ignored") } catch {}
        let l3Counts = await l3Mock.state.counts(); precondition(l3Counts.0 == 0)
        var tokenBudget = config(); tokenBudget.budget.maxTokens = 20
        let tokenMock = AIMockProvider(), tokens = engine("token-limit", tokenBudget, [tokenMock])
        do { _ = try await tokens.run("Explain folders"); preconditionFailure("Token limit ignored") } catch {}
        let tokenCounts = await tokenMock.state.counts(); precondition(tokenCounts.0 == 0)
        let telemetry = AITokenUsage(input: 100, output: 50, cached: 20)
        let cost = telemetry.cost(config().models[0]); precondition(cost != nil && abs(cost! - 0.000185) < 0.0000001)
        precondition(AITokenUsage.unknown.cost(config().models[0]) == nil)
        let journal = try AIJournal(temporary.appendingPathComponent("store"))
        try journal.save(config(), name: "config.json"); precondition(journal.load(AIConfiguration.self, name: "config.json")?.models.count == 4)
        precondition(journal.load(AIConfiguration.self, name: "../config.json") == nil)
        let link = journal.root.appendingPathComponent("escape.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temporary.appendingPathComponent("outside.json"))
        do { try journal.save(config(), name: "escape.json"); preconditionFailure("Symlink accepted") } catch {}
        for scenario in AISimulation.allCases {
            let p = AIMockProvider(scenarios: [scenario]); let e = engine("scenario-" + scenario.rawValue, config(), [p])
            do { _ = try await e.run(scenario == .invalidResponse ? "Redesign architecture" : "Explain folders") } catch {}
            precondition(e.activeProjectID == nil && e.attempts.count <= 20)
        }
        let cacheMock = AIMockProvider(), cached = engine("cache", config(), [cacheMock])
        _ = try await cached.run("Format this list alphabetically: b, a")
        _ = try await cached.run("Format this list alphabetically: b, a")
        let cacheCounts = await cacheMock.state.counts(); precondition(cacheCounts.0 == 1 && cached.cachedResponses == 1)
        let interrupted = AIEngine(root: temporary.appendingPathComponent("project"), configuration: config())
        precondition(interrupted.projects.count == 1 && interrupted.projects[0].state == .completed)
        let reworkMock = AIMockProvider(); reworkMock.failMatching = "Write a Python function for CSV parsing"
        let rework = engine("rework", config(), [reworkMock])
        do { _ = try await rework.run("Build a CSV application architecture"); preconditionFailure("Failed dependency passed") } catch {}
        let old = rework.projects[0]; precondition(old.results.contains { $0.state == .completed } && old.results.contains { $0.state == .blocked })
        let oldCounts = await reworkMock.state.counts(); reworkMock.failMatching = nil
        _ = try await rework.retryFailedProject(old.id)
        let newCounts = await reworkMock.state.counts()
        precondition(rework.projects[0].state == .completed && newCounts.0 - oldCounts.0 == 3)
        let cancelMock = AIMockProvider(); cancelMock.delayMs = 100
        let cancelling = engine("cancel", config(), [cancelMock])
        let running = Task { @MainActor in try await cancelling.run("Explain folders") }
        try await Task.sleep(for: .milliseconds(10)); await cancelling.cancel()
        do { _ = try await running.value; preconditionFailure("Cancellation ignored") } catch {}
        precondition(cancelling.projects[0].state == .cancelled && cancelling.activeProjectID == nil)
        let secretMock = AIMockProvider(), secret = engine("secret", config(), [secretMock])
        do { _ = try await secret.run("password=example"); preconditionFailure("Credential transmitted") } catch {}
        let secretCounts = await secretMock.state.counts(); precondition(secretCounts.0 == 0 && secret.projects.isEmpty)
        let observed = engine("manual", config(), [AIMockProvider()])
        var observedCalls = 0
        let observedText = try await observed.observe("Manual local reply", model: config().models[0]) {
            observedCalls += 1
            return AIWorkerOutput(text: "A manual reply", confidence: nil, usage: .unknown, actualModel: "mock")
        }
        precondition(observedText == "A manual reply" && observedCalls == 1 && observed.attempts.count == 1)
        observed.config.budget.maxL3Requests = 0
        do {
            _ = try await observed.observe("Manual high-end reply", model: config().models[3]) { observedCalls += 1; return AIWorkerOutput(text: "Unexpected", confidence: nil, usage: .unknown, actualModel: "mock") }
            preconditionFailure("Manual L3 budget bypass")
        } catch {}
        precondition(observedCalls == 1)
        let report = "Mock-provider acceptance suite passed: L0–L3 routing, unauthorized providers, privacy, context deduplication, output/permission validation, dry-run, L3-created DAG, two concurrent workers, dependencies/cycles, escalation, low-confidence review, provider fallback/cooldown, cost/token/L3 budgets, cached-token cost accounting, journal persistence/symlinks, all nine failure simulations, formatting cache, targeted rework preserving completed tasks, cancellation, and credential rejection before transmission, and budget-gated compatibility-call tracing. No live AI or paid API calls."
        print(report); return report
    }
    @MainActor static func benchmark() async throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chef-benchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = ["Explain folders", "Write a Python function", "Debug a complex concurrent algorithm"]
        let mixed = AIEngine(root: root.appendingPathComponent("mixed"), configuration: config()), all = AIEngine(root: root.appendingPathComponent("all"), configuration: config())
        mixed.register(AIMockProvider()); all.register(AIMockProvider())
        all.config.models = all.config.models.filter { $0.tier == .l3 }
        for request in requests { _ = try await mixed.run(request); _ = try await all.run(request) }
        let mixedTokens = mixed.attempts.compactMap { $0.usage.total }.reduce(0, +), allTokens = all.attempts.compactMap { $0.usage.total }.reduce(0, +)
        let mc = mixed.attempts.compactMap(\.actualCost).reduce(0, +), ac = all.attempts.compactMap(\.actualCost).reduce(0, +)
        return "SYNTHETIC MOCK BENCHMARK — not live savings\nSame 3 tasks: all-L3 \(allTokens) tokens, \(String(format: "$%.6f", ac)); adaptive \(mixedTokens) tokens, \(String(format: "$%.6f", mc)).\nL3 calls: \(all.attempts.count) → \(mixed.attempts.filter { $0.tier == .l3 }.count). Synthetic token difference: \(allTokens - mixedTokens). Synthetic cost reduction: \(String(format: "%.1f", (ac - mc) / ac * 100))%.\nBoth runs passed structural output checks. Synthetic responses have no production quality score; latency includes deterministic mock delay. No API money spent."
    }
}
