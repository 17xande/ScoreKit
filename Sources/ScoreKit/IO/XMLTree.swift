import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A parsed XML element: an immutable tree node. (Named `XNode` so it doesn't
/// clash with Foundation's `XMLElement`.)
public struct XNode: Sendable, Equatable {
    public let name: String
    public let attributes: [String: String]
    public let children: [XNode]
    /// Character data directly inside this element, untrimmed.
    public let rawText: String
    /// Line in the source where the element starts (0 when built by hand).
    public let line: Int

    public init(name: String, attributes: [String: String] = [:], children: [XNode] = [],
                rawText: String = "", line: Int = 0) {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.rawText = rawText
        self.line = line
    }

    /// Parse a document and return its root element. Never touches the
    /// network or the file system: DTDs and external entities are not loaded.
    /// Internal DTD entities are not expanded on Linux (libxml2 via
    /// FoundationXML reports them as errors); Darwin's parser expands them.
    /// MusicXML doesn't use custom entities, so that is acceptable, and it
    /// keeps entity-expansion bombs from doing any work.
    public static func parse(_ data: Data) throws -> XNode {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let e = parser.parserError as NSError?
            let detail = builder.failure ?? e?.localizedDescription ?? "no root element"
            throw ScoreKitError.badXML(line: parser.lineNumber, detail: detail)
        }
        return root
    }

    public func child(named n: String) -> XNode? { children.first { $0.name == n } }
    public func children(named n: String) -> [XNode] { children.filter { $0.name == n } }
    public func attribute(_ n: String) -> String? { attributes[n] }
    /// An attribute with surrounding whitespace removed.
    public func trimmedAttribute(_ n: String) -> String? {
        attributes[n]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Character data with surrounding whitespace removed. MusicXML elements
    /// hold either text or child elements, so for the rare mixed case all the
    /// element's own text runs are simply joined.
    public var text: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var int: Int? { Int(text) }
    public var double: Double? { Double(text) }

    /// Follow a path of child names: `root.child("part-list", "score-part")`.
    public func child(_ path: String...) -> XNode? {
        var node: XNode? = self
        for n in path { node = node?.child(named: n) }
        return node
    }
}

/// SAX delegate that assembles the tree with a stack of in-progress elements.
private final class TreeBuilder: NSObject, XMLParserDelegate {
    private struct Open {
        var name: String
        var attributes: [String: String]
        var line: Int
        var children: [XNode] = []
        var text = ""
    }
    private var stack: [Open] = []
    var root: XNode?
    var failure: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        stack.append(Open(name: name, attributes: attributes, line: parser.lineNumber))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if !stack.isEmpty { stack[stack.count - 1].text += String(decoding: data, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let o = stack.popLast() else { return }
        let node = XNode(name: o.name, attributes: o.attributes, children: o.children, rawText: o.text, line: o.line)
        if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        failure = error.localizedDescription
    }
}
