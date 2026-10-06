import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct DesktopDashboard: View {
    @ObservedObject var controller: DesktopControlController
    @ObservedObject var agent: DesktopAgent
    @State private var target = ""
    @State private var objective = ""
    @State private var preview: NSImage?
    @State private var targets: [DesktopControlTarget] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("COMPUTER · LOCAL ASSISTANCE").font(.headline)
                    Spacer()
                    Button("Stop now", role: .destructive) { agent.cancel(); controller.stop() }
                }
                Text("Chef inspects accessible controls and your screen locally. Choose the app to work in. Review the exact email before sending.").font(.caption)
                HStack {
                    Button(controller.accessibilityTrusted ? "Accessibility connected" : "Connect Accessibility") { controller.requestAccessibilityAccess() }
                    Button(controller.screenCaptureAllowed ? "Screen connected" : "Connect screen") { controller.requestScreenCaptureAccess() }
                    Button("Refresh access") { controller.refreshPermissions(); targets = controller.availableTargets() }
                }
                Text(controller.status).font(.caption).textSelection(.enabled)
                HStack {
                    Picker("App", selection: $target) {
                        Text("Choose a running app").tag("")
                        ForEach(targets) { Text($0.appName).tag($0.bundleIdentifier) }
                    }.frame(maxWidth: 320)
                    Button("Inspect screen") {
                        Task { @MainActor in
                            controller.resume()
                            guard await controller.selectTarget(bundleIdentifier: target).succeeded,
                                  !Task.isCancelled, !controller.isStopped else { return }
                            preview = await controller.snapshot()?.screenImage
                        }
                    }.disabled(target.isEmpty || agent.isRunning)
                }
                HStack {
                    TextField("For example: compose an email to … about …", text: $objective)
                    Button("Do task") {
                        Task { @MainActor in
                            controller.resume()
                            guard await controller.selectTarget(bundleIdentifier: target).succeeded,
                                  !Task.isCancelled, !controller.isStopped else { return }
                            _ = await agent.run(objective: objective)
                        }
                    }.disabled(target.isEmpty || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.isRunning)
                }
                Text(agent.status).font(.caption).textSelection(.enabled)
                if let approval = agent.pendingApproval {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REVIEW EMAIL").font(.headline)
                        Text("To: " + approval.recipient).textSelection(.enabled)
                        Text("Subject: " + approval.subject).textSelection(.enabled)
                        Text(approval.body).textSelection(.enabled)
                        HStack {
                            Button("Send this exact email") { agent.approvePendingEmail() }
                            Button("Don't send") { agent.rejectPendingEmail() }
                        }
                    }.padding(12).background(Color.cyan.opacity(0.1))
                }
                if let preview { Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 240) }
            }.padding(12)
        }.onAppear { controller.refreshPermissions(); targets = controller.availableTargets() }
    }
}
