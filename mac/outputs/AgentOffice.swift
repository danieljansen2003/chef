import SwiftUI

/// Canonical status mapping kept separate so the board can be checked without constructing UI state.
enum AgentOfficeBoardMapping {
    enum Lane: Equatable { case queued, running, review, done }

    static func personalJob(_ rawStatus: String) -> Lane {
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "queued", "saved", "saved from pocket", "pending": .queued
        case "working", "running", "drafting", "in progress": .running
        case "needs review", "needsreview", "review", "needs reminders", "needs input", "needs attention", "stopped": .review
        case "drafted", "completed", "complete", "done", "succeeded", "added to reminders": .done
        default: .review // Preserve an unfamiliar persisted state for inspection; never imply it is queued.
        }
    }

    static func workflow(_ state: AgentWorkflow.State, deliveryPending: Bool?) -> Lane {
        if deliveryPending == true { return .review }
        switch state {
        case .scheduled: return .queued
        case .running: return .running
        case .succeeded: return .done
        case .failed, .missed: return .review
        case .cancelled: return .review
        }
    }

    static func project(_ state: AIState) -> Lane {
        switch state {
        case .queued, .pending: return .queued
        case .running, .retrying, .escalated: return .running
        case .completed: return .done
        case .needsReview, .failed, .blocked, .cancelled: return .review
        }
    }

    static func selfTest() throws {
        guard personalJob("Queued") == .queued,
              personalJob("Saved from Pocket") == .queued,
              personalJob("Working") == .running,
              personalJob("Drafted") == .done,
              personalJob("Added to Reminders") == .done,
              personalJob("Needs review") == .review,
              personalJob("Needs Reminders") == .review,
              personalJob("Needs input") == .review,
              personalJob("unknown persisted state") == .review,
              workflow(.scheduled, deliveryPending: false) == .queued,
              workflow(.succeeded, deliveryPending: true) == .review,
              workflow(.succeeded, deliveryPending: false) == .done,
              project(.running) == .running,
              project(.needsReview) == .review,
              project(.completed) == .done else {
            throw AgentOfficeBoardMappingError.failed
        }
    }
}

enum AgentOfficeBoardMappingError: Error { case failed }

/// A native, read-only view of the workers and work already represented in Chef's stores.
@available(macOS 26.0, *)
struct AgentOffice: View {
    @ObservedObject var model: ChefModel
    @State private var selectedGroup: WorkflowGroup?
    @State private var selectedWorker: String?
    @State private var boardMode = false

    private let ink = Color(red: 0.025, green: 0.045, blue: 0.085)
    private var workers: [(name: String, role: String, group: String, symbol: String)] {
        [
            ("Nova", "Weather", "Briefing", "cloud.sun.fill"),
            ("Iris", "News", "Briefing", "newspaper.fill"),
            ("Atlas", "Tasks", "Briefing", "checklist"),
            ("Orion", "Secretary / Apps", "Apps", "app.badge"),
            ("Sage", "Knowledge", "Knowledge", "books.vertical.fill"),
            ("Vega", "Build", "Code", "hammer.fill")
        ]
    }
    private var hasActiveWork: Bool { cards.contains { $0.lane == .running } || model.orchestration.activeProjectID != nil || model.runningBriefing }

    var body: some View {
        VStack(spacing: 0) {
            header
            if boardMode { board } else { office }
        }
        .background(ink.gradient)
        .sheet(item: $selectedGroup) { group in groupDetail(group) }
        .sheet(item: Binding(get: { selectedWorker.map(WorkerSelection.init) }, set: { selectedWorker = $0?.name })) { selection in
            workerDetail(selection.name)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CHEF AGENT OFFICE").font(.system(size: 18, weight: .bold, design: .rounded)).tracking(2.2)
                Text(boardMode ? "SHARED WORK BOARD · LIVE SAVED STATE" : "DEPARTMENTS · PEOPLE · LIVE ACTIVITY")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(.white.opacity(0.56))
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(hasActiveWork ? .orange : .green).frame(width: 6, height: 6)
                Text(hasActiveWork ? "WORK IN PROGRESS" : "SYSTEM READY")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
            }.foregroundStyle(.white.opacity(0.78)).padding(.horizontal, 10).padding(.vertical, 8)
                .background(.white.opacity(0.07), in: Capsule())
            Picker("View", selection: $boardMode) {
                Text("Office").tag(false)
                Text("Board").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .foregroundStyle(.white)
    }

    private var office: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    // Quiet floor grid gives the room depth without relying on external art.
                    for i in -10...10 {
                        var a = Path(); a.move(to: CGPoint(x: size.width/2 + CGFloat(i)*34, y: size.height*0.43)); a.addLine(to: CGPoint(x: size.width/2 + CGFloat(i)*105, y: size.height))
                        context.stroke(a, with: .color(.cyan.opacity(0.055)), lineWidth: 1)
                        var b = Path(); b.move(to: CGPoint(x: 0, y: size.height*0.58 + CGFloat(i)*20)); b.addLine(to: CGPoint(x: size.width, y: size.height*0.58 + CGFloat(i)*20))
                        context.stroke(b, with: .color(.cyan.opacity(0.035)), lineWidth: 1)
                    }
                }.allowsHitTesting(false)
                VStack(spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        department("Briefing", span: 2)
                        department("Apps", span: 1)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        department("Knowledge", span: 1)
                        department("Code", span: 1)
                        department("Tasks", span: 1)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap").foregroundStyle(.cyan)
                        Text("SELECT A DEPARTMENT OR WORKER TO SEE CURRENT TASKS AND SAVED ACTIVITY")
                    }.font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.white.opacity(0.52)).padding(.top, 2)
                }
                .frame(maxWidth: min(geo.size.width - 36, 940))
                .position(x: geo.size.width / 2, y: geo.size.height / 2 + 6)
            }
        }
    }

    private func department(_ id: String, span: Int) -> some View {
        let group = WorkflowGroup.all.first { $0.id == id } ?? WorkflowGroup.all[0]
        let members = workers.filter { $0.group == id || (id == "Tasks" && $0.name == "Atlas") || (id == "Briefing" && $0.group == "Briefing") }
        let color = tint(group)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(color)
                    Text(group.responsibility).font(.system(size: 10)).foregroundStyle(.white.opacity(0.57)).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { selectedGroup = group } label: { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(color).padding(7).background(color.opacity(0.12), in: Circle()) }.buttonStyle(.plain).help("Open department details")
            }
            HStack(alignment: .top, spacing: 9) {
                ForEach(members, id: \.name) { worker in workerNode(worker.name, color: color) }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("CURRENT").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.white.opacity(0.4))
                    Text(departmentActivity(id)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.84)).lineLimit(2).multilineTextAlignment(.trailing)
                }.frame(maxWidth: 118, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background {
            Canvas { context, size in
                let top = CGPoint(x: size.width * 0.50, y: size.height * 0.08)
                let right = CGPoint(x: size.width * 0.98, y: size.height * 0.48)
                let front = CGPoint(x: size.width * 0.50, y: size.height * 0.88)
                let left = CGPoint(x: size.width * 0.02, y: size.height * 0.48)
                let drop = size.height * 0.11
                var leftWall = Path(); leftWall.move(to: left); leftWall.addLine(to: front); leftWall.addLine(to: CGPoint(x: front.x, y: front.y + drop)); leftWall.addLine(to: CGPoint(x: left.x, y: left.y + drop)); leftWall.closeSubpath()
                context.fill(leftWall, with: .color(color.opacity(0.34)))
                var rightWall = Path(); rightWall.move(to: front); rightWall.addLine(to: right); rightWall.addLine(to: CGPoint(x: right.x, y: right.y + drop)); rightWall.addLine(to: CGPoint(x: front.x, y: front.y + drop)); rightWall.closeSubpath()
                context.fill(rightWall, with: .color(color.opacity(0.20)))
                var deck = Path(); deck.move(to: top); deck.addLine(to: right); deck.addLine(to: front); deck.addLine(to: left); deck.closeSubpath()
                context.fill(deck, with: .linearGradient(Gradient(colors: [color.opacity(0.27), color.opacity(0.10)]), startPoint: top, endPoint: front))
                context.stroke(deck, with: .color(color.opacity(0.66)), lineWidth: 1.2)

                // Geometric desks and workers make each colored department a small office.
                let count = max(1, min(3, members.count))
                for index in 0..<count {
                    let fraction = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
                    let x = size.width * (0.34 + fraction * 0.32)
                    let y = size.height * (0.50 + abs(fraction - 0.5) * 0.12)
                    let deskWidth = size.width * 0.075
                    var desk = Path()
                    desk.move(to: CGPoint(x: x - deskWidth, y: y)); desk.addLine(to: CGPoint(x: x, y: y - 5))
                    desk.addLine(to: CGPoint(x: x + deskWidth, y: y)); desk.addLine(to: CGPoint(x: x, y: y + 5)); desk.closeSubpath()
                    context.fill(desk, with: .color(.white.opacity(0.18)))
                    context.stroke(desk, with: .color(color.opacity(0.72)), lineWidth: 0.8)
                    for side in [CGFloat(-1), CGFloat(1)] {
                        var leg = Path(); leg.move(to: CGPoint(x: x + deskWidth * side * 0.55, y: y + 1)); leg.addLine(to: CGPoint(x: x + deskWidth * side * 0.55, y: y + 7))
                        context.stroke(leg, with: .color(.white.opacity(0.32)), lineWidth: 1)
                    }
                    context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 18, width: 6, height: 6)), with: .color(color.opacity(0.95)))
                    var figure = Path(); figure.move(to: CGPoint(x: x, y: y - 12)); figure.addLine(to: CGPoint(x: x, y: y - 3))
                    figure.move(to: CGPoint(x: x, y: y - 8)); figure.addLine(to: CGPoint(x: x - 5, y: y - 4))
                    figure.move(to: CGPoint(x: x, y: y - 8)); figure.addLine(to: CGPoint(x: x + 5, y: y - 4))
                    context.stroke(figure, with: .color(.white.opacity(0.75)), lineWidth: 1.6)
                }
            }
        }
        .shadow(color: color.opacity(0.11), radius: 16, y: 8)
        .onTapGesture { selectedGroup = group }
    }

    private func workerNode(_ name: String, color: Color) -> some View {
        let info = workers.first { $0.name == name }!
        let active = workerHasActiveWork(name)
        return Button { selectedWorker = name } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(color.opacity(0.14)).frame(width: 34, height: 34)
                    Circle().stroke(color.opacity(0.62), lineWidth: 1).frame(width: 34, height: 34)
                    Image(systemName: info.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                    if active { Circle().fill(.green).frame(width: 7, height: 7).overlay(Circle().stroke(ink, lineWidth: 1.5)).offset(x: 13, y: -13) }
                }
                Text(name).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                Text(active ? "ACTIVE" : "READY").font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(active ? .green : .white.opacity(0.38))
            }.frame(width: 48)
        }.buttonStyle(.plain).help("Open \(name)'s current work")
    }

    private var board: some View {
        let columns: [(String, [OfficeCard])] = [
            ("QUEUED", cards.filter { $0.lane == .queued }), ("RUNNING", cards.filter { $0.lane == .running }),
            ("REVIEW", cards.filter { $0.lane == .review }), ("DONE", cards.filter { $0.lane == .done })
        ]
        return HStack(alignment: .top, spacing: 12) {
            ForEach(Array(columns.enumerated()), id: \.offset) { column in
                let title = column.element.0
                let items = column.element.1
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(title).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.2); Spacer(); Text("\(items.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.48)) }
                        .foregroundStyle(laneColor(title)).padding(.bottom, 4)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(items) { item in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { Text(item.worker.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.8).foregroundStyle(item.color); Spacer(); Text(item.source).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4)) }
                                    Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(3)
                                    if !item.detail.isEmpty { Text(item.detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.57)).lineLimit(3) }
                                    Text(item.when).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.36))
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(item.color.opacity(0.2), lineWidth: 1))
                            }
                            if items.isEmpty { Text("No saved work").font(.system(size: 9)).foregroundStyle(.white.opacity(0.32)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8) }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(.horizontal, 18).padding(.bottom, 18)
    }

    private var cards: [OfficeCard] {
        var result: [OfficeCard] = []
        for job in model.personalJobs {
            let lane: OfficeLane
            switch AgentOfficeBoardMapping.personalJob(job.status) {
            case .queued: lane = .queued
            case .running: lane = .running
            case .review: lane = .review
            case .done: lane = .done
            }
            result.append(OfficeCard(id: "job-\(job.id)", worker: workerFor(job.skill), title: job.title, detail: "\(job.status) · \(job.message)", source: "JOB", when: job.createdAt, lane: lane, color: workerColor(workerFor(job.skill))))
        }
        for workflow in model.workflows {
            let assigned = workflow.workerIDs.isEmpty ? "Nova · Iris · Atlas" : workflow.workerIDs.joined(separator: " · ")
            let lane: OfficeLane
            switch AgentOfficeBoardMapping.workflow(workflow.state, deliveryPending: workflow.deliveryPending) {
            case .queued: lane = .queued
            case .running: lane = .running
            case .review: lane = .review
            case .done: lane = .done
            }
            result.append(OfficeCard(id: "workflow-\(workflow.id)", worker: assigned, title: workflow.title, detail: workflow.lastOutcome ?? workflow.lastReport ?? workflow.requestSummary ?? "Saved workflow · \(workflow.timezone)", source: "FLOW", when: (workflow.lastFinishedAt ?? workflow.oneShotAt ?? workflow.nextRun ?? workflow.createdAt).formatted(date: .abbreviated, time: .shortened), lane: lane, color: tint(WorkflowGroup.all.first { $0.id == workflow.group } ?? WorkflowGroup.all[0])))
        }
        for project in model.orchestration.projects {
            let lane: OfficeLane = {
                switch AgentOfficeBoardMapping.project(project.state) { case .queued: return .queued; case .running: return .running; case .review: return .review; case .done: return .done }
            }()
            let detail = project.knownIssues.first ?? project.results.first(where: { $0.state == .needsReview || $0.state == .failed || $0.state == .blocked })?.summary ?? project.decisions.first ?? "\(project.tasks.count) task(s) · \(project.results.count) result(s)"
            result.append(OfficeCard(id: "project-\(project.id)", worker: "Vega · orchestration", title: project.objective, detail: detail, source: "PROJECT", when: project.updatedAt.formatted(date: .abbreviated, time: .shortened), lane: lane, color: workerColor("Vega")))
        }
        return result
    }

    private func groupDetail(_ group: WorkflowGroup) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text(group.title).font(.system(size: 19, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(tint(group)); Spacer(); Button("Close") { selectedGroup = nil } }
            Text(group.responsibility).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("PEOPLE").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
            ForEach(workers.filter { $0.group == group.id || (group.id == "Briefing" && $0.group == "Briefing") }, id: \.name) { w in HStack { Image(systemName: w.symbol).foregroundStyle(tint(group)); Text(w.name).bold(); Text(w.role).foregroundStyle(.secondary); Spacer(); Text(workerStatus(w.name)).font(.caption).foregroundStyle(.secondary) } }
            Divider()
            Text("SAVED ACTIVITY").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(cardsFor(group.id)) { card in activityRow(card) }; if cardsFor(group.id).isEmpty { Text("No saved tasks or workflow runs in this department.").font(.caption).foregroundStyle(.secondary) } } }
        }.padding(20).frame(width: 520, height: 470)
    }

    private func workerDetail(_ name: String) -> some View {
        let w = workers.first { $0.name == name }!
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: w.symbol).foregroundStyle(workerColor(name)); Text(name).font(.title2.bold()); Spacer(); Button("Close") { selectedWorker = nil } }
            Text(w.role + " specialist · " + workerStatus(name)).font(.caption).foregroundStyle(.secondary)
            if let book = model.playbooks.first(where: { $0.group == w.group }) {
                Text("Guidance: \(book.useCount) uses · \(book.successCount) verified successes · \(book.failureCount) need attention").font(.caption)
                if !book.lessons.isEmpty { Text(book.lessons.joined(separator: "\n\n")).font(.caption).textSelection(.enabled).lineLimit(6) }
            }
            Divider(); Text("CURRENT AND SAVED WORK").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(cards.filter { $0.worker.localizedCaseInsensitiveContains(name) || (name == "Vega" && $0.source == "PROJECT") }) { activityRow($0) }; if !cards.contains(where: { $0.worker.localizedCaseInsensitiveContains(name) || (name == "Vega" && $0.source == "PROJECT") }) { Text("No saved task or run assigned to this worker.").font(.caption).foregroundStyle(.secondary) } } }
        }.padding(20).frame(width: 500, height: 440)
    }

    private func activityRow(_ card: OfficeCard) -> some View {
        VStack(alignment: .leading, spacing: 4) { HStack { Text(card.title).font(.system(size: 12, weight: .semibold)); Spacer(); Text(card.lane.label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(card.color) }; Text(card.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3); Text("\(card.worker) · \(card.source) · \(card.when)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary) }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func cardsFor(_ group: String) -> [OfficeCard] {
        let names = workers.filter { $0.group == group || (group == "Briefing" && $0.group == "Briefing") }.map(\.name)
        return cards.filter { item in names.contains(where: { item.worker.localizedCaseInsensitiveContains($0) }) || (group == "Code" && item.source == "PROJECT") || (group == "Tasks" && item.worker.contains("Atlas")) }
    }
    private func departmentActivity(_ group: String) -> String {
        let count = cardsFor(group).count
        if count == 0 { return "No saved work" }
        let active = cardsFor(group).filter { $0.lane == .running }.count
        return active > 0 ? "\(active) active · \(count) saved" : "\(count) saved item\(count == 1 ? "" : "s")"
    }
    private func workerHasActiveWork(_ name: String) -> Bool { cards.contains { $0.lane == .running && $0.worker.localizedCaseInsensitiveContains(name) } || (name == "Nova" || name == "Iris" || name == "Atlas") && model.runningBriefing }
    private func workerStatus(_ name: String) -> String {
        if let status = model.workflowWorkerStatus[name], model.runningBriefing { return status }
        if workerHasActiveWork(name) { return "Working on a saved task" }
        return "Ready · no active run"
    }
    private func workerFor(_ skill: JobSkill) -> String { switch skill { case .todo, .planDay, .breakDownGoal: return "Atlas"; case .emailWorkflow, .draftMessage: return "Orion"; case .eccPlan, .eccDevelop, .eccReview, .eccVerify: return "Vega"; case .generalDraft: return "Sage" } }
    private func workerColor(_ name: String) -> Color { let group = workers.first { $0.name == name }?.group ?? "Code"; return tint(WorkflowGroup.all.first { $0.id == group } ?? WorkflowGroup.all[0]) }
    private func tint(_ group: WorkflowGroup) -> Color { Color(hue: group.hue, saturation: 0.70, brightness: 0.98) }
    private func laneColor(_ lane: String) -> Color { switch lane { case "QUEUED": return .cyan; case "RUNNING": return .green; case "REVIEW": return .orange; default: return .mint } }

    private struct WorkerSelection: Identifiable { let name: String; var id: String { name }; init(_ name: String) { self.name = name } }
    private enum OfficeLane { case queued, running, review, done; var label: String { switch self { case .queued: return "QUEUED"; case .running: return "RUNNING"; case .review: return "REVIEW"; case .done: return "DONE" } } }
    private struct OfficeCard: Identifiable { let id: String; let worker: String; let title: String; let detail: String; let source: String; let when: String; let lane: OfficeLane; let color: Color }
}
