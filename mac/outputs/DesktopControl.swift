import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Local, finite macOS accessibility and pointer controls. Every AX target is
/// retained only from the most recent bounded observation; snapshots are data,
/// never authorization to perform a consequential action.
@MainActor
final class DesktopControlController: ObservableObject {
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var screenCaptureAllowed = CGPreflightScreenCaptureAccess()
    @Published private(set) var status = "Desktop control is disconnected."
    @Published private(set) var isStopped = false

    private struct Observation {
        let element: AXUIElement
        let frame: CGRect
        let label: String
    }

    private var observations: [String: Observation] = [:]
    private var observedApplication: NSRunningApplication?
    private var selectedApplication: NSRunningApplication?
    private var generation = UUID()
    private var taskLoop: Task<Void, Never>?
    private let maxElements = 240
    private let maxDepth = 12

    func refreshPermissions() {
        accessibilityTrusted = AXIsProcessTrusted()
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        status = accessibilityTrusted && screenCaptureAllowed
            ? "Desktop control is connected."
            : "Grant Accessibility and Screen Recording access to connect."
    }

    /// Call only from an explicit user-selected permission button.
    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
    }

    /// Call only from an explicit user-selected permission button.
    func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
    }

    /// Running apps only; selection is an explicit local UI action.
    func availableTargets() -> [DesktopControlTarget] {
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.activationPolicy == .regular &&
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                !Self.isDeniedApplication(bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName) }
            .compactMap { app in
                guard let bundle = app.bundleIdentifier else { return nil }
                return DesktopControlTarget(bundleIdentifier: bundle, appName: app.localizedName ?? bundle)
            }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    func selectTarget(bundleIdentifier: String) async -> DesktopControlActionResult {
        guard !isStopped else { status = "Desktop control is stopped."; return denied(status) }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.bundleIdentifier == bundleIdentifier &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            !Self.isDeniedApplication(bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName)
        }) else { return denied("Choose an available running app.") }
        selectedApplication = app
        observations.removeAll()
        observedApplication = nil
        guard await activateTarget(app) else {
            if isStopped { status = "Desktop control is stopped."; return denied(status) }
            if Task.isCancelled { status = "Stopped."; return denied(status) }
            status = "Could not activate \(app.localizedName ?? "the selected app"). Select it in the app switcher and try again."
            return denied(status)
        }
        guard !isStopped else { status = "Desktop control is stopped."; return denied(status) }
        guard !Task.isCancelled else { status = "Stopped."; return denied(status) }
        status = "Selected \(app.localizedName ?? "the app"). Capture a fresh screen before acting."
        return .success(status)
    }

    func snapshot() async -> DesktopControlSnapshot? {
        guard !isStopped else { status = "Desktop control is stopped."; return nil }
        refreshPermissions()
        guard accessibilityTrusted, screenCaptureAllowed else { return nil }
        if let selectedApplication, NSWorkspace.shared.frontmostApplication?.processIdentifier != selectedApplication.processIdentifier {
            guard await activateTarget(selectedApplication) else {
                if isStopped { status = "Desktop control is stopped."; return nil }
                status = "Could not activate \(selectedApplication.localizedName ?? "the selected app")."
                return nil
            }
            guard !isStopped else { status = "Desktop control is stopped."; return nil }
            guard !Task.isCancelled else { status = "Stopped."; return nil }
            try? await Task.sleep(for: .milliseconds(180))
            guard !isStopped else { status = "Desktop control is stopped."; return nil }
            guard !Task.isCancelled else { status = "Stopped."; return nil }
        }
        guard let app = selectedApplication ?? NSWorkspace.shared.frontmostApplication,
              !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Self.isDeniedApplication(bundleIdentifier: app.bundleIdentifier, name: app.localizedName),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            status = "The frontmost app is not available for desktop control."
            return nil
        }

        // Capture only the current main display through ScreenCaptureKit. Pixels
        // remain in process and are never sent to an external service here.
        var image: NSImage?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                status = "No display is available."
                return nil
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = min(max(display.width, 1), 4096)
            configuration.height = min(max(display.height, 1), 4096)
            configuration.showsCursor = true
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            status = "Screen capture failed. Check Screen Recording access."
            return nil
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var found: [DesktopControlElement] = []
        var refs: [String: Observation] = [:]
        var sensitive = false
        var remainingValueBudget = 12_000
        var remainingNodes = 1_000
        Self.walk(root, depth: 0, cap: maxElements, maxDepth: maxDepth,
                  elements: &found, references: &refs, sensitive: &sensitive,
                  remainingValueBudget: &remainingValueBudget, remainingNodes: &remainingNodes)
        guard !sensitive else {
            observations.removeAll()
            observedApplication = nil
            status = "This screen appears to contain authentication, payment, or credential fields. Desktop actions are paused."
            return DesktopControlSnapshot(
                observationID: UUID().uuidString, appName: app.localizedName ?? "App",
                bundleIdentifier: app.bundleIdentifier ?? "", elements: [], screenImage: nil,
                blockedReason: "Sensitive form detected; actions are disabled."
            )
        }
        observations = refs
        observedApplication = app
        generation = UUID()
        status = "Observed \(app.localizedName ?? "the frontmost app") with \(found.count) accessible controls."
        return DesktopControlSnapshot(observationID: generation.uuidString,
                                      appName: app.localizedName ?? "App",
                                      bundleIdentifier: app.bundleIdentifier ?? "",
                                      elements: found, screenImage: image, blockedReason: nil)
    }

    func focusObservedApp() async -> DesktopControlActionResult {
        guard !isStopped, accessibilityTrusted, screenCaptureAllowed,
              let app = selectedApplication ?? observedApplication, app.isTerminated == false else { return denied("No current selected app.") }
        guard await activateTarget(app) else {
            if isStopped { status = "Desktop control is stopped."; return denied(status) }
            status = "Could not activate \(app.localizedName ?? "the observed app")."
            return denied(status)
        }
        guard !isStopped else { status = "Desktop control is stopped."; return denied(status) }
        guard !Task.isCancelled else { status = "Stopped."; return denied(status) }
        status = "Focused \(app.localizedName ?? "the app")."
        return .success(status)
    }

    /// Use macOS 14+ cooperative activation. The old ignoringOtherApps flag is
    /// deprecated and has no effect on current macOS releases.
    private func activateTarget(_ app: NSRunningApplication) async -> Bool {
        guard !Task.isCancelled, !isStopped else { return false }
        let processID = app.processIdentifier
        guard let bundleIdentifier = app.bundleIdentifier else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return true
        }
        NSApplication.shared.yieldActivation(to: app)
        _ = app.activate(from: NSRunningApplication.current, options: [])
        guard !Task.isCancelled, !isStopped, !app.isTerminated,
              app.processIdentifier == processID, app.bundleIdentifier == bundleIdentifier else { return false }
        if await waitUntilFrontmost(app) { return true }
        guard !Task.isCancelled, !isStopped, !app.isTerminated,
              app.processIdentifier == processID, app.bundleIdentifier == bundleIdentifier else { return false }

        guard let bundleURL = app.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        do {
            let openedApp = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            guard !Task.isCancelled, !isStopped, !app.isTerminated,
                  app.processIdentifier == processID, app.bundleIdentifier == bundleIdentifier,
                  openedApp.processIdentifier == processID,
                  openedApp.bundleIdentifier == bundleIdentifier else { return false }
        } catch {
            return false
        }
        guard !Task.isCancelled, !isStopped else { return false }
        return await waitUntilFrontmost(app)
    }

    private func waitUntilFrontmost(_ app: NSRunningApplication) async -> Bool {
        for _ in 0..<20 {
            if Task.isCancelled || isStopped || app.isTerminated { return false }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !Task.isCancelled && !isStopped && !app.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    func movePointer(to point: CGPoint) -> DesktopControlActionResult {
        guard canAct(), Self.isSafePoint(point) else { return denied("Pointer position is outside the permitted screen bounds.") }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return denied("Could not create a pointer event.") }
        event.post(tap: .cghidEventTap)
        return .success("Moved the pointer.")
    }

    func click(at point: CGPoint) -> DesktopControlActionResult {
        guard canAct(), Self.isSafePoint(point),
              let target = observations.values.first(where: { $0.frame.contains(point) }) else {
            return denied("Click must target a currently observed control.")
        }
        guard !Self.isSendLike(target.label), !Self.isFinancialAction(target.label) else {
            return denied("A send-like action requires the planner's exact-content review and explicit approval.")
        }
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        guard let down, let up else { return denied("Could not create a click event.") }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .success("Click event posted; take a fresh observation to verify the result.")
    }

    func pressObservedElement(id: String, userApprovedSend: Bool = false) -> DesktopControlActionResult {
        guard canAct(), let observation = observations[id] else { return denied("That element is stale or was not observed.") }
        guard !Self.isFinancialAction(observation.label) else {
            return denied("Financial actions are unavailable.")
        }
        guard !Self.isSendLike(observation.label) || (userApprovedSend && Self.isSimpleEmailSend(observation.label)) else {
            return denied("A send-like action requires exact-content review and explicit user approval.")
        }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(observation.element, kAXRoleAttribute as CFString, &role) == .success,
              let roleString = role as? String,
              Self.pressableRoles.contains(roleString) else { return denied("This observed element is not an allowed control.") }
        let result = AXUIElementPerformAction(observation.element, kAXPressAction as CFString)
        return result == .success ? .success("Accessibility press accepted; take a fresh observation to verify the result.") : denied("The observed control did not accept the action.")
    }

    func typeText(_ text: String, expectedElementID: String? = nil) -> DesktopControlActionResult {
        guard canAct(), Self.isAllowedText(text), let focus = focusedObservedEditableElement(),
              !text.contains("\n") || focus.role == "AXTextArea" else {
            return denied("Typing requires a currently observed, focused, nonsecure text field and noncredential text.")
        }
        if let expectedElementID {
            guard let expected = observations[expectedElementID], CFEqual(expected.element, focus.element) else {
                return denied("The requested text field did not receive focus; nothing was typed.")
            }
        }
        let chars = Array(text.utf16)
        guard !chars.isEmpty else { return denied("Text is empty.") }
        for offset in stride(from: 0, to: chars.count, by: 20) {
            let end = min(offset + 20, chars.count)
            let chunk = Array(chars[offset..<end])
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return denied("Could not create a typing event.") }
            event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            event.post(tap: .cghidEventTap)
            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return denied("Could not finish typing.") }
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.post(tap: .cghidEventTap)
        }
        return .success("Typing events posted; take a fresh observation to verify the result.")
    }

    func scroll(deltaY: Int, at point: CGPoint) -> DesktopControlActionResult {
        guard canAct(), Self.isSafePoint(point), (-800...800).contains(deltaY), deltaY != 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(deltaY), wheel2: 0, wheel3: 0) else {
            return denied("Scroll amount or position is outside the permitted bounds.")
        }
        event.location = point
        event.post(tap: .cghidEventTap)
        return .success("Scrolled the observed screen location.")
    }

    func pressKey(_ key: DesktopControlKey) -> DesktopControlActionResult {
        guard canAct(), let (code, flags) = Self.keyCode(for: key) else { return denied("That key is not allowed.") }
        if key == .returnKey {
            guard let focused = focusedElementMetadata(),
                  focused.role == "AXTextArea",
                  !Self.isSendLike(focused.label), !Self.isFinancialAction(focused.label) else {
                return denied("Return is allowed only in a currently focused, observed text area.")
            }
        }
        if key == .commandA, focusedObservedEditableElement() == nil {
            return denied("Select an observed text field before using Command+A.")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return denied("Could not create the key event.") }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .success("Pressed \(key.rawValue).")
    }

    /// Allows an integration to bind a finite sequence to a cancellable task.
    /// The controller itself never creates a planner or executes model output.
    func runTaskLoop(_ operation: @escaping @MainActor () async -> Void) {
        stopTaskLoop()
        taskLoop = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation()
            self.taskLoop = nil
        }
    }

    func stopTaskLoop() { taskLoop?.cancel(); taskLoop = nil }

    func stop() {
        stopTaskLoop()
        isStopped = true
        observations.removeAll()
        observedApplication = nil
        selectedApplication = nil
        status = "Desktop control is stopped."
    }

    func resume() { isStopped = false; refreshPermissions() }

    private func canAct() -> Bool {
        guard !isStopped, accessibilityTrusted, screenCaptureAllowed,
              let app = observedApplication, !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        return true
    }

    private func denied(_ reason: String) -> DesktopControlActionResult { .denied(reason) }

    private struct FocusedMetadata {
        let element: AXUIElement
        let role: String
        let subrole: String
        let label: String
    }

    private func focusedElementMetadata() -> FocusedMetadata? {
        guard let app = observedApplication,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        let role = Self.stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = Self.stringAttribute(element, kAXSubroleAttribute) ?? ""
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
            .compactMap { Self.stringAttribute(element, $0) }
            .joined(separator: " ")
        return FocusedMetadata(element: element, role: role, subrole: subrole, label: label)
    }

    private func focusedObservedEditableElement() -> FocusedMetadata? {
        guard let focus = focusedElementMetadata(),
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(focus.role),
              focus.subrole != (kAXSecureTextFieldSubrole as String),
              !Self.isSensitiveContext(focus.label),
              observations.values.contains(where: { CFEqual($0.element, focus.element) }) else { return nil }
        return focus
    }

    private static let pressableRoles: Set<String> = [
        kAXButtonRole as String, kAXCheckBoxRole as String, kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String, kAXMenuButtonRole as String, kAXMenuItemRole as String,
        "AXTabButton", "AXLink"
    ]

    private static func walk(_ element: AXUIElement, depth: Int, cap: Int, maxDepth: Int,
                             elements: inout [DesktopControlElement], references: inout [String: Observation],
                             sensitive: inout Bool, remainingValueBudget: inout Int,
                             remainingNodes: inout Int) {
        guard elements.count < cap, depth <= maxDepth, remainingNodes > 0 else { return }
        remainingNodes -= 1
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        let title = stringAttribute(element, kAXTitleAttribute) ?? ""
        let description = stringAttribute(element, kAXDescriptionAttribute) ?? ""
        let help = stringAttribute(element, kAXHelpAttribute) ?? ""
        let placeholder = stringAttribute(element, kAXPlaceholderValueAttribute) ?? ""
        let context = [title, description, help, placeholder, role, subrole].joined(separator: " ")
        let editableRole = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
        if (editableRole && isSensitiveContext(context)) || subrole == (kAXSecureTextFieldSubrole as String) {
            sensitive = true
        }
        let frame = frameOf(element)
        let label = [title, description, help, placeholder].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        if !sensitive, !label.isEmpty, !frame.isNull, frame.width > 0, frame.height > 0,
           ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXTabButton", "AXLink", "AXTextField", "AXTextArea", "AXComboBox", "AXStaticText", "AXHeading"].contains(role) {
            let id = UUID().uuidString
            let editable = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
            let interactive = editable || pressableRoles.contains(role)
            if interactive { references[id] = Observation(element: element, frame: frame, label: label) }
            let secure = subrole == (kAXSecureTextFieldSubrole as String)
            let value = editable && !secure && remainingValueBudget > 0
                ? editableValue(element, limit: min(2_000, remainingValueBudget))
                : nil
            remainingValueBudget -= value?.utf8.count ?? 0
            elements.append(DesktopControlElement(id: id, role: role, label: String(label.prefix(160)), value: value, frame: frame))
        }
        guard !sensitive else { return }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children.prefix(80) {
            walk(child, depth: depth + 1, cap: cap, maxDepth: maxDepth, elements: &elements, references: &references, sensitive: &sensitive, remainingValueBudget: &remainingValueBudget, remainingNodes: &remainingNodes)
            if sensitive || elements.count >= cap || remainingNodes == 0 { break }
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String else { return nil }
        return String(string.prefix(240))
    }

    private static func editableValue(_ element: AXUIElement, limit: Int) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let text = raw as? String else { return nil }
        guard text.utf8.count <= limit else { return nil }
        return text
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect {
        var p: CFTypeRef?
        var s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return .null }
        let position = unsafeBitCast(p, to: AXValue.self)
        let size = unsafeBitCast(s, to: AXValue.self)
        var point = CGPoint.zero
        var dimension = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimension),
              dimension.width.isFinite, dimension.height.isFinite, point.x.isFinite, point.y.isFinite else { return .null }
        return CGRect(origin: point, size: dimension)
    }

    static func isSafePoint(_ point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0 else { return false }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 16 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.contains { CGDisplayBounds($0).contains(point) }
    }

    static func isAllowedText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 1_000,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }) else { return false }
        let lower = text.lowercased()
        let sensitiveTerms = ["password", "passcode", "one-time code", "verification code", "security code", "cvv", "cvc", "card number", "credit card", "routing number", "social security"]
        if sensitiveTerms.contains(where: lower.contains) { return false }
        let digits = text.filter(\.isNumber)
        if (13...19).contains(digits.count) { return false }
        return true
    }

    static func isDeniedApplication(bundleIdentifier: String?, name: String?) -> Bool {
        let value = ((bundleIdentifier ?? "") + " " + (name ?? "")).lowercased()
        return ["terminal", "iterm", "keychain", "1password", "bitwarden", "password", "authenticator", "wallet", "bank", "broker", "trading", "systempreferences"].contains(where: value.contains)
    }

    private static func isSensitiveContext(_ value: String) -> Bool {
        let lower = value.lowercased()
        let markers = ["password", "passcode", "one-time code", "verification code", "security code", "cvv", "cvc", "credit card", "card number", "payment method", "bank account", "routing number", "social security", "authentication code", "recovery code", "checkout", "place order", "buy now", "purchase", "donate", "confirm payment", "transfer money"]
        return markers.contains(where: lower.contains)
    }

    private static func isSendLike(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["send", "submit", "place order", "buy now", "purchase", "checkout", "transfer", "donate", "confirm payment"].contains(where: lower.contains)
    }

    private static func isFinancialAction(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["place order", "buy", "purchase", "checkout", "transfer", "donate", "confirm payment", "pay", "payment"].contains(where: lower.contains)
    }

    private static func isSimpleEmailSend(_ value: String) -> Bool {
        ["send", "send email", "send message", "send reply"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func keyCode(for key: DesktopControlKey) -> (CGKeyCode, CGEventFlags)? {
        switch key {
        case .returnKey: return (36, [])
        case .escape: return (53, [])
        case .tab: return (48, [])
        case .left: return (123, [])
        case .right: return (124, [])
        case .down: return (125, [])
        case .up: return (126, [])
        case .commandA: return (0, .maskCommand)
        }
    }

    static func selfTest() {
        precondition(!isAllowedText(""))
        precondition(!isAllowedText(String(repeating: "1", count: 16)))
        precondition(!isAllowedText("enter your password here"))
        precondition(isAllowedText("line one\nline two"))
        precondition(!isAllowedText("line one\tline two"))
        precondition(isAllowedText("Prepare a meeting agenda"))
        precondition(isDeniedApplication(bundleIdentifier: "com.apple.keychainaccess", name: "Keychain Access"))
        precondition(!isDeniedApplication(bundleIdentifier: "com.apple.finder", name: "Finder"))
        precondition(isFinancialAction("Buy Now"))
        precondition(!isSimpleEmailSend("Transfer"))
        precondition(isSimpleEmailSend("Send"))
        precondition(!isSafePoint(CGPoint(x: -1, y: 0)))
        precondition(!isSafePoint(CGPoint(x: CGFloat.infinity, y: 2)))
        precondition(!DesktopControlController().pressObservedElement(id: "stale-id").succeeded)
    }
}

struct DesktopControlSnapshot {
    let observationID: String
    let appName: String
    let bundleIdentifier: String
    let elements: [DesktopControlElement]
    let screenImage: NSImage?
    let blockedReason: String?
}

struct DesktopControlTarget: Identifiable {
    let bundleIdentifier: String
    let appName: String
    var id: String { bundleIdentifier }
}

struct DesktopControlElement: Identifiable {
    let id: String
    let role: String
    let label: String
    /// Local-only editable value for concrete review; secure controls are omitted.
    let value: String?
    let frame: CGRect
}

enum DesktopControlKey: String, CaseIterable {
    case returnKey = "Return"
    case escape = "Escape"
    case tab = "Tab"
    case left = "Left"
    case right = "Right"
    case down = "Down"
    case up = "Up"
    case commandA = "Command+A"
}

enum DesktopControlActionResult {
    case success(String)
    case denied(String)

    var message: String { switch self { case .success(let text), .denied(let text): return text } }
    var succeeded: Bool { if case .success = self { return true }; return false }
    /// True means the input call was accepted; user-visible task completion
    /// still requires a subsequent fresh accessibility observation.
    var requiresFreshObservation: Bool { succeeded }
}
