import Foundation
import Combine

struct AIPlanDraft: Codable {
    struct Node: Codable {
        let key: String
        let objective: String
        let kind: AITaskKind
        let tier: AITier
        let dependencies: [String]
        let acceptance: [String]
        let constraints: [String]
        let expectedOutput: String
    }
    let objective: String
    let assumptions: [String]
    let risks: [String]
    let tasks: [Node]
    func packets(project: UUID, maximum: Int) throws -> [AITaskPacket] {
        guard !tasks.isEmpty, tasks.count <= maximum, Set(tasks.map(\.key)).count == tasks.count, tasks.allSatisfy({ !$0.key.isEmpty }) else { throw AIError.invalid("Planner returned invalid task keys or task count.") }
        let ids = Dictionary(uniqueKeysWithValues: tasks.map { ($0.key, UUID()) })
        var packets: [AITaskPacket] = []
        for node in tasks {
            guard node.dependencies.allSatisfy({ ids[$0] != nil }), !node.objective.isEmpty, !node.acceptance.isEmpty, !node.constraints.isEmpty, !node.expectedOutput.isEmpty else { throw AIError.invalid("Planner omitted task objective, constraints, acceptance or dependencies.") }
            let classified = AIClassifier.classify(node.objective)
            var packet = AITaskPacket.single(node.objective, project: project, classification: classified)
            packet = AITaskPacket(id: ids[node.key]!, projectID: project, objective: packet.objective, kind: node.kind, recommendedTier: max(node.tier, classified.tier), priority: packets.count, requirements: ["Complete only this assigned task."], relevantFiles: [], context: [], dependencies: node.dependencies.compactMap { ids[$0] }, constraints: node.constraints + ["Draft only. No file changes, command execution or external actions."], allowed: [.textGeneration], forbidden: packet.forbidden, acceptance: node.acceptance, expectedOutput: node.expectedOutput, verification: packet.verification, maxInputTokens: 5000, maxOutputTokens: min(1600, packet.maxOutputTokens))
            packets.append(packet)
        }
        _ = try AIGraph.levels(packets, maximum: maximum)
        return packets
    }
}
struct AIReview: Codable { let passed: Bool; let issues: [String]; let summary: String }
struct AIStoredRun: Codable { let project: AIProject; let attempts: [AIAttempt] }
struct AICacheValue { let output: AIWorkerOutput; let expires: Date }
struct AIAdaptation: Codable { var samples = 0; var failures = 0 }

final class AIJournal {
    let root: URL
    init(_ root: URL) throws {
        self.root = root.standardizedFileURL
        guard self.root.resolvingSymlinksInPath().path == self.root.path else { throw AIError.invalid("Orchestration store cannot be a symbolic link.") }
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        guard name.range(of: #"^[A-Za-z0-9-]+\.json$"#, options: .regularExpression) != nil else { throw AIError.invalid("Invalid journal path.") }
        let target = root.appendingPathComponent(name)
        guard (try? FileManager.default.attributesOfItem(atPath: target.path)[.type]) as? FileAttributeType != .typeSymbolicLink, target.resolvingSymlinksInPath().path == target.path, root.resolvingSymlinksInPath().path == root.path else { throw AIError.invalid("Journal symbolic link rejected.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 4_194_304 else { throw AIError.invalid("Journal record too large.") }
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard name.range(of: #"^[A-Za-z0-9-]+\.json$"#, options: .regularExpression) != nil else { return nil }
        let target = root.appendingPathComponent(name)
        guard (try? FileManager.default.attributesOfItem(atPath: target.path)[.type]) as? FileAttributeType != .typeSymbolicLink, target.resolvingSymlinksInPath().path == target.path,
              let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_194_304,
              let data = try? Data(contentsOf: target) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func runs() -> [AIStoredRun] {
        guard let paths = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return paths.filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil && $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(200).compactMap { load(AIStoredRun.self, name: $0.lastPathComponent) }
    }
}

final class AIEngine: ObservableObject {
    @Published var config: AIConfiguration
    @Published var projects: [AIProject] = []
    @Published var attempts: [AIAttempt] = []
    @Published var health: [String: AIHealth] = [:]
    @Published var status = "Adaptive router ready. Model prices and unknown telemetry are never inferred."
    @Published var activeProjectID: UUID?
    @Published var dryRunReport = ""
    @Published var requestDraft = ""
    @Published var benchmarkReport = ""
    @Published var cachedResponses = 0
    @Published var liveOutputs: [UUID: String] = [:]
    var streamedText: String { liveOutputs.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { liveOutputs[$0] }.joined(separator: "\n\n") }
    private var adapters: [String: AIProviderAdapter] = [:]
    private var journal: AIJournal?
    private var cache: [String: AICacheValue] = [:]
    private var adaptations: [String: AIAdaptation] = [:]
    private var cancelled = Set<UUID>()
    private var reservations: [UUID: Double] = [:]
    private var reservedTokens: [UUID: Int] = [:]
    private var inFlightProviders: [String: Int] = [:]
    init(root: URL? = nil, configuration: AIConfiguration? = nil) {
        let location = root ?? URL(fileURLWithPath: ChefCompatibility.path("/Users/danieljansen/Documents/Codex/2026-10-02/i-wa/outputs/Chef Home/orchestration"))
        journal = try? AIJournal(location)
        let loaded = configuration ?? journal?.load(AIConfiguration.self, name: "config.json") ?? AIConfiguration()
        config = loaded.valid ? loaded : AIConfiguration()
        if !loaded.valid { status = "Invalid saved configuration rejected; safe defaults restored." }
        if let journal {
            let runs = journal.runs().sorted { $0.project.createdAt > $1.project.createdAt }
            projects = runs.map(\.project); attempts = runs.flatMap(\.attempts)
            health = journal.load([String: AIHealth].self, name: "health.json") ?? [:]
            adaptations = journal.load([String: AIAdaptation].self, name: "performance.json") ?? [:]
            for index in projects.indices where [.running, .queued, .pending, .retrying, .escalated].contains(projects[index].state) {
                projects[index].state = .blocked
                projects[index].knownIssues.append("App stopped during execution. No tasks were automatically replayed.")
                for taskIndex in projects[index].results.indices where projects[index].results[taskIndex].state != .completed { projects[index].results[taskIndex].state = .blocked }
                try? journal.save(AIStoredRun(project: projects[index], attempts: attempts.filter { $0.projectID == projects[index].id }), name: projects[index].id.uuidString + ".json")
            }
        } else { status = "Orchestration storage unavailable. Execution is disabled until its journal is writable." }
    }
    func register(_ adapter: AIProviderAdapter) { adapters[adapter.id] = adapter }
    @MainActor func saveConfiguration() {
        guard config.valid else { status = "Invalid configuration; no changes saved."; return }
        do { guard let journal else { throw AIError.unavailable("Journal unavailable") }; try journal.save(config, name: "config.json"); status = "Routing configuration saved." }
        catch { status = error.localizedDescription }
    }
    @MainActor func resetLearnedRouting() { adaptations = [:]; try? journal?.save(adaptations, name: "performance.json"); status = "Learned routing reset." }
    @MainActor func healthCheck() async {
        for (id, adapter) in adapters {
            if health[id]?.available == false { continue }
            let available = await adapter.healthCheck()
            if available { health[id] = AIHealth() }
            else { health[id] = AIHealth(failures: 1, cooldownUntil: Date().addingTimeInterval(30), lastError: "Provider unavailable", latencyMs: nil) }
        }
        try? journal?.save(health, name: "health.json")
    }
    @MainActor func dryRun(_ request: String) {
        do {
            guard !AISecrets.containsSecret(request), !request.isEmpty else { throw AIError.invalid("Empty or credential-bearing request rejected.") }
            let c = AIClassifier.classify(request)
            let route = try AIRouter.select(c, config: config, health: health, knownProviders: Set(adapters.keys), degraded: degraded(c.kind))
            let cost = route.estimatedCost.map { String(format: "$%.6f", $0) } ?? "unavailable (Codex plan allowance)"
            dryRunReport = "Task: \(String(AISecrets.redact(request).prefix(160)))\nClassification: \(c.kind.rawValue), complexity \(c.complexity)/10, reasoning \(c.reasoning)/10, risk \(c.risk)/10\nRequired tier: \(c.tier.label)\nSelected: \(route.model.id) / \(route.model.tier.label)\nReason: \(route.reason)\nEstimated input/output tokens: \(route.estimatedInput)/\(route.estimatedOutput) (heuristic, not measured)\nEstimated cost: \(cost)\nFallback: \(route.fallback.isEmpty ? "none configured" : route.fallback.joined(separator: ", "))\nExpected workers: \(c.kind == .architecture ? "L3 planner determines a bounded graph; at most \(config.maximumTasks)" : "1")\nVerification: \(route.verificationLevel)\nNo AI request executed."
            status = "Dry-run completed without calling a provider."
        } catch { dryRunReport = error.localizedDescription; status = "Dry-run blocked." }
    }
    private func degraded(_ kind: AITaskKind) -> Set<String> {
        Set(config.models.compactMap { model in
            let stats = adaptations[kind.rawValue + ":" + model.id]
            return (stats?.samples ?? 0) >= config.adaptiveMinimumSamples && Double(stats?.failures ?? 0) / Double(stats!.samples) > 0.4 ? model.id : nil
        })
    }
    // Compatibility calls are traced and budget-gated without changing their finite executors.
    @MainActor func observe(_ request: String, model: AIModel, operation: () async throws -> AIWorkerOutput) async throws -> String {
        guard activeProjectID == nil, let journal else { throw AIError.unavailable("A durable journal and idle engine are required.") }
        guard config.valid, config.authorizedProviders.contains(model.provider), config.models.contains(where: { $0.id == model.id && $0.enabled && $0.authorized }), !AISecrets.containsSecret(request), request.count <= 12000 else { throw AIError.invalid("Manual provider is disabled, request contains credentials, or configuration is invalid.") }
        guard health[model.provider]?.available ?? true else { throw AIError.unavailable("Provider is cooling down.") }
        guard !config.dryRun else { dryRun(request); return dryRunReport }
        let projectID = UUID(), requestID = UUID(), attemptID = UUID(), start = Date()
        let classification = AIClassifier.classify(request)
        let packet = AITaskPacket.single(request, project: projectID, classification: classification)
        let route = AIRoute(model: model, reason: "Explicit manual/compatibility selection; existing local action permissions preserved. Required classification: " + classification.tier.label, estimatedInput: classification.estimatedInputTokens, estimatedOutput: min(model.maxOutputTokens, classification.estimatedOutputTokens), estimatedCost: model.estimateCost(input: classification.estimatedInputTokens, output: classification.estimatedOutputTokens), fallback: [], verificationLevel: "Output/permission checks; human review for architectural drafts")
        guard let adapter = adapters[model.provider] else { throw AIError.unavailable("No authorized adapter.") }
        try reserve(route, adapter: adapter, project: projectID, attempt: attemptID, estimatedInput: classification.estimatedInputTokens)
        let project = AIProject(id: projectID, requestID: requestID, objective: request, tasks: [packet], results: [], state: .running, createdAt: start, updatedAt: start, decisions: [route.reason], knownIssues: [], finalOutput: nil)
        try journal.save(AIStoredRun(project: project, attempts: []), name: projectID.uuidString + ".json")
        projects.insert(project, at: 0); activeProjectID = projectID
        var attempt = AIAttempt(id: attemptID, requestID: requestID, projectID: projectID, taskID: packet.id, modelID: model.id, provider: model.provider, tier: model.tier, reason: route.reason, estimatedInput: route.estimatedInput, estimatedOutput: route.estimatedOutput, usage: .unknown, estimatedCost: route.estimatedCost, actualCost: nil, latencyMs: 0, status: "running", failure: nil, timestamp: start)
        attempts.append(attempt); persist(projectID)
        defer { activeProjectID = nil; release(attemptID, provider: model.provider); cancelled.remove(projectID) }
        do {
            let output = try await operation()
            if cancelled.contains(projectID) { throw AIError.cancelled }
            attempt.usage = output.usage; attempt.actualModel = output.actualModel; attempt.actualCost = output.usage.cost(model)
            let verified = AIVerifier.verify(output, packet: packet)
            guard verified.passed else { throw AIError.verification(verified.issues.joined(separator: "; ")) }
            attempt.status = "success"; attempt.latencyMs = Int(Date().timeIntervalSince(start) * 1000); replaceAttempt(attempt)
            let state: AIState = classification.requiresReview ? .needsReview : .completed
            storeResult(projectID, AITaskResult(id: packet.id, state: state, output: output.text, summary: "Compatibility output checks passed. Human review remains required for code/architectural drafts.", attempts: [attemptID], verification: verified, modelID: model.id))
            updateProject(projectID) { $0.state = state; $0.finalOutput = output.text }
            return output.text
        } catch {
            attempt.status = "failed"; attempt.failure = AISecrets.redact(error.localizedDescription); attempt.latencyMs = Int(Date().timeIntervalSince(start) * 1000); replaceAttempt(attempt)
            storeResult(projectID, AITaskResult(id: packet.id, state: cancelled.contains(projectID) ? .cancelled : .failed, summary: AISecrets.redact(error.localizedDescription), attempts: [attemptID]))
            updateProject(projectID) { $0.state = .failed; $0.knownIssues.append(AISecrets.redact(error.localizedDescription)) }
            throw error
        }
    }
    @MainActor func run(_ request: String, context: [String] = [], forceProject: Bool = false, resumeProject: AIProject? = nil, localOnly: Bool = false) async throws -> String {
        guard activeProjectID == nil else { throw AIError.unavailable("An orchestration project is already running.") }
        guard let journal else { throw AIError.unavailable("A durable journal is required before execution.") }
        guard config.valid, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.count <= 12000, !AISecrets.containsSecret(request) else { throw AIError.invalid("Request is empty, oversized, contains credentials, or configuration is invalid.") }
        if config.dryRun { dryRun(request); return dryRunReport }
        let id = UUID(), requestID = UUID(), classification = AIClassifier.classify(request)
        var initial = AITaskPacket.single(request, project: id, classification: classification)
        if localOnly { initial.constraints.append("Use local models only.") }
        initial.context = AIContext.bounded(context, maxBytes: 4000, objective: request)
        var project = AIProject(id: id, requestID: requestID, objective: request, tasks: [initial], results: [], state: .queued, createdAt: Date(), updatedAt: Date(), decisions: [], knownIssues: [], finalOutput: nil)
        if let previous = resumeProject {
            let ids = Dictionary(uniqueKeysWithValues: previous.tasks.map { ($0.id, UUID()) })
            project.tasks = previous.tasks.map { old in
                AITaskPacket(id: ids[old.id]!, projectID: id, parentTaskID: old.id, objective: old.objective, kind: old.kind, recommendedTier: old.recommendedTier, priority: old.priority, requirements: old.requirements, relevantFiles: old.relevantFiles, context: old.context + previous.knownIssues.suffix(2), dependencies: old.dependencies.compactMap { ids[$0] }, constraints: old.constraints, allowed: old.allowed, forbidden: old.forbidden, acceptance: old.acceptance, expectedOutput: old.expectedOutput, verification: old.verification, maxInputTokens: old.maxInputTokens, maxOutputTokens: old.maxOutputTokens)
            }
            project.results = previous.results.filter { $0.state == .completed && $0.verification?.passed == true }.compactMap { old in
                guard let mapped = ids[old.id] else { return nil }
                return AITaskResult(id: mapped, state: .completed, output: old.output, summary: "Reused verified completed task from project " + previous.id.uuidString, attempts: [], verification: old.verification, modelID: old.modelID)
            }
            project.decisions = ["Explicit targeted rework of " + previous.id.uuidString + "; verified completed tasks are preserved."]
        }
        try journal.save(AIStoredRun(project: project, attempts: []), name: id.uuidString + ".json")
        projects.insert(project, at: 0); activeProjectID = id; liveOutputs = [:]
        defer { activeProjectID = nil; cancelled.remove(id); reservations = [:]; reservedTokens = [:]; inFlightProviders = [:] }
        do {
            updateProject(id) { $0.state = .running }
            if resumeProject == nil && (forceProject || classification.kind == .architecture) {
                var planPacket = initial; planPacket.recommendedTier = .l3; planPacket.kind = .architecture
                planPacket.expectedOutput = "JSON only: {\"objective\":string,\"assumptions\":[string],\"risks\":[string],\"tasks\":[{\"key\":string,\"objective\":string,\"kind\":\"text\"|\"coding\"|\"analysis\"|\"architecture\",\"tier\":0|1|2|3,\"dependencies\":[key],\"acceptance\":[string],\"constraints\":[string],\"expectedOutput\":string}]}. At most \(config.maximumTasks) tasks. Use parallel tasks where independent. Workers can only return drafts; no execution or file writes."
                planPacket.objective = "Plan this project with explicit requirements, dependencies, acceptance criteria and verification strategy: " + request
                planPacket.maxOutputTokens = 2000
                let plan = try await worker(planPacket, requestID: requestID, dependencyResults: [], requireJSON: true)
                guard plan.state == .completed, let text = plan.output else { throw AIError.verification(plan.summary) }
                let draft = try Self.decode(AIPlanDraft.self, text)
                let tasks = try draft.packets(project: id, maximum: config.maximumTasks)
                updateProject(id) { $0.tasks = tasks; $0.results = []; $0.decisions = draft.assumptions; $0.knownIssues = draft.risks }
                project = projects.first { $0.id == id }!
            }
            let layers = try AIGraph.levels(project.tasks, maximum: config.maximumTasks)
            for layer in layers {
                if cancelled.contains(id) { throw AIError.cancelled }
                var pending = layer
                while !pending.isEmpty {
                    let batch = Array(pending.prefix(config.budget.maxConcurrentWorkers)); pending.removeFirst(batch.count)
                    await withTaskGroup(of: AITaskResult.self) { group in
                        for taskID in batch {
                            guard let packet = project.tasks.first(where: { $0.id == taskID }) else { continue }
                            let results = projects.first { $0.id == id }?.results ?? []
                            if results.contains(where: { $0.id == packet.id && $0.state == .completed }) { continue }
                            let dependencies = packet.dependencies.compactMap { dependency in results.first { $0.id == dependency } }
                            if dependencies.contains(where: { $0.state != .completed }) || dependencies.count != packet.dependencies.count {
                                storeResult(id, AITaskResult(id: packet.id, state: .blocked, summary: "A dependency failed or needs review.", attempts: [])); continue
                            }
                            group.addTask { @MainActor in
                                do { return try await self.worker(packet, requestID: requestID, dependencyResults: dependencies.compactMap(\.output)) }
                                catch { return AITaskResult(id: packet.id, state: self.cancelled.contains(id) || error is CancellationError ? .cancelled : .failed, summary: error.localizedDescription, attempts: []) }
                            }
                        }
                        for await result in group { storeResult(id, result) }
                    }
                }
            }
            let results = projects.first { $0.id == id }!.results
            guard results.count == project.tasks.count, results.allSatisfy({ $0.state == .completed }) else { throw AIError.verification("Some tasks failed, were blocked, or require review. Completed results were preserved. " + results.filter { $0.state != .completed }.map { $0.state.rawValue + ": " + $0.summary }.joined(separator: "; ")) }
            let aggregate = project.tasks.compactMap { packet -> String? in
                guard let result = results.first(where: { $0.id == packet.id }), let text = result.output else { return nil }
                return project.tasks.count == 1 ? text : "\(packet.objective)\n\(text)"
            }.joined(separator: "\n\n")
            if classification.requiresReview || forceProject || results.contains(where: { $0.verification?.needsReview == true }) {
                var review = AITaskPacket.single("Review these worker drafts against the user's objective: " + request, project: id, classification: AIClassifier.classify("architecture review"))
                if localOnly { review.constraints.append("Use local models only.") }
                let compact: [[String: Any]] = project.tasks.map { task in
                    let result = results.first { $0.id == task.id }
                    let output = result?.output ?? ""
                    let excerptBudget = 6000 / max(1, project.tasks.count)
                    let excerpt = AIContext.bounded([output], maxBytes: excerptBudget, objective: "").first ?? ""
                    return ["taskId": task.id.uuidString, "objective": String(task.objective.prefix(200)), "acceptance": task.acceptance.map { String($0.prefix(150)) }, "state": result?.state.rawValue ?? "missing", "outputExcerpt": excerpt, "outputIsExcerpt": output.utf8.count > excerptBudget, "filesChanged": [], "testsRun": [], "verification": result?.verification?.checks ?? [], "needsReview": result?.verification?.needsReview ?? true, "confidence": NSNull()]
                }
                let data = try JSONSerialization.data(withJSONObject: ["projectObjective": String(request.prefix(1000)), "expectedTaskCount": project.tasks.count, "results": compact], options: [.sortedKeys])
                guard data.count <= 9000 else { throw AIError.budget("Review manifest exceeds its bounded context. Narrow the project or acceptance criteria.") }
                review.context = [String(decoding: data, as: UTF8.self)]
                review.expectedOutput = "JSON only: {\"passed\":boolean,\"issues\":[string],\"summary\":string}. Verify acceptance, conflicting outputs and missing requirements from the bounded draft summary. Output excerpts are not full source-code verification. Reject missing task outputs, unsupported claims of file changes or tests, and any assertion that unexecuted code was tested."
                let result = try await worker(review, requestID: requestID, dependencyResults: [], requireJSON: true)
                guard result.state == .completed, let text = result.output else { throw AIError.verification("L3 review failed: " + result.summary) }
                let verdict = try Self.decode(AIReview.self, text)
                guard verdict.passed && verdict.issues.isEmpty else { throw AIError.verification("L3 review requires rework: " + verdict.issues.joined(separator: "; ")) }
                updateProject(id) { $0.decisions.append("L3 bounded draft-summary review passed: " + verdict.summary) }
            }
            if cancelled.contains(id) { throw AIError.cancelled }
            updateProject(id) { $0.state = .completed; $0.finalOutput = aggregate }
            status = "Completed and verified \(results.count) draft task(s)."
            return aggregate
        } catch {
            let wasCancelled = cancelled.contains(id) || error is CancellationError
            updateProject(id) {
                $0.state = wasCancelled ? .cancelled : .blocked; $0.knownIssues.append(AISecrets.redact(error.localizedDescription))
                for index in $0.results.indices where [.running, .queued, .pending, .retrying, .escalated].contains($0.results[index].state) {
                    $0.results[index].state = wasCancelled ? .cancelled : .blocked
                    $0.results[index].summary = AISecrets.redact(error.localizedDescription)
                }
            }
            status = error.localizedDescription
            throw error
        }
    }
    @MainActor private func worker(_ packet: AITaskPacket, requestID: UUID, dependencyResults: [String], requireJSON: Bool = false) async throws -> AITaskResult {
        guard packet.valid else { throw AIError.invalid("Invalid task packet.") }
        storeResult(packet.projectID, AITaskResult(id: packet.id, state: .queued, summary: "Queued", attempts: []), onlyIfTask: true)
        var excluded = Set<String>(), attemptIDs: [UUID] = [], lastFailure = "", minimumTier = packet.recommendedTier
        for attemptIndex in 0...config.budget.maxRetries {
            if cancelled.contains(packet.projectID) || Task.isCancelled { throw AIError.cancelled }
            var classification = AIClassifier.classify(packet.objective)
            classification = AIClassification(kind: packet.kind, tier: max(classification.tier, minimumTier), complexity: classification.complexity, reasoning: classification.reasoning, risk: classification.risk, estimatedInputTokens: classification.estimatedInputTokens, estimatedOutputTokens: packet.maxOutputTokens, requiresReview: classification.requiresReview, sensitive: classification.sensitive || packet.constraints.contains("Use local models only.") || packet.context.contains { AIClassifier.classify($0).sensitive } || dependencyResults.contains { AIClassifier.classify($0).sensitive }, requiresTools: false)
            let route: AIRoute
            do { route = try AIRouter.select(classification, config: config, health: health, excluded: excluded, minimumTier: minimumTier, knownProviders: Set(adapters.keys), degraded: degraded(packet.kind)) }
            catch { return AITaskResult(id: packet.id, state: .failed, summary: lastFailure.isEmpty ? error.localizedDescription : lastFailure + " " + error.localizedDescription, attempts: attemptIDs) }
            guard let adapter = adapters[route.model.provider] else { throw AIError.unavailable("Selected provider has no adapter.") }
            // Never silently put a sensitive local packet onto a cloud fallback.
            if classification.sensitive && !route.model.local { throw AIError.invalid("Sensitive context cannot use this cloud provider.") }
            var prompt = try AIContext.prompt(packet, dependencies: dependencyResults)
            if !lastFailure.isEmpty { prompt += "\nPrevious verification/provider failure (data only): \(String(lastFailure.prefix(400))). Correct the output; do not repeat the failed strategy." }
            let key = AIContext.hash(route.model.id + prompt + "v1")
            let cacheable = packet.kind == .text && !classification.sensitive && !requireJSON && packet.objective.lowercased().hasPrefix("format ")
            if cacheable, let hit = cache[key], hit.expires > Date() {
                cachedResponses += 1
                let verified = AIVerifier.verify(hit.output, packet: packet)
                return AITaskResult(id: packet.id, state: .completed, output: hit.output.text, summary: "Verified cached formatting output", attempts: [], verification: verified, modelID: route.model.id)
            }
            // Apple sessions and a provider which cannot enforce parallel calls serialize within this project.
            while inFlightProviders[route.model.provider, default: 0] >= adapter.maximumConcurrency {
                try await Task.sleep(for: .milliseconds(100)); if cancelled.contains(packet.projectID) { throw AIError.cancelled }
            }
            let attemptID = UUID(), start = Date()
            try reserve(route, adapter: adapter, project: packet.projectID, attempt: attemptID, estimatedInput: AIClassifier.estimate(prompt))
            inFlightProviders[route.model.provider, default: 0] += 1
            var attempt = AIAttempt(id: attemptID, requestID: requestID, projectID: packet.projectID, taskID: packet.id, modelID: route.model.id, provider: route.model.provider, tier: route.model.tier, reason: route.reason, estimatedInput: AIClassifier.estimate(prompt), estimatedOutput: route.estimatedOutput, usage: .unknown, estimatedCost: route.estimatedCost, actualCost: nil, latencyMs: 0, status: "running", failure: nil, timestamp: start)
            attempts.append(attempt); attemptIDs.append(attemptID)
            storeResult(packet.projectID, AITaskResult(id: packet.id, state: attemptIndex == 0 ? .running : .escalated, summary: route.reason, attempts: attemptIDs, modelID: route.model.id), onlyIfTask: true)
            persist(packet.projectID)
            do {
                let output = try await adapter.stream(prompt: prompt, model: route.model, maxOutput: min(packet.maxOutputTokens, route.model.maxOutputTokens), requestID: attemptID) { [weak self] text in self?.liveOutputs[packet.id] = String(text.prefix(64000)) }
                if cancelled.contains(packet.projectID) { throw AIError.cancelled }
                attempt.usage = output.usage; attempt.actualModel = output.actualModel; attempt.actualCost = output.usage.cost(route.model)
                let verified = AIVerifier.verify(output, packet: packet)
                guard verified.passed else { throw AIError.verification(verified.issues.joined(separator: "; ")) }
                if requireJSON { _ = try JSONSerialization.jsonObject(with: Self.jsonData(output.text)) }
                attempt.usage = output.usage; attempt.actualModel = output.actualModel; attempt.actualCost = output.usage.cost(route.model); attempt.status = "success"
                attempt.latencyMs = Int(Date().timeIntervalSince(start) * 1000)
                replaceAttempt(attempt); release(attemptID, provider: route.model.provider)
                recordPerformance(packet.kind, model: route.model.id, failed: false)
                health[route.model.provider] = AIHealth(failures: 0, cooldownUntil: nil, lastError: nil, latencyMs: attempt.latencyMs)
                try? journal?.save(health, name: "health.json")
                if cacheable { if cache.count >= 64 { cache = [:] }; cache[key] = AICacheValue(output: output, expires: Date().addingTimeInterval(900)) }
                persist(packet.projectID)
                return AITaskResult(id: packet.id, state: .completed, output: output.text, summary: "Output/permission checks passed; generated code has not been executed.", attempts: attemptIDs, verification: verified, modelID: route.model.id)
            } catch {
                attempt.latencyMs = Int(Date().timeIntervalSince(start) * 1000); attempt.status = "failed"; attempt.failure = AISecrets.redact(error.localizedDescription)
                replaceAttempt(attempt); release(attemptID, provider: route.model.provider); persist(packet.projectID)
                if cancelled.contains(packet.projectID) || error is CancellationError { throw AIError.cancelled }
                recordPerformance(packet.kind, model: route.model.id, failed: true)
                lastFailure = AISecrets.redact(error.localizedDescription); excluded.insert(route.model.id)
                var providerHealth = health[route.model.provider] ?? AIHealth(); providerHealth.failures += 1; providerHealth.lastError = lastFailure
                if case AIError.rateLimited(let seconds) = error { providerHealth.cooldownUntil = Date().addingTimeInterval(Double(max(1, min(300, seconds)))) }
                else if case AIError.timeout = error { providerHealth.cooldownUntil = Date().addingTimeInterval(Double(min(120, 5 * (1 << min(providerHealth.failures, 4)) + Int.random(in: 0...2)))) }
                else if case AIError.unavailable = error { providerHealth.cooldownUntil = Date().addingTimeInterval(30) }
                health[route.model.provider] = providerHealth
                try? journal?.save(health, name: "health.json")
                // Alternate same-tier models first; then a higher tier. Never identical blind retries.
                if !config.models.contains(where: { !excluded.contains($0.id) && $0.tier == minimumTier && $0.enabled && $0.authorized }) { minimumTier = AITier(rawValue: min(3, minimumTier.rawValue + 1)) ?? .l3 }
            }
        }
        return AITaskResult(id: packet.id, state: .failed, summary: "Attempt limit reached: " + lastFailure, attempts: attemptIDs)
    }
    @MainActor private func reserve(_ route: AIRoute, adapter: AIProviderAdapter, project: UUID, attempt: UUID, estimatedInput: Int) throws {
        let records = attempts.filter { $0.projectID == project }
        guard records.count < config.budget.maxRequests else { throw AIError.budget("Hard project request limit reached.") }
        if route.model.tier == .l3 && records.filter({ $0.tier == .l3 }).count >= config.budget.maxL3Requests { throw AIError.budget("Hard L3 request limit reached.") }
        let bound = route.model.estimateCost(input: route.model.contextWindow ?? estimatedInput * 3, output: route.estimatedOutput)
        if !route.model.noMeteredCharge {
            guard adapter.supportsHardTokenLimit, route.model.contextWindow != nil, let bound, records.allSatisfy({ $0.actualCost != nil || $0.status == "running" }), bound <= config.budget.maxTaskCost else { throw AIError.budget("Unknown metered cost or task budget exceeded.") }
            let spent = records.compactMap(\.actualCost).reduce(0, +) + reservations.values.reduce(0, +)
            guard spent + bound <= config.budget.maxProjectCost else { throw AIError.budget("Hard project cost limit reached.") }
            let l3Spent = records.filter { $0.tier == .l3 }.compactMap(\.actualCost).reduce(0, +) + records.filter { $0.tier == .l3 && $0.status == "running" }.compactMap { reservations[$0.id] }.reduce(0, +)
            guard route.model.tier != .l3 || l3Spent + bound <= config.budget.maxL3Cost else { throw AIError.budget("Hard L3 cost limit reached.") }
            reservations[attempt] = bound
        }
        if let maxTokens = config.budget.maxTokens {
            guard adapter.supportsHardTokenLimit, records.allSatisfy({ $0.usage.total != nil || $0.status == "running" }) else { throw AIError.budget("Exact token ceiling is unsupported or measured usage is unavailable; no request sent.") }
            let reserve = (route.model.contextWindow ?? estimatedInput * 3) + route.estimatedOutput
            let measured = records.compactMap { $0.usage.total }.reduce(0, +)
            guard measured + reservedTokens.values.reduce(0, +) + reserve <= maxTokens else { throw AIError.budget("Hard token budget reached.") }
            reservedTokens[attempt] = reserve
        }
    }
    private func release(_ id: UUID, provider: String) { reservations.removeValue(forKey: id); reservedTokens.removeValue(forKey: id); inFlightProviders[provider] = max(0, inFlightProviders[provider, default: 0] - 1) }
    private func replaceAttempt(_ attempt: AIAttempt) { if let i = attempts.firstIndex(where: { $0.id == attempt.id }) { attempts[i] = attempt } }
    private func recordPerformance(_ kind: AITaskKind, model: String, failed: Bool) {
        let key = kind.rawValue + ":" + model
        var stats = adaptations[key] ?? AIAdaptation(); stats.samples += 1; if failed { stats.failures += 1 }; adaptations[key] = stats
        try? journal?.save(adaptations, name: "performance.json")
    }
    private func updateProject(_ id: UUID, _ change: (inout AIProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[index]); projects[index].updatedAt = Date(); persist(id)
    }
    private func storeResult(_ project: UUID, _ result: AITaskResult, onlyIfTask: Bool = false) {
        updateProject(project) { p in
            guard !onlyIfTask || p.tasks.contains(where: { $0.id == result.id }) else { return }
            if let index = p.results.firstIndex(where: { $0.id == result.id }) { p.results[index] = result } else { p.results.append(result) }
        }
    }
    private func persist(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        do { try journal?.save(AIStoredRun(project: project, attempts: attempts.filter { $0.projectID == id }), name: id.uuidString + ".json") }
        catch { status = "Journal write failed: " + error.localizedDescription; cancelled.insert(id) }
    }
    @MainActor func cancel() async {
        guard let id = activeProjectID else { return }; cancelled.insert(id)
        for adapter in adapters.values { await adapter.cancel() }
        status = "Cancelling active project; completed drafts will be retained."
    }
    @MainActor func retryFailedProject(_ id: UUID) async throws -> String {
        // New run, never automatic replay. Reuses only prior completed summaries as relevant context.
        guard let previous = projects.first(where: { $0.id == id }), [.failed, .blocked, .needsReview].contains(previous.state) else { throw AIError.invalid("Project is not eligible for explicit rework.") }
        return try await run(previous.objective, forceProject: previous.tasks.count > 1, resumeProject: previous)
    }
    static func jsonData(_ text: String) -> Data {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```"), let start = clean.firstIndex(of: "\n"), let end = clean.range(of: "```", options: .backwards), start < end.lowerBound { return Data(clean[clean.index(after: start)..<end.lowerBound].utf8) }
        return Data(clean.utf8)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONDecoder().decode(type, from: jsonData(text)) }
    var summary: String {
        let calls = attempts.count, success = attempts.filter { $0.status == "success" }.count
        let measured = attempts.filter { $0.usage.total != nil }, totals = measured.compactMap { $0.usage.total }.reduce(0, +)
        let priced = attempts.filter { $0.actualCost != nil }, cost = priced.compactMap(\.actualCost).reduce(0, +)
        let l3 = attempts.filter { $0.tier == .l3 }.count
        let latency = calls == 0 ? 0 : attempts.map(\.latencyMs).reduce(0, +) / calls
        return "\(projects.count) projects · \(calls) calls · \(success) successes · \(l3) L3 calls\nObserved tokens: \(totals) across \(measured.count)/\(calls) calls; missing telemetry is unavailable.\nConfigured-price cost: \(String(format: "$%.6f", cost)) across \(priced.count)/\(calls) priced calls; other costs unavailable.\nAverage call latency \(latency) ms · verified cache hits \(cachedResponses)\nNo live savings claim without an equivalent measured baseline."
    }
}
