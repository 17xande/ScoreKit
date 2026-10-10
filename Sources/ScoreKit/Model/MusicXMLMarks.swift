import Foundation

/// One octave-shift, pedal, wedge or dynamics element, before its start and stop are paired.
struct RawMark {
    enum Kind {
        case octaveShift(type: String, number: Int, octaves: Int)
        case pedal(type: String, line: Bool?, sign: Bool?)
        case wedge(type: String, number: Int)
        case dynamic(String)
        case words(String)
        case dashes(type: String, number: Int)
    }
    var kind: Kind
    var at: ScorePosition
    var staff: Int
    var above: Bool?
}

extension MusicXMLParser {
    /// All `<words>` of one `<direction-type>` joined (the tree trims each, so they are joined with a space), whitespace collapsed.
    static func wordsText(_ dt: XNode) -> String {
        dt.children(named: "words").map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The marks of one `<direction>`. `at` is the cursor; a `<offset>` moves wedges, dynamics and
    /// pedals (not octave shifts: those decide which notes are shifted).
    func rawMarks(_ el: XNode, at: ScorePosition, state: PartState) throws -> [RawMark] {
        let staff = el.child(named: "staff")?.int ?? 1
        let placement = el.trimmedAttribute("placement")
        var moved = at
        if let off = try optionalOffset(el, state), off != .zero {
            moved.onset = max(.zero, at.onset + off)
        }
        var out: [RawMark] = []
        // Words of a jump direction are drawn with the jump mark; the first words of a tempo direction
        // with the tempo (`TempoDirection.words`). Any other words are plain text.
        let jump = !Self.jumpMarks(in: el, sound: el.child(named: "sound"), onset: .zero).isEmpty
        let tempo = el.child(named: "sound")?.attribute("tempo") != nil
            || el.children(named: "direction-type").contains { $0.child(named: "metronome") != nil }
        var tempoWordsTaken = false
        for dt in el.children(named: "direction-type") {
            let text = Self.wordsText(dt)
            if !text.isEmpty {
                let isTempoWords = tempo && !tempoWordsTaken
                if isTempoWords { tempoWordsTaken = true }
                // Text with no letter or digit ("*", "( )") is a pedal or accidental sign written as words.
                if !jump, !isTempoWords, text.contains(where: { $0.isLetter || $0.isNumber }) {
                    out.append(RawMark(kind: .words(text), at: moved, staff: staff, above: placement.map { $0 == "above" }))
                }
            }
            if let d = dt.child(named: "dashes"), let type = d.trimmedAttribute("type") {
                out.append(RawMark(kind: .dashes(type: type, number: d.trimmedAttribute("number").flatMap { Int($0) } ?? 1), at: moved, staff: staff,
                                   above: (d.trimmedAttribute("placement") ?? placement).map { $0 == "above" }))
            }
            if let o = dt.child(named: "octave-shift"), let type = o.trimmedAttribute("type") {
                let size = o.trimmedAttribute("size").flatMap { Int($0) } ?? 8
                let n = max(1, (size - 1) / 7)
                out.append(RawMark(kind: .octaveShift(type: type, number: o.trimmedAttribute("number").flatMap { Int($0) } ?? 1,
                                                      octaves: type == "up" ? n : -n),
                                   at: at, staff: staff, above: nil))
            }
            if let p = dt.child(named: "pedal"), let type = p.trimmedAttribute("type") {
                func flag(_ a: String) -> Bool? { p.trimmedAttribute(a).map { $0 == "yes" } }
                out.append(RawMark(kind: .pedal(type: type, line: flag("line"), sign: flag("sign")), at: moved, staff: staff, above: nil))
            }
            if let w = dt.child(named: "wedge"), let type = w.trimmedAttribute("type") {
                out.append(RawMark(kind: .wedge(type: type, number: w.trimmedAttribute("number").flatMap { Int($0) } ?? 1),
                                   at: moved, staff: staff, above: placement.map { $0 == "above" }))
            }
            for d in dt.children(named: "dynamics") {
                // `<sf/><p/>` and `<other-dynamics>` give one printed word.
                let text = d.children.map { $0.name == "other-dynamics" ? $0.text : $0.name }.joined()
                guard !text.isEmpty else { continue }
                let side = d.trimmedAttribute("placement") ?? placement
                out.append(RawMark(kind: .dynamic(text), at: moved, staff: staff, above: side.map { $0 == "above" }))
            }
        }
        return out
    }

    /// Pairs starts with stops, stamps the shifted notes' `displayOctaves` and fills the part's
    /// octave lines, pedals, wedges and dynamics. Anything never stopped ends with the part.
    func pairMarks(_ marks: [RawMark], into part: inout Part) {
        guard let last = part.measures.last else { return }
        let partEnd = ScorePosition(measure: last.index, onset: last.duration)
        // Time order; at one position stops come before starts, so a line can end where the next begins.
        func isStop(_ m: RawMark) -> Bool {
            switch m.kind {
            case .octaveShift(let t, _, _): t == "stop"
            case .pedal(let t, _, _): t == "stop" || t == "discontinue"
            case .wedge(let t, _): t == "stop"
            case .dynamic, .words: false
            case .dashes(let t, _): t == "stop"
            }
        }
        let ordered = marks.enumerated().sorted { a, b in
            if a.element.at != b.element.at { return a.element.at < b.element.at }
            if isStop(a.element) != isStop(b.element) { return isStop(a.element) }
            return a.offset < b.offset
        }.map(\.element)

        struct Key: Hashable { var staff: Int; var number: Int }
        var openDashes: [Key: (at: ScorePosition, above: Bool?)] = [:]
        var openShift: [Key: (at: ScorePosition, octaves: Int)] = [:]
        var openWedge: [Key: (at: ScorePosition, cresc: Bool, above: Bool)] = [:]
        var pedal: (start: ScorePosition, changes: [ScorePosition], line: Bool, sign: Bool)?
        func closePedal(_ end: ScorePosition, released: Bool) {
            guard let p = pedal else { return }
            part.pedals.append(Pedal(start: p.start, end: end, changes: p.changes, line: p.line, startSign: p.sign, released: released))
            pedal = nil
        }
        for m in ordered {
            switch m.kind {
            case .octaveShift(let type, let number, let octaves):
                let k = Key(staff: m.staff, number: number)
                if type == "stop" {
                    if let o = openShift.removeValue(forKey: k) {
                        part.octaveShifts.append(OctaveShift(staff: m.staff, start: o.at, end: m.at, octaves: o.octaves))
                    }
                } else if type == "up" || type == "down" {
                    // A new line of the same number ends the open one where it starts.
                    if let o = openShift[k] { part.octaveShifts.append(OctaveShift(staff: m.staff, start: o.at, end: m.at, octaves: o.octaves)) }
                    openShift[k] = (m.at, octaves)
                }
            case .pedal(let type, let line, let sign):
                switch type {
                case "start", "sostenuto", "resume":
                    closePedal(m.at, released: true)
                    // MusicXML: `line` defaults to no, and `sign` to the opposite of `line`.
                    let l = line ?? false
                    // `resume` continues a pedal: its sign is only printed when the file says so.
                    pedal = (m.at, [], l, type == "resume" ? (sign ?? false) : (sign ?? !l))
                case "change":
                    if pedal != nil { pedal!.changes.append(m.at) }
                    else { let l = line ?? false; pedal = (m.at, [], l, sign ?? !l) }
                case "stop": closePedal(m.at, released: true)
                case "discontinue": closePedal(m.at, released: false)
                default: break
                }
            case .wedge(let type, let number):
                let k = Key(staff: m.staff, number: number)
                if type == "stop" {
                    if let w = openWedge.removeValue(forKey: k) {
                        part.wedges.append(Wedge(staff: m.staff, start: w.at, end: m.at, crescendo: w.cresc, above: w.above))
                    }
                } else if type == "crescendo" || type == "diminuendo" {
                    if let w = openWedge[k] { part.wedges.append(Wedge(staff: m.staff, start: w.at, end: m.at, crescendo: w.cresc, above: w.above)) }
                    openWedge[k] = (m.at, type == "crescendo", m.above ?? false)
                }
            case .dynamic(let text):
                part.dynamics.append(Dynamic(staff: m.staff, at: m.at, text: text, above: m.above ?? false))
            case .words(let text):
                part.words.append(TextMark(staff: m.staff, at: m.at, text: text, above: m.above))
            case .dashes(let type, let number):
                let k = Key(staff: m.staff, number: number)
                if type == "stop" {
                    if let o = openDashes.removeValue(forKey: k), m.at > o.at { part.dashes.append(DashLine(staff: m.staff, start: o.at, end: m.at, above: o.above)) }
                } else if type == "start" { openDashes[k] = (m.at, m.above) }
            }
        }
        for (k, o) in openShift { part.octaveShifts.append(OctaveShift(staff: k.staff, start: o.at, end: partEnd, octaves: o.octaves)) }
        for (k, w) in openWedge { part.wedges.append(Wedge(staff: k.staff, start: w.at, end: partEnd, crescendo: w.cresc, above: w.above)) }
        closePedal(partEnd, released: false)
        part.octaveShifts.sort { ($0.start, $0.staff) < ($1.start, $1.staff) }
        part.wedges.sort { ($0.start, $0.staff) < ($1.start, $1.staff) }

        for s in part.octaveShifts {
            for mi in s.start.measure...min(s.end.measure, part.measures.count - 1) {
                // A voice that lives mainly on another staff (an arpeggio crossing over) is not shifted
                // there: MuseScore and the printed editions leave such notes at their own height.
                var perStaff: [String: [Int: Int]] = [:]
                for n in part.measures[mi].notes { perStaff[n.voice, default: [:]][n.staff, default: 0] += 1 }
                for ni in part.measures[mi].notes.indices {
                    let n = part.measures[mi].notes[ni]
                    let pos = ScorePosition(measure: mi, onset: n.onset)
                    let counts = perStaff[n.voice] ?? [:]
                    let main = counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
                    if n.staff == s.staff, main == s.staff, pos >= s.start, pos < s.end { part.measures[mi].notes[ni].displayOctaves = s.octaves }
                }
            }
        }
    }
}

extension MusicXMLParser {
    /// The articulations, fermata, arpeggio, ornaments and tremolo of one `<notations>`.
    func parseEmbellishments(_ notations: XNode, into n: inout Note) {
        func side(_ e: XNode) -> Bool? { e.trimmedAttribute("placement").flatMap { ["above": true, "below": false][$0] } }
        for a in notations.children(named: "articulations") {
            for e in a.children {
                let kind: ArticulationMark.Kind? = switch e.name {
                case "staccato": .staccato
                case "staccatissimo": .staccatissimo
                case "accent": .accent
                case "strong-accent": .strongAccent
                case "tenuto": .tenuto
                case "detached-legato": .tenutoStaccato
                default: nil
                }
                if let kind { n.articulations.append(ArticulationMark(kind: kind, above: side(e))) }
            }
        }
        if let f = notations.child(named: "fermata") { n.fermata = FermataMark(inverted: f.trimmedAttribute("type") == "inverted") }
        if let a = notations.child(named: "arpeggiate") {
            n.arpeggio = ArpeggioMark(number: a.trimmedAttribute("number").flatMap { Int($0) } ?? 1,
                                      up: a.trimmedAttribute("direction").flatMap { ["up": true, "down": false][$0] })
        }
        for o in notations.children(named: "ornaments") {
            // An accidental-mark belongs to the ornament before it, or else to the next one.
            var pending: (name: String, above: Bool?)?
            for e in o.children {
                let kind: OrnamentMark.Kind? = switch e.name {
                case "trill-mark": .trill
                case "mordent": .mordent
                case "inverted-mordent": .invertedMordent
                case "turn": .turn
                case "inverted-turn": .invertedTurn
                default: nil
                }
                if let kind {
                    var m = OrnamentMark(kind: kind, above: side(e))
                    if let p = pending { m.accidental = p.name; m.accidentalAbove = p.above; pending = nil }
                    n.ornaments.append(m)
                } else if e.name == "accidental-mark", let name = Self.nonEmpty(e.text) {
                    if n.ornaments.isEmpty || n.ornaments[n.ornaments.count - 1].accidental != nil { pending = (name, side(e)) }
                    else { n.ornaments[n.ornaments.count - 1].accidental = name; n.ornaments[n.ornaments.count - 1].accidentalAbove = side(e) }
                } else if e.name == "wavy-line" {
                    let kind: WavyMark.Kind? = switch e.trimmedAttribute("type") {
                    case "start": .start
                    case "stop": .stop
                    case "continue": .continue
                    default: nil
                    }
                    if let kind { n.wavyLines.append(WavyMark(kind: kind, number: e.trimmedAttribute("number").flatMap { Int($0) } ?? 1)) }
                } else if e.name == "tremolo" {
                    let kind: TremoloMark.Kind = switch e.trimmedAttribute("type") {
                    case "start": .start
                    case "stop": .stop
                    default: .single
                    }
                    if let k = Int(e.text.trimmingCharacters(in: .whitespacesAndNewlines)), (1...8).contains(k) {
                        n.tremolo = TremoloMark(kind: kind, marks: k)
                    }
                }
            }
        }
    }
}
