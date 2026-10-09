import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import ScoreKit

// S4c: ties, voltas, repeat marks, tempo marks, measure numbers, fingering and extents.

private let allLayoutFiles = [
    "twinkle-twinkle.musicxml", "ode-to-joy.musicxml", "minuet-in-g.musicxml", "bach-prelude-in-c.musicxml",
    "layout/voices-two.musicxml", "layout/compound-6-8.musicxml",
    "edge/key-signature.musicxml", "edge/chord.musicxml", "edge/measure-rest.musicxml", "edge/pickup.musicxml",
    "edge/tuplet.musicxml", "edge/two-part-piano.musicxml", "edge/grace.musicxml", "edge/voltas.musicxml",
    "edge/voice-piano.musicxml", "edge/tie-chain.musicxml", "edge/tie-cross-voice.musicxml", "edge/forward.musicxml",
    "edge/dc-al-fine.musicxml", "edge/tempo-change.musicxml", "edge/ending-multi-number.musicxml",
    "edge/ending-print-object-no.musicxml", "edge/ending-text-differs.musicxml", "edge/repeat-times-3.musicxml",
    "edge/metronome-half-note.musicxml",
]

private func load(_ name: String) throws -> Score { try Score.load(data: fixture(name)) }

private func mini(_ measures: [String], clef: String = "<sign>G</sign><line>2</line>", staves: Int? = nil,
                  time: (Int, Int) = (4, 4), divisions: Int = 1) throws -> Score {
    let body = measures.enumerated().map { i, m in
        "<measure number=\"\(i + 1)\">" + (i == 0 ? "<attributes><divisions>\(divisions)</divisions><key><fifths>0</fifths></key><time><beats>\(time.0)</beats><beat-type>\(time.1)</beat-type></time>\(staves.map { "<staves>\($0)</staves>" } ?? "")<clef number=\"1\">\(clef)</clef>\(staves == 2 ? "<clef number=\"2\"><sign>F</sign><line>4</line></clef>" : "")</attributes>" : "") + m + "</measure>"
    }.joined()
    let xml = "<?xml version=\"1.0\"?><score-partwise version=\"4.0\"><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\">\(body)</part></score-partwise>"
    return try Score.parse(xml: Data(xml.utf8))
}

private func note(_ step: String, _ oct: Int, _ type: String = "quarter", dur: Int = 1, voice: Int = 1, staff: Int? = nil, alter: Int? = nil, chord: Bool = false,
                  tie: String? = nil, extra: String = "", fingering: Int? = nil, fingerText: String? = nil,
                  placement: String? = nil) -> String {
    var notations = ""
    if let tie { notations += "<tied type=\"\(tie)\"/>" }
    if tie == "stop-start" { notations = "<tied type=\"stop\"/><tied type=\"start\"/>" }
    if let f = fingerText ?? fingering.map(String.init) {
        notations += "<technical><fingering\(placement.map { " placement=\"\($0)\"" } ?? "")>\(f)</fingering></technical>"
    }
    return "<note>\(chord ? "<chord/>" : "")<pitch><step>\(step)</step>\(alter.map { "<alter>\($0)</alter>" } ?? "")<octave>\(oct)</octave></pitch><duration>\(dur)</duration><voice>\(voice)</voice><type>\(type)</type>\(extra)\(staff.map { "<staff>\($0)</staff>" } ?? "")\(notations.isEmpty ? "" : "<notations>\(notations)</notations>")</note>"
}

private func inside(_ b: CGRect, _ f: CGRect, eps: Double = 1e-6) -> Bool {
    b.minX >= f.minX - eps && b.maxX <= f.maxX + eps && b.minY >= f.minY - eps && b.maxY <= f.maxY + eps
}

private func items(_ l: ScoreLayout) -> [LayoutItem] { l.systems.flatMap(\.items) }

private func ties(_ l: ScoreLayout) -> [(path: [PathElement], note: NoteID?, system: Int)] {
    l.systems.enumerated().flatMap { si, s in
        s.items.compactMap { item -> (path: [PathElement], note: NoteID?, system: Int)? in
            guard case .path(let els, nil, true, let n, _) = item else { return nil }
            return (els, n, si)
        }
    }
}

private func texts(_ l: ScoreLayout) -> [String] {
    items(l).compactMap { if case .text(let s, _, _) = $0 { s } else { nil } }
}

private func glyphCount(_ l: ScoreLayout, _ g: Glyph) -> Int {
    items(l).filter { if case .glyph(let cp, _, _, _, _) = $0 { cp == g.codepoint } else { false } }.count
}

// MARK: Extents

@Test("every item lies inside its system frame and the layout size", arguments: allLayoutFiles)
func extentsContainAllInk(file: String) throws {
    let score = try load(file)
    let widths: [LayoutOptions.Width] = [.fixed(40), .fixed(60), .fixed(80), .fixed(120), .singleLine]
    for fingering in [false, true] {
        for w in widths {
            let l = score.layout(LayoutOptions(width: w, showFingering: fingering))
            let eps = 1e-6
            for (si, sys) in l.systems.enumerated() {
                for item in sys.items {
                    let b = item.bounds
                    if b.isNull { continue }
                    #expect(inside(b, sys.frame), "\(file) \(w) system \(si): \(item) \(b) outside \(sys.frame)")
                    #expect(b.minX >= -eps && b.minY >= -eps && b.maxX <= l.size.width + eps && b.maxY <= l.size.height + eps,
                            "\(file) \(w): \(item) \(b) outside size \(l.size)")
                }
                if si > 0 { #expect(sys.frame.minY >= l.systems[si - 1].frame.maxY - eps, "\(file) frames overlap") }
            }
        }
    }
}

@Test("tall stems and beams widen the system")
func tallStemsGrowTheSystem() throws {
    // Upper-voice stems rise well above the staff.
    let s = try mini([note("A", 5, "half", dur: 2, voice: 1) + note("C", 6, "half", dur: 2, voice: 1)
                      + "<backup><duration>4</duration></backup>" + note("C", 4, "whole", dur: 4, voice: 2)])
    let l = s.layout(LayoutOptions(width: .fixed(60), showMeasureNumbers: false))
    let sys = l.systems[0]
    let topInk = sys.items.map { $0.bounds.minY }.min()!
    #expect(topInk >= sys.frame.minY - 1e-9)
    #expect(sys.staves[0].top - topInk > 4)
    #expect(topInk >= -1e-9)
}

// MARK: Ties

@Test("a tie for each tied pair, start id on the item, between the heads")
func tieChain() throws {
    let score = try load("edge/tie-chain.musicxml")
    let l = score.layout(LayoutOptions(width: .fixed(80)))
    let notes = score.parts[0].measures.flatMap(\.notes)
    let starts = notes.filter(\.drawnTieStart)
    let t = ties(l)
    #expect(t.count == starts.count)
    #expect(Set(t.compactMap(\.note)) == Set(starts.map(\.id)))
    for tie in t {
        let b = pathBounds(tie.path)
        let s = try #require(l.noteBoxes[tie.note!])
        #expect(b.minX >= s.maxX - 1e-9)
        // The end head is the next stop of the same pitch.
        let startNote = notes.first { $0.id == tie.note }!
        let end = notes.first { $0.id > startNote.id && $0.drawnTieStop && $0.pitch == startNote.pitch }!
        #expect(b.maxX <= l.noteBoxes[end.id]!.minX + 1e-9)
    }
}

@Test("ties across voices pair by pitch, abandoned ones become half ties")
func tieCrossVoice() throws {
    let score = try load("edge/tie-cross-voice.musicxml")
    let l = score.layout(LayoutOptions(width: .fixed(100)))
    let notes = score.parts[0].measures.flatMap(\.notes)
    let starts = notes.filter(\.drawnTieStart)
    #expect(ties(l).count == starts.count)
    // G4 (voice 1) ties to the G4 in voice 2 of the next bar.
    let g = notes.first { $0.drawnTieStart && $0.pitch?.step == .G }!
    let tie = try #require(ties(l).first { $0.note == g.id })
    let end = notes.first { $0.pitch?.step == .G && $0.pitch?.octave == 4 && $0.drawnTieStop }!
    #expect(pathBounds(tie.path).maxX <= l.noteBoxes[end.id]!.minX + 1e-9)
}

@Test("tie side: opposite the stem; chord outer notes outward, inner follow the stem rule")
func tieSides() throws {
    // C4 (stem up) and B5 (stem down), then the chord C4 E4 G4 (stem up) tied to the next bar.
    let s = try mini([
        note("C", 4, "half", dur: 2, tie: "start") + note("B", 5, "half", dur: 2, tie: "start"),
        note("C", 4, "half", dur: 2, tie: "stop") + note("B", 5, "half", dur: 2, tie: "stop"),
        note("C", 4, "whole", dur: 4, tie: "start") + note("E", 4, "whole", dur: 4, chord: true, tie: "start")
            + note("G", 4, "whole", dur: 4, chord: true, tie: "start"),
        note("C", 4, "whole", dur: 4, tie: "stop") + note("E", 4, "whole", dur: 4, chord: true, tie: "stop")
            + note("G", 4, "whole", dur: 4, chord: true, tie: "stop"),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(200), showMeasureNumbers: false))
    let notes = s.parts[0].measures.flatMap(\.notes)
    func side(_ n: Note) throws -> Double {
        let tie = try #require(ties(l).first { $0.note == n.id })
        let head = try #require(l.noteBoxes[n.id])
        let b = pathBounds(tie.path)
        return b.midY - head.midY   // positive: the tie is below its head
    }
    // First measure: low C4, stem up: tie below. High B5, stem down: tie above.
    #expect(try side(notes[0]) > 0)
    #expect(try side(notes[1]) < 0)
    // Chord: bottom note below, top above, the middle one opposite the (up) stem: below.
    #expect(try side(notes[4]) > 0)
    #expect(try side(notes[5]) > 0)
    #expect(try side(notes[6]) < 0)
}

@Test("two voices: ties go on the stem side, away from the other voice")
func tieTwoVoices() throws {
    let s = try mini([
        note("E", 5, "half", dur: 2, voice: 1, tie: "start") + note("E", 5, "half", dur: 2, voice: 1, tie: "stop")
        + "<backup><duration>4</duration></backup>"
        + note("C", 4, "half", dur: 2, voice: 2, tie: "start") + note("C", 4, "half", dur: 2, voice: 2, tie: "stop"),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    let notes = s.parts[0].measures.flatMap(\.notes)
    let up = try #require(ties(l).first { $0.note == notes[0].id })
    let down = try #require(ties(l).first { $0.note == notes[2].id })
    #expect(pathBounds(up.path).midY < l.noteBoxes[notes[0].id]!.midY)
    #expect(pathBounds(down.path).midY > l.noteBoxes[notes[2].id]!.midY)
}

@Test("a tie across a system break is an outgoing and an incoming half tie")
func tieAcrossSystems() throws {
    let s = try mini([
        note("C", 5, "whole", dur: 4, tie: "start"),
        note("C", 5, "whole", dur: 4, tie: "stop"),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(17), showMeasureNumbers: false))
    #expect(l.systems.count == 2)
    let notes = s.parts[0].measures.flatMap(\.notes)
    let t = ties(l)
    #expect(t.count == 2)
    #expect(t.allSatisfy { $0.note == notes[0].id })
    #expect(t[0].system == 0 && t[1].system == 1)
    let out = pathBounds(t[0].path), inc = pathBounds(t[1].path)
    let start = l.noteBoxes[notes[0].id]!, end = l.noteBoxes[notes[1].id]!
    #expect(out.minX >= start.maxX - 1e-9)
    #expect(out.maxX <= l.systems[0].frame.width)
    #expect(inc.maxX <= end.minX + 1e-9)
    #expect(inc.minX < end.minX - 1)
}

@Test("let-ring and unpaired starts draw a short half tie to the right")
func halfTies() throws {
    let s = try mini([
        note("C", 5, "half", dur: 2, tie: "let-ring") + note("E", 5, "half", dur: 2, tie: "start"),
        note("G", 4, "whole", dur: 4),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    let notes = s.parts[0].measures.flatMap(\.notes)
    let t = ties(l)
    #expect(t.count == 2)
    for tie in t {
        let b = pathBounds(tie.path)
        let head = l.noteBoxes[tie.note!]!
        #expect(b.minX >= head.maxX - 1e-9)
        #expect(b.width > 1 && b.width < 4.5)
    }
    _ = notes
}

@Test("a tie out of a closing repeat is a half tie, not a long tie across the repeat")
func tieIntoRepeat() throws {
    let s = try mini([
        note("C", 5, "whole", dur: 4, tie: "start") + "<barline location=\"right\"><bar-style>light-heavy</bar-style><repeat direction=\"backward\"/></barline>",
        note("C", 5, "whole", dur: 4, tie: "stop"),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    let t = ties(l)
    // The outgoing half tie, and an incoming half tie on the target.
    #expect(t.count == 2)
    let notes = s.parts[0].measures.flatMap(\.notes)
    let out = try #require(t.first { $0.note == notes[0].id })
    #expect(pathBounds(out.path).maxX < l.noteBoxes[notes[1].id]!.minX - 1)
    #expect(l.tiedFrom.isEmpty)
}

// MARK: Voltas

private func horizontalBrackets(_ l: ScoreLayout) -> [(system: Int, x1: Double, x2: Double, y: Double)] {
    l.systems.enumerated().flatMap { si, s in
        s.items.compactMap { item -> (Int, Double, Double, Double)? in
            guard case .line(let a, let b, let t, nil, nil) = item, t == EngravingDefaults.repeatEndingLineThickness,
                  a.y == b.y, b.x - a.x > 3, a.y < s.staves[0].top else { return nil }
            return (si, a.x, b.x, a.y)
        }
    }
}

@Test("volta brackets span their measures and carry their labels")
func voltaSpansAndLabels() throws {
    let score = try load("edge/voltas.musicxml")
    let l = score.layout(LayoutOptions(width: .fixed(120)))
    #expect(texts(l).filter { $0 == "1." }.count == 1)
    #expect(texts(l).filter { $0 == "2." }.count == 1)
    let br = horizontalBrackets(l)
    #expect(br.count == 2)
    let sys = l.systems[0]
    let m1 = sys.measures.first { $0.index == 4 }, m2 = sys.measures.first { $0.index == 5 }
    // The first volta covers its measure (from its left edge to its closing barline).
    if let m1, let m2 {
        let first = br.sorted { $0.x1 < $1.x1 }
        #expect(abs(first[0].x1 - m1.x0) < 0.5)
        #expect(abs(first[0].x2 - m1.barX) < 1.0)
        #expect(abs(first[1].x1 - m2.x0) < 0.5)
    }
    // Numbers fall back to "1." / "1, 2.".
    let multi = try load("edge/ending-multi-number.musicxml").layout(LayoutOptions(width: .fixed(120)))
    #expect(texts(multi).contains("1., 2."))
}

@Test("a volta without text is labelled from its numbers")
func voltaNumberFallback() throws {
    let s = try mini([
        note("C", 5, "whole", dur: 4),
        "<barline location=\"left\"><ending number=\"1, 2\" type=\"start\"/></barline>" + note("D", 5, "whole", dur: 4)
            + "<barline location=\"right\"><ending number=\"1, 2\" type=\"stop\"/></barline>",
        "<barline location=\"left\"><ending number=\"3\" type=\"start\"/></barline>" + note("E", 5, "whole", dur: 4)
            + "<barline location=\"right\"><ending number=\"3\" type=\"discontinue\"/></barline>",
    ])
    let l = s.layout(LayoutOptions(width: .fixed(120), showMeasureNumbers: false))
    #expect(texts(l).contains("1, 2."))
    #expect(texts(l).contains("3."))
}

@Test("print-object=no draws no volta")
func voltaPrintObjectNo() throws {
    let l = try load("edge/ending-print-object-no.musicxml").layout(LayoutOptions(width: .fixed(120)))
    #expect(horizontalBrackets(l).isEmpty)
    #expect(!texts(l).contains("1.") && !texts(l).contains("2."))
}

@Test("a volta bracket continues on the next system without its label")
func voltaBreaksAcrossSystems() throws {
    func m(_ s: String, _ extra: String = "") -> String { note(s, 5, "whole", dur: 4) + extra }
    let s = try mini([
        m("C"),
        "<barline location=\"left\"><ending number=\"1\" type=\"start\"/></barline>" + m("D"),
        m("E"),
        m("F", "<barline location=\"right\"><ending number=\"1\" type=\"stop\"/><repeat direction=\"backward\"/></barline>"),
        m("G"),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(27), showMeasureNumbers: false))
    #expect(l.systems.count >= 2)
    let br = horizontalBrackets(l)
    #expect(Set(br.map(\.system)).count >= 2)
    #expect(texts(l).filter { $0 == "1." }.count == 1)
    // Only the closing end has a hook: vertical strokes at the bracket ends, count them.
    let hooks = items(l).filter { item in
        if case .line(let a, let b, let t, nil, nil) = item { return t == EngravingDefaults.repeatEndingLineThickness && a.x == b.x && abs(b.y - a.y - 1.5) < 1e-9 }
        return false
    }
    #expect(hooks.count == 2)   // the left hook where it starts, the right one where it ends
}

// MARK: Repeat marks and tempo

@Test("segno, coda, fine and D.C. marks are drawn")
func jumpMarkGlyphsAndWords() throws {
    let dc = try load("edge/dc-al-fine.musicxml").layout(LayoutOptions(width: .fixed(100)))
    #expect(texts(dc).contains("Fine"))
    #expect(texts(dc).contains("D.C. al Fine"))
    let s = try mini([
        "<direction placement=\"above\"><direction-type><segno/></direction-type><sound segno=\"s1\"/></direction>" + note("C", 5, "whole", dur: 4),
        note("D", 5, "whole", dur: 4) + "<direction placement=\"above\"><direction-type><words>To Coda</words></direction-type><sound tocoda=\"c1\"/></direction>",
        note("E", 5, "whole", dur: 4) + "<direction placement=\"above\"><direction-type><words>D.S. al Coda</words></direction-type><sound dalsegno=\"s1\"/></direction>",
        "<direction placement=\"above\"><direction-type><coda/></direction-type><sound coda=\"c1\"/></direction>" + note("F", 5, "whole", dur: 4),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(140), showMeasureNumbers: false))
    #expect(glyphCount(l, .segno) == 1)   // the sound attribute and the direction type are one mark
    #expect(glyphCount(l, .coda) == 2)    // To Coda's symbol and the coda itself
    #expect(texts(l).contains("To Coda"))
    #expect(texts(l).contains("D.S. al Coda"))
    // Marks stay clear of the staff.
    for sys in l.systems {
        for item in sys.items {
            if case .glyph(let cp, _, _, _, _) = item, cp == Glyph.segno.codepoint || cp == Glyph.coda.codepoint {
                #expect(item.bounds.maxY < sys.staves[0].top)
            }
        }
    }
}

@Test("tempo marks: metronome glyph and text, words, dotted units")
func tempoMarks() throws {
    let tc = try load("edge/tempo-change.musicxml").layout(LayoutOptions(width: .fixed(100)))
    #expect(texts(tc).contains("= 120"))
    #expect(texts(tc).contains("= 90"))
    #expect(glyphCount(tc, .metNoteQuarterUp) == 2)
    let s = try mini([
        "<direction placement=\"above\"><direction-type><words>Allegro</words></direction-type><direction-type><metronome><beat-unit>half</beat-unit><beat-unit-dot/><per-minute>72</per-minute></metronome></direction-type><sound tempo=\"216\"/></direction>"
            + note("C", 5, "whole", dur: 4),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    #expect(texts(l).contains("Allegro"))
    #expect(texts(l).contains("= 72"))
    #expect(glyphCount(l, .metNoteHalfUp) == 1)
    #expect(glyphCount(l, .metAugmentationDot) == 1)
    // Above the first staff, at the first note's x.
    let sys = l.systems[0]
    let mark = sys.items.first { if case .glyph(let cp, _, _, _, _) = $0 { cp == Glyph.metNoteHalfUp.codepoint } else { false } }!
    #expect(mark.bounds.maxY < sys.staves[0].top)
}

@Test("measure numbers open each system but the first and fit the frame")
func measureNumbers() throws {
    let score = try load("minuet-in-g.musicxml")
    let l = score.layout(LayoutOptions(width: .fixed(60)))
    #expect(l.systems.count > 2)
    for (i, sys) in l.systems.enumerated() {
        let numbers = sys.items.compactMap { item -> (String, CGRect)? in
            if case .text(let s, _, let st) = item, st.italic { return (s, item.bounds) } else { return nil }
        }
        if i == 0 { #expect(numbers.isEmpty) }
        else {
            #expect(numbers.count == 1)
            #expect(numbers[0].0 == "\(sys.measureRange.lowerBound + 1)")
            #expect(inside(numbers[0].1, sys.frame))
            #expect(numbers[0].1.maxY <= sys.staves[0].top)
        }
    }
    let off = score.layout(LayoutOptions(width: .fixed(60), showMeasureNumbers: false))
    #expect(!off.systems.flatMap(\.items).contains { if case .text(_, _, let st) = $0 { st.italic } else { false } })
}

// MARK: Fingering

private func fingeringBoxes(_ l: ScoreLayout) -> [(sys: Int, box: CGRect, note: NoteID?)] {
    let digits = [Glyph.fingering0, .fingering1, .fingering2, .fingering3, .fingering4, .fingering5].map(\.codepoint)
    return l.systems.enumerated().flatMap { si, s in
        s.items.compactMap { item -> (Int, CGRect, NoteID?)? in
            guard case .glyph(let cp, _, _, let n, _) = item, digits.contains(cp) else { return nil }
            return (si, item.bounds, n)
        }
    }
}

private func stemAndBeamBoxes(_ l: ScoreLayout, system: Int) -> [CGRect] {
    l.systems[system].items.compactMap { item in
        switch item {
        case .line(_, _, let t, nil, let g) where g != nil && t == EngravingDefaults.stemThickness: item.bounds
        case .beam: item.bounds
        default: nil
        }
    }
}

@Test("fingering never overlaps stems or beams", arguments: ["ode-to-joy.musicxml", "twinkle-twinkle.musicxml", "minuet-in-g.musicxml", "bach-prelude-in-c.musicxml"])
func fingeringClearsStemsAndBeams(file: String) throws {
    var score = try load(file)
    // Finger every note so there is plenty to collide.
    for pi in score.parts.indices { for mi in score.parts[pi].measures.indices { for ni in score.parts[pi].measures[mi].notes.indices {
        score.parts[pi].measures[mi].notes[ni].fingering = String(1 + (ni % 5))
    } } }
    for w in [LayoutOptions.Width.fixed(60), .fixed(100)] {
        let l = score.layout(LayoutOptions(width: w, showFingering: true))
        let f = fingeringBoxes(l)
        #expect(!f.isEmpty)
        for fb in f {
            for other in stemAndBeamBoxes(l, system: fb.sys) {
                #expect(!fb.box.intersects(other), "\(file): fingering \(fb.box) hits \(other)")
            }
        }
    }
}

@Test("fingering with two voices goes outside, past the stem tips")
func fingeringTwoVoices() throws {
    let s = try mini([
        note("E", 5, "eighth", dur: 1, voice: 1, fingering: 3) + note("G", 5, "eighth", dur: 1, voice: 1, fingering: 5)
        + note("A", 5, "half", dur: 2, voice: 1, fingering: 4)
        + "<backup><duration>4</duration></backup>"
        + note("C", 4, "half", dur: 2, voice: 2, fingering: 1) + note("E", 4, "half", dur: 2, voice: 2, fingering: 2),
    ], divisions: 2)
    let l = s.layout(LayoutOptions(width: .fixed(80), showFingering: true, showMeasureNumbers: false))
    let sys = l.systems[0]
    let top = sys.staves[0].top
    let boxes = fingeringBoxes(l)
    #expect(boxes.count == 5)
    for fb in boxes {
        #expect(fb.box.maxY < top || fb.box.minY > top + 4)   // outside the staff
        for other in stemAndBeamBoxes(l, system: 0) { #expect(!fb.box.intersects(other)) }
    }
}

@Test("a fully fingered chord gets stacked digits, one per note")
func fingeringChordStack() throws {
    let s = try mini([
        note("C", 4, "half", dur: 2, fingering: 1) + note("E", 4, "half", dur: 2, chord: true, fingering: 3)
            + note("G", 4, "half", dur: 2, chord: true, fingering: 5)
            + note("D", 4, "half", dur: 2, fingering: 2) + note("F", 4, "half", dur: 2, chord: true)
            + note("A", 4, "half", dur: 2, chord: true, fingering: 4),
    ], divisions: 1)
    let l = s.layout(LayoutOptions(width: .fixed(80), showFingering: true, showMeasureNumbers: false))
    let boxes = fingeringBoxes(l)
    let notes = s.parts[0].measures[0].notes
    // First chord: three digits in one column, in pitch order (below the chord: highest first).
    let first = boxes.filter { b in notes[0...2].contains { $0.id == b.note } }
    #expect(first.count == 3)
    #expect(Set(first.map { ($0.box.midX * 1000).rounded() }).count == 1)
    let byY = first.sorted { $0.box.minY < $1.box.minY }.map(\.note)
    #expect(byY == [notes[2].id, notes[1].id, notes[0].id])
    // Second chord is partly fingered: its two fingered notes are stacked all the same.
    let second = boxes.filter { b in notes[3...5].contains { $0.id == b.note } }
    #expect(second.count == 2)
    #expect(Set(second.map { ($0.box.midX * 1000).rounded() }).count == 1)
}


// MARK: Review round

@Test("ties pair per staff: a C4 tie in each hand, the left hand starting earlier")
func tiesBothHands() throws {
    let s = try mini([
        note("C", 4, "half", dur: 4, staff: 1) + note("C", 4, "half", dur: 4, staff: 1, tie: "start")
            + "<backup><duration>8</duration></backup>"
            + note("C", 4, "quarter", dur: 2, voice: 5, staff: 2) + note("C", 4, "half", dur: 4, voice: 5, staff: 2, tie: "start")
            + note("C", 4, "quarter", dur: 2, voice: 5, staff: 2),
        note("C", 4, "whole", dur: 8, staff: 1, tie: "stop") + "<backup><duration>8</duration></backup>"
            + note("C", 4, "whole", dur: 8, voice: 5, staff: 2, tie: "stop"),
    ], staves: 2, divisions: 2)
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    let notes = s.parts[0].measures.flatMap(\.notes)
    let rhStart = notes[1], lhStart = notes[3], rhStop = notes[5], lhStop = notes[6]
    #expect(l.tiedFrom[rhStop.id] == rhStart.id)
    #expect(l.tiedFrom[lhStop.id] == lhStart.id)
    let t = ties(l)
    #expect(t.count == 2)
    for (start, stop) in [(rhStart, rhStop), (lhStart, lhStop)] {
        let tie = try #require(t.first { $0.note == start.id })
        let b = pathBounds(tie.path)
        #expect(b.minX >= l.noteBoxes[start.id]!.maxX - 1e-9)
        #expect(b.maxX <= l.noteBoxes[stop.id]!.minX + 1e-9)
        #expect(abs(b.midY - l.noteBoxes[start.id]!.midY) < 2)
    }
}

@Test("an enharmonic tie pairs by MIDI number")
func tieEnharmonic() throws {
    let s = try mini([note("C", 5, "half", dur: 2) + note("C", 5, "half", dur: 2, alter: 1, tie: "start"),
                      note("D", 5, "whole", dur: 4, alter: -1, tie: "stop")])
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    #expect(ties(l).count == 1)
    #expect(l.tiedFrom.count == 1)
}

@Test("a stop whose start was dropped (into ending 2) gets an incoming half tie")
func tieIntoEnding2() throws {
    let s = try mini([
        note("G", 4, "half", dur: 2) + note("G", 4, "half", dur: 2, tie: "start"),
        "<barline location=\"left\"><ending number=\"1\" type=\"start\"/></barline>" + note("G", 4, "whole", dur: 4, tie: "stop")
            + "<barline location=\"right\"><ending number=\"1\" type=\"stop\"/><repeat direction=\"backward\"/></barline>",
        "<barline location=\"left\"><ending number=\"2\" type=\"start\"/></barline>" + note("G", 4, "whole", dur: 4, tie: "stop")
            + "<barline location=\"right\"><ending number=\"2\" type=\"stop\"/></barline>",
    ])
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    let notes = s.parts[0].measures.flatMap(\.notes)
    let t = ties(l)
    #expect(t.count == 2)
    let incoming = try #require(t.first { $0.note == notes[3].id })
    let b = pathBounds(incoming.path)
    let head = l.noteBoxes[notes[3].id]!
    #expect(b.maxX <= head.minX + 1e-9)
    #expect(b.width > 1 && b.width < 3)
    #expect(l.tiedFrom[notes[3].id] == nil)
}

@Test("a tie ends before the accidental of its target")
func tieStopsBeforeAccidental() throws {
    let s = try mini([note("C", 5, "half", dur: 2) + note("C", 5, "half", dur: 2, tie: "start"),
                      note("C", 5, "whole", dur: 4, tie: "stop", extra: "<accidental>natural</accidental>")])
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    let notes = s.parts[0].measures.flatMap(\.notes)
    let tie = try #require(ties(l).first)
    let acc = try #require(items(l).first { if case .glyph(let cp, _, _, let n, _) = $0 { cp == Glyph.accidentalNatural.codepoint && n == notes[2].id } else { false } })
    #expect(pathBounds(tie.path).maxX <= acc.bounds.minX + 1e-9)
}

@Test("inner chord ties are flat, split by the middle line and clear of each other")
func innerChordTies() throws {
    let s = try mini([
        note("C", 4, "half", dur: 2) + note("C", 4, "half", dur: 2, tie: "start") + note("E", 4, "half", dur: 2, chord: true, tie: "start")
            + note("G", 4, "half", dur: 2, chord: true, tie: "start") + note("C", 5, "half", dur: 2, chord: true, tie: "start"),
        note("C", 4, "whole", dur: 4, tie: "stop") + note("E", 4, "whole", dur: 4, chord: true, tie: "stop")
            + note("G", 4, "whole", dur: 4, chord: true, tie: "stop") + note("C", 5, "whole", dur: 4, chord: true, tie: "stop"),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    let t = ties(l)
    #expect(t.count == 4)
    let boxes = t.map { pathBounds($0.path) }
    for i in boxes.indices {
        for j in boxes.indices where j > i { #expect(!boxes[i].intersects(boxes[j]), "ties \(i) and \(j) overlap") }
        for h in l.noteBoxes.values { #expect(!boxes[i].intersects(h)) }
    }
    // Inner ties (E4, G4) are flat; the chord splits by position: C4 and E4 curve down, G4 and C5 up.
    let notes = s.parts[0].measures.flatMap(\.notes)
    for (id, down) in [(notes[2].id, true), (notes[3].id, false)] {
        let b = pathBounds(try #require(t.first { $0.note == id }).path)
        #expect(b.height < 0.7)
        #expect(down ? b.midY > l.noteBoxes[id]!.midY : b.midY < l.noteBoxes[id]!.midY)
    }
}

@Test("a very short gap still gets a tie")
func tinyTie() throws {
    let s = try mini([note("C", 5, "quarter", dur: 1, tie: "start") + note("C", 5, "quarter", dur: 1, tie: "stop")
                      + note("D", 5, "half", dur: 2)], divisions: 1)
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    #expect(ties(l).count == 1)
}

@Test(":| followed by |: shares one heavy line; other lines before |: are replaced by it")
func repeatBarCombos() throws {
    func heavy(_ l: ScoreLayout) -> Int { l.systems[0].items.filter { if case .rect = $0 { true } else { false } }.count }
    func dots(_ l: ScoreLayout) -> Int { glyphCount(l, .repeatDot) }
    let back = "<barline location=\"right\"><bar-style>light-heavy</bar-style><repeat direction=\"backward\"/></barline>"
    let fwd = "<barline location=\"left\"><bar-style>heavy-light</bar-style><repeat direction=\"forward\"/></barline>"
    let shared = try mini([note("C", 5, "whole", dur: 4) + back, fwd + note("D", 5, "whole", dur: 4)])
        .layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    #expect(dots(shared) == 4)
    #expect(heavy(shared) == 2)   // the shared line and the final line
    let afterFinal = try mini([note("C", 5, "whole", dur: 4) + "<barline location=\"right\"><bar-style>light-heavy</bar-style></barline>",
                               fwd + note("D", 5, "whole", dur: 4)])
        .layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    #expect(dots(afterFinal) == 2)
    #expect(heavy(afterFinal) == 2)   // the repeat start's and the final line
    let double = try mini([note("C", 5, "whole", dur: 4) + "<barline location=\"right\"><bar-style>light-light</bar-style></barline>",
                           fwd + note("D", 5, "whole", dur: 4)])
        .layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    #expect(heavy(double) == 2)
}

@Test("left barline styles and an explicit regular last bar", arguments: ["heavy-light", "heavy-heavy", "dashed", "dotted", "tick", "short", "regular"])
func barStyles(style: String) throws {
    let s = try mini([note("C", 5, "whole", dur: 4),
                      "<barline location=\"left\"><bar-style>\(style)</bar-style></barline>" + note("D", 5, "whole", dur: 4)
                      + "<barline location=\"right\"><bar-style>regular</bar-style></barline>"])
    let l = s.layout(LayoutOptions(width: .fixed(100), showMeasureNumbers: false))
    let rects = l.systems[0].items.filter { if case .rect = $0 { true } else { false } }.count
    // The last bar is explicitly regular: no heavy final line.
    switch style {
    case "heavy-light": #expect(rects == 1)
    case "heavy-heavy": #expect(rects == 2)
    default: #expect(rects == 0)
    }
    #expect(l.size.width == 100)
}

@Test("fixed width holds with long tempo and jump texts", arguments: [60.0, 200.0])
func fixedWidthHolds(width: Double) throws {
    let tempo = "<direction placement=\"above\"><direction-type><words>Allegro con brio ma non troppo e molto espressivo</words></direction-type><direction-type><metronome><beat-unit>quarter</beat-unit><beat-unit-dot/><per-minute>132</per-minute></metronome></direction-type><sound tempo=\"198\"/></direction>"
    let dc = "<direction><direction-type><words>D.C. al Fine</words></direction-type><sound dacapo=\"yes\"/></direction>"
    let fine = "<direction><direction-type><words>Fine</words></direction-type><sound fine=\"yes\"/></direction>"
    let whole = note("C", 5, "whole", dur: 4)
    let s = try mini([whole, whole, tempo + whole + fine + dc, tempo + whole])
    let l = s.layout(LayoutOptions(width: .fixed(width)))
    #expect(Double(l.size.width) == width)
    for sys in l.systems { #expect(Double(sys.frame.width) == width) }
}

@Test("fixed-width layouts have the target width unless one measure is wider", arguments: allLayoutFiles)
func fixedWidthIsTarget(file: String) throws {
    let score = try load(file)
    for w in [60.0, 80.0, 120.0] {
        let l = score.layout(LayoutOptions(width: .fixed(w)))
        let wide = l.systems.contains { $0.measureRange.count == 1 && $0.frame.width > w }
        #expect(wide || Double(l.size.width) == w, "\(file) at \(w): \(l.size.width)")
    }
}

@Test("fingering: full strings, hyphens, and an explicit placement")
func fingeringStringsAndPlacement() throws {
    let s = try mini([note("C", 5, "half", dur: 2, fingerText: "12") + note("D", 5, "half", dur: 2, fingerText: "3-4")], divisions: 1)
    let l = s.layout(LayoutOptions(width: .fixed(80), showFingering: true, showMeasureNumbers: false))
    #expect(fingeringBoxes(l).count == 4)
    let dashes = items(l).filter { if case .line(_, _, let t, let n, nil) = $0 { t == 0.1 && n != nil } else { false } }
    #expect(dashes.count == 1)
    // C5 has its stem down: digits above by default. placement="below" puts them under the staff.
    let b = try mini([note("C", 5, "whole", dur: 4, fingering: 2, placement: "below")])
        .layout(LayoutOptions(width: .fixed(80), showFingering: true, showMeasureNumbers: false))
    let top = b.systems[0].staves[0].top
    #expect(fingeringBoxes(b).allSatisfy { $0.box.minY > top + 4 })
    let a = try mini([note("C", 4, "quarter", dur: 1, fingering: 1, placement: "above") + note("D", 4, "half", dur: 3)])
        .layout(LayoutOptions(width: .fixed(80), showFingering: true, showMeasureNumbers: false))
    #expect(fingeringBoxes(a).allSatisfy { $0.box.maxY < a.systems[0].staves[0].top })
}

@Test("fingering keeps clear of tuplet numbers and brackets")
func fingeringAndTuplet() throws {
    func trip(_ i: Int) -> String {
        let tm = "<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>"
        let mark = i == 0 ? "<tuplet type=\"start\" bracket=\"yes\" placement=\"above\"/>" : i == 2 ? "<tuplet type=\"stop\"/>" : ""
        let beam = "<beam number=\"1\">\(i == 0 ? "begin" : i == 2 ? "end" : "continue")</beam>"
        return "<note><pitch><step>E</step><octave>5</octave></pitch><duration>2</duration><voice>1</voice><type>eighth</type>\(tm)\(beam)<notations>\(mark)<technical><fingering>\(i + 1)</fingering></technical></notations></note>"
    }
    let xml = (0..<3).map(trip).joined() + note("E", 5, "half", dur: 6) + note("E", 5, "quarter", dur: 2)
    let s = try mini([xml], divisions: 4)
    let l = s.layout(LayoutOptions(width: .fixed(80), showFingering: true, showMeasureNumbers: false))
    let tup = Set((0...9).map { Glyph.tupletDigit($0).codepoint })
    let others = items(l).compactMap { it -> CGRect? in
        switch it {
        case .glyph(let cp, _, _, nil, nil) where tup.contains(cp): it.bounds
        case .line(_, _, let t, nil, nil) where t == EngravingDefaults.tupletBracketThickness: it.bounds
        default: nil
        }
    }
    #expect(!others.isEmpty)
    for f in fingeringBoxes(l) { for o in others { #expect(!f.box.intersects(o)) } }
}

@Test("segno and coda of one measure sit side by side")
func marksSideBySide() throws {
    let s = try mini([
        "<direction><direction-type><segno/></direction-type></direction><direction><direction-type><coda/></direction-type></direction>"
            + note("C", 5, "whole", dur: 4),
    ])
    let l = s.layout(LayoutOptions(width: .fixed(80), showMeasureNumbers: false))
    let marks = items(l).filter { if case .glyph(let cp, _, _, _, _) = $0 { cp == Glyph.segno.codepoint || cp == Glyph.coda.codepoint } else { false } }
    #expect(marks.count == 2)
    #expect(!marks[0].bounds.intersects(marks[1].bounds))
    // Side by side: their heights overlap.
    #expect(marks[0].bounds.minY < marks[1].bounds.maxY && marks[1].bounds.minY < marks[0].bounds.maxY)
}
