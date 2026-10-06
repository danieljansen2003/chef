import FoundationModels
import AppKit
import SwiftUI
import Foundation
import AVFoundation

struct TimerItem: Identifiable, Codable {
    var id = UUID()
    var name: String
    var deadline: Date
    var pausedSeconds: Double? = nil
    var finished = false
    func remaining(at now: Date) -> Double { pausedSeconds ?? max(0, deadline.timeIntervalSince(now)) }
}

enum TimerParser {
    static func parse(_ text: String) -> (seconds: Double, name: String)? {
        let labelRange = text.range(of: " called ", options: .caseInsensitive)
        let durationText = labelRange.map { String(text[..<$0.lowerBound]) } ?? text
        guard durationText.range(of: #"-\s*\d"#, options: .regularExpression) == nil else { return nil }
        let pattern = #"(?<![\d.])(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let ns = durationText as NSString
        let matches = regex.matches(in: durationText, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var seconds: Double = 0
        for match in matches {
            let amount = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let unit = ns.substring(with: match.range(at: 2)).lowercased()
            seconds += amount * (unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1)
        }
        guard seconds > 0, seconds <= 604800 else { return nil }
        var name = "Timer"
        if let range = labelRange {
            let value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { name = value }
        }
        return (seconds, name)
    }
}

struct InstalledApp: Identifiable {
    var url: URL
    var name: String
    var id: String { url.path }
}

struct WebService: Identifiable {
    let name: String
    let symbol: String
    let address: String
    var id: String { name }
}

let webServices = [
    WebService(name: "Gmail", symbol: "envelope", address: "https://mail.google.com/"),
    WebService(name: "Calendar", symbol: "calendar", address: "https://calendar.google.com/"),
    WebService(name: "YouTube Music", symbol: "music.note", address: "https://music.youtube.com/"),
    WebService(name: "YouTube", symbol: "play.rectangle", address: "https://www.youtube.com/"),
    WebService(name: "Google", symbol: "magnifyingglass", address: "https://www.google.com/")
]

func formatTime(_ seconds: Double) -> String {
    let value = Int(ceil(max(0, seconds)))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
}

@available(macOS 26.0, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var model: ChefModel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = ChefModel()
        model.showWindow = { [weak self] in self?.show() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Chef"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChefView(model: model))
        window.center()
        let mainMenu = NSMenu()
        let root = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Chef", action: #selector(show), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Chef", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu
        mainMenu.addItem(root)
        let editRoot = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editRoot.submenu = edit
        mainMenu.addItem(editRoot)
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Chef")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Chef", action: #selector(show), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Chef", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
        show()
    }
    @objc func show() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.save() }
}

@available(macOS 26.0, *)
@main enum ChefMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--briefing-sources-test") {
            Task {
                do { print(try await LiveInformation.answer(LiveQuery(kind: .weather, query: "Columbia, Illinois"))); print(try await LiveInformation.answer(LiveQuery(kind: .news, query: "business"))); exit(0) }
                catch { fputs("Public briefing source check failed: \(error)\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--register-daily-briefing") {
            do { let store = AgentWorkflowStore(); try store.prepare(); _ = try store.scheduleBriefing(hour: 11, minute: 45, location: "Columbia, Illinois"); print("Daily 11:45 AM briefing registered for Columbia, Illinois.") }
            catch { fputs("Briefing registration failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--prepare-home") {
            do { let home = PersonalWorkspace(); try home.prepare(); print("Personal workspace prepared: " + home.root.path) }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--usage-self-test") || Bundle.main.object(forInfoDictionaryKey: ChefCompatibility.key("ChefUsageTest")) as? Bool == true {
            Task { @MainActor in
                var success = false
                var message = ""
                do {
                    let snapshot = try await CodexAllowance.fetch()
                    message = snapshot.spoken(); success = true
                    if let root = Bundle.main.object(forInfoDictionaryKey: ChefCompatibility.key("ChefWorkspacePath")) as? String {
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                        try? encoder.encode(snapshot).write(to: URL(fileURLWithPath: root + ChefCompatibility.path("/work/chef-updates/usage.json")), options: .atomic)
                    }
                } catch { message = error.localizedDescription }
                print(message)
                if let root = Bundle.main.object(forInfoDictionaryKey: ChefCompatibility.key("ChefWorkspacePath")) as? String,
                   Bundle.main.object(forInfoDictionaryKey: ChefCompatibility.key("ChefUsageTest")) as? Bool == true {
                    let data = try? JSONSerialization.data(withJSONObject: ["success": success, "message": message])
                    try? data?.write(to: URL(fileURLWithPath: root + "/work/usage-test-result.json"), options: .atomic)
                }
                exit(success ? 0 : 1)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--ai-self-test") || Bundle.main.object(forInfoDictionaryKey: ChefCompatibility.key("ChefPlannerTest")) as? Bool == true {
            func report(_ success: Bool, _ text: String) {
                print(text)
                if let path = Bundle.main.object(forInfoDictionaryKey: ChefCompatibility.key("ChefPlannerTestResult")) as? String,
                   path == (Bundle.main.object(forInfoDictionaryKey: ChefCompatibility.key("ChefWorkspacePath")) as? String ?? "") + "/work/ai-test-result.json" {
                    let data = try? JSONSerialization.data(withJSONObject: ["success": success, "message": text])
                    try? data?.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
            Task { @MainActor in
                guard case .available = SystemLanguageModel.default.availability else {
                    report(false, "LOCAL_AI_UNAVAILABLE: \(SystemLanguageModel.default.availability)")
                    exit(2)
                }
                var diagnostic = ""
                do {
                    let requests = ["Remind me to stretch tomorrow at 9 AM", "What's on my calendar tomorrow?", "Help me draft a friendly email to a colleague", "Please start a ten-minute timer for tea"]
                    for request in requests {
                        let plan = try await SemanticPlanner.plan(request, context: "", inspect: { diagnostic += request + " -> " + String(describing: $0) + "\n" })
                        print("INTENT: \(request) -> \(plan.map { String(describing: $0.action) })")
                        switch request {
                        case requests[0]: guard plan.count == 1, case .reminder = plan[0].action else { throw SemanticPlanner.PlanError.invalid }
                        case requests[1]: guard plan.count == 1, case .agenda(1) = plan[0].action else { throw SemanticPlanner.PlanError.invalid }
                        case requests[2]: guard plan.count == 1, case .chat = plan[0].action else { throw SemanticPlanner.PlanError.invalid }
                        default: guard plan.count == 1, case .startTimer(let seconds, _) = plan[0].action, seconds == 600 else { throw SemanticPlanner.PlanError.invalid }
                        }
                    }
                    report(true, "Live local AI planning passed for reminders, agenda, email drafting and timers. No actions executed or account data accessed.")
                    exit(0)
                } catch { report(false, "LOCAL_AI_TEST_FAILED: \(error)\n" + diagnostic); exit(1) }
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--public-info-test") {
            Task { @MainActor in
                var success = true
                for query in [LiveQuery(kind: .weather, query: "Chicago, Illinois"), LiveQuery(kind: .news, query: ""), LiveQuery(kind: .reference, query: "Moon")] {
                    do { print("PUBLIC_SOURCE_OK: " + String(try await LiveInformation.answer(query).prefix(1400))) }
                    catch { success = false; print("PUBLIC_SOURCE_FAILED: " + error.localizedDescription) }
                }
                exit(success ? 0 : 1)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--orchestration-self-test") {
            Task { @MainActor in
                do { _ = try await OrchestrationTests.run(); print(try await OrchestrationTests.benchmark()); exit(0) }
                catch { print("Orchestration checks failed: \(error.localizedDescription)"); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--self-test") {
            precondition(TimerParser.parse("timer 1 hour 15 minutes called Dinner")?.seconds == 4500)
            precondition(TimerParser.parse("timer 1 hour 15 minutes called Dinner")?.name == "Dinner")
            precondition(TimerParser.parse("30 seconds")?.seconds == 30)
            precondition(TimerParser.parse("1.5 mins")?.seconds == 90)
            precondition(TimerParser.parse("0 seconds") == nil)
            precondition(TimerParser.parse("200 hours") == nil)
            precondition(TimerParser.parse("open Safari") == nil)
            precondition(TimerParser.parse("timer -5 minutes") == nil)
            precondition(TimerParser.parse("timer 5 minutes called 10 minute workout")?.seconds == 300)
            precondition(formatTime(65) == "01:05")
            precondition(formatTime(3661) == "1:01:01")
            let item = TimerItem(name: "Test", deadline: Date(timeIntervalSince1970: 100))
            precondition(item.remaining(at: Date(timeIntervalSince1970: 90)) == 10)
            precondition(item.remaining(at: Date(timeIntervalSince1970: 110)) == 0)
            var paused = item
            paused.pausedSeconds = 8
            precondition(paused.remaining(at: Date(timeIntervalSince1970: 110)) == 8)
            let encoded = try! JSONEncoder().encode(paused)
            precondition(try! JSONDecoder().decode(TimerItem.self, from: encoded).pausedSeconds == 8)
            for text in ["pay my rent", "buy a phone", "send money", "subscribe to YouTube", "transfer 10 dollars", "checkout", "open PayPal"] { precondition(Safety.blocked(text)) }
            for text in ["timer 5 minutes", "open Gmail", "what time is it"] { precondition(!Safety.blocked(text)) }
            precondition(!Safety.apps.contains("com.apple.Terminal"))
            precondition(!Safety.apps.contains("com.apple.shortcuts"))
            precondition(!Safety.allowsURL(URL(string: "https://paypal.com/")!))
            precondition(!Safety.allowsURL(URL(string: "https://www.google.com/pay")!))
            precondition(Safety.allowsURL(URL(string: "https://www.google.com/search?q=hello")!))
            precondition(TimerParser.parse(Safety.normalize("Hey Chef, set a timer for five minutes"))?.seconds == 300)
            print("31 timer, voice-command normalization, payment-blocking, and action-boundary checks passed.")
            CodexLink.test()
            WorkspaceMap.test()
            OrbGeometry.test()
            precondition(PresenceDissolveOverlay.test(), "Particle layout must remain finite and bounded")
            HolographicPortrait.test()
            let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ChefWorkflowTest-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: testRoot) }
            do { try AgentWorkflowStore.test(at: testRoot) } catch { preconditionFailure("Workflow test: \(error)") }
            ChefCompatibility.test()
            VoiceInteraction.test()
            LiveInformation.test()
            AgentIdentity.test()
            DesktopControlController.selfTest()
            DesktopAgent.test()
            WorkflowTests.run()
            PersonalAssistantTests.run()
            CodexAllowance.test()
            FishFreeVoice.test()
            SpeechTurn.test()
            PersonalWorkspace.test()
            do {
                try PocketSyncTests.run()
                try AgentOfficeBoardMapping.selfTest()
            } catch {
                fputs("Phone sync or Agent Office self-test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}