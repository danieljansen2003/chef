import SwiftUI
import AppKit

let hudCyan = Color(red: 0.20, green: 0.88, blue: 1.0)
let hudDim = Color(red: 0.34, green: 0.60, blue: 0.68)

struct HUDFrame: Shape {
    func path(in r: CGRect) -> Path {
        let c: CGFloat = 12
        var p = Path()
        p.move(to: CGPoint(x: c, y: 0)); p.addLine(to: CGPoint(x: r.width - c, y: 0))
        p.addLine(to: CGPoint(x: r.width, y: c)); p.addLine(to: CGPoint(x: r.width, y: r.height - c))
        p.addLine(to: CGPoint(x: r.width - c, y: r.height)); p.addLine(to: CGPoint(x: c, y: r.height))
        p.addLine(to: CGPoint(x: 0, y: r.height - c)); p.addLine(to: CGPoint(x: 0, y: c)); p.closeSubpath()
        return p
    }
}

struct HUDPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Rectangle().fill(hudCyan).frame(width: 3, height: 12); Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(hudCyan); Spacer() }
            content()
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(HUDFrame().fill(Color(red: 0.018, green: 0.075, blue: 0.10).opacity(0.88)))
            .overlay(HUDFrame().stroke(hudCyan.opacity(0.28), lineWidth: 1))
    }
}

struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for x in stride(from: CGFloat(0), through: size.width, by: 36) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: CGFloat(0), through: size.height, by: 36) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
            context.stroke(grid, with: .color(hudCyan.opacity(0.045)), lineWidth: 0.5)
        }.background(Color(red: 0.006, green: 0.021, blue: 0.035)).allowsHitTesting(false)
    }
}

struct Reactor: View {
    let state: String
    let active: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
            let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 8
            ZStack {
                Circle().fill(RadialGradient(colors: [hudCyan.opacity(active ? 0.23 : 0.08), .clear], center: .center, startRadius: 10, endRadius: 145))
                Circle().stroke(hudCyan.opacity(0.18), lineWidth: 1).padding(6)
                Circle().stroke(hudCyan.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 7])).padding(17)
                ForEach(0..<4, id: \.self) { index in
                    Circle().trim(from: 0.02, to: 0.19).stroke(hudCyan.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .square))
                        .padding(30).rotationEffect(.degrees(angle + Double(index) * 90))
                }
                Circle().stroke(hudCyan.opacity(0.45), lineWidth: 1).padding(43)
                ForEach(0..<36, id: \.self) { index in
                    Rectangle().fill(hudCyan.opacity(index % 3 == 0 ? 0.8 : 0.22)).frame(width: 2, height: index % 3 == 0 ? 12 : 6)
                        .offset(y: -86).rotationEffect(.degrees(Double(index) * 10 - angle / 2))
                }
                Circle().stroke(hudCyan.opacity(0.3), lineWidth: 2).padding(69)
                Circle().stroke(hudCyan.opacity(0.5), lineWidth: 1).padding(76)
                VStack(spacing: 10) {
                    Image(systemName: active ? "waveform" : "waveform.circle").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(hudCyan)
                    Text(state).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(hudCyan)
                }
            }.frame(width: 272, height: 272).shadow(color: hudCyan.opacity(0.2), radius: 12)
        }.accessibilityLabel("Chef \(state.lowercased())")
    }
}

/// Carries samples from the same native orb geometry into the calendar and task layouts.
private struct OrbWorkspaceDissolve: View, Animatable {
    var progress: Double
    let speaking: Bool
    let listening: Bool
    let thinking: Bool
    let destination: PresenceDissolveDestination
    let variant: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            guard size.width > 1, size.height > 1 else { return }
            let mode: OrbGeometry.Mode = speaking ? .speaking : (thinking ? .thinking : (listening ? .listening : .idle))
            let fullCloud = OrbGeometry.project(count: 3_600, variant: variant, mode: mode, yaw: 0, pitch: 0,
                                                time: 0, radius: min(size.width, size.height) * 0.405)
            let cloud = (0..<420).map { fullCloud[$0 * fullCloud.count / 420] }
            let t = min(1, max(0, progress))
            let movement = reduceMotion ? 0.0 : t * t * (3 - 2 * t)
            for (index, particle) in cloud.enumerated() {
                let target = destinationPoint(index, layout: destination)
                let startX = Double(size.width / 2 + particle.x) / Double(size.width)
                let startY = Double(size.height / 2 - particle.y) / Double(size.height)
                let jitter = reduceMotion ? 0 : sin(t * .pi * 2 + Double(index) * 1.7) * 0.006 * sin(t * .pi)
                let x = startX + (target.x - startX) * movement + jitter
                let y = startY + (target.y - startY) * movement
                let center = CGPoint(x: x * Double(size.width), y: y * Double(size.height))
                let separation = reduceMotion ? 0 : sin(t * .pi) * (2 + Double(index % 7))
                let angle = Double(index) * 2.3999632297
                let point = CGPoint(x: center.x + cos(angle) * separation, y: center.y + sin(angle) * separation)
                let alpha = particle.alpha * (reduceMotion ? 1 - t * 0.25 : 1)
                let diameter = max(1.1, particle.radius * 2.4)
                let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
                context.opacity = alpha
                context.fill(Path(ellipseIn: rect), with: .color(particle.color))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func destinationPoint(_ index: Int, layout: PresenceDissolveDestination) -> CGPoint {
        switch layout {
        case .calendar:
            let cell = index % 42
            let column = cell % 7
            let row = cell / 7
            let sample = index / 42
            let along = Double(sample % 3) * 0.24 + 0.18
            let x0 = 0.035 + Double(column) * (0.93 / 7)
            let x1 = 0.035 + Double(column + 1) * (0.93 / 7)
            let y0 = 0.22 + Double(row) * (0.57 / 6)
            let y1 = 0.22 + Double(row + 1) * (0.57 / 6)
            switch sample % 4 {
            case 0: return CGPoint(x: x0 + (x1 - x0) * along, y: y0)
            case 1: return CGPoint(x: x1, y: y0 + (y1 - y0) * along)
            case 2: return CGPoint(x: x1 - (x1 - x0) * along, y: y1)
            default: return CGPoint(x: x0, y: y1 - (y1 - y0) * along)
            }
        case .tasks:
            let row = index % 5
            let slot = index / 5 % 84
            return CGPoint(x: 0.08 + Double(slot) * 0.01,
                           y: 0.30 + Double(row) * 0.105)
        }
    }
}

@available(macOS 26.0, *)
struct ChefView: View {
    @ObservedObject var model: ChefModel
    @State private var tab = "Conversation"
    @State private var search = ""
    @State private var controls = false
    @State private var presentedSpace = "Presence"
    @State private var transitionProgress = 0.0
    @State private var transitioningSpace = false
    @State private var transitionToken: UInt64 = 0
    @State private var transitionTargetSpace = "Presence"
    @State private var transitionArrivingAtPlanning = false
    @State private var transitionDestination: PresenceDissolveDestination = .calendar
    @State private var transitionVariant = "Presence"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                if transitioningSpace {
                    workspaceView(for: presentedSpace)
                        .opacity(transitionArrivingAtPlanning ? 1 - transitionProgress : transitionProgress)
                    workspaceView(for: transitionTargetSpace)
                        .opacity(transitionArrivingAtPlanning ? transitionProgress : 1 - transitionProgress)
                } else {
                    workspaceView(for: presentedSpace)
                }
                if transitioningSpace {
                    OrbWorkspaceDissolve(progress: transitionProgress, speaking: model.isSpeaking,
                                         listening: model.isListening,
                                         thinking: model.thinking || model.orchestration.activeProjectID != nil,
                                         destination: transitionDestination, variant: transitionVariant)
                        .opacity(0.9).allowsHitTesting(false)
                }
            }.allowsHitTesting(!transitioningSpace).padding(.top, 72).padding(.bottom, model.conversation.last == nil ? 112 : 174)
            VStack(alignment: .leading, spacing: 10) {
                header
                if presentedSpace == "Presence" && !controls { statePills }
                Spacer(minLength: 0)
                if controls {
                    VStack(alignment: .leading, spacing: 10) {
                        CodexChannel(model: model, link: model.codex, engine: model.orchestration)
                        ScrollView(.horizontal, showsIndicators: false) {
                          HStack(spacing: 7) {
                ForEach(["Conversation", "Timers", "Apps", "Context & Jobs", "Voice & Safety", "Computer", "System", "Updates", "AI Manager"], id: \.self) { section in
                    Button(section.uppercased()) { model.noteInteraction(); tab = section }
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1)
                        .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 10)
                        .background(tab == section ? hudCyan.opacity(0.15) : .clear)
                        .overlay(Rectangle().stroke(hudCyan.opacity(tab == section ? 0.7 : 0.16)))
                }
                          }
                        }
            Group {
                if tab == "Conversation" { conversationPanel }
                else if tab == "Timers" { timersPanel }
                else if tab == "Apps" { appsPanel }
                else if tab == "Computer" { DesktopDashboard(controller: model.desktopControl, agent: model.desktopAgent) }
                else if tab == "System" { systemPanel }
                else if tab == "Updates" { updatesPanel }
                else if tab == "AI Manager" { OrchestrationDashboard(engine: model.orchestration, link: model.codex) }
                else if tab == "Context & Jobs" { personalWorkspacePanel }
                else { voicePanel }
            }.frame(maxWidth: .infinity).frame(height: 225)
                    }.padding(12).background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
                }
                if !controls,
                   let latest = model.conversation.last(where: { $0.role == "CHEF" }) {
                    Text(latest.text).font(.system(size: 15)).foregroundStyle(.white)
                        .lineLimit(3).textSelection(.enabled).multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
                commandPanel
            }.padding(24)
        }.frame(minWidth: 900, minHeight: 680)
            .onAppear { presentedSpace = model.spaceMode }
            .onChange(of: model.spaceMode) { _, newSpace in
                controls = false
                changeSpace(to: newSpace)
            }
            .onChange(of: model.desktopPanelRequested) { _, requested in if requested { controls = true; tab = "Computer"; model.desktopPanelRequested = false } }
            .background(.black).preferredColorScheme(.dark).tint(hudCyan)
    }

    var statePills: some View {
        HStack(spacing: 7) {
            ForEach(["LISTENING", "THINKING", "SPEAKING"], id: \.self) { state in
                let active = (state == "LISTENING" && model.isListening) || (state == "THINKING" && (model.thinking || model.orchestration.activeProjectID != nil)) || (state == "SPEAKING" && model.isSpeaking)
                let color = state == "LISTENING" ? Color(red: 1, green: 0.67, blue: 0.25) : state == "THINKING" ? Color(red: 0.71, green: 0.59, blue: 1) : Color(red: 1, green: 0.35, blue: 0.47)
                Text(state).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
                    .foregroundStyle(active ? color : color.opacity(0.35))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(active ? color.opacity(0.12) : .white.opacity(0.035), in: Capsule())
                    .overlay(Capsule().stroke(active ? color.opacity(0.5) : color.opacity(0.12), lineWidth: 1))
            }
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            Text("CHEF").font(.system(size: 18, weight: .light, design: .monospaced)).tracking(4).foregroundStyle(.white)
            Menu {
                ForEach(["Presence", "Calendar", "Tasks", "Phone", "Folders", "Chats", "Projects", "Agents", "Jobs"], id: \.self) { space in
                    Button(space == "Tasks" ? "To-do list" : space) { requestSpaceChange(to: space) }
                }
            } label: {
                Label(model.spaceMode, systemImage: "square.grid.2x2").font(.system(size: 11, design: .monospaced)).foregroundStyle(hudDim)
            }.menuStyle(.borderlessButton)
            Spacer()
            if presentedSpace != "Presence" && !transitioningSpace {
                Button { requestSpaceChange(to: "Presence") } label: {
                    OrbHologram(speaking: model.isSpeaking,
                                thinking: model.thinking || model.orchestration.activeProjectID != nil,
                                listening: model.isListening, variant: "Presence")
                        .frame(width: 46, height: 46)
                        .background(.black.opacity(0.6), in: Circle())
                        .overlay(Circle().stroke(hudCyan.opacity(0.55), lineWidth: 1))
                        .shadow(color: hudCyan.opacity(0.18), radius: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return to Presence")
                .help("Return to Presence · active voice state")
            }
            if let remaining = model.codex.limits?.limits.bucket?.primary?.usedPercent, remaining.isFinite {
                Text("\(Int(max(0, min(100, 100 - remaining))))%")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(hudDim)
                    .help("Primary Codex allowance remaining. Full account details are in Controls & history.")
            }
            Text(model.now.formatted(date: .omitted, time: .shortened)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            Button { model.noteInteraction(); controls.toggle() } label: {
                Image(systemName: controls ? "xmark" : "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(hudDim).padding(8)
            }.buttonStyle(.plain).help(controls ? "Close controls & history" : "Controls & history")
        }
    }

    func requestSpaceChange(to space: String) {
        model.noteInteraction()
        controls = false
        model.spaceMode = space
    }
    @ViewBuilder private func workspaceView(for space: String) -> some View {
        if space == "Agents" {
            AgentOffice(model: model)
        } else if space == "Phone" {
            if let sync = model.pocketSync {
                PhoneSyncWorkspace(model: model, sync: sync)
            } else {
                Text(model.pocketSyncUnavailable.isEmpty ? "Phone sync is unavailable." : model.pocketSyncUnavailable)
                    .foregroundStyle(.orange).padding(24)
            }
        } else if space == "Calendar" || space == "Tasks" {
            PlanningWorkspace(model: model, space: space)
        } else {
            OrbWorkspace(model: model, space: space)
        }
    }
    private func changeSpace(to newSpace: String) {
        guard newSpace != presentedSpace || transitioningSpace else { return }
        transitionToken &+= 1
        let token = transitionToken
        let planningSpaces: Set<String> = ["Calendar", "Tasks", "Phone"]
        let sourceIsPlanning = planningSpaces.contains(presentedSpace)
        let destinationIsPlanning = planningSpaces.contains(newSpace)
        guard newSpace != presentedSpace, (sourceIsPlanning || destinationIsPlanning), !reduceMotion else {
            transitioningSpace = false
            presentedSpace = newSpace
            transitionProgress = 0
            return
        }
        transitionTargetSpace = newSpace
        transitionArrivingAtPlanning = destinationIsPlanning
        transitionDestination = newSpace == "Tasks" || (sourceIsPlanning && presentedSpace == "Tasks") ? .tasks : .calendar
        transitionVariant = sourceIsPlanning ? newSpace : presentedSpace
        transitionProgress = destinationIsPlanning ? 0 : 1
        transitioningSpace = true
        let endProgress = destinationIsPlanning ? 1.0 : 0.0
        DispatchQueue.main.async {
            guard token == transitionToken else { return }
            withAnimation(.easeInOut(duration: 0.68)) { transitionProgress = endProgress }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
            guard token == transitionToken else { return }
            presentedSpace = newSpace
            transitioningSpace = false
            transitionProgress = 0
        }
    }
    var personalWorkspacePanel: some View {
        HUDPanel(title: "HOME / HARNESS / BRAIN / CONTEXT / SKILLS") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("HOME · Your Mac     HARNESS · Native Chef     BRAIN · Apple local AI").font(.system(size: 11, design: .monospaced)).foregroundStyle(hudCyan)
                    Text("Chef Home stores context, jobs, and drafts locally. Open a saved job here to continue its available workflow or prepare a handoff.").font(.caption).foregroundStyle(hudDim)
                    HStack { Button("Open Chef Home") { model.openPersonalHome() }; Text(model.homePath).font(.caption).textSelection(.enabled) }
                    Text("ABOUT ME").font(.caption).foregroundStyle(hudCyan)
                    TextEditor(text: $model.personalContext.about).frame(height: 65).scrollContentBackground(.hidden).background(hudCyan.opacity(0.05))
                    Text("PREFERENCES").font(.caption).foregroundStyle(hudCyan)
                    TextEditor(text: $model.personalContext.preferences).frame(height: 65).scrollContentBackground(.hidden).background(hudCyan.opacity(0.05))
                    Text("CURRENT GOALS").font(.caption).foregroundStyle(hudCyan)
                    TextEditor(text: $model.personalContext.goals).frame(height: 65).scrollContentBackground(.hidden).background(hudCyan.opacity(0.05))
                    HStack { Button("Save context") { model.savePersonalContext() }; Text("Context is local. Keep credentials out. Up to 600 characters from each field inform replies.").font(.caption).foregroundStyle(hudDim) }
                    Divider()
                    Text("GIVE CHEF A JOB").foregroundStyle(hudCyan).font(.caption)
                    TextField("Job title", text: $model.jobTitle)
                    TextField("Details, constraints and desired output", text: $model.jobDetails)
                    HStack {
                        Picker("Skill", selection: $model.jobSkill) { ForEach(JobSkill.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 340)
                        Button("Save job") { model.addPersonalJob() }
                    }
                    if model.jobSkill.isECC {
                        Text("ECC workflows: plan, implement, review and verify. Include the repository path and acceptance criteria. Draft locally creates a proposal; Prepare Codex handoff creates a prompt for a coding session with access to your repository.").font(.caption).foregroundStyle(hudCyan)
                    }
                    Text(model.workspaceStatus).font(.caption).foregroundStyle(hudDim).textSelection(.enabled)
                    ForEach(model.personalJobs) { job in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(job.title + " · " + job.status).font(.headline)
                            Text(job.skill.title + " — " + job.details).font(.caption).lineLimit(3)
                            Text(job.message).font(.caption).foregroundStyle(hudDim)
                            HStack {
                                if job.skill != .todo && job.skill != .emailWorkflow {
                                    Button("Draft locally") { model.draftPersonalJob(job) }.disabled(model.thinking || model.draftingJob)
                                    Button("Open output") { model.openPersonalDraft(job) }.disabled(job.status != "Drafted")
                                    Button(job.skill.isECC ? "Prepare Codex handoff" : "Prepare ChatGPT handoff") { model.prepareChatGPTHandoff(job) }
                                }
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(hudCyan.opacity(0.045))
                    }
                    Text("Just say ‘remember that …’, ‘my goal is …’, ‘plan my day’ or ‘draft an email …’. Chef saves context or selects a job template and starts its local draft automatically. Memory and projects folders are not automatically imported.").font(.caption).foregroundStyle(hudDim)
                }
            }
        }
    }
    var corePanel: some View {
        HUDPanel(title: "VOICE CORE") {
            NeuralSpace(model: model, link: model.codex)
        }
    }
    var conversationPanel: some View {
        LinkedConversation(engine: model.orchestration, model: model, link: model.codex)
    }
    var localConversationPanel: some View {
        HUDPanel(title: "COMMUNICATION CHANNEL") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        if model.conversation.isEmpty {
                            Text("At your service.").font(.system(size: 27, weight: .light)).foregroundStyle(.white)
                            Text("Speak a request, start a timer, or open your everyday apps. Your assistant never makes payments.").font(.callout).foregroundStyle(hudDim)
                            Text("TRY: ‘HEY CHEF, SET A TIMER FOR FIVE MINUTES’").font(.system(size: 10, design: .monospaced)).foregroundStyle(hudCyan).padding(.top, 12)
                        }
                        ForEach(model.conversation) { line in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(line.role).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(line.role == "CHEF" ? hudCyan : hudDim)
                                Text(line.text).font(.system(size: 14)).foregroundStyle(line.role == "CHEF" ? .white : hudDim).textSelection(.enabled)
                            }.id(line.id)
                        }
                        if model.thinking { Text("Processing locally…").foregroundStyle(hudCyan).font(.callout) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: model.conversation.count) { _, _ in if let id = model.conversation.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Text(model.aiStatus).font(.system(size: 9, design: .monospaced)).foregroundStyle(hudDim)
            Text(model.routeSummary).font(.system(size: 9, design: .monospaced)).foregroundStyle(hudCyan.opacity(0.75)).lineLimit(2)
        }
    }
    var commandPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right").foregroundStyle(hudCyan)
                TextField("Ask Chef…", text: $model.command).textFieldStyle(.plain).font(.system(size: 15)).onSubmit { model.submit() }
                Button("Send") { model.stopSpeech(); model.submit() }.disabled(model.thinking)
                Button { model.toggleTalk() } label: { Label(model.isListening ? "Stop mic" : "Talk", systemImage: model.isListening ? "stop.circle" : "mic.fill") }.keyboardShortcut("m", modifiers: .command)
            }.padding(14).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 1))
            HStack {
                if model.isListening && !model.isSpeaking { Button("Done speaking") { model.finishVoiceRequest() } }
                if model.isSpeaking { Button("Interrupt") { model.interruptToListen() } }
                if actionableVoiceMessage { Text(model.voiceStatus).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1) }
                if controls && !model.captureDiagnostic.isEmpty { Text(model.captureDiagnostic).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1) }
                Spacer(minLength: 0)
            }
        }
    }
    var actionableVoiceMessage: Bool {
        let status = model.voiceStatus.lowercased()
        return ["off", "unavailable", "couldn't", "failed", "retrying", "error", "no working"].contains { status.contains($0) }
    }
    var timersPanel: some View {
        HUDPanel(title: "TEMPORAL CONTROL") {
            HStack {
                ForEach([5, 10, 25, 60], id: \.self) { minutes in Button("\(minutes) MIN") { model.addTimer(seconds: Double(minutes * 60), name: minutes == 25 ? "Focus" : "Timer") }.font(.system(size: 11, design: .monospaced)) }
                Spacer()
                Text("MULTIPLE TIMERS • PAUSE • RESUME").font(.system(size: 9, design: .monospaced)).foregroundStyle(hudDim)
            }
            ScrollView {
                VStack(spacing: 8) {
                    if model.timers.isEmpty {
                        HStack {
                            Image(systemName: "timer").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(hudCyan.opacity(0.6))
                            VStack(alignment: .leading, spacing: 7) { Text("No active timers.").foregroundStyle(.white); Text("Try ‘timer 10 minutes called Laundry’ or use a preset above.").font(.callout).foregroundStyle(hudDim) }
                            Spacer()
                        }.padding(.vertical, 28)
                    }
                    ForEach(model.timers) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.headline); Text(item.finished ? "COMPLETE" : item.pausedSeconds == nil ? "RUNNING" : "PAUSED").font(.system(size: 9, design: .monospaced)).foregroundStyle(hudDim) }
                            Spacer()
                            Text(item.finished ? "DONE" : formatTime(item.remaining(at: model.now))).font(.system(size: 27, weight: .light, design: .monospaced)).foregroundStyle(hudCyan)
                            if !item.finished { Button(item.pausedSeconds == nil ? "Pause" : "Resume") { model.toggle(item.id) } }
                            Button(item.finished ? "Dismiss" : "Cancel") { model.remove(item.id) }
                        }.padding(12).background(hudCyan.opacity(0.045)).overlay(Rectangle().stroke(hudCyan.opacity(0.15)))
                    }
                }
            }
        }
    }
    var appsPanel: some View {
        HUDPanel(title: "APPLICATION GATEWAY") {
            HStack {
                ForEach(webServices) { service in Button { model.openService(service) } label: { Label(service.name, systemImage: service.symbol) } }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(model.calendarConnected ? "Calendar connected" : "Connect Calendar") { model.connectCalendar() }.disabled(model.calendarConnected)
                    Button(model.remindersConnected ? "Reminders connected" : "Connect Reminders") { model.connectReminders() }.disabled(model.remindersConnected)
                }
                Text("Read your agenda and create reminders with macOS permission. Google events must be synced into Mac Calendar. Gmail, YouTube and YouTube Music currently open in your browser; account actions need separate connections.")
                if !model.connectionStatus.isEmpty { Text(model.connectionStatus).foregroundStyle(hudCyan) }
            }.font(.caption)
            Text("Try: ‘what’s on my calendar tomorrow?’ or ‘remind me to stretch tomorrow at 9 AM’.").font(.caption).foregroundStyle(hudDim)
            TextField("Find an approved Mac app", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(model.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { app in
                        Button { model.openApp(app) } label: { HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 20, height: 20); Text(app.name).lineLimit(1); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }.padding(6) }
                    }
                }
            }
        }
    }
    var voicePanel: some View {
        HUDPanel(title: "VOICE / SAFETY PROTOCOL") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Check voice diagnostics") { model.refreshVoiceDiagnostics() }
                    if !model.voiceDiagnostics.isEmpty { Text(model.voiceDiagnostics).font(.caption).textSelection(.enabled) }
                    Stepper("Pause before sending: \(Int(model.voicePauseSeconds)) seconds", value: Binding(get: { model.voicePauseSeconds }, set: { model.setVoicePause($0) }), in: 2...15, step: 1)
                    Text("You can pause for this long mid-request. Say ‘okay’, ‘stop’, or ‘Chef’ to interrupt playback, then continue your request. Done speaking sends immediately.").font(.caption)
                    HStack { Button("Test spoken reply") { model.testVoice() }; Button("Stop speaking") { model.stopSpeech() }; Button("Refresh local AI") { model.configureAI() } }
                    HStack {
                        Text("Voice")
                        Picker("Voice", selection: Binding(get: { model.selectedVoiceID }, set: { model.setVoice($0) })) {
                            Text("Best installed English voice").tag("")
                            ForEach(model.availableVoices, id: \.identifier) { voice in Text(voice.name + " · " + voice.language + (voice.quality.rawValue > 1 ? " · Enhanced/Premium" : "")).tag(voice.identifier) }
                        }.labelsHidden().frame(maxWidth: 330)
                    }
                    Divider()
                    Text("FISH AUDIO · FREE MODEL ONLY").font(.caption).foregroundStyle(hudCyan)
                    Text("Fish voices public replies across every space. Fish receives spoken reply text and may retain requests for model improvement. Private replies stay on screen. Errors or free-window expiry show a notice without switching voices. Free support expires November 30, 2026.").font(.caption)
                    SecureField("Free Fish API key · saved in macOS Keychain", text: $model.fishKeyDraft).textFieldStyle(.roundedBorder)
                    TextField("Fish voice model ID · 32-character ID from its voice URL", text: $model.fishVoiceID).textFieldStyle(.roundedBorder)
                    Toggle("Allow conversation reply text to be sent to Fish Audio", isOn: Binding(get: { model.fishConsent }, set: { model.setFishConsent($0) }))
                    Toggle("Allow calendar and to-do reply text to be spoken by Fish", isOn: Binding(get: { model.fishPlanningConsent }, set: { model.setFishPlanningConsent($0) }))
                    Toggle("Allow phone-chat reply text to be sent to Fish Audio for speech", isOn: Binding(get: { model.fishPhoneReplyConsent }, set: { model.setFishPhoneReplyConsent($0) }))
                    Toggle("Allow requested phone briefing text, including saved to-dos, to be sent to Fish Audio", isOn: Binding(get: { model.fishPhoneBriefingConsent }, set: { model.setFishPhoneBriefingConsent($0) }))
                    Text("Only reply text you explicitly allow is shared; Fish may retain it for model improvement. Requested phone briefings can include saved to-dos. Desktop screens, credentials, and personal profile/history stay local. Separate toggles control phone chat and briefing text.").font(.caption)
                    HStack {
                        Button("Open free key setup") { model.openFishSetup() }
                        Button("Save & enable free voice") { model.saveFishVoice() }
                        Button("Test Fish voice") { model.testFishVoice() }.disabled(!model.fishEnabled)
                        Button("Use local voice") { model.disableFishVoice() }
                    }
                    Text(model.fishStatus).font(.caption).foregroundStyle(hudDim)
                    Divider()
                    HStack {
                        Text("Wake response")
                        TextField("Automatic time-aware greeting", text: Binding(get: { model.acknowledgment }, set: { model.setAcknowledgment($0) })).textFieldStyle(.roundedBorder)
                    }
                    Text("Talk: click Talk or press ⌘M and speak. Hands-free: enable Hey Chef, say ‘Hey Chef’, and pause. Chef greets you, then stays in conversation for three minutes after every exchange without another wake phrase. After three minutes of silence, say Hey Chef again. Say ‘go to sleep’ to end a conversation or ‘stop listening’ to turn off the mic. An empty Wake response uses a time-aware greeting. You can also give a command with the wake phrase in one utterance.")
                    Text("Voice requires macOS microphone and speech recognition permission. English recognition stays on this Mac; if local speech assets aren't available, recognition stops rather than uploading audio. The microphone runs only after you enable it.")
                    Text("Payments and purchases remain unavailable. Desktop assistance requires its visible macOS connection and can be stopped at any time. Email is sent only after you review and approve the specific message.").foregroundStyle(hudCyan)
                    Text("Try: ‘what time is it’, ‘open Gmail’, ‘set a timer for five minutes’, ‘pause my timer’, or ‘help me plan my morning’. Free local AI conversation requires an available Apple Intelligence model.")
                    Text("Timers alert while this app is running and your Mac is awake. Closing the window keeps it in the menu bar; quitting stops alerts until you reopen it.").foregroundStyle(hudDim)
                }.font(.callout).textSelection(.enabled)
            }
        }
    }
    var systemPanel: some View {
        HUDPanel(title: "SUPERVISOR / SPECIALISTS / COMPLETION CHECK") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("One request. A clear plan. Verified results. Running build " + model.runningBuild + ".").font(.headline)
                    Text("Local AI understands natural requests and follow-ups, then proposes a bounded plan. Specialists handle timers, calendars, reminders, app opening and Google search. Calendar and Reminders require macOS permission. Gmail account access is not connected yet.").font(.caption).foregroundStyle(hudDim)
                    if model.taskProgress.isEmpty {
                        Text("Try: ‘set a timer for five minutes and then open Gmail’. The supervisor routes each step, and the completion checker reports any unfinished work.").font(.callout).foregroundStyle(hudCyan)
                    }
                    ForEach(model.taskProgress) { task in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) { Text(task.specialist.rawValue.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(hudCyan); Text(task.request).font(.caption).foregroundStyle(hudDim) }
                            Spacer()
                            Text(task.status).font(.system(size: 10, design: .monospaced)).foregroundStyle(task.status == "Complete" ? hudCyan : .white)
                        }.padding(10).background(hudCyan.opacity(0.04))
                    }
                    Button("Check Codex allowance") { model.command = "How much Codex usage do I have left?"; model.submit() }.disabled(model.thinking)
                    Text(model.usageText).font(.caption).foregroundStyle(hudDim)
                    Text("Up to six sequential tasks. Successful actions are never retried automatically. Safety is checked before planning and again before each action. AI conversation cannot invoke tools.").font(.caption).foregroundStyle(hudDim)
                }
            }
        }
    }
    var updatesPanel: some View {
        HUDPanel(title: "VOICE → CODEX → TESTED APP UPDATE") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.bridgeDescription).font(.caption).foregroundStyle(hudDim)
                HStack {
                    TextField("Describe a feature or fix for Chef", text: $model.updateDraft).textFieldStyle(.roundedBorder)
                    Button("Send request") { model.sendUpdateDraft() }.disabled(model.thinking)
                    Button("Apply update") { model.restartForUpdate() }.disabled(!model.updateRows.contains { $0.status == "ready" })
                }
                Toggle("Automatically apply tested updates when idle", isOn: Binding(get: { model.automaticallyApplyUpdates }, set: { model.setAutomaticallyApplyUpdates($0) })).font(.caption)
                Text("Tell Chef what to improve, such as ‘I want the voice to sound more human’ or ‘I want Chef to listen while talking’. It saves the request here for Codex to implement and test. Tested builds apply after a short idle pause, with timers and microphone mode restored. Code maintenance uses your existing Codex usage.").font(.caption).foregroundStyle(hudDim)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.updateRows.isEmpty { Text("No requests yet. Try: ‘feature request: give me a quieter timer alert’.").font(.callout).foregroundStyle(hudCyan) }
                        ForEach(model.updateRows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(row.status.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(hudCyan); Spacer() }
                                Text(row.request).font(.callout)
                                Text(row.message).font(.caption).foregroundStyle(hudDim)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(hudCyan.opacity(0.04))
                        }
                    }
                }
            }
        }
    }
}

struct LinkedConversation: View {
    @ObservedObject var engine: AIEngine
    @ObservedObject var model: ChefModel
    @ObservedObject var link: CodexLink
    var body: some View {
        HUDPanel(title: "COMMUNICATION CHANNEL") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !link.history.isEmpty && model.conversation.isEmpty {
                            ForEach(Array(link.history.enumerated()), id: \.offset) { _, line in
                                Text(line.0).font(.caption2).foregroundStyle(hudCyan)
                                Text(line.1).textSelection(.enabled)
                            }
                        }
                        if model.conversation.isEmpty && link.history.isEmpty {
                            Text("At your service.").font(.system(size: 27, weight: .light))
                            Text("Connect your Codex account, then type or speak. Explore folders, chats and projects with the arrows on my left.").foregroundStyle(hudDim)
                        }
                        ForEach(model.conversation) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.role).font(.system(size: 9, design: .monospaced)).foregroundStyle(hudCyan)
                                Text(line.text).font(.system(size: 14)).textSelection(.enabled)
                            }
                        }
                        if model.thinking {
                            Text(model.adaptiveRouting ? (engine.streamedText.isEmpty ? "Working…" : engine.streamedText) : (link.stream.isEmpty ? "Working…" : link.stream)).foregroundStyle(hudCyan).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: engine.streamedText) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                 .onChange(of: link.stream) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                 .onChange(of: model.conversation.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                 .onChange(of: link.history.count) { _, _ in if !model.thinking { model.conversation = link.history.map { ConversationLine(role: $0.0, text: $0.1) } } }
                 .onChange(of: link.selected?.id) { _, _ in if !model.thinking { model.conversation = [] } }
            }
            Text(model.adaptiveRouting ? "Adaptive local / Codex · verified drafts · ECC updates" : model.useCodex ? "Codex replies · local actions · ECC update queue" : model.aiStatus).font(.system(size: 9, design: .monospaced)).foregroundStyle(hudDim)
            Text(model.routeSummary).font(.system(size: 9, design: .monospaced)).foregroundStyle(hudCyan).lineLimit(1)
        }
    }
}
