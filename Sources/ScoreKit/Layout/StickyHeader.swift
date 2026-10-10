import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The clef, key and time signature pinned at the left edge of a scrolled line. It is laid out like the
/// system start itself (the brace and barline, then clef, key and time at the start's own offsets), so
/// pinning it at scroll 0 changes nothing. `layout` holds one system of furniture in the line's own
/// x coordinates (0 to `width`) and y, so the same renderer draws it at the viewport's left edge; the
/// caller puts an opaque background behind it.
public struct StickyHeader: Sendable {
    public var width: Double
    public var contexts: [StaffContext]
    public var layout: ScoreLayout
}

extension ScoreLayout {
    /// The clef, key and time of each staff of `system` (`LaidSystem.staves` order) in effect at `x`:
    /// the latest change at or left of it (the first measure's start when `x` is left of everything).
    /// Empty without a system.
    public func stickyContext(atX x: Double, system: Int = 0) -> [StaffContext] {
        guard systems.indices.contains(system) else { return [] }
        let steps = systems[system].contextSteps
        guard !steps.isEmpty else { return [] }
        var lo = 0, hi = steps.count - 1   // the last step with x <= query
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if steps[mid].x <= x { lo = mid } else { hi = mid - 1 }
        }
        return steps[lo].contexts
    }

    /// Where the furniture of a header for `contexts` ends, and the offsets of the key and time.
    private func headerMetrics(_ contexts: [StaffContext], system: Int) -> (clefX: Double, keyX: Double, timeX: Double, width: Double)? {
        guard systems.indices.contains(system), let x0 = systems[system].measures.first?.x0, !contexts.isEmpty else { return nil }
        var clefW = 0.0, keyW = 0.0, timeW = 0.0
        for c in contexts {
            clefW = max(clefW, ClefShape(c.clef).glyph.metrics.advance)
            keyW = max(keyW, Engraving.keySignature(c.key, clef: c.clef, from: nil, x: 0).width)
            timeW = max(timeW, c.time.map(Engraving.timeSignatureWidth) ?? 0)
        }
        // The system start's plan: a gap of 0.7 before each part and after it.
        var cursor = x0 + 0.7
        let clefX = cursor; cursor += clefW + 0.7
        let keyX = cursor; if keyW > 0 { cursor += keyW + 0.7 }
        let timeX = cursor; if timeW > 0 { cursor += timeW + 0.7 }
        return (clefX, keyX, timeX, cursor)
    }

    /// The contexts the header of a line scrolled to `x` shows, nil while it is not scrolled (the real
    /// start is in view). They are those in effect at the header's right edge, so a change hidden under
    /// the header is already in it (found by one more pass, as the header's width depends on them).
    public func stickyHeaderContexts(atX x: Double, system: Int = 0) -> [StaffContext]? {
        guard x > 0, systems.indices.contains(system), systems[system].measures.first != nil else { return nil }
        let first = stickyContext(atX: x, system: system)
        guard let w = headerMetrics(first, system: system)?.width else { return nil }
        return stickyContext(atX: x + w, system: system)
    }

    /// The widest header of the system, in staff spaces.
    public func maxStickyHeaderWidth(system: Int = 0) -> Double {
        guard systems.indices.contains(system) else { return 0 }
        var seen = Set<[StaffContext]>()
        return systems[system].contextSteps.filter { seen.insert($0.contexts).inserted }
            .compactMap { headerMetrics($0.contexts, system: system)?.width }.max() ?? 0
    }

    /// The header for a line scrolled so that `x` is at its left edge; nil while the line is not scrolled.
    public func stickyHeader(atX x: Double, system: Int = 0) -> StickyHeader? {
        stickyHeaderContexts(atX: x, system: system).flatMap { stickyHeader(for: $0, system: system) }
    }

    /// The header for these contexts (one per staff of `system`).
    public func stickyHeader(for contexts: [StaffContext], system: Int = 0) -> StickyHeader? {
        guard let m = headerMetrics(contexts, system: system), systems[system].staves.count == contexts.count,
              let x0 = systems[system].measures.first?.x0 else { return nil }
        let sys = systems[system]
        var items = sys.leftFurniture
        for (c, staff) in zip(contexts, sys.staves) {
            var local: [LayoutItem] = (0..<5).map {
                .line(from: CGPoint(x: x0, y: Double($0)), to: CGPoint(x: m.width, y: Double($0)), thickness: EngravingDefaults.staffLineThickness)
            }
            local.append(Engraving.clefItem(c.clef, x: m.clefX))
            local += Engraving.keySignature(c.key, clef: c.clef, from: nil, x: m.keyX).items
            if let t = c.time { local += Engraving.timeSignature(t, x: m.timeX) }
            items += local.map { $0.translated(dy: staff.top) }
        }
        var header = sys
        header.items = items
        header.columns = []
        header.measures = []
        header.marks = []
        header.leftFurniture = []
        header.contextSteps = []
        header.frame = CGRect(x: 0, y: sys.frame.minY, width: m.width, height: sys.frame.height)
        let layout = ScoreLayout(size: CGSize(width: m.width, height: sys.frame.maxY), systems: [header], notes: [:], noteBoxes: [:],
                                 groups: [:], beams: [:], sharedHeads: [:])
        return StickyHeader(width: m.width, contexts: contexts, layout: layout)
    }
}
