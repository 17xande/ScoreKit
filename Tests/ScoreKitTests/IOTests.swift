import Foundation
import Testing
@testable import ScoreKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test("detect: bytes decide the format, not the name")
func detectFormats() throws {
    #expect(ScoreFile.detect(try fixture("minuet-in-g.mxl")) == .mxl)
    #expect(ScoreFile.detect(try fixture("minuet-in-g.musicxml")) == .musicxml)
    #expect(ScoreFile.detect(Data("hello world".utf8)) == nil)
    #expect(ScoreFile.detect(Data()) == nil)
    #expect(ScoreFile.detect(Data("<html><score-partwisely>".utf8)) == nil)
    #expect(ScoreFile.detect(Data("<score-timewise version=\"4.0\">".utf8)) == .musicxml)
}

@Test("detect: UTF-8 BOM and UTF-16 documents")
func detectEncodings() {
    let xml = "<?xml version=\"1.0\"?><score-partwise version=\"3.1\"></score-partwise>"
    #expect(ScoreFile.detect(Data([0xEF, 0xBB, 0xBF] + Array(xml.utf8))) == .musicxml)
    let le = Data([0xFF, 0xFE]) + xml.data(using: .utf16LittleEndian)!
    let be = Data([0xFE, 0xFF]) + xml.data(using: .utf16BigEndian)!
    #expect(ScoreFile.detect(le) == .musicxml)
    #expect(ScoreFile.detect(be) == .musicxml)
}

@Test("xmlData of an .mxl equals the original MusicXML",
      arguments: [("minuet-in-g.mxl", "minuet-in-g.musicxml"),
                  ("ode-to-joy.mxl", "ode-to-joy.musicxml"),
                  ("twinkle-twinkle-stored.mxl", "twinkle-twinkle.musicxml"),
                  ("bach-prelude-in-c-nocontainer.mxl", "bach-prelude-in-c.musicxml"),
                  ("subfolder.mxl", "ode-to-joy.musicxml"),
                  ("pdf-rootfile.mxl", "minuet-in-g.musicxml")])
func mxlRoundTrip(mxl: String, xml: String) throws {
    #expect(try ScoreFile.xmlData(from: try fixture(mxl)) == (try fixture(xml)))
}

@Test("xmlData of plain MusicXML is the bytes unchanged; garbage throws")
func xmlDataPlain() throws {
    let x = try fixture("ode-to-joy.musicxml")
    #expect(try ScoreFile.xmlData(from: x) == x)
    #expect(throws: ScoreKitError.notAScore) { try ScoreFile.xmlData(from: Data("nope".utf8)) }
}

/// Offset of the first entry's data whose local header names `name`.
private func dataOffset(of name: String, in d: Data) throws -> Int {
    let r = try #require(d.range(of: Data(name.utf8)))
    let header = r.lowerBound - 30
    #expect(Array(d[header..<header + 4]) == [0x50, 0x4B, 3, 4])
    return r.upperBound + Int(d[header + 28]) + Int(d[header + 29]) << 8
}

@Test("a truncated archive is a badZip error, not a crash")
func truncatedArchive() throws {
    let good = try fixture("minuet-in-g.mxl")
    for cut in [4, 10, 30, good.count / 2, good.count - 5] {
        let err = #expect(throws: ScoreKitError.self) { try ScoreFile.xmlData(from: good.prefix(cut)) }
        guard case .badZip? = err else { Issue.record("cut \(cut): \(String(describing: err))"); continue }
    }
}

@Test("damaged deflate data inside the score entry throws badDeflate or crcMismatch")
func damagedDeflate() throws {
    let good = try fixture("minuet-in-g.mxl")
    let start = try dataOffset(of: "minuet-in-g.musicxml", in: good)
    for off in [0, 1, 7, 100, 400] {
        var bad = good
        for i in 0..<8 { bad[start + off + i] ^= 0xA5 }
        let err = #expect(throws: ScoreKitError.self) { try ScoreFile.xmlData(from: bad) }
        switch err {
        case .badDeflate?, .crcMismatch?: break
        default: Issue.record("offset \(off): unexpected \(String(describing: err))")
        }
    }
}

@Test("random bytes after a zip signature never crash")
func randomArchives() {
    for seed in 0..<50 {
        var g = SeededGenerator(seed: UInt64(seed))
        var d = Data([0x50, 0x4B, 3, 4])
        d.append(contentsOf: (0..<200).map { _ in UInt8.random(in: 0...255, using: &g) })
        _ = try? ScoreFile.xmlData(from: d)
    }
}

@Test("an archive with only junk .xml files has no score")
func junkOnly() throws {
    #expect(throws: ScoreKitError.noScoreInArchive) { try ScoreFile.xmlData(from: try fixture("junk-only.mxl")) }
}

@Test("an entry larger than the cap is rejected")
func oversizedEntry() throws {
    // A stored entry whose header claims more than the cap.
    var d = try fixture("twinkle-twinkle-stored.mxl")
    let name = Data("twinkle-twinkle.musicxml".utf8)
    // Central directory copy of the name is the last occurrence; its header starts 46 bytes before.
    let r = try #require(d.range(of: name, options: .backwards))
    let h = r.lowerBound - 46
    #expect(Array(d[h..<h + 4]) == [0x50, 0x4B, 1, 2])
    let big = UInt32(ScoreFile.maxEntryBytes + 1)
    for i in 0..<4 { d[h + 24 + i] = UInt8((big >> (8 * UInt32(i))) & 0xFF) }
    let err = #expect(throws: ScoreKitError.self) { try ScoreFile.xmlData(from: d) }
    guard case .tooLarge? = err else { Issue.record("got \(String(describing: err))"); return }
}

@Test("a flipped byte in stored data is a CRC mismatch")
func crcMismatch() throws {
    var d = try fixture("twinkle-twinkle-stored.mxl")
    let marker = Data("<score-partwise".utf8)
    let r = try #require(d.range(of: marker))
    d[r.upperBound + 3] ^= 0x01
    #expect(throws: ScoreKitError.crcMismatch(entry: "twinkle-twinkle.musicxml")) {
        try ScoreFile.xmlData(from: d)
    }
}

@Test("XNode parses a starter and finds part-list/score-part")
func parseStarter() throws {
    let root = try XNode.parse(try fixture("minuet-in-g.musicxml"))
    #expect(root.name == "score-partwise")
    let part = try #require(root.child("part-list", "score-part"))
    #expect(part.attribute("id") != nil)
    #expect(!root.children(named: "part").isEmpty)
    let beats = root.child(named: "part")?.child("measure", "attributes", "time", "beats")
    #expect(beats?.int == 3)
}

@Test("XNode text helpers and CDATA")
func nodeHelpers() throws {
    let n = try XNode.parse(Data("<a x=\"1\"><b> 4.5 </b><c><![CDATA[hi]]></c><b>2</b></a>".utf8))
    #expect(n.attribute("x") == "1")
    #expect(n.children(named: "b").count == 2)
    #expect(n.child(named: "b")?.double == 4.5)
    #expect(n.child(named: "c")?.text == "hi")
    #expect(n.child(named: "zzz") == nil)
}

@Test("DOCTYPE with an external DTD is not fetched, and bad XML throws")
func doctypeNoNetwork() throws {
    // A DTD URL on a reserved, unroutable host: fetching it would stall or fail.
    let xml = """
    <?xml version="1.0"?>
    <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.1 Partwise//EN" "http://192.0.2.1/partwise.dtd">
    <score-partwise><part-list/></score-partwise>
    """
    let start = Date()
    let root = try XNode.parse(Data(xml.utf8))
    #expect(root.name == "score-partwise")
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(throws: ScoreKitError.self) { try XNode.parse(Data("<a><b></a>".utf8)) }
    #expect(throws: ScoreKitError.self) { try XNode.parse(Data()) }
}

@Test("XXE: an external file entity is not read")
func xxe() throws {
    let xml = """
    <?xml version="1.0"?>
    <!DOCTYPE score-partwise [<!ENTITY x SYSTEM "file:///etc/passwd">]>
    <score-partwise><work-title>&x;</work-title></score-partwise>
    """
    if let root = try? XNode.parse(Data(xml.utf8)) {
        #expect(root.child("work-title")?.text.range(of: "root:") == nil)
    }
}

@Test("billion laughs fails fast with badXML")
func billionLaughs() throws {
    var dtd = "<!ENTITY a0 \"lol\">"
    for i in 1...9 {
        dtd += "<!ENTITY a\(i) \"" + String(repeating: "&a\(i - 1);", count: 10) + "\">"
    }
    let xml = "<?xml version=\"1.0\"?><!DOCTYPE s [\(dtd)]><s>&a9;</s>"
    let start = Date()
    let err = #expect(throws: ScoreKitError.self) { try XNode.parse(Data(xml.utf8)) }
    guard case .badXML? = err else { Issue.record("got \(String(describing: err))"); return }
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test("badXML carries the line and a friendly message")
func badXMLMessage() {
    let err = #expect(throws: ScoreKitError.self) { try XNode.parse(Data("<a>\n<b>\n</a>".utf8)) }
    guard case .badXML(let line, let detail)? = err else { Issue.record("wrong error"); return }
    #expect(line >= 1 && !detail.isEmpty)
    #expect(err?.errorDescription?.contains("isn't valid MusicXML") == true)
}

@Test("XNode records source lines and trims attributes")
func lines() throws {
    let n = try XNode.parse(Data("<a>\n<b x=\" 1 \"/>\n</a>".utf8))
    #expect(n.child(named: "b")?.line == 2)
    #expect(n.child(named: "b")?.trimmedAttribute("x") == "1")
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
