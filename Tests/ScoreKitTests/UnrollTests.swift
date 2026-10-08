import Foundation
import Testing
@testable import ScoreKit

/// A one-part 4/4 score of whole-note measures (C4 up the scale), each with extra XML
/// before its note (directions) and a barline XML after it.
private func piece(_ ms: [(pre: String, post: String)]) throws -> Score {
    let steps = ["C", "D", "E", "F", "G", "A", "B", "C", "D", "E"]
    var body = ""
    for (i, m) in ms.enumerated() {
        let attrs = i == 0 ? "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>" : ""
        body += "<measure number=\"\(i + 1)\">\(attrs)\(m.pre)<note><pitch><step>\(steps[i % steps.count])</step><octave>4</octave></pitch><duration>4</duration></note>\(m.post)</measure>"
    }
    let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\">\(body)</part></score-partwise>"
    return try Score.parse(xml: Data(xml.utf8))
}

private func sound(_ attrs: String) -> String { "<direction><direction-type><words/></direction-type><sound \(attrs)/></direction>" }
private let fwd = "<barline location=\"left\"><repeat direction=\"forward\"/></barline>"
private func back(_ times: Int? = nil) -> String {
    "<barline location=\"right\"><repeat direction=\"backward\"\(times.map { " times=\"\($0)\"" } ?? "")/></barline>"
}
private func order(_ s: Score) -> [Int] { Unroll(score: s).measures.map { $0.index + 1 } }
private let plain = (pre: "", post: "")

@Test("jumps: D.S. al Coda goes back to the segno, then to the coda at 'to coda'")
func dalSegnoAlCoda() throws {
    let s = try piece([plain, (sound("segno=\"s\""), ""), (sound("tocoda=\"c\""), ""), (sound("dalsegno=\"s\""), ""),
                       (sound("coda=\"c\""), ""), plain])
    #expect(order(s) == [1, 2, 3, 4, 2, 3, 5, 6])
}

@Test("jumps: D.C. al Coda; the unnamed marks match each other")
func daCapoAlCoda() throws {
    let s = try piece([plain, (sound("tocoda=\"yes\""), ""), (sound("dacapo=\"yes\""), ""), (sound("coda=\"yes\""), ""), plain])
    #expect(order(s) == [1, 2, 3, 1, 2, 4, 5])
}

@Test("jumps: the <segno/> and <coda/> direction types count as marks")
func directionTypeMarks() throws {
    let segno = "<direction><direction-type><segno/></direction-type></direction>"
    let s = try piece([plain, (segno, ""), (sound("dalsegno=\"x\""), ""), plain])
    #expect(order(s) == [1, 2, 3, 2, 3, 4])
    #expect(s.parts[0].measures[1].jumpMarks.first == JumpMark(kind: .segno, id: nil, onset: .zero, source: .directionType))
}

@Test("jumps: repeats are not retaken after D.C., and the last ending plays")
func repeatsAfterJump() throws {
    let end1 = "<barline location=\"left\"><ending number=\"1\" type=\"start\">1.</ending></barline>"
    let stop1 = "<barline location=\"right\"><ending number=\"1\" type=\"stop\"/><repeat direction=\"backward\"/></barline>"
    let end2 = "<barline location=\"left\"><ending number=\"2\" type=\"start\">2.</ending></barline>"
    let stop2 = "<barline location=\"right\"><ending number=\"2\" type=\"discontinue\"/></barline>"
    let s = try piece([(fwd, ""), (end1, stop1), (end2 + sound("fine=\"yes\""), stop2), (sound("dacapo=\"yes\""), "")])
    // 1 2 | 1 3 (fine only counts after the jump), 4 -> D.C.: 1 then 3 (ending 2, not 2), fine.
    #expect(order(s) == [1, 2, 1, 3, 4, 1, 3])
}

@Test("jumps: a fine or tocoda without a jump is ignored; a second jump is not taken")
func marksBeforeJump() throws {
    let s = try piece([plain, (sound("fine=\"yes\""), ""), (sound("tocoda=\"c\"") + sound("dacapo=\"yes\""), ""), (sound("coda=\"c\""), "")])
    #expect(order(s) == [1, 2, 3, 1, 2])  // after D.C. the fine stops it
    let twice = try piece([plain, (sound("dacapo=\"yes\""), ""), plain])
    #expect(order(twice) == [1, 2, 1, 2, 3])  // no fine: plays on to the end
}

@Test("repeats: sections, times, nesting of finished sections, default start")
func repeatSections() throws {
    #expect(order(try piece([plain, (fwd, back()), plain])) == [1, 2, 2, 3])
    #expect(order(try piece([(fwd, back(3)), plain])) == [1, 1, 1, 2])
    #expect(order(try piece([plain, (plain.pre, back()), plain, (plain.pre, back())])) == [1, 2, 1, 2, 3, 4, 3, 4])
    #expect(order(try piece([(fwd, back()), (fwd, back())])) == [1, 1, 2, 2])
}

@Test("endings: numbers, groups, ranges and unnumbered endings")
func endingVariants() throws {
    func ending(_ n: String, _ text: String = "", stop: Bool = false, back b: Bool = false) -> (pre: String, post: String) {
        ("<barline location=\"left\"><ending number=\"\(n)\" type=\"start\">\(text)</ending></barline>",
         "<barline location=\"right\"><ending number=\"\(n)\" type=\"stop\"/>\(b ? "<repeat direction=\"backward\"/>" : "")</barline>")
    }
    // Three passes: endings 1, 2, 3 and a following measure.
    let s = try piece([(fwd, ""), ending("1", back: true), ending("2", back: true), ending("3"), plain])
    #expect(order(s) == [1, 2, 1, 3, 1, 4, 5])
    // "1-2" covers two passes.
    let r = try piece([(fwd, ""), ending("1-2", back: true), ending("3"), plain])
    #expect(order(r) == [1, 2, 1, 2, 1, 3, 4])
    // Unnumbered endings take their label digits, else their ordinal.
    let u = try piece([(fwd, ""), ending("", "1.", back: true), ending("", "2."), plain])
    #expect(order(u) == [1, 2, 1, 3, 4])
    let o = try piece([(fwd, ""), ending("", "", back: true), ending("", ""), plain])
    #expect(order(o) == [1, 2, 1, 3, 4])
}

@Test("unroll: the start of each played measure follows the longest part")
func startQuarters() throws {
    let s = try piece([(fwd, back()), plain])
    let u = Unroll(score: s)
    #expect(u.measures.map(\.start) == [Rational(0), Rational(4), Rational(8)])
    #expect(u.measures.map(\.pass) == [1, 2, 1])
    #expect(u.length == Rational(12))
}

@Test("spelling: accidentals and octaves belong to the letter")
func spelling() {
    #expect(Spelled(midi: 60, letter: .B) == Spelled(letter: .B, acc: 1, octave: 3))
    #expect(Spelled(midi: 59, letter: .C) == Spelled(letter: .C, acc: -1, octave: 4))
    #expect(Spelled(midi: 61, letter: .C) == Spelled(letter: .C, acc: 1, octave: 4))
    #expect(Spelled(midi: 70, letter: .B) == Spelled(letter: .B, acc: -1, octave: 4))
    #expect(Spelled(midi: 61, letter: .D) == Spelled(letter: .D, acc: -1, octave: 4))
    #expect(Spelled(midi: 62, letter: .C) == Spelled(letter: .C, acc: 2, octave: 4))
    #expect(Spelled(midi: 12, letter: .C) == Spelled(letter: .C, acc: 0, octave: 0))
    #expect(Spelled(midi: 11, letter: .C) == Spelled(letter: .C, acc: -1, octave: 0))
    #expect(Spelled(midi: 0, letter: .B) == Spelled(letter: .B, acc: 1, octave: -2))
    // The accidental flips sign past a tritone.
    #expect(Spelled(midi: 66, letter: .C) == Spelled(letter: .C, acc: 6, octave: 4))
    #expect(Spelled(midi: 67, letter: .C) == Spelled(letter: .C, acc: -5, octave: 5))
    #expect(Spelled(midi: 65, letter: .B) == Spelled(letter: .B, acc: 6, octave: 3))
    #expect(Spelled(midi: 64, letter: .B) == Spelled(letter: .B, acc: 5, octave: 3))
}

@Test("timeline: a lone tie start keeps its own length; a lone stop is untied; ties are per part and pitch")
func tieEdges() throws {
    func n(_ step: String, _ tied: String) -> String {
        "<note><pitch><step>\(step)</step><octave>4</octave></pitch><duration>1</duration>\(tied.isEmpty ? "" : "<notations><tied type=\"\(tied)\"/></notations>")</note>"
    }
    let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\"><measure number=\"1\"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>\(n("C", "start"))\(n("D", "stop"))\(n("E", "start"))\(n("E", "stop"))</measure></part></score-partwise>"
    let t = Timeline(score: try Score.parse(xml: Data(xml.utf8)))
    let notes = t.entries.flatMap(\.notes)
    #expect(notes.map(\.tie) == [.start, .none, .start, .continue])
    #expect(notes.map(\.quarters) == [1, 1, 2, 1])
}

@Test("timeline: rests, hidden and other parts' positions; grace and zero-duration notes are not reported")
func positions() throws {
    let (score, t, _) = try loadTimeline("voice-piano")
    // The voice part's eighth is a position of its own; only the piano is played.
    let chosen = chooseParts(score.parts.map { ($0.name, $0.staves) })
    #expect(t.entries.contains { !$0.notes.isEmpty && walkNotes($0, chosen: chosen).isEmpty })
    let g = Timeline(score: try Score.load(data: fixture("edge/grace.musicxml")))
    #expect(g.entries.allSatisfy { $0.notes.allSatisfy { $0.quarters > 0 } })
}

@Test("tempo: metronome beats sound, raw per-minute, rounding, standalone sound only in measure 0")
func tempoRules() throws {
    func bpms(_ name: String) throws -> [Double] {
        let t = Timeline(score: try Score.load(data: fixture("edge/\(name).musicxml")))
        var out: [Double] = []
        for e in t.entries where out.last != e.bpm { out.append(e.bpm) }
        return out
    }
    #expect(try bpms("sound-and-metronome-differ") == [80])
    #expect(try bpms("metronome-half-note") == [60, 40, 120])
    #expect(try bpms("standalone-sound-later") == [120])
    #expect(try bpms("no-tempo") == [100])
}

@Test("parser: jump marks from sound attributes")
func jumpMarkParsing() throws {
    let s = try Score.load(data: fixture("edge/dc-al-fine.musicxml"))
    let marks = s.parts[0].measures.map(\.jumpMarks)
    #expect(marks[0].isEmpty)
    #expect(marks[1].map(\.kind) == [.fine])
    #expect(marks[2].map(\.kind) == [.dacapo])
    #expect(marks[2][0].source == .sound)
}

@Test("timeline: .mxl and .musicxml give the same entries")
func mxlSameTimeline() throws {
    let a = Timeline(score: try Score.load(data: fixture("ode-to-joy.musicxml")))
    let b = Timeline(score: try Score.load(data: fixture("edge/ode-to-joy.mxl")))
    #expect(a.entries == b.entries)
    #expect(a.entries.count == 62)
}

// MARK: Quarter-note measures with positioned marks

/// A score of 4/4 measures of four quarter notes; `pre[m][i]` goes before note `i` of measure `m`,
/// `post[m]` after the measure's notes. `pitches[m]` overrides the measure's pitch (default C4).
private func quarterPiece(_ n: Int, pre: [Int: [Int: String]] = [:], post: [Int: String] = [:],
                          tied: [Int: String] = [:], pitch: [Int: String] = [:]) throws -> Score {
    var body = ""
    for m in 0..<n {
        let attrs = m == 0 ? "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>" : ""
        var notes = ""
        for i in 0..<4 {
            let step = pitch[m] ?? "C"
            // A tie start ends the measure (its last note); a stop begins it.
            let kind = tied[m]
            let tie = (kind == "start" && i == 3) || (kind == "stop" && i == 0) ? "<notations><tied type=\"\(kind!)\"/></notations>" : ""
            notes += (pre[m]?[i] ?? "") + "<note><pitch><step>\(step)</step><octave>4</octave></pitch><duration>1</duration>\(tie)</note>"
        }
        body += "<measure number=\"\(m + 1)\">\(attrs)\(notes)\(post[m] ?? "")</measure>"
    }
    let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\">\(body)</part></score-partwise>"
    return try Score.parse(xml: Data(xml.utf8))
}

private func positions(_ t: Timeline) -> [(Int, Double, Double)] { t.entries.map { ($0.measure, $0.position.double, $0.beat) } }

@Test("played range: a mid-bar Fine ends playback after the note it sits over; at the bar's start or end it leaves the bar whole")
func fineMidBar() throws {
    let s = try quarterPiece(3, pre: [1: [2: sound("fine=\"yes\"")]], post: [2: sound("dacapo=\"yes\"")])
    let u = Unroll(score: s)
    #expect(u.measures.map(\.index) == [0, 1, 2, 0, 1])
    // The Fine sits before the third note (position 2): that note is the last one played.
    #expect(u.measures.last?.from == .zero && u.measures.last?.to == Rational(3))
    let t = Timeline(score: s)
    #expect(t.entries.count == 12 + 4 + 3)
    #expect(near(t.entries.last!.beat, 18))   // m1 12..16, m2 positions 0-2: beats 16, 17, 18
    #expect(near(t.length.double, 19))
    // The usual placement at the measure's start keeps the whole measure.
    let whole = try quarterPiece(3, pre: [1: [0: sound("fine=\"yes\"")]], post: [2: sound("dacapo=\"yes\"")])
    #expect(Unroll(score: whole).measures.last?.to == Rational(4))
}

@Test("played range: a mid-bar segno is entered there, and beats stay continuous")
func segnoMidBar() throws {
    let s = try quarterPiece(3, pre: [1: [2: sound("segno=\"s\"")]], post: [2: sound("dalsegno=\"s\"")])
    let u = Unroll(score: s)
    #expect(u.measures.map(\.index) == [0, 1, 2, 1, 2])   // no Fine: m3 plays on after the jump
    #expect(u.measures[3].from == Rational(2) && u.measures[3].to == Rational(4))
    let t = Timeline(score: s)
    let jumped = t.entries.filter { $0.playedMeasureIndex == 3 }
    #expect(jumped.map(\.position.double) == [2, 3])
    #expect(jumped.map(\.beat) == [12, 13])
    #expect(near(t.entries.last!.beat, 17))
}

@Test("played range: a segno on the right barline starts the next measure; a mid-bar coda is entered there")
func segnoAtBarEnd() throws {
    let s = try quarterPiece(3, post: [0: "<barline location=\"right\" segno=\"s\"/>", 2: sound("dalsegno=\"s\"")])
    #expect(Unroll(score: s).measures.map(\.index) == [0, 1, 2, 1, 2])
    let c = try quarterPiece(3, pre: [2: [2: sound("coda=\"c\"")]], post: [0: sound("dacapo=\"yes\"")])
    // D.C. in m1 goes to m1 again... then plays on: no To Coda, so the coda is just played through.
    #expect(Unroll(score: c).measures.map(\.index) == [0, 0, 1, 2])
}

@Test("to coda: the coda is the first one after the To Coda measure, even with a coda sign beside the To Coda")
func codaAfterToCoda() throws {
    let codaSign = "<direction><direction-type><coda/></direction-type>"
    // Sibelius/Finale style: the To Coda text carries a coda symbol, its sound has tocoda="coda",
    // and the destination is an unnamed coda sign (no sound coda).
    let s = try quarterPiece(5, pre: [1: [0: codaSign + "<sound tocoda=\"coda\"/></direction>"],
                                      3: [0: codaSign + "</direction>"]],
                             post: [2: sound("dacapo=\"yes\"")])
    #expect(Unroll(score: s).measures.map(\.index) == [0, 1, 2, 0, 1, 3, 4])
}

@Test("to coda: a coda entered mid-bar plays from there")
func codaMidBar() throws {
    let s = try quarterPiece(4, pre: [1: [0: sound("tocoda=\"c\"")], 3: [1: sound("coda=\"c\"")]],
                             post: [2: sound("dacapo=\"yes\"")])
    let u = Unroll(score: s)
    #expect(u.measures.map(\.index) == [0, 1, 2, 0, 1, 3])
    #expect(u.measures.last?.from == Rational(1))
}

@Test("repeat counts are capped, so absurd times terminate")
func repeatCap() throws {
    let s = try piece([(fwd, back(1_000_000)), plain])
    #expect(order(s).count == 16 + 1)
    // Overflowing digits are not a number: the default of two passes applies.
    let huge = "<barline location=\"right\"><repeat direction=\"backward\" times=\"99999999999999999999\"/></barline>"
    #expect(order(try piece([(fwd, huge), plain])) == [1, 1, 2])
    #expect(Unroll(score: try piece(Array(repeating: (pre: fwd, post: back(1_000_000)), count: 40))).measures.count <= 64 * 40)
}

@Test("ties resolve over the played order: a tie before :| does not claim a note after the volta")
func tieBeforeRepeat() throws {
    // m1 |: E, m2 G (tie start) :|, m3 G (tie stop). Played m1 m2 m1 m2 m3.
    let s = try quarterPiece(3, post: [1: back()], tied: [1: "start", 2: "stop"], pitch: [0: "E", 1: "G", 2: "G"])
    var s2 = s
    s2.parts[0].measures[0].barlines = [Barline(location: .left, onset: .zero, style: nil, repeatMark: Repeat(direction: .forward, times: nil), ending: nil)]
    let t = Timeline(score: s2)
    let g = t.entries.flatMap(\.notes).filter { $0.tie != .none }
    #expect(g.map(\.tie) == [.start, .start, .continue])
    #expect(g.map(\.quarters) == [1, 2, 1])  // pass 1's lone start keeps its own length
}

@Test("ties resolve over the played order: a tie into ending 2 continues from the measure before ending 1")
func tieIntoSecondEnding() throws {
    // m1 G tie start; m2 (ending 1) G :|; m3 (ending 2) G tie stop.
    var s = try quarterPiece(3, tied: [0: "start", 2: "stop"], pitch: [0: "G", 1: "G", 2: "G"])
    s.parts[0].measures[0].barlines = [Barline(location: .left, onset: .zero, style: nil, repeatMark: Repeat(direction: .forward, times: nil), ending: nil)]
    s.parts[0].measures[1].barlines = [
        Barline(location: .left, onset: .zero, style: nil, repeatMark: nil, ending: Ending(numbers: [1], rawNumber: "1", text: "1.", printObject: true, kind: .start)),
        Barline(location: .right, onset: Rational(4), style: nil, repeatMark: Repeat(direction: .backward, times: nil),
                ending: Ending(numbers: [1], rawNumber: "1", text: "", printObject: true, kind: .stop))]
    s.parts[0].measures[2].barlines = [
        Barline(location: .left, onset: .zero, style: nil, repeatMark: nil, ending: Ending(numbers: [2], rawNumber: "2", text: "2.", printObject: true, kind: .start)),
        Barline(location: .right, onset: Rational(4), style: nil, repeatMark: nil,
                ending: Ending(numbers: [2], rawNumber: "2", text: "", printObject: true, kind: .discontinue))]
    let t = Timeline(score: s)
    #expect(t.unroll.measures.map(\.index) == [0, 1, 0, 2])
    let tied = t.entries.flatMap(\.notes).filter { $0.tie != .none }
    #expect(tied.map(\.tie) == [.start, .start, .continue])
    #expect(tied.map(\.quarters) == [1, 2, 1])
}

@Test("ties: across voices in a staff, enharmonic, and the tie-cross-voice fixture reading")
func tieMatching() throws {
    let (_, t, _) = try loadTimeline("tie-cross-voice")
    let tied = t.entries.flatMap(\.notes).filter { $0.tie != .none }.map { ($0.midi, $0.tie, $0.quarters) }
    #expect(tied.map(\.0) == [67, 67, 66, 66, 60, 60])
    #expect(tied.map(\.1) == [.start, .continue, .start, .continue, .start, .continue])
}

@Test("timeline API: entryIndices and playedMeasureIndex")
func entryIndicesAPI() throws {
    let score = try Score.load(data: fixture("minuet-in-g.musicxml"))
    let t = Timeline(score: score)
    let first = try #require(t.entries.first?.notes.first)
    let idx = t.entryIndices(for: first.id)
    #expect(idx.count == 2)  // the minuet repeats from the start
    #expect(idx[0] == 0 && t.entries[idx[1]].occurrence > t.entries[idx[0]].occurrence)
    #expect(t.entries[idx[1]].playedMeasureIndex == t.entries[idx[1]].measureIndex + 16)
    #expect(t.entryIndices(for: NoteID(-1)).isEmpty)
    for (i, e) in t.entries.enumerated() {
        #expect(t.unroll.measures[e.playedMeasureIndex].index == e.measureIndex)
        for n in e.notes { #expect(t.entryIndices(for: n.id).contains(i)) }
    }
}

@Test("tempo offsets follow the spec: only sound=\"yes\" or an offset inside <sound> moves the tempo")
func tempoOffsetSpec() throws {
    func at(_ dir: String) throws -> [Double] {
        let s = try quarterPiece(1, pre: [0: [2: dir]])
        return Timeline(score: s).entries.map(\.bpm)
    }
    let words = "<direction-type><words/></direction-type>"
    #expect(try at("<direction>\(words)<offset>1</offset><sound tempo=\"60\"/></direction>") == [100, 100, 60, 60])
    #expect(try at("<direction>\(words)<offset sound=\"yes\">1</offset><sound tempo=\"60\"/></direction>") == [100, 100, 100, 60])
    #expect(try at("<direction>\(words)<sound tempo=\"60\"><offset>1</offset></sound></direction>") == [100, 100, 100, 60])
    // The sound's own offset beats the direction's.
    #expect(try at("<direction>\(words)<offset sound=\"yes\">-1</offset><sound tempo=\"60\"><offset>1</offset></sound></direction>") == [100, 100, 100, 60])
    let s = try quarterPiece(1, pre: [0: [0: "<direction>\(words)<offset sound=\"yes\">1</offset><sound tempo=\"60\"/></direction>"]])
    let d = s.parts[0].measures[0].directions[0]
    #expect(d.offsetSound && d.offset == Rational(1) && d.soundPosition == Rational(1))
}

@Test("parser: barline segno/coda and ending numbers with a full stop")
func barlineMarksAndLabels() throws {
    let s = try quarterPiece(2, post: [0: "<barline location=\"right\" coda=\"c\"/>", 1: "<barline location=\"right\"><segno/></barline>"])
    #expect(s.parts[0].measures[0].jumpMarks == [JumpMark(kind: .coda, id: "c", onset: Rational(4), source: .barline)])
    #expect(s.parts[0].measures[1].jumpMarks == [JumpMark(kind: .segno, id: nil, onset: Rational(4), source: .barline)])
    let e = try quarterPiece(2, post: [0: "<barline location=\"right\"><ending number=\"1.\" type=\"stop\"/></barline>"])
    #expect(e.parts[0].measures[0].barlines[0].ending?.numbers == [1])
    let r = try quarterPiece(1, post: [0: "<barline location=\"right\"><ending number=\"1., 3\" type=\"stop\"/></barline>"])
    #expect(r.parts[0].measures[0].barlines[0].ending?.numbers == [1, 3])
}
