import Foundation
import Testing
@testable import ScoreKit

// Parity with the web app's OSMD walk (Fixtures/walk/*.walk.json, see its README).
// Policy: match OSMD exactly, except where OSMD is plainly wrong. Those fixtures are
// listed in `divergences` below with a reason; the parity test then asserts that
// they still differ (so the list cannot go stale), and `DivergentTimelineTests`
// asserts the musically correct result for each.

// MARK: Fixture model

struct WalkFile: Decodable {
    struct Note: Decodable {
        struct Spelled: Decodable { var letter: String; var acc: Int; var octave: Int }
        var midi: Int
        var spelled: Spelled
        var staff: Int
        var tie: String
        var quarters: Double
        var finger: String?
    }
    struct Entry: Decodable {
        var measure: Int
        var occurrence: Int
        var beat: Double
        var bpm: Double
        var notes: [Note]
    }
    struct Part: Decodable { var name: String; var staves: Int }
    struct Choice: Decodable { var part: Int; var staffOffset: Int }
    var parts: [Part]
    var chosen: [Choice]
    var entries: [Entry]
}

/// The inputs: the four starters, then the edge cases (`ode-to-joy-mxl` is the .mxl).
func walkInputPath(_ name: String) -> String {
    switch name {
    case "bach-prelude-in-c", "minuet-in-g", "ode-to-joy", "twinkle-twinkle": "\(name).musicxml"
    case "ode-to-joy-mxl": "edge/ode-to-joy.mxl"
    case _ where name.hasPrefix("openscore-"): "complex/openscore/\(name.dropFirst("openscore-".count)).mxl"
    case _ where name.hasPrefix("lilypond-"): "complex/lilypond/\(name.dropFirst("lilypond-".count)).mxl"
    default: "edge/\(name).musicxml"
    }
}

/// Scores OSMD cannot walk: their `.walk.json` holds `{source, error}` only. They get no parity
/// check; ComplexScoreTests still parses, unrolls and lays each out.
let errorOnlyWalks: Set<String> = [
    "openscore-grandval-les-clochettes",    // wavy-line trill starting and stopping on one note
    "lilypond-13a-KeySignatures",           // VexFlow "Bad key signature spec" (theoretical keys)
    "lilypond-41h-TooManyParts",            // OSMD cannot load it
]

let walkNames: [String] = {
    let dir = Bundle.module.url(forResource: "walk", withExtension: nil, subdirectory: "Fixtures")!
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return files.filter { $0.hasSuffix(".walk.json") }.map { String($0.dropLast(".walk.json".count)) }
        .filter { !errorOnlyWalks.contains($0) }.sorted()
}()

// MARK: Test-only part choice (the web's chooseParts; the app's MusicCore owns the real one)

func chooseParts(_ parts: [(name: String, staves: Int)]) -> [(part: Int, staffOffset: Int)] {
    func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    let keyboard = "piano|pno|klavier|keyboard|clavier|cembalo|harpsichord|organ"
    let hand = #"\b(right|left|r\.?\s?h\.?|l\.?\s?h\.?|rechts|links|droite|gauche)\b"#
    guard !parts.isEmpty else { return [] }
    if let g = parts.firstIndex(where: { $0.staves >= 2 && matches($0.name, keyboard) }) { return [(g, 0)] }
    let anyGrand = parts.firstIndex { $0.staves >= 2 }
    var i = 0
    while i + 1 < parts.count {
        let (a, b) = (parts[i], parts[i + 1])
        if a.staves == 1, b.staves == 1, matches(a.name, hand), matches(b.name, hand) { return [(i, 0), (i + 1, 1)] }
        i += 1
    }
    return [(anyGrand ?? 0, 0)]
}

/// What the web's `walkCursor` would record from a `Timeline`.
struct WalkNote: Equatable {
    var midi: Int, letter: String, acc: Int, octave: Int, staff: Int, tie: String, quarters: Double, finger: String?
}

func walkNotes(_ e: TimelineEntry, chosen: [(part: Int, staffOffset: Int)]) -> [WalkNote] {
    e.notes.compactMap { n in
        guard let c = chosen.first(where: { $0.part == n.partIndex }) else { return nil }
        return WalkNote(midi: n.midi, letter: n.spelled.letter.rawValue, acc: n.spelled.acc, octave: n.spelled.octave,
                        staff: c.staffOffset + n.staffInPart, tie: n.tie.rawValue, quarters: n.quarters,
                        finger: n.fingering?.isEmpty == false ? n.fingering : nil)
    }
}

func sortKey(_ n: WalkNote) -> String {
    "\(n.staff)|\(n.midi)|\(n.letter)|\(n.acc)|\(n.octave)|\(n.tie)|\(String(format: "%.9f", n.quarters))|\(n.finger ?? "")"
}
func sorted(_ ns: [WalkNote]) -> [WalkNote] { ns.sorted { sortKey($0) < sortKey($1) } }

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

func loadWalk(_ name: String) throws -> WalkFile {
    try JSONDecoder().decode(WalkFile.self, from: fixture("walk/\(name).walk.json"))
}

func loadTimeline(_ name: String) throws -> (Score, Timeline, WalkFile) {
    let score = try Score.load(data: fixture(walkInputPath(name)))
    return (score, Timeline(score: score), try loadWalk(name))
}

/// What a divergent fixture is still compared on.
enum Mask {
    /// Every field of every entry.
    case exact
    /// Everything but `bpm` (the divergence is only in the tempo).
    case ignoringBPM
    /// The repeat structure differs, so entries are compared per played measure: each of our
    /// passes over a measure against the walk's first pass over that measure (measures the walk
    /// never plays are skipped), on beat offsets within the pass and notes; not on bpm, occurrence.
    case perMeasureContent
    /// Everything except each note's `tie` and `quarters` (OSMD pairs some ties wrongly).
    case ignoringTies
    /// Only the part choice and the played measure order; beats and notes are not compared.
    case orderOnly
}

private func notesMatch(_ mine: [WalkNote], _ w: [WalkFile.Note], ignoringTies: Bool = false) -> Bool {
    let mine = sorted(mine)
    let theirs = sorted(w.map {
        WalkNote(midi: $0.midi, letter: $0.spelled.letter, acc: $0.spelled.acc, octave: $0.spelled.octave,
                 staff: $0.staff, tie: $0.tie, quarters: $0.quarters, finger: $0.finger)
    })
    return mine.count == theirs.count && zip(mine, theirs).allSatisfy { a, b in
        var x = a, y = b
        let q = ignoringTies || near(x.quarters, y.quarters)
        x.quarters = 0; y.quarters = 0
        if ignoringTies { x.tie = ""; y.tie = "" }
        return q && x == y
    }
}

/// Differences between the timeline and the web walk; empty when they agree.
func parityMismatches(_ name: String, mask: Mask = .exact) throws -> [String] {
    let (score, timeline, walk) = try loadTimeline(name)
    var out: [String] = []
    let chosen = chooseParts(score.parts.map { ($0.name, $0.staves) })
    if chosen.map(\.part) != walk.chosen.map(\.part) || chosen.map(\.staffOffset) != walk.chosen.map(\.staffOffset) {
        out.append("part choice \(chosen) != \(walk.chosen)")
    }
    if score.parts.map(\.name) != walk.parts.map(\.name) || score.parts.map(\.staves) != walk.parts.map(\.staves) {
        out.append("parts \(score.parts.map { ($0.name, $0.staves) }) != \(walk.parts.map { ($0.name, $0.staves) })")
    }
    if mask == .orderOnly {
        func order<E>(_ es: [E], _ m: (E) -> Int, _ o: (E) -> Int) -> [Int] {
            var seq: [Int] = []
            var last = -1
            for e in es where o(e) != last { seq.append(m(e)); last = o(e) }
            return seq
        }
        if order(timeline.entries, { $0.measure }, { $0.occurrence }) != order(walk.entries, { $0.measure }, { $0.occurrence }) {
            out.append("played measure order differs")
        }
        return out
    }
    if mask == .perMeasureContent {
        func groups<E>(_ es: [E], _ occ: (E) -> Int) -> [[E]] {
            var g: [[E]] = []
            var last = -1
            for e in es { if occ(e) != last { g.append([]); last = occ(e) }; g[g.count - 1].append(e) }
            return g
        }
        let theirs = groups(walk.entries) { $0.occurrence }
        var compared = 0
        for g in groups(timeline.entries, { $0.occurrence }) {
            guard let t = theirs.first(where: { $0[0].measure == g[0].measure }) else { continue }
            compared += 1
            let tag = "measure \(g[0].measure)"
            if g.count != t.count { out.append("\(tag): \(g.count) entries != \(t.count)"); continue }
            for (e, w) in zip(g, t) {
                if !near(e.beat - g[0].beat, w.beat - t[0].beat) { out.append("\(tag): beat offset \(e.beat - g[0].beat)") }
                if !notesMatch(walkNotes(e, chosen: chosen), w.notes) { out.append("\(tag) beat \(w.beat): notes differ") }
            }
        }
        if compared == 0 { out.append("no measure compared") }
        return out
    }
    if timeline.entries.count != walk.entries.count {
        out.append("entry count \(timeline.entries.count) != \(walk.entries.count)")
    }
    for (i, (e, w)) in zip(timeline.entries, walk.entries).enumerated() {
        let tag = "entry \(i) (m\(w.measure) beat \(w.beat))"
        if e.measure != w.measure { out.append("\(tag): measure \(e.measure)") }
        if e.occurrence != w.occurrence { out.append("\(tag): occurrence \(e.occurrence) != \(w.occurrence)") }
        if !near(e.beat, w.beat) { out.append("\(tag): beat \(e.beat)") }
        if mask != .ignoringBPM, !near(e.bpm, w.bpm) { out.append("\(tag): bpm \(e.bpm) != \(w.bpm)") }
        if !notesMatch(walkNotes(e, chosen: chosen), w.notes, ignoringTies: mask == .ignoringTies) { out.append("\(tag): notes differ") }
    }
    return out
}

/// Fixtures where ScoreKit deliberately differs from OSMD: why, and what they are still compared on.
let divergences: [String: (reason: String, mask: Mask)] = [
    "repeat-times-3": ("OSMD ignores repeat times (plays 2 passes); ScoreKit plays 3", .perMeasureContent),
    "ending-multi-number": ("OSMD keeps the first digit of number=\"1, 2\"; ScoreKit treats it as endings 1 and 2", .perMeasureContent),
    "ending-text-differs": ("OSMD reads the ending's text instead of its number, and drops measures when the text has no digit", .perMeasureContent),
    "ending-text-digits-swapped": ("OSMD 2.2.0 lets the text override the number and plays 1 2 1 2 3 4; the intended order is 1 2 1 3 4, which ScoreKit plays from the number attribute", .perMeasureContent),
    "ending-print-object-no": ("OSMD skips endings with print-object=\"no\" entirely; ScoreKit plays them (it only hides the bracket)", .perMeasureContent),
    "lilypond-21d-Chords-SchubertStabatMater": ("OSMD turns the tempo word \"Largo\" into 52 bpm (its table of tempo words); ScoreKit treats words as display only and plays the default 100", .ignoringBPM),
    "lilypond-45a-SimpleRepeat": ("OSMD ignores repeat times (plays the bar twice); the file says five", .perMeasureContent),
    "lilypond-45c-SimpleRepeat-Nested": ("OSMD ignores repeat times and then repeats the wrong bars (1-3 2-7 4-8); intended 1, 2-3 five times, 4-8", .perMeasureContent),
    "lilypond-45d-Repeats-MultipleEndings": ("OSMD keeps only the first digit of \"3, 5, 7\" and lets the text of ending 4, 6 override its number, so most endings are lost (1-2 1-2 1-2 1 11-12); intended eight passes", .perMeasureContent),
    "openscore-satie-je-te-veux": ("OSMD plays 1-78 6-35 38-110 (endings 2 and 3 on the first pass); intended is 1-37 47-78 6-35 38-39 79-110 6-35 40-46", .perMeasureContent),
    "openscore-stanford-sou-wester": ("OSMD joins the voice 2 tie start of bar 1 to the voice 1 stop of bar 3 instead of the stop in the same bar (its tie dictionary is never cleared); ScoreKit pairs them in time order", .ignoringTies),
    "openscore-boulanger-parfois-je-suis-triste": ("OSMD adds an empty position and 0.375 quarters to the bar after a grace chord and a notehead-less 32nd (beats drift from there on), and drops the tie of two chord notes between bars 51 and 52; ScoreKit has neither", .orderOnly),
    "sound-decimal-tempo": ("OSMD turns an invalid tempo=\"fast\" into 100 (and its walk reports 0 for \"0\", which the web's score layer ignores); ScoreKit keeps the current tempo for both", .ignoringBPM),
]
// Deliberate improvement that no listed fixture shows: ties are resolved over the played order
// (a tie out of a measure joins only the measure played next), where OSMD resolves them in score order.

@Test("web parity: the timeline equals the OSMD walk", arguments: walkNames.filter { divergences[$0] == nil })
func timelineParity(name: String) throws {
    let bad = try parityMismatches(name)
    #expect(bad.isEmpty, "\(name): \(bad.prefix(5).joined(separator: "\n"))")
}

@Test("web parity: listed divergences differ from the walk only where documented", arguments: divergences.keys.sorted())
func divergencesStillDiffer(name: String) throws {
    let d = try #require(divergences[name])
    #expect(walkNames.contains(name))
    #expect(!(try parityMismatches(name)).isEmpty, "\(name) now matches OSMD; remove it from `divergences`")
    let masked = try parityMismatches(name, mask: d.mask)
    #expect(masked.isEmpty, "\(name) differs beyond its mask: \(masked.prefix(5).joined(separator: "\n"))")
}

@Test("every walk fixture is either checked for parity or a listed divergence")
func fixtureCount() {
    #expect(walkNames.count == 63)
    #expect(Set(divergences.keys).isSubset(of: Set(walkNames)))
}

// MARK: Divergent fixtures: the musically correct result

private func measures(_ name: String) throws -> [Int] {
    let (_, t, _) = try loadTimeline(name)
    var seq: [Int] = []
    var last = -1
    for e in t.entries where e.occurrence != last { seq.append(e.measure); last = e.occurrence }
    return seq
}

struct DivergentTimelineTests {
    @Test func repeatTimes3PlaysThreePasses() throws {
        #expect(try measures("repeat-times-3") == [1, 2, 3, 2, 3, 2, 3, 4])
    }
    @Test func multiNumberEndingServesBothPasses() throws {
        // Endings "1, 2" and "3": the repeat is played three times.
        #expect(try measures("ending-multi-number") == [1, 2, 1, 2, 1, 3, 4])
    }
    @Test func endingNumbersGovernNotText() throws {
        #expect(try measures("ending-text-differs") == [1, 2, 1, 3, 4])
        #expect(try measures("ending-text-digits-swapped") == [1, 2, 1, 3, 4])
    }
    @Test func hiddenEndingsStillPlay() throws {
        #expect(try measures("ending-print-object-no") == [1, 2, 1, 3, 4])
    }
    @Test func soundTempoWinsOverMetronome() throws {
        // <metronome> quarter=80 with <sound tempo="120"> in one direction: the sound tempo plays
        // (MusicXML spec, OSMD 2.2.0); ScoreKit's display value keeps the metronome mark.
        let (_, t, _) = try loadTimeline("sound-and-metronome-differ")
        #expect(t.entries.allSatisfy { near($0.bpm, 120) })
    }
    @Test func invalidTemposKeepTheCurrentTempo() throws {
        let (_, t, _) = try loadTimeline("sound-decimal-tempo")
        // 92.5 rounds to 93; "fast" is ignored (OSMD: 100); 92.4 rounds to 92; "0" is ignored (as the web's score layer does).
        let bpmByMeasure = Dictionary(grouping: t.entries, by: \.measure).mapValues { Set($0.map(\.bpm)) }
        #expect(bpmByMeasure == [1: [93], 2: [93], 3: [92], 4: [92]])
    }
}
