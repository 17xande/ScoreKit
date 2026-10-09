import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One tie to draw, paired up from the notes' `<tied>` marks before the layout runs.
/// Full: both ends. Start only: a half tie to the right (let-ring, abandoned, over a repeat).
/// End only: an incoming half tie (its start was dropped, e.g. across a repeat or into ending 2).
struct TieSpec {
    var start: NoteID?
    var end: NoteID?
    var startMeasure: Int?
    var endMeasure: Int?
    /// The id drawn tie items carry: the start note's, else the end note's.
    var tag: NoteID { (start ?? end)! }
}

extension Engraving {
    /// Pairs ties the way the timeline does (OSMD's reader): per (part, staff), a tie stop takes
    /// the oldest open start of the same step and octave, else of the same MIDI number (so
    /// C#4 to Db4 ties). `continue` is a stop and a start. A start with no partner, a
    /// `let-ring`, a tie that would span more than the next measure, and a tie that crosses a
    /// closing repeat or volta end become half ties; a stop left without its start becomes an
    /// incoming half tie.
    static func pairTies(_ score: Score, parts: [Int]) -> [TieSpec] {
        var out: [TieSpec] = []
        for pi in parts {
            let measures = score.parts[pi].measures
            func breaksAfter(_ m: Int) -> Bool {
                measures[m].barlines.contains { b in
                    b.location == .right && (b.repeatMark?.direction == .backward
                                             || b.ending.map { $0.kind == .stop || $0.kind == .discontinue } == true)
                }
            }
            struct Item { var note: Note; var measure: Int }
            var all: [Item] = []
            for (mi, m) in measures.enumerated() {
                let sorted = m.notes.enumerated().sorted { ($0.element.onset, $0.offset) < ($1.element.onset, $1.offset) }
                for (_, n) in sorted where !n.isRest && !n.isGrace && n.printObject { all.append(Item(note: n, measure: mi)) }
            }
            func samePitch(_ a: Note, _ b: Note) -> Bool {
                switch (a.kind, b.kind) {
                case (.pitched(let p), .pitched(let q)): return p.step == q.step && p.octave == q.octave
                case (.unpitched(let s, let o), .unpitched(let t, let u)): return s == t && o == u
                default: return false
                }
            }
            func find(_ list: [Item], _ n: Note) -> Int? {
                if let i = list.firstIndex(where: { samePitch($0.note, n) }) { return i }
                guard let m = n.pitch?.midi else { return nil }
                return list.firstIndex { $0.note.pitch?.midi == m }
            }
            var open: [Int: [Item]] = [:]
            func abandon(_ it: Item) {
                out.append(TieSpec(start: it.note.id, end: nil, startMeasure: it.measure, endMeasure: nil))
            }
            func orphan(_ it: Item) {
                out.append(TieSpec(start: nil, end: it.note.id, startMeasure: nil, endMeasure: it.measure))
            }
            for it in all {
                let n = it.note
                let stops = n.drawnTieStop || n.drawnTieContinue
                let starts = n.drawnTieStart || n.drawnTieContinue
                if stops {
                    var list = open[n.staff] ?? []
                    while let f = list.first, it.measure - f.measure > 1 { abandon(f); list.removeFirst() }
                    if let i = find(list, n) {
                        let f = list.remove(at: i)
                        if it.measure != f.measure, breaksAfter(f.measure) { abandon(f); orphan(it) }
                        else {
                            out.append(TieSpec(start: f.note.id, end: n.id, startMeasure: f.measure, endMeasure: it.measure))
                        }
                    } else {
                        orphan(it)
                    }
                    open[n.staff] = list
                }
                if n.drawnTieLetRing, !starts { abandon(it) }
                else if starts { open[n.staff, default: []].append(it) }
            }
            for list in open.values { for it in list { abandon(it) } }
        }
        return out.sorted { $0.tag < $1.tag }
    }

    /// Where a note's head is, for ties: the placed group and the index into its notes.
    private struct HeadRef { var pi: Int; var ni: Int }

    private func headBox(_ pg: PlacedGroup, _ ni: Int) -> CGRect {
        let g = pg.group
        let size: Double? = g.scale == 1 ? nil : g.size
        let n = g.notes[ni]
        let origin = CGPoint(x: pg.x + g.baseDX + n.dx, y: StaffGeometry.y(n.p))
        return g.head.metrics.box(at: origin, size: size)
    }

    /// Whether the tie of the note at `ni` of the group curves up. Single voice: opposite to the
    /// stem; in a chord the notes split by position: the upper half curve up and the lower half
    /// down (an odd count leaves the middle note to the usual rule: below the middle line down,
    /// above it up, on it opposite the stem). With two voices ties go on the stem side, away
    /// from the other voice.
    static func tieAbove(_ g: Group, _ ni: Int) -> Bool {
        if g.multiVoice { return g.stemUp }
        let n = g.notes.count
        if n > 1 {
            if ni > n / 2 || (n % 2 == 0 && ni == n / 2) { return true }
            if ni < n / 2 { return false }
            // The middle note of an odd chord.
            let p = g.notes[ni].p
            if p > 4 { return true }
            if p < 4 { return false }
        }
        return !g.stemUp
    }

    /// The filled crescent of a tie between two points (staff-local), bulging up or down.
    /// `inner` ties (inside a chord) are flatter. Thickness follows Bravura's tie endpoint and
    /// midpoint thicknesses; the height is nudged so the apex stays off the staff lines.
    static func tiePath(x1: Double, y1: Double, x2: Double, y2: Double, above: Bool, inner: Bool = false,
                        height: Double? = nil) -> [PathElement] {
        let len = x2 - x1
        let dir = above ? -1.0 : 1.0
        let end = EngravingDefaults.tieEndpointThickness, mid = EngravingDefaults.tieMidpointThickness
        var h = inner ? min(0.5, 0.3 + 0.03 * len) : min(1.2, 0.3 + 0.075 * len)
        let yAvg = (y1 + y2) / 2
        func onLine(_ y: Double) -> Bool { let r = y.rounded(); return r >= 0 && r <= 4 && abs(y - r) < 0.08 }
        // Keep the apexes (outer and inner edge) off the staff lines: the nearest height that clears them.
        let base = h
        if height != nil { h = height! }
        else { for d in [0.0, -0.05, 0.05, -0.1, 0.1, -0.15, 0.15, -0.2, 0.2, 0.3] {
            let c = max(0.25, base + d)
            if !onLine(yAvg + dir * c) && !onLine(yAvg + dir * (c - mid)) { h = c; break }
        } }
        // A cubic's midpoint is 3/4 of the way to its controls' offset.
        let kOut = h / 0.75
        let kIn = max(0.05, kOut - (mid - end) / 0.75)
        let cx1 = x1 + len * 0.28, cx2 = x2 - len * 0.28
        return [
            .move(CGPoint(x: x1, y: y1)),
            .curve(to: CGPoint(x: x2, y: y2), control1: CGPoint(x: cx1, y: y1 + dir * kOut), control2: CGPoint(x: cx2, y: y2 + dir * kOut)),
            .line(CGPoint(x: x2, y: y2 - dir * end)),
            .curve(to: CGPoint(x: x1, y: y1 - dir * end), control1: CGPoint(x: cx2, y: y2 - dir * end + dir * kIn),
                   control2: CGPoint(x: cx1, y: y1 - dir * end + dir * kIn)),
            .close,
        ]
    }

    /// The left edge of the leftmost accidental of the group whose box reaches height `y`.
    private func accidentalLimit(_ pg: PlacedGroup, y: Double) -> Double? {
        let g = pg.group
        let size: Double? = g.scale == 1 ? nil : g.size
        let leftmost = pg.x + (g.leftEdge ?? (g.baseDX + (g.notes.map(\.dx).min() ?? 0)))
        var limit: Double?
        for n in g.notes {
            guard let acc = n.acc, n.sharedWith == nil else { continue }
            var right = leftmost - 0.2 * g.scale
            for j in 0..<n.accCol { right -= g.accColW[j] }
            let pl = Glyph.accidentalParensLeft.metrics.advance * g.scale
            let pr = Glyph.accidentalParensRight.metrics.advance * g.scale
            let bw = acc.metrics.advance * g.scale + (n.parens ? pl + pr : 0)
            let cx = right - bw
            let box = acc.metrics.box(at: CGPoint(x: cx + (n.parens ? pl : 0), y: StaffGeometry.y(n.p)), size: size)
            if y >= box.minY - 0.15, y <= box.maxY + 0.15 { limit = min(limit ?? cx, cx) }
        }
        return limit
    }

    /// Ties of one system: whole ties between two heads, a half tie out of the system's end and
    /// one into its start for ties across a system break, and short half ties.
    /// Every tie item carries the *start* note's id (the end note's for a tie whose start was
    /// dropped); see `LayoutItem`.
    func layoutTies(range: Range<Int>, placed: [PlacedGroup], measures: [MeasureData], laid: [LaidMeasure],
                    bufs: inout [StaffBuffer]) {
        var ref: [NoteID: HeadRef] = [:]
        for (pi, pg) in placed.enumerated() where !pg.group.isRest && !pg.group.grace {
            for (ni, n) in pg.group.notes.enumerated() { ref[n.note.id] = HeadRef(pi: pi, ni: ni) }
        }
        func laidMeasure(_ m: Int) -> LaidMeasure? { laid.first { $0.index == m } }
        func barLeft(_ m: Int) -> Double {
            guard let lm = laidMeasure(m) else { return 0 }
            return lm.barX - (measures[m].endFixed - measures[m].endClefW)
        }
        let gap = 0.15
        func isInner(_ pg: PlacedGroup, _ ni: Int) -> Bool {
            !pg.group.multiVoice && pg.group.notes.count > 2 && ni > 0 && ni < pg.group.notes.count - 1
        }
        func startX(_ pg: PlacedGroup, _ ni: Int, above: Bool) -> Double {
            let g = pg.group
            var x = headBox(pg, ni).maxX
            if g.dots > 0 {
                let maxDX = g.notes.map(\.dx).max() ?? 0
                let first = pg.x + g.baseDX + maxDX + g.headWidth + 0.4 * g.scale + g.dotExtra
                x = max(x, first + Double(g.dots - 1) * 0.55 * g.scale + 0.4 * g.scale)
            }
            if above, let s = pg.stem, s.up { x = max(x, s.x + s.thickness / 2 + 0.05) }
            return x + gap
        }
        func tieY(_ pg: PlacedGroup, _ ni: Int, above: Bool) -> Double {
            let p = pg.group.notes[ni].p
            // On a line the tie leaves from the space beside the head; in a space, just past the lines.
            let off = p % 2 == 0 ? 0.55 : 0.64
            return StaffGeometry.y(p) + (above ? -off : off)
        }
        func endX(_ pg: PlacedGroup, _ ni: Int, above: Bool) -> Double {
            var x = headBox(pg, ni).minX
            if !above, let s = pg.stem, !s.up { x = min(x, s.x - s.thickness / 2 - 0.05) }
            if let a = accidentalLimit(pg, y: tieY(pg, ni, above: above)) { x = min(x, a) }
            return x - gap
        }
        func emit(_ spec: TieSpec, _ els: [PathElement], slot: Int) {
            bufs[slot].items.append(.path(els, stroke: nil, fill: true, noteID: spec.tag))
        }
        /// A path between two x, never dropped: a tiny gap gets a minimal tie centred in it.
        func span(_ x1: Double, _ x2: Double) -> (Double, Double) {
            if x2 - x1 >= 0.6 { return (x1, x2) }
            let c = (x1 + x2) / 2
            return (c - 0.3, c + 0.3)
        }
        // Ties between the same two chords in the same direction are nested copies of one arc: the
        // same ends and the same rise, one head spacing apart (so they never cross), the rise
        // fitted to the outermost.
        struct Pair: Hashable { var s: Int; var e: Int }
        var common: [Pair: (x1: Double, x2: Double, h: Double)] = [:]
        for spec in ties {
            guard let sr = spec.start.flatMap({ ref[$0] }), let er = spec.end.flatMap({ ref[$0] }),
                  spec.startMeasure.map(range.contains) ?? false, spec.endMeasure.map(range.contains) ?? false,
                  sr.pi != er.pi, placed[sr.pi].slotIndex == placed[er.pi].slotIndex else { continue }
            let above = Self.tieAbove(placed[sr.pi].group, sr.ni)
            let key = Pair(s: sr.pi, e: er.pi)
            let x1 = startX(placed[sr.pi], sr.ni, above: above), x2 = endX(placed[er.pi], er.ni, above: above)
            let h = min(1.2, 0.3 + 0.075 * (x2 - x1))
            if let c = common[key] { common[key] = (max(c.x1, x1), min(c.x2, x2), min(c.h, h)) } else { common[key] = (x1, x2, h) }
        }
        var groupSize: [Pair: Int] = [:]
        for spec in ties {
            guard let sr = spec.start.flatMap({ ref[$0] }), let er = spec.end.flatMap({ ref[$0] }) else { continue }
            let key = Pair(s: sr.pi, e: er.pi)
            if common[key] != nil { groupSize[key, default: 0] += 1 }
        }
        for spec in ties {
            let startHere = spec.startMeasure.map(range.contains) ?? false
            let endHere = spec.endMeasure.map(range.contains) ?? false
            guard startHere || endHere else { continue }
            let startRef = spec.start.flatMap { ref[$0] }
            let endRef = spec.end.flatMap { ref[$0] }
            if let s = startRef, startHere {
                let pg = placed[s.pi]
                let above = Self.tieAbove(pg.group, s.ni)
                let inner = isInner(pg, s.ni)
                let x1 = startX(pg, s.ni, above: above)
                let y1 = tieY(pg, s.ni, above: above)
                if let e = endRef, endHere, e.pi != s.pi, placed[e.pi].slotIndex == pg.slotIndex {
                    let epg = placed[e.pi]
                    let key = Pair(s: s.pi, e: e.pi)
                    if let c = common[key], groupSize[key, default: 0] > 1 {
                        let (a, b) = span(c.x1, c.x2)
                        emit(spec, Self.tiePath(x1: a, y1: y1, x2: b, y2: tieY(epg, e.ni, above: above), above: above, inner: inner,
                                                 height: inner ? min(c.h, min(0.5, 0.3 + 0.03 * (b - a))) : c.h), slot: pg.slotIndex)
                        continue
                    }
                    let x2 = endX(epg, e.ni, above: above)
                    let (a, b) = span(x1, x2)
                    emit(spec, Self.tiePath(x1: a, y1: y1, x2: b, y2: tieY(epg, e.ni, above: above), above: above, inner: inner), slot: pg.slotIndex)
                    continue
                }
                // Half tie to the right: short, ending before the barline of the measure.
                let limit = barLeft(spec.startMeasure!) - 0.15
                let length = spec.end == nil ? 2.2 : 4.0
                let x2 = min(x1 + length, max(limit, x1 + 1.0))
                emit(spec, Self.tiePath(x1: x1, y1: y1, x2: x2, y2: y1, above: above, inner: inner), slot: pg.slotIndex)
            } else if let e = endRef, endHere, !startHere {
                // The start is on an earlier system, or gone: the tie arrives from the left.
                let epg = placed[e.pi]
                let above = Self.tieAbove(epg.group, e.ni)
                let x2 = endX(epg, e.ni, above: above)
                let first = laidMeasure(range.lowerBound)?.bodyStart ?? (x2 - 2)
                let x1 = min(max(x2 - 2.2, first - 0.2), x2 - 1.0)
                let yy = tieY(epg, e.ni, above: above)
                emit(spec, Self.tiePath(x1: x1, y1: yy, x2: x2, y2: yy, above: above, inner: isInner(epg, e.ni)), slot: epg.slotIndex)
            }
        }
    }
}
