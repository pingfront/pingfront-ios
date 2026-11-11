#if canImport(UIKit)
    import SwiftUI

    /// A Messages-style bubble: a rounded body with a tail at the bottom corner on the last bubble of a
    /// group.
    ///
    /// The tail side always reserves `tailWidth`, so tailed and untailed bubbles line up.
    /// Drawn for a trailing tail and mirrored for leading; apply `.flipsForRightToLeftLayoutDirection(true)`.
    nonisolated struct BubbleShape: Shape {
        var radius: CGFloat
        var tail: Bool
        var trailing: Bool
        var tailWidth: CGFloat = 6

        func path(in rect: CGRect) -> Path {
            let w = rect.width
            let h = rect.height
            let bw = w - tailWidth
            let hb = tail ? h - 1.5 : h
            let r = max(0, min(radius, hb / 2, bw / 2))
            var p = Path()
            p.move(to: CGPoint(x: r, y: 0))
            p.addLine(to: CGPoint(x: bw - r, y: 0))
            p.addArc(tangent1End: CGPoint(x: bw, y: 0), tangent2End: CGPoint(x: bw, y: r), radius: r)
            if tail {
                let start = max(r, hb - max(14, r * 0.8))
                p.addLine(to: CGPoint(x: bw, y: start))
                // Outer edge sweeps down and out to the tip, then the inner edge hooks back into the bottom.
                p.addCurve(
                    to: CGPoint(x: w, y: h), control1: CGPoint(x: bw, y: hb - 3), control2: CGPoint(x: bw + tailWidth * 0.55, y: h - 0.3))
                p.addCurve(to: CGPoint(x: bw - 9, y: hb), control1: CGPoint(x: bw + 0.5, y: h + 0.4), control2: CGPoint(x: bw - 4, y: hb))
            } else {
                p.addLine(to: CGPoint(x: bw, y: hb - r))
                p.addArc(tangent1End: CGPoint(x: bw, y: hb), tangent2End: CGPoint(x: bw - r, y: hb), radius: r)
            }
            p.addLine(to: CGPoint(x: r, y: hb))
            p.addArc(tangent1End: CGPoint(x: 0, y: hb), tangent2End: CGPoint(x: 0, y: hb - r), radius: r)
            p.addLine(to: CGPoint(x: 0, y: r))
            p.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: r, y: 0), radius: r)
            p.closeSubpath()
            guard !trailing else { return p.offsetBy(dx: rect.minX, dy: rect.minY) }
            return p.applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0)).offsetBy(dx: rect.minX, dy: rect.minY)
        }
    }
#endif
