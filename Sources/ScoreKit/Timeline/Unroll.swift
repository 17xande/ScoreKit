/// One measure as played: repeats, voltas and jumps unrolled.
public struct PlayedMeasure: Sendable, Hashable {
    /// 0-based measure index in the score.
    public var index: Int
    /// Where this playing starts, in quarters since the start of playback; it is the time of
    /// position `from` (a measure entered at a mid-bar segno starts there).
    public var start: Rational
    /// The repeat pass (1-based) this measure was played in; 1 outside repeats.
    public var pass: Int
    /// The part of the measure played, in quarters into the measure: positions in
    /// `from ..< to`. Whole measures play `0 ..< length`; a segno or coda entered mid-bar
    /// raises `from`, a Fine or To Coda mid-bar lowers `to`.
    public var from: Rational
    public var to: Rational
    /// Quarters played.
    public var length: Rational { to - from }
    /// Whether a position within the measure is played.
    public func plays(_ position: Rational) -> Bool { position >= from && position < to }
}

/// The playback order of a score's measures.
///
/// - A forward repeat starts a section (the piece start when there is none, or the
///   measure after the previous finished section); a backward repeat plays it
///   `times` times (default 2; at least as many as the highest ending number of
///   its volta group).
/// - Endings (voltas) play only on the passes they list, by the `number`
///   attribute; the text and `print-object` are presentation.
/// - `dacapo`, `dalsegno` and `tocoda` act at the end of the measure that holds them.
///   A jump is taken once; after it repeats are not retaken, voltas play their last
///   ending, `tocoda` jumps to the first coda after it and `fine` stops. A `fine` or
///   `tocoda` with a mid-bar position ends the measure after the notes that start there
///   (the mark sits over the final note or chord; with no note there, at the mark itself);
///   a mark at the measure's start or end (the usual place for a label) leaves it whole. A segno or
///   coda mid-bar is entered there; one at the bar's end starts the next measure.
/// - An ending whose bracket stops before the backward repeat that closes it, with the next
///   ending right after that repeat, extends to the repeat (as OSMD does). An open last ending
///   on a single bar extends to a Fine before the next ending (a heuristic for under-encoded files).
/// - A backward repeat plays as many passes as the highest ending number of any volta group
///   inside its section.
/// - `times` is capped at 16 and the total at 64 measures per score measure, so
///   a malformed score cannot play for ever.
/// - A measure's length is the longest of any part's measure with that index.
public struct Unroll: Sendable {
    /// Length in quarters of each measure index.
    public let measureLengths: [Rational]
    /// The measures in playing order.
    public let measures: [PlayedMeasure]
    /// Total length in quarters.
    public let length: Rational

    private struct Region {
        var start: Int
        var end: Int
        var numbers: [Int]
        var group: Int
    }

    static let maxTimes = 16
    static let maxPassesOfScore = 64

    public init(score: Score) {
        let n = score.parts.map(\.measures.count).max() ?? 0
        var lengths = [Rational](repeating: .zero, count: n)
        var forward = Set<Int>()
        var backward: [Int: Int?] = [:]
        var marks = [[JumpMark]](repeating: [], count: n)
        struct RawStart { var index: Int; var numbers: [Int]; var text: String }
        var noteEnds = [[Rational: Rational]](repeating: [:], count: n)   // by measure: onset -> latest end
        var starts: [Int: RawStart] = [:]
        var stops: [Int] = []
        var openStops = Set<Int>()   // stops written as `discontinue` (no closing hook)

        for part in score.parts {
            for m in part.measures {
                let i = m.index
                guard i < n else { continue }
                lengths[i] = max(lengths[i], m.duration)
                for note in m.notes where !note.isGrace && note.duration > .zero {
                    noteEnds[i][note.onset] = max(noteEnds[i][note.onset] ?? .zero, note.onset + note.duration)
                }
                for mark in m.jumpMarks where !marks[i].contains(mark) { marks[i].append(mark) }
                for b in m.barlines {
                    if let r = b.repeatMark {
                        switch r.direction {
                        case .forward:
                            let at = b.location == .right ? i + 1 : i
                            if at < n { forward.insert(at) }
                        case .backward:
                            let at = b.location == .left ? i - 1 : i
                            if at >= 0 {
                                let old = backward[at] ?? nil
                                backward[at] = [old, r.times.map { min(max($0, 1), Self.maxTimes) }].compactMap { $0 }.max()
                            }
                        }
                    }
                    if let e = b.ending {
                        switch e.kind {
                        case .start:
                            if starts[i] == nil {
                                starts[i] = RawStart(index: i, numbers: e.numbers, text: e.text)
                            }
                        case .stop, .discontinue:
                            let at = b.location == .left ? max(0, i - 1) : i
                            stops.append(at)
                            if e.kind == .discontinue { openStops.insert(at) }
                        }
                    }
                }
            }
        }
        measureLengths = lengths

        // Endings: each from its start to the first stop at or after it, but not past
        // the next start. Regions that touch form a group (one volta bracket set).
        var regions: [Region] = []
        let sortedStarts = starts.values.sorted { $0.index < $1.index }
        var group = 0
        var ordinal = 0
        for (k, s) in sortedStarts.enumerated() {
            let nextStart = k + 1 < sortedStarts.count ? sortedStarts[k + 1].index : n
            var end = min(stops.filter { $0 >= s.index }.min() ?? n - 1, nextStart - 1)
            let nextNumbers = k + 1 < sortedStarts.count ? sortedStarts[k + 1].numbers : []
            // A non-last ending whose bracket stops early but whose backward repeat comes later,
            // right before the next ending, covers everything up to that repeat (OpenScore and
            // MuseScore export a long volta 1 as start and discontinue on its first measure).
            // Read strictly, the repeat would jump back to the measure after the bracket.
            if k + 1 < sortedStarts.count, (nextNumbers.min() ?? 0) > (s.numbers.max() ?? 0),
               let b = backward.keys.filter({ $0 >= end }).min(), b > end, b + 1 == nextStart,
               !forward.contains(where: { $0 > end && $0 <= b }) {
                end = b
            }
            // Heuristic for an under-encoded last ending: an open ending written on a single bar,
            // not touching the next ending, with a Fine before that next ending, runs to the Fine
            // (the closing "Pour finir" section of a rondo-like song).
            if end == s.index, openStops.contains(end), end + 1 < nextStart,
               let f = (end + 1..<nextStart).first(where: { marks[$0].contains { $0.kind == .fine } }) {
                end = f
            }
            if let last = regions.last, last.end + 1 != s.index { group += 1; ordinal = 0 }
            ordinal += 1
            var numbers = s.numbers
            if numbers.isEmpty {
                // No usable number attribute: digits of the label, else the ordinal in the group.
                numbers = s.text.split { !$0.isNumber }.compactMap { Int($0) }
                if numbers.isEmpty { numbers = [ordinal] }
            }
            regions.append(Region(start: s.index, end: end, numbers: numbers, group: group))
        }
        var groupMax: [Int: Int] = [:]
        for r in regions { groupMax[r.group] = max(groupMax[r.group] ?? 0, r.numbers.max() ?? 1) }
        var regionStarting: [Int: Region] = [:]
        var regionHolding = [Region?](repeating: nil, count: n)
        for r in regions {
            regionStarting[r.start] = r
            for i in r.start...max(r.start, r.end) where i < n { regionHolding[i] = r }
        }

        /// Where a jump lands: a measure and a position in it.
        func landing(_ mark: (measure: Int, onset: Rational)) -> (index: Int, from: Rational) {
            if mark.onset <= .zero { return (mark.measure, .zero) }
            if mark.onset >= lengths[mark.measure] { return (mark.measure + 1, .zero) }
            return (mark.measure, mark.onset)
        }
        /// The segno a D.S. in measure `i` returns to: the one it names, else the nearest before it.
        func segno(named id: String?, from i: Int) -> (measure: Int, onset: Rational)? {
            let all = marks.enumerated().flatMap { m, ms in ms.filter { $0.kind == .segno }.map { (measure: m, onset: $0.onset, id: $0.id) } }
            let before = all.filter { $0.measure <= i }
            let pool = before.isEmpty ? all : before
            let hit = id.flatMap { id in pool.last { $0.id == id } } ?? pool.last
            return hit.map { ($0.measure, $0.onset) }
        }
        /// The coda a To Coda in measure `i` jumps to: the first one after that measure, the one
        /// it names if several.
        func coda(named id: String?, after i: Int) -> (measure: Int, onset: Rational)? {
            let later = marks.enumerated().filter { $0.offset > i }
                .flatMap { m, ms in ms.filter { $0.kind == .coda }.map { (measure: m, onset: $0.onset, id: $0.id) } }
            let hit = id.flatMap { id in later.first { $0.id == id } } ?? later.first
            return hit.map { ($0.measure, $0.onset) }
        }
        /// Where a Fine or To Coda in measure `i` ends the measure: after the notes that start at
        /// its position (the latest end over all parts and voices), else at the position itself.
        func cutoff(_ onset: Rational, _ i: Int) -> Rational {
            if onset <= .zero || onset >= lengths[i] { return lengths[i] }
            return min(noteEnds[i][onset] ?? onset, lengths[i])
        }

        let maxPlayed = Self.maxPassesOfScore * max(n, 1)
        var played: [PlayedMeasure] = []
        var start = Rational.zero
        var i = 0
        var pass = 1
        var repeatStart = 0
        var jumped = false
        var viaRepeat = false
        var from = Rational.zero
        while i < n, played.count < maxPlayed {
            if let r = regionStarting[i] {
                let plays = jumped ? r.numbers.contains(groupMax[r.group] ?? 1) : r.numbers.contains(pass)
                if !plays { i = r.end + 1; from = .zero; continue }
            }
            if !jumped, !viaRepeat, forward.contains(i) { repeatStart = i; pass = 1 }
            viaRepeat = false
            let here = marks[i]
            // After a jump, a Fine ends playback and a To Coda leaves for the coda.
            let fine = jumped ? here.first { $0.kind == .fine } : nil
            let toCoda = jumped ? here.first { $0.kind == .toCoda }.flatMap { m in coda(named: m.id, after: i).map { (m, $0) } } : nil
            var to = lengths[i]
            if let fine { to = cutoff(fine.onset, i) } else if let toCoda { to = cutoff(toCoda.0.onset, i) }
            if from < to {
                played.append(PlayedMeasure(index: i, start: start, pass: jumped ? 1 : pass, from: from, to: to))
                start += to - from
            }
            from = .zero

            var tookRepeat = false
            if !jumped, let entry = backward[i] {
                // As many passes as the highest ending number of any volta group in the section.
                let endings = regions.filter { $0.start >= repeatStart && $0.start <= i }
                    .map { groupMax[$0.group] ?? 1 }.max() ?? 0
                let total = max(entry ?? 2, endings)
                if pass < total {
                    pass += 1
                    i = repeatStart
                    viaRepeat = true
                    tookRepeat = true
                } else {
                    pass = 1
                    repeatStart = i + 1
                }
            }
            if tookRepeat { continue }
            // The last ending of a group closes the section.
            if !jumped, let r = regionHolding[i], r.end == i, regionStarting[i + 1] == nil, backward[i] == nil {
                pass = 1
                repeatStart = i + 1
            }

            if fine != nil { break }
            if let (_, target) = toCoda {
                (i, from) = landing(target)
                continue
            }
            if !jumped {
                if here.contains(where: { $0.kind == .dacapo }) {
                    jumped = true
                    i = 0
                    continue
                }
                if let d = here.first(where: { $0.kind == .dalsegno }), let t = segno(named: d.id, from: i) {
                    jumped = true
                    (i, from) = landing(t)
                    continue
                }
            }
            i += 1
        }
        measures = played
        length = start
    }
}
