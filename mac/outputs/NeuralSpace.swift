import SwiftUI
import AppKit

struct SpaceEntry: Identifiable {
    let id: String
    let title: String
    let kind: String
    let path: String
    var detail: String = ""
    var colorKey: String? = nil
}
enum PreviewSummary {
    static func clean(_ text: String, limit: Int = 240) -> String {
        let redacted = AISecrets.redact(text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(redacted.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func folder(_ url: URL, children: [URL]) -> String {
        let name = url.lastPathComponent == ChefCompatibility.path("Chef Home") ? "Chef Home" : url.lastPathComponent
        let purpose: String
        switch name {
        case "Chef Home": purpose = "Chef's local workspace for saved jobs, project notes, memory, skills, and orchestration records."
        case "jobs": purpose = "Saved local tasks and their status records."
        case "projects": purpose = "Local project notes and project-specific material."
        case "memory": purpose = "Locally stored assistant memory files."
        case "skills": purpose = "Local workflow guidance and skill catalog files."
        case "workflows": purpose = "Persistent schedules, worker playbooks and verified completion records."
        case "orchestration": purpose = "Adaptive routing configuration, task records, and run history."
        case "outputs": purpose = "Draft outputs produced by saved local jobs."
        default: purpose = "Direct contents of this workspace folder."
        }
        guard !children.isEmpty else { return purpose + " It is currently empty." }
        let files = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }.count
        let folders = children.count - files
        let kinds = [folders > 0 ? "\(folders) folders" : nil, files > 0 ? "\(files) files" : nil].compactMap { $0 }.joined(separator: " and ")
        return "\(purpose) " + (children.count >= 80 ? "Preview includes \(kinds) from at most 80 direct entries." : "Contains \(kinds) directly.")
    }
    static func chat(title: String, history: [(String, String)]?) -> String {
        guard let history, !history.isEmpty else { return "Codex conversation: \(clean(title, limit: 120)). Its message history has not been loaded in this preview." }
        let excerpts = history.suffix(2).compactMap { item -> String? in
            let value = clean(item.1, limit: 170)
            return value.isEmpty ? nil : "\(clean(item.0, limit: 16)): \(value)"
        }
        return "Codex conversation: \(clean(title, limit: 120)). Recent loaded messages: " + (excerpts.isEmpty ? "no readable text." : excerpts.joined(separator: " · "))
    }
    static func test() {
        precondition(clean("access_token=secretvalue ordinary text").contains("[REDACTED]"))
        precondition(clean(String(repeating: "x", count: 400)).count == 240)
        precondition(chat(title: "Design notes", history: nil).contains("Design notes"))
        print("Workspace preview summaries redact secrets and stay bounded.")
    }
}
enum WorkspaceMap {
    static func entries(_ path: String) -> [SpaceEntry] {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix("/Users/danieljansen/Documents/Codex/"), !url.pathComponents.contains(where: { $0.hasPrefix(".") }) else { return [] }
        guard url.resolvingSymlinksInPath().path == url.path,
              let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        return Array(children.prefix(256)).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
            let detail: String
            if values.isDirectory == true {
                let nested: [URL]
                if let listed = try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                    nested = listed.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                        .prefix(80).map { $0 }
                } else { nested = [] }
                detail = PreviewSummary.folder(child, children: nested)
            } else { detail = "Local \(child.pathExtension.isEmpty ? "file" : child.pathExtension.uppercased() + " file"). Open reveals it in Finder." }
            return SpaceEntry(id: child.path, title: child.lastPathComponent, kind: values.isDirectory == true ? "Folder" : "File", path: child.path, detail: detail)
        }
    }
    static func test() {
        precondition(entries("/Users/danieljansen/.codex").isEmpty)
        precondition(entries("/etc").isEmpty)
        precondition(entries("/Users/danieljansen/Documents/Codex/../.codex").isEmpty)
        PreviewSummary.test()
        print("Workspace map path and hidden-directory boundaries passed.")
    }
}

struct Hologram: View {
    let face: Bool
    let active: Bool
    var speaking = false
    var yawOffset = 0.0
    var pitchOffset = 0.0
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let yaw = yawOffset + (reduceMotion ? 0 : sin(time * 0.22) * (face ? 0.12 : 0.05))
                let pulse = reduceMotion ? 1.0 : 1 + sin(time * (speaking && face ? 9 : 1.4)) * (speaking && face ? 0.055 : 0.012)
                func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
                    let xx = x * cos(yaw) + z * sin(yaw)
                    let zz = -x * sin(yaw) + z * cos(yaw)
                    let yy = y * cos(pitchOffset) - zz * sin(pitchOffset)
                    let depth = (1 + zz * 0.16) * pulse
                    return CGPoint(x: size.width / 2 + xx * min(size.width * 0.7, size.height * 0.55) * depth, y: size.height * (face ? 0.43 : 0.5) + yy * size.height * (face ? 0.40 : 0.35) * depth)
                }
                var rows: [[CGPoint]] = []
                for i in 0...28 {
                    let v = Double(i) / 28 * .pi
                    var row: [CGPoint] = []
                    for j in 0...40 {
                        let u = Double(j) / 40 * 2 * .pi
                        var x = sin(v) * cos(u), y = -cos(v), z = sin(v) * sin(u)
                        if face {
                            x *= 0.70 * (y > 0.4 ? 1 - (y - 0.4) * 0.85 : 1)
                            if z > 0 {
                                let nose = exp(-pow(x / 0.14, 2) - pow((y - 0.12) / 0.24, 2)) * 0.36
                                let eyes = (exp(-pow((x - 0.24) / 0.12, 2)) + exp(-pow((x + 0.24) / 0.12, 2))) * exp(-pow((y + 0.10) / 0.10, 2)) * 0.14
                                let mouth = exp(-pow(x / 0.26, 2) - pow((y - 0.46) / (speaking ? 0.06 + abs(sin(time * 9)) * 0.025 : 0.06), 2)) * 0.1
                                z += nose - eyes - mouth
                            }
                        } else {
                            let wave = 1 + sin(u * 3 + time * 0.20) * sin(v * 2) * 0.24
                            x *= wave; z *= wave
                        }
                        row.append(project(x, y, z))
                    }
                    rows.append(row)
                }
                for i in rows.indices {
                    var path = Path(); path.addLines(rows[i]); context.stroke(path, with: .color(hudCyan.opacity(face ? (speaking ? 0.66 + sin(time * 9) * 0.12 : 0.42) : 0.35)), lineWidth: 0.6)
                    for j in rows[i].indices {
                        if i > 0 { var line = Path(); line.move(to: rows[i-1][j]); line.addLine(to: rows[i][j]); context.stroke(line, with: .color(hudCyan.opacity(0.18)), lineWidth: 0.5) }
                        if j % 2 == 0 && i % 2 == 0 { let p = rows[i][j]; context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)), with: .color(hudCyan.opacity(0.85))) }
                    }
                }
                if face {
                    var previous: [CGPoint] = []
                    for row in 0...5 {
                        let y = 0.95 + Double(row) * 0.10
                        let width = row < 3 ? 0.24 : 0.24 + Double(row - 2) * 0.24
                        let points = (0...16).map { column in
                            let u = Double(column) / 16 * .pi
                            return project(cos(u) * width, y, sin(u) * 0.25)
                        }
                        var neck = Path(); neck.addLines(points)
                        context.stroke(neck, with: .color(hudCyan.opacity(0.4)), lineWidth: 0.8)
                        if !previous.isEmpty {
                            for index in points.indices { var segment = Path(); segment.move(to: previous[index]); segment.addLine(to: points[index]); context.stroke(segment, with: .color(hudCyan.opacity(0.25)), lineWidth: 0.6) }
                        }
                        previous = points
                    }
                    func feature(_ points: [(Double, Double, Double)], opacity: Double = 0.65) {
                        var path = Path(); path.addLines(points.map { project($0.0, $0.1, $0.2) })
                        context.stroke(path, with: .color(hudCyan.opacity(opacity)), lineWidth: 1.2)
                    }
                    let blink = reduceMotion ? 1.0 : (time.truncatingRemainder(dividingBy: 5.2) < 0.16 ? 0.08 : 1.0)
                    for side in [-1.0, 1.0] {
                        for edge in [-1.0, 1.0] {
                            feature((0...16).map { i in
                                let t = Double(i) / 16 * .pi
                                return (side * 0.24 + cos(t) * 0.135, -0.10 + sin(t) * 0.055 * edge * blink, 0.99)
                            })
                        }
                        feature([(side * 0.38, -0.20, 0.91), (side * 0.25, -0.25, 1.0), (side * 0.11, -0.21, 1.01)])
                        feature([(side * 0.05, -0.14, 1.04), (side * 0.055, 0.17, 1.30), (side * 0.10, 0.27, 1.10), (0, 0.29, 1.20)])
                        feature((0...20).map { i in let t = Double(i) / 20 * 2 * Double.pi; return (side * (0.66 + sin(t) * 0.065), 0.06 + cos(t) * 0.20, 0.17) }, opacity: 0.4)
                    }
                    let mouthOpening = speaking ? 0.025 + abs(sin(time * 9)) * 0.03 : 0.01
                    for edge in [-1.0, 1.0] {
                        feature((0...20).map { i in let t = Double(i) / 20 * .pi; return (cos(t) * 0.21, 0.44 + sin(t) * mouthOpening * edge, 1.01) })
                    }
                    for side in [-1.0, 1.0] {
                        let point = project(side * 0.24, -0.10, 1)
                        context.addFilter(.shadow(color: hudCyan, radius: active ? 12 : 6))
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 2, width: 18, height: 4)), with: .color(hudCyan))
                    }
                }
            }
        }.accessibilityLabel(face ? "Chef holographic face" : "Workspace wireframe")
    }
}

struct NeuralSpace: View {
    @ObservedObject var model: ChefModel
    @ObservedObject var link: CodexLink
    @ObservedObject var engine: AIEngine
    let showsPortrait: Bool
    init(model: ChefModel, link: CodexLink, showsPortrait: Bool = true) { self.model = model; self.link = link; self.engine = model.orchestration; self.showsPortrait = showsPortrait }
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    @GestureState private var drag = CGSize.zero
    @State private var preview: SpaceEntry?
    var mode: String {
        get { model.spaceMode }
        nonmutating set { model.spaceMode = newValue }
    }
    @State private var folder = CodexLink.home
    @State private var page = 0
    @State private var inspectedJob: PersonalJob?
    private let modes = ["Presence", "Folders", "Chats", "Projects", "Agents", "Jobs"]
    var entries: [SpaceEntry] {
        switch mode {
        case "Folders": return WorkspaceMap.entries(folder)
        case "Chats": return link.chats.filter { !$0.agent }.map { chat in
            let loaded = link.selected?.id == chat.id ? link.history : nil
            return SpaceEntry(id: chat.id, title: chat.title, kind: "Codex chat", path: chat.cwd, detail: PreviewSummary.chat(title: chat.title, history: loaded))
        }
        case "Agents":
            let workers = AgentIdentity.entries(model: model, engine: engine).map { entry in
                let parts = entry.detail.split(separator: "\n", maxSplits: 1).map(String.init)
                let summary = parts.first.map { PreviewSummary.clean($0, limit: 200) } ?? "No task description is available."
                let context = parts.count > 1 ? " Context: \(PreviewSummary.clean(parts[1], limit: 120))." : ""
                return SpaceEntry(id: entry.id, title: entry.title, kind: entry.kind, path: entry.path, detail: "\(PreviewSummary.clean(entry.kind, limit: 80)): \(summary).\(context)", colorKey: entry.colorKey)
            }
            return workers + link.chats.filter(\.agent).map { chat in
                SpaceEntry(id: chat.id, title: AgentIdentity.name(chat.id), kind: "Codex agent", path: chat.cwd,
                           detail: "Codex subagent conversation: \(PreviewSummary.clean(chat.title, limit: 160)).", colorKey: chat.id)
            }
        case "Projects": return Array(Set(link.chats.map(\.cwd).filter { !$0.isEmpty })).sorted().map { path in
            let title = URL(fileURLWithPath: path).lastPathComponent
            let chats = link.chats.filter { $0.cwd == path }
            let names = chats.prefix(3).map { PreviewSummary.clean($0.title, limit: 90) }
            let related = names.isEmpty ? "No related conversation titles are loaded." : "Related Codex conversations: \(names.joined(separator: "; "))."
            return SpaceEntry(id: path, title: title, kind: "Workspace", path: path,
                              detail: "Workspace used by \(chats.count) loaded Codex conversation\(chats.count == 1 ? "" : "s"). \(related)")
        }
        case "Jobs": return model.workflows.map { job in SpaceEntry(id: "workflow:" + job.id, title: job.title, kind: "Scheduled workflow · " + job.state.rawValue, path: "", detail: "Daily \(String(format: "%02d:%02d", job.hour, job.minute)) · \(job.timezone) · \(job.location). Workers: \(job.workerIDs.joined(separator: ", ")). Next: \(job.nextRun?.formatted() ?? "not scheduled"). Last outcome: \(job.lastOutcome ?? "No run yet").") } + model.personalJobs.map { job in
            SpaceEntry(id: job.id.uuidString, title: job.title, kind: job.status, path: model.homePath + "/jobs",
                       detail: "\(PreviewSummary.clean(job.skill.title, limit: 80)) · \(PreviewSummary.clean(job.status, limit: 40)). Objective: \(PreviewSummary.clean(job.details, limit: 260)).")
        }
        default: return []
        }
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button { navigate(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous Chef space")
                Spacer(); Text(mode.uppercased()).tracking(2).font(.system(size: 10, design: .monospaced)); Spacer()
                Button { navigate(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next Chef space")
            }.buttonStyle(.plain)
            GeometryReader { geometry in
                ZStack {
                    if mode == "Presence" {
                        if showsPortrait { HolographicPortrait(speaking: model.isSpeaking) }
                    } else {
                        Hologram(face: false, active: true, yawOffset: yaw + Double(drag.width) * 0.008, pitchOffset: pitch + Double(drag.height) * 0.006)
                    }
                    if mode == "Agents" { AgentGroupMap(model: model) }
                    else if mode != "Presence" {
                        ForEach(Array(entries.dropFirst(page * 8).prefix(8).enumerated()), id: \.element.id) { index, entry in
                            let angle = Double(index) / 8 * 2 * Double.pi - Double.pi / 2
                            node(entry).position(nodePosition(angle, geometry.size)).opacity(nodeDepth(angle) < 0 ? 0.55 : 1)
                        }
                        if entries.isEmpty { Text(link.connected || mode == "Folders" || mode == "Jobs" ? "No \(mode.lowercased()) here" : "Connect to load \(mode.lowercased())").font(.caption).padding(8).background(.black.opacity(0.8)) }
                    }
                }.gesture(DragGesture(minimumDistance: 8).updating($drag) { value, state, _ in state = value.translation }.onChanged { _ in model.noteInteraction() }.onEnded { value in yaw += Double(value.translation.width) * 0.008; pitch += Double(value.translation.height) * 0.006 }).allowsHitTesting(mode != "Presence" || showsPortrait)
            }
            HStack {
                if mode == "Folders" {
                    Button("Home") { folder = model.homePath; page = 0 }
                    Button("Up") { let parent = URL(fileURLWithPath: folder).deletingLastPathComponent().path; if parent.hasPrefix("/Users/danieljansen/Documents/Codex/") { folder = parent; page = 0 } }
                    Button("Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }
                } else { Text(mode == "Presence" ? model.stateLabel : "\(entries.count) ITEMS").font(.system(size: 9, design: .monospaced)) }
                Spacer()
                if page > 0 { Button("‹") { page -= 1 } }
                if (page + 1) * 8 < entries.count { Button("›") { page += 1 } }
                if ["Chats", "Projects", "Agents"].contains(mode) {
                    Button("Refresh") { Task { await link.refreshChats() } }.disabled(!link.connected)
                    if link.nextCursor != nil { Button("More") { Task { await link.refreshChats(more: true) } } }
                }
            }.font(.system(size: 9))
            Text(mode == "Folders" ? folder : "Drag to rotate 360° · use arrows to switch spaces").font(.system(size: 8, design: .monospaced)).foregroundStyle(hudDim).lineLimit(1).help(folder)
        }.foregroundStyle(hudCyan)
            .onChange(of: model.spaceMode) { _, _ in page = 0 }
            .sheet(item: $inspectedJob) { job in
                VStack(alignment: .leading, spacing: 14) {
                    Text(job.title).font(.title2)
                    Text(job.skill.title + " · " + job.status).foregroundStyle(hudCyan)
                    ScrollView { Text(job.details).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Button("Open output") { model.openPersonalDraft(job) }.disabled(job.status != "Drafted"); Spacer(); Button("Close") { inspectedJob = nil } }
                }.padding(24).frame(width: 500, height: 350)
            }
    }
    func nodeDepth(_ angle: Double) -> Double { sin(angle + yaw + Double(drag.width) * 0.008) }
    func nodePosition(_ angle: Double, _ size: CGSize) -> CGPoint {
        let rotation = yaw + Double(drag.width) * 0.008
        let x = cos(angle + rotation), z = sin(angle + rotation)
        let latitude = sin(angle * 2) * 0.48
        let tilt = pitch + Double(drag.height) * 0.006
        let y = latitude * cos(tilt) - z * sin(tilt)
        return CGPoint(x: size.width / 2 + x * min(size.width * 0.32, size.height * 0.38), y: size.height / 2 + y * size.height * 0.38)
    }
    func node(_ entry: SpaceEntry) -> some View {
        let color = AgentIdentity.color(entry.colorKey ?? entry.id)
        return Button { model.noteInteraction(); preview = entry } label: {
            VStack(spacing: 5) {
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
                    Circle().fill(color).frame(width: 12, height: 12).shadow(color: color, radius: 12).opacity(0.80 + sin(timeline.date.timeIntervalSinceReferenceDate * 1.3 + Double(AgentIdentity.hash(entry.id) % 10)) * 0.15)
                }.frame(width: 20, height: 20)
                Text(entry.title).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(2)
                    .frame(width: 130).padding(6).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            }
        }.buttonStyle(.plain).help(entry.kind + " · " + entry.detail)
            .accessibilityLabel(entry.kind + ": " + entry.title)
            .popover(isPresented: Binding(get: { preview?.id == entry.id }, set: { if !$0 { preview = nil } })) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(entry.title, systemImage: "circle.fill").foregroundStyle(color).font(.headline)
                    Text(entry.kind).font(.caption)
                    Text(entry.detail.isEmpty ? entry.path : entry.detail).font(.callout).lineLimit(8).textSelection(.enabled)
                    if !entry.id.hasPrefix("worker:") && !entry.id.hasPrefix("specialist:") && !entry.id.hasPrefix("workflow:") {
                        Button("Open") { preview = nil; choose(entry) }
                    }
                    Button("Close preview") { preview = nil }
                }.padding(20).frame(width: 320)
            }
    }
    func navigate(_ offset: Int) { model.noteInteraction(); let index = modes.firstIndex(of: mode) ?? 0; mode = modes[(index + offset + modes.count) % modes.count]; page = 0 }
    func choose(_ entry: SpaceEntry) {
        if mode == "Folders" {
            if entry.kind == "Folder" { folder = entry.path; page = 0 }
            else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        } else if mode == "Projects" { folder = entry.path; mode = "Folders"; page = 0 }
        else if mode == "Jobs" { inspectedJob = model.personalJobs.first { $0.id.uuidString == entry.id } }
        else if let chat = link.chats.first(where: { $0.id == entry.id }) { Task { await link.inspect(chat) } }
    }
}

struct CodexChannel: View {
    @ObservedObject var model: ChefModel
    @ObservedObject var link: CodexLink
    @ObservedObject var engine: AIEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Adaptive", isOn: $model.adaptiveRouting).toggleStyle(.checkbox).disabled(model.thinking)
                Picker("AI", selection: $model.useCodex) { Text("ChatGPT / Codex").tag(true); Text("Apple local AI").tag(false) }.frame(width: 205).disabled(model.adaptiveRouting || model.thinking)
                Button(link.connected ? "Refresh" : "Connect") { Task { if link.connected { await link.refreshChats(); await link.refreshLimits() } else { await link.connect() }; model.configureWorkerModels() } }.disabled(link.busy)
                Button("New chat") { link.newConversation(); model.conversation = []; model.adaptiveRouting = false }.disabled(model.thinking)
                if link.selected != nil { Button("Continue as separate Chef chat") { model.adaptiveRouting = false; Task { await link.continueSelected(); model.conversation = link.history.map { ConversationLine(role: $0.0, text: $0.1) } } }.disabled(model.thinking || link.busy) }
                if engine.activeProjectID != nil { Button("Stop task") { Task { await engine.cancel() } } }
                if link.busy { Button("Stop reply") { Task { await link.cancel() } } }
            }.font(.caption)
            Text(link.status).font(.system(size: 9, design: .monospaced)).foregroundStyle(hudDim)
            if let snapshot = link.limits, let bucket = snapshot.limits.bucket {
                HStack(spacing: 18) {
                    allowance(bucket.primary, title: "PRIMARY")
                    allowance(bucket.secondary, title: "WEEKLY")
                    Text("Codex allowance · \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))").font(.system(size: 9, design: .monospaced)).foregroundStyle(hudDim)
                }.help(snapshot.spoken())
            }
            if let selected = link.selected { Text("\(selected.title) · \(selected.cwd)").font(.caption2).foregroundStyle(hudDim).lineLimit(1) }
        }
    }
    @ViewBuilder func allowance(_ window: AllowanceWindow?, title: String) -> some View {
        if let used = window?.usedPercent, used.isFinite {
            let remaining = max(0, min(100, 100 - used))
            HStack { Text("\(title) \(Int(remaining))% LEFT").font(.system(size: 9, design: .monospaced)); ProgressView(value: remaining, total: 100).tint(hudCyan).frame(width: 90) }
        }
    }
}
