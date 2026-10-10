import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// S6c part 2: articulations, tremolo slashes, arpeggios, ornaments (with trill lines) and
// fermatas. They sit on the notes (Gould, Behind Bars): articulations next to the heads or past the
// stem tip, ornaments and fermatas above the staff, arpeggios left of the chord.

/// A trill's wavy line: from the note with its `start` to the end of the note with its `stop`.
struct WavySpec {
    var part: Int
    var staff: Int
    var start: NoteID
    var startPos: ScorePosition
    /// The end of the stop note (its onset plus duration); the end of the start note when never stopped.
    var end: ScorePosition
}

/// An arpeggio between two staves, drawn once the staves have their places.
struct ArpPiece {
    var slot: Int, endSlot: Int
    var x: Double
    /// Staff-local: `y1` in `slot`, `y2` in `endSlot`.
    var y1: Double, y2: Double
    var up: Bool?
}

/// What the notation passes leave for the system assembly: marks between two staves.
struct CrossStaffMarks {
    var slurs: [Engraving.SlurPiece] = []
    var arpeggios: [ArpPiece] = []
}

extension LayoutItem {
    /// The ink as small boxes: a glyph or text by its box; a slanted line, a path or a beam by boxes
    /// along it, so that a sloped beam or a long slur does not count as the whole area under it.
    var inkBoxes: [CGRect] {
        func along(_ pts: [CGPoint], _ r: Double) -> [CGRect] {
            var out: [CGRect] = []
            var prev: CGPoint?
            for p in pts {
                if let q = prev, hypot(p.x - q.x, p.y - q.y) > 0.01 {
                    let n = max(1, Int(ceil(hypot(p.x - q.x, p.y - q.y) / 0.1)))
                    for i in 0...n {
                        let t = Double(i) / Double(n)
                        out.append(CGRect(x: q.x + (p.x - q.x) * t - r, y: q.y + (p.y - q.y) * t - r, width: 2 * r, height: 2 * r))
                    }
                } else if prev == nil { out.append(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
                prev = p
            }
            return out
        }
        switch self {
        case .line(let a, let b, let t, _, _) where a.x != b.x && a.y != b.y: return along([a, b], t / 2)
        case .path(let els, let stroke, _, _, _): return along(Engraving.flatten(els), (stroke ?? 0) / 2)
        case .beam(let els, _): return along(Engraving.flatten(els), 0.1)
        default: let b = bounds; return b.isNull ? [] : [b]
        }
    }
}

extension Glyph {
    /// The glyph of an articulation, for the side it is on.
    static func articulation(_ k: ArticulationMark.Kind, above: Bool) -> Glyph {
        switch k {
        case .staccato: above ? .articStaccatoAbove : .articStaccatoBelow
        case .staccatissimo: above ? .articStaccatissimoAbove : .articStaccatissimoBelow
        case .accent: above ? .articAccentAbove : .articAccentBelow
        case .strongAccent: above ? .articMarcatoAbove : .articMarcatoBelow
        case .tenuto: above ? .articTenutoAbove : .articTenutoBelow
        case .tenutoStaccato: above ? .articTenutoStaccatoAbove : .articTenutoStaccatoBelow
        }
    }

    static func ornament(_ k: OrnamentMark.Kind) -> Glyph {
        switch k {
        case .trill: .ornamentTrill
        case .mordent: .ornamentMordent
        case .invertedMordent: .ornamentShortTrill
        case .turn: .ornamentTurn
        case .invertedTurn: .ornamentTurnInverted
        }
    }

    /// The slash glyph of a single tremolo (one to five strokes; more are drawn as five).
    static func tremolo(_ marks: Int) -> Glyph {
        switch marks {
        case 1: .tremolo1
        case 2: .tremolo2
        case 3: .tremolo3
        case 4: .tremolo4
        default: .tremolo5
        }
    }

    /// Heads, accidentals, dots, flags and rests: the ink of a note that its own marks start from.
    fileprivate var isNoteBody: Bool {
        (0xE0A0...0xE0AF).contains(rawValue) || (0xE260...0xE26F).contains(rawValue) || self == .augmentationDot
            || (0xE240...0xE24F).contains(rawValue) || (0xE4E0...0xE4FF).contains(rawValue)
    }
}

extension Engraving {
    // MARK: Planning

    /// Pairs the `<wavy-line>` starts and stops of each part by staff and number. A line never
    /// stopped (or started again) covers its own note only.
    static func pairWavy(_ score: Score, parts: [Int]) -> [WavySpec] {
        struct Key: Hashable { var staff: Int; var number: Int }
        var out: [WavySpec] = []
        for pi in parts {
            var open: [Key: WavySpec] = [:]
            for (mi, m) in score.parts[pi].measures.enumerated() {
                for n in m.notes where !n.wavyLines.isEmpty {
                    let end = ScorePosition(measure: mi, onset: n.onset + n.duration)
                    for w in n.wavyLines {
                        let k = Key(staff: n.staff, number: w.number)
                        switch w.kind {
                        case .start:
                            if let o = open.removeValue(forKey: k) { out.append(o) }
                            open[k] = WavySpec(part: pi, staff: n.staff, start: n.id, startPos: ScorePosition(measure: mi, onset: n.onset), end: end)
                        case .stop:
                            if var o = open.removeValue(forKey: k) { o.end = max(o.end, end); out.append(o) }
                        case .continue: break
                        }
                    }
                }
            }
            out += open.values
        }
        return out.sorted { $0.startPos < $1.startPos }
    }

    // MARK: Collision helpers

    /// Whether anything of the staff but the group's own body ink overlaps `r`.
    func blocked(_ buf: StaffBuffer, _ r: CGRect, own: Set<NoteID>, lead: NoteID) -> Bool {
        let probe = r.insetBy(dx: -0.08, dy: -0.08)
        for it in buf.items {
            let b = it.bounds
            if b.isNull || !b.intersects(probe) { continue }
            switch it {
            case .glyph(let cp, _, _, let n, let g):
                if let glyph = Glyph(rawValue: cp), glyph.isNoteBody, (n.map(own.contains) ?? false) || g == lead { continue }
            case .line(_, _, _, let n, let g):
                if (n.map(own.contains) ?? false) || g == lead { continue }
            default: break
            }
            if it.inkBoxes.contains(where: { $0.intersects(probe) }) { return true }
        }
        return false
    }

    /// The x of the left edge of a chord's ink (heads and accidentals), for the arpeggio line.
    private func leftInk(_ pg: PlacedGroup, buf: StaffBuffer) -> Double {
        let ids = Set(pg.group.notes.map(\.note.id))
        var left = Double.infinity
        for it in buf.items {
            switch it {
            case .glyph(let cp, _, _, let n, _):
                guard let n, ids.contains(n), let g = Glyph(rawValue: cp),
                      (0xE0A0...0xE0AF).contains(g.rawValue) || (0xE260...0xE26F).contains(g.rawValue) else { continue }
                left = min(left, it.bounds.minX)
            // The stem (down stems are on the left of the head) and the ledger lines.
            case .line(_, _, _, _, let g) where g == pg.group.leadID:
                left = min(left, it.bounds.minX)
            default: break
            }
        }
        return left.isFinite ? left : pg.x
    }

    /// The glyph's origin so that its box is centred on (`cx`, `cy`).
    private func centred(_ g: Glyph, _ cx: Double, _ cy: Double, size: Double? = nil) -> CGPoint {
        let m = g.metrics, k = (size ?? Glyph.standardSize) / Glyph.standardSize
        return CGPoint(x: cx - (m.minX + m.maxX) / 2 * k, y: cy + (m.minY + m.maxY) / 2 * k)
    }

    // MARK: Articulations

    /// Articulations go on the notehead side (opposite the stem), or on the stem side past its tip
    /// when the staff has two voices. Each sits in a space of the staff where there is one and a
    /// little clear of the head; several stack outward in Gould's order (staccato nearest, then
    /// tenuto, accent, marcato). Anything in the way (a tie, another voice, a tuplet bracket)
    /// pushes the stack out by a space.
    func layoutArticulations(placed: [PlacedGroup], bufs: inout [StaffBuffer]) {
        for pg in placed {
            let g = pg.group
            guard !g.isRest, !g.grace, let kinds = Self.mergedArticulations(g) else { continue }
            // A beam can turn the stems of its group; the drawn stem decides.
            let stemUp = pg.stem?.up ?? g.stemUp
            let above = g.multiVoice ? stemUp : !stemUp
            let ref: Double, xc: Double, base: Double
            if g.multiVoice, let s = pg.stem {
                (ref, xc, base) = (s.yEnd, s.x, 0.3)
            } else {
                let ni = above ? g.notes.count - 1 : 0
                let box = headBox(pg, ni)
                (ref, xc, base) = (StaffGeometry.y(g.notes[ni].p), box.midX, 0.5 * g.scale + 0.25)
            }
            let own = Set(g.notes.map(\.note.id))
            let glyphs = kinds.map { Glyph.articulation($0, above: above) }
            let sign = above ? -1.0 : 1.0
            // The centres, nearest to farthest.
            func centres(shift: Double) -> [Double] {
                var ys: [Double] = []
                var edge = ref + sign * shift   // the line the next mark must clear
                var need = base
                for gl in glyphs {
                    let half = gl.metrics.height / 2
                    let want = edge + sign * (need + half)
                    // The space centre (k + 0.5) at or beyond `want`, inside the staff; outside it, `want` itself.
                    var y = want
                    let snapped = above ? Foundation.floor(want - 0.5) + 0.5 : Foundation.ceil(want - 0.5) + 0.5
                    if snapped > 0, snapped < 4 { y = snapped }
                    ys.append(y)
                    edge = y; need = half + 0.3
                }
                return ys
            }
            var shift = 0.0
            var ys = centres(shift: shift)
            for _ in 0..<8 {
                let hit = zip(glyphs, ys).contains { gl, y in
                    blocked(bufs[pg.slotIndex], gl.metrics.box(at: centred(gl, xc, y), size: nil), own: own, lead: g.leadID)
                }
                if !hit { break }
                shift += 1.0
                ys = centres(shift: shift)
            }
            var items: [LayoutItem] = []
            for (gl, y) in zip(glyphs, ys) { items.append(.glyph(codepoint: gl.codepoint, position: centred(gl, xc, y))) }
            bufs[pg.slotIndex].addMark(.articulation, items)
            if let last = glyphs.last, let y = ys.last { bufs[pg.slotIndex].articulationEdge[g.leadID] = (above, y + sign * last.metrics.height / 2) }
        }
    }

    /// The group's articulations, nearest the head first; a tenuto with a staccato is one
    /// portato mark. nil when it has none.
    static func mergedArticulations(_ g: Group) -> [ArticulationMark.Kind]? {
        var kinds = Set(g.notes.flatMap { $0.note.articulations.map(\.kind) })
        guard !kinds.isEmpty else { return nil }
        if kinds.contains(.tenuto), kinds.contains(.staccato) { kinds.subtract([.tenuto, .staccato]); kinds.insert(.tenutoStaccato) }
        let order: [ArticulationMark.Kind] = [.staccato, .staccatissimo, .tenutoStaccato, .tenuto, .accent, .strongAccent]
        return order.filter(kinds.contains)
    }

    // MARK: Tremolo

    /// Single tremolos are slashes across the stem, centred on the stem between the head and the
    /// beam or flag; a note with no stem has them over (or under) its head. The two notes of a
    /// double tremolo (both stemmed, in one staff) are joined by slashes between their stems.
    func layoutTremolos(placed: [PlacedGroup], bufs: inout [StaffBuffer]) {
        for (i, pg) in placed.enumerated() {
            let g = pg.group
            guard !g.isRest, !g.grace, let t = g.notes.lazy.compactMap(\.note.tremolo).first else { continue }
            switch t.kind {
            case .single:
                let gl = Glyph.tremolo(t.marks)
                if let s = pg.stem {
                    // Beams and flags take their levels off the tip end of the stem.
                    let levels = Double(beamLevel(g.value))
                    let tip = s.yEnd - (s.up ? -1 : 1) * levels * 0.75
                    let yc = (s.yStart + tip) / 2
                    bufs[pg.slotIndex].addMark(.tremolo, [.glyph(codepoint: gl.codepoint, position: centred(gl, s.x, yc))])
                } else {
                    let ni = g.stemUp ? g.notes.count - 1 : 0
                    let box = headBox(pg, ni)
                    let up = g.stemUp
                    let yc = up ? box.minY - 0.45 - gl.metrics.height / 2 : box.maxY + 0.45 + gl.metrics.height / 2
                    bufs[pg.slotIndex].addMark(.tremolo, [.glyph(codepoint: gl.codepoint, position: centred(gl, box.midX, yc))])
                }
            case .start:
                // The next group of the voice in this staff and measure carries the stop.
                guard let j = placed[(i + 1)...].firstIndex(where: {
                    $0.slotIndex == pg.slotIndex && $0.measure == pg.measure && $0.group.voice == g.voice && !$0.group.isRest && !$0.group.grace
                }), placed[j].group.notes.contains(where: { $0.note.tremolo?.kind == .stop }),
                      let s1 = pg.stem, let s2 = placed[j].stem, s1.up == s2.up, s2.x - s1.x > 1.5 else { continue }
                let n = t.marks
                let m1 = (s1.yStart + s1.yEnd) / 2, m2 = (s2.yStart + s2.yEnd) / 2
                // Between the heads: after the first note's (right of a down stem), before the second's (left of an up stem).
                let lo = s1.x + (s1.up ? 0.5 : 2.2), hi = s2.x - (s2.up ? 1.4 : 0.5)
                guard hi - lo > 0.8 else { continue }
                let len = min(hi - lo, 3.0)
                let xa = (lo + hi) / 2 - len / 2, xb = xa + len
                let slope = max(-0.12, min(0.12, (m2 - m1) / (s2.x - s1.x)))
                let ymid = (m1 + m2) / 2
                let thick = EngravingDefaults.beamThickness, space = thick + EngravingDefaults.beamSpacing
                var items: [LayoutItem] = []
                for k in 0..<n {
                    let off = (Double(k) - Double(n - 1) / 2) * space
                    let ya = ymid + off + slope * (xa - (s1.x + s2.x) / 2), yb = ymid + off + slope * (xb - (s1.x + s2.x) / 2)
                    items.append(.path([.move(CGPoint(x: xa, y: ya - thick / 2)), .line(CGPoint(x: xb, y: yb - thick / 2)),
                                        .line(CGPoint(x: xb, y: yb + thick / 2)), .line(CGPoint(x: xa, y: ya + thick / 2)), .close],
                                       stroke: nil, fill: true))
                }
                bufs[pg.slotIndex].addMark(.tremolo, items)
            case .stop: break
            }
        }
    }

    // MARK: Arpeggio

    // Known limits: double tremolos on whole notes or between opposite stems are not drawn; accents and
// marcato sit inside slurs (Gould puts them outside); a slur end on the stem side ignores
// `articulationEdge`; `markClashes` does not check cross-staff arpeggios.

    /// A wavy vertical line left of a chord (and of its stem, ledger lines and accidentals), from its lowest head to its highest. Notes of one
    /// number at one position in two staves of a part form one line across both. Single-staff
    /// lines are drawn here; the others come back for the system assembly.
    func layoutArpeggios(placed: [PlacedGroup], bufs: inout [StaffBuffer]) -> [ArpPiece] {
        struct Key: Hashable { var part: Int; var measure: Int; var onset: Rational; var number: Int }
        var sets: [Key: [Int]] = [:]
        for (i, pg) in placed.enumerated() where !pg.group.isRest && !pg.group.grace {
            guard let a = pg.group.notes.lazy.compactMap(\.note.arpeggio).first else { continue }
            sets[Key(part: slots[pg.slotIndex].part, measure: pg.measure, onset: pg.group.onset, number: a.number), default: []].append(i)
        }
        var cross: [ArpPiece] = []
        for key in sets.keys.sorted(by: { ($0.measure, $0.onset, $0.number, $0.part) < ($1.measure, $1.onset, $1.number, $1.part) }) {
            let marked = sets[key]!
            let top = marked.map { placed[$0].slotIndex }.min()!, bottom = marked.map { placed[$0].slotIndex }.max()!
            // The line is for the whole chord of the staves it touches: every voice sounding at that onset.
            let idx = placed.indices.filter { i in
                let pg = placed[i]
                return !pg.group.isRest && !pg.group.grace && pg.measure == key.measure && pg.group.onset == key.onset
                    && marked.contains { placed[$0].slotIndex == pg.slotIndex }
            }
            var x = Double.infinity
            var y1 = Double.infinity, y2 = -Double.infinity
            for i in idx {
                let pg = placed[i]
                x = min(x, leftInk(pg, buf: bufs[pg.slotIndex]))
                if pg.slotIndex == top { y1 = min(y1, (0..<pg.group.notes.count).map { headBox(pg, $0).minY }.min()!) }
                if pg.slotIndex == bottom { y2 = max(y2, (0..<pg.group.notes.count).map { headBox(pg, $0).maxY }.max()!) }
            }
            let up = placed[marked[0]].group.notes.lazy.compactMap(\.note.arpeggio).first?.up
            x -= 0.62
            if top == bottom {
                bufs[top].addMark(.arpeggio, Self.arpeggioItems(x: x, y1: y1, y2: max(y2, y1 + 1.2), up: up))
            } else {
                cross.append(ArpPiece(slot: top, endSlot: bottom, x: x, y1: y1, y2: y2, up: up))
            }
        }
        return cross
    }

    /// The wavy line (a stroked path of half waves) and its arrowhead, if the file gives a direction.
    static func arpeggioItems(x: Double, y1: Double, y2: Double, up: Bool?) -> [LayoutItem] {
        let amp = 0.22, arrow = 0.7
        let a = y1 + (up == true ? arrow : 0), b = y2 - (up == false ? arrow : 0)
        let n = max(2, Int(((b - a) / 0.5).rounded()))
        let hl = (b - a) / Double(n)
        var els: [PathElement] = [.move(CGPoint(x: x, y: a))]
        for i in 0..<n {
            let sign = i % 2 == 0 ? 1.0 : -1.0
            els.append(.quad(to: CGPoint(x: x, y: a + Double(i + 1) * hl), control: CGPoint(x: x + sign * 2 * amp, y: a + (Double(i) + 0.5) * hl)))
        }
        var out: [LayoutItem] = [.path(els, stroke: 0.18, fill: false)]
        if let up {
            let tip = up ? y1 : y2, back = up ? y1 + arrow : y2 - arrow
            out.append(.path([.move(CGPoint(x: x, y: tip)), .line(CGPoint(x: x - 0.32, y: back)), .line(CGPoint(x: x + 0.32, y: back)), .close],
                             stroke: nil, fill: true))
        }
        return out
    }

    // MARK: Ornaments and fermatas

    /// Trill signs, mordents and turns above their notes (below when the file says so), with the
    /// wavy line of a trill after its "tr". They sit outside the staff and everything on it,
    /// slurs included, on a level over their whole extent; accidentals of an ornament are small,
    /// above it (below a mordent) unless the file says. A trill line that carries on from the
    /// previous system starts at the left of the music.
    func layoutOrnaments(_ ctx: NotationContext, placed: [PlacedGroup], bufs: inout [StaffBuffer]) {
        let wavy = wavyLines.filter { $0.end > ScorePosition(measure: ctx.range.lowerBound, onset: .zero) && $0.startPos.measure < ctx.range.upperBound }
        func lineEnd(_ w: WavySpec) -> Double {
            let m = w.end.measure
            if !ctx.range.contains(m), !(m == ctx.range.upperBound && w.end.onset == .zero) { return ctx.barLeft(ctx.range.upperBound - 1) - 0.3 }
            if m == ctx.range.upperBound { return ctx.barLeft(m - 1) - 0.3 }
            guard let l = ctx.lm(m) else { return 0 }
            return w.end.onset >= l.duration ? ctx.barLeft(m) - 0.3 : l.x(at: w.end.onset) - 0.4
        }
        let wiggle = Glyph.wiggleTrill
        func addWiggles(_ items: inout [LayoutItem], from x0: Double, to x1: Double, y: Double) {
            let adv = wiggle.metrics.advance
            var x = x0
            while x + adv <= x1 + 1e-6 { items.append(.glyph(codepoint: wiggle.codepoint, position: CGPoint(x: x, y: y))); x += adv }
        }
        for pg in placed where !pg.group.isRest && !pg.group.grace {
            let g = pg.group
            let ornaments = g.notes.flatMap(\.note.ornaments)
            let spec = wavy.first { w in g.notes.contains { $0.note.id == w.start } }
            guard !ornaments.isEmpty || spec != nil else { continue }
            let xc = headBox(pg, 0).midX
            // Pieces from the staff outward, per side.
            struct Piece { var glyph: Glyph; var size: Double?; var wavy: Bool }
            var pieces: [Bool: [Piece]] = [true: [], false: []]
            var wavyPlaced = spec == nil
            for o in ornaments {
                // With two voices the lower voice's ornaments go below.
                let ab = o.above ?? !(g.multiVoice && !(pg.stem?.up ?? g.stemUp))
                var inner: [Piece] = [], outer: [Piece] = []
                if let name = o.accidental, let acc = Glyph.accidental(named: name) {
                    let accAbove = o.accidentalAbove ?? (o.kind != .mordent)
                    // Away from the staff is `outer`.
                    if accAbove == ab { outer.append(Piece(glyph: acc, size: 2.6, wavy: false)) } else { inner.append(Piece(glyph: acc, size: 2.6, wavy: false)) }
                }
                let carriesLine = !wavyPlaced && o.kind == .trill
                if carriesLine { wavyPlaced = true }
                pieces[ab]! += inner + [Piece(glyph: .ornament(o.kind), size: nil, wavy: carriesLine)] + outer
            }
            if !wavyPlaced { pieces[true]!.append(Piece(glyph: wiggle, size: nil, wavy: true)) }
            for ab in [true, false] {
                guard let list = pieces[ab], !list.isEmpty else { continue }
                // The x extent, for the level: the glyphs, and the trill line to its end.
                var x0 = xc, x1 = xc
                for p in list {
                    let w = p.glyph.metrics.width * (p.size ?? 4) / 4
                    x0 = min(x0, xc - w / 2); x1 = max(x1, xc + w / 2)
                }
                var lineFrom = 0.0, lineTo = 0.0
                if let spec, list.contains(where: \.wavy) {
                    let tr = list.first { $0.wavy }!
                    lineFrom = tr.glyph == wiggle ? headBox(pg, 0).minX : xc + tr.glyph.metrics.width / 2 + 0.15
                    lineTo = max(lineEnd(spec), lineFrom + 1)
                    x1 = max(x1, lineTo)
                }
                let buf = bufs[pg.slotIndex]
                var cursor = ab ? min(skyline(buf, x0 - 0.2, x1 + 0.2) - 0.45, -0.5) : max(floor(buf, x0 - 0.2, x1 + 0.2) + 0.45, 4.5)
                var items: [LayoutItem] = []
                for p in list {
                    let m = p.glyph.metrics, k = (p.size ?? 4) / 4
                    let y: Double
                    if ab { y = cursor + m.minY * k; cursor = y - m.maxY * k - 0.25 }
                    else { y = cursor + m.maxY * k; cursor = y - m.minY * k + 0.25 }
                    if p.wavy && p.glyph == wiggle {
                        addWiggles(&items, from: lineFrom, to: lineTo, y: y)
                    } else {
                        items.append(.glyph(codepoint: p.glyph.codepoint, position: CGPoint(x: xc - (m.minX + m.maxX) / 2 * k, y: y), size: p.size))
                        if p.wavy { addWiggles(&items, from: lineFrom, to: lineTo, y: y) }
                    }
                }
                bufs[pg.slotIndex].addMark(.ornament, items)
            }
        }
        // Trill lines whose start is on an earlier system.
        for w in wavy where w.startPos.measure < ctx.range.lowerBound {
            guard let slot = ctx.slot(w.part, w.staff), let l = ctx.lm(ctx.range.lowerBound) else { continue }
            let from = l.bodyStart + 0.2, to = lineEnd(w)
            guard to - from > 1 else { continue }
            let buf = bufs[slot]
            let y = min(skyline(buf, from - 0.2, to + 0.2) - 0.45, -0.5) + wiggle.metrics.minY
            var items: [LayoutItem] = []
            addWiggles(&items, from: from, to: to, y: y)
            bufs[slot].addMark(.ornament, items)
        }
    }

    /// Fermatas over their notes and rests (under, when inverted) and over barlines: above the
    /// staff, on a level clear of what is there.
    func layoutFermatas(_ ctx: NotationContext, placed: [PlacedGroup], bufs: inout [StaffBuffer]) {
        func put(_ f: FermataMark, slot: Int, xc: Double) {
            let gl: Glyph = f.inverted ? .fermataBelow : .fermataAbove
            let m = gl.metrics
            let x0 = xc - m.width / 2 - 0.1, x1 = xc + m.width / 2 + 0.1
            let buf = bufs[slot]
            let y: Double
            if f.inverted { y = max(floor(buf, x0, x1) + 0.45, 4.8) + m.maxY }
            else { y = min(skyline(buf, x0, x1) - 0.45, -0.8) + m.minY }
            bufs[slot].addMark(.fermata, [.glyph(codepoint: gl.codepoint, position: CGPoint(x: xc - (m.minX + m.maxX) / 2, y: y))])
        }
        for pg in placed {
            let g = pg.group
            guard let f = g.notes.lazy.compactMap(\.note.fermata).first else { continue }
            let xc = g.isRest ? pg.x + Glyph.rest(g.value).metrics.advance / 2 : headBox(pg, 0).midX
            put(f, slot: pg.slotIndex, xc: xc)
        }
        for part in ctx.parts {
            guard let first = slots.firstIndex(where: { $0.part == part }), let last = slots.lastIndex(where: { $0.part == part }) else { continue }
            for m in ctx.range where m < score.parts[part].measures.count {
                guard let l = ctx.lm(m) else { continue }
                for b in score.parts[part].measures[m].barlines {
                    guard let f = b.fermata else { continue }
                    let xc: Double
                    switch b.location {
                    case .right: xc = l.barX - 0.3
                    case .left: xc = l.x0 + 0.3
                    case .middle: xc = l.x(at: b.onset)
                    }
                    put(f, slot: f.inverted ? last : first, xc: xc)
                }
            }
        }
    }
}
