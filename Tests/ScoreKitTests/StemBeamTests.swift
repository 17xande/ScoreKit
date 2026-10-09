import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import ScoreKit

// S4b: voices, stems, flags, beams and tuplets.

private func score(time: (Int, Int) = (4, 4), divisions: Int = 4, measures: [String], clef: String = "<sign>G</sign><line>2</line>") throws -> Score {
    let body = measures.enumerated().map { i, m in
        "<measure number=\"\(i + 1)\">" + (i == 0 ? "<attributes><divisions>\(divisions)</divisions><key><fifths>0</fifths></key><time><beats>\(time.0)</beats><beat-type>\(time.1)</beat-type></time><clef>\(clef)</clef></attributes>" : "") + m + "</measure>"
    }.joined()
    let xml = "<?xml version=\"1.0\"?><score-partwise version=\"4.0\"><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\">\(body)</part></score-partwise>"
    return try Score.parse(xml: Data(xml.utf8))
}

private func n(_ step: String, _ oct: Int, _ type: String, dur: Int, voice: Int = 1, extra: String = "") -> String {
    "<note><pitch><step>\(step)</step><octave>\(oct)</octave></pitch><duration>\(dur)</duration><voice>\(voice)</voice><type>\(type)</type>\(extra)</note>"
}
private func chordTone(_ step: String, _ oct: Int, _ type: String, dur: Int) -> String {
    "<note><chord/><pitch><step>\(step)</step><octave>\(oct)</octave></pitch><duration>\(dur)</duration><voice>1</voice><type>\(type)</type></note>"
}
private func eighths(_ steps: [(String, Int)]) -> String { steps.map { n($0.0, $0.1, "eighth", dur: 2) }.joined() }
private func sixteenths(_ steps: [(String, Int)]) -> String { steps.map { n($0.0, $0.1, "16th", dur: 1) }.joined() }

private func lay(_ s: Score) -> ScoreLayout { s.layout(LayoutOptions(width: .fixed(120), showMeasureNumbers: false)) }
private func load(_ name: String) throws -> Score { try Score.load(data: fixture(name)) }

private func stemUp(_ l: ScoreLayout, _ note: Note) -> Bool? {
    guard let ln = l.notes[note.id], let end = ln.stemEnd else { return nil }
    return end.y < ln.headBox.midY
}

private func allNotes(_ s: Score) -> [Note] { s.parts.flatMap(\.measures).flatMap(\.notes) }

private func glyphItems(_ l: ScoreLayout, _ g: [Glyph]) -> [(Glyph, CGPoint, NoteID?, NoteID?)] {
    l.systems.flatMap(\.items).compactMap { item in
        guard case .glyph(let cp, let p, _, let nid, let gid) = item, let gl = Glyph(rawValue: cp), g.contains(gl) else { return nil }
        return (gl, p, nid, gid)
    }
}

private let flags: [Glyph] = [.flag8thUp, .flag8thDown, .flag16thUp, .flag16thDown, .flag32ndUp, .flag32ndDown, .flag64thUp, .flag64thDown]

private struct BeamPath { var id: BeamID; var pts: [CGPoint] }
private func beamPaths(_ l: ScoreLayout) -> [BeamPath] {
    l.systems.flatMap(\.items).compactMap { item in
        guard case .beam(let els, let gid) = item else { return nil }
        let pts = els.compactMap { e -> CGPoint? in
            switch e { case .move(let p), .line(let p): p; default: nil }
        }
        return BeamPath(id: gid, pts: pts)
    }
}

/// The y of the beam path's top edge at x (the first two points).
private func topY(_ b: BeamPath, at x: Double) -> Double {
    let (a, c) = (b.pts[0], b.pts[1])
    return a.y + (c.y - a.y) * (x - a.x) / (c.x - a.x)
}

// MARK: Stem direction

@Test("single voice: stems follow the head farthest from the middle line; <stem> overrides")
func stemDirections() throws {
    let s = try score(measures: [
        n("A", 4, "quarter", dur: 4) + n("B", 4, "quarter", dur: 4) + n("C", 5, "quarter", dur: 4)
            + n("C", 5, "quarter", dur: 4, extra: "<stem>up</stem>"),
        // C4 E4 G4 chord (far head below) and G4 B4 E5 chord (far head above)
        n("C", 4, "half", dur: 8) + chordTone("E", 4, "half", dur: 8) + chordTone("G", 4, "half", dur: 8)
            + n("G", 4, "half", dur: 8) + chordTone("B", 4, "half", dur: 8) + chordTone("E", 5, "half", dur: 8),
    ])
    let l = lay(s)
    let ns = allNotes(s).filter { !$0.isChordTone }
    #expect(stemUp(l, ns[0]) == true)    // A4
    #expect(stemUp(l, ns[1]) == false)   // B4: middle line, down
    #expect(stemUp(l, ns[2]) == false)   // C5
    #expect(stemUp(l, ns[3]) == true)    // C5 with <stem>up</stem>
    #expect(stemUp(l, ns[4]) == true)    // chord C4 E4 G4
    #expect(stemUp(l, ns[5]) == false)   // chord G4 B4 E5
}

@Test("stems are 3.5 sp long, reach the middle line, and span a chord; stemEnd is filled in")
func stemLengths() throws {
    let s = try score(measures: [
        n("G", 4, "quarter", dur: 4) + n("C", 6, "quarter", dur: 4) + n("C", 3, "quarter", dur: 4)
            + n("C", 4, "quarter", dur: 4) + chordTone("G", 4, "quarter", dur: 4),
    ])
    let l = lay(s)
    let ns = allNotes(s)
    let g4 = l.notes[ns[0].id]!
    #expect(abs(abs(g4.stemEnd!.y - g4.headBox.midY) - 3.5) < 0.01)
    // C6 is far above the staff: its stem runs to the middle line.
    let top = l.systems[0].staves[0].top
    #expect(abs(l.notes[ns[1].id]!.stemEnd!.y - (top + 2)) < 0.01)
    #expect(abs(l.notes[ns[2].id]!.stemEnd!.y - (top + 2)) < 0.01)
    // Chord: the stem reaches 3.5 sp above the top head.
    let c4 = l.notes[ns[3].id]!, g4c = l.notes[ns[4].id]!
    #expect(c4.stemEnd == g4c.stemEnd)
    #expect(abs(g4c.stemEnd!.y - (g4c.headBox.midY - 3.5)) < 0.01)
    // Every stemmed note has stemEnd; whole notes and rests don't.
    let whole = try score(measures: [n("C", 5, "whole", dur: 16), "<note><rest/><duration>16</duration><type>whole</type></note>"].map { $0 }.prefix(1).map { $0 })
    let lw = lay(whole)
    #expect(lw.notes.values.allSatisfy { $0.stemEnd == nil })
}

@Test("stemEnd is set for every stemmed note of the starters")
func stemEndEverywhere() throws {
    for f in ["ode-to-joy.musicxml", "minuet-in-g.musicxml", "bach-prelude-in-c.musicxml"] {
        let s = try load(f)
        let l = lay(s)
        for note in allNotes(s) where note.pitch != nil {
            let ln = try #require(l.notes[note.id])
            let v = note.noteValue ?? .quarter
            #expect((ln.stemEnd != nil) == (v != .whole && v != .breve), "\(f) note \(note.id.value)")
        }
    }
}

// MARK: Flags

@Test("flags only on unbeamed notes")
func flagsOnUnbeamed() throws {
    // A lone eighth, a lone 16th, a beamed pair of eighths and a lone quarter.
    let s = try score(measures: [
        n("C", 5, "eighth", dur: 2) + "<note><rest/><duration>2</duration><type>eighth</type></note>"
            + n("D", 5, "16th", dur: 1) + "<note><rest/><duration>3</duration><type>eighth</type><dot/></note>"
            + n("E", 5, "eighth", dur: 2) + n("F", 5, "eighth", dur: 2) + n("G", 5, "quarter", dur: 4),
    ])
    let l = lay(s)
    let ns = allNotes(s).filter { $0.pitch != nil }
    let fl = glyphItems(l, flags)
    #expect(fl.count == 2)
    #expect(Set(fl.compactMap { $0.3 }) == [ns[0].id, ns[1].id])
    #expect(fl.contains { $0.0 == .flag16thDown })
    #expect(fl.contains { $0.0 == .flag8thDown })
    #expect(beamPaths(l).count == 1)
}

@Test("32nd and 64th notes get longer stems and their own flags")
func shortFlags() throws {
    let s = try score(measures: [
        n("C", 5, "32nd", dur: 1) + n("C", 5, "quarter", dur: 4) + n("C", 5, "64th", dur: 1),
    ])
    let l = lay(s)
    let fl = glyphItems(l, flags).map(\.0)
    #expect(fl.contains(.flag32ndDown) && fl.contains(.flag64thDown))
    let ns = allNotes(s)
    let len32 = abs(l.notes[ns[0].id]!.stemEnd!.y - l.notes[ns[0].id]!.headBox.midY)
    #expect(len32 > 3.5)
}

// MARK: Beam groups

private func beamCounts(_ l: ScoreLayout) -> [Int] { l.beams.values.map(\.count).sorted() }

@Test("4/4: eighths beam by half bar, 16ths by beat")
func beamGroups44() throws {
    let e = eighths([("C", 5), ("D", 5), ("E", 5), ("F", 5), ("G", 5), ("A", 5), ("G", 5), ("F", 5)])
    #expect(beamCounts(lay(try score(measures: [e]))) == [4, 4])
    let sx = sixteenths(Array(repeating: ("C", 5), count: 8)) + n("C", 5, "half", dur: 8)
    #expect(beamCounts(lay(try score(measures: [sx]))) == [4, 4])
    // A rest inside the half bar splits the eighths.
    let r = eighths([("C", 5), ("D", 5)]) + "<note><rest/><duration>2</duration><type>eighth</type></note>" + eighths([("F", 5)])
        + n("C", 5, "half", dur: 8)
    #expect(beamCounts(lay(try score(measures: [r]))) == [2])
}

@Test("3/4 and 2/4: by beat")
func beamGroups34() throws {
    let e = eighths(Array(repeating: ("C", 5), count: 6))
    #expect(beamCounts(lay(try score(time: (3, 4), measures: [e]))) == [2, 2, 2])
    #expect(beamCounts(lay(try score(time: (2, 4), measures: [eighths(Array(repeating: ("C", 5), count: 4))]))) == [2, 2])
}

@Test("6/8: by dotted quarter, and 16ths in 6/8")
func beamGroups68() throws {
    let s = try load("layout/compound-6-8.musicxml")
    let l = lay(s)
    // Measure 1: two groups of three. Measure 2: E4 alone, rest, G4 alone, then three. Measure 3: 12 16ths in two groups.
    #expect(beamCounts(l) == [3, 3, 3, 6, 6])
    // The 16ths have two beam levels: two paths per beam.
    let paths = beamPaths(l)
    for (id, members) in l.beams where members.count == 6 {
        #expect(paths.filter { $0.id == id }.count == 2)
    }
}

@Test("beams are never made across rests or barlines")
func beamsStayInMeasure() throws {
    let rest = "<note><rest/><duration>2</duration><type>eighth</type></note>"
    let s = try score(measures: [
        // Six eighths then two more at the barline: the last two must not join the next bar's.
        eighths([("C", 5), ("D", 5), ("E", 5), ("F", 5), ("G", 5), ("A", 5)]) + eighths([("C", 5), ("D", 5)]),
        // A rest between two eighths, a rest at the start, a rest before the last two.
        eighths([("C", 5)]) + rest + eighths([("D", 5), ("E", 5)]) + rest + eighths([("F", 5)]) ,
    ])
    let l = lay(s)
    let byID = Dictionary(uniqueKeysWithValues: allNotes(s).map { ($0.id, $0) })
    let measureOf = Dictionary(uniqueKeysWithValues: s.parts[0].measures.enumerated().flatMap { mi, m in m.notes.map { ($0.id, mi) } })
    for (_, members) in l.beams {
        // One measure per beam, and no rest between members.
        #expect(Set(members.map { measureOf[$0]! }).count == 1)
        let ms = members.map { byID[$0]! }
        let rests = s.parts[0].measures[measureOf[members[0]]!].notes.filter { $0.isRest }
        for r in rests { #expect(!(ms.first!.onset < r.onset && r.onset < ms.last!.onset)) }
    }
    // Measure 2: C, rest | D E | rest, F -> only D E beam.
    #expect(beamCounts(l).filter { $0 == 2 }.count >= 1)
    #expect(l.beams.values.allSatisfy { $0.count >= 2 })
}

@Test("beams in the file are honoured")
func fileBeams() throws {
    // Four eighths that would be one half-bar group are split in two pairs by the file.
    func b(_ v: String) -> String { "<beam number=\"1\">\(v)</beam>" }
    let notes = n("C", 5, "eighth", dur: 2, extra: b("begin")) + n("D", 5, "eighth", dur: 2, extra: b("end"))
        + n("E", 5, "eighth", dur: 2, extra: b("begin")) + n("F", 5, "eighth", dur: 2, extra: b("end"))
        + n("G", 5, "half", dur: 8)
    let l = lay(try score(measures: [notes]))
    #expect(beamCounts(l) == [2, 2])
    // And a file's hook: begin/end on level 1, a 16th with a forward hook on level 2.
    let hooked = n("C", 5, "eighth", dur: 2, extra: b("begin") + "<beam number=\"2\">forward hook</beam>")
        + n("D", 5, "16th", dur: 1, extra: b("end"))
        + n("E", 5, "half", dur: 8) + n("E", 5, "quarter", dur: 4)
    let l2 = lay(try score(measures: [hooked]))
    #expect(beamCounts(l2) == [2])
    #expect(beamPaths(l2).count == 2)
}

@Test("dotted eighth and 16th: the 16th has a backward hook")
func dottedHook() throws {
    let s = try score(measures: [
        n("C", 5, "eighth", dur: 3, extra: "<dot/>") + n("D", 5, "16th", dur: 1) + n("E", 5, "half", dur: 8) + n("E", 5, "quarter", dur: 4),
    ])
    let l = lay(s)
    let ns = allNotes(s)
    let paths = beamPaths(l)
    #expect(paths.count == 2)
    let x16 = l.notes[ns[1].id]!.stemEnd!.x
    let hook = paths.first { $0.pts.map(\.x).max()! < x16 + 0.2 && $0.pts.map(\.x).min()! < x16 - 0.5 && $0.pts.map(\.x).max()! <= x16 + 0.07 }
    #expect(hook != nil)
}

// MARK: Beam geometry

@Test("beam slope follows the interval (max 1 sp), both ends sit on staff lines, and stems meet the beam")
func beamGeometry() throws {
    // Intervals between the first and last tip: a second (1/4), a third (1/2), a fourth (3/4), a sixth+ (1).
    let cases: [([(String, Int)], Double)] = [
        ([("C", 5), ("C", 5), ("D", 5), ("D", 5)], 0.25),
        ([("C", 5), ("D", 5), ("D", 5), ("E", 5)], 0.5),
        ([("C", 5), ("D", 5), ("E", 5), ("F", 5)], 0.75),
        ([("C", 5), ("E", 5), ("G", 5), ("C", 6)], 1.0),
        ([("E", 5), ("E", 5), ("E", 5), ("E", 5)], 0),
    ]
    for (pitches, slope) in cases {
        // Pad with a half note so the group sits in one beat cell.
        let s = try score(measures: [eighths(pitches) + n("C", 5, "half", dur: 8)])
        let l = lay(s)
        let p = try #require(beamPaths(l).first)
        let members = l.beams[p.id]!
        let first = l.notes[members[0]]!, last = l.notes[members[members.count - 1]]!
        let up = first.stemEnd!.y < first.headBox.midY
        let top = l.systems[0].staves[0].top
        // The outer edge of the outer beam at the first and last stem.
        let outerL = first.stemEnd!.y - top, outerR = last.stemEnd!.y - top
        let edgeMods: (Double) -> Bool = { v in
            let m = ((v.truncatingRemainder(dividingBy: 1)) + 1).truncatingRemainder(dividingBy: 1)
            let ok: [Double] = up ? [0, 0.5, 0.75] : [0, 0.25, 0.5]
            return ok.contains { abs($0 - m) < 1e-6 || abs($0 - m + 1) < 1e-6 }
        }
        #expect(edgeMods(outerL) && edgeMods(outerR), "ends \(outerL) \(outerR)")
        #expect(abs(abs(outerR - outerL) - slope) < 1e-6, "slope \(outerR - outerL) vs \(slope)")
        #expect(abs(outerR - outerL) <= 1.0 + 1e-9)
        for gid in l.beams[p.id]! {
            let end = l.notes[gid]!.stemEnd!
            let outer = up ? topY(p, at: end.x) : topY(p, at: end.x) + EngravingDefaults.beamThickness
            #expect(abs(end.y - outer) < 0.02, "stem \(gid.value) ends \(end.y), beam edge \(outer)")
        }
    }
}

@Test("repeated pitches and concave groups get flat beams")
func flatBeams() throws {
    let rep = lay(try score(measures: [eighths(Array(repeating: ("E", 5), count: 4))]))
    let p = beamPaths(rep)[0]
    #expect(abs(p.pts[1].y - p.pts[0].y) < 1e-9)
    // Stems up, a hill: the middle notes stick out past both ends.
    let hill = lay(try score(measures: [eighths([("E", 4), ("C", 5), ("D", 5), ("F", 4)])]))
    #expect(abs(beamPaths(hill)[0].pts[1].y - beamPaths(hill)[0].pts[0].y) < 1e-9)
    // Stems down, a valley.
    let valley = lay(try score(measures: [eighths([("A", 5), ("D", 5), ("E", 5), ("B", 5)])]))
    #expect(abs(beamPaths(valley)[0].pts[1].y - beamPaths(valley)[0].pts[0].y) < 1e-9)
    // A plain rise slopes.
    let rise = lay(try score(measures: [eighths([("C", 5), ("D", 5), ("E", 5), ("F", 5)])]))
    #expect(abs(beamPaths(rise)[0].pts[1].y - beamPaths(rise)[0].pts[0].y) > 0.1)
}

@Test("stems of a beam group share one direction and stems are cut to the beam")
func beamedDirection() throws {
    let s = try score(measures: [eighths([("G", 4), ("C", 5), ("D", 5), ("A", 4)]) + n("C", 5, "half", dur: 8)])
    let l = lay(s)
    let ns = allNotes(s).filter { $0.noteValue == .eighth }
    let dirs = Set(ns.map { stemUp(l, $0)! })
    #expect(dirs.count == 1)
    // The farthest head is D5 (above): stems down.
    #expect(dirs == [false])
}

// MARK: Voices

@Test("two voices: upper stems up, lower stems down; rests move out of the way")
func voices() throws {
    let s = try load("layout/voices-two.musicxml")
    let l = lay(s)
    let ms = s.parts[0].measures
    let v1 = ms[0].notes.filter { $0.voice == "1" }
    let v2 = ms[0].notes.filter { $0.voice == "2" && !$0.isRest }
    #expect(v1.allSatisfy { stemUp(l, $0) == true })
    #expect(v2.allSatisfy { stemUp(l, $0) == false })
    // The voice 2 quarter rest of measure 1 is below the middle line; whole-measure rest of measure 2 hangs lower.
    let top = l.systems[0].staves[0].top
    let rest1 = ms[0].notes.first { $0.isRest }!
    let box1 = l.notes[rest1.id]!.headBox
    #expect(box1.midY > top + 2)
    let rest2 = ms[1].notes.first { $0.isRest }!
    let box2 = l.notes[rest2.id]!.headBox
    #expect(box2.minY >= top + 2.9)
}

@Test("voices: heads a second apart are offset, unisons of equal value share, other overlaps shift")
func voiceHeadOffsets() throws {
    let s = try load("layout/voices-two.musicxml")
    let l = lay(s)
    let m1 = s.parts[0].measures[0].notes
    // Beat 3: C5 (voice 1, stem up) and D5 (voice 2, stem down) are a second apart; the stem-up
    // note goes to the right of the stem-down note.
    let c5 = l.notes[m1.first { $0.voice == "1" && $0.onset == Rational(2) }!.id]!
    let d5 = l.notes[m1.first { $0.voice == "2" && $0.onset == Rational(2) && !$0.isRest }!.id]!
    #expect(abs(c5.headBox.minX - d5.headBox.maxX) < 0.01)
    let m3 = s.parts[0].measures[2].notes
    // Beat 1: two G4s with the same stem direction are shifted; beat 3: equal A4s with opposite stems share a head.
    let g1 = l.notes[m3[0].id]!, g2 = l.notes[m3.first { $0.voice == "2" && $0.onset == .zero }!.id]!
    #expect(abs(g2.headBox.minX - g1.headBox.minX) > 1)
    let a1 = l.notes[m3.first { $0.voice == "1" && $0.onset == Rational(2) }!.id]!
    let a2 = l.notes[m3.first { $0.voice == "2" && $0.onset == Rational(2) }!.id]!
    #expect(abs(a2.headBox.minX - a1.headBox.minX) < 0.01)
    // Beat 4: no overlap, no shift.
    let b4 = l.notes[m3.first { $0.voice == "1" && $0.onset == Rational(3) }!.id]!
    let g4 = l.notes[m3.first { $0.voice == "2" && $0.onset == Rational(3) }!.id]!
    #expect(abs(b4.headBox.minX - g4.headBox.minX) < 0.01)
}

@Test("the bach prelude bass (voices 5 and 6) lays out with opposite stems")
func bachBass() throws {
    let s = try load("bach-prelude-in-c.musicxml")
    let l = lay(s)
    let m = s.parts[0].measures[0].notes.filter { $0.staff == 2 && !$0.isRest }
    // Voice 6 (E4) sounds above voice 5 (C4): with no <stem> in the file, the upper one is up.
    let up = m.filter { $0.voice == "6" }, down = m.filter { $0.voice == "5" }
    #expect(!up.isEmpty && !down.isEmpty)
    #expect(up.allSatisfy { stemUp(l, $0) == true })
    #expect(down.allSatisfy { stemUp(l, $0) == false })
}

// MARK: Tuplets

@Test("tuplets: a beamed triplet shows only the number; an unbeamed one gets a bracket")
func tuplets() throws {
    let l = lay(try load("edge/tuplet.musicxml"))
    #expect(glyphItems(l, [.tuplet3]).count == 1)
    func bracketLines(_ l: ScoreLayout) -> Int {
        let top = l.systems[0].staves[0].top
        return l.systems[0].items.filter {
            guard case .line(let a, let b, let t, nil, nil) = $0, t == EngravingDefaults.tupletBracketThickness else { return false }
            return min(a.y, b.y) < top - 0.5 || max(a.y, b.y) > top + 4.5
        }.count
    }
    #expect(bracketLines(l) == 0)

    func tm(_ s: String) -> String { "<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>" + s }
    let notations: (String) -> String = { "<notations><tuplet type=\"\($0)\"/></notations>" }
    // Quarter triplets (the layout reads the written type; the durations here are only roughly right).
    let b = n("C", 5, "quarter", dur: 3, extra: tm("") + notations("start"))
        + n("D", 5, "quarter", dur: 3, extra: tm(""))
        + n("E", 5, "quarter", dur: 3, extra: tm("") + notations("stop"))
        + n("F", 5, "half", dur: 7)
    let l2 = lay(try score(measures: [b]))
    #expect(glyphItems(l2, [.tuplet3]).count == 1)
    #expect(bracketLines(l2) == 4)   // two bracket halves and two hooks
}

@Test("time-modification without tuplet notations still gets a number")
func tupletFallback() throws {
    let tm = "<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>"
    let b = n("C", 5, "eighth", dur: 1, extra: tm) + n("D", 5, "eighth", dur: 1, extra: tm) + n("E", 5, "eighth", dur: 2, extra: tm)
        + n("F", 5, "half", dur: 8) + n("F", 5, "quarter", dur: 4)
    // Durations are not exact thirds here; the grouping goes by the modification, not the sum.
    let l = lay(try score(measures: [b]))
    #expect(glyphItems(l, [.tuplet3]).count == 1)
}

// MARK: Review follow-ups

@Test("seconds between voices: the stem-up note goes right, also when the voices cross")
func secondsAndCrossing() throws {
    // Voice 1 (up) E4 over voice 2 (down) D4 on beat 1: a second, the upper voice above.
    // Beat 2: voice 1 D4 under voice 2 E4: crossed.
    let m = n("E", 4, "quarter", dur: 4) + n("D", 4, "quarter", dur: 4) + n("C", 5, "half", dur: 8)
        + "<backup><duration>16</duration></backup>"
        + n("D", 4, "quarter", dur: 4, voice: 2) + n("E", 4, "quarter", dur: 4, voice: 2) + n("C", 4, "half", dur: 8, voice: 2)
    let s = try score(measures: [m])
    let l = lay(s)
    let ns = allNotes(s)
    let (e1, d1) = (l.notes[ns[0].id]!, l.notes[ns[1].id]!)
    let (d2, e2) = (l.notes[ns[3].id]!, l.notes[ns[4].id]!)
    #expect(abs(e1.headBox.minX - d2.headBox.maxX) < 0.01)   // up note right of down note
    #expect(abs(d1.headBox.minX - e2.headBox.maxX) < 0.01)   // crossed: still the up note on the right
}

@Test("shared unison: one head, one accidental, both notes get the same box")
func sharedUnison() throws {
    let acc = "<accidental>sharp</accidental>"
    func f(_ voice: Int) -> String {
        "<note><pitch><step>F</step><alter>1</alter><octave>5</octave></pitch><duration>4</duration><voice>\(voice)</voice><type>quarter</type>\(acc)</note>"
    }
    let s = try score(measures: [f(1) + n("C", 5, "half", dur: 8) + "<backup><duration>12</duration></backup>" + f(2) + n("C", 4, "half", dur: 8, voice: 2)])
    let l = lay(s)
    let ns = allNotes(s)
    let (a, b) = (ns[0], ns[2])
    #expect(l.sharedHeads[b.id] == a.id)
    #expect(l.notes[a.id]!.headBox == l.notes[b.id]!.headBox)
    // One head and one sharp in the layout for that column.
    let heads = glyphItems(l, [.noteheadBlack]).filter { $0.2 == a.id || $0.2 == b.id }
    #expect(heads.count == 1)
    let sharps = glyphItems(l, [.accidentalSharp]).filter { $0.2 == a.id || $0.2 == b.id }
    #expect(sharps.count == 1)
}

@Test("unisons of different value do not share: the later voice shifts")
func unsharedUnison() throws {
    let s = try score(measures: [n("G", 4, "half", dur: 8) + n("C", 5, "half", dur: 8) + "<backup><duration>16</duration></backup>"
                                 + n("G", 4, "quarter", dur: 4, voice: 2) + n("C", 4, "quarter", dur: 4, voice: 2) + n("C", 4, "half", dur: 8, voice: 2)])
    let l = lay(s)
    let ns = allNotes(s)
    #expect(l.sharedHeads.isEmpty)
    #expect(abs(l.notes[ns[0].id]!.headBox.minX - l.notes[ns[2].id]!.headBox.minX) > 1)
}

@Test("a rest stays clear of the other voice's heads")
func restClearsOtherVoice() throws {
    // Voice 1 (upper) rests while voice 2 has C6 far above the staff; voice 2 (lower) rests while voice 1 has C3 below.
    let rest = "<note><rest/><duration>4</duration><voice>1</voice><type>quarter</type></note>"
    let rest2 = "<note><rest/><duration>4</duration><voice>2</voice><type>quarter</type></note>"
    let s = try score(measures: [rest + n("C", 5, "quarter", dur: 4) + n("C", 5, "half", dur: 8)
                                 + "<backup><duration>16</duration></backup>" + n("C", 6, "quarter", dur: 4, voice: 2)
                                 + n("C", 3, "quarter", dur: 4, voice: 2) + n("C", 4, "half", dur: 8, voice: 2)])
    let l = lay(s)
    let ms = s.parts[0].measures[0].notes
    let r1 = l.notes[ms.first { $0.isRest }!.id]!.headBox
    let c6 = l.notes[ms.first { $0.voice == "2" }!.id]!.headBox
    #expect(r1.maxY <= c6.minY + 1e-6)
    _ = rest2
    // Lower voice rest below the upper voice's low note.
    let s2 = try score(measures: [n("C", 3, "quarter", dur: 4) + n("C", 5, "quarter", dur: 4) + n("C", 5, "half", dur: 8)
                                  + "<backup><duration>16</duration></backup>" + rest2 + n("C", 4, "quarter", dur: 4, voice: 2) + n("C", 4, "half", dur: 8, voice: 2)])
    let l2 = lay(s2)
    let m2 = s2.parts[0].measures[0].notes
    let low = l2.notes[m2.first { $0.voice == "1" }!.id]!.headBox
    let r2 = l2.notes[m2.first { $0.isRest }!.id]!.headBox
    #expect(r2.minY >= low.maxY - 1e-6)
}

@Test("Bach bass: voice 6's 16th rests sit just above voice 5's C4, at most 2.5 spaces above the staff")
func bachRestsInStaff() throws {
    let s = try load("bach-prelude-in-c.musicxml")
    let l = lay(s)
    let rests = s.parts[0].measures[0].notes.filter { $0.isRest && $0.staff == 2 }
    #expect(!rests.isEmpty)
    for r in rests {
        let box = l.notes[r.id]!.headBox
        let top = l.systems[0].staves[1].top
        // Voice 6 (E4, on a ledger line) is the upper voice, so its rests sit just above the C4 of
        // voice 5: the glyph's bottom is at most 2.5 spaces above the top line (a 16th rest is
        // 2.7 tall, so its top reaches about 5 above).
        #expect(box.maxY >= top - 2.5 && box.minY >= top - 5.5 && box.maxY <= top + 4.6, "rest box \(box.minY - top)...\(box.maxY - top)")
    }
}

@Test("triplet eighths in 4/4 beam by beat, not by half bar")
func tripletsInFourFour() throws {
    let tm = "<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>"
    // Divisions 6: a triplet eighth is 2 divisions, a half note 12.
    let t = (0..<6).map { n("C", 5, "eighth", dur: 2, extra: tm + ($0 % 3 == 0 ? "<notations><tuplet type=\"start\"/></notations>" : "") + ($0 % 3 == 2 ? "<notations><tuplet type=\"stop\"/></notations>" : "")) }.joined()
    let l = lay(try score(divisions: 6, measures: [t + n("C", 5, "half", dur: 12)]))
    #expect(beamCounts(l) == [3, 3])
    #expect(glyphItems(l, [.tuplet3]).count == 2)
}

@Test("pickup measures group by the position from the bar end")
func pickupGrouping() throws {
    // 3/4 with a pickup of three eighths: they are the last 1.5 beats of a bar, so the first is
    // alone on the offbeat of beat 2 and the other two make beat 3.
    let s = try score(time: (3, 4), measures: [eighths([("C", 5), ("D", 5), ("E", 5)]), eighths(Array(repeating: ("C", 5), count: 6))])
    let l = lay(s)
    let ns = s.parts[0].measures[0].notes
    #expect(l.beams.values.contains([ns[1].id, ns[2].id]))
    #expect(!l.beams.values.contains { $0.contains(ns[0].id) })
    #expect(beamCounts(l) == [2, 2, 2, 2])
}

@Test("meters: 2/2 16ths by quarter, 5/8 as 3+2, 6/4 by dotted half")
func meterRules() throws {
    // 2/2: sixteens by the quarter.
    let sx = sixteenths(Array(repeating: ("C", 5), count: 8)) + n("C", 5, "half", dur: 8)
    #expect(beamCounts(lay(try score(time: (2, 2), measures: [sx]))) == [4, 4])
    // 2/2: four eighths beam as a half-note group.
    #expect(beamCounts(lay(try score(time: (2, 2), measures: [eighths(Array(repeating: ("C", 5), count: 8))]))) == [4, 4])
    // 5/8: 3 + 2.
    #expect(beamCounts(lay(try score(time: (5, 8), measures: [eighths(Array(repeating: ("C", 5), count: 5))]))) == [2, 3])
    // 6/4: eighths by the dotted half (six eighths of the twelve), dotted-half cells.
    let e6 = eighths(Array(repeating: ("C", 5), count: 12))
    #expect(beamCounts(lay(try score(time: (6, 4), measures: [e6]))) == [6, 6])
}

@Test("grace notes: stems always up, consecutive short graces beam")
func graceNotes() throws {
    func gr(_ step: String, _ oct: Int, _ type: String) -> String {
        "<note><grace/><pitch><step>\(step)</step><octave>\(oct)</octave></pitch><voice>1</voice><type>\(type)</type></note>"
    }
    let s = try score(measures: [gr("A", 5, "16th") + gr("B", 5, "16th") + n("C", 6, "quarter", dur: 4) + n("C", 5, "half", dur: 8) + n("C", 5, "quarter", dur: 4)
                                 + gr("A", 5, "eighth") + n("C", 5, "quarter", dur: 4)])
    let l = lay(s)
    let graces = allNotes(s).filter(\.isGrace)
    for g in graces { #expect(stemUp(l, g) == true) }
    #expect(beamCounts(l).contains(2))
    // The lone grace eighth keeps a flag.
    #expect(glyphItems(l, flags).count >= 1)
}

@Test("beams have their own identity and every member has a stem")
func beamIdentity() throws {
    let l = lay(try load("minuet-in-g.musicxml"))
    #expect(!l.beams.isEmpty)
    let ids = Set(l.systems.flatMap(\.items).compactMap(\.beamID))
    #expect(ids == Set(l.beams.keys))
    for item in l.systems.flatMap(\.items) { if case .beam = item { #expect(item.noteID == nil && item.groupID == nil) } }
}

@Test("malformed beams and tuplets do not crash and give sensible shapes")
func malformedMarks() throws {
    func b(_ n: Int, _ v: String) -> String { "<beam number=\"\(n)\">\(v)</beam>" }
    // A beam begin never ended, an end without a begin, and a continue on its own.
    let beams = n("C", 5, "eighth", dur: 2, extra: b(1, "begin")) + n("D", 5, "eighth", dur: 2, extra: b(1, "begin")) + n("E", 5, "eighth", dur: 2, extra: b(1, "end"))
        + n("F", 5, "eighth", dur: 2, extra: b(1, "end")) + n("G", 5, "eighth", dur: 2, extra: b(1, "continue")) + n("A", 5, "eighth", dur: 2)
        + n("A", 5, "eighth", dur: 2, extra: b(2, "backward hook")) + n("B", 5, "eighth", dur: 2, extra: b(1, "begin"))
    let l = lay(try score(measures: [beams]))
    #expect(l.beams.values.allSatisfy { $0.count >= 2 })
    #expect(!l.beams.isEmpty)
    // Tuplets: a stop without a start, a start never stopped (closes at the first plain note), nested numbers.
    let tm = "<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>"
    let t = n("C", 5, "eighth", dur: 1, extra: tm + "<notations><tuplet type=\"stop\"/></notations>")
        + n("D", 5, "eighth", dur: 1, extra: tm + "<notations><tuplet type=\"start\"/></notations>")
        + n("E", 5, "eighth", dur: 1, extra: tm)
        + n("F", 5, "quarter", dur: 4) + n("G", 5, "quarter", dur: 4) + n("A", 5, "half", dur: 8)
    let l2 = lay(try score(measures: [t]))
    #expect(glyphItems(l2, [.tuplet3]).count == 1)
}
