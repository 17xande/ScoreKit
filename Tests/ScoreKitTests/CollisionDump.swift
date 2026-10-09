import Foundation
import Testing
@testable import ScoreKit

// Debug: SCOREKIT_DUMP_CLASHES=1 swift test --filter dumpClashes prints every clash of the piano parts.
@Test("dump clashes", .enabled(if: ProcessInfo.processInfo.environment["SCOREKIT_DUMP_CLASHES"] != nil))
func dumpClashes() throws {
    let names = ["boulanger-parfois-je-suis-triste", "grandval-les-clochettes", "satie-je-te-veux", "schumann-widmung", "stanford-sou-wester"]
    for n in names {
        let s = try Score.load(data: try fixture("complex/openscore/\(n).mxl"))
        let l = s.layout(pianoOptions(s, width: Double(ProcessInfo.processInfo.environment["W"] ?? "100")!))
        let cs = clashes(l)
        var byKind: [String: Int] = [:]
        for c in cs { byKind["\(c.a.kind)-\(c.b.kind)", default: 0] += 1 }
        print("CLASH \(n): \(cs.count) \(byKind.sorted { $0.key < $1.key })")
        if ProcessInfo.processInfo.environment["SCOREKIT_DUMP_CLASHES"] == "2" {
            for c in cs.sorted(by: { ($0.measure ?? 0) < ($1.measure ?? 0) }) { print("CLASH   \(c) A=\(c.a.rect) B=\(c.b.rect) groups \(c.a.group.value) \(c.b.group.value)") }
        }
    }
}

// Debug: SCOREKIT_DUMP_MARKS=1 (or 2 for every clash) swift test --filter dumpMarkClashes
@Test("dump mark clashes", .enabled(if: ProcessInfo.processInfo.environment["SCOREKIT_DUMP_MARKS"] != nil))
func dumpMarkClashes() throws {
    let names = ["boulanger-parfois-je-suis-triste", "grandval-les-clochettes", "satie-je-te-veux", "schumann-widmung", "stanford-sou-wester"]
    for n in names {
        let s = try Score.load(data: try fixture("complex/openscore/\(n).mxl"))
        for w in [80.0, 100.0] {
            let l = s.layout(pianoOptions(s, width: w))
            let cs = markClashes(l)
            var by: [String: Int] = [:]
            for c in cs { by["\(c.mark)x\(c.other)", default: 0] += 1 }
            let counts = l.systems.flatMap(\.marks).reduce(into: [String: Int]()) { $0["\($1.kind)", default: 0] += 1 }
            print("MARK \(n) w\(Int(w)): \(cs.count) \(by.sorted { $0.key < $1.key }) of \(counts.sorted { $0.key < $1.key })")
            if ProcessInfo.processInfo.environment["SCOREKIT_DUMP_MARKS"] == "2", w == 100 {
                for c in cs.prefix(60) { print("MARK   \(c)") }
            }
        }
    }
}
