#if canImport(UIKit) && DEBUG
    package import UIKit
    import PingFrontCore

    /// Draws the images fixture messages reference (`fixture://…`): abstract avatars (no real people),
    /// app icons and the photos people send, so previews and snapshots render complete without network.
    package enum FixtureImages {
        package static func install() {
            let store = ImageStore.shared
            let images: [(String, () -> UIImage)] =
                [
                    ("att_widget", widgetScreenshot), ("att_page", pageScreenshot), ("att_chart", chartScreenshot),
                    ("att_leaves", leavesPhoto),
                    ("att_landscape", landscapePhoto),
                ] + ["deniz", "mara", "ines", "sam", "theo"].map { id in ("fixture://avatar/\(id)", { portrait(id) }) }
            for (key, make) in images where store.image(for: key) == nil { store.set(make(), for: key) }
        }

        /// A CC0 team portrait the host app bundles as `Avatar<Name>`; a plain initial when the host has none
        /// (host-less snapshot smoke test).
        static func portrait(_ id: String) -> UIImage {
            let name = id.prefix(1).uppercased() + id.dropFirst()
            if let image = UIImage(named: "Avatar\(name)") { return image }
            let size = CGSize(width: 80, height: 80)
            return renderer(size, scale: 3).image { _ in
                rgb(0xD8, 0xD8, 0xDD).setFill()
                UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
                let text = String(name.prefix(1)) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: rgb(0x3C, 0x3C, 0x43),
                ]
                let box = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: (size.width - box.width) / 2, y: (size.height - box.height) / 2), withAttributes: attributes)
            }
        }

        private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
            UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }

        private static func renderer(_ size: CGSize, scale: CGFloat = 1) -> UIGraphicsImageRenderer {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            return UIGraphicsImageRenderer(size: size, format: format)
        }

        /// The icon of an example app (`clockwise`, `fieldnotes`, `stride`, `sprout`).
        package static func appIcon(_ app: String = "clockwise") -> UIImage {
            renderer(CGSize(width: 128, height: 128)).image { context in
                let cg = context.cgContext
                switch app {
                case "fieldnotes":
                    rgb(0x1F, 0x6F, 0x5C).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                    UIColor(white: 1, alpha: 0.95).setFill()
                    UIBezierPath(roundedRect: CGRect(x: 34, y: 24, width: 60, height: 80), cornerRadius: 8).fill()
                    rgb(0x1F, 0x6F, 0x5C).withAlphaComponent(0.5).setFill()
                    for row in 0..<4 { context.fill(CGRect(x: 44, y: 42 + row * 14, width: row == 3 ? 24 : 40, height: 5)) }
                case "stride":
                    rgb(0xE8, 0x59, 0x0C).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: 30, y: 88))
                    path.addLine(to: CGPoint(x: 56, y: 58))
                    path.addLine(to: CGPoint(x: 72, y: 74))
                    path.addLine(to: CGPoint(x: 100, y: 38))
                    path.lineWidth = 12
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    UIColor.white.setStroke()
                    path.stroke()
                case "sprout":
                    rgb(0xFF, 0xE0, 0x66).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                    rgb(0x2E, 0x7D, 0x32).setFill()
                    cg.saveGState()
                    cg.translateBy(x: 64, y: 70)
                    cg.rotate(by: -0.6)
                    UIBezierPath(ovalIn: CGRect(x: -6, y: -42, width: 30, height: 46)).fill()
                    cg.restoreGState()
                    cg.saveGState()
                    cg.translateBy(x: 64, y: 70)
                    cg.rotate(by: 0.7)
                    UIBezierPath(ovalIn: CGRect(x: -22, y: -40, width: 26, height: 40)).fill()
                    cg.restoreGState()
                    context.fill(CGRect(x: 61, y: 66, width: 6, height: 34))
                default:
                    rgb(0x18, 0x23, 0x3F).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                    let ring = UIBezierPath(ovalIn: CGRect(x: 26, y: 26, width: 76, height: 76))
                    ring.lineWidth = 9
                    UIColor.white.setStroke()
                    ring.stroke()
                    let hand = UIBezierPath()
                    hand.move(to: CGPoint(x: 64, y: 64))
                    hand.addLine(to: CGPoint(x: 64, y: 40))
                    hand.move(to: CGPoint(x: 64, y: 64))
                    hand.addLine(to: CGPoint(x: 80, y: 72))
                    hand.lineWidth = 8
                    hand.lineCapStyle = .round
                    hand.stroke()
                    rgb(0xFF, 0xCE, 0x3A).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 92, y: 18, width: 18, height: 18)).fill()
                }
            }
        }

        private static let photoSize = CGSize(width: 390, height: 467)

        /// A home-screen widget with a rendering glitch.
        static func widgetScreenshot() -> UIImage {
            renderer(photoSize, scale: 3).image { context in
                rgb(0xD9, 0xE0, 0xEC).setFill()
                context.fill(CGRect(origin: .zero, size: photoSize))
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: 30, y: 60, width: 330, height: 160), cornerRadius: 24).fill()
                let ink = rgb(0x18, 0x23, 0x3F)
                ("Focus" as NSString).draw(
                    at: CGPoint(x: 54, y: 84),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: ink])
                ("24:00" as NSString).draw(
                    at: CGPoint(x: 54, y: 118),
                    withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 54, weight: .bold), .foregroundColor: ink])
                rgb(0xC2, 0x36, 0x2D).withAlphaComponent(0.85).setFill()
                context.fill(CGRect(x: 30, y: 150, width: 330, height: 10))
                UIColor(white: 1, alpha: 0.9).setFill()
                context.fill(CGRect(x: 140, y: 140, width: 220, height: 6))
                for (index, color) in [rgb(0x35, 0x50, 0xE6), rgb(0x16, 0x80, 0x4F), rgb(0x5A, 0x66, 0x80), rgb(0xFF, 0xCE, 0x3A)]
                    .enumerated()
                {
                    color.setFill()
                    UIBezierPath(roundedRect: CGRect(x: 30 + CGFloat(index) * 88, y: 260, width: 66, height: 66), cornerRadius: 15).fill()
                    color.withAlphaComponent(0.5).setFill()
                    UIBezierPath(roundedRect: CGRect(x: 30 + CGFloat(index) * 88, y: 360, width: 66, height: 66), cornerRadius: 15).fill()
                }
            }
        }

        /// A journal page whose last lines are cut off.
        static func pageScreenshot() -> UIImage {
            renderer(photoSize, scale: 3).image { context in
                rgb(0xF4, 0xF1, 0xEA).setFill()
                context.fill(CGRect(origin: .zero, size: photoSize))
                let ink = rgb(0x2B, 0x2B, 0x2B)
                ("Tuesday, 28 Oct" as NSString).draw(
                    at: CGPoint(x: 36, y: 44),
                    withAttributes: [.font: UIFont(name: "Georgia-Bold", size: 24) ?? .boldSystemFont(ofSize: 24), .foregroundColor: ink])
                ink.withAlphaComponent(0.55).setFill()
                for row in 0..<11 { context.fill(CGRect(x: 36, y: 100 + row * 26, width: row % 4 == 3 ? 200 : 318, height: 7)) }
                rgb(0xC2, 0x36, 0x2D).setFill()
                context.fill(CGRect(x: 0, y: 392, width: 390, height: 3))
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 395, width: 390, height: 72))
            }
        }

        /// A pace chart with a GPS spike.
        static func chartScreenshot() -> UIImage {
            renderer(photoSize, scale: 3).image { context in
                rgb(0x17, 0x17, 0x1C).setFill()
                context.fill(CGRect(origin: .zero, size: photoSize))
                ("Pace" as NSString).draw(
                    at: CGPoint(x: 30, y: 36),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: UIColor.white])
                UIColor(white: 1, alpha: 0.12).setFill()
                for row in 0..<5 { context.fill(CGRect(x: 30, y: 120 + row * 60, width: 330, height: 1)) }
                let path = UIBezierPath()
                let points: [CGFloat] = [300, 290, 296, 284, 288, 140, 286, 280, 276, 282, 270]
                for (index, y) in points.enumerated() {
                    let point = CGPoint(x: 30 + CGFloat(index) * 33, y: y)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.lineWidth = 5
                path.lineJoinStyle = .round
                rgb(0xFF, 0x8A, 0x3D).setStroke()
                path.stroke()
            }
        }

        /// Fern leaves turning yellow.
        ///
        /// A generated landscape (sky, sun, layered hills, a lake): a photo-like image for the photo viewer.
        static func landscapePhoto() -> UIImage {
            let size = CGSize(width: 390, height: 520)
            return renderer(size, scale: 3).image { context in
                let cg = context.cgContext
                let sky = [rgb(0x7F, 0xB2, 0xE5).cgColor, rgb(0xF6, 0xC9, 0x9B).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sky, locations: [0, 1]) {
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 330), options: [.drawsAfterEndLocation])
                }
                rgb(0xFF, 0xE3, 0xA8).setFill()
                UIBezierPath(ovalIn: CGRect(x: 250, y: 150, width: 70, height: 70)).fill()
                let ridges: [(UIColor, CGFloat, CGFloat)] = [
                    (rgb(0x8A, 0x94, 0xB8), 230, 0.9), (rgb(0x5F, 0x77, 0x8F), 270, 1.4), (rgb(0x3F, 0x5E, 0x55), 310, 2.1),
                ]
                for (color, base, phase) in ridges {
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for x in stride(from: 0, through: size.width, by: 6) {
                        path.addLine(to: CGPoint(x: x, y: base - 38 * sin(x / 70 + phase) - 14 * sin(x / 23 + phase * 2)))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.close()
                    color.setFill()
                    path.fill()
                }
                rgb(0x6F, 0x9F, 0xC4).setFill()
                context.fill(CGRect(x: 0, y: 380, width: size.width, height: 140))
                rgb(0xA9, 0xCB, 0xE3).setFill()
                for row in 0..<6 {
                    context.fill(CGRect(x: 40 + CGFloat(row * 47 % 210), y: 396 + CGFloat(row * 19), width: 90, height: 2))
                }
            }
        }

        static func leavesPhoto() -> UIImage {
            renderer(photoSize, scale: 3).image { context in
                rgb(0xE9, 0xE4, 0xD8).setFill()
                context.fill(CGRect(origin: .zero, size: photoSize))
                let cg = context.cgContext
                for index in 0..<7 {
                    let yellow = index % 3 == 0
                    (yellow ? rgb(0xD8, 0xC0, 0x4A) : rgb(0x3E, 0x8E, 0x41)).setFill()
                    cg.saveGState()
                    cg.translateBy(x: 195, y: 430)
                    cg.rotate(by: CGFloat(index - 3) * 0.32)
                    UIBezierPath(ovalIn: CGRect(x: -22, y: -380 + CGFloat(abs(index - 3)) * 40, width: 44, height: 300)).fill()
                    cg.restoreGState()
                }
            }
        }
    }
#endif
