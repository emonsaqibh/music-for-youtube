import Foundation

/// A dynamic JSON value.
///
/// InnerTube responses are deeply nested trees of "renderer" objects whose shape
/// shifts between YouTube releases. Modelling every renderer with `Codable` would
/// break constantly, so we keep the raw tree and traverse it defensively — the same
/// strategy the community Python clients use.
enum JSONError: Error { case notUTF8 }

enum JSON: Sendable, Equatable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

// MARK: - Decoding

extension JSON: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSON].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSON].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrepresentable JSON value")
        }
    }

    /// Parses with `JSONSerialization` rather than the `Decodable` conformance above:
    /// decoding by trial (`try?` Bool, then Double, then String…) throws and catches at
    /// nearly every node, and took ~0.6s on a typical 1.3MB Home response, against ~0.05s
    /// here.
    init(parsing text: String) throws {
        guard let data = text.data(using: .utf8) else { throw JSONError.notUTF8 }
        self = JSON(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private init(foundation value: Any) {
        switch value {
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            // JSON booleans arrive as NSNumber too; only the CF type tells them apart.
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]:
            self = .array(a.map(JSON.init(foundation:)))
        case let o as [String: Any]:
            self = .object(o.mapValues(JSON.init(foundation:)))
        default:
            self = .null
        }
    }
}

// MARK: - Access

extension JSON {
    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    /// Follows a dotted path, e.g. `json["a.b.0.c"]` — convenient for the long
    /// renderer chains InnerTube returns.
    subscript(path path: String) -> JSON {
        path.split(separator: ".").reduce(self) { node, part in
            if let i = Int(part) { return node[i] }
            return node[String(part)]
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var intValue: Int? { doubleValue.map(Int.init) }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }

    var arrayValue: [JSON] { if case .array(let a) = self { return a }; return [] }
    var objectValue: [String: JSON] { if case .object(let o) = self { return o }; return [:] }

    var exists: Bool { self != .null }

    /// YouTube renders every piece of display text as either `{simpleText:}` or
    /// `{runs:[{text:}]}`. This flattens both.
    var text: String? {
        if let s = self["simpleText"].stringValue { return s }
        let runs = self["runs"].arrayValue.compactMap { $0["text"].stringValue }
        if !runs.isEmpty { return runs.joined() }
        return stringValue
    }
}

// MARK: - Search

extension JSON {
    /// Depth-first search for the first value stored under `key` anywhere below this node.
    func first(_ key: String) -> JSON? {
        switch self {
        case .object(let o):
            if let hit = o[key] { return hit }
            for (_, v) in o { if let hit = v.first(key) { return hit } }
        case .array(let a):
            for v in a { if let hit = v.first(key) { return hit } }
        default: break
        }
        return nil
    }

    /// Every value stored under `key` anywhere below this node, in document order.
    func all(_ key: String) -> [JSON] {
        var out: [JSON] = []
        collect(key, into: &out)
        return out
    }

    private func collect(_ key: String, into out: inout [JSON]) {
        switch self {
        case .object(let o):
            // Array order (which is what carries shelf/track ordering) is preserved
            // below; sorting sibling keys just makes the walk deterministic.
            if let hit = o[key] { out.append(hit) }
            for k in o.keys.sorted() where k != key { o[k]!.collect(key, into: &out) }
        case .array(let a):
            for v in a { v.collect(key, into: &out) }
        default: break
        }
    }
}
