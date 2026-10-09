import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Cursor, hit testing and scrolling: the bridge between the layout and the playback timeline.
// Everything is in layout coordinates (staff spaces, y down); renderers scale it.

/// Where the playback cursor sits: a vertical band over a whole system.
///
/// `x` is the left edge of a standard notehead at the position (the web's staff-entry x). The
/// band is `bandWidth` wide and centred on the notehead column: on `x` plus half a standard
/// (black) notehead's width.
public struct CursorSpot: Sendable, Hashable {
    public var systemIndex: Int
    public var x: Double
    /// The top line of the system's first staff.
    public var top: Double
    /// To the bottom line of its last staff.
    public var height: Double

    public static let bandWidth = 3.0
    /// From `x` to the centre of the notehead column (half a standard black notehead).
    public static let headCentreOffset = Glyph.noteheadBlack.metrics.advance / 2

    public init(systemIndex: Int, x: Double, top: Double, height: Double) {
        self.systemIndex = systemIndex; self.x = x; self.top = top; self.height = height
    }

    /// The band to draw.
    public var bandRect: CGRect {
        CGRect(x: x + Self.headCentreOffset - Self.bandWidth / 2, y: top, width: Self.bandWidth, height: height)
    }

    /// The spot `fraction` (0...1) of the way to `other`, for gliding. Never moves across a
    /// system break, and never backwards (a repeat jump): then the cursor stays on `self`
    /// until `fraction` reaches 1, and lands on `other`. (`ScoreLayout.glideSpot` also holds
    /// on forward jumps over skipped measures.)
    public func interpolated(to other: CursorSpot, fraction: Double) -> CursorSpot {
        if fraction >= 1 { return other }
        guard systemIndex == other.systemIndex, other.x >= x else { return self }
        let t = max(0, fraction)
        return CursorSpot(systemIndex: systemIndex, x: x + (other.x - x) * t, top: top, height: height)
    }
}

/// What a tap landed on.
///
/// `(measureIndex, position)` is the seek key: hand it to MusicCore to find the playback step.
/// `noteID` is for highlighting only and may not appear in the timeline (rests, grace notes);
/// for a grace note, `position` is the main note's onset.
public struct HitResult: Sendable, Hashable {
    /// The tapped note; a shared unison head gives the first note (see `ScoreLayout.sharedHeads`).
    public var noteID: NoteID
    public var measureIndex: Int
    /// Quarters into the measure.
    public var position: Rational
    public var systemIndex: Int
    /// Index into `LaidSystem.staves`.
    public var staffIndex: Int
    /// Index into `Score.parts`.
    public var partIndex: Int
    public var isRest: Bool
    public var isGrace: Bool
}

extension ScoreLayout {
    // MARK: Cursor
    //
    // Consumers should compute one `CursorSpot` per timeline entry per layout (`cursorSpots`)
    // and reuse it, instead of querying on every frame.

    /// The x of a (possibly fractional) position in a measure; see `x(measureIndex:position:)`.
    public func cursorX(measureIndex: Int, position: Double) -> LaidX? {
        // Quarters as a fraction of 5040 (= 7!, divisible by every tuplet and 1...10), so the
        // conversion is exact for musical positions and the nearest 1/5040 otherwise.
        let den = 5040
        let q = Rational(Int((max(0, position) * Double(den)).rounded()), den)
        return x(measureIndex: measureIndex, position: q)
    }

    /// The band's vertical extent for a system: its first staff's top line to its last staff's
    /// bottom line (the staves that were laid out, so a staff selection is respected).
    private func verticalExtent(_ systemIndex: Int) -> (top: Double, height: Double)? {
        guard systems.indices.contains(systemIndex), let f = systems[systemIndex].staves.first,
              let l = systems[systemIndex].staves.last else { return nil }
        return (f.top, l.top + 4 - f.top)
    }

    /// The cursor spot of a position in a measure. Nil when the measure was not laid out.
    /// Works for any position, drawn column or not (it is interpolated).
    public func cursorSpot(measureIndex: Int, position: Rational) -> CursorSpot? {
        guard let p = x(measureIndex: measureIndex, position: position), let v = verticalExtent(p.systemIndex) else { return nil }
        return CursorSpot(systemIndex: p.systemIndex, x: p.x, top: v.top, height: v.height)
    }

    public func cursorSpot(for entry: TimelineEntry) -> CursorSpot? {
        cursorSpot(measureIndex: entry.measureIndex, position: entry.position)
    }

    public func cursorSpot(timeline: Timeline, entryIndex: Int) -> CursorSpot? {
        timeline.entries.indices.contains(entryIndex) ? cursorSpot(for: timeline.entries[entryIndex]) : nil
    }

    /// One spot per timeline entry, in order: precompute this per layout.
    public func cursorSpots(for timeline: Timeline) -> [CursorSpot?] {
        timeline.entries.map { cursorSpot(for: $0) }
    }

    /// The cursor `fraction` (0...1) of the way from `from` to the next entry `to`, for gliding.
    ///
    /// It moves only when `to` is the same played measure or the next one (and the written
    /// measure is the same or the next), on the same system, and not backwards. Otherwise
    /// (a system break, a repeat jump either way, a volta skip) it holds on `from` until
    /// `fraction` reaches 1, then lands on `to`.
    ///
    /// With `to` nil (the last entry) it glides toward the end of the entry's shortest note,
    /// or of the measure for a rest, capped at the closing barline.
    public func glideSpot(from: TimelineEntry, to: TimelineEntry?, fraction: Double) -> CursorSpot? {
        guard let a = cursorSpot(for: from) else { return to.flatMap { cursorSpot(for: $0) } }
        guard let to else {
            let length = from.notes.map(\.quarters).min().map(Self.rational) ?? Rational(1_000_000)
            guard let end = cursorSpot(measureIndex: from.measureIndex, position: from.position + length) else { return a }
            return a.interpolated(to: end, fraction: min(fraction, 1))
        }
        guard let b = cursorSpot(for: to) else { return a }
        let played = to.playedMeasureIndex - from.playedMeasureIndex
        let written = to.measureIndex - from.measureIndex
        guard (0...1).contains(played), (0...1).contains(written) else { return fraction >= 1 ? b : a }
        return a.interpolated(to: b, fraction: fraction)
    }

    private static func rational(_ quarters: Double) -> Rational {
        Rational(Int((max(0, quarters) * 5040).rounded()), 5040)
    }

    // MARK: Hit testing

    /// The system a point belongs to: the one nearest vertically, within a slack of 3 sp or
    /// half the gap to the neighbouring system, whichever is larger. The point must also lie
    /// within the layout's width. The frame is ink, not the tap target.
    private func systemIndex(at point: CGPoint) -> Int? {
        var best: (index: Int, distance: Double)?
        for (i, sys) in systems.enumerated() {
            let f = sys.frame
            guard point.x >= f.minX, point.x <= f.maxX else { continue }
            let above = point.y < f.minY
            let d = above ? f.minY - point.y : max(0, point.y - f.maxY)
            if d > 0 {
                let neighbour = above ? (i > 0 ? systems[i - 1].frame.maxY : nil) : (i + 1 < systems.count ? systems[i + 1].frame.minY : nil)
                let gap = neighbour.map { abs(above ? f.minY - $0 : $0 - f.maxY) } ?? 0
                if d > max(3, gap / 2) { continue }
            }
            if best.map({ d < $0.distance }) ?? true { best = (i, d) }
        }
        return best?.index
    }

    /// The note under or nearest to `point`, in the system it belongs to (see `systemIndex(at:)`).
    /// Nil only outside every system (or in a system without notes).
    ///
    /// Within the system: a notehead box containing the point wins; otherwise the nearest
    /// column in the nearest staff whose x is within `tolerance` (staff spaces); if no staff
    /// has one, the first column at or right of the tap, else the last. In a column,
    /// pitched non-grace notes beat rests and grace notes, then the head vertically nearest.
    /// Ties, beams, stems and text are never targets.
    public func hitTest(_ point: CGPoint, tolerance: Double = 3) -> HitResult? {
        guard let si = systemIndex(at: point), systemNotes.indices.contains(si) else { return nil }
        let all = systemNotes[si]
        guard !all.isEmpty else { return nil }
        let sys = systems[si]
        func rank(_ n: LaidNote) -> Int { n.isRest || n.isGrace ? 1 : 0 }
        func dx(_ n: LaidNote) -> Double { abs(point.x - n.headBox.midX) }
        func dy(_ n: LaidNote) -> Double {
            let b = n.headBox
            return point.y < b.minY ? b.minY - point.y : max(0, point.y - b.maxY)
        }
        func pick(_ column: [LaidNote]) -> HitResult? {
            guard let n = column.min(by: { (rank($0), dy($0), $0.id) < (rank($1), dy($1), $1.id) }) else { return nil }
            let id = sharedHeads[n.id] ?? n.id
            guard let t = noteTimes[id] ?? noteTimes[n.id] else { return nil }
            let staff = sys.staves.indices.contains(n.staffIndex) ? sys.staves[n.staffIndex] : nil
            return HitResult(noteID: id, measureIndex: t.measureIndex, position: t.onset, systemIndex: si,
                             staffIndex: n.staffIndex, partIndex: staff?.partIndex ?? 0, isRest: n.isRest, isGrace: n.isGrace)
        }
        func staffDistance(_ i: Int) -> Double {
            let t = sys.staves[i].top
            return point.y < t ? t - point.y : max(0, point.y - (t + 4))
        }
        let order = sys.staves.indices.sorted { (staffDistance($0), $0) < (staffDistance($1), $1) }
        // A head containing the point.
        // Its column (same staff, same x) competes, so a rest or grace note yields to a pitched note.
        if let ref = all.filter({ $0.headBox.contains(point) && noteTimes[$0.id] != nil }).min(by: { (dx($0), $0.id) < (dx($1), $1.id) }) {
            return pick(all.filter { $0.staffIndex == ref.staffIndex && abs($0.headBox.midX - ref.headBox.midX) <= 0.35 })
        }
        // The nearest column in the nearest staff that has one within tolerance.
        for staff in order {
            let inStaff = all.filter { $0.staffIndex == staff }
            guard let bestDX = inStaff.map(dx).min(), bestDX <= tolerance else { continue }
            return pick(inStaff.filter { dx($0) <= bestDX + 0.35 })
        }
        // Nothing near: the first column at or right of the tap, else the last one.
        for staff in order {
            let inStaff = all.filter { $0.staffIndex == staff }
            guard !inStaff.isEmpty else { continue }
            let right = inStaff.filter { $0.headBox.midX >= point.x }
            let edge = right.isEmpty ? inStaff.map(\.headBox.midX).max()! : right.map(\.headBox.midX).min()!
            return pick(inStaff.filter { abs($0.headBox.midX - edge) <= 0.35 })
        }
        return nil
    }

    /// The measure under `point`: for the results heatmap and "practise this measure". Any
    /// point in a system's tap area (see `hitTest`) gives a measure (left of the first one,
    /// the first; right of the last, the last). Nil outside every system.
    public func hitTestMeasure(_ point: CGPoint) -> Int? {
        guard let si = systemIndex(at: point) else { return nil }
        let ms = systems[si].measures
        guard !ms.isEmpty else { return nil }
        return (ms.first { point.x < $0.barX } ?? ms[ms.count - 1]).index
    }

    // MARK: Measures, systems and scrolling

    /// The index of the system holding a measure; nil when it was not laid out.
    public func systemIndex(forMeasure index: Int) -> Int? { measureLocations[index]?.systemIndex }

    public func systemFrame(_ index: Int) -> CGRect? {
        systems.indices.contains(index) ? systems[index].frame : nil
    }

    /// The horizontal extent of a measure on its system, from just after the previous barline
    /// (the system's left edge for the first) to its closing barline.
    public func measureXRange(_ index: Int) -> ClosedRange<Double>? {
        guard let loc = measureLocations[index] else { return nil }
        let m = systems[loc.systemIndex].measures[loc.slot]
        return m.x0...m.barX
    }

    /// The horizontal scroll offset of a line view that keeps the cursor at `anchor` (0.2:
    /// a fifth of the way across) of the viewport, clamped to the content. `x` and
    /// `viewportWidth` are in the same units as the layout (scale both to staff spaces).
    public func scrollOffset(forCursorX x: Double, viewportWidth: Double, anchor: Double = 0.2) -> Double {
        let maxOffset = max(0, Double(size.width) - viewportWidth)
        return min(max(0, x - anchor * viewportWidth), maxOffset)
    }

    public func scrollOffset(for spot: CursorSpot, viewportWidth: Double, anchor: Double = 0.2) -> Double {
        scrollOffset(forCursorX: spot.x, viewportWidth: viewportWidth, anchor: anchor)
    }
}
