import SwiftUI
import AppKit
import SceneKit

/// A curved, emissive portrait over a complete procedural head, neck, and shoulder volume.
/// The reference artwork supplies the familiar front-facing detail; the underlying solid
/// geometry remains visible as the user turns the hologram through a full revolution.
struct HolographicPortrait: View {
    let speaking: Bool
    var yaw: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let portrait: NSImage? = Bundle.main.url(forResource: ChefCompatibility.key("ChefHead"), withExtension: "png").flatMap(NSImage.init(contentsOf:))

    static func test() {
        precondition(portrait != nil && portrait!.size.width >= 512 && portrait!.size.height >= 512, "Missing holographic portrait resource")
        let shape = HeadSurface.make(widthSegments: 32, heightSegments: 40)
        precondition(shape.vertices.count > 1000, "Holographic head surface is too sparse")
        let depths = shape.vertices.map(\.z)
        precondition((depths.max() ?? 0) - (depths.min() ?? 0) > 0.3, "Holographic head must have real depth")
        precondition(shape.indices.count > shape.vertices.count * 3, "Holographic portrait surface must have a dense triangulated mesh")
        precondition(shape.vertices.allSatisfy { abs($0.x) < 1.3 && $0.y > -1.9 && $0.y < 1.5 }, "Hologram geometry must stay inside the human head and shoulder envelope")
        precondition(HeadSurface.profile(at: -1.78).width > HeadSurface.profile(at: 0.45).width * 1.3, "Shoulder silhouette must widen below the human head")
        let noseTip = HeadSurface.point(y: 0.02, angle: 0)
        let cheekProfile = HeadSurface.point(y: 0.02, angle: 0.48)
        precondition(noseTip.z > cheekProfile.z, "The frontal profile must retain a raised nose")
        let rearVertices = shape.vertices.filter { $0.z < -0.25 }
        precondition(rearVertices.count > shape.vertices.count / 8, "Holographic head must carry dense geometry around the back")
        let constellation = HeadConstellation.make(count: 900)
        precondition(constellation.points.count == 900 && constellation.links.count > 900, "A dense particle network must cover the whole head")
        precondition(constellation.points.filter { $0.z < -0.25 }.count > 180, "Rear of hologram must carry cyan constellation particles")
        precondition(constellation.points.filter { abs($0.x) > 0.55 && $0.y > -0.5 && $0.y < 1.2 }.count > 135, "Side profile must carry cyan constellation particles")
        let front = HeadSurface.makeFrontReference(widthSegments: 32, heightSegments: 40)
        precondition(front.uv.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }, "Reference artwork must preserve the full portrait proportions")
        let openMouth = front.withSpeakingMouthOpen()
        let mouthChanges = zip(front.vertices, openMouth.vertices).filter { abs($0.0.y - $0.1.y) > 0.001 }
        precondition(!mouthChanges.isEmpty && mouthChanges.allSatisfy { $0.0.y > -0.62 && $0.0.y < -0.28 }, "Speaking morph must stay bounded around the lips")
        print("Bundled portrait and depth-bearing holographic head geometry are available.")
    }

    var body: some View {
        HeadScene(speaking: speaking, reduceMotion: reduceMotion, yaw: yaw)
            .accessibilityLabel("Chef cyan holographic human portrait. Drag to rotate.")
            .accessibilityHint("Rotate the three-dimensional hologram by dragging")
    }
}

private struct HeadScene: NSViewRepresentable {
    let speaking: Bool
    let reduceMotion: Bool
    let yaw: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = makeScene()
        view.backgroundColor = .clear
        view.isPlaying = true
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.speaking = speaking
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.morpher = view.scene?.rootNode.childNode(withName: "curvedReferenceDetail", recursively: true)?.morpher
        let drag = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        view.addGestureRecognizer(drag)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.speaking = speaking
        context.coordinator.reduceMotion = reduceMotion
        if let rig = view.scene?.rootNode.childNode(withName: "rotationRig", recursively: false) {
            rig.eulerAngles.y = CGFloat(yaw)
        }
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let rig = SCNNode(); rig.name = "rotationRig"; scene.rootNode.addChildNode(rig)

        // A single circumferential wire surface gives the silhouette continuous depth
        // from forehead over the skull, ears, nape, neck, and shoulders.
        let volume = HeadSurface.make(widthSegments: 80, heightSegments: 110)
        let volumeGeometry = SCNGeometry(sources: [SCNGeometrySource(vertices: volume.vertices)], elements: [SCNGeometryElement(indices: volume.indices, primitiveType: .triangles)])
        let wire = SCNMaterial(); wire.fillMode = .lines; wire.lightingModel = .constant
        wire.diffuse.contents = NSColor(calibratedRed: 0.008, green: 0.14, blue: 0.24, alpha: 0.24)
        wire.emission.contents = wire.diffuse.contents; wire.isDoubleSided = true
        volumeGeometry.materials = [wire]
        let volumeNode = SCNNode(geometry: volumeGeometry); volumeNode.name = "continuousHeadVolume"; rig.addChildNode(volumeNode)
        let constellation = HeadConstellation.make(count: 900)
        let particleElement = SCNGeometryElement(indices: Array(Int32(0)..<Int32(constellation.points.count)), primitiveType: .point)
        particleElement.pointSize = 4.5
        particleElement.minimumPointScreenSpaceRadius = 2.2
        particleElement.maximumPointScreenSpaceRadius = 4.2
        let linkElement = SCNGeometryElement(indices: constellation.links, primitiveType: .line)
        let starElement = SCNGeometryElement(indices: stride(from: 0, to: constellation.points.count, by: 7).map { Int32($0) }, primitiveType: .point)
        starElement.pointSize = 8
        starElement.minimumPointScreenSpaceRadius = 4
        starElement.maximumPointScreenSpaceRadius = 8
        let particleGeometry = SCNGeometry(sources: [SCNGeometrySource(vertices: constellation.points)], elements: [particleElement, linkElement, starElement])
        let particles = SCNMaterial(); particles.lightingModel = .constant
        particles.diffuse.contents = NSColor(calibratedRed: 0.12, green: 0.98, blue: 1, alpha: 1)
        particles.emission.contents = particles.diffuse.contents
        let links = SCNMaterial(); links.lightingModel = .constant; links.blendMode = .alpha
        links.diffuse.contents = NSColor(calibratedRed: 0.025, green: 0.72, blue: 0.96, alpha: 0.96)
        links.emission.contents = links.diffuse.contents
        let stars = SCNMaterial(); stars.lightingModel = .constant
        stars.diffuse.contents = NSColor(calibratedRed: 0.54, green: 0.96, blue: 1, alpha: 1)
        stars.emission.contents = stars.diffuse.contents
        particleGeometry.materials = [particles, links, stars]
        let particleNode = SCNNode(geometry: particleGeometry); particleNode.name = "headConstellation"; particleNode.renderingOrder = 2; rig.addChildNode(particleNode)

        if let portrait = HolographicPortrait.portrait {
            let mesh = HeadSurface.makeFrontReference(widthSegments: 80, heightSegments: 110)
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: mesh.vertices), SCNGeometrySource(textureCoordinates: mesh.uv)], elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
            let ionized = Self.ionized(portrait)
            let material = SCNMaterial()
            material.diffuse.contents = ionized
            material.emission.contents = ionized
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            material.blendMode = .alpha
            geometry.materials = [material]
            let imageNode = SCNNode(geometry: geometry)
            imageNode.name = "curvedReferenceDetail"
            imageNode.renderingOrder = 100
            let targetMesh = mesh.withSpeakingMouthOpen()
            let target = SCNGeometry(sources: [SCNGeometrySource(vertices: targetMesh.vertices), SCNGeometrySource(textureCoordinates: targetMesh.uv)], elements: [SCNGeometryElement(indices: targetMesh.indices, primitiveType: .triangles)])
            target.materials = [material]
            let morpher = SCNMorpher(); morpher.calculationMode = .normalized; morpher.targets = [target]
            imageNode.morpher = morpher
            rig.addChildNode(imageNode)
        }

        let camera = SCNCamera(); camera.wantsHDR = false; camera.bloomIntensity = 0; camera.fieldOfView = 35; camera.zNear = 0.1; camera.zFar = 100
        let cameraNode = SCNNode(); cameraNode.camera = camera; cameraNode.position = SCNVector3(0, -0.1, 6.1); cameraNode.look(at: SCNVector3(0, -0.22, 0)); scene.rootNode.addChildNode(cameraNode)
        let light = SCNLight(); light.type = .omni; light.intensity = 120; light.color = NSColor(calibratedRed: 0.23, green: 0.83, blue: 1, alpha: 1)
        let lightNode = SCNNode(); lightNode.light = light; lightNode.position = SCNVector3(-2, 2, 4); scene.rootNode.addChildNode(lightNode)
        return scene
    }

    /// Preserve the supplied cyan-and-white artwork and feather only its alpha.
    private static func ionized(_ source: NSImage) -> NSImage {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let input = NSBitmapImageRep(cgImage: cg).cgImage,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: input.width, pixelsHigh: input.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: input.width * 4, bitsPerPixel: 32),
              let ctx = CGContext(data: rep.bitmapData, width: input.width, height: input.height, bitsPerComponent: 8, bytesPerRow: rep.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return source }
        ctx.draw(input, in: CGRect(x: 0, y: 0, width: input.width, height: input.height))
        let bytes = rep.bitmapData!
        for i in stride(from: 0, to: input.width * input.height * 4, by: 4) {
            let sourceRed = Int(bytes[i]), sourceGreen = Int(bytes[i + 1]), sourceBlue = Int(bytes[i + 2])
            let luma = (Int(bytes[i]) * 3 + Int(bytes[i + 1]) * 6 + Int(bytes[i + 2])) / 10
            let alpha = max(0, min(255, (luma - 8) * 2))
            bytes[i] = UInt8(sourceRed * alpha / 255)
            bytes[i + 1] = UInt8(sourceGreen * alpha / 255)
            bytes[i + 2] = UInt8(sourceBlue * alpha / 255)
            bytes[i + 3] = UInt8(alpha)
        }
        return NSImage(cgImage: rep.cgImage!, size: source.size)
    }
}

private struct HeadSurface {
    let vertices: [SCNVector3]
    let uv: [CGPoint]
    let indices: [Int32]

    static func make(widthSegments: Int, heightSegments: Int) -> HeadSurface {
        var vertices: [SCNVector3] = []; var uv: [CGPoint] = []; var indices: [Int32] = []
        for row in 0...heightSegments {
            let v = Double(row) / Double(heightSegments)
            let y = 1.48 - v * 3.36
            for col in 0...widthSegments {
                let u = Double(col) / Double(widthSegments)
                let angle = u * 2 * Double.pi
                vertices.append(Self.point(y: y, angle: angle))
                uv.append(CGPoint(x: u, y: v))
                if row < heightSegments && col < widthSegments {
                    let a = Int32(row * (widthSegments + 1) + col), b = a + 1, c = a + Int32(widthSegments + 1), d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }
        return HeadSurface(vertices: vertices, uv: uv, indices: indices)
    }

    static func point(y: Double, angle: Double) -> SCNVector3 {
        let profile = Self.profile(at: y)
        let front = cos(angle)
        var x = sin(angle) * profile.width
        var z = cos(angle) * profile.depth
        let face = max(0, front)
        // Nose bridge/tip, brow ridge, eye recesses, cheeks, lips, and chin all
        // deform the same watertight surface, including the cyan side profile.
        z += face * (0.23 * exp(-pow(x / 0.15, 2) - pow((y - 0.02) / 0.36, 2))
            + 0.045 * exp(-pow((abs(x) - 0.30) / 0.22, 2) - pow((y - 0.43) / 0.12, 2))
            - 0.035 * exp(-pow((abs(x) - 0.29) / 0.20, 2) - pow((y - 0.30) / 0.10, 2))
            + 0.045 * exp(-pow((abs(x) - 0.41) / 0.23, 2) - pow((y - 0.03) / 0.22, 2))
            + 0.035 * exp(-pow(x / 0.29, 2) - pow((y + 0.405) / 0.050, 2))
            + 0.038 * exp(-pow(x / 0.29, 2) - pow((y + 0.492) / 0.048, 2))
            - 0.040 * exp(-pow(x / 0.25, 4) - pow((y + 0.452) / 0.023, 2))
            + 0.065 * exp(-pow(x / 0.36, 2) - pow((y + 0.60) / 0.18, 2)))
        z -= max(0, -front) * (0.035 * exp(-pow((y - 0.35) / 0.60, 2)) + 0.045 * exp(-pow((y + 0.62) / 0.22, 2)))
        // Ears are continuous lateral folds in the same surface, with a shallow concha.
        let earSide = exp(-pow((abs(sin(angle)) - 0.91) / 0.14, 2))
        let earBand = exp(-pow((y - 0.04) / 0.22, 4)) * exp(-pow((abs(x) - 0.67) / 0.105, 2)) * earSide
        x += (x < 0 ? -1 : 1) * earBand * 0.075
        z += earBand * (0.055 + max(0, front) * 0.05)
        let earCavity = exp(-pow((y - 0.04) / 0.12, 2)) * exp(-pow((abs(x) - 0.665) / 0.038, 2)) * earSide
        z -= earCavity * 0.018
        return SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z))
    }

    fileprivate static func profile(at y: Double) -> (width: Double, depth: Double) {
        // Smooth landmarks from crown through jaw, neck, then shoulder line.
        let keys: [(Double, Double, Double)] = [(1.48, 0.02, 0.02), (1.34, 0.39, 0.34), (0.98, 0.70, 0.55), (0.48, 0.77, 0.61), (0.08, 0.70, 0.56), (-0.36, 0.52, 0.46), (-0.70, 0.27, 0.34), (-0.91, 0.24, 0.31), (-1.35, 0.31, 0.34), (-1.63, 0.78, 0.43), (-1.88, 1.16, 0.49), (-1.88, 0.02, 0.02)]
        for index in 0..<(keys.count - 1) where y <= keys[index].0 && y >= keys[index + 1].0 {
            let a = keys[index], b = keys[index + 1]
            let t = max(0, min(1, (a.0 - y) / (a.0 - b.0)))
            let smooth = t * t * (3 - 2 * t)
            return (a.1 + (b.1 - a.1) * smooth, a.2 + (b.2 - a.2) * smooth)
        }
        return y > 1.48 ? (0.02, 0.02) : (0.02, 0.02)
    }

    static func makeFrontReference(widthSegments: Int, heightSegments: Int) -> HeadSurface {
        var vertices: [SCNVector3] = []; var uv: [CGPoint] = []; var indices: [Int32] = []
        for row in 0...heightSegments {
            let v = Double(row) / Double(heightSegments)
            let y = 1.48 - v * 3.36
            let profile = Self.profile(at: y)
            for col in 0...widthSegments {
                let u = Double(col) / Double(widthSegments)
                // Preserve the 1086×1448 reference proportions when viewed from the front.
                let x = (u * 2 - 1) * 1.26
                let normalizedX = u * 2 - 1
                let z = profile.depth * sqrt(max(0.02, 1 - normalizedX * normalizedX)) + 0.008
                vertices.append(SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)))
                uv.append(CGPoint(x: u, y: v))
                if row < heightSegments && col < widthSegments {
                    let a = Int32(row * (widthSegments + 1) + col), b = a + 1, c = a + Int32(widthSegments + 1), d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }
        return HeadSurface(vertices: vertices, uv: uv, indices: indices)
    }

    func withSpeakingMouthOpen() -> HeadSurface {
        var deformed = vertices
        for index in deformed.indices {
            let point = deformed[index]
            let x = Double(point.x), y = Double(point.y)
            // With full portrait UVs, the lips sit just below y=-0.4.
            let region = exp(-pow(x / 0.31, 4) - pow((y + 0.45) / 0.075, 4))
            let upper = y >= -0.45 ? 1.0 : -1.0
            deformed[index].y += CGFloat(region * upper * 0.016)
            deformed[index].z += CGFloat(region * 0.01)
        }
        return HeadSurface(vertices: deformed, uv: uv, indices: indices)
    }
}

/// Deterministic irregular samples and short links laid over the continuous surface.
private struct HeadConstellation {
    let points: [SCNVector3]
    let links: [Int32]

    static func make(count: Int) -> HeadConstellation {
        var state: UInt64 = 0x4A4152564953
        func nextUnit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992.0
        }
        var params: [(angle: Double, y: Double)] = []
        var points: [SCNVector3] = []
        params.reserveCapacity(count); points.reserveCapacity(count)
        for _ in 0..<count {
            let angle = nextUnit() * 2 * Double.pi
            let y = -1.84 + nextUnit() * 3.25
            params.append((angle, y))
            points.append(HeadSurface.point(y: y, angle: angle))
        }

        var links: [Int32] = []
        links.reserveCapacity(count * 6)
        for i in 0..<count {
            let a = params[i]
            let width = HeadSurface.profile(at: a.y).width
            var nearest: [(index: Int, distance: Double)] = []
            nearest.reserveCapacity(8)
            for j in 0..<count where j != i {
                let b = params[j]
                var da = abs(a.angle - b.angle)
                if da > Double.pi { da = 2 * Double.pi - da }
                let dy = a.y - b.y
                let distance = sqrt(pow(da * width, 2) + dy * dy)
                if distance < 0.34 { nearest.append((j, distance)) }
            }
            nearest.sort { $0.distance < $1.distance }
            for neighbor in nearest.prefix(3) where i < neighbor.index {
                links.append(Int32(i)); links.append(Int32(neighbor.index))
            }
        }
        return HeadConstellation(points: points, links: links)
    }
}

private final class Coordinator: NSObject, SCNSceneRendererDelegate {
    weak var view: SCNView?
    var speaking = false
    var reduceMotion = false
    var morpher: SCNMorpher?
    private var startYaw: CGFloat = 0
    private var startPitch: CGFloat = 0

    @objc func drag(_ gesture: NSPanGestureRecognizer) {
        guard let view, let rig = view.scene?.rootNode.childNode(withName: "rotationRig", recursively: false) else { return }
        switch gesture.state {
        case .began:
            startYaw = CGFloat(rig.eulerAngles.y); startPitch = CGFloat(rig.eulerAngles.x)
        case .changed:
            let delta = gesture.translation(in: view)
            rig.eulerAngles.y = CGFloat(startYaw + delta.x * 0.009)
            rig.eulerAngles.x = CGFloat(max(-0.42, min(0.42, startPitch + delta.y * 0.005)))
        default: break
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let rig = renderer.scene?.rootNode.childNode(withName: "rotationRig", recursively: false) else { return }
        let front = rig.childNode(withName: "curvedReferenceDetail", recursively: false)
        // Keep the image layer frontal; the native mesh carries all side and rear views.
        let frontLimit = cos(0.72)
        let frontOpacity = max(0, min(1, (cos(Double(rig.eulerAngles.y)) - frontLimit) / (1 - frontLimit)))
        front?.opacity = CGFloat(frontOpacity)
        // The reference itself supplies the front particle detail; reserve procedural
        // wires and points for the turning side and back surfaces.
        rig.childNode(withName: "continuousHeadVolume", recursively: false)?.opacity = CGFloat(1 - frontOpacity)
        rig.childNode(withName: "headConstellation", recursively: false)?.opacity = CGFloat(1 - frontOpacity)
        let mouthAmount = speaking && !reduceMotion ? (sin(time * 8.5) + 1) * 0.5 : 0
        morpher?.setWeight(mouthAmount, forTargetAt: 0)
        if reduceMotion {
            rig.opacity = 1
            return
        }
        let amount = speaking ? 0.025 : 0.006
        let pulse = (sin(time * (speaking ? 8.5 : 1.1)) + 1) * 0.5
        rig.scale = SCNVector3(1 + amount * pulse, 1 + amount * pulse, 1 + amount * pulse)
        rig.opacity = CGFloat(0.94 + pulse * (speaking ? 0.06 : 0.025))
    }
}
