import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension TextStyle {
    /// A rough advance width of `s` in staff spaces, for a serif face (Times-like proportions).
    /// Renderers measure real text; layout only needs this to reserve room and align.
    public func estimatedWidth(of s: String) -> Double {
        var w = 0.0
        for ch in s {
            switch ch {
            case " ": w += 0.25
            case ".", ",", ":", ";", "'", "!", "|": w += 0.28
            case "i", "l", "j", "t", "f": w += 0.3
            case "m", "w", "M", "W": w += 0.8
            case "=": w += 0.56
            default:
                if ch.isNumber { w += 0.5 }
                else if ch.isUppercase { w += 0.68 }
                else { w += 0.46 }
            }
        }
        return w * size * (bold ? 1.08 : 1)
    }
}

extension PathElement {
    /// Control points and the endpoint (for conservative bounds of straight parts).
    fileprivate func flattened(from p0: CGPoint) -> [CGPoint] {
        switch self {
        case .move(let p), .line(let p): return [p]
        case .close: return []
        case .quad(let to, let c):
            return (1...12).map { i in
                let t = Double(i) / 12, u = 1 - t
                return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * to.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * to.y)
            }
        case .curve(let to, let c1, let c2):
            return (1...16).map { i in
                let t = Double(i) / 16, u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * to.x, y: a * p0.y + b * c1.y + c * c2.y + d * to.y)
            }
        }
    }
}

/// The tight bounds of a path: curves are sampled, not bounded by their control points.
func pathBounds(_ els: [PathElement]) -> CGRect {
    var pts: [CGPoint] = []
    var cur = CGPoint.zero
    var start = CGPoint.zero
    for e in els {
        if case .move(let p) = e { start = p }
        let f = e.flattened(from: cur)
        pts += f
        if case .close = e { cur = start } else if let l = f.last { cur = l }
    }
    guard let first = pts.first else { return .null }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

extension LayoutItem {
    /// The ink bounds in layout coordinates: glyphs by their SMuFL boxes, lines with their
    /// thickness (butt caps), paths by their sampled curves (a stroked path is grown by half
    /// its thickness), text by `TextStyle.estimatedWidth`. `.null` for an empty path.
    public var bounds: CGRect {
        switch self {
        case .glyph(let cp, let p, let size, _, _):
            guard let g = Glyph(rawValue: cp) else { return CGRect(origin: p, size: .zero) }
            return g.metrics.box(at: p, size: size)
        case .line(let a, let b, let t, _, _):
            let minX = min(a.x, b.x), maxX = max(a.x, b.x), minY = min(a.y, b.y), maxY = max(a.y, b.y)
            // Butt caps: a vertical stroke grows sideways, a horizontal one up and down, a slanted
            // one both ways (a little too much).
            let vertical = maxX == minX, horizontal = maxY == minY
            let gx = horizontal && !vertical ? 0 : t / 2, gy = vertical && !horizontal ? 0 : t / 2
            return CGRect(x: minX - gx, y: minY - gy, width: maxX - minX + 2 * gx, height: maxY - minY + 2 * gy)
        case .rect(let r, _, _):
            return r
        case .text(let s, let p, let style):
            let w = style.estimatedWidth(of: s)
            let x: Double
            switch style.anchor {
            case .start: x = p.x
            case .middle: x = p.x - w / 2
            case .end: x = p.x - w
            }
            return CGRect(x: x, y: p.y - 0.78 * style.size, width: w, height: 0.78 * style.size + 0.22 * style.size)
        case .path(let els, let stroke, _, _, _):
            let b = pathBounds(els)
            guard !b.isNull else { return b }
            let g = (stroke ?? 0) / 2
            return b.insetBy(dx: -g, dy: -g)
        case .beam(let els, _):
            return pathBounds(els)
        }
    }
}
