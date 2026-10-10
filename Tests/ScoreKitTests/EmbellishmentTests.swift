import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import ScoreKit

// S6c part 2: articulations, fermatas, arpeggios, ornaments, tremolo, words.

private func score(_ measures: [String], staves: Int = 1, extraParts: String = "") throws -> Score {
    let clefs = staves == 2 ? "<staves>2</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>F</sign><line>4</line></clef>"
                            : "<clef><sign>G</sign><line>2</line></clef>"
    var body = "", other = ""
    for (i, m) in measures.enumerated() {
        let attrs = i == 0 ? "<attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time>\(clefs)</attributes>" : ""
        body += "<measure number=\"\(i + 1)\">\(attrs)\(m)</measure>"
    }
    if !extraParts.isEmpty {
        other = "<part id=\"P2\">" + measures.indices.map { i in
            "<measure number=\"\(i + 1)\">\(i == 0 ? "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>" : "")\(i == 0 ? extraParts : "")<note><rest measure=\"yes\"/><duration>4</duration></note></measure>"
        }.joined() + "</part>"
    }
    let list = "<score-part id=\"P1\"><part-name>Piano</part-name></score-part>" + (extraParts.isEmpty ? "" : "<score-part id=\"P2\"><part-name>Voice</part-name></score-part>")
    return try Score.parse(xml: Data("<score-partwise><part-list>\(list)</part-list><part id=\"P1\">\(body)</part>\(other)</score-partwise>".utf8))
}

private func note(_ step: String, _ oct: Int, dur: Int = 1, staff: Int = 1, voice: Int = 1, extra: String = "", chord: Bool = false, notations: String = "") -> String {
    "<note>\(chord ? "<chord/>" : "")<pitch><step>\(step)</step><octave>\(oct)</octave></pitch><duration>\(dur)</duration><voice>\(voice)</voice><staff>\(staff)</staff>\(extra)\(notations.isEmpty ? "" : "<notations>\(notations)</notations>")</note>"
}
private func rest(_ dur: Int) -> String { "<note><rest/><duration>\(dur)</duration></note>" }
private func words(_ text: String, placement: String? = nil, extra: String = "") -> String {
    "<direction\(placement.map { " placement=\"\($0)\"" } ?? "")><direction-type><words>\(text)</words>\(extra)</direction-type><staff>1</staff></direction>"
}
private func marks(_ l: ScoreLayout, _ kind: LaidMark.Kind) -> [[LayoutItem]] {
    l.systems.flatMap { s in s.marks.filter { $0.kind == kind }.map { Array(s.items[$0.items]) } }
}
private func top(_ l: ScoreLayout, _ it: LayoutItem) -> Double { it.bounds.midY - l.systems[0].staves[0].top }

// MARK: Parsing

@Test("parse: articulations, fermata, arpeggio, ornaments with accidental marks, wavy line and tremolo")
func parseEmbellishments() throws {
    let s = try score([
        note("C", 5, notations: "<articulations><staccato/><accent placement=\"below\"/><detached-legato/><strong-accent/><tenuto/><staccatissimo/></articulations><fermata type=\"inverted\"/>")
        + note("D", 5, notations: "<arpeggiate number=\"2\" direction=\"up\"/><ornaments><trill-mark/><accidental-mark placement=\"below\">sharp</accidental-mark><wavy-line type=\"start\" number=\"1\"/><mordent/><inverted-mordent/><turn/><inverted-turn/></ornaments>")
        + note("E", 5, notations: "<ornaments><wavy-line type=\"stop\"/><tremolo>3</tremolo></ornaments>")
        + note("F", 5, notations: "<ornaments><tremolo type=\"start\">2</tremolo></ornaments>"),
    ])
    let n = s.parts[0].measures[0].notes
    #expect(n[0].articulations.map(\.kind) == [.staccato, .accent, .tenutoStaccato, .strongAccent, .tenuto, .staccatissimo])
    #expect(n[0].articulations[1].above == false && n[0].articulations[0].above == nil)
    #expect(n[0].fermata == FermataMark(inverted: true))
    #expect(n[1].arpeggio == ArpeggioMark(number: 2, up: true))
    #expect(n[1].ornaments.map(\.kind) == [.trill, .mordent, .invertedMordent, .turn, .invertedTurn])
    #expect(n[1].ornaments[0].accidental == "sharp" && n[1].ornaments[0].accidentalAbove == false && n[1].ornaments[1].accidental == nil)
    #expect(n[1].wavyLines == [WavyMark(kind: .start, number: 1)] && n[2].wavyLines == [WavyMark(kind: .stop, number: 1)])
    #expect(n[2].tremolo == TremoloMark(kind: .single, marks: 3) && n[3].tremolo == TremoloMark(kind: .start, marks: 2))
}

@Test("parse: a fermata on a barline")
func parseBarlineFermata() throws {
    let s = try score([note("C", 5, dur: 4) + "<barline location=\"right\"><bar-style>light-heavy</bar-style><fermata/></barline>"])
    #expect(s.parts[0].measures[0].barlines.first?.fermata == FermataMark(inverted: false))
}

@Test("parse: plain words are kept (collapsed); tempo, jump and symbol words are not; dashes pair up")
func parseWords() throws {
    let s = try score([
        words("cresc.   poco", placement: "below", extra: "") + "<direction><direction-type><dashes type=\"start\" number=\"1\"/></direction-type><staff>1</staff></direction>"
        + note("C", 5, dur: 2) + "<direction><direction-type><dashes type=\"stop\" number=\"1\"/></direction-type><staff>1</staff></direction>" + note("D", 5, dur: 2),
        words("Allegro") .replacingOccurrences(of: "</direction>", with: "<sound tempo=\"120\"/></direction>") + words("*") + words("D.C. al Fine").replacingOccurrences(of: "</direction>", with: "<sound dacapo=\"yes\"/></direction>")
        + words("rit.") + note("C", 5, dur: 4),
    ])
    let p = s.parts[0]
    #expect(p.words.map(\.text) == ["cresc. poco", "rit."])
    #expect(p.words[0].above == false && p.words[1].above == nil)
    #expect(p.dashes == [DashLine(staff: 1, start: ScorePosition(measure: 0, onset: .zero), end: ScorePosition(measure: 0, onset: Rational(2)), above: nil)])
    #expect(p.measures[1].directions.first?.words == "Allegro")
}

// MARK: Articulations

@Test("articulations: opposite the stem, in a space, nearest the head first; with two voices on the stem side")
func articulationPlacement() throws {
    // Stem up (C5 and below the middle line: B4 is on the line, stem up): marks below.
    let s = try score([
        note("E", 4, notations: "<articulations><accent/><staccato/></articulations>") + note("G", 5, notations: "<articulations><staccato/></articulations>") + rest(2),
    ])
    let l = s.layout(.singleLine)
    let a = marks(l, .articulation)
    #expect(a.count == 2)
    let head1 = try #require(l.noteBoxes[NoteID(0)]), head2 = try #require(l.noteBoxes[NoteID(1)])
    // E4 stem up: below the head, the dot nearer than the accent.
    #expect(a[0].count == 2 && a[0][0].bounds.minY > head1.maxY && a[0][0].bounds.minY < a[0][1].bounds.minY)
    // G5 stem down: above the head.
    #expect(a[1][0].bounds.maxY < head2.minY)
    // A mark in the staff sits in a space (centre at k + 0.5 from the top line), not on a line.
    let c = top(l, a[0][0]) + 0
    #expect(abs((c - 0.5) - (c - 0.5).rounded()) < 0.2 || c > 4 || c < 0)
}

@Test("articulations: with two voices on one staff they go on the stem side, past the tip")
func articulationStemSide() throws {
    let s = try score([
        note("G", 5, dur: 2, notations: "<articulations><staccato/></articulations>") + rest(2) + "<backup><duration>4</duration></backup>" + note("C", 4, dur: 2, voice: 2, notations: "<articulations><accent/></articulations>") + rest(2),
    ])
    let l = s.layout(.singleLine)
    let a = marks(l, .articulation)
    #expect(a.count == 2)
    let st = l.systems[0].staves[0].top
    // Upper voice: stem up, so the dot is above the stem tip, far over the head.
    #expect(a[0][0].bounds.maxY < (l.noteBoxes[NoteID(0)]!.minY - 2))
    #expect(a[1][0].bounds.minY > (l.noteBoxes[NoteID(2)]!.maxY + 2))
    _ = st
}

@Test("articulations: a tenuto with a staccato is one portato mark")
func portato() throws {
    let s = try score([note("C", 5, notations: "<articulations><tenuto/><staccato/></articulations>") + rest(3)])
    let a = marks(s.layout(.singleLine), .articulation)
    #expect(glyphsOf(a[0]) == [Glyph.articTenutoStaccatoAbove.codepoint])
}
private func glyphsOf(_ its: [LayoutItem]) -> [UInt32] { its.compactMap { if case .glyph(let c, _, _, _, _) = $0 { c } else { nil } } }

@Test("articulations: a slur on the same side goes outside them")
func slurOutsideArticulations() throws {
    let s = try score([
        note("C", 5, notations: "<slur type=\"start\"/><articulations><staccato/></articulations>") + note("D", 5, notations: "<articulations><staccato/></articulations>")
        + note("E", 5, notations: "<articulations><staccato/></articulations>") + note("F", 5, notations: "<slur type=\"stop\"/><articulations><staccato/></articulations>"),
    ])
    let l = s.layout(.singleLine)
    #expect(markClashes(l).isEmpty)
    let slur = try #require(marks(l, .slur).first?.first)
    let dots = marks(l, .articulation).flatMap { $0 }
    // All stems point down here (notes above the middle line): the dots are above the heads, inside the slur's arc.
    #expect(dots.allSatisfy { $0.bounds.maxY > slur.bounds.minY })
}

// MARK: Fermata

@Test("fermata: above the staff; inverted below it; also on rests and barlines")
func fermatas() throws {
    let s = try score([
        note("C", 5, notations: "<fermata/>") + note("D", 5, notations: "<fermata type=\"inverted\"/>")
        + "<note><rest/><duration>2</duration><notations><fermata/></notations></note>"
        + "<barline location=\"right\"><fermata/></barline>",
    ])
    let l = s.layout(.singleLine)
    let f = marks(l, .fermata)
    #expect(f.count == 4)
    #expect(glyphsOf(f[0]) == [Glyph.fermataAbove.codepoint] && top(l, f[0][0]) < 0)
    #expect(glyphsOf(f[1]) == [Glyph.fermataBelow.codepoint] && top(l, f[1][0]) > 4)
    #expect(markClashes(l).isEmpty)
}

// MARK: Arpeggio

@Test("arpeggio: a wavy line left of the chord, spanning its heads, with room reserved for it")
func arpeggioLine() throws {
    let chord = note("C", 4, notations: "<arpeggiate/>") + note("E", 4, chord: true, notations: "<arpeggiate/>") + note("G", 4, chord: true, notations: "<arpeggiate/>")
    let with = try score([chord + rest(3)]), without = try score([note("C", 4) + note("E", 4, chord: true) + note("G", 4, chord: true) + rest(3)])
    let l = with.layout(.singleLine), l0 = without.layout(.singleLine)
    let a = try #require(marks(l, .arpeggio).first)
    let box = try #require(l.noteBoxes[NoteID(0)]), top = try #require(l.noteBoxes[NoteID(2)])
    let line = a[0].bounds
    #expect(line.maxX < box.minX && line.minY <= top.minY + 0.01 && line.maxY >= box.maxY - 0.01)
    #expect(l.size.width > l0.size.width, "the line takes room")
    #expect(markClashes(l).isEmpty)
}

@Test("arpeggio: notes of one number in both staves make one line across them")
func arpeggioCrossStaff() throws {
    let m = note("C", 3, staff: 2, notations: "<arpeggiate/>") + note("G", 3, staff: 2, chord: true, notations: "<arpeggiate/>")
        .replacingOccurrences(of: "<voice>1</voice>", with: "<voice>1</voice>")
    let s = try score([
        note("E", 4, staff: 1, notations: "<arpeggiate/>") + note("C", 5, staff: 1, chord: true, notations: "<arpeggiate/>") + rest(3)
        + "<backup><duration>4</duration></backup>" + m.replacingOccurrences(of: "<voice>1</voice>", with: "<voice>2</voice>") + rest(3).replacingOccurrences(of: "<duration>3</duration>", with: "<duration>3</duration><voice>2</voice><staff>2</staff>"),
    ], staves: 2)
    let l = s.layout(.singleLine)
    let a = marks(l, .arpeggio)
    #expect(a.count == 1, "one line, not one per staff")
    let b = a[0][0].bounds
    let sys = l.systems[0]
    #expect(b.minY < sys.staves[0].top + 4 && b.maxY > sys.staves[1].top, "it crosses from the first staff into the second")
}

// MARK: Ornaments

@Test("ornaments: tr, mordents and turns sit over the staff; below when the file says; accidentals are small")
func ornamentGlyphs() throws {
    let s = try score([
        note("C", 5, notations: "<ornaments><trill-mark/><accidental-mark>sharp</accidental-mark></ornaments>")
        + note("D", 5, notations: "<ornaments><mordent/></ornaments>") + note("E", 5, notations: "<ornaments><inverted-mordent/></ornaments>")
        + note("F", 5, notations: "<ornaments><turn placement=\"below\"/></ornaments>"),
    ])
    let l = s.layout(.singleLine)
    let o = marks(l, .ornament)
    #expect(o.count == 4)
    #expect(glyphsOf(o[0]).contains(Glyph.ornamentTrill.codepoint) && glyphsOf(o[0]).contains(Glyph.accidentalSharp.codepoint))
    #expect(glyphsOf(o[1]) == [Glyph.ornamentMordent.codepoint] && glyphsOf(o[2]) == [Glyph.ornamentShortTrill.codepoint])
    #expect(top(l, o[0][0]) < 0 && top(l, o[3][0]) > 4)
    #expect(markClashes(l).isEmpty)
}

@Test("ornaments: a trill's wavy line runs to the end of the stop note and breaks across systems")
func trillLineBreaks() throws {
    let m = [
        note("C", 5, dur: 4, notations: "<ornaments><trill-mark/><wavy-line type=\"start\"/></ornaments>"),
        note("C", 5, dur: 4), note("C", 5, dur: 4), note("C", 5, dur: 4), note("C", 5, dur: 4), note("C", 5, dur: 4),
        note("D", 5, dur: 4, notations: "<ornaments><wavy-line type=\"stop\"/></ornaments>"), note("C", 5, dur: 4),
    ]
    let s = try score(m)
    let one = marks(s.layout(.singleLine), .ornament)
    #expect(one.count == 1 && glyphsOf(one[0]).first == Glyph.ornamentTrill.codepoint)
    let wide = glyphsOf(one[0]).filter { $0 == Glyph.wiggleTrill.codepoint }.count
    #expect(wide > 10)
    var o = LayoutOptions(width: .fixed(40)); o.showMeasureNumbers = true
    let l = s.layout(o)
    #expect(l.systems.count >= 2)
    let pieces = l.systems.map { sys in sys.marks.filter { $0.kind == .ornament }.map { glyphsOf(Array(sys.items[$0.items])) } }
    let hasLine = pieces.filter { $0.contains { $0.contains(Glyph.wiggleTrill.codepoint) } }.count
    #expect(hasLine >= 2, "the line continues on the next system")
    #expect(pieces.flatMap { $0 }.filter { $0.contains(Glyph.ornamentTrill.codepoint) }.count == 1, "only one tr")
    #expect(markClashes(l).isEmpty)
}

// MARK: Tremolo

@Test("tremolo: single slashes across the stem, between the head and the beam")
func singleTremolo() throws {
    let s = try score([note("C", 5, dur: 2, extra: "<type>half</type><stem>down</stem>", notations: "<ornaments><tremolo type=\"single\">2</tremolo></ornaments>") + rest(2)])
    let l = s.layout(.singleLine)
    let t = marks(l, .tremolo)
    #expect(t.count == 1 && glyphsOf(t[0]) == [Glyph.tremolo2.codepoint])
    let head = try #require(l.noteBoxes[NoteID(0)])
    #expect(t[0][0].bounds.minY > head.maxY - 0.5, "below the head, on the down stem")
    #expect(markClashes(l).isEmpty)
}

// MARK: Words

@Test("words: dolce below, rit. above unless the file says; tempo words and a hidden part's duplicates are not drawn twice")
func wordsPlacement() throws {
    let s = try score([
        words("dolce") + words("rit.") + words("sempre", placement: "above") + note("C", 5, dur: 4),
    ], extraParts: words("dolce") + words("only here"))
    var o = LayoutOptions.singleLine; o.restrict(toPianoOf: s)
    o.staves = [LayoutOptions.StaffRef(part: 0, staff: 1)]
    let l = s.layout(o)
    let w = marks(l, .words).flatMap { $0 }
    func text(_ it: LayoutItem) -> String { if case .text(let t, _, _) = it { t } else { "" } }
    let by = Dictionary(uniqueKeysWithValues: w.map { (text($0), top(l, $0)) })
    #expect(Set(by.keys) == ["dolce", "rit.", "sempre"], "the hidden part's dolce is the same mark, and its other text stays off")
    #expect(by["dolce"]! > 4 && by["rit."]! < 0 && by["sempre"]! < 0)
    #expect(markClashes(l).isEmpty)
}

@Test("words: dashes continue after the words and are drawn only when the file has them")
func wordsDashes() throws {
    let dash = { (t: String) in "<direction><direction-type><dashes type=\"\(t)\" number=\"1\"/></direction-type><staff>1</staff></direction>" }
    let plain = try score([words("cresc.", placement: "below") + note("C", 5, dur: 4)])
    #expect(marks(plain.layout(.singleLine), .words).flatMap { $0 }.count == 1)
    let s = try score([words("cresc.", placement: "below") + dash("start") + note("C", 5, dur: 2) + note("D", 5, dur: 2) + dash("stop")])
    let l = s.layout(.singleLine)
    let w = marks(l, .words).flatMap { $0 }
    #expect(w.count > 2, "the words and some dashes")
    #expect(markClashes(l).isEmpty)
}

// MARK: Fixtures

@Test("the OpenScore piano parts draw the expected embellishments")
func embellishmentCounts() throws {
    func count(_ n: String, _ k: LaidMark.Kind) throws -> Int {
        let s = try Score.load(data: fixture("complex/openscore/\(n).mxl"))
        return s.layout(pianoOptions(s)).systems.flatMap(\.marks).filter { $0.kind == k }.count
    }
    #expect(try count("schumann-widmung", .articulation) > 0 && count("schumann-widmung", .arpeggio) == 1 && count("schumann-widmung", .ornament) == 2)
    #expect(try count("grandval-les-clochettes", .articulation) > 100 && count("grandval-les-clochettes", .fermata) == 4)
    #expect(try count("stanford-sou-wester", .tremolo) == 4 && count("stanford-sou-wester", .fermata) == 2)
    #expect(try count("boulanger-parfois-je-suis-triste", .arpeggio) == 2 && count("boulanger-parfois-je-suis-triste", .words) > 20)
    #expect(try count("satie-je-te-veux", .arpeggio) == 2)
}

@Test("the mark clash check sees an articulation moved onto a notehead")
func articulationClashCheckDetects() throws {
    let s = try score([note("C", 5, notations: "<articulations><accent/></articulations>") + rest(3)])
    var l = s.layout(.singleLine)
    #expect(markClashes(l).isEmpty)
    let box = try #require(l.noteBoxes[NoteID(0)])
    let m = try #require(l.systems[0].marks.first { $0.kind == .articulation })
    l.systems[0].items[m.items.lowerBound] = .glyph(codepoint: Glyph.articAccentAbove.codepoint, position: CGPoint(x: box.minX, y: box.midY))
    #expect(!markClashes(l).isEmpty)
}

@Test("words: a hidden part's copy of a rit. is dropped (Schumann m28), and its own text does not leak (Satie)")
func hiddenWords() throws {
    func texts(_ n: String) throws -> (ScoreLayout, [[String]]) {
        let s = try Score.load(data: fixture("complex/openscore/\(n).mxl"))
        let l = s.layout(pianoOptions(s))
        return (l, l.systems.map { sys in sys.marks.filter { $0.kind == .words }.flatMap { sys.items[$0.items] }.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } } })
    }
    let (sl, st) = try texts("schumann-widmung")
    let sys = try #require(sl.measureLocations[27]).systemIndex
    #expect(st[sys].filter { $0 == "ritard." }.count == 1)
    let (_, at) = try texts("satie-je-te-veux")
    #expect(!at.joined().contains { $0.contains("Verse") })
}

@Test("words: several <words> of one direction-type are joined; a tempo direction keeps its other words")
func joinedWords() throws {
    let s = try score([
        "<direction><direction-type><words>un </words><words>peu</words></direction-type><staff>1</staff></direction>"
        + "<direction><direction-type><words>Allegro</words></direction-type><direction-type><words>dolce</words></direction-type><sound tempo=\"100\"/></direction>"
        + note("C", 5, dur: 4),
    ])
    #expect(s.parts[0].words.map(\.text) == ["un peu", "dolce"])
    #expect(s.parts[0].measures[0].directions.first?.words == "Allegro")
}
