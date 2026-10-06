import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct OrbWorkspace: View {
    @ObservedObject var model: ChefModel
    var space: String? = nil
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    @State private var folder = ""
    @State private var selected: SpaceEntry?
    @State private var planning = false
    @State private var agentGroups = false
    @State private var page = 0
    @GestureState private var drag = CGSize.zero
    private let pageSize = 36

    private var mode: String { space ?? model.spaceMode }
    private var entries: [SpaceEntry] {
        switch mode {
        case "Folders": return WorkspaceMap.entries(folder.isEmpty ? model.homePath : folder)
        case "Chats": return model.codex.chats.filter { !$0.agent }.map { chat in
            SpaceEntry(id: chat.id, title: chat.title, kind: "Codex chat", path: chat.cwd,
                       detail: PreviewSummary.chat(title: chat.title, history: model.codex.selected?.id == chat.id ? model.codex.history : nil))
        }
        case "Projects":
            return Array(Set(model.codex.chats.map(\.cwd).filter { !$0.isEmpty })).sorted().map { path in
                let chats = model.codex.chats.filter { $0.cwd == path }
                return SpaceEntry(id: path, title: URL(fileURLWithPath: path).lastPathComponent, kind: "Workspace", path: path,
                                  detail: "Workspace used by \(chats.count) loaded Codex conversations. " + chats.prefix(3).map { PreviewSummary.clean($0.title, limit: 80) }.joined(separator: "; "))
            }
        case "Agents":
            let workers = AgentIdentity.entries(model: model, engine: model.orchestration).map { item in
                SpaceEntry(id: item.id, title: item.title, kind: item.kind, path: item.path,
                           detail: PreviewSummary.clean(item.detail.replacingOccurrences(of: "\n", with: " · "), limit: 260), colorKey: item.colorKey)
            }
            return workers + model.codex.chats.filter(\.agent).map { chat in
                SpaceEntry(id: chat.id, title: AgentIdentity.name(chat.id), kind: "Codex agent", path: chat.cwd,
                           detail: "Codex subagent conversation: \(PreviewSummary.clean(chat.title, limit: 160)).", colorKey: chat.id)
            }
        case "Jobs":
            return model.workflows.map { job in
                SpaceEntry(id: "workflow:" + job.id, title: job.title, kind: "Scheduled workflow · " + job.state.rawValue, path: "",
                           detail: "\(job.group) · Workers: \(job.workerIDs.joined(separator: ", ")). Next: \(job.nextRun?.formatted() ?? "not scheduled"). Last outcome: \(job.lastOutcome ?? "No run yet").")
            } + model.personalJobs.map { job in
                SpaceEntry(id: job.id.uuidString, title: job.title, kind: job.skill.title + " · " + job.status, path: model.homePath + "/jobs",
                           detail: "\(job.status). \(PreviewSummary.clean(job.details, limit: 260))")
            }
        case "Calendar": return calendarEntries + taskEntries + briefingEntries
        case "Tasks": return taskEntries + briefingEntries
        default: return []
        }
    }
    private var calendarEntries: [SpaceEntry] {
        model.calendarEvents.map { event in
            SpaceEntry(id: "event:" + event.id + ":" + String(Int(event.start.timeIntervalSince1970)), title: event.title, kind: "Calendar event", path: "",
                       detail: "\(event.isAllDay ? "All day" : event.start.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarTitle)")
        }
    }
    private var taskEntries: [SpaceEntry] {
        model.reminderSnapshots.filter { !$0.isCompleted }.map { item in
            SpaceEntry(id: "reminder:" + item.id, title: item.title, kind: "Reminder · \(item.listTitle)", path: "",
                       detail: item.dueDate?.formatted(date: .abbreviated, time: .shortened) ?? "No due date")
        } + model.personalJobs.filter { $0.skill == .todo && !["Completed", "Done", "Added to Reminders"].contains($0.status) }.map { job in
            SpaceEntry(id: "todo:" + job.id.uuidString, title: job.title, kind: "Saved local task · \(job.status)", path: model.homePath + "/jobs",
                       detail: job.dueDate?.formatted(date: .abbreviated, time: .shortened) ?? PreviewSummary.clean(job.details, limit: 220))
        }
    }
    private var briefingEntries: [SpaceEntry] {
        model.workflows.compactMap { job in
            guard let date = PlanningWorkflowSchedule.nextRun(for: job) else { return nil }
            return SpaceEntry(id: "workflow:" + job.id, title: job.title, kind: "Scheduled briefing", path: "",
                              detail: "\(date.formatted(date: .abbreviated, time: .shortened)) · \(job.state.rawValue) · \(job.workerIDs.joined(separator: ", "))")
        }
    }
    private func makeNodes(_ visibleEntries: [SpaceEntry], totalCount: Int, offset: Int) -> [OrbNode] {
        visibleEntries.enumerated().map { localIndex, entry in
            let index = localIndex + offset
            let stable = Double(AgentIdentity.hash(entry.id) % 100_000) / 100_000
            let angle = Double(index) * 2.3999632297 + stable * 0.35
            let latitude = asin(1 - 2 * (Double(index) + 0.5) / Double(max(totalCount, 1)))
            return OrbNode(id: entry.id, title: entry.title, detail: entry.detail, hue: entry.colorKey.map { Double(AgentIdentity.hash($0) % 100_000) / 100_000 } ?? 0.105, angle: angle, latitude: latitude)
        }
    }

    var body: some View {
        let allEntries = entries
        let offset = page * pageSize
        let visibleEntries = Array(allEntries.dropFirst(offset).prefix(pageSize))
        let visibleNodes = makeNodes(visibleEntries, totalCount: allEntries.count, offset: offset)
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(mode.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(hudCyan)
                if mode == "Folders" { Text(folder.isEmpty ? model.homePath : folder).font(.system(size: 9, design: .monospaced)).foregroundStyle(hudDim).lineLimit(1) }
                Spacer()
                if ["Chats", "Projects", "Agents"].contains(mode) {
                    Button(model.codex.connected ? "Refresh" : "Connect") { Task { if model.codex.connected { await model.codex.refreshChats() } else { await model.codex.connect() } } }
                        .disabled(model.codex.busy).font(.caption)
                }
                if mode == "Agents" { Button("Agent groups") { agentGroups = true }.font(.caption) }
                if mode == "Calendar" || mode == "Tasks" { Button(mode == "Tasks" ? "Open full task list" : "Open calendar/list") { showPlanning() }.font(.caption) }
                if mode == "Calendar", !model.calendarConnected { Button("Connect Calendar") { model.connectCalendar() }.font(.caption) }
                if (mode == "Calendar" || mode == "Tasks"), !model.remindersConnected { Button("Connect Reminders") { model.connectReminders() }.font(.caption) }
                if mode == "Folders" {
                    Button("Home") { folder = model.homePath }
                    Button("Up") { navigateUp() }
                    Button("Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.isEmpty ? model.homePath : folder) }
                }
            }
            GeometryReader { geo in
                ZStack {
                    OrbHologram(speaking: model.isSpeaking, thinking: model.thinking || model.orchestration.activeProjectID != nil,
                                listening: model.isListening, yaw: yaw + Double(drag.width) * 0.008, pitch: pitch + Double(drag.height) * 0.006, variant: mode,
                                nodes: visibleNodes, onSelect: { node in model.noteInteraction(); selected = visibleEntries.first { $0.id == node.id } })
                    if allEntries.isEmpty && mode != "Presence" {
                        Text(emptyMessage).font(.system(size: 12, design: .monospaced)).foregroundStyle(hudDim)
                            .padding(9).background(.black.opacity(0.7), in: Capsule()).offset(y: geo.size.height * 0.37)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 8).updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        model.noteInteraction()
                        yaw += Double(value.translation.width) * 0.008
                        pitch = max(-0.9, min(0.9, pitch + Double(value.translation.height) * 0.006))
                    })
            }
            HStack {
                if mode != "Presence" {
                    Text("\(allEntries.isEmpty ? 0 : offset + 1)–\(min(offset + pageSize, allEntries.count)) OF \(allEntries.count) NODES · DRAG TO ROTATE 360°")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(hudDim)
                }
                Spacer()
                if offset > 0 { Button("‹ Previous") { page = max(0, page - 1) }.font(.caption) }
                if offset + pageSize < allEntries.count { Button("Next ›") { page += 1 }.font(.caption) }
                if mode == "Chats" || mode == "Projects" || mode == "Agents", model.codex.nextCursor != nil {
                    Button("More") { Task { await model.codex.refreshChats(more: true) } }.disabled(model.codex.busy).font(.caption)
                }
            }
            if mode == "Calendar" || mode == "Tasks" {
                HStack(spacing: 12) {
                    if mode == "Calendar" { Text(model.calendarLoadStatus).lineLimit(1) }
                    Text(model.remindersLoadStatus).lineLimit(1)
                }.font(.system(size: 8, design: .monospaced)).foregroundStyle(hudDim)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .onAppear {
            if folder.isEmpty { folder = model.homePath }
            if mode == "Calendar" || mode == "Tasks" { Task { await model.refreshPlanningData(month: model.planningDate) } }
        }
        .onChange(of: mode) { _, next in
            selected = nil
            page = 0
            if next == "Calendar" || next == "Tasks" { Task { await model.refreshPlanningData(month: model.planningDate) } }
        }
        .onChange(of: entries.count) { _, count in page = min(page, max(0, (count - 1) / pageSize)) }
        .popover(item: $selected) { entry in detail(entry).padding(18).frame(width: 340) }
        .sheet(isPresented: $planning) { PlanningWorkspace(model: model, space: mode == "Tasks" ? "Tasks" : "Calendar").frame(minWidth: 720, minHeight: 560) }
        .sheet(isPresented: $agentGroups) { AgentGroupMap(model: model).frame(minWidth: 650, minHeight: 500).padding(20) }
    }

    private var emptyMessage: String {
        switch mode {
        case "Folders": return "No visible items in this folder"
        case "Chats", "Projects", "Agents": return model.codex.connected ? "No loaded items" : "Connect Codex to load items"
        case "Calendar": return model.calendarConnected ? "No calendar events or tasks" : "Connect Calendar to show events · tasks remain local"
        case "Tasks": return model.remindersConnected ? "No active tasks or briefings" : "Connect Reminders to show reminders"
        default: return ""
        }
    }

    @ViewBuilder private func detail(_ entry: SpaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(entry.title, systemImage: "circle.fill").font(.headline).foregroundStyle(AgentIdentity.color(entry.colorKey ?? entry.id))
            Text(entry.kind).font(.caption).foregroundStyle(hudDim)
            Text(entry.detail.isEmpty ? entry.path : entry.detail).font(.callout).textSelection(.enabled)
            if mode == "Folders" || mode == "Projects" { Button("Open") { open(entry) } }
            else if mode == "Chats" || (mode == "Agents" && !entry.id.hasPrefix("worker:") && !entry.id.hasPrefix("specialist:")) { Button("Open conversation") { Task { if let chat = model.codex.chats.first(where: { $0.id == entry.id }) { await model.codex.inspect(chat) } } } }
            else if mode == "Jobs", let job = model.personalJobs.first(where: { $0.id.uuidString == entry.id }), job.status == "Drafted" { Button("Open output") { model.openPersonalDraft(job) } }
            else if mode == "Calendar" || mode == "Tasks" { Button("Open full calendar/list") { showPlanning() } }
            Button("Close") { selected = nil }
        }
    }

    private func open(_ entry: SpaceEntry) {
        selected = nil
        if mode == "Folders" {
            if entry.kind == "Folder" { folder = entry.path }
            else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        } else if mode == "Projects" { folder = entry.path; model.spaceMode = "Folders" }
    }

    private func showPlanning() {
        selected = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { planning = true }
    }

    private func navigateUp() {
        let current = folder.isEmpty ? model.homePath : folder
        let root = "/Users/danieljansen/Documents/Codex"
        let parent = URL(fileURLWithPath: current).standardizedFileURL.deletingLastPathComponent().path
        guard parent == root || parent.hasPrefix(root + "/") else { return }
        folder = parent
    }
}
