import Foundation
import ZIPFoundation

/// Telling score files apart and getting at the XML inside them.
public enum ScoreFile {
    public enum Format: Sendable, Equatable {
        case mxl, musicxml
    }

    /// Which kind of file this is. The bytes decide, not the name: a zip by
    /// its "PK\3\4" signature, otherwise XML that opens a score-partwise or
    /// score-timewise element within the first 4 KB. Nil for anything else.
    public static func detect(_ data: Data) -> Format? {
        let b = [UInt8](data.prefix(4))
        if b == [0x50, 0x4B, 3, 4] { return .mxl }
        guard let head = headText(data) else { return nil }
        for tag in ["<score-partwise", "<score-timewise"] {
            guard let r = head.range(of: tag), r.upperBound < head.endIndex else { continue }
            // Must be the whole name: `<score-partwise>`, `<score-partwise version=`.
            let next = head[r.upperBound]
            if next.isWhitespace || next == ">" || next == "/" { return .musicxml }
        }
        return nil
    }

    /// The score XML, whether `data` is plain MusicXML or a zipped .mxl.
    public static func xmlData(from data: Data) throws -> Data {
        switch detect(data) {
        case .mxl: return try scoreXML(inArchive: data)
        case .musicxml: return data
        case nil: throw ScoreKitError.notAScore
        }
    }

    private static let musicXMLType = "application/vnd.recordare.musicxml+xml"
    /// The most one archive entry may unpack to. Real scores are well under
    /// 10 MB; this stops a zip bomb (or a lying header) cheaply.
    static let maxEntryBytes = 50 << 20

    /// The score inside an .mxl: the first container.xml rootfile that turns
    /// out to be MusicXML, else the first `.musicxml` (then `.xml`) outside
    /// META-INF and __MACOSX that does. Throws `noScoreInArchive` if none does.
    private static func scoreXML(inArchive data: Data) throws -> Data {
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) } catch {
            throw ScoreKitError.badZip("\(error)")
        }
        if let container = archive["META-INF/container.xml"],
           let root = try? XNode.parse(extract(container, from: archive)),
           let files = root.child("rootfiles")?.children(named: "rootfile") {
            for f in files {
                // A rootfile typed as something else (a PDF rendering, say) is skipped unread.
                if let t = f.trimmedAttribute("media-type"), t != musicXMLType { continue }
                if let path = f.trimmedAttribute("full-path"), let e = archive[path], e.type == .file {
                    let xml = try extract(e, from: archive)
                    if detect(xml) == .musicxml { return xml }
                }
            }
        }
        let candidates = archive.filter { e in
            let parts = e.path.split(separator: "/")
            return e.type == .file && !parts.contains("META-INF") && !parts.contains("__MACOSX")
        }
        for ext in ["musicxml", "xml"] {
            for e in candidates where (e.path as NSString).pathExtension.lowercased() == ext {
                let xml = try extract(e, from: archive)
                if detect(xml) == .musicxml { return xml }
            }
        }
        throw ScoreKitError.noScoreInArchive
    }

    private static func extract(_ entry: Entry, from archive: Archive) throws -> Data {
        guard entry.uncompressedSize <= UInt64(maxEntryBytes) else { throw ScoreKitError.tooLarge(entry: entry.path) }
        var out = Data()
        let crc: CRC32
        do {
            crc = try archive.extract(entry) { chunk in
                // The header's size can lie, so count what actually comes out.
                guard out.count + chunk.count <= maxEntryBytes else { throw ScoreKitError.tooLarge(entry: entry.path) }
                out.append(chunk)
            }
        } catch let e as ScoreKitError {
            throw e
        } catch Archive.ArchiveError.invalidCompressionMethod {
            throw ScoreKitError.unsupportedZip("compression method of \(entry.path)")
        } catch {
            throw ScoreKitError.badDeflate("\(entry.path): \(error)")
        }
        // The consumer overload returns the checksum but leaves comparing it to us.
        guard crc == entry.checksum else { throw ScoreKitError.crcMismatch(entry: entry.path) }
        return out
    }

    /// The first ~4 KB decoded as text, honouring a UTF-8 or UTF-16 BOM
    /// (UTF-16 has no ASCII bytes to search otherwise).
    private static func headText(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(4096))
        func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
            // Whole code units only; lossy decoding repairs a cut surrogate pair.
            let units = stride(from: bytes.startIndex, to: bytes.endIndex - 1, by: 2).map { i in
                bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i])
            }
            return String(decoding: units, as: UTF16.self)
        }
        if head.starts(with: [0xFF, 0xFE]) { return utf16(head.dropFirst(2), bigEndian: false) }
        if head.starts(with: [0xFE, 0xFF]) { return utf16(head.dropFirst(2), bigEndian: true) }
        let body = head.starts(with: [0xEF, 0xBB, 0xBF]) ? head.dropFirst(3) : head[...]
        return String(decoding: body, as: UTF8.self)
    }
}
