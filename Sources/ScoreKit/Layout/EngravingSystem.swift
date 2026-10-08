import Foundation

/// A note recorded in staff-local coordinates, converted when the system is assembled.
struct LocalNote {
    var id: NoteID
    var headBox: CGRect
    var groupID: NoteID
    var stemEnd: CGPoint?
    var isRest: Bool
}

/// Items for one staff in staff-local coordinates (top line at y = 0), with how far they
/// reach above and below the staff.
struct StaffBuffer {
    var items: [LayoutItem] = []
    // Starts with room for clef overshoot (a G clef reaches about 1.5 sp beyond the staff).
    var minY = -2.0
    var maxY = 6.0
    var notes: [LocalNote] = []
    var groups: [NoteID: [NoteID]] = [:]

    mutating func grow(_ r: CGRect) {
        minY = min(minY, r.minY)
        maxY = max(maxY, r.maxY)
    }

    mutating func glyph(_ g: Glyph, at p: CGPoint, size: Double? = nil, id: NoteID? = nil) {
        items.append(.glyph(codepoint: g.codepoint, position: p, size: size, noteID: id))
        grow(g.metrics.box(at: p, size: size))
    }
}

/// A stem, in staff-local coordinates: `yStart` is at the head end, `yEnd` the tip.
struct StemGeometry {
    var x: Double
    var yStart: Double
    var yEnd: Double
    var up: Bool
    var thickness: Double
    /// The note whose head the stem grows from.
    var attachedTo: NoteID
}

/// Pass 1's result for one group: where it sits and its stem. Between the passes, later
/// milestones adjust stems (beams, flags) and place ties.
struct PlacedGroup {
    var group: Group
    /// The column's x (or, for grace notes and measure rests, the group's own x).
    var x: Double
    var slotIndex: Int
    var stem: StemGeometry?
}

extension Engraving {
    func layoutSystem(_ measures: [MeasureData], _ range: Range<Int>, systemIndex: Int, top systemTop: Double,
                      justify: Bool, targetWidth: Double?) -> (LaidSystem, [NoteID: LaidNote], [NoteID: [NoteID]]) {
        let plans = range.map { plan(measures[$0], first: $0 == range.lowerBound) }
        // Justification stretches only the rhythmic part of each gap.
        let fixedWidth = plans.reduce(0) { $0 + $1.total }
            + range.reduce(0) { $0 + measures[$1].endFixed + measures[$1].fixedGaps.reduce(0, +) }
        let elastic = range.reduce(0) { r, m in
            r + zip(measures[m].gaps, measures[m].fixedGaps).reduce(0) { $0 + $1.0 - $1.1 }
        }
        let gapCount = range.reduce(0) { $0 + measures[$1].gaps.count }
        var factor = 1.0
        var bonus = 0.0
        if justify, let t = targetWidth {
            let extra = t - staffLeft - rightMargin - fixedWidth
            if elastic > 1e-9 { factor = max(1, extra / elastic) }
            else if extra > 0 { bonus = extra / Double(gapCount) }
        }

        var bufs = [StaffBuffer](repeating: StaffBuffer(), count: slots.count)
        var bars: [(x: Double, kind: BarKind, part: Int)] = []
        var repeatStarts: [(x: Double, part: Int)] = []
        var laidColumns: [LaidColumn] = []
        var laidMeasures: [LaidMeasure] = []
        var placed: [PlacedGroup] = []
        var x0 = staffLeft

        for (k, mi) in range.enumerated() {
            let md = measures[mi]
            let pl = plans[k]
            let isFirst = k == 0
            let bodyStart = x0 + pl.total
            var xs: [Double] = []
            var cx = bodyStart
            var measureColumns: [LaidColumn] = []
            func gap(_ i: Int) -> Double { md.fixedGaps[i] + (md.gaps[i] - md.fixedGaps[i]) * factor + bonus }
            for i in md.columns.indices {
                cx += gap(i)
                xs.append(cx)
                measureColumns.append(LaidColumn(measureIndex: mi, onset: md.columns[i].onset, x: cx))
            }
            laidColumns += measureColumns
            let endX = (xs.last ?? bodyStart) + gap(md.columns.count) + md.endFixed
            laidMeasures.append(LaidMeasure(index: mi, duration: md.duration, x0: x0, bodyStart: bodyStart,
                                            barX: endX, columns: measureColumns))
            let barW = md.endFixed - md.endClefW
            let columnIndex = Dictionary(uniqueKeysWithValues: md.columns.enumerated().map { ($1.onset, $0) })
            let nextHasRepeat = k + 1 < range.count && measures[mi + 1].leftRepeat

            for part in Set(slots.map(\.part)) {
                if let kind = md.bars[part], !(kind == .regular && nextHasRepeat) { bars.append((endX, kind, part)) }
                if md.leftRepeat, let off = pl.offset[.repeatStart] { repeatStarts.append((x0 + off, part)) }
            }

            for si in slots.indices {
                let sm = md.slots[si]
                // Furniture.
                if isFirst {
                    if let off = pl.offset[.clef] { bufs[si].items.append(clefItem(sm.clef, x: x0 + off)) }
                    if let off = pl.offset[.key] {
                        bufs[si].items += keySignature(sm.key, clef: sm.clef, from: nil, x: x0 + off).items
                    }
                } else {
                    if let off = pl.offset[.clef], let c = sm.startClefChange, c.printObject {
                        bufs[si].items.append(clefItem(c, x: x0 + off, scale: Self.smallClef))
                    }
                    if let off = pl.offset[.key], sm.keyChanged {
                        bufs[si].items += keySignature(sm.key, clef: sm.clef, from: sm.keyBefore, x: x0 + off).items
                    }
                }
                if let off = pl.offset[.time], sm.timeChanged, let t = sm.time {
                    bufs[si].items += timeSignature(t, x: x0 + off)
                }
                // Mid-measure clefs and keys, left of the column's graces and accidentals.
                for (o, c) in sm.midClefs where c.printObject {
                    if let i = columnIndex[o] {
                        bufs[si].items.append(clefItem(c, x: xs[i] - md.columns[i].leftW + 0.1, scale: Self.smallClef))
                    }
                }
                for mk in sm.midKeys {
                    if let i = columnIndex[mk.onset] {
                        let cx = xs[i] - md.columns[i].leftW + md.columns[i].clefW + 0.1
                        bufs[si].items += keySignature(mk.key, clef: sm.clef, from: mk.before, x: cx).items
                    }
                }
                if let c = sm.endClef, c.printObject {
                    bufs[si].items.append(clefItem(c, x: endX - barW - md.endClefW + 0.25, scale: Self.smallClef))
                }
                // Pass 1: position the groups.
                var graceLeft: [Rational: Double] = [:]
                for g in sm.groups {
                    guard let i = columnIndex[g.onset] else { continue }
                    var x = xs[i]
                    if g.grace {
                        let remaining = graceLeft[g.onset] ?? sm.groups.filter { $0.grace && $0.onset == g.onset }
                            .reduce(0) { $0 + $1.graceWidth }
                        x = xs[i] - md.columns[i].accW - remaining + g.leftW
                        graceLeft[g.onset] = remaining - g.graceWidth
                    } else if g.measureRest {
                        let mid = (bodyStart + (endX - md.endFixed)) / 2
                        x = mid - Glyph.rest(g.value).metrics.advance / 2
                    }
                    placed.append(PlacedGroup(group: g, x: x, slotIndex: si, stem: stemGeometry(g, x: x)))
                }
            }
            x0 = endX
        }
        let endX = x0

        // Between the passes: 4b adjusts stems (beams, flags) here, 4c places ties.
        // Pass 2: emit items.
        for p in placed { emit(p, into: &bufs[p.slotIndex]) }

        // Vertical placement.
        let numberRoom = options.showMeasureNumbers && range.lowerBound > 0 ? 2.6 : 0
        var tops: [Double] = []
        var y = systemTop + max(numberRoom, -bufs[0].minY)
        for si in slots.indices {
            tops.append(y)
            if si + 1 < slots.count {
                let samePart = slots[si].part == slots[si + 1].part
                let below = max(0, bufs[si].maxY - 4)
                let above = max(0, -bufs[si + 1].minY)
                let gap = max(samePart ? options.staffDistance : options.partDistance, below + above + 1.2)
                y += 4 + gap
            }
        }
        let bottom = (tops.last ?? systemTop) + max(4, bufs[bufs.count - 1].maxY)

        var items: [LayoutItem] = []
        var notes: [NoteID: LaidNote] = [:]
        var groups: [NoteID: [NoteID]] = [:]
        for (si, t) in tops.enumerated() {
            for i in 0..<5 {
                items.append(.line(from: CGPoint(x: staffLeft, y: t + Double(i)), to: CGPoint(x: endX, y: t + Double(i)),
                                   thickness: EngravingDefaults.staffLineThickness))
            }
            items += bufs[si].items.map { $0.translated(dy: t) }
            for n in bufs[si].notes {
                notes[n.id] = LaidNote(id: n.id, systemIndex: systemIndex, staffIndex: si,
                                       headBox: n.headBox.offsetBy(dx: 0, dy: t), groupID: n.groupID,
                                       stemEnd: n.stemEnd?.offset(dy: t), isRest: n.isRest)
            }
            groups.merge(bufs[si].groups) { a, _ in a }
        }

        // Barlines span all staves of a part.
        func partSpan(_ part: Int) -> (top: Double, bottom: Double, tops: [Double]) {
            let idx = slots.indices.filter { slots[$0].part == part }
            return (tops[idx.first!], tops[idx.last!] + 4, idx.map { tops[$0] })
        }
        for b in bars { items += barline(b.kind, rightEdge: b.x, span: partSpan(b.part)) }
        for r in repeatStarts { items += repeatStart(at: r.x, span: partSpan(r.part)) }
        // System barline.
        if let f = tops.first, let l = tops.last {
            items.append(.line(from: CGPoint(x: staffLeft + 0.08, y: f), to: CGPoint(x: staffLeft + 0.08, y: l + 4),
                               thickness: EngravingDefaults.thinBarlineThickness))
        }
        // Braces and bracket.
        for part in Set(slots.map(\.part)) {
            let idx = slots.indices.filter { slots[$0].part == part }
            if idx.count == 2 {
                let h = tops[idx[1]] + 4 - tops[idx[0]]
                let w = Glyph.brace.metrics.maxX * h / Glyph.standardSize
                items.append(.glyph(codepoint: Glyph.brace.codepoint, position: CGPoint(x: staffLeft - 0.3 - w, y: tops[idx[1]] + 4), size: h))
            }
        }
        if multiPart, let f = tops.first, let l = tops.last {
            let bx = 0.4
            items.append(.rect(CGRect(x: bx, y: f, width: EngravingDefaults.bracketThickness, height: l + 4 - f)))
            items.append(.glyph(codepoint: Glyph.bracketTop.codepoint, position: CGPoint(x: bx, y: f)))
            items.append(.glyph(codepoint: Glyph.bracketBottom.codepoint, position: CGPoint(x: bx, y: l + 4)))
        }
        // Measure number.
        if options.showMeasureNumbers, let f = tops.first, range.lowerBound > 0 {
            items.append(.text(measures[range.lowerBound].number, position: CGPoint(x: staffLeft + 0.2, y: f - 1.2),
                               style: TextStyle(size: 1.7, italic: true)))
        }

        // A measure wider than the page overflows; the frame reports what was really used.
        let content = endX + rightMargin
        let width: Double
        switch options.width {
        case .fixed(let w): width = max(w, content)
        case .singleLine: width = content
        }
        let frame = CGRect(x: 0, y: systemTop, width: width, height: bottom - systemTop + 0.5)
        let staves = slots.enumerated().map { LaidStaff(partIndex: $1.part, staffInPart: $1.staff, top: tops[$0]) }
        let system = LaidSystem(frame: frame, staves: staves, measureRange: range, items: items,
                                columns: laidColumns, measures: laidMeasures)
        return (system, notes, groups)
    }

    // MARK: Barlines

    private func barline(_ kind: BarKind, rightEdge r: Double, span: (top: Double, bottom: Double, tops: [Double])) -> [LayoutItem] {
        let thin = EngravingDefaults.thinBarlineThickness
        let thick = EngravingDefaults.thickBarlineThickness
        func line(_ rightX: Double) -> LayoutItem {
            .line(from: CGPoint(x: rightX - thin / 2, y: span.top), to: CGPoint(x: rightX - thin / 2, y: span.bottom), thickness: thin)
        }
        func heavy(_ rightX: Double) -> LayoutItem {
            .rect(CGRect(x: rightX - thick, y: span.top, width: thick, height: span.bottom - span.top))
        }
        switch kind {
        case .none: return []
        case .regular: return [line(r)]
        case .double: return [line(r), line(r - thin - 0.4)]
        case .heavy: return [heavy(r)]
        case .final: return [line(r - thick - 0.4), heavy(r)]
        case .repeatBackward:
            let thinRight = r - thick - 0.4
            var out = [line(thinRight), heavy(r)]
            let dotX = thinRight - thin - 0.16 - Glyph.repeatDot.metrics.advance
            for t in span.tops {
                for dy in [1.5, 2.5] {
                    out.append(.glyph(codepoint: Glyph.repeatDot.codepoint, position: CGPoint(x: dotX, y: t + dy)))
                }
            }
            return out
        }
    }

    private func repeatStart(at x: Double, span: (top: Double, bottom: Double, tops: [Double])) -> [LayoutItem] {
        let thin = EngravingDefaults.thinBarlineThickness
        let thick = EngravingDefaults.thickBarlineThickness
        var out: [LayoutItem] = [
            .rect(CGRect(x: x, y: span.top, width: thick, height: span.bottom - span.top)),
            .line(from: CGPoint(x: x + thick + 0.4 + thin / 2, y: span.top), to: CGPoint(x: x + thick + 0.4 + thin / 2, y: span.bottom), thickness: thin),
        ]
        let dotX = x + thick + 0.4 + thin + 0.16
        for t in span.tops {
            for dy in [1.5, 2.5] {
                out.append(.glyph(codepoint: Glyph.repeatDot.codepoint, position: CGPoint(x: dotX, y: t + dy)))
            }
        }
        return out
    }

    // MARK: Notes

    private static func dotPositions(_ g: Group) -> [(p: Int, note: HeadNote)] {
        // Dots sit in spaces: a head on a line takes the space above, or the one below when
        // the chord note above already has its dot there. Walk from the top.
        var used = Set<Int>()
        var out: [(Int, HeadNote)] = []
        for n in g.notes.reversed() {
            var p = (n.p & 1) == 0 ? n.p + 1 : n.p
            if used.contains(p), (n.p & 1) == 0 { p -= 2 }
            guard used.insert(p).inserted else { continue }
            out.append((p, n))
        }
        return out
    }

    /// Pass 1 for the stem: the placeholder rule (up if below the middle line, else down;
    /// an explicit `<stem>` wins). TODO(4b): flags, beams and proper stem lengths.
    func stemGeometry(_ g: Group, x: Double) -> StemGeometry? {
        guard !g.isRest, g.value != .whole, g.value != .breve else { return nil }
        let size: Double? = g.scale == 1 ? nil : g.size
        let hm = g.head.metrics
        let lowest = g.notes.first!, highest = g.notes.last!
        let thick = EngravingDefaults.stemThickness
        let len = stemLength * g.scale
        if g.stemUp {
            let a = hm.anchor("stemUpSE", size: size) ?? CGPoint(x: hm.maxX, y: -0.168)
            let sx = x + g.baseDX + a.x - thick / 2
            return StemGeometry(x: sx, yStart: StaffGeometry.y(lowest.p) + a.y,
                                yEnd: min(StaffGeometry.y(highest.p) - len, 2), up: true,
                                thickness: thick, attachedTo: lowest.note.id)
        }
        let a = hm.anchor("stemDownNW", size: size) ?? CGPoint(x: 0, y: 0.168)
        let sx = x + g.baseDX + a.x + thick / 2
        return StemGeometry(x: sx, yStart: StaffGeometry.y(highest.p) + a.y,
                            yEnd: max(StaffGeometry.y(lowest.p) + len, 2), up: false,
                            thickness: thick, attachedTo: highest.note.id)
    }

    /// Pass 2: turn a placed group into items.
    func emit(_ pg: PlacedGroup, into buf: inout StaffBuffer) {
        let g = pg.group
        let x = pg.x
        let scale = g.scale
        let size: Double? = scale == 1 ? nil : g.size
        let lead = g.leadID
        buf.groups[lead] = g.notes.map(\.note.id)
        if g.isRest {
            let id = g.notes[0].note.id
            let glyph = Glyph.rest(g.value)
            let y = (g.value == .whole || g.value == .breve) ? 1.0 : 2.0
            buf.glyph(glyph, at: CGPoint(x: x, y: y), id: id)
            buf.notes.append(LocalNote(id: id, headBox: glyph.metrics.box(at: CGPoint(x: x, y: y)), groupID: lead,
                                       stemEnd: nil, isRest: true))
            if g.dots > 0 {
                var dx = x + glyph.metrics.advance + 0.4
                for _ in 0..<g.dots {
                    buf.glyph(.augmentationDot, at: CGPoint(x: dx, y: 1.5), id: id)
                    dx += 0.55
                }
            }
            return
        }
        let head = g.head
        let hm = head.metrics
        var ledgers: [Int: (minX: Double, maxX: Double)] = [:]
        for n in g.notes {
            let hx = x + g.baseDX + n.dx
            let origin = CGPoint(x: hx, y: StaffGeometry.y(n.p))
            buf.glyph(head, at: origin, size: size, id: n.note.id)
            let box = hm.box(at: origin, size: size)
            buf.notes.append(LocalNote(id: n.note.id, headBox: box, groupID: lead,
                                       stemEnd: pg.stem.map { CGPoint(x: $0.x, y: $0.yEnd) }, isRest: false))
            for p in StaffGeometry.ledgerPositions(n.p) {
                let lo = hx - EngravingDefaults.legerLineExtension * scale
                let hi = hx + g.headWidth + EngravingDefaults.legerLineExtension * scale
                if var l = ledgers[p] { l.minX = min(l.minX, lo); l.maxX = max(l.maxX, hi); ledgers[p] = l }
                else { ledgers[p] = (lo, hi) }
            }
        }
        // Ledger lines are shared by the chord: group items.
        for (p, l) in ledgers.sorted(by: { $0.key < $1.key }) {
            let y = StaffGeometry.y(p)
            buf.items.append(.line(from: CGPoint(x: l.minX, y: y), to: CGPoint(x: l.maxX, y: y),
                                   thickness: EngravingDefaults.legerLineThickness, groupID: lead))
        }
        // Accidentals, nearest column first.
        let leftmost = x + g.baseDX + (g.notes.map(\.dx).min() ?? 0)
        for n in g.notes {
            guard let acc = n.acc else { continue }
            let am = acc.metrics
            var right = leftmost - 0.2 * scale
            for j in 0..<n.accCol { right -= g.accColW[j] }
            let pl = Glyph.accidentalParensLeft.metrics.advance * scale
            let pr = Glyph.accidentalParensRight.metrics.advance * scale
            let bw = am.advance * scale + (n.parens ? pl + pr : 0)
            var cx = right - bw
            let y = StaffGeometry.y(n.p)
            if n.parens { buf.glyph(.accidentalParensLeft, at: CGPoint(x: cx, y: y), size: size, id: n.note.id); cx += pl }
            buf.glyph(acc, at: CGPoint(x: cx, y: y), size: size, id: n.note.id)
            cx += am.advance * scale
            if n.parens { buf.glyph(.accidentalParensRight, at: CGPoint(x: cx, y: y), size: size, id: n.note.id) }
        }
        // Stem (a group item).
        if let s = pg.stem {
            buf.items.append(.line(from: CGPoint(x: s.x, y: s.yStart), to: CGPoint(x: s.x, y: s.yEnd),
                                   thickness: s.thickness, groupID: lead))
            buf.grow(CGRect(x: s.x, y: min(s.yStart, s.yEnd), width: s.thickness, height: abs(s.yEnd - s.yStart)))
        }
        // Dots, each belonging to its note.
        if g.dots > 0 {
            let maxDX = g.notes.map(\.dx).max() ?? 0
            for (p, n) in Self.dotPositions(g) {
                var dx = x + g.baseDX + maxDX + g.headWidth + 0.4 * scale
                for _ in 0..<g.dots {
                    buf.glyph(.augmentationDot, at: CGPoint(x: dx, y: StaffGeometry.y(p)), size: size, id: n.note.id)
                    dx += 0.55 * scale
                }
            }
        }
        // Fingering: above a down stem's highest head, below an up stem's lowest.
        // TODO(4b): chord fingerings and stem/beam collisions.
        if options.showFingering, !g.grace {
            let up = g.stemUp
            let target = up ? g.notes.first! : g.notes.last!
            if let f = target.note.fingering?.first, let d = f.wholeNumberValue, d <= 5 {
                let glyph = [Glyph.fingering0, .fingering1, .fingering2, .fingering3, .fingering4, .fingering5][d]
                let m = glyph.metrics
                let hx = x + g.baseDX + target.dx + g.headWidth / 2
                let ox = hx - (m.minX + m.maxX) / 2 * 0.75
                let hy = StaffGeometry.y(target.p)
                let oy = up ? max(hy + 2.0, 5.2) : min(hy - 1.0, -1.2)
                buf.glyph(glyph, at: CGPoint(x: ox, y: oy), size: 3, id: target.note.id)
            }
        }
    }
}
