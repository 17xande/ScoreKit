import Foundation

/// Everything that can go wrong reading a score, with messages fit to show.
public enum ScoreKitError: Error, Equatable, LocalizedError {
    case notAScore
    case badZip(String)
    case unsupportedZip(String)
    case badDeflate(String)
    case crcMismatch(entry: String)
    case noScoreInArchive
    case tooLarge(entry: String)
    /// `line` is where parsing stopped; `detail` is the parser's own message, for logs.
    case badXML(line: Int, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notAScore: "This isn't a MusicXML file (.musicxml or .mxl)."
        case .badZip(let m): "The .mxl archive is damaged: \(m)."
        case .unsupportedZip(let m): "The .mxl archive uses an unsupported feature: \(m)."
        case .badDeflate(let m): "The compressed score data is damaged: \(m)."
        case .crcMismatch(let e): "The file \(e) in the .mxl archive is corrupt (checksum mismatch)."
        case .noScoreInArchive: "The .mxl archive doesn't contain a MusicXML score."
        case .tooLarge(let e): "The file \(e) in the .mxl archive is too large to be a score."
        case .badXML(let line, _): "This file isn't valid MusicXML (problem near line \(line))."
        }
    }
}
