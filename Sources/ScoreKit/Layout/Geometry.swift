import Foundation

// Layout geometry uses Foundation's CGPoint/CGSize/CGRect (corelibs Foundation on Linux).
// It is in staff spaces (sp), x right, y down, origin at the top-left of the
// layout. Renderers scale it. Glyph metrics (Glyphs.swift) are SMuFL's, y up; conversion
// happens in `GlyphMetrics.box(at:size:)`.

extension CGPoint {
    func offset(dx: Double = 0, dy: Double = 0) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}

/// One segment of a `.path` item. Enough for beams (polygons), ties and slurs (beziers).
public enum PathElement: Sendable, Hashable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(to: CGPoint, control: CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
    case close

    func translated(dy: Double) -> PathElement {
        switch self {
        case .move(let p): .move(p.offset(dy: dy))
        case .line(let p): .line(p.offset(dy: dy))
        case .quad(let to, let c): .quad(to: to.offset(dy: dy), control: c.offset(dy: dy))
        case .curve(let to, let c1, let c2):
            .curve(to: to.offset(dy: dy), control1: c1.offset(dy: dy), control2: c2.offset(dy: dy))
        case .close: .close
        }
    }
}

public struct TextStyle: Sendable, Hashable {
    public enum Anchor: Sendable, Hashable { case start, middle, end }
    /// Font size in staff spaces.
    public var size: Double
    public var italic = false
    public var bold = false
    public var anchor: Anchor = .start

    public init(size: Double, italic: Bool = false, bold: Bool = false, anchor: Anchor = .start) {
        self.size = size; self.italic = italic; self.bold = bold; self.anchor = anchor
    }
}

/// SMuFL metrics of one glyph, y up from the glyph origin, in staff spaces at the standard
/// 4 sp em.
public struct GlyphMetrics: Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double
    public var advance: Double
    public var anchors: [String: CGPoint]

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    /// The glyph's bounding box in layout coordinates (y down) when its origin is at `origin`
    /// and it is drawn with an em of `size` sp (nil is the standard 4).
    public func box(at origin: CGPoint, size: Double? = nil) -> CGRect {
        let k = (size ?? Glyph.standardSize) / Glyph.standardSize
        return CGRect(x: origin.x + minX * k, y: origin.y - maxY * k, width: width * k, height: height * k)
    }

    /// An anchor in layout coordinates (y down), relative to the glyph origin.
    public func anchor(_ name: String, size: Double? = nil) -> CGPoint? {
        guard let a = anchors[name] else { return nil }
        let k = (size ?? Glyph.standardSize) / Glyph.standardSize
        return CGPoint(x: a.x * k, y: -a.y * k)
    }
}

extension Glyph {
    /// The em of a standard-size glyph: 4 staff spaces.
    public static let standardSize: Double = 4
    public var codepoint: UInt32 { rawValue }
}
