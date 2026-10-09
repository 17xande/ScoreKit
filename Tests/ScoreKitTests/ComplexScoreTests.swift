import Foundation
import Testing
@testable import ScoreKit

// Real-world and conformance scores: OpenScore Lieder (CC0) and the LilyPond unofficial
// MusicXML test suite (MIT). Licences and sources are beside the files.

private let openScore = [
    "boulanger-parfois-je-suis-triste", "grandval-les-clochettes", "satie-je-te-veux",
    "schumann-widmung", "stanford-sou-wester",
].map { "complex/openscore/\($0).mxl" }

private let lilypond = [
    "03e-Rhythm-No-Divisions", "13a-KeySignatures", "13e-KeySignatures-Cancel", "21d-Chords-SchubertStabatMater",
    "23a-Tuplets", "23d-Tuplets-Nested", "24a-GraceNotes", "33b-Spanners-Tie", "41h-TooManyParts", "43a-PianoStaff",
    "45a-SimpleRepeat", "45b-RepeatWithAlternatives", "45c-SimpleRepeat-Nested", "45d-Repeats-MultipleEndings",
    "45i-Repeats-Nested", "46d-PickupMeasure-ImplicitMeasures", "51a-Header-Credits", "51b-Header-Quotes",
    "51c-MultipleMetadata", "51d-EmptyTitle",
].map { "complex/lilypond/\($0).mxl" }

private func load(_ name: String) throws -> Score { try Score.load(data: fixture(name)) }

/// The played measures (1-based) as compressed runs, e.g. "1-84,29-57".
private func runs(_ s: Score) -> String {
    let seq = Unroll(score: s).measures.map { $0.index + 1 }
    var out: [String] = []
    var i = 0
    while i < seq.count {
        var j = i
        while j + 1 < seq.count && seq[j + 1] == seq[j] + 1 { j += 1 }
        out.append(i == j ? "\(seq[i])" : "\(seq[i])-\(seq[j])")
        i = j + 1
    }
    return out.joined(separator: ",")
}

@Test("fixtures: every complex score parses, unrolls and lays out (page and line) within budget",
      arguments: openScore + lilypond)
func complexScoresLayOut(name: String) throws {
    let clock = ContinuousClock()
    let elapsed = try clock.measure {
        let score = try load(name)
        let timeline = Timeline(score: score)
        #expect(!timeline.unroll.measures.isEmpty)
        for width in [LayoutOptions.Width.fixed(80), .singleLine] {
            let layout = score.layout(LayoutOptions(width: width))
            #expect(!layout.systems.isEmpty)
        }
    }
    // Generous for a debug build on a slow machine; they take well under a second in release.
    #expect(elapsed < .seconds(15), "\(name) took \(elapsed)")
}

@Test("unroll: Stanford 'Sou'wester' plays volta 1 (measures 58-84) once, then volta 2")
func stanfordOrder() throws {
    // Volta 1 is exported as start + discontinue on its first measure; the backward repeat
    // at 84 closes it. Correct (and OSMD 2.1.3's walk): 1-84, 29-57, 85-141. Before the fix
    // the repeat returned to 59 and ending 2 was lost: 1-84, 59-84, 86-141.
    #expect(runs(try load("complex/openscore/stanford-sou-wester.mxl")) == "1-84,29-57,85-141")
}

@Test("unroll: a short bracket before a later backward repeat extends to the repeat")
func longVoltaExtends() throws {
    func m(_ i: Int, _ extra: String = "", _ end: String = "") -> String {
        "<measure number=\"\(i)\">\(i == 1 ? "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>" : "")\(extra)<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration></note>\(end)</measure>"
    }
    let start1 = "<barline location=\"left\"><ending number=\"1\" type=\"start\">1.</ending></barline>"
    let stopEarly = "<barline location=\"right\"><ending number=\"1\" type=\"discontinue\"/></barline>"
    let back = "<barline location=\"right\"><repeat direction=\"backward\"/></barline>"
    let start2 = "<barline location=\"left\"><ending number=\"2\" type=\"start\">2.</ending></barline>"
    let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\">"
        + m(1, "<barline location=\"left\"><repeat direction=\"forward\"/></barline>") + m(2)
        + m(3, start1, stopEarly) + m(4) + m(5, "", back) + m(6, start2) + m(7) + "</part></score-partwise>"
    #expect(runs(try Score.parse(xml: Data(xml.utf8))) == "1-5,1-2,6-7")
}

@Test("unroll: Satie 'Je te veux' plays refrain with endings 1, 2, 3 around the two verses")
func satieOrder() throws {
    // Intended order (segno glyphs at 6, 78, 110, the verse lyrics, "Pour finir" and the Fine):
    // refrain with ending 1, verse 1, refrain with ending 2, verse 2, refrain with ending 3 to the Fine.
    // OSMD 2.1.3 gives 1-78,6-35,38-110 (endings 2 and 3 on the first pass), which is wrong.
    #expect(runs(try load("complex/openscore/satie-je-te-veux.mxl")) == "1-37,47-78,6-35,38-39,79-110,6-35,40-46")
}

@Test("unroll: the straight-through scores play in written order")
func straightThrough() throws {
    #expect(runs(try load("complex/openscore/schumann-widmung.mxl")) == "1-44")
    #expect(runs(try load("complex/openscore/boulanger-parfois-je-suis-triste.mxl")) == "1-52")
}

@Test("key signatures: more than 7 accidentals (theoretical keys) never trap")
func theoreticalKeys() throws {
    // LilyPond 13a: -11...11 fifths, plus extremes and key changes between them.
    _ = try load("complex/lilypond/13a-KeySignatures.mxl").layout(LayoutOptions(width: .fixed(80)))
    for f in [8, 10, 14, 15, 99, -8, -11, -15, Int(Int32.max), Int.max, Int.min] {
        let head = "<score-partwise><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\">"
        let time = "<time><beats>4</beats><beat-type>4</beat-type></time>"
        let note = "<note><pitch><step>F</step><octave>4</octave></pitch><duration>4</duration></note>"
        var xml = head
        xml += "<measure number=\"1\"><attributes><divisions>1</divisions><key><fifths>\(f)</fifths></key>\(time)</attributes>\(note)</measure>"
        xml += "<measure number=\"2\"><attributes><key><fifths>\(f / -3)</fifths></key></attributes>\(note)</measure>"
        xml += "<measure number=\"3\"><attributes><key><fifths>3</fifths></key></attributes>\(note)</measure></part></score-partwise>"
        let s = try Score.parse(xml: Data(xml.utf8))
        _ = s.layout(LayoutOptions(width: .fixed(80)))
        _ = s.layout(LayoutOptions(width: .singleLine))
    }
}

@Test("key signatures: theoretical keys double the first letters")
func theoreticalKeyAlterations() {
    // G-sharp major: F## and six single sharps.
    #expect(StaffGeometry.keyAlter(fifths: 8, step: .F) == 2)
    #expect(StaffGeometry.keyAlter(fifths: 8, step: .C) == 1)
    #expect(StaffGeometry.keyAlter(fifths: 10, step: .G) == 2)
    #expect(StaffGeometry.keyAlter(fifths: 10, step: .D) == 1)
    // -9 fifths is B-double-flat major: B and E doubled, the other flats single.
    #expect(StaffGeometry.keyAlter(fifths: -9, step: .B) == -2)
    #expect(StaffGeometry.keyAlter(fifths: -9, step: .E) == -2)
    #expect(StaffGeometry.keyAlter(fifths: -9, step: .A) == -1)
    #expect(StaffGeometry.keyAlter(fifths: 7, step: .F) == 1)
    #expect(StaffGeometry.keyAlter(fifths: 100, step: .B) == 2)
    #expect(StaffGeometry.keyAlter(fifths: 0, step: .F) == 0)
    #expect(StaffGeometry.keyGlyphCount(11) == 7)
    #expect(StaffGeometry.keyGlyphCount(-3) == 3)
}

@Test("parse: a missing <divisions> counts as 1 per quarter (LilyPond 03e, 41h, 51a-d)")
func missingDivisions() throws {
    for n in ["03e-Rhythm-No-Divisions", "41h-TooManyParts", "51a-Header-Credits", "51b-Header-Quotes",
              "51c-MultipleMetadata", "51d-EmptyTitle"] {
        let s = try load("complex/lilypond/\(n).mxl")
        for p in s.parts {
            #expect(!p.measures.isEmpty, "\(n)")
            for m in p.measures { #expect(m.divisions == 1, "\(n)") }
        }
        // Whole notes with <duration>4</duration> are 4 quarters.
        let first = try #require(s.parts[0].measures.first)
        #expect(first.duration == Rational(4, 1), "\(n)")
        #expect(!first.notes.isEmpty, "\(n)")
        #expect(Timeline(score: s).length == Rational(4, 1) * Rational(s.parts[0].measures.count, 1), "\(n)")
    }
    #expect(try load("complex/lilypond/41h-TooManyParts.mxl").parts.count == 3)
}

private func glyphCodes(_ s: Score, measure: Int = 0) -> [Glyph] {
    let l = s.layout(.singleLine)
    let first = s.parts[0].measures[measure].notes.compactMap { l.noteBoxes[$0.id]?.minX }.min() ?? .infinity
    let all: [Glyph] = [.accidentalSharp, .accidentalFlat, .accidentalNatural, .accidentalDoubleSharp, .accidentalDoubleFlat]
    return l.systems.flatMap(\.items).compactMap { item -> (Glyph, CGPoint)? in
        guard case .glyph(let cp, let p, _, let id, _) = item, id == nil, let g = Glyph(rawValue: cp), all.contains(g) else { return nil }
        return (g, p)
    }.filter { $0.1.x < first }.sorted { $0.1.x < $1.1.x }.map(\.0)
}

private func keyScore(_ fifths: [Int]) throws -> Score {
    let head = "<score-partwise><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\">"
    var xml = head
    for (i, f) in fifths.enumerated() {
        let attrs = i == 0 ? "<divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time>" : ""
        xml += "<measure number=\"\(i + 1)\"><attributes>\(attrs)<key><fifths>\(f)</fifths></key></attributes>"
        xml += "<note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration></note></measure>"
    }
    return try Score.parse(xml: Data((xml + "</part></score-partwise>").utf8))
}

@Test("key signatures: 8 sharps is one double sharp (F) and six sharps; 10 doubles F, C, G")
func theoreticalKeyGlyphs() throws {
    #expect(glyphCodes(try keyScore([8])) == [.accidentalDoubleSharp] + Array(repeating: .accidentalSharp, count: 6))
    #expect(glyphCodes(try keyScore([10])) == Array(repeating: .accidentalDoubleSharp, count: 3) + Array(repeating: .accidentalSharp, count: 4))
    #expect(glyphCodes(try keyScore([-9])) == Array(repeating: .accidentalDoubleFlat, count: 2) + Array(repeating: .accidentalFlat, count: 5))
    #expect(try keyScore([Int.min, Int.max]).parts[0].measures.count == 2)
}

@Test("key signatures: a change cancels only the letters it alters less")
func keyCancellation() throws {
    func naturals(_ f: [Int]) throws -> Int {
        let s = try keyScore(f)
        return glyphCodes(s, measure: 1).filter { $0 == .accidentalNatural }.count
    }
    #expect(try naturals([3, 9]) == 0)       // more sharps: nothing cancelled
    #expect(try naturals([3, 1]) == 2)       // F C G -> F: naturals on C and G
    #expect(try naturals([3, -2]) == 3)      // sign change cancels all
    #expect(try naturals([3, 0]) == 3)
    #expect(try naturals([2, 3]) == 0)
}

@Test("unroll: endings and repeats around the long-volta rule")
func voltaRuleGuards() throws {
    func m(_ i: Int, _ extra: String = "", _ end: String = "") -> String {
        let attrs = i == 1 ? "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>" : ""
        return "<measure number=\"\(i)\">\(attrs)\(extra)<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration></note>\(end)</measure>"
    }
    func ending(_ n: Int, _ type: String, _ loc: String, back: Bool = false) -> String {
        "<barline location=\"\(loc)\"><ending number=\"\(n)\" type=\"\(type)\">\(n).</ending>\(back ? "<repeat direction=\"backward\"/>" : "")</barline>"
    }
    let fwd = "<barline location=\"left\"><repeat direction=\"forward\"/></barline>"
    let back = "<barline location=\"right\"><repeat direction=\"backward\"/></barline>"
    func order(_ ms: [String]) throws -> String {
        let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\">" + ms.joined() + "</part></score-partwise>"
        return runs(try Score.parse(xml: Data(xml.utf8)))
    }
    // AABB: A (1-2) with endings 3 / 4 and the repeat in the ending, then B (5-8) repeated without a forward sign.
    #expect(try order([m(1), m(2), m(3, ending(1, "start", "left"), ending(1, "stop", "right", back: true)),
                       m(4, ending(2, "start", "left"), ending(2, "stop", "right")), m(5), m(6), m(7), m(8, "", back)])
            == "1-3,1-2,4-8,5-8")
    // A one-bar volta 1 with the repeat in the same bar.
    #expect(try order([m(1, fwd), m(2, ending(1, "start", "left"), ending(1, "stop", "right", back: true)),
                       m(3, ending(2, "start", "left"), ending(2, "stop", "right")), m(4)]) == "1-2,1,3-4")
    // A later section with its own forward sign after a finished volta group.
    #expect(try order([m(1, fwd), m(2, ending(1, "start", "left"), ending(1, "stop", "right", back: true)),
                       m(3, ending(2, "start", "left"), ending(2, "stop", "right")),
                       m(4, fwd), m(5, "", back), m(6)]) == "1-2,1,3-5,4-6")
}

@Test("fixtures: measure counts and timeline lengths are stable")
func fixtureInvariants() throws {
    let expected: [String: (measures: Int, quarters: Double)] = [
        "complex/openscore/stanford-sou-wester.mxl": (141, 0),
        "complex/openscore/schumann-widmung.mxl": (44, 0),
        "complex/openscore/boulanger-parfois-je-suis-triste.mxl": (52, 0),
        "complex/openscore/satie-je-te-veux.mxl": (110, 0),
        "complex/openscore/grandval-les-clochettes.mxl": (98, 0),
    ]
    for (name, e) in expected {
        let s = try load(name)
        #expect(s.parts.map(\.measures.count).max() == e.measures, "\(name)")
        let t = Timeline(score: s)
        #expect(t.length == t.unroll.length)
        #expect(t.length > .zero)
    }
}

@Test("unroll: LilyPond 45a/c/d/i repeats play in the intended order")
func lilypondRepeatOrders() throws {
    func order(_ n: String) throws -> String { runs(try load("complex/lilypond/\(n).mxl")) }
    // 45a: bar 1 five times, then bar 2.
    #expect(try order("45a-SimpleRepeat") == "1,1,1,1,1-2")
    // 45c: bar 1; bars 2-3 five times; 4-7 (outer repeat times=1: once); 8.
    #expect(try order("45c-SimpleRepeat-Nested") == "1-3,2-3,2-3,2-3,2-8")
    // 45d: eight passes of bar 1 + endings 1 | 2 | 3,5,7 | 4,6 | 3,5,7 | 4,6 | 3,5,7 | 8, then bar 12.
    #expect(try order("45d-Repeats-MultipleEndings") == "1-2,1,3-5,1,6-9,1,10,1,6-9,1,10,1,6-9,1,11-12")
    // 45i: ending 1 holds a nested repeat of bar 3, ending 2 one of bar 5 (same as OSMD).
    #expect(try order("45i-Repeats-Nested") == "1-3,3-4,1,5,5-7")
}

@Test("timeline: ties over grace notes, in time order across voices (OSMD parity and its tie bugs)")
func tieEdgeCases() throws {
    // Stanford bar 1: voice 2 holds E-flat/G for 3 beats into voice 1's chord, which stops them.
    let t = Timeline(score: try load("complex/openscore/stanford-sou-wester.mxl"))
    let first = try #require(t.entries.first { $0.notes.contains { $0.midi == 51 } })
    #expect(first.notes.filter { $0.midi == 51 }.allSatisfy { $0.tie == .start && near($0.quarters, 2) })
    let stop = try #require(t.entries.filter { $0.notes.contains { $0.midi == 51 } }.dropFirst().first)
    #expect(stop.notes.filter { $0.midi == 51 }.allSatisfy { $0.tie == .continue })
    // Bars 51-52 of Boulanger: the 5-note chord tie is whole: E5/C6 start 0.833 and continue.
    let b = Timeline(score: try load("complex/openscore/boulanger-parfois-je-suis-triste.mxl"))
    let m51 = try #require(b.entries.last { $0.measure == 51 })
    #expect(m51.notes.contains { $0.midi == 76 && $0.tie == .start && near($0.quarters, 0.5 + 1.0 / 3) })
}

@Test("tempo: OSMD maps the word Largo to 52; ScoreKit keeps its default 100 for words")
func tempoWordsAreDisplayOnly() throws {
    let t = Timeline(score: try load("complex/lilypond/21d-Chords-SchubertStabatMater.mxl"))
    #expect(t.entries.allSatisfy { near($0.bpm, TempoMap.defaultBPM) })
}
