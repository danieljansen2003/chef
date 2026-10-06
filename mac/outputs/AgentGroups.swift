import SwiftUI

struct WorkflowGroup: Identifiable {
    let id: String
    let title: String
    let responsibility: String
    let members: [String]
    let hue: Double
    static let all: [Self] = [
        .init(id: "Briefing", title: "BRIEFING", responsibility: "Daily and one-time briefings use only the workers requested for each saved run.", members: ["Nova", "Iris", "Atlas"], hue: 0.50),
        .init(id: "Weather", title: "WEATHER", responsibility: "Current weather from fixed public sources for your saved city.", members: ["Nova"], hue: 0.56),
        .init(id: "News", title: "NEWS", responsibility: "Public business headlines with sources and fetch times.", members: ["Iris"], hue: 0.78),
        .init(id: "Tasks", title: "TASKS", responsibility: "Atlas handles connected Reminders, saved to-dos, scheduled work and completion evidence.", members: ["Atlas"], hue: 0.12),
        .init(id: "Apps", title: "SECRETARY / APPS", responsibility: "Orion handles approved app launches and Gmail desktop tasks. Every exact recipient, subject and body needs human review before sending.", members: ["Orion"], hue: 0.31),
        .init(id: "Knowledge", title: "KNOWLEDGE", responsibility: "Local conversation and reusable human-authored guidance.", members: ["Sage"], hue: 0.65),
        .init(id: "Code", title: "BUILD", responsibility: "Human update requests, tested code changes and draft workers.", members: ["Vega"], hue: 0.04)
    ]
}

@available(macOS 26.0, *)
struct AgentGroupMap: View {
    @ObservedObject var model: ChefModel
    @State private var selected: WorkflowGroup?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    for index in WorkflowGroup.all.indices {
                        let point = position(index, size)
                        var path = Path(); path.move(to: center); path.addLine(to: point)
                        context.stroke(path, with: .color(hudCyan.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 8]))
                    }
                }.allowsHitTesting(false)
                VStack { Image(systemName: "sparkles").font(.largeTitle); Text("CHEF").tracking(4); Text("TASK GROUPS").font(.caption2) }.foregroundStyle(hudCyan)
                ForEach(Array(WorkflowGroup.all.enumerated()), id: \.element.id) { index, group in
                    Button { model.noteInteraction(); selected = group } label: {
                        VStack(spacing: 6) {
                            ZStack { Circle().stroke(color(group).opacity(0.35), lineWidth: 1).frame(width: 54, height: 54); Circle().fill(color(group)).frame(width: 10, height: 10).shadow(color: color(group), radius: 16) }
                            Text(group.title).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(1)
                            Text(group.members.joined(separator: " · ")).font(.caption2)
                        }.frame(width: 145).foregroundStyle(color(group)).padding(5).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).position(position(index, geometry.size)).help(group.responsibility)
                }
            }
        }.sheet(item: $selected) { group in
            VStack(alignment: .leading, spacing: 12) {
                Text(group.title).font(.title2).foregroundStyle(color(group))
                Text(group.responsibility).font(.caption)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(group.members, id: \.self) { name in
                            HStack {
                                Circle().fill(color(group)).frame(width: 8, height: 8)
                                Text(name).bold()
                                Spacer()
                                Text(memberStatus(name, group: group.id)).font(.caption).multilineTextAlignment(.trailing)
                            }
                        }
                        if group.id == "Briefing" { briefingRecords }
                        if group.id == "Tasks" { savedJobs(for: .todo, empty: "No saved to-do jobs.") }
                        if group.id == "Apps" { savedJobs(for: .emailWorkflow, empty: "No saved Gmail desktop tasks.") }
                        if let book = model.playbooks.first(where: { $0.group == group.id }) {
                            Text("\(book.useCount) uses · \(book.successCount) verified successes · \(book.failureCount) need attention").font(.caption)
                            Text(book.lessons.isEmpty ? "No guidance saved yet. Say ‘remember for the \(group.id) agent …’." : book.lessons.joined(separator: "\n\n")).font(.caption).textSelection(.enabled)
                        } else { Text("No guidance saved yet. Say ‘remember for the \(group.id) agent …’.").font(.caption) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Close") { selected = nil }
            }.padding(24).frame(width: 500, height: 460)
        }
    }

    @ViewBuilder private var briefingRecords: some View {
        let jobs = model.workflows.filter { $0.group == "Briefing" }.sorted { $0.createdAt > $1.createdAt }
        if jobs.isEmpty {
            Text("No saved briefing runs.").font(.caption)
        } else {
            ForEach(jobs) { job in
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.oneShotAt == nil ? "Daily briefing" : "One-time briefing").font(.headline)
                    Text(job.requestSummary ?? "Standard daily briefing").font(.caption).textSelection(.enabled)
                    Text("\(workflowStatus(job)) · \(workflowDeadline(job)) · \(job.timezone)").font(.caption2)
                    if job.deliveryPending == true { Text("Prepared · waiting for delivery").font(.caption).foregroundStyle(hudCyan) }
                    let scope = AgentBriefingScope(request: job.requestSummary, oneShot: job.oneShotAt != nil)
                    let assigned = assignedWorkers(scope)
                    Text("Assigned: \(assigned.isEmpty ? "none" : assigned.joined(separator: ", "))").font(.caption2)
                    ForEach(assigned, id: \.self) { worker in
                        Text("\(worker): \(workerResult(worker, job: job))").font(.caption2).textSelection(.enabled)
                    }
                    if let result = job.lastReport ?? job.lastOutcome { Text(result).font(.caption).lineLimit(8).textSelection(.enabled) }
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(hudCyan.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder private func savedJobs(for skill: JobSkill, empty: String) -> some View {
        let jobs = Array(model.personalJobs.filter { $0.skill == skill }.prefix(12))
        if jobs.isEmpty {
            Text(empty).font(.caption)
        } else {
            ForEach(jobs) { job in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(job.title) · \(job.status)").font(.headline)
                    Text(job.message).font(.caption).textSelection(.enabled)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(hudCyan.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func memberStatus(_ name: String, group: String) -> String {
        guard group == "Briefing", let job = model.workflows.filter({ $0.group == "Briefing" }).max(by: { $0.createdAt < $1.createdAt }) else {
            return model.workflowWorkerStatus[name] ?? "Ready · no individual run result"
        }
        let scope = AgentBriefingScope(request: job.requestSummary, oneShot: job.oneShotAt != nil)
        guard assignedWorkers(scope).contains(name) else { return "Not assigned to this run" }
        return workerResult(name, job: job)
    }

    private func assignedWorkers(_ scope: AgentBriefingScope) -> [String] {
        var workers: [String] = []
        if scope.weather { workers.append("Nova") }
        if scope.news { workers.append("Iris") }
        if scope.tasks { workers.append("Atlas") }
        return workers
    }

    private func workerResult(_ worker: String, job: AgentWorkflow) -> String {
        if let saved = job.workerResults?[worker] { return saved }
        if job.state == .running, model.runningBriefing { return model.workflowWorkerStatus[worker] ?? "Working" }
        if job.deliveryPending == true { return "No individual result saved" }
        if job.state == .scheduled { return "Assigned · waiting for due time" }
        return "No individual result saved"
    }

    private func workflowStatus(_ job: AgentWorkflow) -> String {
        job.deliveryPending == true ? "Prepared" : job.state.rawValue.capitalized
    }

    private func workflowDeadline(_ job: AgentWorkflow) -> String {
        let date: Date?
        if job.deliveryPending == true { date = job.oneShotAt ?? job.lastFinishedAt ?? job.nextRun }
        else if job.state == .failed || job.state == .missed { date = job.lastFinishedAt ?? job.oneShotAt ?? job.nextRun }
        else { date = job.oneShotAt ?? job.nextRun ?? job.lastStartedAt }
        return date?.formatted(date: .complete, time: .shortened) ?? "Time not available"
    }

    private func color(_ group: WorkflowGroup) -> Color { Color(hue: group.hue, saturation: 0.75, brightness: 1) }
    private func position(_ index: Int, _ size: CGSize) -> CGPoint {
        let angle = Double(index) / 7 * 2 * Double.pi - Double.pi / 2
        return CGPoint(x: size.width / 2 + cos(angle) * max(30, min(size.width * 0.35, 330)), y: size.height / 2 + sin(angle) * max(30, min(size.height * 0.33, 230)))
    }
}
