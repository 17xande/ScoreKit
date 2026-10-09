import Foundation

// Per staff and measure: voices, stem directions, beam groups, head offsets between voices,
// accidental columns, rest offsets and tuplets. Pure analysis, no coordinates.

func beamLevel(_ v: NoteValue) -> Int {
    switch v {
    case .eighth: 1
    case .sixteenth: 2
    case .thirtySecond: 3
    case .sixtyFourth: 4
    case .oneTwentyEighth: 5
    default: 0
    }
}

extension Engraving {
    /// `pickupOffset` is how much shorter than the bar the measure is when it is a pickup
    /// (beat positions count back from the barline), else zero.
    func engraveVoices(_ sm: inout SlotMeasure, pickupOffset: Rational) {
        var gs = sm.groups
        guard !gs.isEmpty else { return }

        // Voices in this staff: numeric order when they are numbers, else first appearance.
        var order: [String] = []
        for g in gs where !g.grace && !order.contains(g.voice) { order.append(g.voice) }
        if order.allSatisfy({ Int($0) != nil }) { order.sort { Int($0)! < Int($1)! } }
        let multi = order.count > 1
        // Default direction of each voice when the file has no <stem>. Voice numbers are
        // arbitrary (1 and 5, 2 and 5, ...), so rank within the staff decides: with two voices the
        // upper-sounding one is up (equal means: the first in order). With three or more (Gould): the voice lying highest is
        // up, the lowest down, and a middle voice takes the direction of the outer voice its mean
        // pitch is nearer to (a tie: by rank).
        var meanPitch: [String: Double] = [:]
        for v in order {
            let ps = gs.filter { !$0.isRest && !$0.grace && $0.voice == v }.flatMap { $0.notes.map(\.p) }
            if !ps.isEmpty { meanPitch[v] = Double(ps.reduce(0, +)) / Double(ps.count) }
        }
        var defaultUp: [String: Bool] = [:]
        for (r, v) in order.enumerated() { defaultUp[v] = r % 2 == 0 }
        if order.count == 2, let a = meanPitch[order[0]], let b = meanPitch[order[1]], abs(a - b) > 0.5 {
            // Two voices: the upper-sounding one is up, whatever its number or order (crossing
            // voices, means within half a staff step, keep the order rule).
            defaultUp[order[0]] = a > b; defaultUp[order[1]] = b > a
        }
        if order.count >= 3 {
            let noted = order.filter { meanPitch[$0] != nil }.sorted { meanPitch[$0]! > meanPitch[$1]! }
            if noted.count >= 3, let hi = noted.first, let lo = noted.last {
                defaultUp[hi] = true; defaultUp[lo] = false
                for v in noted.dropFirst().dropLast() {
                    let dh = meanPitch[hi]! - meanPitch[v]!, dl = meanPitch[v]! - meanPitch[lo]!
                    if dh != dl { defaultUp[v] = dh < dl }
                }
            }
        }
        for i in gs.indices {
            gs[i].multiVoice = multi && !gs[i].grace
            gs[i].voiceRank = order.firstIndex(of: gs[i].voice) ?? 0
            gs[i].voiceDefaultUp = defaultUp[gs[i].voice] ?? (gs[i].voiceRank % 2 == 0)
        }

        // Provisional stem directions (in multi-voice staves: the file's <stem>, else the voice's default).
        for i in gs.indices where !gs[i].isRest {
            gs[i].stemUp = Self.naturalStemUp(gs[i])
        }

        // Beams.
        let voiceIdx = Dictionary(grouping: gs.indices.filter { !gs[$0].grace }, by: { gs[$0].voice })
        var beams: [BeamGroup] = []
        for v in order {
            let idxs = voiceIdx[v] ?? []
            let fileBeamed = idxs.contains { i in gs[i].notes.contains { !$0.note.beams.isEmpty } }
            var found: [(members: [Int], roles: [[Int: BeamValue]])] = fileBeamed
                ? Self.fileBeams(idxs, gs)
                : Self.computedBeams(idxs, gs, time: sm.time ?? TimeSignature(beats: 4, beatType: 4, symbol: nil), offset: pickupOffset)
            found.removeAll { $0.members.count < 2 }
            for f in found {
                let up = Self.beamStemUp(f.members.map { gs[$0] })
                let maxLevel = f.members.map { max(1, beamLevel(gs[$0].value)) }.max() ?? 1
                let bi = beams.count
                for m in f.members { gs[m].stemUp = up; gs[m].beamIndex = bi }
                beams.append(BeamGroup(members: f.members, segments: Self.segments(f.roles), stemUp: up, maxLevel: maxLevel))
            }
        }

        // Consecutive grace notes of eighth value or shorter beam together (stems always up).
        var gi = 0
        while gi < gs.count {
            guard gs[gi].grace, !gs[gi].isRest, beamLevel(gs[gi].value) > 0 else { gi += 1; continue }
            var run = [gi]
            var j = gi + 1
            while j < gs.count, gs[j].grace, !gs[j].isRest, beamLevel(gs[j].value) > 0, gs[j].onset == gs[gi].onset { run.append(j); j += 1 }
            if run.count >= 2 {
                let bi = beams.count
                for m in run { gs[m].stemUp = true; gs[m].beamIndex = bi }
                beams.append(BeamGroup(members: run, segments: Self.segments(Self.computedRoles(run.map { gs[$0] })),
                                       stemUp: true, maxLevel: run.map { beamLevel(gs[$0].value) }.max() ?? 1))
            }
            gi = j
        }

        // Flipped seconds within chords.
        for i in gs.indices where !gs[i].isRest { Self.flipSeconds(&gs[i]) }

        // Per onset: heads of different voices, accidentals, dots.
        var byOnset: [Rational: [Int]] = [:]
        for i in gs.indices where !gs[i].grace && !gs[i].isRest { byOnset[gs[i].onset, default: []].append(i) }
        for (_, idxs) in byOnset {
            let ordered = idxs.sorted { (gs[$0].voiceRank, $0) < (gs[$1].voiceRank, $1) }
            Self.separateVoices(ordered, &gs)
            Self.assignAccidentals(ordered, &gs)
            let right = { (g: Group) in g.baseDX + (g.notes.map(\.dx).max() ?? 0) + g.headWidth }
            let maxRight = ordered.map { right(gs[$0]) }.max() ?? 0
            for i in ordered where gs[i].dots > 0 { gs[i].dotExtra = max(0, maxRight - right(gs[i])) }
        }
        for i in gs.indices where gs[i].grace && !gs[i].isRest { Self.assignAccidentals([i], &gs) }

        // Rests: a voice whose notes all go one way (explicit <stem>, or the voice's default
        // direction) keeps that way for its rests too.
        var voiceUp: [String: Bool] = [:]
        for v in order {
            let ups = gs.indices.filter { !gs[$0].isRest && !gs[$0].grace && !gs[$0].stemNone && gs[$0].voice == v }.map { gs[$0].stemUp }
            if !ups.isEmpty, ups.allSatisfy({ $0 == ups[0] }) { voiceUp[v] = ups[0] }
        }
        // ...except the voice lying above (below) all the others, whose rests go up (down).
        let mean = meanPitch
        for i in gs.indices where gs[i].isRest {
            let v = gs[i].voice
            var up = voiceUp[v] ?? gs[i].voiceDefaultUp
            let opposed = voiceUp[v].map { d in voiceUp.contains { $0.key != v && $0.value != d } } ?? false
            if let m = mean[v], mean.count > 1, !opposed {
                let others = mean.filter { $0.key != v }.map(\.value)
                if m > others.max()! { up = true } else if m < others.min()! { up = false }
            }
            if mean[v] == nil, let at = order.firstIndex(of: v) {
                // A voice with no notes on this staff (its notes are on the other one): above the
                // staff's voices when it comes first, below them when it comes last.
                let noted = order.indices.filter { mean[order[$0]] != nil }
                if let lo = noted.first, let hi = noted.last {
                    if at < lo { up = true } else if at > hi { up = false }
                }
            }
            gs[i].restUp = up
        }

        // Rests move out of the way of the other voices (the one nearest the staff first).
        let restOrder = gs.indices.filter { gs[$0].isRest && gs[$0].multiVoice }
            .sorted { (gs[$0].voiceRank, $0) < (gs[$1].voiceRank, $1) }
        for i in restOrder { gs[i].restDY = Self.restOffset(i, gs); gs[i].restPlaced = true }

        sm.groups = gs
        sm.beams = beams
        sm.tuplets = Self.tuplets(order: order, voiceIdx: voiceIdx, gs)
    }

    /// Vertical shift of a rest in a multi-voice staff: the upper voice's up, the lower voice's
    /// down, drifting toward its own neighbouring note, and beyond the extreme head of any other
    /// voice sounding at the same time. The result puts the glyph on whole staff spaces.
    static func restOffset(_ i: Int, _ gs: [Group]) -> Double {
        let g = gs[i]
        let up = g.restUp
        let long = g.value == .whole || g.value == .breve
        let m = Glyph.rest(g.value).metrics
        let base = long ? 1.0 : 2.0
        // Box extents relative to the origin (y down): top = -maxY, bottom = -minY.
        let top = -m.maxY, bottom = -m.minY
        let half = (bottom - top) / 2, mid = (top + bottom) / 2
        var centre: Double   // target centre of the glyph, staff-local y
        if long {
            centre = up ? 0.5 : 3.5
        } else {
            let same = gs.indices.filter { !gs[$0].isRest && !gs[$0].grace && gs[$0].voice == g.voice }
            let near = same.first { $0 > i } ?? same.last { $0 < i }
            let ny = near.map { StaffGeometry.y(gs[$0].notes[gs[$0].notes.count / 2].p) } ?? (up ? 0 : 4)
            if up { centre = max(-1 + half, min(1, ny)) } else { centre = min(5 - half, max(3, ny)) }
        }
        // Keep clear of the other voices' heads sounding during the rest.
        let start = g.onset, end = g.onset + max(g.notes[0].note.duration, Rational(1, 64))
        var topY = Double.infinity, bottomY = -Double.infinity
        for o in gs where !o.isRest && !o.grace && o.voice != g.voice {
            let oEnd = o.onset + max(o.notes[0].note.duration, Rational(1, 64))
            guard o.onset < end, oEnd > start else { continue }
            topY = min(topY, StaffGeometry.y(o.notes.last!.p) - 0.5)
            bottomY = max(bottomY, StaffGeometry.y(o.notes.first!.p) + 0.5)
        }
        func clearOfHeads(_ c: Double) -> Bool {
            up ? !topY.isFinite || c + half <= topY - 0.25 + 1e-9 : !bottomY.isFinite || c - half >= bottomY + 0.25 - 1e-9
        }
        // Then clear of what stands in the rest's own column: heads, stems and other voices'
        // rests of the same onset (a stem is as much in the way as a head).
        let w = Glyph.rest(g.value).metrics.advance
        var boxes: [CGRect] = []
        for (j, o) in gs.enumerated() where j != i && !o.grace && o.onset == g.onset && o.voice != g.voice {
            if o.isRest {
                guard o.restPlaced else { continue }
                let om = Glyph.rest(o.value).metrics
                let oy = ((o.value == .whole || o.value == .breve) ? 1.0 : 2.0) + o.restDY
                boxes.append(CGRect(x: 0, y: oy - om.maxY, width: om.advance, height: om.maxY - om.minY))
                continue
            }
            let hw = o.headWidth
            let lo = StaffGeometry.y(o.notes.last!.p), hi = StaffGeometry.y(o.notes.first!.p)
            boxes.append(CGRect(x: o.baseDX + (o.notes.map(\.dx).min() ?? 0), y: lo - 0.5,
                                width: (o.notes.map(\.dx).max() ?? 0) - (o.notes.map(\.dx).min() ?? 0) + hw, height: hi - lo + 1))
            if !o.stemNone, o.value != .whole, o.value != .breve {
                let len = stemLength * o.scale
                if o.stemUp { boxes.append(CGRect(x: o.baseDX + hw - 0.1, y: min(lo - len, 2), width: 0.2, height: max(0, lo - min(lo - len, 2)))) }
                else { boxes.append(CGRect(x: o.baseDX - 0.1, y: hi, width: 0.2, height: max(2, hi + len) - hi)) }
            }
            if o.dots > 0 { boxes.append(CGRect(x: o.baseDX + hw + 0.3, y: lo - 0.5, width: 0.4 + 0.55 * Double(o.dots), height: hi - lo + 1)) }
        }
        // Nearest whole staff space, then away from the other voices until nothing is in the way.
        let startOff = (centre - mid).rounded()
        var off = startOff
        var cleared = false
        for _ in 0..<20 {
            let c = off + mid
            let r = CGRect(x: 0, y: c - half, width: w, height: 2 * half).insetBy(dx: 0, dy: -0.15)
            if clearOfHeads(c), !boxes.contains(where: { $0.intersects(r) }) { cleared = true; break }
            off += up ? -1 : 1
        }
        return (cleared ? off : startOff) - base
    }

    // MARK: Stems

    static func explicitStem(_ g: Group) -> Bool? {
        g.notes.compactMap(\.note.stem).first { $0 == .up || $0 == .down }.map { $0 == .up }
    }

    /// The file's `<stem>`, else the voice's direction in multi-voice measures, else the head
    /// farthest from the middle line (the middle line itself takes a down stem).
    static func naturalStemUp(_ g: Group) -> Bool {
        if g.grace { return true }
        if let e = explicitStem(g) { return e }
        // A stemless chord has no stem to place; it keeps the order rule so heads are offset as ever.
        if g.multiVoice { return g.stemNone ? g.voiceRank % 2 == 0 : g.voiceDefaultUp }
        return farthestUp(g.notes.map(\.p))
    }

    static func farthestUp(_ ps: [Int]) -> Bool {
        guard let far = ps.map({ abs($0 - 4) }).max() else { return false }
        let above = ps.contains { $0 - 4 == far }, below = ps.contains { 4 - $0 == far }
        if above && below {
            return ps.filter { $0 < 4 }.count > ps.filter { $0 > 4 }.count
        }
        return below
    }

    static func beamStemUp(_ members: [Group]) -> Bool {
        if members[0].grace { return true }
        let explicit = members.compactMap(explicitStem)
        if !explicit.isEmpty { return explicit.filter { $0 }.count > explicit.count - explicit.filter { $0 }.count }
        if members[0].multiVoice { return members[0].voiceDefaultUp }
        return farthestUp(members.flatMap { $0.notes.map(\.p) })
    }

    // MARK: Beam groups

    static func fileBeams(_ idxs: [Int], _ gs: [Group]) -> [(members: [Int], roles: [[Int: BeamValue]])] {
        var out: [(members: [Int], roles: [[Int: BeamValue]])] = []
        var cur: [Int] = []
        var roles: [[Int: BeamValue]] = []
        func flush() { if !cur.isEmpty { out.append((cur, roles)) }; cur = []; roles = [] }
        for i in idxs {
            let g = gs[i]
            if g.isRest || g.stemNone { continue }
            let list = g.notes.first { !$0.note.beams.isEmpty }?.note.beams ?? []
            let r = Dictionary(list.map { ($0.number, $0.value) }, uniquingKeysWith: { a, _ in a })
            guard let v = r[1] else { flush(); continue }
            switch v {
            case .begin: flush(); cur = [i]; roles = [r]
            case .continue: cur.append(i); roles.append(r)
            case .end: cur.append(i); roles.append(r); flush()
            case .forwardHook, .backwardHook: flush()
            }
        }
        flush()
        return out
    }

    /// Where beam groups break inside the bar: the length of a regular cell and, for the odd
    /// meters, the explicit cut points (in quarters from the bar start).
    static func cells(_ t: TimeSignature) -> (length: Rational, cuts: [Rational]?) {
        let unit = Rational(4, t.beatType)
        switch (t.beats, t.beatType) {
        case (5, 8): return (Rational(5, 2), [Rational(3, 2)])          // 3 + 2
        case (7, 8): return (Rational(7, 2), [Rational(1), Rational(2)]) // 2 + 2 + 3
        case (2, 2): return (Rational(1), nil)                           // by quarter; 8ths merge below
        default: break
        }
        if t.beatType >= 8 {
            if t.beats % 3 == 0 && t.beats >= 3 { return (unit * Rational(3), nil) }
            return (unit * Rational(2), nil)
        }
        if t.beatType == 4 && t.beats % 3 == 0 && t.beats >= 6 { return (Rational(3), nil) }   // 6/4: dotted half
        return (unit, nil)
    }

    static func computedBeams(_ idxs: [Int], _ gs: [Group], time: TimeSignature, offset: Rational) -> [(members: [Int], roles: [[Int: BeamValue]])] {
        let (cell, cuts) = cells(time)
        func beamable(_ g: Group) -> Bool { !g.isRest && !g.stemNone && beamLevel(g.value) > 0 }
        // Beat position, counted from the bar's end in a pickup measure.
        func pos(_ g: Group) -> Double { (g.onset + offset).double }
        func isPlainEighth(_ g: Group) -> Bool {
            !g.isRest && g.value == .eighth && g.dots == 0 && g.notes.allSatisfy { $0.note.timeModification == nil }
        }
        // 4/4 and 2/2: four plain eighths in a half bar beam together.
        var merged = Set<Int>()
        if time.quarters == Rational(4) && (time.beatType == 4 || time.beatType == 2) {
            for h in 0..<2 {
                let inHalf = idxs.filter { Int(pos(gs[$0]) / 2 + 1e-9) == h }
                if !inHalf.isEmpty, inHalf.allSatisfy({ isPlainEighth(gs[$0]) }) { merged.insert(h) }
            }
        }
        func key(_ g: Group) -> Int {
            let p = pos(g)
            if merged.contains(Int(p / 2 + 1e-9)) { return 1000 + Int(p / 2 + 1e-9) }
            if let cuts { return cuts.filter { $0.double <= p + 1e-9 }.count }
            return Int(p / cell.double + 1e-9)
        }
        var out: [(members: [Int], roles: [[Int: BeamValue]])] = []
        var run: [Int] = []
        var runKey = 0
        func flush() {
            if run.count >= 2 { out.append((run, computedRoles(run.map { gs[$0] }))) }
            run = []
        }
        for i in idxs {
            let g = gs[i]
            guard beamable(g) else { flush(); continue }
            let k = key(g)
            if !run.isEmpty && k != runKey { flush() }
            run.append(i); runKey = k
        }
        flush()
        return out
    }

    static func computedRoles(_ members: [Group]) -> [[Int: BeamValue]] {
        let levels = members.map { beamLevel($0.value) }
        let n = levels.count
        var roles = [[Int: BeamValue]](repeating: [:], count: n)
        for k in 1...max(1, levels.max() ?? 1) {
            var i = 0
            while i < n {
                guard levels[i] >= k else { i += 1; continue }
                var j = i
                while j + 1 < n && levels[j + 1] >= k { j += 1 }
                if j > i {
                    for m in i...j { roles[m][k] = m == i ? .begin : (m == j ? .end : .continue) }
                } else {
                    // A lone short note: the hook points to the note it belongs with.
                    let forward: Bool
                    if i == 0 { forward = true }
                    else if i == n - 1 { forward = false }
                    else {
                        let x = members[i].onset.double / (2 * members[i].value.quarters.double)
                        forward = abs(x - x.rounded()) < 1e-6
                    }
                    roles[i][k] = forward ? .forwardHook : .backwardHook
                }
                i = j + 1
            }
        }
        return roles
    }

    static func segments(_ roles: [[Int: BeamValue]]) -> [BeamSegment] {
        var out: [BeamSegment] = []
        let levels = Set(roles.flatMap(\.keys)).sorted()
        for k in levels {
            var open: Int?
            func close(_ end: Int) {
                guard let o = open else { return }
                out.append(BeamSegment(level: k, from: o, to: end))
                open = nil
            }
            for (idx, r) in roles.enumerated() {
                switch r[k] {
                case nil: close(idx - 1)
                case .begin?: close(idx - 1); open = idx
                case .continue?: if open == nil { open = idx }
                case .end?: if open == nil { open = idx }; close(idx)
                case .forwardHook?: close(idx - 1); out.append(BeamSegment(level: k, from: idx, to: idx, forward: true))
                case .backwardHook?: close(idx - 1); out.append(BeamSegment(level: k, from: idx, to: idx, forward: false))
                }
            }
            close(roles.count - 1)
        }
        return out
    }

    // MARK: Heads

    static func flipSeconds(_ g: inout Group) {
        guard g.notes.count > 1 else { return }
        let w = g.headWidth
        var n = g.notes
        if g.stemUp || [.whole, .breve].contains(g.value) {
            var prevFlipped = false
            for i in 1..<n.count {
                if n[i].p - n[i - 1].p == 1, !prevFlipped { n[i].dx = w; prevFlipped = true } else { prevFlipped = false }
            }
        } else {
            var prevFlipped = false
            for i in stride(from: n.count - 2, through: 0, by: -1) {
                if n[i + 1].p - n[i].p == 1, !prevFlipped { n[i].dx = -w; prevFlipped = true } else { prevFlipped = false }
            }
        }
        g.notes = n
    }

    /// Moves heads of different voices apart where they would overlap. With opposite stems the
    /// stem-up voice goes to the right (also when the voices cross); with the same direction, or
    /// unisons that cannot share a head, the later voice does. Unisons of equal value and
    /// opposite stems share one head: the later note is marked `sharedWith`.
    static func separateVoices(_ ordered: [Int], _ gs: inout [Group]) {
        guard ordered.count > 1 else { return }
        for (k, i) in ordered.enumerated() where k > 0 {
            for _ in 0..<6 {
                guard let j = ordered[..<k].first(where: { clashes(gs[i], gs[$0]) || stemHits(gs[i], gs[$0]) || stemHits(gs[$0], gs[i]) }) else { break }
                let a = gs[i], b = gs[j]
                let opposite = a.stemUp != b.stemUp
                if opposite && (hasSecond(a, b) || stemHits(a, b) || stemHits(b, a)) {
                    // The stem-up group moves right.
                    if a.stemUp { gs[i].voiceDX += a.headWidth } else { gs[j].voiceDX += b.headWidth }
                } else {
                    gs[i].voiceDX += a.headWidth
                }
            }
        }
        // Shared heads, once everything has settled.
        for (k, i) in ordered.enumerated() where k > 0 {
            for j in ordered[..<k] where canShare(gs[i], gs[j]) {
                for ni in gs[i].notes.indices where gs[i].notes[ni].sharedWith == nil {
                    let x = gs[i].baseDX + gs[i].notes[ni].dx
                    if let nj = gs[j].notes.first(where: { $0.p == gs[i].notes[ni].p && abs(gs[j].baseDX + $0.dx - x) < 0.01 }) {
                        gs[i].notes[ni].sharedWith = nj.note.id
                        gs[i].notes[ni].acc = nil
                    }
                }
            }
        }
    }

    private static func canShare(_ a: Group, _ b: Group) -> Bool {
        a.value == b.value && a.dots == b.dots && a.head == b.head && a.stemUp != b.stemUp && a.scale == b.scale
    }

    private static func hasSecond(_ a: Group, _ b: Group) -> Bool {
        for x in a.notes { for y in b.notes where abs(x.p - y.p) == 1 {
            if abs((a.baseDX + x.dx) - (b.baseDX + y.dx)) < a.headWidth - 0.01 { return true }
        } }
        return false
    }

    /// Whether the stem of `a` (as it will be drawn, tip estimated) runs through a head of `b`.
    private static func stemHits(_ a: Group, _ b: Group) -> Bool {
        guard !a.stemNone, a.value != .whole, a.value != .breve, !a.notes.isEmpty, !b.notes.isEmpty else { return false }
        let hw = a.headWidth
        let top = StaffGeometry.y(a.notes.last!.p), bottom = StaffGeometry.y(a.notes.first!.p)
        let len = stemLength * a.scale
        let sx = a.baseDX + (a.stemUp ? hw : 0)
        let (y0, y1) = a.stemUp ? (min(top - len, 2), bottom) : (top, max(bottom + len, 2))
        let sharing = canShare(a, b)
        for y in b.notes where y.sharedWith == nil {
            if sharing, a.notes.contains(where: { $0.p == y.p }) { continue }   // one shared head
            let x0 = b.baseDX + y.dx, x1 = x0 + b.headWidth
            let hy = StaffGeometry.y(y.p)
            // A stem on the edge of the head it runs past counts too: that is where an up stem
            // (right edge) or a down stem (left edge) of a crossing voice lies.
            let lo = x0 + (a.stemUp ? 0.1 : -0.2), hi = x1 - (a.stemUp ? -0.2 : 0.1)
            if sx > lo, sx < hi, hy + 0.4 > y0, hy - 0.4 < y1 - 0.2 { return true }
        }
        return false
    }

    private static func clashes(_ a: Group, _ b: Group) -> Bool {
        let share = canShare(a, b)
        for x in a.notes {
            for y in b.notes where abs(x.p - y.p) <= 1 {
                let dx = abs((a.baseDX + x.dx) - (b.baseDX + y.dx))
                if dx >= a.headWidth - 0.01 { continue }
                if share && x.p == y.p && dx < 0.01 { continue }
                return true
            }
        }
        return false
    }

    /// Accidental columns over all the groups at one onset, so voices do not stack them.
    static func assignAccidentals(_ idxs: [Int], _ gs: inout [Group]) {
        var entries: [(g: Int, n: Int)] = []
        for i in idxs { for n in gs[i].notes.indices where gs[i].notes[n].acc != nil { entries.append((i, n)) } }
        entries.sort { (gs[$0.g].notes[$0.n].p, $1.g) > (gs[$1.g].notes[$1.n].p, $0.g) }
        // Gould's order: the highest first, then the lowest, the second highest, the second lowest,
        // and so on, each into the first column it fits (a seventh or more from what is already
        // there). That zig-zag keeps a cluster's accidentals compact instead of a long staircase.
        if entries.count > 2 {
            var zig: [(g: Int, n: Int)] = []
            var lo = 0, hi = entries.count - 1
            var top = true
            while lo <= hi {
                if top { zig.append(entries[lo]); lo += 1 } else { zig.append(entries[hi]); hi -= 1 }
                top.toggle()
            }
            entries = zig
        }
        var cols: [[Int]] = []
        var widths: [Double] = []
        for e in entries {
            let g = gs[e.g]
            let n = g.notes[e.n]
            var bw = n.acc!.metrics.advance
            if n.parens { bw += Glyph.accidentalParensLeft.metrics.advance + Glyph.accidentalParensRight.metrics.advance }
            bw *= g.scale
            var k = 0
            while k < cols.count, cols[k].contains(where: { abs($0 - n.p) < 6 }) { k += 1 }
            if k == cols.count { cols.append([]); widths.append(0) }
            cols[k].append(n.p)
            widths[k] = max(widths[k], bw + 0.12 * g.scale)
            gs[e.g].notes[e.n].accCol = k
        }
        let left = idxs.map { gs[$0].baseDX + (gs[$0].notes.map(\.dx).min() ?? 0) }.min()
        for i in idxs { gs[i].accColW = widths; gs[i].leftEdge = left }
    }

    // MARK: Tuplets

    static func tuplets(order: [String], voiceIdx: [String: [Int]], _ gs: [Group]) -> [TupletSpan] {
        var out: [TupletSpan] = []
        func finish(_ members: [Int], bracket: Bool?, show: String?) {
            guard members.count >= 1 else { return }
            let tm = members.compactMap { i in gs[i].notes.compactMap(\.note.timeModification).first }.first
            let number = tm?.actual ?? members.count
            let hideNumber = show == "none"
            let fully = members.allSatisfy { !gs[$0].isRest && gs[$0].beamIndex != nil && gs[$0].beamIndex == gs[members[0]].beamIndex }
            let br = bracket ?? !fully
            guard br || !hideNumber else { return }
            let pitched = members.filter { !gs[$0].isRest }
            let up: Bool
            if pitched.isEmpty { up = gs[members[0]].voiceDefaultUp }
            else { up = pitched.filter { gs[$0].stemUp }.count * 2 >= pitched.count }
            out.append(TupletSpan(members: members, number: hideNumber ? 0 : number, bracket: br, above: up))
        }
        for v in order {
            let idxs = voiceIdx[v] ?? []
            func marks(_ i: Int) -> [TupletMark] {
                var seen = Set<String>()
                return gs[i].notes.flatMap(\.note.tuplets).filter { seen.insert("\($0.kind)\($0.number ?? 1)").inserted }
            }
            if idxs.contains(where: { !marks($0).isEmpty }) {
                var open: [Int: (members: [Int], bracket: Bool?, show: String?)] = [:]
                for i in idxs {
                    let ms = marks(i)
                    // A start without a stop ends at the first note outside the time modification.
                    if gs[i].notes.first?.note.timeModification == nil, !open.isEmpty {
                        for o in open.values { finish(o.members, bracket: o.bracket, show: o.show) }
                        open = [:]
                    }
                    for m in ms where m.kind == .start { open[m.number ?? 1] = ([], m.bracket, m.showNumber) }
                    for key in open.keys { open[key]!.members.append(i) }
                    for m in ms where m.kind == .stop {
                        if let o = open.removeValue(forKey: m.number ?? 1) { finish(o.members, bracket: o.bracket, show: o.show) }
                    }
                }
                for o in open.values { finish(o.members, bracket: o.bracket, show: o.show) }
            } else {
                // No notations: consecutive notes with the same time modification, `actual` at a time.
                var run: [Int] = []
                var cur: TimeModification?
                func flush() {
                    if let c = cur, c.actual > 0 {
                        var s = 0
                        while s + c.actual <= run.count { finish(Array(run[s..<(s + c.actual)]), bracket: nil, show: nil); s += c.actual }
                    }
                    run = []; cur = nil
                }
                for i in idxs {
                    let tm = gs[i].notes.first?.note.timeModification
                    if tm != cur { flush(); cur = tm }
                    if tm != nil { run.append(i) }
                }
                flush()
            }
        }
        return out
    }
}
