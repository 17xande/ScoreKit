import Foundation
import ScoreKit

// Debug tool: lays a MusicXML/.mxl score out and writes the result as SVG to stdout.
//   swift run scorekit-svg <file.musicxml|.mxl> [--width N | --line] [--font path] [--fingering] > out.svg
// Glyphs are <text font-family="Bravura"> using an @font-face for the app's Bravura.otf.
// 1 staff space = `scale` user units.

let scale = 10.0

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

var path: String?
var options = LayoutOptions(width: .fixed(80))
// Font: --font, else $SCOREKIT_FONT, else no @font-face (the viewer's installed Bravura is used).
var fontPath: String? = ProcessInfo.processInfo.environment["SCOREKIT_FONT"]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--width":
        guard let v = args.first.flatMap(Double.init) else { fail("--width needs a number (staff spaces)") }
        args.removeFirst()
        options.width = .fixed(v)
    case "--line": options.width = .singleLine
    case "--font":
        guard let v = args.first else { fail("--font needs a path") }
        args.removeFirst()
        fontPath = v
    case "--fingering": options.showFingering = true
    case "--no-numbers": options.showMeasureNumbers = false
    default:
        if a.hasPrefix("--") { fail("unknown option \(a)") }
        path = a
    }
}
guard let path else {
    fail("usage: scorekit-svg <file.musicxml|.mxl> [--width N | --line] [--font path] [--fingering] [--no-numbers] > out.svg")
}

let score: Score
do {
    score = try Score.load(data: try Data(contentsOf: URL(fileURLWithPath: path)))
} catch {
    fail("cannot load \(path): \(error)")
}
let layout = score.layout(options)

func n(_ v: Double) -> String {
    let r = (v * 1000).rounded() / 1000
    return r == r.rounded() ? String(Int(r)) : String(r)
}
func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
}
func attr(_ id: NoteID?, _ group: NoteID? = nil) -> String {
    (id.map { " data-note=\"\($0.value)\"" } ?? "") + (group.map { " data-group=\"\($0.value)\"" } ?? "")
}

func pathData(_ els: [PathElement]) -> String {
    els.map { e -> String in
        switch e {
        case .move(let p): "M\(n(p.x)) \(n(p.y))"
        case .line(let p): "L\(n(p.x)) \(n(p.y))"
        case .quad(let to, let c): "Q\(n(c.x)) \(n(c.y)) \(n(to.x)) \(n(to.y))"
        case .curve(let to, let c1, let c2): "C\(n(c1.x)) \(n(c1.y)) \(n(c2.x)) \(n(c2.y)) \(n(to.x)) \(n(to.y))"
        case .close: "Z"
        }
    }.joined(separator: " ")
}

let fontFace: String = {
    guard let fontPath else { return "" }
    return "@font-face { font-family: \"Bravura\"; src: url(\"\(URL(fileURLWithPath: fontPath).absoluteString)\"); }"
}()

var out = """
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="\(n(layout.size.width * scale))" height="\(n(layout.size.height * scale))" viewBox="0 0 \(n(layout.size.width)) \(n(layout.size.height))">
<style>
\(fontFace)
text.g { font-family: "Bravura"; font-size: 4px; }
text.t { font-family: serif; }
</style>
<rect width="100%" height="100%" fill="white"/>

"""
for (i, sys) in layout.systems.enumerated() {
    out += "<g id=\"system\(i)\">\n"
    for item in sys.items {
        switch item {
        case .glyph(let cp, let p, let size, let id, let gid):
            let fs = size.map { " style=\"font-size:\(n($0))px\"" } ?? ""
            out += "<text class=\"g\" x=\"\(n(p.x))\" y=\"\(n(p.y))\"\(fs)\(attr(id, gid))>&#x\(String(cp, radix: 16, uppercase: true));</text>\n"
        case .line(let a, let b, let t, let id, let gid):
            out += "<line x1=\"\(n(a.x))\" y1=\"\(n(a.y))\" x2=\"\(n(b.x))\" y2=\"\(n(b.y))\" stroke=\"black\" stroke-width=\"\(n(t))\"\(attr(id, gid))/>\n"
        case .rect(let r, let id, let gid):
            out += "<rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\"\(attr(id, gid))/>\n"
        case .text(let s, let p, let st):
            let anchor = ["start", "middle", "end"][[TextStyle.Anchor.start, .middle, .end].firstIndex(of: st.anchor)!]
            out += "<text class=\"t\" x=\"\(n(p.x))\" y=\"\(n(p.y))\" font-size=\"\(n(st.size))\" text-anchor=\"\(anchor)\"\(st.italic ? " font-style=\"italic\"" : "")\(st.bold ? " font-weight=\"bold\"" : "")>\(esc(s))</text>\n"
        case .beam(let els, let bid):
            out += "<path d=\"\(pathData(els))\" fill=\"black\" data-beam=\"\(bid.value)\"/>\n"
        case .path(let els, let stroke, let fill, let id, let gid):
            out += "<path d=\"\(pathData(els))\" fill=\"\(fill ? "black" : "none")\"\(stroke.map { " stroke=\"black\" stroke-width=\"\(n($0))\"" } ?? "")\(attr(id, gid))/>\n"
        }
    }
    out += "</g>\n"
}
// Debug aid: notehead boxes, only with SCOREKIT_BOXES=1.
if ProcessInfo.processInfo.environment["SCOREKIT_BOXES"] == "1" {
    for r in layout.noteBoxes.values {
        out += "<rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" fill=\"none\" stroke=\"red\" stroke-width=\"0.05\"/>\n"
    }
}
out += "</svg>\n"
FileHandle.standardOutput.write(Data(out.utf8))
