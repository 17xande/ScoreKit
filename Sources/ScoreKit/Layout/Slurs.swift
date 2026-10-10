import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One slur to draw: a start and a stop paired up from the notes' `<slur>` marks.
struct SlurSpec {
    var start: NoteID
    var end: NoteID
    var part: Int
    var startStaff: Int
    var endStaff: Int
    var voice: String
    var startVoice: String
    var startMeasure: Int
    var endMeasure: Int
    var startOnset: Rational
    var endOnset: Rational
    /// `placement`/`orientation` of the file, nil when it says nothing.
    var above: Bool?
    /// An end is a grace note: such a slur goes head to head, on the side opposite the grace stem.
    var grace: Bool
}

extension Engraving {
    /// Pairs slur starts and stops per part by `number` (a stop takes the open start of its
    /// number; the pairs cross staves and voices). A start with no stop, a stop with no start and
    /// a slur that starts and stops on one note are dropped. A grace note counts as just before
    /// the note it belongs to, and at one position stops come before starts, so a slur can end
    /// where the next begins.
    static func pairSlurs(_ score: Score, parts: [Int]) -> [SlurSpec] {
        var out: [SlurSpec] = []
        for pi in parts {
            struct Event { var note: Note; var measure: Int; var phase: Int; var order: Int }
            var events: [Event] = []
            for (mi, m) in score.parts[pi].measures.enumerated() {
                for (oi, n) in m.notes.enumerated() where !n.slurs.isEmpty && n.printObject {
                    // Graces first; then the stops of ordinary notes; then their starts.
                    if n.isGrace { events.append(Event(note: n, measure: mi, phase: 0, order: oi)) }
                    else {
                        if n.slurs.contains(where: { $0.kind == .stop }) { events.append(Event(note: n, measure: mi, phase: 1, order: oi)) }
                        if n.slurs.contains(where: { $0.kind == .start }) { events.append(Event(note: n, measure: mi, phase: 2, order: oi)) }
                    }
                }
            }
            events.sort { a, b in
                if (a.measure, a.note.onset) != (b.measure, b.note.onset) { return (a.measure, a.note.onset) < (b.measure, b.note.onset) }
                return (a.phase, a.order) < (b.phase, b.order)
            }
            // Writers reuse one number for slurs of different staves and voices, so a stop takes the
            // latest open start of its number in its own voice and staff, else its voice, else its staff, else any.
            var open: [(number: Int, note: Note, measure: Int, above: Bool?)] = []
            for e in events {
                for s in e.note.slurs {
                    if e.phase == 1, s.kind != .stop { continue }
                    if e.phase == 2, s.kind != .start { continue }
                    switch s.kind {
                    case .start:
                        open.removeAll { $0.number == s.number && $0.note.staff == e.note.staff && $0.note.voice == e.note.voice }
                        open.append((s.number, e.note, e.measure, s.above))
                    case .stop:
                        let same = open.indices.filter { open[$0].number == s.number }
                        guard let i = same.last(where: { open[$0].note.staff == e.note.staff && open[$0].note.voice == e.note.voice })
                                ?? same.last(where: { open[$0].note.voice == e.note.voice })
                                ?? same.last(where: { open[$0].note.staff == e.note.staff }) ?? same.last else { continue }
                        let o = open.remove(at: i)
                        guard o.note.id != e.note.id else { continue }
                        out.append(SlurSpec(start: o.note.id, end: e.note.id, part: pi, startStaff: o.note.staff, endStaff: e.note.staff,
                                            voice: o.note.voice, startVoice: o.note.voice, startMeasure: o.measure, endMeasure: e.measure,
                                            startOnset: o.note.onset, endOnset: e.note.onset, above: o.above ?? s.above,
                                            grace: o.note.isGrace || e.note.isGrace))
                    case .continue:
                        break
                    }
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Which side a slur curves to (Gould): where the file says; with two voices on the staff, the
    /// stem side of the slur's voice (the upper voice above); otherwise on the notehead side, so
    /// below when every stem it spans points up and above when they point down or are mixed.
    func slurAbove(_ s: SlurSpec, measures: [MeasureData]) -> Bool {
        // Grace notes have stems up: their slur is on the heads, below (whatever the file says).
        if s.grace { return false }
        if let a = s.above { return a }
        guard let si = slots.firstIndex(of: Slot(part: s.part, staff: s.startStaff)) else { return true }
        var up = 0, down = 0
        var multi = false
        var first: Bool?
        for m in s.startMeasure...max(s.startMeasure, s.endMeasure) where m < measures.count {
            for g in measures[m].slots[si].groups where g.voice == s.voice && !g.isRest && !g.grace {
                let pos = ScorePosition(measure: m, onset: g.onset)
                guard pos >= ScorePosition(measure: s.startMeasure, onset: s.startOnset),
                      pos <= ScorePosition(measure: s.endMeasure, onset: s.endOnset) else { continue }
                if g.stemUp { up += 1 } else { down += 1 }
                multi = multi || g.multiVoice
                if first == nil { first = g.stemUp }
            }
        }
        if multi { return first ?? true }
        return !(down == 0 && up > 0)
    }

    /// One slur, or the part of it on this system: its ends in staff-local coordinates.
    struct SlurPiece {
        var slot: Int
        /// The slot of the end on another staff (a cross-staff slur); `y2` is then local to it.
        var endSlot: Int?
        var above: Bool
        /// The file gave no side: a cross-staff slur may pick the side that clears best.
        var sideFree = false
        var x1: Double, y1: Double, x2: Double, y2: Double
        var tag: NoteID
    }

    /// The slurs of one system. A slur between two heads of a staff goes from the start to the stop
    /// (heads side, or the stem tip when the stem is on the slur's side) and clears everything it
    /// spans; one across a system break is two halves meeting the break at the level of the end that
    /// is on the system. Cross-staff slurs are returned, not drawn: they need the staves' places.
    func layoutSlurs(range: Range<Int>, measures: [MeasureData], laid: [LaidMeasure], placed: [PlacedGroup],
                     bufs: inout [StaffBuffer]) -> [SlurPiece] {
        var ref: [NoteID: (pi: Int, ni: Int)] = [:]
        for (pi, pg) in placed.enumerated() where !pg.group.isRest {
            for (ni, n) in pg.group.notes.enumerated() { ref[n.note.id] = (pi, ni) }
        }
        func lm(_ m: Int) -> LaidMeasure? { laid.first { $0.index == m } }
        func barLeft(_ m: Int) -> Double {
            guard let l = lm(m) else { return 0 }
            return l.barX - (measures[m].endFixed - measures[m].endClefW)
        }
        /// Where a slur meets a chord: its head on the slur's side, or the stem tip if the stem is there.
        func endpoint(_ pg: PlacedGroup, above: Bool) -> (x: Double, y: Double) {
            let g = pg.group
            if !g.grace, let s = pg.stem, s.up == above { return (s.x, s.yEnd + (above ? -0.45 : 0.45)) }
            let box = headBox(pg, above ? g.notes.count - 1 : 0)
            // Articulations on the slur's side stay inside it: the slur starts outside them.
            if let a = bufs[pg.slotIndex].articulationEdge[g.leadID], a.above == above {
                return (box.midX, above ? min(box.minY - 0.4, a.y - 0.35) : max(box.maxY + 0.4, a.y + 0.35))
            }
            return (box.midX, above ? box.minY - 0.4 : box.maxY + 0.4)
        }
        var pieces: [SlurPiece] = []
        for spec in slurs where spec.startMeasure < range.upperBound && spec.endMeasure >= range.lowerBound {
            let startHere = range.contains(spec.startMeasure), endHere = range.contains(spec.endMeasure)
            let s = startHere ? ref[spec.start] : nil, e = endHere ? ref[spec.end] : nil
            if (startHere && s == nil) || (endHere && e == nil) { continue }
            guard let slot = s.map({ placed[$0.pi].slotIndex }) ?? e.map({ placed[$0.pi].slotIndex })
                    ?? slots.firstIndex(of: Slot(part: spec.part, staff: spec.startStaff)) else { continue }
            var endSlot: Int?
            if let s, let e, placed[s.pi].slotIndex != placed[e.pi].slotIndex { endSlot = placed[e.pi].slotIndex }
            // A cross-staff slur with no placement in the file goes above when it rises to the upper staff.
            let above = spec.above == nil && endSlot != nil ? (endSlot! < slot) : slurAbove(spec, measures: measures)
            let open = above ? -1.0 : 5.0
            var p = SlurPiece(slot: slot, endSlot: endSlot, above: above, sideFree: spec.above == nil && endSlot != nil, x1: 0, y1: open, x2: 0, y2: open, tag: spec.start)
            if let s { (p.x1, p.y1) = endpoint(placed[s.pi], above: above) }
            if let e { (p.x2, p.y2) = endpoint(placed[e.pi], above: above) }
            // The half that continues past the system's edge takes the level of the end it has.
            if s == nil {
                p.x1 = (lm(range.lowerBound)?.bodyStart ?? 0) + 0.1
                p.y1 = e != nil ? p.y2 : open
            }
            if e == nil {
                p.x2 = barLeft(range.upperBound - 1) - 0.3
                p.y2 = s != nil ? p.y1 : open
            }
            guard p.x2 - p.x1 >= 0.8 else { continue }
            pieces.append(p)
        }
        // Short slurs first: longer ones that span them then go outside.
        pieces.sort { ($0.x2 - $0.x1) < ($1.x2 - $1.x1) }
        for p in pieces where p.endSlot == nil {
            let inkItems = Set(bufs[p.slot].marks.filter { Self.slurObstacles.contains($0.kind) }.flatMap { Array($0.items) })
            let item = slurItem(p, items: bufs[p.slot].items, slurItems: Set(bufs[p.slot].marks.filter { $0.kind == .slur }.flatMap { Array($0.items) }),
                                inkItems: inkItems, cross: false)
            bufs[p.slot].addMark(.slur, [item])
        }
        return pieces.filter { $0.endSlot != nil }
    }

    /// A cross-staff slur between two staves of a placed system, in layout coordinates: it clears the
    /// notes of both staves near it, like any slur. `items` are the system's items so far and
    /// `slurItems` the indices of the slurs among them.
    func crossStaffSlurItem(_ p: SlurPiece, items: [LayoutItem], slurItems: Set<Int>, inkItems: Set<Int>) -> LayoutItem {
        slurItem(p, items: items, slurItems: slurItems, inkItems: inkItems, cross: true)
    }

    /// The marks a slur curves outside of: they sit on the notes, inside it.
    static let slurObstacles: Set<LaidMark.Kind> = [.articulation, .tremolo, .arpeggio]

    private struct SlurFit { var c1: Double, c2: Double, residual: Double, worstU: Double }

    /// Fits a slur between `p`'s ends (its `above`, and `lift1`/`lift2` raising the ends away from the
    /// heads) over obstacles given as sample points. The curve is measured across the chord: the
    /// offsets of its controls at 1/3 and 2/3 grow until its inner edge clears every point.
    private func fitSlur(_ p: SlurPiece, lift1: Double, lift2: Double, points: [CGPoint], band: Double?) -> (fit: SlurFit, y1: Double, y2: Double) {
        let y1 = p.y1 + (p.above ? -lift1 : lift1), y2 = p.y2 + (p.above ? -lift2 : lift2)
        let dx = p.x2 - p.x1, dy = y2 - y1
        let len = hypot(dx, dy)
        let cs = dx / len, sn = dy / len
        // The obstacles in the chord's frame: X along it, Y across it (up is negative).
        var local: [(u: Double, need: Double)] = []
        for q in points {
            let ox = q.x - p.x1, oy = q.y - y1
            let X = ox * cs + oy * sn, Y = -ox * sn + oy * cs
            guard X > 0.3, X < len - 0.3 else { continue }
            if let band, abs(Y) > band { continue }
            local.append((X / len, (p.above ? -Y : Y) + 0.25))
        }
        // A slur rises with its length: 0.45 sp plus 0.085 per sp, at most 3.2 sp (apex = 3/4 of a control offset).
        var c1 = min(0.45 + 0.085 * len, 3.2) / 0.75, c2 = c1
        func deficit(_ pt: (u: Double, need: Double)) -> Double {
            let u = pt.u
            let edge = 3 * c1 * u * (1 - u) * (1 - u) + 3 * c2 * u * u * (1 - u) - (0.1 + 0.12 * 4 * u * (1 - u))
            return pt.need - edge
        }
        for _ in 0..<40 {
            guard let w = local.max(by: { deficit($0) < deficit($1) }), deficit(w) > 0.01 else { break }
            let d = deficit(w), u = w.u
            let w1 = 3 * u * (1 - u) * (1 - u), w2 = 3 * u * u * (1 - u)
            let den = w1 * w1 + w2 * w2
            c1 = min(8, c1 + d * w1 / den)
            c2 = min(8, c2 + d * w2 / den)
        }
        let worst = local.max(by: { deficit($0) < deficit($1) })
        return (SlurFit(c1: c1, c2: c2, residual: max(0, worst.map(deficit) ?? 0), worstU: worst?.u ?? 0.5), y1, y2)
    }

    private func slurItem(_ p: SlurPiece, items: [LayoutItem], slurItems: Set<Int>, inkItems: Set<Int>, cross: Bool) -> LayoutItem {
        // Everything with ink the slur must clear: heads, accidentals, dots, stems, flags, beams,
        // ties, fingering, earlier slurs, and tuplet numbers and brackets. Each is sampled by the
        // corners and edge middles of its box (an earlier slur by slices of its arc).
        let tupletDigits = Set((0...9).map { Glyph.tupletDigit($0).codepoint })
        var points: [CGPoint] = []
        func addBox(_ r: CGRect) {
            for x in [r.minX, r.midX, r.maxX] { for y in [r.minY, r.midY, r.maxY] { points.append(CGPoint(x: x, y: y)) } }
        }
        let xa = min(p.x1, p.x2) + 0.2, xb = max(p.x1, p.x2) - 0.2
        for (idx, it) in items.enumerated() {
            var obstacle = it.noteID != nil || it.groupID != nil || it.beamID != nil
            switch it {
            case .glyph(let cp, _, _, nil, nil): obstacle = tupletDigits.contains(cp)
            case .line(_, _, let t, nil, nil): obstacle = t == EngravingDefaults.tupletBracketThickness
            default: break
            }
            if slurItems.contains(idx) || inkItems.contains(idx) { obstacle = true }
            guard obstacle else { continue }
            let b = it.bounds
            if b.isNull || b.maxX < xa || b.minX > xb { continue }
            if case .path(let els, _, _, _, _) = it, slurItems.contains(idx) {
                let pts = Self.flatten(els)
                let n = max(1, Int(ceil((b.maxX - b.minX) / 0.8)))
                for k in 0..<n {
                    let lo = b.minX + (b.maxX - b.minX) * Double(k) / Double(n), hi = b.minX + (b.maxX - b.minX) * Double(k + 1) / Double(n)
                    let ys = pts.filter { $0.x >= lo - 0.2 && $0.x <= hi + 0.2 }.map(\.y)
                    if let a = ys.min(), let z = ys.max() { addBox(CGRect(x: lo, y: a, width: hi - lo, height: z - a)) }
                }
            } else { addBox(b) }
        }
        let band: Double? = cross ? 3.5 : nil
        // The ends rise off the heads (as Gould has it) when the curve alone cannot clear a note near one.
        func best(_ q: SlurPiece) -> (SlurPiece, SlurFit, Double, Double) {
            var l1 = 0.0, l2 = 0.0
            var r = fitSlur(q, lift1: 0, lift2: 0, points: points, band: band)
            for _ in 0..<12 where r.fit.residual > 0.05 {
                if r.fit.worstU < 0.5 { l1 += 0.35 } else { l2 += 0.35 }
                r = fitSlur(q, lift1: l1, lift2: l2, points: points, band: band)
            }
            return (q, r.fit, r.y1, r.y2)
        }
        var chosen = best(p)
        if cross, p.sideFree {
            var other = p; other.above.toggle()
            let o = best(other)
            if (o.1.residual, o.1.c1 + o.1.c2) < (chosen.1.residual, chosen.1.c1 + chosen.1.c2) { chosen = o }
        }
        let (q, fit, y1, y2) = chosen
        // Drawn along a level chord, then turned onto the real one so its thickness stays across it.
        let dx = q.x2 - q.x1, dy = y2 - y1
        let len = hypot(dx, dy)
        let level = Self.crescent(x1: 0, y1: 0, x2: len, y2: 0, dir: q.above ? -1 : 1, kOut1: fit.c1, kOut2: fit.c2, controlFraction: 1.0 / 3,
                                  endThickness: EngravingDefaults.slurEndpointThickness, midThickness: EngravingDefaults.slurMidpointThickness)
        let cs = dx / len, sn = dy / len
        func t(_ pt: CGPoint) -> CGPoint { CGPoint(x: q.x1 + pt.x * cs - pt.y * sn, y: y1 + pt.x * sn + pt.y * cs) }
        let els: [PathElement] = level.map { e in
            switch e {
            case .move(let pt): .move(t(pt))
            case .line(let pt): .line(t(pt))
            case .quad(let to, let c): .quad(to: t(to), control: t(c))
            case .curve(let to, let c1, let c2): .curve(to: t(to), control1: t(c1), control2: t(c2))
            case .close: .close
            }
        }
        return .path(els, stroke: nil, fill: true)
    }

    /// The points of a path's curves, sampled.
    static func flatten(_ els: [PathElement]) -> [CGPoint] {
        var pts: [CGPoint] = []
        var cur = CGPoint.zero, start = CGPoint.zero
        for e in els {
            if case .move(let q) = e { start = q }
            let f = e.flattened(from: cur)
            pts += f
            if case .close = e { cur = start } else if let l = f.last { cur = l }
        }
        return pts
    }
}
