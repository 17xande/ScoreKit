import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import ScoreKit

private let layoutFiles = [
    "twinkle-twinkle.musicxml", "ode-to-joy.musicxml", "minuet-in-g.musicxml", "bach-prelude-in-c.musicxml",
    "edge/key-signature.musicxml", "edge/chord.musicxml", "edge/measure-rest.musicxml", "edge/pickup.musicxml",
    "edge/tuplet.musicxml", "edge/two-part-piano.musicxml", "edge/grace.musicxml", "edge/voltas.musicxml",
    "edge/voice-piano.musicxml", "edge/tie-chain.musicxml", "edge/forward.musicxml",
]

private func loadScore(_ name: String) throws -> Score { try Score.load(data: fixture(name)) }

/// A one-part score from measure bodies (attributes + notes).
private func miniScore(clef: String = "<sign>G</sign><line>2</line>", fifths: Int = 0, notes: String,
                       staves: Int? = nil, measure2: String? = nil) throws -> Score {
    let xml = """
    <?xml version="1.0"?><score-partwise version="4.0"><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
    <part id="P1"><measure number="1"><attributes><divisions>1</divisions><key><fifths>\(fifths)</fifths></key>
    <time><beats>4</beats><beat-type>4</beat-type></time>\(staves.map { "<staves>\($0)</staves>" } ?? "")<clef><sign>G</sign><line>2</line></clef>
    </attributes>\(notes)</measure>\(measure2.map { "<measure number=\"2\">\($0)</measure>" } ?? "")</part></score-partwise>
    """.replacingOccurrences(of: "<clef><sign>G</sign><line>2</line></clef>", with: "<clef>\(clef)</clef>")
    return try Score.parse(xml: Data(xml.utf8))
}

private func pitch(_ step: String, _ octave: Int, alter: Int = 0, type: String = "quarter", dur: Int = 1, extra: String = "") -> String {
    "<note><pitch><step>\(step)</step>\(alter != 0 ? "<alter>\(alter)</alter>" : "")<octave>\(octave)</octave></pitch><duration>\(dur)</duration><type>\(type)</type>\(extra)</note>"
}

private func close(_ a: [Double], _ b: [Double]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }
}

private func staffTop(_ layout: ScoreLayout, system: Int = 0, staff: Int = 0) -> Double {
    layout.systems[system].staves[staff].top
}

private func glyphs(_ sys: LaidSystem, _ list: [Glyph]) -> [(Glyph, CGPoint, NoteID?)] {
    sys.items.compactMap { item in
        guard case .glyph(let cp, let p, _, let id, _) = item, let g = Glyph(rawValue: cp), list.contains(g) else { return nil }
        return (g, p, id)
    }
}

private func maxX(_ item: LayoutItem) -> Double {
    switch item {
    case .glyph(let cp, let p, let size, _, _): Double(Glyph(rawValue: cp)?.metrics.box(at: p, size: size).maxX ?? p.x)
    case .line(let a, let b, let t, _, _): max(a.x, b.x) + t / 2
    case .rect(let r, _, _): r.maxX
    case .text(_, let p, _): p.x
    case .path(let els, _, _, _, _):
        els.map { e -> Double in
            switch e {
            case .move(let p), .line(let p): p.x
            case .quad(let to, _), .curve(let to, _, _): to.x
            case .close: 0
            }
        }.max() ?? 0
    }
}

// MARK: Invariants over the fixtures

@Test("every drawn pitched note has a notehead box", arguments: layoutFiles)
func everyNoteHasBox(file: String) throws {
    let score = try loadScore(file)
    let layout = score.layout(LayoutOptions(width: .fixed(80)))
    for part in score.parts {
        for note in part.measures.flatMap(\.notes) where note.pitch != nil && note.printObject {
            let box = try #require(layout.noteBoxes[note.id], "note \(note.id.value) in \(file)")
            #expect(box.width > 0 && box.height > 0)
        }
    }
}

@Test("columns increase within a measure, and each measure is in one system", arguments: layoutFiles)
func columnsIncrease(file: String) throws {
    let layout = try loadScore(file).layout(LayoutOptions(width: .fixed(70)))
    for sys in layout.systems {
        for (m, cols) in Dictionary(grouping: sys.columns, by: \.measureIndex) {
            #expect(sys.measureRange.contains(m))
            #expect(cols.map(\.x) == cols.map(\.x).sorted())
            #expect(Set(cols.map(\.x)).count == cols.count, "distinct x in measure \(m) of \(file)")
            #expect(cols.map(\.onset) == cols.map(\.onset).sorted())
        }
        // Columns run left to right across measures too.
        #expect(sys.columnXs == sys.columnXs.sorted())
    }
}

@Test("systems fit the width and cover every measure once, in order", arguments: layoutFiles, [40.0, 60.0, 120.0])
func systemsFitAndCover(file: String, width: Double) throws {
    let score = try loadScore(file)
    let layout = score.layout(LayoutOptions(width: .fixed(width)))
    let total = score.parts.map(\.measures.count).max()!
    var next = 0
    for sys in layout.systems {
        #expect(sys.measureRange.lowerBound == next)
        #expect(!sys.measureRange.isEmpty)
        next = sys.measureRange.upperBound
        // A single measure wider than the page is allowed to overflow; otherwise nothing may.
        if sys.measureRange.count > 1 {
            #expect(sys.frame.width <= width + 1e-9)
            let right = sys.items.map(maxX).max() ?? 0
            #expect(right <= width + 1e-6, "system \(sys.measureRange) of \(file) reaches \(right) > \(width)")
        }
    }
    #expect(next == total)
    #expect(layout.systems.allSatisfy { $0.measureRange.count == 1 } || layout.size.width <= width + 1e-9)
}

@Test("justified systems fill the width, the last one stays natural")
func justification() throws {
    let layout = try loadScore("ode-to-joy.musicxml").layout(LayoutOptions(width: .fixed(80)))
    #expect(layout.systems.count > 1)
    for sys in layout.systems.dropLast() {
        let right = sys.items.compactMap { item -> Double? in
            if case .line(let a, let b, let t, _, _) = item, a.x == b.x, a.y != b.y { return a.x + t / 2 }
            if case .rect(let r, _, _) = item { return r.maxX }
            return nil
        }.max()!
        #expect(abs(right - (80 - rightMargin)) < 0.05, "right edge \(right)")
    }
    let last = layout.systems.last!
    let lastRight = last.items.map(maxX).max()!
    #expect(lastRight < 80 - rightMargin - 1)
}

@Test("single line gives one system holding every measure", arguments: layoutFiles)
func singleLine(file: String) throws {
    let score = try loadScore(file)
    let layout = score.layout(.singleLine)
    #expect(layout.systems.count == 1)
    #expect(layout.systems[0].measureRange == 0..<score.parts.map(\.measures.count).max()!)
    #expect(layout.size.width >= layout.systems[0].items.map(maxX).max()!)
}

@Test("staff selection: one staff, one part, grand staff gets a brace")
func selection() throws {
    let score = try loadScore("minuet-in-g.musicxml")
    let both = score.layout(LayoutOptions(width: .fixed(90)))
    #expect(both.systems[0].staves.count == 2)
    #expect(!glyphs(both.systems[0], [.brace]).isEmpty)
    let one = score.layout(LayoutOptions(width: .fixed(90), staves: [.init(part: 0, staff: 1)]))
    #expect(one.systems[0].staves.map(\.staffInPart) == [1])
    #expect(glyphs(one.systems[0], [.brace]).isEmpty)
    // Only the selected staff's notes are boxed.
    let staff2 = Set(score.parts[0].measures.flatMap(\.notes).filter { $0.staff == 2 && $0.pitch != nil }.map(\.id))
    #expect(staff2.isDisjoint(with: Set(one.noteBoxes.keys)))
    // Staves of different parts are separated by the part distance at least.
    let two = try loadScore("edge/two-part-piano.musicxml").layout(LayoutOptions(width: .fixed(80)))
    let tops = two.systems[0].staves.map(\.top)
    #expect(tops.count == 2 && tops[1] - tops[0] >= 4 + 8)
}

// MARK: Staff positions

@Test("staff positions per clef")
func staffPositions() {
    let treble = Clef(sign: "G", line: 2, octaveChange: 0)
    let bass = Clef(sign: "F", line: 4, octaveChange: 0)
    let alto = Clef(sign: "C", line: 3, octaveChange: 0)
    let tenor = Clef(sign: "C", line: 4, octaveChange: 0)
    let vb = Clef(sign: "G", line: 2, octaveChange: -1)
    #expect(StaffGeometry.position(.G, 4, clef: treble) == 2)   // second line
    #expect(StaffGeometry.position(.E, 4, clef: treble) == 0)   // bottom line
    #expect(StaffGeometry.position(.F, 5, clef: treble) == 8)   // top line
    #expect(StaffGeometry.position(.C, 4, clef: treble) == -2)  // first ledger line below
    #expect(StaffGeometry.position(.F, 3, clef: bass) == 6)     // fourth line
    #expect(StaffGeometry.position(.G, 2, clef: bass) == 0)
    #expect(StaffGeometry.position(.C, 4, clef: bass) == 10)    // first ledger line above
    #expect(StaffGeometry.position(.C, 4, clef: alto) == 4)     // middle line
    #expect(StaffGeometry.position(.C, 4, clef: tenor) == 6)
    #expect(StaffGeometry.position(.G, 3, clef: vb) == 2)
    #expect(StaffGeometry.ledgerPositions(-2) == [-2])
    #expect(StaffGeometry.ledgerPositions(-1) == [])
    #expect(StaffGeometry.ledgerPositions(-3) == [-2])
    #expect(StaffGeometry.ledgerPositions(-4) == [-2, -4])
    #expect(StaffGeometry.ledgerPositions(9) == [])
    #expect(StaffGeometry.ledgerPositions(12) == [10, 12])
}

@Test("noteheads sit on the right staff line in the layout")
func noteheadsOnLines() throws {
    let treble = try miniScore(notes: pitch("G", 4) + pitch("E", 4) + pitch("C", 4) + pitch("B", 4) + pitch("F", 5, type: "half", dur: 2))
    let l = treble.layout(.singleLine)
    let top = staffTop(l)
    let ys = treble.parts[0].measures[0].notes.map { l.noteBoxes[$0.id]!.midY - top }
    #expect(close(ys, [3, 4, 5, 2, 0]))  // G4 line 2, E4 bottom line, C4 ledger, B4 middle, F5 top
    // C4 gets one ledger line, on the same y as the notehead centre.
    let c4 = treble.parts[0].measures[0].notes[2]
    let ledgers = l.systems[0].items.filter { if case .line(let a, let b, _, _, let g) = $0 { a.y == b.y && g == l.notes[c4.id]!.groupID } else { false } }
    #expect(ledgers.count == 1)
    if case .line(let a, _, _, _, _) = ledgers[0] { #expect(a.y - top == 5) }

    let bass = try miniScore(clef: "<sign>F</sign><line>4</line>", notes: pitch("F", 3) + pitch("G", 2) + pitch("C", 4))
    let lb = bass.layout(.singleLine)
    let tb = staffTop(lb)
    let yb = bass.parts[0].measures[0].notes.map { lb.noteBoxes[$0.id]!.midY - tb }
    #expect(close(yb, [1, 4, -1]))  // F3 fourth line, G2 bottom line, C4 first ledger above
}

@Test("rests are centred, measure rests are centred in the measure, dots go in spaces")
func restsAndDots() throws {
    let s = try miniScore(notes: "<note><rest/><duration>2</duration><type>half</type></note>"
                          + "<note><rest/><duration>1</duration><type>quarter</type></note>"
                          + pitch("G", 4, type: "quarter", extra: "<dot/>"))
    let l = s.layout(.singleLine)
    let top = staffTop(l)
    let rests = glyphs(l.systems[0], [.restHalf, .restQuarter])
    #expect(rests.count == 2)
    #expect(close(rests.map { $0.1.y - top }, [2, 2]))
    // G4 sits on a line (position 2), so its dot moves up into the space above it.
    let dots = glyphs(l.systems[0], [.augmentationDot])
    #expect(dots.count == 1)
    #expect(abs(dots[0].1.y - top - 2.5) < 1e-9)

    let m = try loadScore("edge/measure-rest.musicxml")
    let lm = m.layout(.singleLine)
    let measureRests = glyphs(lm.systems[0], [.restWhole])
    #expect(measureRests.count == 1)
    #expect(abs(measureRests[0].1.y - staffTop(lm) - 1) < 1e-9)  // hangs from the fourth line
    let sys = lm.systems[0]
    let bars = sys.items.compactMap { item -> Double? in
        if case .line(let a, let b, _, _, _) = item, a.x == b.x, a.y != b.y { return a.x }
        return nil
    }.sorted()
    // The rest sits between the barlines around measure 2.
    let x = measureRests[0].1.x + Glyph.restWhole.metrics.advance / 2
    let left = bars.last { $0 < x }!, right = bars.first { $0 > x }!
    #expect(abs((x - left) - (right - x)) < 1.0)
}

// MARK: Accidentals

private func accidentalGlyphs(_ layout: ScoreLayout, notes: [Note]) -> [[Glyph]] {
    let acc: [Glyph] = [.accidentalSharp, .accidentalFlat, .accidentalNatural, .accidentalDoubleSharp, .accidentalDoubleFlat]
    return notes.map { n in glyphs(layout.systems[0], acc).filter { $0.2 == n.id }.map(\.0) }
}

@Test("key-signature fixture: written accidentals are drawn, carried ones are not")
func accidentalsWritten() throws {
    let score = try loadScore("edge/key-signature.musicxml")
    let notes = Array(score.parts[0].measures[0].notes)
    let result = accidentalGlyphs(score.layout(.singleLine), notes: notes)
    #expect(result[0] == [])                       // B flat is in the key (Bb major has Bb, Eb)
    #expect(result[1] == [.accidentalNatural])     // B natural
    #expect(result[2] == [.accidentalSharp])       // F sharp
    #expect(result[3] == [])                       // carried F sharp
}

@Test("key-signature fixture: the same accidentals are computed when the file has none")
func accidentalsComputed() throws {
    var score = try loadScore("edge/key-signature.musicxml")
    for mi in score.parts[0].measures.indices {
        for ni in score.parts[0].measures[mi].notes.indices { score.parts[0].measures[mi].notes[ni].accidental = nil }
    }
    let m1 = Array(score.parts[0].measures[0].notes)
    let result = accidentalGlyphs(score.layout(.singleLine), notes: m1)
    #expect(result[0] == [])
    #expect(result[1] == [.accidentalNatural])
    #expect(result[2] == [.accidentalSharp])
    #expect(result[3] == [])
    // A new measure forgets the carried accidental: F natural in the next measure needs nothing
    // (F is natural in the key), but a sharp again would need one.
    let barrier = try miniScore(fifths: -2, notes:
        pitch("F", 4, alter: 1) + pitch("F", 4, alter: 1) + pitch("F", 5, alter: 1) + pitch("F", 4, alter: 0))
    let b = Array(barrier.parts[0].measures[0].notes)
    let r = accidentalGlyphs(barrier.layout(.singleLine), notes: b)
    #expect(r == [[.accidentalSharp], [], [.accidentalSharp], [.accidentalNatural]])  // octaves are separate
}

@Test("accidental in parentheses when marked")
func accidentalMarks() throws {
    let s = try miniScore(notes:
        pitch("F", 4, alter: 1, extra: "<accidental parentheses=\"yes\">sharp</accidental>"))
    let l = s.layout(.singleLine)
    let n0 = s.parts[0].measures[0].notes[0]
    let parens = glyphs(l.systems[0], [.accidentalParensLeft, .accidentalParensRight]).filter { $0.2 == n0.id }
    #expect(parens.count == 2)
    #expect(glyphs(l.systems[0], [.accidentalSharp]).filter { $0.2 == n0.id }.count == 1)
}

@Test("a tie into the next bar prints no accidental, and leaves the bar's state alone (Gould)")
func tieAcrossBar() throws {
    let tieStart = "<tie type=\"start\"/><notations><tied type=\"start\"/></notations>"
    let tieStop = "<tie type=\"stop\"/><notations><tied type=\"stop\"/></notations>"
    let s = try miniScore(notes: pitch("C", 4, type: "half", dur: 3, extra: "<dot/>") + pitch("F", 4, alter: 1, extra: tieStart),
                          measure2: pitch("F", 4, alter: 1, extra: tieStop) + pitch("F", 4, alter: 1) + pitch("F", 4, type: "half", dur: 2))
    let l = s.layout(.singleLine)
    let m1 = s.parts[0].measures[0].notes, m2 = s.parts[0].measures[1].notes
    let r1 = accidentalGlyphs(l, notes: m1)
    #expect(r1[1] == [.accidentalSharp])               // the tie's first note shows its sharp
    let r2 = accidentalGlyphs(l, notes: m2)
    #expect(r2[0] == [])                               // tied over the barline: nothing
    #expect(r2[1] == [.accidentalSharp])               // the next F sharp in the bar reprints it
    #expect(r2[2] == [.accidentalNatural])
}

@Test("accidentals follow time across voices, not document order")
func accidentalsAcrossVoices() throws {
    func v(_ n: String, _ o: Int, alter: Int = 0, type: String = "quarter", dur: Int = 1, voice: Int) -> String {
        pitch(n, o, alter: alter, type: type, dur: dur, extra: "<voice>\(voice)</voice>")
    }
    let body = v("A", 4, voice: 1) + v("A", 4, voice: 1) + v("F", 4, alter: 1, type: "half", dur: 2, voice: 1)
        + "<backup><duration>4</duration></backup>"
        + "<note><rest/><duration>1</duration><voice>2</voice><type>quarter</type></note>"
        + v("F", 4, alter: 1, voice: 2) + v("D", 4, type: "half", dur: 2, voice: 2)
    let s = try miniScore(notes: body)
    let l = s.layout(.singleLine)
    let n = s.parts[0].measures[0].notes
    #expect(accidentalGlyphs(l, notes: [n[4]]) == [[.accidentalSharp]])   // voice 2, beat 2: first in time
    #expect(accidentalGlyphs(l, notes: [n[2]]) == [[]])                   // voice 1, beat 3: carried
}

@Test("chords group by onset and voice, not document adjacency")
func chordGrouping() throws {
    let body = pitch("C", 5, extra: "<voice>1</voice>")
        + "<backup><duration>1</duration></backup>"
        + "<note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><voice>2</voice><type>quarter</type></note>"
        + "<note><chord/><pitch><step>G</step><octave>5</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>"
    let s = try miniScore(notes: body)
    let l = s.layout(.singleLine)
    let n = s.parts[0].measures[0].notes
    #expect(n.count == 3)
    #expect(l.groups[n[0].id]?.sorted() == [n[0].id, n[2].id].sorted())
    #expect(l.notes[n[2].id]?.groupID == n[0].id)
    #expect(l.notes[n[1].id]?.groupID == n[1].id)
}

@Test("chord with a hidden first tone still forms one group")
func hiddenLead() throws {
    let s = try miniScore(notes: "<note print-object=\"no\"><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>"
        + "<note><chord/><pitch><step>E</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>"
        + "<note><chord/><pitch><step>G</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>")
    let l = s.layout(.singleLine)
    let n = s.parts[0].measures[0].notes
    #expect(l.noteBoxes[n[0].id] == nil)
    #expect(l.notes[n[1].id]?.groupID == n[1].id && l.notes[n[2].id]?.groupID == n[1].id)
}

@Test("dotted chord: a line note's dot goes below when the space above has a dot")
func dottedChord() throws {
    let s = try miniScore(notes: pitch("B", 4, type: "half", dur: 3, extra: "<dot/>")
                          + "<note><chord/><pitch><step>C</step><octave>5</octave></pitch><duration>3</duration><type>half</type><dot/></note>")
    let l = s.layout(.singleLine)
    let top = staffTop(l)
    let dots = glyphs(l.systems[0], [.augmentationDot])
    #expect(dots.count == 2)
    // C5 (space, p5) dots at y 1.5; B4 (line, p4) can't use p5 and drops to p3: y 2.5.
    #expect(close(dots.map { $0.1.y - top }.sorted(), [1.5, 2.5]))
    #expect(Set(dots.compactMap { $0.2 }).count == 2)   // each dot belongs to its own note
}

@Test("a mid-measure key change applies from its onset")
func midMeasureKey() throws {
    let xml = """
    <?xml version="1.0"?><score-partwise version="4.0"><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
    <part id="P1"><measure number="1"><attributes><divisions>1</divisions><key><fifths>0</fifths></key>
    <time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
    \(pitch("F", 4)) \(pitch("F", 4, alter: 1))
    <attributes><key><fifths>1</fifths></key></attributes>
    \(pitch("F", 4, alter: 1)) \(pitch("F", 4))</measure></part></score-partwise>
    """
    let s = try Score.parse(xml: Data(xml.utf8))
    let l = s.layout(.singleLine)
    let n = s.parts[0].measures[0].notes
    let r = accidentalGlyphs(l, notes: n)
    #expect(r == [[], [.accidentalSharp], [], [.accidentalNatural]])
    let sig = glyphs(l.systems[0], [.accidentalSharp]).filter { $0.2 == nil }
    #expect(sig.count == 1)
    #expect(sig[0].1.x > l.noteBoxes[n[1].id]!.maxX && sig[0].1.x < l.noteBoxes[n[2].id]!.minX)
}

@Test("a measure wider than the page overflows and the layout reports the real width")
func measureOverflow() throws {
    var body = ""
    for _ in 0..<64 { body += pitch("F", 4, alter: 1, type: "64th", dur: 1) + pitch("F", 4, type: "64th", dur: 1) }
    let xml = """
    <?xml version="1.0"?><score-partwise version="4.0"><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
    <part id="P1"><measure number="1"><attributes><divisions>32</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>\(body)</measure></part></score-partwise>
    """
    let l = try Score.parse(xml: Data(xml.utf8)).layout(LayoutOptions(width: .fixed(40)))
    #expect(l.systems.count == 1)
    let right = l.systems[0].items.map(maxX).max()!
    #expect(right > 40)
    #expect(l.size.width >= right)
    #expect(l.systems[0].frame.width >= right)
}

@Test("sparse measures: the gap before the first note does not stretch")
func sparseJustify() throws {
    var ms = ""
    for i in 0..<8 { ms += "<measure number=\"\(i + 2)\">" + pitch("C", 5, type: "whole", dur: 4) + "</measure>" }
    let xml = """
    <?xml version="1.0"?><score-partwise version="4.0"><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
    <part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>\(pitch("C", 5, type: "whole", dur: 4))</measure>\(ms)</part></score-partwise>
    """
    let l = try Score.parse(xml: Data(xml.utf8)).layout(LayoutOptions(width: .fixed(60)))
    #expect(l.systems.count > 1)
    let leads = l.systems.flatMap(\.measures).map { $0.columns[0].x - $0.bodyStart }
    #expect(Set(leads.map { ($0 * 1000).rounded() }).count == 1)
}

// MARK: Measure geometry and notes

@Test("x(measureIndex:position:) interpolates between columns and measure bounds")
func positionToX() throws {
    let l = try loadScore("ode-to-joy.musicxml").layout(LayoutOptions(width: .fixed(80)))
    #expect(l.systems.count > 2)
    for (si, sys) in l.systems.enumerated() {
        for m in sys.measures {
            #expect(m.x0 <= m.bodyStart && m.bodyStart < m.barX)
            #expect(m.columns.allSatisfy { $0.x > m.bodyStart && $0.x < m.barX })
            let first = m.columns[0]
            let r0 = try #require(l.x(measureIndex: m.index, position: first.onset))
            #expect(r0.systemIndex == si && abs(r0.x - first.x) < 1e-9)
            let end = try #require(l.x(measureIndex: m.index, position: m.duration))
            #expect(abs(end.x - m.barX) < 1e-9)
            // Halfway between two columns.
            let a = m.columns[0], b = m.columns[1]
            let mid = try #require(l.x(measureIndex: m.index, position: Rational(1, 1) * (a.onset + b.onset) / Rational(2)))
            #expect(abs(mid.x - (a.x + b.x) / 2) < 1e-9)
            // Positions before the first column or past the end clamp or interpolate within bounds.
            let before = try #require(l.x(measureIndex: m.index, position: .zero))
            #expect(before.x >= m.bodyStart - 1e-9 && before.x <= first.x + 1e-9)
        }
    }
    #expect(l.x(measureIndex: 99, position: .zero) == nil)
    // A selection that hides nothing still lays out every measure.
    let last = try #require(l.x(measureIndex: 15, position: .zero))
    #expect(last.systemIndex == l.systems.count - 1)
}

@Test("LaidNote records system, staff, group and stem end; group items carry the group id")
func laidNotes() throws {
    let s = try miniScore(notes: pitch("C", 4) + pitch("E", 4, extra: "")
        + "<note><rest/><duration>1</duration><type>quarter</type></note>" + pitch("G", 4, type: "whole", dur: 4))
    let l = s.layout(.singleLine)
    let n = s.parts[0].measures[0].notes
    let c = try #require(l.notes[n[0].id])
    #expect(c.systemIndex == 0 && c.staffIndex == 0 && c.groupID == n[0].id && !c.isRest)
    let end = try #require(c.stemEnd)
    #expect(end.y < c.headBox.minY || end.y > c.headBox.maxY)
    #expect(try #require(l.notes[n[2].id]).isRest)
    #expect(l.noteBoxes[n[2].id] == nil)
    #expect(l.notes[n[3].id]?.stemEnd == nil)     // whole note: no stem
    let items = l.systems[0].items
    // The stem belongs to the group, the head to the note.
    let stems = items.filter { if case .line(_, _, _, nil, let g) = $0 { g == n[0].id } else { false } }
    #expect(stems.count >= 1)
    #expect(items.contains { if case .glyph(_, _, _, let id, nil) = $0 { id == n[0].id } else { false } })
    #expect(l.groups[n[0].id] == [n[0].id])
}
// MARK: Key signatures

@Test("key signature glyphs: count and positions")
func keySignatures() throws {
    func sigs(_ score: Score) -> [(Glyph, Double)] {
        let l = score.layout(.singleLine)
        let top = staffTop(l)
        let first = score.parts[0].measures[0].notes.compactMap { l.noteBoxes[$0.id]?.minX }.min()!
        return glyphs(l.systems[0], [.accidentalSharp, .accidentalFlat]).filter { $0.2 == nil && $0.1.x < first }
            .sorted { $0.1.x < $1.1.x }.map { ($0.0, $0.1.y - top) }
    }
    let one = sigs(try miniScore(fifths: 1, notes: pitch("C", 5)))
    #expect(one.map(\.0) == [.accidentalSharp])
    #expect(close(one.map(\.1), [0]))                       // F sharp on the top line
    let flats = sigs(try miniScore(fifths: -2, notes: pitch("C", 5)))
    #expect(flats.map(\.0) == [.accidentalFlat, .accidentalFlat])
    #expect(close(flats.map(\.1), [2, 0.5]))                // B flat middle line, E flat top space
    let seven = sigs(try miniScore(fifths: 7, notes: pitch("C", 5)))
    #expect(close(seven.map(\.1), [0, 1.5, -0.5, 1, 2.5, 0.5, 2]))
    let bass = sigs(try miniScore(clef: "<sign>F</sign><line>4</line>", fifths: 1, notes: pitch("C", 3)))
    #expect(close(bass.map(\.1), [1]))                      // F sharp on the fourth line
    let bassFlats = sigs(try miniScore(clef: "<sign>F</sign><line>4</line>", fifths: -2, notes: pitch("C", 3)))
    #expect(close(bassFlats.map(\.1), [3, 1.5]))            // B flat second line, E flat third space
    let alto = Clef(sign: "C", line: 3, octaveChange: 0), tenor = Clef(sign: "C", line: 4, octaveChange: 0)
    #expect(StaffGeometry.keySignaturePositions(sharps: true, count: 7, clef: alto) == [7, 4, 8, 5, 2, 6, 3])
    #expect(StaffGeometry.keySignaturePositions(sharps: false, count: 7, clef: alto) == [3, 6, 2, 5, 1, 4, 0])
    #expect(StaffGeometry.keySignaturePositions(sharps: true, count: 7, clef: tenor) == [2, 6, 3, 7, 4, 8, 5])
    #expect(StaffGeometry.keySignaturePositions(sharps: false, count: 7, clef: tenor) == [5, 8, 4, 7, 3, 6, 2])
    #expect(StaffGeometry.keySignaturePositions(sharps: false, count: 7, clef: Clef(sign: "F", line: 4, octaveChange: 0)) == [2, 5, 1, 4, 0, 3, 6])
    // Octave-shifted clefs keep the base clef's pattern; other clefs stay within the staff window.
    #expect(StaffGeometry.keySignaturePositions(sharps: true, count: 7, clef: Clef(sign: "G", line: 2, octaveChange: -1)) == [8, 5, 9, 6, 3, 7, 4])
    for (sign, line) in [("C", 1), ("C", 2), ("F", 3), ("G", 1), ("F", 5), ("C", 5)] {
        for sharps in [true, false] {
            let ps = StaffGeometry.keySignaturePositions(sharps: sharps, count: 7, clef: Clef(sign: sign, line: line, octaveChange: 0))
            #expect(ps.count == 7 && ps.allSatisfy { $0 >= 0 && $0 <= 9 }, "\(sign)\(line) \(sharps): \(ps)")
        }
    }
    let none = sigs(try miniScore(fifths: 0, notes: pitch("C", 5)))
    #expect(none.isEmpty)
}

@Test("key and time changes at a measure start get furniture; time signatures draw digits")
func furniture() throws {
    let xml = """
    <?xml version="1.0"?><score-partwise version="4.0"><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
    <part id="P1"><measure number="1"><attributes><divisions>1</divisions><key><fifths>2</fifths></key>
    <time><beats>3</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
    \(pitch("D", 5, type: "half", dur: 3, extra: "<dot/>"))</measure>
    <measure number="2"><attributes><key><fifths>0</fifths></key><time symbol="cut"><beats>2</beats><beat-type>2</beat-type></time></attributes>
    \(pitch("C", 5, type: "half", dur: 2))</measure></part></score-partwise>
    """
    let s = try Score.parse(xml: Data(xml.utf8))
    let l = s.layout(.singleLine)
    let sys = l.systems[0]
    // Measure 1: 3/4 digits. Measure 2: cut time, and two naturals cancelling the two sharps.
    #expect(glyphs(sys, [.timeSig3]).count == 1 && glyphs(sys, [.timeSig4]).count == 1)
    #expect(glyphs(sys, [.timeSigCutCommon]).count == 1)
    #expect(glyphs(sys, [.accidentalNatural]).count == 2)
    #expect(glyphs(sys, [.accidentalSharp]).count == 2)
    #expect(glyphs(sys, [.gClef]).count == 1)
}

@Test("clef changes: mid-measure takes a column, positions follow the new clef")
func clefChange() throws {
    let xml = """
    <?xml version="1.0"?><score-partwise version="4.0"><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
    <part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time>
    <clef><sign>G</sign><line>2</line></clef></attributes>
    \(pitch("G", 4, type: "half", dur: 2))
    <attributes><clef><sign>F</sign><line>4</line></clef></attributes>
    \(pitch("F", 3, type: "half", dur: 2))</measure></part></score-partwise>
    """
    let s = try Score.parse(xml: Data(xml.utf8))
    let l = s.layout(.singleLine)
    let notes = s.parts[0].measures[0].notes
    let top = staffTop(l)
    #expect(abs(l.noteBoxes[notes[0].id]!.midY - top - 3) < 1e-6)
    #expect(abs(l.noteBoxes[notes[1].id]!.midY - top - 1) < 1e-6)
    #expect(glyphs(l.systems[0], [.gClef]).count == 1 && glyphs(l.systems[0], [.fClef]).count == 1)
    #expect(l.systems[0].columns.count == 2)
}

@Test("barlines: final is light-heavy, repeats have dots")
func barlines() throws {
    let l = try loadScore("minuet-in-g.musicxml").layout(.singleLine)
    let sys = l.systems[0]
    #expect(glyphs(sys, [.repeatDot]).count == 8)   // forward and backward repeat, 2 dots on each of 2 staves
    let heavy = sys.items.filter { if case .rect = $0 { true } else { false } }
    #expect(heavy.count >= 2)
    let tune = try loadScore("twinkle-twinkle.musicxml").layout(.singleLine)
    let heavies = tune.systems[0].items.filter { if case .rect = $0 { true } else { false } }
    #expect(heavies.count == 1)   // only the final barline is heavy
}

@Test("note-owned items carry the NoteID; fingering is optional")
func noteIDsAndFingering() throws {
    let score = try loadScore("ode-to-joy.musicxml")
    let plain = score.layout(.singleLine)
    let fingered = score.layout(LayoutOptions(width: .singleLine, showFingering: true))
    func fingeringCount(_ l: ScoreLayout) -> Int {
        glyphs(l.systems[0], [.fingering0, .fingering1, .fingering2, .fingering3, .fingering4, .fingering5]).count
    }
    #expect(fingeringCount(plain) == 0)
    #expect(fingeringCount(fingered) > 0)
    #expect(glyphs(fingered.systems[0], [.noteheadBlack, .noteheadHalf, .noteheadWhole]).allSatisfy { $0.2 != nil })
}

@Test("glyph metrics: SMuFL values")
func glyphMetrics() {
    let h = Glyph.noteheadBlack.metrics
    #expect(h.maxX == 1.18 && h.minY == -0.5 && h.maxY == 0.5)
    #expect(h.anchors["stemUpSE"] == CGPoint(x: 1.18, y: 0.168))
    #expect(Glyph.gClef.rawValue == 0xE050 && Glyph.fClef.rawValue == 0xE062)
    #expect(EngravingDefaults.staffLineThickness == 0.13)
    let box = h.box(at: CGPoint(x: 10, y: 20))
    #expect(box == CGRect(x: 10, y: 19.5, width: 1.18, height: 1))
}

@Test("every glyph in the table has metrics")
func allGlyphsHaveMetrics() {
    for g in Glyph.allCases {
        let m = g.metrics
        #expect(m.maxX >= m.minX && m.maxY >= m.minY && m.advance > 0, "\(g)")
    }
}
