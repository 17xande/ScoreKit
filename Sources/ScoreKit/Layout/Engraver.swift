import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Lays a `Score` out into systems of pure geometry (staff spaces, y down). No rendering.
public enum Engraver {
    public static func layout(_ score: Score, options: LayoutOptions = .default) -> ScoreLayout {
        Engraving(score: score, options: options).run()
    }
}

extension Score {
    /// Engrave this score: see `LayoutOptions` and `ScoreLayout`.
    public func layout(_ options: LayoutOptions = .default) -> ScoreLayout {
        Engraver.layout(self, options: options)
    }
}

let stemLength = 3.5
let rightMargin = 0.5

struct Engraving {
    let score: Score
    let options: LayoutOptions
    let slots: [Slot]
    let measureCount: Int
    /// Ties and volta brackets, planned over the whole score before it is broken into systems.
    let ties: [TieSpec]
    let voltas: [VoltaSpec]
    let slurs: [SlurSpec]
    let wavyLines: [WavySpec]

    init(score: Score, options: LayoutOptions) {
        self.score = score
        self.options = options
        var s: [Slot] = []
        if let sel = options.staves {
            for r in sel where r.part >= 0 && r.part < score.parts.count && r.staff >= 1 && r.staff <= max(1, score.parts[r.part].staves) {
                let slot = Slot(part: r.part, staff: r.staff)
                if !s.contains(slot) { s.append(slot) }
            }
            s.sort { ($0.part, $0.staff) < ($1.part, $1.staff) }
        } else {
            for (pi, p) in score.parts.enumerated() { for st in 1...max(1, p.staves) { s.append(Slot(part: pi, staff: st)) } }
        }
        if options.hideEmptyStaves {
            let kept = s.filter { slot in
                score.parts[slot.part].measures.contains { $0.notes.contains { $0.staff == slot.staff && !$0.isRest } }
            }
            if !kept.isEmpty { s = kept }
        }
        slots = s
        measureCount = Set(s.map(\.part)).map { score.parts[$0].measures.count }.max() ?? 0
        ties = Self.pairTies(score, parts: Array(Set(s.map(\.part))).sorted())
        voltas = s.first.map { Self.planVoltas(score, part: $0.part) } ?? []
        slurs = Self.pairSlurs(score, parts: Array(Set(s.map(\.part))).sorted())
        wavyLines = Self.pairWavy(score, parts: Array(Set(s.map(\.part))).sorted())
    }

    // MARK: Run

    func run() -> ScoreLayout {
        guard !slots.isEmpty, measureCount > 0 else {
            return ScoreLayout(size: CGSize(width: 0, height: 0), systems: [], notes: [:], noteBoxes: [:], groups: [:], beams: [:], sharedHeads: [:])
        }
        let measures = analyze()
        let ranges: [Range<Int>]
        var target: Double?
        switch options.width {
        case .singleLine:
            ranges = [0..<measureCount]
        case .fixed(let w):
            target = w
            ranges = breakLines(measures, available: w - staffLeft - rightMargin)
        }
        var systems: [LaidSystem] = []
        var notes: [NoteID: LaidNote] = [:]
        var groups: [NoteID: [NoteID]] = [:]
        var beams: [BeamID: [NoteID]] = [:]
        var shared: [NoteID: NoteID] = [:]
        var times: [NoteID: NoteTime] = [:]
        var y = 0.0
        var maxWidth = 0.0
        for (i, r) in ranges.enumerated() {
            let last = i == ranges.count - 1
            let res = layoutSystem(measures, r, systemIndex: i, top: y, justify: !last && target != nil, targetWidth: target)
            let sys = res.system
            systems.append(sys)
            notes.merge(res.notes) { a, _ in a }
            groups.merge(res.groups) { a, _ in a }
            beams.merge(res.beams) { a, _ in a }
            shared.merge(res.sharedHeads) { a, _ in a }
            times.merge(res.noteTimes) { a, _ in a }
            y = sys.frame.maxY + options.systemDistance
            maxWidth = max(maxWidth, sys.frame.width)
        }
        let height = (systems.last?.frame.maxY ?? 0) + 0.5
        var boxes: [NoteID: CGRect] = [:]
        for (id, n) in notes where !n.isRest { boxes[id] = n.headBox }
        // The width is the target, or more when a measure did not fit.
        var tiedFrom: [NoteID: NoteID] = [:]
        for t in ties {
            if let a = t.start, let b = t.end, notes[a] != nil, notes[b] != nil { tiedFrom[b] = a }
        }
        var result = ScoreLayout(size: CGSize(width: max(target ?? 0, maxWidth), height: height), systems: systems,
                                 notes: notes, noteBoxes: boxes, groups: groups, beams: beams, sharedHeads: shared)
        result.tiedFrom = tiedFrom
        result.noteTimes = times
        result.buildIndexes()
        return result
    }

    var multiPart: Bool { Set(slots.map(\.part)).count > 1 }
    var hasBrace: Bool { Dictionary(grouping: slots, by: \.part).values.contains { $0.count == 2 } }
    var staffLeft: Double { 0.4 + (multiPart ? 1.4 : 0) + (hasBrace ? 1.6 : 0) + 0.4 }

    // MARK: Furniture planning

    enum FKind: Hashable { case repeatStart, clef, key, time }
    struct Plan { var offset: [FKind: Double] = [:]; var total = 0.0 }

    static let smallClef = 0.75

    func plan(_ m: MeasureData, first: Bool) -> Plan {
        var widths: [FKind: Double] = [:]
        if first {
            widths[.clef] = m.slots.map { ClefShape($0.clef).glyph.metrics.advance }.max()
            let k = m.slots.map { keySignature($0.key, clef: $0.clef, from: nil, x: 0).width }.max() ?? 0
            if k > 0 { widths[.key] = k }
            if m.slots.contains(where: { $0.timeChanged && $0.time != nil }) {
                widths[.time] = m.slots.compactMap { $0.time.map(timeSignatureWidth) }.max()
            }
        } else {
            let c = m.slots.filter { $0.startClefChange?.printObject == true }
                .map { ClefShape($0.startClefChange!).glyph.metrics.advance * Self.smallClef }.max()
            if let c { widths[.clef] = c }
            let k = m.slots.filter(\.keyChanged).map { keySignature($0.key, clef: $0.clef, from: $0.keyBefore, x: 0).width }.max()
            if let k, k > 0 { widths[.key] = k }
            if m.slots.contains(where: { $0.timeChanged && $0.time != nil }) {
                widths[.time] = m.slots.filter(\.timeChanged).compactMap { $0.time.map(timeSignatureWidth) }.max()
            }
        }
        if m.leftRepeat { widths[.repeatStart] = 1.62 }
        guard !widths.isEmpty else { return Plan() }
        let order: [FKind] = first ? [.clef, .key, .time, .repeatStart] : [.repeatStart, .clef, .key, .time]
        var p = Plan()
        var cursor = first ? 0.7 : (m.leftRepeat ? 0 : 0.5)
        for k in order {
            guard let w = widths[k] else { continue }
            p.offset[k] = cursor
            cursor += w + (k == .repeatStart ? 0.5 : 0.7)
        }
        p.total = cursor
        return p
    }

    // MARK: Line breaking

    func breakLines(_ ms: [MeasureData], available: Double) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        var used = 0.0
        for i in 0..<ms.count {
            let w = plan(ms[i], first: i == start).total + ms[i].gaps.reduce(0, +) + ms[i].endFixed
            if i > start, used + w > available {
                out.append(start..<i)
                start = i
                used = plan(ms[i], first: true).total + ms[i].gaps.reduce(0, +) + ms[i].endFixed
            } else {
                used += w
            }
        }
        out.append(start..<ms.count)
        return out
    }

    // MARK: Signature glyphs

    /// Key signature glyphs at `x` (staff-local y) and the width they take. `from` is the
    /// previous key when it must be cancelled with naturals first.
    func keySignature(_ key: Key, clef: Clef, from old: Key?, x: Double) -> (items: [LayoutItem], width: Double) {
        var items: [LayoutItem] = []
        var cursor = x
        func put(_ g: Glyph, _ p: Int) {
            items.append(.glyph(codepoint: g.codepoint, position: CGPoint(x: cursor, y: StaffGeometry.y(p))))
            cursor += g.metrics.advance + 0.12
        }
        if let old, old.fifths != 0, !old.nonTraditional {
            // Naturals go on the letters the new key signature alters less than the old one:
            // all of them when the sign changes, and none that stay or gain accidentals.
            let order = old.fifths > 0 ? StaffGeometry.sharpOrder : StaffGeometry.flatOrder
            let count = StaffGeometry.keyGlyphCount(old.fifths)
            let signChanges = key.fifths == 0 || (key.fifths > 0) != (old.fifths > 0)
            let cancel = (0..<count).filter {
                signChanges || abs(StaffGeometry.keyAlter(fifths: key.fifths, step: order[$0]))
                    < abs(StaffGeometry.keyAlter(fifths: old.fifths, step: order[$0]))
            }
            if !cancel.isEmpty {
                let ps = StaffGeometry.keySignaturePositions(sharps: old.fifths > 0, count: count, clef: clef)
                for i in cancel { put(.accidentalNatural, ps[i]) }
                if key.fifths != 0 { cursor += 0.3 }
            }
        }
        if key.fifths != 0, !key.nonTraditional {
            let ps = StaffGeometry.keySignaturePositions(sharps: key.fifths > 0, count: StaffGeometry.keyGlyphCount(key.fifths), clef: clef)
            for (i, p) in ps.enumerated() {
                // Theoretical keys (past 7): every letter keeps its usual place and the first
                // letters in order (F, C, G... or B, E, A...) are doubled in place, so 10 sharps
                // is F## C## G## D# A# E# B# (the usual convention; Behind Bars, key signatures).
                let doubled = i < min(abs(key.fifths), StaffGeometry.maxKeyFifths) - 7
                put(key.fifths > 0 ? (doubled ? .accidentalDoubleSharp : .accidentalSharp)
                                   : (doubled ? .accidentalDoubleFlat : .accidentalFlat), p)
            }
        }
        return (items, max(0, cursor - x - (items.isEmpty ? 0 : 0.12)))
    }

    func timeSignatureWidth(_ t: TimeSignature) -> Double {
        switch t.symbol {
        case .common: return Glyph.timeSigCommon.metrics.advance
        case .cut: return Glyph.timeSigCutCommon.metrics.advance
        case nil: return max(digitsWidth(t.beats), digitsWidth(t.beatType))
        }
    }

    private func digitsWidth(_ n: Int) -> Double {
        String(n).compactMap { $0.wholeNumberValue }.reduce(0) { $0 + Glyph.timeDigit($1).metrics.advance }
    }

    func timeSignature(_ t: TimeSignature, x: Double) -> [LayoutItem] {
        switch t.symbol {
        case .common: return [.glyph(codepoint: Glyph.timeSigCommon.codepoint, position: CGPoint(x: x, y: 2))]
        case .cut: return [.glyph(codepoint: Glyph.timeSigCutCommon.codepoint, position: CGPoint(x: x, y: 2))]
        case nil:
            let w = timeSignatureWidth(t)
            var items: [LayoutItem] = []
            for (n, y) in [(t.beats, 1.0), (t.beatType, 3.0)] {
                var cx = x + (w - digitsWidth(n)) / 2
                for d in String(n).compactMap({ $0.wholeNumberValue }) {
                    items.append(.glyph(codepoint: Glyph.timeDigit(d).codepoint, position: CGPoint(x: cx, y: y)))
                    cx += Glyph.timeDigit(d).metrics.advance
                }
            }
            return items
        }
    }

    func clefItem(_ clef: Clef, x: Double, scale: Double = 1) -> LayoutItem {
        let s = ClefShape(clef)
        // Scaling about the origin keeps the clef on its line.
        return .glyph(codepoint: s.glyph.codepoint, position: CGPoint(x: x, y: s.originY),
                      size: scale == 1 ? nil : Glyph.standardSize * scale)
    }
}
