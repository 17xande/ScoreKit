import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Glyph {
    /// The SMuFL glyphs of a dynamic word: one combined glyph for the usual ones, else its letters.
    static func dynamics(_ text: String) -> [Glyph] {
        let combined: [String: Glyph] = [
            "p": .dynamicPiano, "pp": .dynamicPP, "ppp": .dynamicPPP, "pppp": .dynamicPPPP,
            "mp": .dynamicMP, "mf": .dynamicMF, "pf": .dynamicPF,
            "f": .dynamicForte, "ff": .dynamicFF, "fff": .dynamicFFF, "ffff": .dynamicFFFF,
            "fp": .dynamicFortePiano, "fz": .dynamicForzando,
            "sf": .dynamicSforzando1, "sfz": .dynamicSforzato, "sffz": .dynamicSforzatoFF,
            "sfp": .dynamicSforzandoPiano, "sfpp": .dynamicSforzandoPianissimo, "sfzp": .dynamicSforzatoPiano,
            "rf": .dynamicRinforzando1, "rfz": .dynamicRinforzando2, "n": .dynamicNiente, "m": .dynamicMezzo,
        ]
        if let g = combined[text] { return [g] }
        let letters: [Character: Glyph] = ["p": .dynamicPiano, "m": .dynamicMezzo, "f": .dynamicForte, "r": .dynamicRinforzando,
                                           "s": .dynamicSforzando, "z": .dynamicZ, "n": .dynamicNiente]
        return text.compactMap { letters[$0] }
    }

    /// The label of an octave line: "8va" (written an octave lower than it sounds) and so on.
    static func octaveLabel(_ octaves: Int) -> Glyph {
        switch octaves {
        case ...(-3): .ventiduesimaAlta
        case -2: .quindicesimaAlta
        case -1: .ottavaAlta
        case 1: .ottavaBassaVb
        case 2: .quindicesimaBassaMb
        default: .ventiduesimaBassaMb
        }
    }
}

extension Engraving {
    /// The lowest ink of a staff buffer over an x range, never above the bottom line (4).
    func floor(_ buf: StaffBuffer, _ x0: Double, _ x1: Double) -> Double {
        var low = 4.0
        for it in buf.items {
            let b = it.bounds
            if b.isNull || b.maxX < x0 || b.minX > x1 { continue }
            low = max(low, b.maxY)
        }
        return low
    }

    /// Slurs, dynamics, hairpins, octave lines and pedal marks of one system, into the buffers of
    /// the staves they belong to. Order matters: each kind goes outside the ones before it
    /// (slurs, then dynamics and hairpins, octave lines, pedal), and the volta, tempo and jump
    /// marks over the first staff (`layoutOverlays`) go outside all of them.
    func layoutNotation(range: Range<Int>, measures: [MeasureData], laid: [LaidMeasure], placed: [PlacedGroup],
                        bufs: inout [StaffBuffer]) -> [SlurPiece] {
        let cross = layoutSlurs(range: range, measures: measures, laid: laid, placed: placed, bufs: &bufs)
        let ctx = NotationContext(engraving: self, range: range, measures: measures, laid: laid)
        layoutDynamics(ctx, bufs: &bufs)
        layoutOctaveLines(ctx, bufs: &bufs)
        layoutPedals(ctx, bufs: &bufs)
        return cross
    }

    // MARK: Dynamics and hairpins

    /// Dynamics and hairpins share a row under (or over) each staff: those that touch or overlap
    /// horizontally sit on one centre line, which clears whatever is under them.
    private func layoutDynamics(_ ctx: NotationContext, bufs: inout [StaffBuffer]) {
        struct Elem {
            var isHairpin: Bool
            var x0: Double, x1: Double
            // A dynamic: its glyphs' origin x, and ascent/descent about its baseline.
            var glyphs: [Glyph] = []
            var originX = 0.0
            var ascent = 0.0, descent = 0.0
            // A hairpin.
            var cresc = false
            var spreadStart = 0.0, spreadEnd = 0.0
            var position: ScorePosition?
        }
        struct RowKey: Hashable { var slot: Int; var above: Bool }
        var rows: [RowKey: [Elem]] = [:]
        // Visual middle of a dynamic's lower-case letters: the hairpin line goes through it.
        let mid = 0.55

        for part in ctx.parts {
            for d in score.parts[part].dynamics {
                guard let slot = ctx.slot(part, d.staff), let x = ctx.x(d.at, in: self) else { continue }
                let gs = Glyph.dynamics(d.text)
                guard let first = gs.first, let last = gs.last else { continue }
                let advances = gs.dropLast().reduce(0.0) { $0 + $1.metrics.advance }
                let width = advances + last.metrics.maxX - first.metrics.minX
                let cx = x + 0.59
                // A single glyph is centred by its SMuFL optical centre, a run of letters by its box.
                let centre = gs.count == 1 ? first.metrics.anchors["opticalCenter"]?.x : nil
                let origin = max(centre.map { cx - $0 } ?? (cx - width / 2 - first.metrics.minX), staffLeft + 0.3)
                var e = Elem(isHairpin: false, x0: origin + first.metrics.minX, x1: origin + first.metrics.minX + width)
                e.glyphs = gs; e.originX = origin
                e.ascent = gs.map(\.metrics.maxY).max()!
                e.descent = -gs.map(\.metrics.minY).min()!
                e.position = d.at
                rows[RowKey(slot: slot, above: d.above), default: []].append(e)
            }
        }
        // Dynamics that would overlap in a row are nudged right, in order.
        for k in rows.keys.sorted(by: { ($0.slot, $0.above ? 1 : 0) < ($1.slot, $1.above ? 1 : 0) }) {
            rows[k]!.sort { $0.x0 < $1.x0 }
            var edge = -Double.infinity
            for i in rows[k]!.indices {
                let shift = max(0, edge + 0.3 - rows[k]![i].x0)
                rows[k]![i].x0 += shift; rows[k]![i].x1 += shift; rows[k]![i].originX += shift
                edge = rows[k]![i].x1
            }
        }
        for part in ctx.parts {
            for w in score.parts[part].wedges where w.end > ScorePosition(measure: ctx.range.lowerBound, onset: .zero)
                && w.start.measure < ctx.range.upperBound {
                guard let slot = ctx.slot(part, w.staff) else { continue }
                let key = RowKey(slot: slot, above: w.above)
                let dyns = (rows[key] ?? []).filter { !$0.isHairpin }
                let startsHere = ctx.range.contains(w.start.measure), endsHere = ctx.ends(w.end)
                // Starts after a dynamic written at its start; ends before one written at its end.
                var x1: Double, x2: Double
                if startsHere, let x = ctx.x(w.start, in: self) {
                    x1 = x
                    if let d = dyns.first(where: { $0.position == w.start }) { x1 = d.x1 + 0.4 }
                } else { x1 = (ctx.lm(ctx.range.lowerBound)?.bodyStart ?? 0) + 0.2 }
                if endsHere, let x = ctx.x(w.end, in: self) {
                    x2 = x - 0.5
                    if let d = dyns.first(where: { $0.position == w.end }) { x2 = d.x0 - 0.4 }
                } else { x2 = ctx.barLeft(ctx.range.upperBound - 1) - 0.3 }
                guard x2 - x1 > 0.5 else { continue }
                let spread = min(1.2, 0.45 + 0.09 * (x2 - x1))
                // A wedge broken across systems is drawn open at the break: wider than a point.
                let open = 0.55 * spread
                let (a, b): (Double, Double) = w.crescendo ? (startsHere ? 0 : open, endsHere ? spread : open)
                                                           : (startsHere ? spread : open, endsHere ? 0 : open)
                var e = Elem(isHairpin: true, x0: x1, x1: x2)
                e.cresc = w.crescendo; e.spreadStart = a; e.spreadEnd = b
                rows[key, default: []].append(e)
            }
        }
        for (key, all) in rows.sorted(by: { ($0.key.slot, $0.key.above ? 1 : 0) < ($1.key.slot, $1.key.above ? 1 : 0) }) {
            let elems = all.sorted { $0.x0 < $1.x0 }
            // Clusters: elements within 0.8 sp of each other.
            var clusters: [[Elem]] = []
            for e in elems {
                if let last = clusters.last, let reach = last.map(\.x1).max(), e.x0 < reach + 0.8 { clusters[clusters.count - 1].append(e) }
                else { clusters.append([e]) }
            }
            for cl in clusters {
                let x0 = cl.map(\.x0).min()! - 0.2, x1 = cl.map(\.x1).max()! + 0.2
                var yc: Double
                if key.above {
                    // Centre line above the staff: the lowest ink of any member clear of what is there.
                    let low = cl.map { $0.isHairpin ? max($0.spreadStart, $0.spreadEnd) / 2 : $0.descent + mid }.max()!
                    yc = min(-2.3, skyline(bufs[key.slot], x0, x1) - 0.5 - low)
                } else {
                    let high = cl.map { $0.isHairpin ? max($0.spreadStart, $0.spreadEnd) / 2 : $0.ascent - mid }.max()!
                    yc = max(6.3, floor(bufs[key.slot], x0, x1) + 0.5 + high)
                }
                for e in cl {
                    if e.isHairpin {
                        let ink = EngravingDefaults.hairpinThickness
                        let (sa, sb) = (e.spreadStart, e.spreadEnd)
                        // A hairpin is two strokes meeting at its closed end.
                        var items: [LayoutItem] = []
                        for sign in [-1.0, 1.0] {
                            items.append(.line(from: CGPoint(x: e.x0, y: yc + sign * sa / 2), to: CGPoint(x: e.x1, y: yc + sign * sb / 2), thickness: ink))
                        }
                        bufs[key.slot].addMark(.hairpin, items)
                    } else {
                        var x = e.originX
                        var items: [LayoutItem] = []
                        for g in e.glyphs {
                            items.append(.glyph(codepoint: g.codepoint, position: CGPoint(x: x, y: yc + mid)))
                            x += g.metrics.advance
                        }
                        bufs[key.slot].addMark(.dynamic, items)
                    }
                }
            }
        }
    }

    // MARK: Octave lines

    /// 8va and 15ma lines above their staff, 8vb and 15mb below: the label, a dashed line and a
    /// hook toward the staff at the end. A line that continues past the system's edge says
    /// "(8va)" again on the next system and has no hook where it breaks.
    private func layoutOctaveLines(_ ctx: NotationContext, bufs: inout [StaffBuffer]) {
        let thick = EngravingDefaults.octaveLineThickness
        let hook = 1.0
        for part in ctx.parts {
            for o in score.parts[part].octaveShifts
            where o.end > ScorePosition(measure: ctx.range.lowerBound, onset: .zero) && o.start.measure < ctx.range.upperBound {
                guard o.octaves != 0, let slot = ctx.slot(part, o.staff) else { continue }
                let above = o.octaves < 0
                let startsHere = ctx.range.contains(o.start.measure)
                // The end position is exclusive: it is where the next, unshifted note begins.
                let endsHere = ctx.ends(o.end)
                let x1: Double
                if startsHere, let x = ctx.x(o.start, in: self) { x1 = x - 0.2 }
                else { x1 = (ctx.lm(ctx.range.lowerBound)?.bodyStart ?? 0) }
                var x2: Double
                if endsHere, ctx.range.contains(o.end.measure), let x = ctx.x(o.end, in: self) { x2 = x - 0.7 }
                else { x2 = ctx.barLeft(ctx.range.upperBound - 1) - 0.3 }
                let label = Glyph.octaveLabel(o.octaves)
                let lm = label.metrics
                let parensL = Glyph.octaveParensLeft.metrics, parensR = Glyph.octaveParensRight.metrics
                let labelW = lm.advance + (startsHere ? 0 : parensL.advance + parensR.advance)
                x2 = max(x2, x1 + labelW + 1.5)
                let buf = bufs[slot]
                // The line is level and clear of everything it spans; the label sits on it.
                let lineY: Double
                if above { lineY = min(-2.3, skyline(buf, x1, x2) - 0.5 - hook) }
                else { lineY = max(6.3, floor(buf, x1, x2) + 0.5 + hook) }
                let baseline = lineY + 0.55
                var items: [LayoutItem] = []
                var x = x1
                if !startsHere {
                    items.append(.glyph(codepoint: Glyph.octaveParensLeft.codepoint, position: CGPoint(x: x, y: baseline)))
                    x += parensL.advance
                }
                items.append(.glyph(codepoint: label.codepoint, position: CGPoint(x: x, y: baseline)))
                x += lm.advance
                if !startsHere {
                    items.append(.glyph(codepoint: Glyph.octaveParensRight.codepoint, position: CGPoint(x: x, y: baseline)))
                    x += parensR.advance
                }
                // Dashes from the label to the end, ending exactly at x2.
                let on = 0.6, off = 0.45
                var dx = x + 0.3
                while dx < x2 - 1e-6 {
                    items.append(.line(from: CGPoint(x: dx, y: lineY), to: CGPoint(x: min(dx + on, x2), y: lineY), thickness: thick))
                    dx += on + off
                }
                if endsHere {
                    items.append(.line(from: CGPoint(x: x2, y: lineY - thick / 2), to: CGPoint(x: x2, y: lineY + (above ? hook : -hook)), thickness: thick))
                }
                bufs[slot].addMark(.octaveLine, items)
            }
        }
    }

    // MARK: Pedal

    /// Pedal marks go below the lowest staff of their part, all on one line per system: "Ped."
    /// and "*" signs, or a bracket line with an upward hook at the release and a notch at each
    /// change. Signs of one pedal that would touch are pushed apart.
    private func layoutPedals(_ ctx: NotationContext, bufs: inout [StaffBuffer]) {
        let thick = EngravingDefaults.pedalLineThickness
        let hook = 1.0
        let ped = Glyph.keyboardPedalPed.metrics, star = Glyph.keyboardPedalUp.metrics
        struct Sign { var star: Bool; var want: Double; var left = 0.0 }
        struct Piece {
            var slot: Int
            var signs: [Sign]
            var lineX1: Double, endX: Double
            var changes: [Double]
            var line: Bool, hookStart: Bool, endsHere: Bool
            var x0 = 0.0, x1 = 0.0
        }
        var pieces: [Piece] = []
        for part in ctx.parts {
            guard let slot = slots.lastIndex(where: { $0.part == part }) else { continue }
            for p in score.parts[part].pedals
            where p.end > ScorePosition(measure: ctx.range.lowerBound, onset: .zero) && p.start.measure < ctx.range.upperBound {
                let startsHere = ctx.range.contains(p.start.measure)
                let endsHere = ctx.ends(p.end) && p.released
                let startX = startsHere ? (ctx.x(p.start, in: self) ?? 0) : (ctx.lm(ctx.range.lowerBound)?.bodyStart ?? 0) + 0.2
                let endX: Double
                if ctx.range.contains(p.end.measure), let x = ctx.x(p.end, in: self) { endX = x - 0.5 }
                else { endX = ctx.barLeft(ctx.range.upperBound - 1) - 0.3 }
                let changes = p.changes.filter { ctx.range.contains($0.measure) }.compactMap { ctx.x($0, in: self) }
                var signs: [Sign] = []
                if startsHere && p.startSign { signs.append(Sign(star: false, want: startX - 0.3)) }
                if !p.line {
                    for c in changes { signs.append(Sign(star: true, want: c - 1.0)); signs.append(Sign(star: false, want: c + 0.6)) }
                    if endsHere { signs.append(Sign(star: true, want: endX + 0.5 - star.advance / 2 + 0.2)) }
                }
                pieces.append(Piece(slot: slot, signs: signs, lineX1: startX, endX: endX, changes: changes, line: p.line,
                                    hookStart: startsHere && !p.startSign, endsHere: endsHere))
            }
        }
        // Signs, left to right over all pedals of a staff: each at its place or just after the one before.
        let width = { (s: Sign) in s.star ? star.advance : ped.advance }
        for slot in Set(pieces.map(\.slot)).sorted() {
            var all: [(pi: Int, si: Int)] = []
            for (pi, p) in pieces.enumerated() where p.slot == slot { for si in p.signs.indices { all.append((pi, si)) } }
            all.sort { pieces[$0.pi].signs[$0.si].want < pieces[$1.pi].signs[$1.si].want }
            var edge = -Double.infinity
            for (pi, si) in all {
                let left = max(pieces[pi].signs[si].want, edge + 0.4)
                pieces[pi].signs[si].left = left
                edge = left + width(pieces[pi].signs[si])
            }
        }
        for i in pieces.indices {
            // The bracket starts after "Ped." or, without one, at the note (with a hook up).
            let signRight = pieces[i].signs.map { $0.left + width($0) }.max()
            let afterSign = pieces[i].signs.first.map { !$0.star && $0.want <= pieces[i].lineX1 } ?? false
            if pieces[i].line, afterSign, let r = signRight { pieces[i].lineX1 = r + 0.3 }
            pieces[i].x0 = min(pieces[i].signs.first?.left ?? pieces[i].lineX1, pieces[i].line ? pieces[i].lineX1 : .infinity)
            pieces[i].x1 = max(signRight ?? pieces[i].endX, pieces[i].line ? pieces[i].endX : -.infinity)
        }
        guard !pieces.isEmpty else { return }
        // One baseline per staff: clear of everything under the staff in the pieces' ranges. The
        // sign's top is 2.2 sp over its baseline.
        var base: [Int: Double] = [:]
        for p in pieces {
            let b = max(4 + 1.5 + 2.22, floor(bufs[p.slot], p.x0 - 0.2, p.x1 + 0.2) + 0.6 + 2.22)
            base[p.slot] = max(base[p.slot] ?? 0, b)
        }
        for p in pieces {
            let y = base[p.slot]!
            var out: [LayoutItem] = []
            for s in p.signs {
                let g = s.star ? Glyph.keyboardPedalUp : Glyph.keyboardPedalPed
                out.append(.glyph(codepoint: g.codepoint, position: CGPoint(x: s.left, y: y)))
            }
            if p.line {
                // One stroked path: along the baseline, up and down at each change, up at the ends.
                var els: [PathElement] = []
                if p.hookStart { els += [.move(CGPoint(x: p.lineX1, y: y - hook)), .line(CGPoint(x: p.lineX1, y: y))] }
                else { els.append(.move(CGPoint(x: p.lineX1, y: y))) }
                for c in p.changes where c > p.lineX1 && c < p.endX {
                    els += [.line(CGPoint(x: c - 0.5, y: y)), .line(CGPoint(x: c, y: y - hook)), .line(CGPoint(x: c + 0.5, y: y))]
                }
                els.append(.line(CGPoint(x: p.endX, y: y)))
                if p.endsHere { els.append(.line(CGPoint(x: p.endX, y: y - hook))) }
                out.append(.path(els, stroke: thick, fill: false))
            }
            bufs[p.slot].addMark(.pedal, out)
        }
    }
}

/// What the notation passes need to know about one system.
struct NotationContext {
    let parts: [Int]
    let range: Range<Int>
    let measures: [MeasureData]
    let slotIndex: [StaffKey: Int]
    let laid: [Int: LaidMeasure]

    init(engraving e: Engraving, range: Range<Int>, measures: [MeasureData], laid: [LaidMeasure]) {
        parts = Array(Set(e.slots.map(\.part))).sorted()
        self.range = range
        self.measures = measures
        var idx: [StaffKey: Int] = [:]
        for (i, s) in e.slots.enumerated() { idx[StaffKey(part: s.part, staff: s.staff)] = i }
        slotIndex = idx
        self.laid = Dictionary(uniqueKeysWithValues: laid.map { ($0.index, $0) })
    }

    func slot(_ part: Int, _ staff: Int) -> Int? { slotIndex[StaffKey(part: part, staff: staff)] }
    func lm(_ m: Int) -> LaidMeasure? { laid[m] }
    /// Whether a span ending at `p` (exclusive) ends on this system: inside it, or on the downbeat
    /// of the next one, which is this system's barline.
    func ends(_ p: ScorePosition) -> Bool { range.contains(p.measure) || (p.measure == range.upperBound && p.onset == .zero) }
    /// The right edge of a measure's last music, before its barline.
    func barLeft(_ m: Int) -> Double {
        guard let l = laid[m] else { return 0 }
        return l.barX - (measures[m].endFixed - measures[m].endClefW)
    }
    /// The x of the column at a position, on this system; nil when its measure is on another.
    func x(_ p: ScorePosition, in e: Engraving) -> Double? { laid[p.measure]?.x(at: p.onset) }
}

struct StaffKey: Hashable { var part: Int; var staff: Int }
