import Foundation
import AppKit

@available(macOS 26.0, *)
extension ChefModel {
    func reloadWorkflows() {
        workflows = (try? workflowStore.workflows()) ?? []
        playbooks = (try? workflowStore.playbooks()) ?? []
        restorePendingBriefingDelivery()
        let active = workflows.first(where: { $0.state == .running })
        let pending = workflows.first(where: { $0.deliveryPending == true })
        let latestEvidence = workflows.filter { $0.lastFinishedAt != nil || $0.lastReport != nil }
            .max { ($0.lastFinishedAt ?? $0.lastStartedAt ?? $0.createdAt) < ($1.lastFinishedAt ?? $1.lastStartedAt ?? $1.createdAt) }
        if !runningBriefing, let job = active ?? pending ?? latestEvidence ?? workflows.first {
            workflowWorkerStatus = job.workerResults ?? [:]
            briefingText = job.lastReport ?? job.lastOutcome ?? ""
        }
    }
    private func restorePendingBriefingDelivery() {
        pendingBriefingDelivery = nil; pendingBriefingID = nil
        guard let job = try? workflowStore.pendingDelivery(), let report = job.lastReport else { return }
        pendingBriefingDelivery = report
        pendingBriefingID = job.id
        let scope = AgentBriefingScope(request: job.requestSummary, oneShot: job.oneShotAt != nil)
        pendingBriefingIsPrivate = scope.includesPrivateData
    }
    private func deliverPendingBriefingIfReady() {
        guard let report = pendingBriefingDelivery, let id = pendingBriefingID,
              !thinking, !isSpeaking, orchestration.activeProjectID == nil else { return }
        if shownBriefingAwaitingAckID != id {
            reply(report, cloudAllowed: !pendingBriefingIsPrivate, privateContent: pendingBriefingIsPrivate)
            showWindow?()
            NSSound(named: "Glass")?.play()
            shownBriefingAwaitingAckID = id
        }
        do {
            try workflowStore.markDelivered(id: id)
            pendingBriefingDelivery = nil; pendingBriefingID = nil; pendingBriefingIsPrivate = true
            shownBriefingAwaitingAckID = nil
        } catch { workspaceStatus = "Briefing was shown but delivery status could not be saved: " + error.localizedDescription }
    }
    func pollWorkflows() {
        restorePendingBriefingDelivery()
        deliverPendingBriefingIfReady()
        guard !runningBriefing else { return }
        do {
            let due = try workflowStore.due()
            reloadWorkflows()
            if let item = due.first { runBriefing(item) }
        } catch { workspaceStatus = "Workflow check failed: " + error.localizedDescription }
    }
    func runBriefing(_ job: AgentWorkflow) {
        guard !runningBriefing else { return }
        runningBriefing = true
        let oneShot = job.oneShotAt != nil
        let scope = AgentBriefingScope(request: job.requestSummary, oneShot: oneShot)
        let wantsWeather = scope.weather
        let wantsNews = scope.news
        let wantsTasks = scope.tasks
        workflowWorkerStatus = ["Nova": wantsWeather ? "Working · weather" : "Not requested", "Iris": wantsNews ? "Working · business headlines" : "Not requested", "Atlas": wantsTasks ? "Working · to-do list" : "Not requested"]
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runningBriefing = false }
            async let weather = Self.optionalPublicBriefingPart(wantsWeather, query: LiveQuery(kind: .weather, query: job.location))
            async let news = Self.optionalPublicBriefingPart(wantsNews, query: LiveQuery(kind: .news, query: "business"))
            async let tasks = self.optionalBriefingTasks(wantsTasks)
            var parts = await [weather, news, tasks]
            if wantsNews && scope.stockMarket {
                parts[1].0 += "\nStock coverage is limited to business headlines; live price quotes are not connected."
            }
            for (index, identity) in AgentWorkflowIdentity.briefingWorkers.enumerated() {
                let requested = [wantsWeather, wantsNews, wantsTasks][index]
                self.workflowWorkerStatus[identity.id] = requested ? (parts[index].1 ? "Complete" : "Needs attention") : "Not requested"
                if requested { try? self.workflowStore.recordOutcome(group: identity.title, success: parts[index].1, evidence: AISecrets.redact(String(parts[index].0.prefix(500)))) }
            }
            let label = job.requestSummary.map { "Requested briefing · " + $0 } ?? "Daily briefing"
            let requestedParts = zip([wantsWeather, wantsNews, wantsTasks], parts).filter { $0.0 }.map { $0.1.0 }
            let text = label + " · " + Date().formatted(date: .abbreviated, time: .shortened) + "\n\n" + requestedParts.joined(separator: "\n\n")
            self.briefingText = text
            let requestedResults = zip([wantsWeather, wantsNews, wantsTasks], parts).filter { $0.0 }.map { $0.1 }
            do { try self.workflowStore.complete(id: job.id, success: requestedResults.allSatisfy { $0.1 }, evidence: AISecrets.redact(String(text.prefix(500))), report: text, workers: self.workflowWorkerStatus) }
            catch { self.workspaceStatus = "Briefing ran but its outcome could not be saved: " + error.localizedDescription }
            self.reloadWorkflows()
            self.deliverPendingBriefingIfReady()
        }
    }
    private static func publicBriefingPart(_ query: LiveQuery) async -> (String, Bool) {
        if query.kind == .weather && query.query.isEmpty { return ("Weather needs a city. Say ‘set briefing location to Columbia, Illinois’.", false) }
        do { return (try await LiveInformation.answer(query), true) }
        catch { return ("\(query.kind == .weather ? "Weather" : "Business news") unavailable: \(error.localizedDescription)", false) }
    }
    private static func optionalPublicBriefingPart(_ requested: Bool, query: LiveQuery) async -> (String, Bool) {
        guard requested else { return ("\(query.kind == .weather ? "Weather" : "News"): not requested.", true) }
        return await publicBriefingPart(query)
    }
    private func optionalBriefingTasks(_ requested: Bool) async -> (String, Bool) {
        guard requested else { return ("To-do list: not requested.", true) }
        return await briefingTasks()
    }
    private func briefingTasks() async -> (String, Bool) {
        let summary = AISecrets.redact(await currentTodoSummary())
        return (summary, !summary.contains("Reminders list unavailable:"))
    }
}
