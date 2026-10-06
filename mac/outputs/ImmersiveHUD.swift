import SwiftUI

@available(macOS 26.0, *)
enum AgentIdentity {
    static func hash(_ id: String) -> UInt64 { id.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 } }
    static func name(_ id: String) -> String {
        let names = ["Atlas", "Nova", "Iris", "Orion", "Vega", "Echo", "Sage", "Lyra", "Rune", "Sol", "Cleo", "Aster"]
        return names[Int(hash(id) % UInt64(names.count))] + " · " + String(id.suffix(4)).uppercased()
    }
    static func color(_ id: String) -> Color { Color(hue: Double(hash(id)) / Double(UInt64.max), saturation: 0.65, brightness: 1) }
    static func entries(model: ChefModel, engine: AIEngine) -> [SpaceEntry] {
        var entries = model.taskProgress.map { task in
            SpaceEntry(id: "specialist:" + task.id.uuidString, title: task.specialist == .apps ? "Orion" : task.specialist == .maintenance ? "Vega" : task.specialist == .conversation ? "Sage" : "Atlas", kind: task.specialist.rawValue + " · " + task.status, path: "", detail: task.request, colorKey: task.specialist.rawValue)
        }
        if let job = model.activeDraftJob { entries.append(SpaceEntry(id: "worker:job:" + job.id.uuidString, title: name(job.id.uuidString), kind: job.skill.title + " · drafting locally", path: "", detail: job.title + "\n" + String(job.details.prefix(300)), colorKey: job.id.uuidString)) }
        if let project = engine.projects.first {
            entries += project.tasks.map { task in
                let identity = (task.parentTaskID ?? task.id).uuidString
                let state = project.results.first { $0.id == task.id }?.state.rawValue ?? "queued"
                return SpaceEntry(id: "worker:" + task.id.uuidString, title: name(identity), kind: task.recommendedTier.label + " draft worker · " + state, path: "", detail: task.objective + "\nProject: " + project.objective, colorKey: identity)
            }
        }
        return entries
    }
    static func test() {
        let first = "11111111-1111-1111-1111-111111111111", second = "22222222-2222-2222-2222-222222222222"
        precondition(name(first) == name(first) && name(first) != name(second) && hash(first) != hash(second))
        print("Agent identity stability and distinct names passed.")
    }
}

@available(macOS 26.0, *)
struct AgentActivity: View {
    @ObservedObject var model: ChefModel
    @ObservedObject var engine: AIEngine
    var body: some View {
        let entries = AgentIdentity.entries(model: model, engine: engine)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(entries.prefix(8)) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(entry.title, systemImage: "circle.fill").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(AgentIdentity.color(entry.colorKey ?? entry.id))
                        Text(entry.kind).font(.caption2).foregroundStyle(.white)
                        Text(entry.detail).font(.caption2).foregroundStyle(hudDim).lineLimit(2).frame(width: 205, alignment: .leading)
                    }.padding(12).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                }
                if entries.isEmpty { Text("No agents working · your next request starts the appropriate specialist").font(.caption).foregroundStyle(hudDim) }
            }
        }.frame(height: 85)
    }
}
