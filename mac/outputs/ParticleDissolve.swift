import SwiftUI

/// Destination arrangement used while Chef's presence dissolves into a workspace.
enum PresenceDissolveDestination {
    case calendar
    case tasks
}

/// Color mode for the small hologram sparks. The default amber is used while listening.
enum PresenceDissolveTone {
    case listening
    case thinking
    case speaking
}

/// A deterministic particle bridge between the holographic head and a workspace panel.
/// Put this above the portrait in the same sized container. `progress` is interpolated
/// by SwiftUI: zero is a formed head and one is the calendar/task arrangement.
struct PresenceDissolveOverlay: View, Animatable {
    var progress: Double
    var speaking: Bool
    var destination: PresenceDissolveDestination
    var thinking: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    init(
        progress: Double,
        speaking: Bool = false,
        destination: PresenceDissolveDestination = .calendar,
        thinking: Bool = false
    ) {
        self.progress = min(1, max(0, progress))
        self.speaking = speaking
        self.destination = destination
        self.thinking = thinking
    }

    var body: some View {
        Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }
            let t = min(1, max(0, progress))
            let accent: Color = speaking ? Color(red: 1, green: 0.35, blue: 0.47)
                : (thinking ? Color(red: 0.71, green: 0.59, blue: 1)
                    : Color(red: 1, green: 0.67, blue: 0.25))

            for (index, particle) in Self.particles.enumerated() {
                // Reduced Motion keeps each spark at its origin; the quiet opacity shift
                // still communicates the state change without traveling particles.
                let travel = reduceMotion ? 0 : Self.ease(t)
                let destinationPoint = Self.destinationPoint(index: index, layout: destination)
                let x = particle.x + (destinationPoint.x - particle.x) * travel
                let y = particle.y + (destinationPoint.y - particle.y) * travel
                let jitter = reduceMotion ? 0 : sin(t * .pi * 2 + particle.phase) * 0.012 * t
                let point = CGPoint(x: (x + jitter) * size.width,
                                    y: (y + (reduceMotion ? 0 : t * t * 0.06)) * size.height)

                // Particles separate from the face midway through the transition, then
                // settle into a restrained calendar grid or task list.
                let separation = reduceMotion ? 0 : sin(t * .pi) * (0.018 + particle.spread * 0.045)
                let angle = particle.phase * 2.0 * .pi
                let center = CGPoint(x: point.x + cos(angle) * separation * size.width,
                                     y: point.y + sin(angle) * separation * size.height)
                let diameter = particle.size * min(size.width, size.height)
                let alpha = (0.34 + particle.glow * 0.62) * (reduceMotion ? 1 - t * 0.45 : 1)
                let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                  width: diameter, height: diameter)
                let color = index.isMultiple(of: 8) ? Color.white.opacity(alpha * 0.82) : accent.opacity(alpha)
                context.fill(Path(ellipseIn: rect), with: .color(color))

                // A faint, short light tail gives direction without creating visual clutter.
                if !reduceMotion && t > 0.12 && t < 0.94 && index.isMultiple(of: 3) {
                    let tail = CGPoint(x: center.x - cos(angle) * diameter * (0.8 + t),
                                       y: center.y - sin(angle) * diameter * (0.8 + t))
                    var path = Path(); path.move(to: tail); path.addLine(to: center)
                    context.stroke(path, with: .color(accent.opacity(alpha * 0.18)), lineWidth: max(0.35, diameter * 0.28))
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static func ease(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    private static func destinationPoint(index: Int, layout: PresenceDissolveDestination) -> CGPoint {
        switch layout {
        case .calendar:
            // Seven calendar days with a header and six compact week rows.
            let col = index % 7
            let row = (index / 7) % 6
            return CGPoint(x: 0.20 + Double(col) * 0.10,
                           y: 0.31 + Double(row) * 0.072)
        case .tasks:
            // Four quiet task rows with a leading checkbox and varied text lengths.
            let row = index % 4
            let slot = (index / 4) % 8
            let widths: [Double] = [0.045, 0.12, 0.082, 0.15, 0.065, 0.105, 0.14, 0.072]
            return CGPoint(x: 0.22 + widths[slot] + Double(slot) * 0.052,
                           y: 0.35 + Double(row) * 0.105)
        }
    }

    private struct Particle {
        let x: Double
        let y: Double
        let phase: Double
        let size: Double
        let glow: Double
        let spread: Double
    }

    /// Seeded once, so a SwiftUI redraw cannot reshuffle the cloud between frames.
    private static let particles: [Particle] = {
        var result: [Particle] = []
        result.reserveCapacity(420)
        var state: UInt64 = 0x4A4152564953
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0x7fff_ffff) / Double(0x7fff_ffff)
        }
        while result.count < 420 {
            let x = 0.12 + next() * 0.76
            let y = 0.08 + next() * 0.82
            guard Self.inHeadSilhouette(x: x, y: y) else { continue }
            result.append(Particle(x: x, y: y, phase: next(), size: 0.003 + next() * 0.004,
                                   glow: next(), spread: next()))
        }
        return result
    }()

    /// Lightweight geometry invariant used by the app's existing self-test.
    /// It checks stable particle origins and both destination layouts stay finite
    /// and within the unit canvas, including the progress endpoints.
    static func test() -> Bool {
        guard particles.count == 420 else { return false }
        for (index, particle) in particles.enumerated() {
            let origin = CGPoint(x: particle.x, y: particle.y)
            guard origin.x.isFinite, origin.y.isFinite,
                  (0...1).contains(origin.x), (0...1).contains(origin.y) else { return false }
            for destination in [PresenceDissolveDestination.calendar, .tasks] {
                let end = destinationPoint(index: index, layout: destination)
                guard end.x.isFinite, end.y.isFinite,
                      (0...1).contains(end.x), (0...1).contains(end.y) else { return false }
                for progress in [0.0, 0.5, 1.0] {
                    let t = ease(progress)
                    let point = CGPoint(x: particle.x + (end.x - particle.x) * t,
                                        y: particle.y + (end.y - particle.y) * t)
                    guard point.x.isFinite, point.y.isFinite,
                          (0...1).contains(point.x), (0...1).contains(point.y) else { return false }
                }
            }
        }
        return true
    }

    private static func inHeadSilhouette(x: Double, y: Double) -> Bool {
        // Rounded cranium, tapering jaw, neck and soft shoulder edge, expressed in the
        // overlay's normalized coordinates so it scales with any portrait container.
        let headY = (y - 0.36) / 0.29
        let headWidth = y < 0.48 ? 0.245 : max(0.115, 0.245 - (y - 0.48) * 0.43)
        let headCenter = 0.5 + max(0, y - 0.40) * 0.04
        let inHead = pow((x - headCenter) / headWidth, 2) + pow(headY, 2) <= 1
        let neck = y >= 0.60 && y <= 0.79 && abs(x - 0.5) < 0.105
        let shoulders = y > 0.70 && y < 0.91 && abs(x - 0.5) < (0.12 + (y - 0.70) * 1.15)
        return inHead || neck || shoulders
    }
}
