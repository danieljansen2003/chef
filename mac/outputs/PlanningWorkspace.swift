import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct PlanningWorkspace: View {
    @ObservedObject var model: ChefModel
    var space: String? = nil
    @State private var displayedMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    private var shownSpace: String { space ?? model.spaceMode }
    private var calendar: Calendar { Calendar.current }
    private var weekdayHeaders: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let index = max(0, min(6, calendar.firstWeekday - 1))
        return Array(symbols.dropFirst(index)) + Array(symbols.prefix(index))
    }
    private var monthDays: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        let offset = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: interval.start) ?? interval.start
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    private var dayEvents: [CalendarEventSnapshot] {
        model.calendarEvents.filter { overlaps($0.start, $0.end, day: model.planningDate) }.sorted { $0.start < $1.start }
    }
    private var dayBriefings: [AgentWorkflow] {
        model.workflows.filter { workflow in
            PlanningWorkflowSchedule.nextRun(for: workflow).map { calendar.isDate($0, inSameDayAs: model.planningDate) } ?? false
        }
    }
    private var dayReminders: [ReminderSnapshot] {
        model.reminderSnapshots.filter { $0.dueDate.map { calendar.isDate($0, inSameDayAs: model.planningDate) } ?? false }
    }
    private var dayLocalTasks: [PersonalJob] {
        savedTasks.filter { $0.dueDate.map { calendar.isDate($0, inSameDayAs: model.planningDate) } ?? false }
    }
    private var savedTasks: [PersonalJob] {
        let reminderTitles = Set(model.reminderSnapshots.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return model.personalJobs.filter { job in
            job.skill == .todo && !["Completed", "Done", "Cancelled", "Canceled"].contains(job.status)
                && !reminderTitles.contains(job.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shownSpace == "Tasks" ? "TO-DO LIST" : "CALENDAR").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Your Mac Calendar, Reminders, and locally saved work").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await model.refreshPlanningData(month: displayedMonth) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered).help("Refresh calendar and tasks").accessibilityLabel("Refresh calendar and tasks")
                    if shownSpace != "Tasks" {
                        Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.bordered)
                        Text(displayedMonth.formatted(.dateTime.month(.wide).year())).font(.headline).frame(minWidth: 150)
                        Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.bordered)
                    }
                }
                if shownSpace == "Tasks" { tasksView } else { calendarView }
            }.padding(24)
        }
        .task {
            displayedMonth = calendar.dateInterval(of: .month, for: model.planningDate)?.start ?? model.planningDate
            await model.refreshPlanningData(month: displayedMonth)
        }
        .onChange(of: model.planningDate) { _, date in
            let newMonth = calendar.dateInterval(of: .month, for: date)?.start ?? date
            if !calendar.isDate(newMonth, equalTo: displayedMonth, toGranularity: .month) {
                displayedMonth = newMonth
                Task { await model.refreshPlanningData(month: newMonth) }
            }
        }
        .onChange(of: shownSpace) { _, mode in
            if mode == "Calendar" { displayedMonth = calendar.dateInterval(of: .month, for: model.planningDate)?.start ?? model.planningDate }
            Task { await model.refreshPlanningData(month: displayedMonth) }
        }
    }

    private var calendarView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 10) {
                HStack { ForEach(0..<weekdayHeaders.count, id: \.self) { index in Text(weekdayHeaders[index].uppercased()).frame(maxWidth: .infinity).font(.caption2.weight(.bold)).foregroundStyle(.secondary) } }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(monthDays, id: \.self) { date in
                        let inMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
                        let selected = calendar.isDate(date, inSameDayAs: model.planningDate)
                        Button { model.planningDate = date } label: {
                            VStack(spacing: 3) {
                                Text(date.formatted(.dateTime.day())).font(.callout.weight(selected ? .bold : .regular))
                                Circle().fill(hasMarker(date) ? Color.cyan : .clear).frame(width: 4, height: 4)
                            }.frame(maxWidth: .infinity, minHeight: 43).foregroundStyle(selected ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.45)))
                                .background(selected ? Color.cyan.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .background { OrbParticleCell(active: selected) }
                        }.buttonStyle(.plain).accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                    }
                }
            }.padding(10)
                .background { OrbParticlePanel(rows: 6, columns: 7, tint: hudCyan) }
            connectionLine(status: model.calendarLoadStatus, connected: model.calendarConnected, connect: model.connectCalendar)
            connectionLine(status: model.remindersLoadStatus, connected: model.remindersConnected, connect: model.connectReminders)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.planningDate.formatted(date: .complete, time: .omitted)).font(.title3.weight(.semibold))
                if dayEvents.isEmpty { Text(model.calendarConnected ? "No events scheduled for this day." : "Connect Calendar to see events for this day.").foregroundStyle(.secondary).padding(.vertical, 8) }
                ForEach(dayEvents) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.isAllDay ? "ALL DAY" : event.start.formatted(date: .omitted, time: .shortened)).font(.caption.weight(.bold)).foregroundStyle(.cyan).frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) { Text(event.title).font(.body.weight(.medium)); Text(event.calendarTitle).font(.caption).foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                }
                ForEach(dayBriefings) { briefing in
                    HStack(alignment: .top, spacing: 12) {
                        Text((PlanningWorkflowSchedule.nextRun(for: briefing) ?? briefing.createdAt).formatted(date: .omitted, time: .shortened)).font(.caption.weight(.bold)).foregroundStyle(.purple).frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) { Text(briefing.title).font(.body.weight(.medium)); Text("Scheduled briefing").font(.caption).foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                }
                ForEach(dayReminders) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.dueDate?.formatted(date: .omitted, time: .shortened) ?? "DUE").font(.caption.weight(.bold)).foregroundStyle(.orange).frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.body.weight(.medium)); Text("Reminders · \(item.listTitle)").font(.caption).foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                }
                ForEach(dayLocalTasks) { task in
                    HStack(alignment: .top, spacing: 12) {
                        Button { model.completePocketTodo(task) } label: { Image(systemName: "circle").foregroundStyle(.cyan) }
                            .buttonStyle(.plain).accessibilityLabel("Complete \(task.title)")
                        Text(task.dueDate?.formatted(date: .omitted, time: .shortened) ?? "DUE").font(.caption.weight(.bold)).foregroundStyle(.orange).frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) { Text(task.title).font(.body.weight(.medium)); Text(task.message.contains("Synced from Pocket") ? "Phone · saved locally" : "Saved locally in Chef").font(.caption).foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var tasksView: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionLine(status: model.remindersLoadStatus, connected: model.remindersConnected, connect: model.connectReminders)
            section("UPCOMING REMINDERS") {
                if !model.remindersConnected { empty("Connect Reminders to show items saved in the macOS Reminders app.") }
                else if model.reminderSnapshots.isEmpty { empty("No incomplete Reminders found.") }
                ForEach(model.reminderSnapshots) { item in
                    taskRow(item.title, subtitle: [item.dueDate?.formatted(date: .abbreviated, time: .shortened), item.listTitle].compactMap { $0 }.joined(separator: " · "))
                }
            }
            section("SAVED LOCALLY") {
                if savedTasks.isEmpty { empty("No local to-do tasks saved in Chef.") }
                ForEach(savedTasks) { task in
                    HStack(spacing: 12) {
                        Button { model.completePocketTodo(task) } label: { Image(systemName: "circle").foregroundStyle(.cyan) }
                            .buttonStyle(.plain).accessibilityLabel("Complete \(task.title)")
                        taskRow(task.title, subtitle: [task.dueDate?.formatted(date: .abbreviated, time: .shortened), task.message.contains("Synced from Pocket") ? "Phone · \(task.status)" : "Chef · \(task.status)"].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
            section("SCHEDULED BRIEFINGS") {
                let briefings = model.workflows.filter { PlanningWorkflowSchedule.nextRun(for: $0) != nil }.sorted {
                    (PlanningWorkflowSchedule.nextRun(for: $0) ?? .distantFuture) < (PlanningWorkflowSchedule.nextRun(for: $1) ?? .distantFuture)
                }
                if briefings.isEmpty { empty("No scheduled briefings.") }
                ForEach(briefings) { briefing in
                    let time = (PlanningWorkflowSchedule.nextRun(for: briefing) ?? briefing.createdAt).formatted(date: .abbreviated, time: .shortened)
                    taskRow(briefing.title, subtitle: "\(time) · Chef must be running and Mac awake")
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary); content() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background { OrbParticlePanel(rows: 5, columns: 12, tint: hudCyan) }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(hudCyan.opacity(0.22), lineWidth: 1))
    }
    private func taskRow(_ title: String, subtitle: String) -> some View {
        HStack(spacing: 12) { Image(systemName: "circle").foregroundStyle(.cyan); VStack(alignment: .leading, spacing: 3) { Text(title).font(.body.weight(.medium)); Text(subtitle.isEmpty ? "No due date" : subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer() }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background { OrbParticleCell(active: false, tint: hudCyan) }
    }
    private func empty(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 3) }
    private func connectionLine(status: String, connected: Bool, connect: @escaping () -> Void) -> some View {
        HStack(spacing: 10) { Image(systemName: connected ? "checkmark.circle.fill" : "info.circle").foregroundStyle(connected ? .green : .orange); Text(status).font(.caption).foregroundStyle(.secondary); Spacer(); if !connected { Button("Connect") { connect() }.buttonStyle(.bordered) } }
    }
    private func shiftMonth(_ amount: Int) {
        guard let newMonth = calendar.date(byAdding: .month, value: amount, to: displayedMonth), let first = calendar.dateInterval(of: .month, for: newMonth)?.start else { return }
        displayedMonth = first
        model.planningDate = first
        Task { await model.refreshPlanningData(month: first) }
    }
    private func hasMarker(_ date: Date) -> Bool {
        model.calendarEvents.contains { overlaps($0.start, $0.end, day: date) }
            || model.reminderSnapshots.contains { $0.dueDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false }
            || savedTasks.contains { $0.dueDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false }
            || model.workflows.contains { workflow in
                PlanningWorkflowSchedule.nextRun(for: workflow).map { calendar.isDate($0, inSameDayAs: date) } ?? false
            }
    }
    private func overlaps(_ start: Date, _ end: Date, day: Date) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return start < dayEnd && end > dayStart
    }
}

/// A quiet dotted cell frame leaves date and task labels as crisp native text.
private struct OrbParticleCell: View {
    var active: Bool
    var tint: Color = hudCyan

    var body: some View {
        Canvas { context, size in
            let color = tint.opacity(active ? 0.86 : 0.42)
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            context.fill(Path(roundedRect: bounds, cornerRadius: 8), with: .color(tint.opacity(active ? 0.08 : 0.018)))
            let horizontalSteps = max(2, Int(size.width / 5))
            let verticalSteps = max(2, Int(size.height / 5))
            for index in 0...horizontalSteps {
                let x = 2 + CGFloat(index) / CGFloat(horizontalSteps) * (size.width - 4)
                let radius: CGFloat = active && index.isMultiple(of: 5) ? 1.5 : 0.9
                for y in [CGFloat(1.5), size.height - 1.5] {
                    context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                }
            }
            for index in 0...verticalSteps {
                let y = 2 + CGFloat(index) / CGFloat(verticalSteps) * (size.height - 4)
                let radius: CGFloat = active && index.isMultiple(of: 5) ? 1.5 : 0.9
                for x in [CGFloat(1.5), size.width - 1.5] {
                    context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Persistent particle rails give the month grid and task sections a shared hologram structure.
private struct OrbParticlePanel: View {
    let rows: Int
    let columns: Int
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            context.fill(Path(roundedRect: bounds, cornerRadius: 14), with: .color(tint.opacity(0.025)))
            let horizontalSteps = max(2, Int(size.width / 6))
            let verticalSteps = max(2, Int(size.height / 6))
            for row in 0...max(1, rows) {
                let y = 2 + (size.height - 4) * CGFloat(row) / CGFloat(max(1, rows))
                for step in 0...horizontalSteps {
                    let x = 2 + (size.width - 4) * CGFloat(step) / CGFloat(horizontalSteps)
                    let radius: CGFloat = row == 0 || row == rows ? 1.05 : 0.72
                    let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(row.isMultiple(of: 2) ? 0.34 : 0.22)))
                }
            }
            if columns <= 7 {
                for column in 0...columns {
                    let x = 2 + (size.width - 4) * CGFloat(column) / CGFloat(max(1, columns))
                    for step in 0...verticalSteps {
                        let y = 2 + (size.height - 4) * CGFloat(step) / CGFloat(verticalSteps)
                        let radius: CGFloat = column == 0 || column == columns ? 1.05 : 0.62
                        context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(tint.opacity(0.26)))
                    }
                }
            } else {
                for side in [CGFloat(2), size.width - 2] {
                    for step in 0...verticalSteps {
                        let y = 2 + (size.height - 4) * CGFloat(step) / CGFloat(verticalSteps)
                        let rect = CGRect(x: side - 0.9, y: y - 0.9, width: 1.8, height: 1.8)
                        context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.30)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct PhoneSyncWorkspace: View {
    @ObservedObject var model: ChefModel
    @ObservedObject var sync: PocketSync
    private var thoughts: [PocketItem] {
        sync.items.filter { $0.kind == .thought }
    }

    private static func displayDate(_ text: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        guard let date else { return text }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("PHONE").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Connect an Android phone to sync to-dos and thoughts. Phone content stays saved locally until you connect.")
                    .font(.callout).foregroundStyle(.secondary)
                PocketSyncPanel(sync: sync)
                VStack(alignment: .leading, spacing: 10) {
                    Text("CAPTURE A THOUGHT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    TextField("Write a thought to keep on this Mac…", text: $model.pocketThoughtDraft, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save thought") { model.capturePocketThought() }
                            .disabled(model.pocketThoughtDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Thoughts are saved locally. Sync starts only after Connect.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background { OrbParticlePanel(rows: 4, columns: 10, tint: hudCyan) }
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(hudCyan.opacity(0.22), lineWidth: 1))
                VStack(alignment: .leading, spacing: 10) {
                    Text("THOUGHTS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    if thoughts.isEmpty {
                        Text("No thoughts saved yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(thoughts) { thought in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(thought.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.displayDate(thought.updatedAt))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
                .background { OrbParticlePanel(rows: max(3, thoughts.count + 1), columns: 10, tint: hudCyan) }
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(hudCyan.opacity(0.22), lineWidth: 1))
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
        }
    }
}