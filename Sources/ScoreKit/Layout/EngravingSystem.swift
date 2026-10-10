import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A note recorded in staff-local coordinates, converted when the system is assembled.
struct LocalNote {
    var id: NoteID
    var headBox: CGRect
    var groupID: NoteID
    var stemEnd: CGPoint?
    var isRest: Bool
    var isGrace = false
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
    /// Beam to its member groups, in time order.
    var beams: [BeamID: [NoteID]] = [:]
    /// Second note of a shared head to the first.
    var shared: [NoteID: NoteID] = [:]
    /// Notation marks (slurs, dynamics ...) and the range of `items` each one drew.
    var marks: [(kind: LaidMark.Kind, items: Range<Int>)] = []
    /// Per group (by lead note): the outer edge of its stack of articulations and the side it is on,
    /// where a slur at the group starts or ends.
    var articulationEdge: [NoteID: (above: Bool, y: Double)] = [:]

    /// Adds the items of one notation mark.
    mutating func addMark(_ kind: LaidMark.Kind, _ new: [LayoutItem]) {
        let start = items.count
        items += new
        marks.append((kind, start..<items.count))
    }

    mutating func grow(_ r: CGRect) {
        minY = min(minY, r.minY)
        maxY = max(maxY, r.maxY)
    }

    /// Widens the extent to cover every item's ink, with a little air.
    mutating func fitExtent() {
        var lo = Double.infinity, hi = -Double.infinity
        for it in items {
            let b = it.bounds
            if b.isNull { continue }
            lo = min(lo, b.minY); hi = max(hi, b.maxY)
        }
        minY = min(minY, lo - 0.25)
        maxY = max(maxY, hi + 0.25)
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
    /// Drawn under a beam: no flag, and the stem is cut to the beam.
    var beamed = false
    /// The measure it is in (0-based index).
    var measure = 0
}

/// What laying out one system produces.
struct SystemResult {
    var system: LaidSystem
    var notes: [NoteID: LaidNote]
    var groups: [NoteID: [NoteID]]
    var beams: [BeamID: [NoteID]]
    var sharedHeads: [NoteID: NoteID]
    var noteTimes: [NoteID: NoteTime] = [:]
}

/// The placed groups of one staff-measure, with the beams and tuplets that span them.
struct StaffMeasurePlacement {
    var slot: Int
    /// Index into the system's placed groups for each of the staff-measure's groups (-1: none).
    var pidx: [Int]
    var beams: [BeamGroup]
    var tuplets: [TupletSpan]
}

extension Engraving {
    func layoutSystem(_ measures: [MeasureData], _ range: Range<Int>, systemIndex: Int, top systemTop: Double,
                      justify: Bool, targetWidth: Double?) -> SystemResult {
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
        var repeatStarts: [(x: Double, part: Int, shared: Bool)] = []
        var laidColumns: [LaidColumn] = []
        var laidMeasures: [LaidMeasure] = []
        var placed: [PlacedGroup] = []
        var slotMeasures: [StaffMeasurePlacement] = []
        var noteTimes: [NoteID: NoteTime] = [:]
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
                // A repeat start replaces a plain, double, final or heavy line before it, and shares
                // the closing repeat's heavy line (:||:).
                if let kind = md.bars[part] {
                    let replaced = nextHasRepeat && kind != .none && kind != .repeatBackward && kind != .dashed
                        && kind != .dotted && kind != .tick && kind != .short
                    if !replaced { bars.append((endX, kind, part)) }
                }
                if md.leftRepeat, let off = pl.offset[.repeatStart] {
                    let shared = k > 0 && measures[mi - 1].bars[part] == .repeatBackward
                    repeatStarts.append((x0 + off, part, shared))
                }
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
                var pidx = [Int](repeating: -1, count: sm.groups.count)
                for (gi, g) in sm.groups.enumerated() {
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
                    pidx[gi] = placed.count
                    for hn in g.notes { noteTimes[hn.note.id] = NoteTime(measureIndex: mi, onset: g.onset) }
                    placed.append(PlacedGroup(group: g, x: x, slotIndex: si, stem: stemGeometry(g, x: x), measure: mi))
                }
                slotMeasures.append(StaffMeasurePlacement(slot: si, pidx: pidx, beams: sm.beams, tuplets: sm.tuplets))
            }
            x0 = endX
        }
        let endX = x0

        // Between the passes: beams cut the stems of their groups, then tuplets sit outside them
        // (4c places ties here).
        for sm in slotMeasures {
            for b in sm.beams { layoutBeam(b, sm.pidx, &placed, &bufs[sm.slot]) }
        }
        for sm in slotMeasures {
            for t in sm.tuplets { layoutTuplet(t, sm.pidx, placed, &bufs[sm.slot]) }
        }
        // Pass 2: emit items.
        for p in placed { emit(p, into: &bufs[p.slotIndex]) }
        layoutTies(range: range, placed: placed, measures: measures, laid: laidMeasures, bufs: &bufs)
        var pageLimit: Double?
        if case .fixed(let w) = options.width { pageLimit = w - rightMargin }
        let crossStaff = layoutNotation(range: range, measures: measures, laid: laidMeasures, placed: placed, bufs: &bufs)
        layoutOverlays(range: range, measures: measures, laid: laidMeasures, limit: pageLimit, buf: &bufs[0])
        for i in bufs.indices { bufs[i].fitExtent() }

        // Vertical placement.
        var tops: [Double] = []
        var y = systemTop + (-bufs[0].minY)
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
        var beamMap: [BeamID: [NoteID]] = [:]
        var sharedMap: [NoteID: NoteID] = [:]
        var laidMarks: [LaidMark] = []
        for (si, t) in tops.enumerated() {
            for i in 0..<5 {
                items.append(.line(from: CGPoint(x: staffLeft, y: t + Double(i)), to: CGPoint(x: endX, y: t + Double(i)),
                                   thickness: EngravingDefaults.staffLineThickness))
            }
            let base = items.count
            items += bufs[si].items.map { $0.translated(dy: t) }
            for m in bufs[si].marks {
                laidMarks.append(LaidMark(kind: m.kind, staffIndex: si, items: (base + m.items.lowerBound)..<(base + m.items.upperBound)))
            }
            for n in bufs[si].notes {
                notes[n.id] = LaidNote(id: n.id, systemIndex: systemIndex, staffIndex: si,
                                       headBox: n.headBox.offsetBy(dx: 0, dy: t), groupID: n.groupID,
                                       stemEnd: n.stemEnd?.offset(dy: t), isRest: n.isRest, isGrace: n.isGrace)
            }
            groups.merge(bufs[si].groups) { a, _ in a }
            beamMap.merge(bufs[si].beams) { a, _ in a }
            sharedMap.merge(bufs[si].shared) { a, _ in a }
        }

        // Slurs between two staves, now that the staves have places.
        for p in crossStaff.slurs {
            var q = p
            q.y1 += tops[p.slot]
            q.y2 += tops[p.endSlot!]
            let slurItems = Set(laidMarks.filter { $0.kind == .slur || $0.kind == .crossStaffSlur }.flatMap { Array($0.items) })
            let inkItems = Set(laidMarks.filter { Self.slurObstacles.contains($0.kind) }.flatMap { Array($0.items) })
            let item = crossStaffSlurItem(q, items: items, slurItems: slurItems, inkItems: inkItems)
            laidMarks.append(LaidMark(kind: .crossStaffSlur, staffIndex: p.slot, items: items.count..<(items.count + 1)))
            items.append(item)
        }

        // Arpeggios between two staves.
        for a in crossStaff.arpeggios {
            let new = Self.arpeggioItems(x: a.x, y1: a.y1 + tops[a.slot], y2: a.y2 + tops[a.endSlot], up: a.up)
            laidMarks.append(LaidMark(kind: .arpeggio, staffIndex: a.slot, items: items.count..<(items.count + new.count)))
            items += new
        }

        // Barlines span all staves of a part.
        func partSpan(_ part: Int) -> (top: Double, bottom: Double, tops: [Double]) {
            let idx = slots.indices.filter { slots[$0].part == part }
            return (tops[idx.first!], tops[idx.last!] + 4, idx.map { tops[$0] })
        }
        for b in bars { items += barline(b.kind, rightEdge: b.x, span: partSpan(b.part)) }
        for r in repeatStarts { items += repeatStart(at: r.x, shared: r.shared, span: partSpan(r.part)) }
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
        // A measure wider than the page overflows; the frame reports what was really used, and
        // it covers every item's ink.
        var ink = CGRect.null
        for it in items { ink = ink.union(it.bounds) }
        let content = max(endX + rightMargin, ink.isNull ? 0 : ink.maxX)
        let width: Double
        switch options.width {
        case .fixed(let w): width = content > w + 1e-6 ? content : w
        case .singleLine: width = content
        }
        let frameTop = min(systemTop, ink.isNull ? systemTop : ink.minY)
        let frameBottom = max(bottom + 0.5, ink.isNull ? 0 : ink.maxY)
        let frame = CGRect(x: 0, y: frameTop, width: width, height: frameBottom - frameTop)
        let staves = slots.enumerated().map { LaidStaff(partIndex: $1.part, staffInPart: $1.staff, top: tops[$0]) }
        let system = LaidSystem(frame: frame, staves: staves, measureRange: range, items: items,
                                columns: laidColumns, measures: laidMeasures, marks: laidMarks)
        return SystemResult(system: system, notes: notes, groups: groups, beams: beamMap, sharedHeads: sharedMap,
                            noteTimes: noteTimes)
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
        func dashes(_ rightX: Double, on: Double, off: Double) -> [LayoutItem] {
            let x = rightX - thin / 2
            var out: [LayoutItem] = []
            for t in span.tops {
                var y = t
                while y < t + 4 - 1e-9 {
                    out.append(.line(from: CGPoint(x: x, y: y), to: CGPoint(x: x, y: min(y + on, t + 4)), thickness: thin))
                    y += on + off
                }
            }
            return out
        }
        switch kind {
        case .none: return []
        case .dashed: return dashes(r, on: 0.6, off: 0.4)
        case .dotted: return dashes(r, on: 0.16, off: 0.34)
        case .tick:
            return span.tops.map { t in
                .line(from: CGPoint(x: r - thin / 2, y: t - 0.5), to: CGPoint(x: r - thin / 2, y: t + 0.5), thickness: thin)
            }
        case .short:
            return span.tops.map { t in
                .line(from: CGPoint(x: r - thin / 2, y: t + 1), to: CGPoint(x: r - thin / 2, y: t + 3), thickness: thin)
            }
        case .heavyLight: return [line(r), heavy(r - thin - 0.4)]
        case .heavyHeavy: return [heavy(r), heavy(r - thick - 0.4)]
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

    private func repeatStart(at x0: Double, shared: Bool, span: (top: Double, bottom: Double, tops: [Double])) -> [LayoutItem] {
        let thin = EngravingDefaults.thinBarlineThickness
        let thick = EngravingDefaults.thickBarlineThickness
        // Shared with a closing repeat's heavy line just before it: only the thin line and dots.
        let x = shared ? x0 - thick : x0
        var out: [LayoutItem] = shared ? [] : [
            .rect(CGRect(x: x, y: span.top, width: thick, height: span.bottom - span.top)),
        ]
        out += [
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
        for n in g.notes.reversed() where n.sharedWith == nil {
            var p = (n.p & 1) == 0 ? n.p + 1 : n.p
            if used.contains(p), (n.p & 1) == 0 { p -= 2 }
            guard used.insert(p).inserted else { continue }
            out.append((p, n))
        }
        return out
    }

    /// Pass 1 for the stem: direction comes from the analysis (`Group.stemUp`); the length is
    /// 3.5 sp from the far head, reaching the middle line at least, and longer for 32nd and
    /// shorter flags. Beams replace the tip later.
    func stemGeometry(_ g: Group, x: Double) -> StemGeometry? {
        guard !g.isRest, !g.stemNone, g.value != .whole, g.value != .breve else { return nil }
        let size: Double? = g.scale == 1 ? nil : g.size
        let hm = g.head.metrics
        let lowest = g.notes.first!, highest = g.notes.last!
        let thick = EngravingDefaults.stemThickness
        let levels = g.beamIndex == nil ? beamLevel(g.value) : 1
        let len = (stemLength + Double(max(0, levels - 2)) * 0.75) * g.scale
        if g.stemUp {
            let a = hm.anchor("stemUpSE", size: size) ?? CGPoint(x: hm.maxX, y: -0.168)
            let sx = x + g.baseDX + a.x - thick / 2
            let tip = flagClearOfDots(g, x: x, stemX: sx, thickness: thick, yEnd: min(StaffGeometry.y(highest.p) - len, 2), up: true)
            return StemGeometry(x: sx, yStart: StaffGeometry.y(lowest.p) + a.y,
                                yEnd: tip, up: true,
                                thickness: thick, attachedTo: lowest.note.id)
        }
        let a = hm.anchor("stemDownNW", size: size) ?? CGPoint(x: 0, y: 0.168)
        let sx = x + g.baseDX + a.x + thick / 2
        let tip = flagClearOfDots(g, x: x, stemX: sx, thickness: thick, yEnd: max(StaffGeometry.y(lowest.p) + len, 2), up: false)
        return StemGeometry(x: sx, yStart: StaffGeometry.y(highest.p) + a.y,
                            yEnd: tip, up: false,
                            thickness: thick, attachedTo: highest.note.id)
    }

    /// The stem tip of an unbeamed dotted note, lengthened (by quarter spaces) until its flag no
    /// longer covers the augmentation dots, which sit right of the heads at head height.
    private func flagClearOfDots(_ g: Group, x: Double, stemX: Double, thickness: Double, yEnd: Double, up: Bool) -> Double {
        let levels = beamLevel(g.value)
        guard g.dots > 0, g.beamIndex == nil, levels > 0, let flag = Glyph.flag(levels: levels, up: up) else { return yEnd }
        let size: Double? = g.scale == 1 ? nil : g.size
        let a = flag.metrics.anchor(up ? "stemUpNW" : "stemDownSW", size: size) ?? .zero
        let maxDX = g.notes.map(\.dx).max() ?? 0
        let dot0 = x + g.baseDX + maxDX + g.headWidth + 0.4 * g.scale + g.dotExtra
        let dotsRect = Self.dotPositions(g).map { d in
            CGRect(x: dot0, y: StaffGeometry.y(d.p) - 0.25, width: 0.55 * Double(g.dots) * g.scale, height: 0.5)
        }
        var tip = yEnd
        for _ in 0..<16 {
            let o = CGPoint(x: stemX - thickness / 2 - a.x, y: tip - a.y)
            let box = flag.metrics.box(at: o, size: size)
            if !dotsRect.contains(where: { $0.intersects(box.insetBy(dx: -0.1, dy: -0.2)) }) { break }
            tip += up ? -0.25 : 0.25
        }
        return tip
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
            let y = ((g.value == .whole || g.value == .breve) ? 1.0 : 2.0) + g.restDY
            buf.glyph(glyph, at: CGPoint(x: x, y: y), id: id)
            buf.notes.append(LocalNote(id: id, headBox: glyph.metrics.box(at: CGPoint(x: x, y: y)), groupID: lead,
                                       stemEnd: nil, isRest: true))
            if g.dots > 0 {
                var dx = x + glyph.metrics.advance + 0.4
                for _ in 0..<g.dots {
                    buf.glyph(.augmentationDot, at: CGPoint(x: dx, y: 1.5 + g.restDY), id: id)
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
            if let other = n.sharedWith { buf.shared[n.note.id] = other }
            else { buf.glyph(head, at: origin, size: size, id: n.note.id) }
            let box = hm.box(at: origin, size: size)
            buf.notes.append(LocalNote(id: n.note.id, headBox: box, groupID: lead,
                                       stemEnd: pg.stem.map { CGPoint(x: $0.x, y: $0.yEnd) }, isRest: false, isGrace: g.grace))
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
        let leftmost = x + (g.leftEdge ?? (g.baseDX + (g.notes.map(\.dx).min() ?? 0)))
        for n in g.notes {
            guard let acc = n.acc, n.sharedWith == nil else { continue }
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
            // Flag on an unbeamed stem.
            let levels = beamLevel(g.value)
            if !pg.beamed, levels > 0, let flag = Glyph.flag(levels: levels, up: s.up) {
                let a = flag.metrics.anchor(s.up ? "stemUpNW" : "stemDownSW", size: size) ?? .zero
                let o = CGPoint(x: s.x - s.thickness / 2 - a.x, y: s.yEnd - a.y)
                buf.items.append(.glyph(codepoint: flag.codepoint, position: o, size: size, groupID: lead))
                buf.grow(flag.metrics.box(at: o, size: size))
            }
        }
        // Dots, each belonging to its note.
        if g.dots > 0 {
            let maxDX = g.notes.map(\.dx).max() ?? 0
            for (p, n) in Self.dotPositions(g) {
                var dx = x + g.baseDX + maxDX + g.headWidth + 0.4 * scale + g.dotExtra
                for _ in 0..<g.dots {
                    buf.glyph(.augmentationDot, at: CGPoint(x: dx, y: StaffGeometry.y(p)), size: size, id: n.note.id)
                    dx += 0.55 * scale
                }
            }
        }
        emitFingering(pg, into: &buf)
    }
}

extension Engraving {
    /// One fingering label: a run of digit glyphs (and hyphens for "3-4"), centred on `cx`.
    private func fingeringItems(_ text: String, cx: Double, baseline: Double, size: Double, id: NoteID) -> [LayoutItem] {
        let digits = [Glyph.fingering0, .fingering1, .fingering2, .fingering3, .fingering4, .fingering5]
        let k = size / Glyph.standardSize
        enum Piece { case digit(Glyph), dash }
        var pieces: [Piece] = []
        for ch in text {
            if let d = ch.wholeNumberValue, d <= 5 { pieces.append(.digit(digits[d])) }
            else if "-\u{2013}\u{2014}".contains(ch) { pieces.append(.dash) }
        }
        let dashW = 0.5
        var width = 0.0
        for p in pieces { if case .digit(let g) = p { width += g.metrics.advance * k } else { width += dashW } }
        var x = cx - width / 2
        var out: [LayoutItem] = []
        for p in pieces {
            switch p {
            case .digit(let g):
                out.append(.glyph(codepoint: g.codepoint, position: CGPoint(x: x, y: baseline), size: size, noteID: id))
                x += g.metrics.advance * k
            case .dash:
                out.append(.line(from: CGPoint(x: x + 0.1, y: baseline - 0.38), to: CGPoint(x: x + dashW - 0.1, y: baseline - 0.38),
                                 thickness: 0.1, noteID: id))
                x += dashW
            }
        }
        return out
    }

    /// Fingering sits outside the staff, on the side away from the stem (with two voices:
    /// above for the upper voice, below for the lower one, past the stem tip and any beam), or
    /// where `placement` says. Every fingered note of a chord gets its digits in a stack in
    /// pitch order. Digits keep clear of tuplet numbers and brackets on their side.
    func emitFingering(_ pg: PlacedGroup, into buf: inout StaffBuffer) {
        let g = pg.group
        guard options.showFingering, !g.grace, !g.isRest else { return }
        let size = 3.0
        let fingered = g.notes.filter { ($0.note.fingering ?? "").contains { $0.isNumber } }
        guard !fingered.isEmpty else { return }
        var above = g.multiVoice ? g.stemUp : !g.stemUp
        if let placement = fingered.compactMap(\.note.fingeringPlacement).first {
            if placement == "above" { above = true } else if placement == "below" { above = false }
        }
        // Nearest the chord first: the lowest note's digits when above, the highest when below.
        let stack = above ? fingered : fingered.reversed()
        let top = StaffGeometry.y(g.notes.last!.p) - 0.5
        let bottom = StaffGeometry.y(g.notes.first!.p) + 0.5
        var baseline: Double
        if above {
            var edge = min(top, -0.7)
            if let s = pg.stem, s.up { edge = min(edge, s.yEnd) }
            baseline = edge - 0.5
        } else {
            var edge = max(bottom, 3.7)
            if let s = pg.stem, !s.up { edge = max(edge, s.yEnd) }
            baseline = edge + 1.5
        }
        let step = 1.0
        let cxChord = pg.x + g.baseDX + ((g.notes.map(\.dx).min() ?? 0) + (g.notes.map(\.dx).max() ?? 0)) / 2 + g.headWidth / 2
        func place(_ base: Double) -> [LayoutItem] {
            var out: [LayoutItem] = []
            var b = base
            for n in stack {
                let cx = stack.count > 1 ? cxChord : pg.x + g.baseDX + n.dx + g.headWidth / 2
                out += fingeringItems(n.note.fingering!, cx: cx, baseline: b, size: size, id: n.note.id)
                b += above ? -step : step
            }
            return out
        }
        // Tuplet numbers and brackets already placed on this staff.
        let tupletDigits = Set((0...9).map { Glyph.tupletDigit($0).codepoint })
        let tuplets: [CGRect] = buf.items.compactMap { it in
            switch it {
            case .glyph(let cp, _, _, nil, nil) where tupletDigits.contains(cp): return it.bounds
            case .line(_, _, let t, nil, nil) where t == EngravingDefaults.tupletBracketThickness: return it.bounds
            default: return nil
            }
        }
        var items = place(baseline)
        for _ in 0..<12 {
            let hit = items.contains { it in tuplets.contains { $0.insetBy(dx: -0.1, dy: -0.1).intersects(it.bounds) } }
            if !hit { break }
            baseline += above ? -0.4 : 0.4
            items = place(baseline)
        }
        buf.items += items
    }
}
