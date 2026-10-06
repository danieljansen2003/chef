import SwiftUI

struct OrbNode: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    var hue: Double? = nil
    /// Longitude and latitude in radians on the orb's local surface.
    var angle: Double = 0
    var latitude: Double = 0

    init(id: String, title: String, detail: String, hue: Double? = nil, angle: Double = 0, latitude: Double = 0) {
        self.id = id; self.title = title; self.detail = detail; self.hue = hue; self.angle = angle; self.latitude = latitude
    }
}

/// Procedural, native SwiftUI particle hologram. All coordinates are generated from stable
/// seeds and projected in 3D, so the reverse side remains present through a complete turn.
struct OrbHologram: View {
    let speaking: Bool
    let thinking: Bool
    let listening: Bool
    var yaw: Double = 0
    var pitch: Double = 0
    var variant: String = "Presence"
    var nodes: [OrbNode] = []
    var onSelect: (OrbNode) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let particleCount = 3_600

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            TimelineView(.animation(minimumInterval: (speaking || thinking || listening) ? 1.0 / 30.0 : 1.0 / 24.0, paused: reduceMotion)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
                        drawAura(in: context, center: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2), radius: size * 0.405, time: t)
                        let points = OrbGeometry.project(count: particleCount, variant: variant, mode: mode,
                                                         yaw: yaw, pitch: pitch, time: t, radius: size * 0.405)
                        for p in points {
                            let center = CGPoint(x: geo.size.width / 2 + p.x, y: geo.size.height / 2 - p.y)
                            let r = p.radius
                            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                            context.fill(Path(ellipseIn: rect), with: .color(p.color.opacity(p.alpha)))
                            if p.spark {
                                let halo = CGRect(x: center.x - r * 2.4, y: center.y - r * 2.4, width: r * 4.8, height: r * 4.8)
                                context.fill(Path(ellipseIn: halo), with: .color(p.color.opacity(p.alpha * 0.06)))
                            }
                        }
                    }
                    ForEach(nodes) { node in
                        let p = OrbGeometry.projectNode(node, variant: variant, mode: mode, yaw: yaw, pitch: pitch, time: t, radius: size * 0.405)
                        Button { onSelect(node) } label: {
                            Circle().fill(Color(hue: node.hue ?? 0.105, saturation: 0.52, brightness: 1))
                                .frame(width: p.front ? 9 : 6, height: p.front ? 9 : 6)
                                .shadow(color: Color(hue: node.hue ?? 0.105, saturation: 0.7, brightness: 1).opacity(p.front ? 0.85 : 0.25), radius: p.front ? 8 : 3)
                                .overlay(Circle().stroke(.white.opacity(p.front ? 0.8 : 0.2), lineWidth: 0.7))
                        }
                        .buttonStyle(.plain).opacity(p.front ? 0.95 : 0.25)
                        .accessibilityLabel(node.title).accessibilityHint(node.detail)
                        .help(node.title + (node.detail.isEmpty ? "" : " · " + String(node.detail.prefix(100))))
                        .position(x: geo.size.width / 2 + p.x, y: geo.size.height / 2 - p.y)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(variant) holographic orb")
    }

    private var mode: OrbGeometry.Mode { speaking ? .speaking : thinking ? .thinking : listening ? .listening : .idle }

    private func drawAura(in context: GraphicsContext, center: CGPoint, radius: CGFloat, time: Double) {
        let pulse = speaking ? 0.035 * sin(time * 4.2) : thinking ? 0.018 * sin(time * 1.3) : listening ? 0.012 * sin(time * 1.8) : 0
        let rect = CGRect(x: center.x - radius * (1.15 + pulse), y: center.y - radius * (1.15 + pulse), width: radius * 2.3 * (1 + pulse), height: radius * 2.3 * (1 + pulse))
        let hue: Double = thinking ? 0.77 : speaking ? 0.96 : 0.105
        context.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [Color(hue: hue, saturation: 0.8, brightness: 0.75).opacity(0.095), .clear]), center: center, startRadius: radius * 0.35, endRadius: radius * 1.18))
    }
}

enum OrbGeometry {
    enum Mode: Equatable { case idle, listening, thinking, speaking }
    struct Particle {
        let x, y: CGFloat
        let depth: Double
        let radius: CGFloat
        let alpha: Double
        let color: Color
        let spark: Bool
    }
    struct Projection { let x, y: CGFloat; let front: Bool }
    private struct Seed { let lat: Double; let lon: Double }
    private static let seeds: [Seed] = (0..<3_600).map { i in
        let u = (Double(i) + 0.5) / 3_600
        return Seed(lat: asin(1 - 2 * u), lon: Double(i) * 2.399963229728653)
    }

    static func test() {
        let cloud = project(count: 2400, variant: "Presence", mode: .listening, yaw: 0, pitch: 0, time: 0, radius: 100)
        precondition(cloud.count == 2400)
        precondition(cloud.contains { $0.depth > 0.25 } && cloud.contains { $0.depth < -0.25 }, "Orb particles must cover front and rear surfaces")
        precondition(cloud.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.alpha >= 0 && $0.alpha <= 1 })
        let folded = project(count: 1600, variant: "Projects", mode: .thinking, yaw: 1.5, pitch: 0.5, time: 2, radius: 100)
        precondition(folded.count == 1600 && folded.contains { $0.depth < -0.2 })
        let initial = project(count: 3600, variant: "Presence", mode: .listening, yaw: 0, pitch: 0, time: 0, radius: 100)
        let fullTurn = project(count: 3600, variant: "Presence", mode: .listening, yaw: 2 * .pi, pitch: 0, time: 0, radius: 100)
        precondition(zip(initial, fullTurn).allSatisfy { abs($0.x - $1.x) < 0.0001 && abs($0.y - $1.y) < 0.0001 }, "Full rotation must return to the same particle positions")
        print("Procedural orb projection is bounded, covers full depth, and joins seamlessly after 360 degrees.")
    }

    static func project(count: Int, variant: String, mode: Mode, yaw: Double, pitch: Double, time: Double, radius: CGFloat) -> [Particle] {
        guard count > 0 else { return [] }
        let phase = stablePhase(variant)
        return seeds.prefix(min(count, seeds.count)).enumerated().map { i, seed in
            let lat = seed.lat
            let lon = seed.lon + phase
            let v = shape(lon: lon, lat: lat, variant: variant, mode: mode, time: time)
            let rotated = rotate(v, yaw: yaw + (mode == .speaking && time != 0 ? sin(time * 0.55) * 0.025 : 0), pitch: pitch)
            let depth = rotated.z
            let light = depth >= 0 ? 0.95 + 0.05 * max(0, depth) : 0.60 + 0.12 * (depth + 1)
            let hue = palette(lon: lon, lat: lat, depth: depth, variant: variant, mode: mode, time: time)
            let paleSpeck = i % 10 < 3
            let color = Color(hue: paleSpeck ? 0.075 : hue, saturation: paleSpeck ? 0.16 : 0.25 + 0.25 * ((sin(lon * 4 + lat * 2) + 1) / 2), brightness: paleSpeck ? min(1, light + 0.03) : light)
            let rearFade = depth >= 0 ? 0.75 + 0.20 * depth : 0.30 + 0.20 * (depth + 1)
            let pulse = mode == .speaking ? 0.76 + 0.24 * sin(time * 5 + lon * 2) : mode == .thinking ? 0.72 + 0.28 * sin(time * 1.4 + lon) : 1
            let radiusScale = (i % 31 == 0) ? 1.8 : (i % 5 == 0 ? 1.25 : 0.78)
            return Particle(x: CGFloat(rotated.x) * radius * CGFloat(1 + depth * 0.1), y: CGFloat(rotated.y) * radius * CGFloat(1 + depth * 0.1), depth: depth,
                            radius: i % 127 == 0 ? 1.1 : max(0.35, radius * 0.0022 * radiusScale), alpha: depth >= 0 ? min(0.98, max(0.75, rearFade * pulse)) : min(0.50, max(0.30, rearFade * pulse)), color: color, spark: i % 127 == 0)
        }
    }

    static func projectNode(_ node: OrbNode, variant: String, mode: Mode, yaw: Double, pitch: Double, time: Double, radius: CGFloat) -> Projection {
        let v = shape(lon: node.angle, lat: node.latitude, variant: variant, mode: mode, time: time)
        let p = rotate(v, yaw: yaw, pitch: pitch)
        let light = max(0.5, min(1, 0.62 + max(0, p.z) * 0.38))
        let perspective = CGFloat(1 + p.z * 0.1)
        return Projection(x: CGFloat(p.x) * radius * perspective, y: CGFloat(p.y) * radius * perspective, front: p.z > -0.12)
    }

    private static func shape(lon: Double, lat: Double, variant: String, mode: Mode, time: Double) -> (x: Double, y: Double, z: Double) {
        let base = cos(lat)
        let variantWave: Double
        switch variant.lowercased() {
        case "projects": variantWave = 0.10 * cos(4 * lon + 0.8) * cos(lat) + 0.035 * sin(3 * lat)
        case "agents": variantWave = 0.12 * sin(5 * lon) * cos(lat) * cos(lat) + 0.025 * cos(7 * lat)
        case "folders": variantWave = 0.13 * cos(3 * lon + 2 * lat) * cos(lat) + 0.04 * sin(6 * lon)
        case "calendar": variantWave = 0.09 * sin(6 * lon + lat) * cos(lat) + 0.035 * cos(4 * lat)
        case "tasks": variantWave = 0.12 * sin(4 * lon - 3 * lat) * cos(lat) + 0.035 * sin(7 * lon)
        default: variantWave = 0
        }
        let activity: Double
        switch mode {
        case .thinking:
            // Broad toroidal waist with several soft folded petals, never a sharp mesh.
            let petal = cos(5 * lon + 0.8 * sin(2 * lat))
            activity = -0.18 * exp(-pow(lat / 0.38, 2)) + 0.30 * petal * cos(lat) * cos(lat) + 0.045 * sin(3 * lon + lat * 2)
        case .speaking:
            activity = 0.075 * sin(3 * lon + time * 1.7) * cos(2 * lat + time * 0.9) + 0.05 * sin(5 * lon - 3 * lat + time * 0.7)
        case .listening: activity = 0.045 * sin(3 * lon) * cos(lat) + 0.025 * cos(4 * lat)
        case .idle: activity = 0.10 * sin(2 * lon + lat + time * 0.18) * cos(lat)
        }
        let r = 1 + variantWave + activity
        if mode == .thinking {
            let tube = 0.64 + 0.20 * cos(5 * lon + 0.8 * sin(2 * lat))
            let rr = (tube + activity * 0.55) * r
            return (rr * base * cos(lon), 0.84 * rr * sin(lat) + 0.04 * sin(5 * lon), rr * base * sin(lon))
        }
        return (r * base * cos(lon), r * sin(lat), r * base * sin(lon))
    }

    private static func rotate(_ p: (x: Double, y: Double, z: Double), yaw: Double, pitch: Double) -> (x: Double, y: Double, z: Double) {
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let x = p.x * cy + p.z * sy
        let z = -p.x * sy + p.z * cy
        return (x, p.y * cp - z * sp, p.y * sp + z * cp)
    }

    private static func stablePhase(_ text: String) -> Double {
        let hash = text.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Double(hash % 10_000) / 10_000 * 2 * .pi
    }

    private static func palette(lon: Double, lat: Double, depth: Double, variant: String, mode: Mode, time: Double) -> Double {
        let warm = 0.105, rose = 0.965, lavender = 0.755
        let blend = (sin(lon * 2.7 + lat * 4.2 + (mode == .thinking ? time * 0.18 : 0)) + 1) / 2
        let jitter = 0.025 * sin(7 * lon + 3 * lat)
        if mode == .thinking { return blend < 0.64 ? lavender + jitter : (blend < 0.9 ? rose + jitter : warm + jitter) }
        if mode == .speaking { return blend < 0.62 ? rose + jitter : (blend < 0.88 ? warm + jitter : lavender + jitter) }
        return blend < 0.68 ? warm + jitter : (blend < 0.84 ? rose + jitter : lavender + jitter)
    }
}
