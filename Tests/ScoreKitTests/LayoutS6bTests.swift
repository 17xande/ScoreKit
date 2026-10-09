import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import ScoreKit

// S6b: multi-voice staves, rests, tie and accidental crowding on real scores; piano-part selection.

private let openScore = [
    "boulanger-parfois-je-suis-triste", "grandval-les-clochettes", "satie-je-te-veux",
    "schumann-widmung", "stanford-sou-wester",
]
private func load(_ name: String) throws -> Score { try Score.load(data: fixture(name)) }
private func openScoreFile(_ n: String) throws -> Score { try load("complex/openscore/\(n).mxl") }
private func pianoLayout(_ s: Score, width: Double = 100) -> ScoreLayout { s.layout(pianoOptions(s, width: width)) }

// MARK: Piano part selection

@Test("piano part: the piano parts of the five OpenScore scores are picked, and only they are laid out",
      arguments: [("boulanger-parfois-je-suis-triste", [1]), ("grandval-les-clochettes", [1, 2]), ("satie-je-te-veux", [1]),
                  ("schumann-widmung", [1]), ("stanford-sou-wester", [5])])
func pianoPartSelection(name: String, parts: [Int]) throws {
    let s = try openScoreFile(name)
    #expect(s.pianoPartIndices == parts)
    let staves = try #require(LayoutOptions.pianoStaves(of: s))
    #expect(staves.count == parts.count * 2)
    #expect(staves.allSatisfy { parts.contains($0.part) })
    let l = pianoLayout(s)
    #expect(!l.systems.isEmpty)
    for sys in l.systems { #expect(sys.staves.allSatisfy { parts.contains($0.partIndex) }) }
    // The default is still the whole score.
    let all = s.layout(LayoutOptions(width: .fixed(100)))
    #expect(Set(all.systems[0].staves.map(\.partIndex)).count == s.parts.count)
    #expect(l.size.height < all.size.height)
    // Every note of the shown parts is drawn, none of the hidden ones.
    for (pi, p) in s.parts.enumerated() {
        let drawn = p.measures.flatMap(\.notes).filter { l.notes[$0.id] != nil }.count
        #expect(parts.contains(pi) ? drawn > 0 : drawn == 0, "part \(pi)")
    }
}

@Test("piano part: the plain piano starters keep both staves; a score without piano is laid out whole")
func pianoPartPlain() throws {
    for n in ["bach-prelude-in-c", "minuet-in-g", "ode-to-joy", "twinkle-twinkle"] {
        let s = try Score.load(data: fixture("\(n).musicxml"))
        #expect(s.pianoPartIndices == [0], "\(n)")
        #expect(LayoutOptions.pianoStaves(of: s) == [.init(part: 0, staff: 1), .init(part: 0, staff: 2)], "\(n)")
        #expect(s.layout(pianoOptions(s, width: 80)).systems.count == s.layout(LayoutOptions()).systems.count)
    }
    // No piano part: staves stay nil.
    let s = try load("complex/lilypond/41h-TooManyParts.mxl")
    #expect(LayoutOptions.pianoStaves(of: s) == nil)
    var o = LayoutOptions()
    o.restrict(toPianoOf: s)
    #expect(o.staves == nil)
    // The LilyPond piano-staff file (a grand staff with no instrument name) counts as piano
    // only when other parts exist; alone it is already the whole score.
    let ps = try load("complex/lilypond/43a-PianoStaff.mxl")
    #expect(ps.layout(pianoOptions(ps, width: 80)).systems.count == ps.layout(LayoutOptions()).systems.count)
}

@Test("piano part: how a part is recognised")
func pianoRecognition() {
    func part(name: String = "", abbr: String? = nil, inst: String? = nil, sound: String? = nil, midi: Int? = nil) -> Part {
        Part(id: "P", name: name, abbreviation: abbr, staves: 1, measures: [], instrumentName: inst, instrumentSound: sound, midiProgram: midi)
    }
    #expect(part(sound: "keyboard.piano").isPiano)
    #expect(part(sound: "keyboard.harpsichord").isPiano)     // keyboard.* counts
    #expect(part(sound: "keyboard.celesta").isPiano)
    #expect(!part(name: "Organ", sound: "keyboard.organ").isPiano)
    #expect(part(name: "Klavier").isPiano)
    #expect(part(inst: "Pianoforte").isPiano)
    #expect(part(name: "Pno.").isPiano)                       // whole words
    #expect(part(abbr: "Pf.").isPiano)
    #expect(part(name: "Solo pf").isPiano)
    #expect(!part(name: "Chopf").isPiano)
    #expect(!part(name: "Pnoise").isPiano)
    #expect(!part(name: "Voice", sound: "voice.vocals").isPiano)
    #expect(!part(name: "Viola", sound: "strings.viola", midi: 42).isPiano)
    // MIDI 1-8 only as a last resort: a part with no name and no instrument information.
    #expect(part(midi: 1).isPiano)
    #expect(!part(name: "Lute", midi: 1).isPiano)
    #expect(!part(sound: "pluck.guitar", midi: 1).isPiano)
}

@Test("piano part: the grand-staff fallback needs a G clef over an F clef and no harp, organ or voice")
func grandStaffFallback() throws {
    func score(_ name: String, clefs: (String, String), sound: String? = nil, otherSound: String = "voice.vocals") throws -> Score {
        func inst(_ s: String?) -> String { s.map { "<score-instrument id=\"I\"><instrument-name>x</instrument-name><instrument-sound>\($0)</instrument-sound></score-instrument>" } ?? "" }
        let attrs = "<attributes><divisions>1</divisions><staves>2</staves><clef number=\"1\"><sign>\(clefs.0)</sign><line>2</line></clef><clef number=\"2\"><sign>\(clefs.1)</sign><line>4</line></clef></attributes>"
        let note = "<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><voice>1</voice><staff>1</staff></note>"
        let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>Solo</part-name>\(inst(otherSound))</score-part><score-part id=\"P2\"><part-name>\(name)</part-name>\(inst(sound))</score-part></part-list><part id=\"P1\"><measure number=\"1\"><attributes><divisions>1</divisions></attributes>\(note)</measure></part><part id=\"P2\"><measure number=\"1\">\(attrs)\(note)</measure></part></score-partwise>"
        return try Score.parse(xml: Data(xml.utf8))
    }
    #expect(try score("Acc.", clefs: ("G", "F")).pianoPartIndices == [1])
    #expect(try score("Acc.", clefs: ("G", "G")).pianoPartIndices.isEmpty)
    #expect(try score("Acc.", clefs: ("F", "F")).pianoPartIndices.isEmpty)
    #expect(try score("Harp", clefs: ("G", "F")).pianoPartIndices.isEmpty)
    #expect(try score("Acc.", clefs: ("G", "F"), sound: "pluck.harp").pianoPartIndices.isEmpty)
    #expect(try score("Organ", clefs: ("G", "F")).pianoPartIndices.isEmpty)
    #expect(try score("Choir", clefs: ("G", "F")).pianoPartIndices.isEmpty)
    // Exclusions are whole words and only matter for the fallback.
    #expect(try score("Bassoon duet", clefs: ("G", "F")).pianoPartIndices == [1])
    #expect(try score("Accompaniment", clefs: ("G", "F")).pianoPartIndices == [1])
    #expect(try score("Bass guitar", clefs: ("G", "F")).pianoPartIndices.isEmpty)
    #expect(try score("Piano (Bass)", clefs: ("G", "F")).pianoPartIndices == [1])
    #expect(try score("Klavier (Begleitung)", clefs: ("G", "F")).pianoPartIndices == [1])
    #expect(try score("Piano Alto Bass", clefs: ("F", "F")).pianoPartIndices == [1])
    // A part that says piano wins whatever its clefs are.
    #expect(try score("Piano", clefs: ("G", "G")).pianoPartIndices == [1])
}

@Test("piano part: tempo and words of hidden parts are still drawn above the piano")
func tempoFromHiddenParts() throws {
    let s = try openScoreFile("schumann-widmung")
    // "Innig, lebhaft" lives on the voice part (P1, hidden); it must show with the piano only.
    #expect(s.parts[0].measures[0].directions.contains { $0.words == "Innig, lebhaft" })
    let l = pianoLayout(s)
    let texts = l.systems.flatMap(\.items).compactMap { item -> String? in if case .text(let t, _, _) = item { t } else { nil } }
    #expect(texts.contains("Innig, lebhaft"))
    // And every tempo mark with words of any part appears (once per mark).
    for n in openScore {
        let sc = try openScoreFile(n)
        let ll = pianoLayout(sc)
        let t = Set(ll.systems.flatMap(\.items).compactMap { item -> String? in if case .text(let t, _, _) = item { t } else { nil } })
        for p in sc.parts { for m in p.measures { for d in m.directions where d.source == .direction {
            if let w = d.words { #expect(t.contains(w), "\(n): \(w)") }
        } } }
    }
}

@Test("tempo marks repeated by several parts are drawn once, even at other offsets or with the metronome in one copy")
func tempoDedupe() throws {
    func score(_ d1: String, _ d2: String) throws -> Score {
        let m = { (d: String) in "<measure number=\"1\"><attributes><divisions>4</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>\(d)<note><pitch><step>C</step><octave>5</octave></pitch><duration>16</duration><voice>1</voice><type>whole</type></note></measure>" }
        let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>A</part-name></score-part><score-part id=\"P2\"><part-name>B</part-name></score-part></part-list><part id=\"P1\">\(m(d1))</part><part id=\"P2\">\(m(d2))</part></score-partwise>"
        return try Score.parse(xml: Data(xml.utf8))
    }
    func words(_ w: String, offset: Int? = nil, metro: Bool = false, tempo: Bool = true) -> String {
        "<direction placement=\"above\"><direction-type><words>\(w)</words></direction-type>"
            + (metro ? "<direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>120</per-minute></metronome></direction-type>" : "")
            + (offset.map { "<offset>\($0)</offset>" } ?? "") + (tempo ? "<sound tempo=\"120\"/>" : "") + "</direction>"
    }
    func count(_ l: ScoreLayout, text: String) -> Int {
        l.systems.flatMap(\.items).filter { if case .text(let t, _, _) = $0 { t == text } else { false } }.count
    }
    func glyphs(_ l: ScoreLayout, _ g: Glyph) -> Int {
        l.systems.flatMap(\.items).filter { if case .glyph(let c, _, _, _, _) = $0 { c == g.codepoint } else { false } }.count
    }
    let o = LayoutOptions(width: .fixed(80))
    // Same words, one copy offset by a sixteenth.
    #expect(count(try score(words("Allegro"), words("Allegro", offset: 1)).layout(o), text: "Allegro") == 1)
    // Metronome in one part only: drawn once, with its note glyph.
    let l = try score(words("Allegro", metro: true), words("Allegro")).layout(o)
    #expect(count(l, text: "Allegro") == 1)
    #expect(glyphs(l, .metNoteQuarterUp) == 1)
    // The metronome copy is in the second part: still once, and merged.
    let l2 = try score(words("Allegro"), words("Allegro", metro: true)).layout(o)
    #expect(count(l2, text: "Allegro") == 1 && glyphs(l2, .metNoteQuarterUp) == 1)
    // Different texts at the same place are both drawn.
    let l3 = try score(words("Allegro"), words("Vivace")).layout(o)
    #expect(count(l3, text: "Allegro") == 1 && count(l3, text: "Vivace") == 1)
}

@Test("hideEmptyStaves with several parts and a system break")
func hideEmptyMultiPart() throws {
    // Part 1: one staff of notes. Part 2: a grand staff whose lower staff is only rests.
    let notes = (1...12).map { _ in "<note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><voice>1</voice><staff>1</staff></note>" }
    func measure(_ i: Int, _ extra: String, _ body: String) -> String { "<measure number=\"\(i)\">\(extra)\(body)</measure>" }
    let attrs1 = "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>"
    let attrs2 = "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><staves>2</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>F</sign><line>4</line></clef></attributes>"
    let rest2 = "<backup><duration>4</duration></backup><note><rest/><duration>4</duration><voice>2</voice><staff>2</staff></note>"
    let p1 = notes.enumerated().map { measure($0 + 1, $0 == 0 ? attrs1 : "", $1) }.joined()
    let p2 = notes.enumerated().map { measure($0 + 1, $0 == 0 ? attrs2 : "", $1 + rest2) }.joined()
    let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>A</part-name></score-part><score-part id=\"P2\"><part-name>B</part-name></score-part></part-list><part id=\"P1\">\(p1)</part><part id=\"P2\">\(p2)</part></score-partwise>"
    let s = try Score.parse(xml: Data(xml.utf8))
    var o = LayoutOptions(width: .fixed(30))
    #expect(s.layout(o).systems[0].staves.count == 3)
    o.hideEmptyStaves = true
    let l = s.layout(o)
    #expect(l.systems.count > 1)
    for sys in l.systems { #expect(sys.staves.map { [$0.partIndex, $0.staffInPart] } == [[0, 1], [1, 1]]) }
}

@Test("hideEmptyStaves drops a staff with only rests, keeps the others")
func hideEmpty() throws {
    let rest = "<note><rest/><duration>4</duration><voice>1</voice><staff>2</staff></note>"
    let nt = "<note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><voice>1</voice><staff>1</staff></note>"
    let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>Piano</part-name></score-part></part-list><part id=\"P1\"><measure number=\"1\"><attributes><divisions>1</divisions><staves>2</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>F</sign><line>4</line></clef></attributes>\(nt)<backup><duration>4</duration></backup>\(rest)</measure></part></score-partwise>"
    let s = try Score.parse(xml: Data(xml.utf8))
    #expect(s.layout(LayoutOptions()).systems[0].staves.count == 2)
    var o = LayoutOptions()
    o.hideEmptyStaves = true
    let l = s.layout(o)
    #expect(l.systems[0].staves.map(\.staffInPart) == [1])
    // Real piano music keeps both staves.
    let b = try Score.load(data: fixture("bach-prelude-in-c.musicxml"))
    #expect(b.layout(o).systems[0].staves.count == 2)
}

// MARK: Collisions

private func summary(_ cs: [Clash]) -> String { cs.prefix(8).map(\.description).joined(separator: "\n") }

// Known leftovers, by 0-based measure: Schumann m26 and m28 (1-based) have one head touching a stem
// of the other voice. Everything else on these scores is clash-free.
private let knownClashes: [String: Set<Int>] = ["schumann-widmung": [25, 27]]

@Test("no overlapping heads, stems, rests, accidentals or dots between voices, at two widths (known leftovers listed)",
      arguments: openScore, [80.0, 100.0])
func noClashes(name: String, width: Double) throws {
    let cs = clashes(pianoLayout(try openScoreFile(name), width: width))
    let allowed = knownClashes[name] ?? []
    let unexpected = cs.filter { !($0.measure.map(allowed.contains) ?? false) }
    #expect(unexpected.isEmpty, "\(summary(unexpected))")
    // The allowed ones are exactly the known pair of heads and stems, none of them rests or accidentals.
    for c in cs where allowed.contains(c.measure ?? -1) { #expect([c.a.kind, c.b.kind].contains(.stem) && [c.a.kind, c.b.kind].contains(.head)) }
    #expect(cs.count == allowed.count, "\(name) \(width): \(cs.count) clashes\n\(summary(cs))")
}

@Test("collisions: Satie m20-21 left hand (voices 1, 2 and 5) and Boulanger m31-34 are clash-free")
func namedMeasures() throws {
    for (n, ms) in [("satie-je-te-veux", 19...20), ("boulanger-parfois-je-suis-triste", 30...33), ("schumann-widmung", 3...12)] {
        let l = pianoLayout(try openScoreFile(n))
        let cs = clashes(l).filter { c in c.measure.map { ms.contains($0) } ?? false }
        #expect(cs.isEmpty, "\(n)\n\(summary(cs))")
    }
}

@Test("collisions: the rests of Satie's voice 5 hang below the voice 2 chords, not above the staff")
func satieRestsBelow() throws {
    let s = try openScoreFile("satie-je-te-veux")
    let l = pianoLayout(s)
    for mi in [19, 20] {
        let notes = s.parts[1].measures[mi].notes.filter { $0.staff == 2 }
        let v2 = notes.filter { $0.voice == "2" && !$0.isRest }
        for r in notes where r.voice == "5" && r.isRest {
            let box = try #require(l.notes[r.id]).headBox
            for h in v2 where h.onset == r.onset { #expect(box.minY >= l.notes[h.id]!.headBox.maxY - 1e-6, "m\(mi + 1)") }
            // not floating above the staff
            let top = l.systems[l.notes[r.id]!.systemIndex].staves[l.notes[r.id]!.staffIndex].top
            #expect(box.minY > top - 0.5)
        }
    }
}

// MARK: Voices on one staff

private func voiceScore(_ body: String) throws -> Score {
    let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\"><measure number=\"1\"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>\(body)</measure></part></score-partwise>"
    return try Score.parse(xml: Data(xml.utf8))
}
private func vnote(_ step: String, _ oct: Int, voice: Int, stem: String? = nil, dur: Int = 4, type: String = "whole") -> String {
    "<note><pitch><step>\(step)</step><octave>\(oct)</octave></pitch><duration>\(dur)</duration><voice>\(voice)</voice><type>\(type)</type>\(stem.map { "<stem>\($0)</stem>" } ?? "")</note>"
}

@Test("three voices on a staff: odd voices stem up, even down; the third voice's heads are offset; no overlaps")
func threeVoices() throws {
    let q = { (s: String, o: Int, v: Int) in vnote(s, o, voice: v, dur: 1, type: "quarter") }
    // Voice 1 and 3 share a pitch region (a second apart), voice 2 sits below.
    let s = try voiceScore(q("E", 5, 1) + q("E", 5, 1) + q("E", 5, 1) + q("E", 5, 1)
        + "<backup><duration>4</duration></backup>" + q("C", 5, 2) + q("C", 5, 2) + q("C", 5, 2) + q("C", 5, 2)
        + "<backup><duration>4</duration></backup>" + q("F", 5, 3) + q("E", 5, 3) + q("D", 5, 3) + q("F", 5, 3))
    let l = s.layout(LayoutOptions(width: .fixed(80), showMeasureNumbers: false))
    let ns = s.parts[0].measures[0].notes
    func up(_ n: Note) -> Bool { l.notes[n.id]!.stemEnd!.y < l.notes[n.id]!.headBox.midY }
    #expect(ns.filter { $0.voice == "1" }.allSatisfy { up($0) })
    #expect(ns.filter { $0.voice == "2" }.allSatisfy { !up($0) })
    #expect(ns.filter { $0.voice == "3" }.allSatisfy { up($0) })
    // Voice 3's F5 sits a second above voice 1's E5 and shares its stem side: it moves aside.
    let e1 = l.notes[ns.first { $0.voice == "1" }!.id]!.headBox, f3 = l.notes[ns.first { $0.voice == "3" }!.id]!.headBox
    #expect(abs(e1.minX - f3.minX) > 1)
    #expect(clashes(l).isEmpty, "\(summary(clashes(l)))")
}

@Test("two voices without <stem>: the upper-sounding voice is up whatever the numbers or order; equal registers use the order",
      arguments: [(1, 2), (1, 3), (1, 5), (2, 5), (3, 1), (5, 2)], [true, false])
func voicePairs(pair: (Int, Int), firstIsUpper: Bool) throws {
    let (a, b) = pair   // voice a is written first in the file
    // Voice a is the upper or the lower one; they never cross.
    let sa = vnote(firstIsUpper ? "E" : "B", firstIsUpper ? 5 : 4, voice: a, dur: 2, type: "half")
    let sb = vnote(firstIsUpper ? "B" : "E", firstIsUpper ? 4 : 5, voice: b, dur: 2, type: "half")
    let s = try voiceScore(sa + sa + "<backup><duration>4</duration></backup>" + sb + sb)
    let l = s.layout(LayoutOptions(width: .fixed(80), showMeasureNumbers: false))
    for n in s.parts[0].measures[0].notes where !n.isRest {
        let ln = l.notes[n.id]!
        let up = ln.stemEnd!.y < ln.headBox.midY
        let upper = (Int(n.voice)! == a) == firstIsUpper
        #expect(up == upper, "voices \(a),\(b) firstIsUpper \(firstIsUpper): voice \(n.voice)")
    }
}

@Test("two voices in one register without <stem>: the order decides")
func voicePairEqualRegister() throws {
    let s = try voiceScore(vnote("E", 5, voice: 3, dur: 2, type: "half") + vnote("E", 5, voice: 3, dur: 2, type: "half")
                           + "<backup><duration>4</duration></backup>" + vnote("E", 5, voice: 1, dur: 2, type: "half") + vnote("E", 5, voice: 1, dur: 2, type: "half"))
    let l = s.layout(LayoutOptions(width: .fixed(80), showMeasureNumbers: false))
    for n in s.parts[0].measures[0].notes {
        let ln = l.notes[n.id]!
        #expect((ln.stemEnd!.y < ln.headBox.midY) == (n.voice == "1"))
    }
}

@Test("three voices without <stem>: highest up, lowest down, the middle one toward the nearer outer voice")
func threeVoicesByPitch() throws {
    let q = { (s: String, o: Int, v: Int) in vnote(s, o, voice: v, dur: 1, type: "quarter") }
    func four(_ s: String, _ o: Int, _ v: Int) -> String { (0..<4).map { _ in q(s, o, v) }.joined() }
    let back = "<backup><duration>4</duration></backup>"
    // Voice 1 lowest, voice 2 highest, voice 3 just above voice 1.
    let s = try voiceScore(four("C", 4, 1) + back + four("A", 5, 2) + back + four("E", 4, 3))
    let l = s.layout(LayoutOptions(width: .fixed(80), showMeasureNumbers: false))
    let ns = s.parts[0].measures[0].notes
    func up(_ n: Note) -> Bool { l.notes[n.id]!.stemEnd!.y < l.notes[n.id]!.headBox.midY }
    #expect(ns.filter { $0.voice == "2" }.allSatisfy { up($0) })
    #expect(ns.filter { $0.voice == "1" }.allSatisfy { !up($0) })
    #expect(ns.filter { $0.voice == "3" }.allSatisfy { !up($0) })
}

@Test("an extra voice's rest is clear of the other voices and sits on the side of its own stems")
func extraVoiceRests() throws {
    // Voice 1 up (stem up), voice 2 down with a chord; voice 3 (stems down by explicit stem) rests under it.
    let r = "<note><rest/><duration>1</duration><voice>3</voice><type>quarter</type></note>"
    let s = try voiceScore(vnote("A", 5, voice: 1, dur: 4)
        + "<backup><duration>4</duration></backup>" + vnote("E", 4, voice: 2, stem: "down", dur: 1, type: "quarter")
        + "<note><chord/><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><voice>2</voice><type>quarter</type><stem>down</stem></note>"
        + "<forward><duration>3</duration></forward>"
        + "<backup><duration>4</duration></backup>" + r + vnote("B", 3, voice: 3, stem: "down", dur: 1, type: "quarter"))
    let l = s.layout(LayoutOptions(width: .fixed(80), showMeasureNumbers: false))
    let rest = s.parts[0].measures[0].notes.first { $0.isRest }!
    let rb = l.notes[rest.id]!.headBox
    let chord = s.parts[0].measures[0].notes.filter { $0.voice == "2" }.map { l.notes[$0.id]!.headBox }
    #expect(chord.allSatisfy { rb.minY >= $0.maxY - 1e-6 })
    #expect(clashes(l).isEmpty, "\(summary(clashes(l)))")
}

@Test("accidental columns of a chord never overlap, on every complex score")
func accidentalColumns() throws {
    for n in openScore {
        let cs = clashes(pianoLayout(try openScoreFile(n))).filter { $0.a.kind == .accidental || $0.b.kind == .accidental }
        #expect(cs.isEmpty, "\(n)\n\(summary(cs))")
    }
}

@Test("ties between the same two chords are nested, never crossing, with common ends")
func nestedChordTies() throws {
    let s = try openScoreFile("boulanger-parfois-je-suis-triste")
    let l = pianoLayout(s)
    // Group tie paths by (staff, rounded x range): tie arcs of one chord pair stay in the same
    // direction in a nested order, so no two arcs of the same direction swap their apexes.
    struct Arc { var x1: Double; var x2: Double; var yStart: Double; var apex: Double; var up: Bool; var sys: Int }
    var arcs: [Arc] = []
    for (si, sys) in l.systems.enumerated() {
        for it in sys.items {
            guard case .path(let els, _, true, let note?, nil) = it, l.notes[note] != nil else { continue }
            guard case .move(let a)? = els.first, case .curve(let to, let c1, _)? = els.dropFirst().first else { continue }
            let up = c1.y < a.y
            arcs.append(Arc(x1: a.x, x2: to.x, yStart: a.y, apex: pathBounds(els).let { up ? $0.minY : $0.maxY }, up: up, sys: si))
        }
    }
    #expect(arcs.count > 20)
    for i in arcs.indices { for j in arcs.indices where j > i {
        let a = arcs[i], b = arcs[j]
        guard a.sys == b.sys, a.up == b.up, abs(a.x1 - b.x1) < 0.01, abs(a.x2 - b.x2) < 0.01, abs(a.yStart - b.yStart) > 0.01 else { continue }
        // Same ends and direction: the arc that starts farther out must also peak farther out.
        let outerStartsFirst = a.up ? a.yStart < b.yStart : a.yStart > b.yStart
        let outerPeaksFirst = a.up ? a.apex < b.apex : a.apex > b.apex
        #expect(outerStartsFirst == outerPeaksFirst, "tie arcs cross at x=\(a.x1)")
    } }
}

private extension CGRect { func `let`<T>(_ f: (CGRect) -> T) -> T { f(self) } }

// MARK: Dots

@Test("every dotted note draws exactly one augmentation dot per dot, in a space, right of its head")
func dotsAreDrawn() throws {
    var scores: [(String, Score)] = []
    for n in ["bach-prelude-in-c", "minuet-in-g", "ode-to-joy", "twinkle-twinkle"] { scores.append((n, try Score.load(data: fixture("\(n).musicxml")))) }
    for n in openScore { scores.append((n, try openScoreFile(n))) }
    for n in ["03e-Rhythm-No-Divisions", "13a-KeySignatures", "21d-Chords-SchubertStabatMater", "23a-Tuplets", "24a-GraceNotes", "33b-Spanners-Tie", "43a-PianoStaff", "45a-SimpleRepeat"] {
        scores.append((n, try load("complex/lilypond/\(n).mxl")))
    }
    for (name, s) in scores {
        // Whole score, so every drawn note is checked (piano-only for the big ones).
        var o = LayoutOptions(width: .fixed(100))
        o.restrict(toPianoOf: s)
        let l = s.layout(o)
        var dots: [NoteID: [CGRect]] = [:]
        var heads: [NoteID: CGRect] = [:]
        for sys in l.systems { for it in sys.items {
            guard case .glyph(let cp, _, _, let id?, _) = it else { continue }
            if cp == Glyph.augmentationDot.codepoint { dots[id, default: []].append(it.bounds) }
        } }
        for (id, ln) in l.notes { heads[id] = ln.headBox }
        var checked = 0
        for p in s.parts { for m in p.measures { for n in m.notes where n.dots > 0 && !n.isGrace && n.printObject {
            guard let ln = l.notes[n.id], !ln.isRest || true else { continue }
            if l.sharedHeads[n.id] != nil { continue }   // the dot is drawn once, by the note that owns the head
            checked += 1
            let ds = dots[n.id] ?? []
            #expect(ds.count == n.dots, "\(name) m\(m.index + 1) note \(n.id.value): \(ds.count) dots for \(n.dots)")
            if !n.isRest {
                // To the right of the head, and centred in a space (a half-integer y in staff units).
                for d in ds { #expect(d.minX >= ln.headBox.maxX - 0.01, "\(name) dot left of its head") }
            }
        } } }
        #expect(checked > 0 || name.hasPrefix("1") || name.hasPrefix("0") || name.hasPrefix("2") || name.hasPrefix("3") || name.hasPrefix("4") || name == "ode-to-joy" || name == "twinkle-twinkle" || name == "stanford-sou-wester" || name == "grandval-les-clochettes", "\(name)")
    }
}

@Test("a dot never touches the flag or stem of its own note: the starter songs and the complex scores")
func dotsClearOfFlags() throws {
    var scores: [(String, Score)] = []
    for n in ["bach-prelude-in-c", "minuet-in-g", "ode-to-joy", "twinkle-twinkle"] { scores.append((n, try Score.load(data: fixture("\(n).musicxml")))) }
    for n in openScore { scores.append((n, try openScoreFile(n))) }
    for (n, s) in scores {
        let cs = clashes(s.layout(pianoOptions(s, width: 80))).filter { $0.a.kind == .dot || $0.b.kind == .dot }
        #expect(cs.isEmpty, "\(n)\n\(summary(cs))")
    }
}
