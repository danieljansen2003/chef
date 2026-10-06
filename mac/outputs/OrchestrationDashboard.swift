import SwiftUI
import AppKit

struct OrchestrationDashboard: View {
    @ObservedObject var engine: AIEngine
    @ObservedObject var link: CodexLink
    var request: String { engine.requestDraft }
    @State private var selectedCatalog = ""
    @State private var assignedTier = AITier.l1
    @State private var testing = false
    var body: some View {
        HUDPanel(title: "ADAPTIVE AI MANAGEMENT") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(engine.status).foregroundStyle(hudCyan).font(.caption)
                    HStack {
                        TextField("Task or project objective", text: $engine.requestDraft).textFieldStyle(.roundedBorder)
                        Button("Dry run") { engine.dryRun(request) }.disabled(request.isEmpty)
                        Button("Run draft project") { let objective = request; engine.requestDraft = ""; Task { do { _ = try await engine.run(objective, forceProject: true) } catch { engine.status = error.localizedDescription } } }.disabled(request.isEmpty || engine.activeProjectID != nil)
                        if engine.activeProjectID != nil { Button("Cancel") { Task { await engine.cancel() } } }
                    }
                    Text("Workers return drafts and plans. Code changes use Updates and ECC; generated text has no command or file-write permissions.").font(.caption2).foregroundStyle(hudDim)
                    if !engine.dryRunReport.isEmpty { Text(engine.dryRunReport).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                    HStack {
                        Picker("Budget mode", selection: $engine.config.budget.mode) { ForEach(AIBudgetMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Stepper("L3 cap: \(engine.config.budget.maxL3Requests)", value: $engine.config.budget.maxL3Requests, in: 0...20)
                        Stepper("Workers: \(engine.config.budget.maxConcurrentWorkers)", value: $engine.config.budget.maxConcurrentWorkers, in: 1...4)
                        Button("Save") { engine.saveConfiguration() }
                    }.disabled(engine.activeProjectID != nil).font(.caption)
                    Text("Paid-provider budgets remain zero. Exact token ceilings fail closed when a provider cannot enforce them. Pricing and capabilities can be configured in Chef Home/orchestration/config.json.").font(.caption2).foregroundStyle(hudDim)
                    registry
                    Text(engine.summary).font(.system(size: 10, design: .monospaced)).foregroundStyle(hudDim).textSelection(.enabled)
                    HStack {
                        Button("Provider health") { Task { await engine.healthCheck() } }
                        Button(testing ? "Testing…" : "Run mock acceptance suite") { runTests() }.disabled(testing)
                        Button("Mock benchmark") { Task { do { engine.benchmarkReport = try await OrchestrationTests.benchmark() } catch { engine.benchmarkReport = error.localizedDescription } } }
                        Button("Reset learned routing") { engine.resetLearnedRouting() }.disabled(engine.activeProjectID != nil)
                    }.font(.caption)
                    if !engine.benchmarkReport.isEmpty { Text(engine.benchmarkReport).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                    ForEach(engine.health.keys.sorted(), id: \.self) { provider in
                        let h = engine.health[provider]!
                        Text("\(provider): \(h.available ? "available" : "cooldown") · \(h.failures) failures · \(h.lastError ?? "no reported error")").font(.caption2).foregroundStyle(hudDim)
                    }
                    ForEach(engine.projects.prefix(20)) { project in projectView(project) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    var registry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL REGISTRY").font(.system(size: 10, design: .monospaced)).foregroundStyle(hudCyan)
            ForEach(engine.config.models) { model in
                HStack {
                    Text("\(model.tier.label) · \(model.id) · \(model.capabilities.sorted().joined(separator: ", "))").font(.caption)
                    Spacer()
                    Text(model.enabled ? "Enabled" : "Disabled").foregroundStyle(hudDim).font(.caption2)
                }
            }
            if !link.modelCatalog.isEmpty {
                DisclosureGroup("Available models from signed Codex catalog") {
                    ForEach(link.modelCatalog) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.title).font(.caption)
                                Spacer()
                                ForEach([AITier.l1, .l2, .l3], id: \.self) { tier in
                                    Button("Use " + tier.label) { selectedCatalog = item.model; assignedTier = tier; assignModel() }
                                        .accessibilityLabel("Assign " + item.title + " to " + tier.label)
                                }
                            }
                            Text(item.details).font(.caption2).foregroundStyle(hudDim)
                        }.disabled(engine.activeProjectID != nil)
                    }
                }.font(.caption)
            } else { Text("Connect Codex above to load its real model catalog. No model names or prices are guessed.").font(.caption2).foregroundStyle(hudDim) }
        }
    }
    func projectView(_ project: AIProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(project.state.rawValue.uppercased()) · \(project.objective)").font(.caption).lineLimit(2)
                Spacer()
                if [.blocked, .failed, .needsReview].contains(project.state) {
                    Button("Rework unfinished tasks") { Task { do { _ = try await engine.retryFailedProject(project.id) } catch { engine.status = error.localizedDescription } } }.disabled(engine.activeProjectID != nil)
                }
            }
            Text("Project \(project.id.uuidString) · request \(project.requestID.uuidString)").font(.system(size: 8, design: .monospaced)).foregroundStyle(hudDim).textSelection(.enabled)
            ForEach(project.tasks) { packet in
                let result = project.results.first { $0.id == packet.id }
                VStack(alignment: .leading, spacing: 3) {
                    Text("↳ \(packet.recommendedTier.label) · \(packet.objective) → \(result?.state.rawValue ?? "pending")").font(.caption)
                    Text(result?.summary ?? "Waiting for dependencies").font(.caption2).foregroundStyle(hudDim)
                    if let output = result?.output { Text(String(output.prefix(2000))).font(.caption2).textSelection(.enabled) }
                    ForEach(engine.attempts.filter { $0.taskID == packet.id }) { attempt in
                        Text("\(attempt.tier.label) / \(attempt.actualModel ?? attempt.modelID) / \(attempt.status) / \(attempt.latencyMs) ms · \(attempt.reason)").font(.system(size: 8, design: .monospaced)).foregroundStyle(hudDim)
                    }
                }.padding(.leading, 8)
            }
            ForEach(engine.attempts.filter { attempt in attempt.projectID == project.id && !project.tasks.contains { $0.id == attempt.taskID } }) { attempt in
                Text("Planner / review → " + attempt.tier.label + " · " + (attempt.actualModel ?? attempt.modelID) + " · " + attempt.status).font(.caption2).foregroundStyle(hudCyan)
            }
            ForEach(Array(project.decisions.enumerated()), id: \.offset) { _, decision in Text(decision).font(.caption2).foregroundStyle(hudDim) }
            ForEach(Array(project.knownIssues.enumerated()), id: \.offset) { _, issue in Text(issue).foregroundStyle(.orange).font(.caption2) }
            if let final = project.finalOutput { DisclosureGroup("Final draft") { Text(final).font(.caption).textSelection(.enabled) } }
        }.padding(10).background(hudCyan.opacity(0.04))
    }
    func assignModel() {
        guard link.modelCatalog.contains(where: { $0.model == selectedCatalog }) else { return }
        let id = "codex:" + selectedCatalog
        var model = AIModel.codexDefault
        model = AIModel(id: id, provider: "codex", model: selectedCatalog, tier: assignedTier, capabilities: ["text", "code", "reasoning"], contextWindow: nil, maxOutputTokens: 2000, supportsTools: false, supportsVision: false, supportsStructuredOutput: true, inputPrice: nil, outputPrice: nil, cachedInputPrice: nil, reliability: 0.90, priority: assignedTier.rawValue, enabled: true, authorized: true, local: false, noMeteredCharge: true, latencyEstimateMs: 5000)
        if let index = engine.config.models.firstIndex(where: { $0.id == id }) { engine.config.models[index] = model } else { engine.config.models.append(model) }
        engine.saveConfiguration()
    }
    func runTests() {
        testing = true
        Task { @MainActor in
            defer { testing = false }
            do { engine.benchmarkReport = try await OrchestrationTests.run() }
            catch { engine.benchmarkReport = "Mock suite failed: " + error.localizedDescription }
        }
    }
}
