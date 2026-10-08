import Foundation

extension Engraving {
    func analyze() -> [MeasureData] {
        let defaultClef = Clef(sign: "G", line: 2, octaveChange: 0)
        var clefs = [Clef](repeating: defaultClef, count: slots.count)
        var keys = [Key](repeating: Key(fifths: 0), count: slots.count)
        var times = [TimeSignature?](repeating: nil, count: slots.count)
        var pendingKey = [Key?](repeating: nil, count: slots.count)
        var pendingTime = [TimeSignature?](repeating: nil, count: slots.count)
        let partsUsed = Array(Set(slots.map(\.part))).sorted()
        var out: [MeasureData] = []

        for m in 0..<measureCount {
            let present = partsUsed.compactMap { p in m < score.parts[p].measures.count ? (p, score.parts[p].measures[m]) : nil }
            var md = MeasureData(index: m, number: present.first?.1.number ?? "\(m + 1)",
                                 duration: present.map(\.1.duration).max() ?? Rational(4), slots: [])
            for (si, slot) in slots.enumerated() {
                var sm = SlotMeasure()
                guard m < score.parts[slot.part].measures.count else {
                    sm.clef = clefs[si]; sm.key = keys[si]; sm.keyBefore = keys[si]; sm.time = times[si]
                    md.slots.append(sm)
                    continue
                }
                let meas = score.parts[slot.part].measures[m]
                // Clefs.
                var cur = clefs[si]
                let changes = meas.clefChanges.filter { $0.staff == slot.staff }.sorted { $0.onset < $1.onset }
                for c in changes where c.onset == .zero {
                    cur = c.clef
                    sm.startClefChange = c.clef
                }
                sm.clef = cur
                for c in changes where c.onset > .zero {
                    if c.onset < md.duration {
                        sm.midClefs.append((c.onset, c.clef))
                    } else {
                        sm.endClef = c.clef
                    }
                    cur = c.clef
                }
                clefs[si] = cur
                // Key and time: changes at the start (or carried over from the end of the previous
                // measure) apply at the measure start, later ones from their onset.
                sm.keyBefore = keys[si]
                if let k = pendingKey[si] { keys[si] = k; pendingKey[si] = nil }
                if let t = pendingTime[si] {
                    if times[si] != t { sm.timeChanged = true }
                    times[si] = t; pendingTime[si] = nil
                }
                let atEnd = md.duration > .zero
                for k in meas.keyChanges.sorted(by: { $0.onset < $1.onset }) where k.staff == nil || k.staff == slot.staff {
                    if k.onset <= .zero { keys[si] = k.key }
                    else if atEnd && k.onset >= md.duration { pendingKey[si] = k.key }
                    else {
                        if k.key != keys[si] { sm.midKeys.append((k.onset, k.key, keys[si])) }
                        keys[si] = k.key
                    }
                }
                let startKey = sm.midKeys.isEmpty ? keys[si] : sm.midKeys[0].before
                sm.key = startKey
                sm.keyChanged = startKey != sm.keyBefore
                for t in meas.timeChanges where t.staff == nil || t.staff == slot.staff {
                    if atEnd && t.onset >= md.duration { pendingTime[si] = t.time; continue }
                    if times[si] != t.time { sm.timeChanged = true }
                    times[si] = t.time
                }
                sm.time = times[si]
                sm.groups = groups(for: slot, in: meas, sm: sm, measureDuration: md.duration)
                var pickup = Rational.zero
                if m == 0, let ts = sm.time, md.duration < ts.quarters { pickup = ts.quarters - md.duration }
                engraveVoices(&sm, pickupOffset: pickup)
                md.slots.append(sm)
            }
            finishColumns(&md)
            // Barlines.
            func styleKind(_ style: String?) -> BarKind? {
                switch style {
                case "regular": .regular
                case "light-heavy": .final
                case "light-light": .double
                case "none": BarKind.none
                case "heavy": .heavy
                case "heavy-light": .heavyLight
                case "heavy-heavy": .heavyHeavy
                case "dashed": .dashed
                case "dotted": .dotted
                case "tick": .tick
                case "short": .short
                default: nil
                }
            }
            for (p, meas) in present {
                var kind: BarKind = m == measureCount - 1 ? .final : .regular
                for b in meas.barlines {
                    if b.location == .left, b.repeatMark?.direction == .forward { md.leftRepeat = true }
                    // A styled left barline (no repeat) is the previous measure's closing line,
                    // unless that one says otherwise.
                    if b.location == .left, b.repeatMark == nil, m > 0, let k = styleKind(b.style),
                       out[m - 1].bars[p] == .regular {
                        out[m - 1].bars[p] = k
                        out[m - 1].endFixed = out[m - 1].endClefW + (out[m - 1].bars.values.map(\.width).max() ?? BarKind.regular.width)
                    }
                    guard b.location == .right else { continue }
                    if b.repeatMark?.direction == .backward { kind = .repeatBackward; continue }
                    if let k = styleKind(b.style) { kind = k }
                }
                md.bars[p] = kind
            }
            md.endFixed = md.endClefW + (md.bars.values.map(\.width).max() ?? BarKind.regular.width)
            out.append(md)
        }
        return out
    }

    // MARK: Groups

    private func clef(at onset: Rational, _ sm: SlotMeasure) -> Clef {
        var c = sm.clef
        for (o, k) in sm.midClefs where o <= onset { c = k }
        return c
    }

    private func keyAt(_ onset: Rational, _ sm: SlotMeasure) -> Key {
        var k = sm.key
        for m in sm.midKeys where m.onset <= onset { k = m.key }
        return k
    }

    private func groups(for slot: Slot, in meas: Measure, sm: SlotMeasure, measureDuration: Rational) -> [Group] {
        // Group by (onset, voice) rather than adjacency, so a chord whose first tone is hidden or
        // on another staff still forms one group here. Grace notes group by adjacency: a run of
        // them is a sequence, not a chord.
        struct GKey: Hashable { var onset: Rational; var voice: String; var rest: Bool }
        var raw: [(onset: Rational, grace: Bool, notes: [Note])] = []
        var index: [GKey: Int] = [:]
        for n in meas.notes where n.staff == slot.staff && n.printObject {
            if n.isGrace {
                if n.isChordTone, let last = raw.last, last.grace, last.onset == n.onset { raw[raw.count - 1].notes.append(n) }
                else { raw.append((n.onset, true, [n])) }
                continue
            }
            let k = GKey(onset: n.onset, voice: n.voice, rest: n.isRest)
            if !n.isRest, let i = index[k] { raw[i].notes.append(n) }
            else { index[k] = raw.count; raw.append((n.onset, false, [n])) }
        }
        // Accidentals follow time, not document order: sort by onset, graces before their note.
        let order = raw.indices.sorted { a, b in
            if raw[a].onset != raw[b].onset { return raw[a].onset < raw[b].onset }
            if raw[a].grace != raw[b].grace { return raw[a].grace }
            return a < b
        }
        var state: [Int: Int] = [:]   // diatonic index -> alteration in force
        var curKey = sm.key
        var out: [Group] = []
        for ri in order {
            let chord = raw[ri].notes
            let first = chord[0]
            let clef = clef(at: first.onset, sm)
            let key = keyAt(first.onset, sm)
            if key != curKey { state = [:]; curKey = key }
            var g = Group(leadID: first.id, onset: first.onset, notes: [])
            g.grace = first.isGrace
            g.voice = first.voice
            g.stemNone = first.stem.map { $0 == Stem.none } ?? false
            g.scale = first.isGrace ? 0.6 : 1
            // Written value and dots.
            if let v = first.noteValue {
                g.value = v; g.dots = first.dots
            } else if first.isRest, first.duration >= measureDuration {
                g.value = .whole
            } else {
                var q = first.duration
                if let tm = first.timeModification, tm.normal > 0 { q = q * Rational(tm.actual, tm.normal) }
                (g.value, g.dots) = noteValueAndDots(quarters: q)
            }
            if first.isRest {
                g.isRest = true
                if case .rest(let explicit, _, _) = first.kind {
                    g.measureRest = explicit || (first.onset == .zero && first.duration >= measureDuration
                                                  && (first.noteValue == nil || first.noteValue == .whole))
                }
                if g.measureRest { g.value = .whole; g.dots = 0 }
                g.notes = [HeadNote(note: first, p: 4)]
                out.append(g)
                continue
            }
            g.head = .notehead(g.value)
            for n in chord {
                var p = 4
                var hn: HeadNote
                switch n.kind {
                case .pitched(let pitch):
                    p = StaffGeometry.position(pitch.step, pitch.octave, clef: clef)
                    hn = HeadNote(note: n, p: p)
                    let idx = StaffGeometry.diatonic(pitch.step, pitch.octave)
                    let alter = pitch.semitoneAlter
                    let prev = state[idx] ?? StaffGeometry.keyAlter(fifths: key.fifths, step: pitch.step)
                    let tieStop = n.soundTieStop || n.drawnTieStop
                    if let name = n.accidental, let glyph = Glyph.accidental(named: name) {
                        hn.acc = glyph
                    } else if alter != prev, !tieStop {
                        hn.acc = .accidental(alter: alter)
                    }
                    if hn.acc != nil, !n.accidentalMarks.isDisjoint(with: [.parentheses, .cautionary]) { hn.parens = true }
                    // A tied-over note that printed nothing leaves the state alone (Gould): the
                    // next note of that pitch in the bar must show its accidental again.
                    if hn.acc != nil || !tieStop { state[idx] = alter }
                case .unpitched(let step, let octave):
                    if let step, let octave { p = StaffGeometry.position(step, octave, clef: clef) }
                    hn = HeadNote(note: n, p: p)
                case .rest:
                    continue
                }
                g.notes.append(hn)
            }
            guard !g.notes.isEmpty else { continue }
            finalize(&g)
            out.append(g)
        }
        return out
    }

    /// Sorts the heads bottom to top. Stems, flipped seconds and accidentals come later, in
    /// `engraveVoices`, once the voices are known.
    private func finalize(_ g: inout Group) {
        g.notes.sort { $0.p < $1.p }
    }

    // MARK: Columns

    private func finishColumns(_ md: inout MeasureData) {
        var onsets = Set<Rational>()
        for s in md.slots {
            for g in s.groups { onsets.insert(g.onset) }
            for (o, _) in s.midClefs { onsets.insert(o) }
            for m in s.midKeys { onsets.insert(m.onset) }
        }
        let sorted = onsets.sorted()
        var columns: [Column] = []
        for (i, o) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1] : md.duration
            var minDur: Double?
            var c = Column(onset: o, spaceDur: 1)
            for s in md.slots {
                let here = s.groups.filter { $0.onset == o }
                for g in here where !g.grace {
                    let d = g.notes[0].note.duration
                    if d > .zero { minDur = min(minDur ?? .infinity, d.double) }
                    c.accW = max(c.accW, g.leftW)
                    c.rightW = max(c.rightW, g.rightW)
                }
                c.graceW = max(c.graceW, here.filter(\.grace).reduce(0) { $0 + $1.graceWidth })
                if s.midClefs.contains(where: { $0.onset == o }) {
                    let w = s.midClefs.filter { $0.onset == o }.map { ClefShape($0.clef).glyph.metrics.advance }.max() ?? 0
                    c.clefW = max(c.clefW, w * Self.smallClef + 0.5)
                }
                for mk in s.midKeys where mk.onset == o {
                    let w = keySignature(mk.key, clef: clef(at: o, s), from: mk.before, x: 0).width
                    c.keyW = max(c.keyW, w + 0.5)
                }
            }
            let gap = (next - o).double
            c.spaceDur = max(0.01, min(minDur ?? gap, gap > 0 ? gap : (minDur ?? 1)))
            columns.append(c)
        }
        md.columns = columns
        md.hasOnlyMeasureRests = !columns.isEmpty && md.slots.allSatisfy { $0.groups.allSatisfy(\.measureRest) }
            && md.slots.contains { !$0.groups.isEmpty }
        // Gaps: `need` is what the glyphs require, the rest is rhythmic space that stretches.
        var gaps: [Double] = []
        var fixed: [Double] = []
        if columns.isEmpty {
            gaps = [8]; fixed = [0]
        } else {
            gaps.append(1.1 + columns[0].leftW); fixed.append(gaps[0])
            for i in 1..<max(1, columns.count) where columns.count > 1 {
                let prev = columns[i - 1]
                let need = prev.rightW + 0.4 + columns[i].leftW
                gaps.append(max(Spacing.space(prev.spaceDur), need)); fixed.append(need)
            }
            let last = columns[columns.count - 1]
            let need = last.rightW + 0.9
            gaps.append(max(Spacing.space(last.spaceDur) - 0.5, need)); fixed.append(need)
        }
        if md.hasOnlyMeasureRests { gaps[gaps.count - 1] += max(0, 9 - gaps.reduce(0, +)) }
        md.gaps = gaps
        md.fixedGaps = fixed
        let endW = md.slots.compactMap { $0.endClef }.filter(\.printObject)
            .map { ClefShape($0).glyph.metrics.advance * Self.smallClef + 0.5 }.max() ?? 0
        md.endClefW = endW
    }
}
