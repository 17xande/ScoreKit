
import Foundation

/// A measure's rectangle in layout coordinates (staff spaces), across all the staves of its system.
public struct MeasureFrame: Sendable, Equatable {
    public var index: Int
    public var minX: Double, maxX: Double, minY: Double, maxY: Double
    public init(index: Int, minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.index = index; self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
    }
}

extension ScoreLayout {
    /// Every laid-out measure's frame: its horizontal extent on the system and the staves' height plus
    /// a margin (what the heat tints and the range fade cover).
    public var measureFrames: [MeasureFrame] {
        systems.flatMap { sys -> [MeasureFrame] in
            guard let first = sys.staves.first, let last = sys.staves.last else { return [] }
            return sys.measures.map {
                MeasureFrame(index: $0.index, minX: $0.x0, maxX: $0.barX, minY: first.top - 2, maxY: last.top + 6)
            }
        }
    }
}

/// The pure logic of selecting a measure range by dragging over the score.
public enum MeasureSelection {
    /// The measure under a point. Inside a frame it is that frame; otherwise the point snaps to the
    /// system (row of frames) nearest vertically, then the frame nearest horizontally in it, so a drag
    /// that strays into a margin or between systems still selects something. Nil with no frames.
    public static func measure(at p: CGPoint, in frames: [MeasureFrame]) -> Int? {
        var best: MeasureFrame?
        var bestDy = Double.infinity, bestDx = Double.infinity
        for f in frames {
            let dy = p.y < f.minY ? f.minY - p.y : p.y > f.maxY ? p.y - f.maxY : 0
            let dx = p.x < f.minX ? f.minX - p.x : p.x > f.maxX ? p.x - f.maxX : 0
            if dy < bestDy || (dy == bestDy && dx < bestDx) { best = f; bestDy = dy; bestDx = dx }
        }
        return best?.index
    }

    /// The span between two measures, whichever way it was dragged.
    public static func span(_ a: Int, _ b: Int) -> ClosedRange<Int> { min(a, b)...max(a, b) }

    /// The 0-based measures outside the practice range `from...to` (1-based, inclusive; nil is the
    /// piece's end) of `count` measures. Empty when the range is the whole piece.
    public static func outside(count: Int, from: Int?, to: Int?) -> Set<Int> {
        let a = from ?? 1, b = to ?? count
        if a <= 1 && b >= count { return [] }
        return Set((0..<max(0, count)).filter { $0 + 1 < a || $0 + 1 > b })
    }
}
