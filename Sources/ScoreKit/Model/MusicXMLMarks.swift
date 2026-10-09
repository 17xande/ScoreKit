import Foundation

/// One octave-shift, pedal, wedge or dynamics element, before its start and stop are paired.
struct RawMark {
    enum Kind {
        case octaveShift(type: String, number: Int, octaves: Int)
        case pedal(type: String, line: Bool?, sign: Bool?)
        case wedge(type: String, number: Int)
        case dynamic(String)
    }
    var kind: Kind
    var at: ScorePosition
    var staff: Int
    var above: Bool?
}

extension MusicXMLParser {
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
        for dt in el.children(named: "direction-type") {
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
            case .dynamic: false
            }
        }
        let ordered = marks.enumerated().sorted { a, b in
            if a.element.at != b.element.at { return a.element.at < b.element.at }
            if isStop(a.element) != isStop(b.element) { return isStop(a.element) }
            return a.offset < b.offset
        }.map(\.element)

        struct Key: Hashable { var staff: Int; var number: Int }
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
