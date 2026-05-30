import Foundation
import Yams

public enum YAMLConfigError: Error, Equatable, Sendable, LocalizedError {
    /// Yams couldn't parse the text. `detail` carries Yams' message (with line
    /// context) verbatim so the editor can show an inline parse-error banner.
    case parseFailed(String)
    /// The document parsed but its root wasn't a mapping. A config document is
    /// always an object, so a bare list/scalar at the root is rejected before
    /// any PUT.
    case notAnObject

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let detail):
            return "Couldn't parse YAML: \(detail)"
        case .notAnObject:
            return "Config must be a YAML mapping (key: value), not a list or scalar."
        }
    }
}

/// Converts between the editable YAML pane's text and the `JSONValue` the rest
/// of the config pipeline speaks. Parsing goes through Yams (the same parser
/// ``HermesConfigDocument`` uses) so scalar typing and error reporting match the
/// existing config surfaces; a parse failure throws so the harness never PUTs
/// unparseable text.
public enum YAMLConfigCodec {
    /// Parses YAML config text into a `JSONValue` object. Throws
    /// ``YAMLConfigError/parseFailed(_:)`` on malformed YAML and
    /// ``YAMLConfigError/notAnObject`` when the root isn't a mapping.
    public static func jsonValue(fromYAML text: String) throws -> JSONValue {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw YAMLConfigError.parseFailed(String(describing: error))
        }
        // Blank / comments-only document → empty config object.
        guard let node else { return .object([:]) }
        guard case .mapping = node else {
            throw YAMLConfigError.notAnObject
        }
        return convert(node)
    }

    /// Renders a `JSONValue` object as YAML text for display in the editable
    /// pane. Whole numbers serialize without a trailing `.0`.
    public static func yaml(from value: JSONValue) throws -> String {
        do {
            return try Yams.dump(object: anyValue(value))
        } catch {
            throw YAMLConfigError.parseFailed(String(describing: error))
        }
    }

    // MARK: - Node → JSONValue

    private static func convert(_ node: Node) -> JSONValue {
        switch node {
        case .scalar(let scalar):
            return scalarValue(scalar)
        case .mapping(let mapping):
            var object: [String: JSONValue] = [:]
            for (keyNode, valueNode) in mapping {
                guard let key = keyNode.string else { continue }
                object[key] = convert(valueNode)
            }
            return .object(object)
        case .sequence(let sequence):
            return .array(sequence.map(convert))
        case .alias:
            return .null
        }
    }

    /// Infers a JSON scalar type from a YAML scalar, honoring explicit quoting
    /// (a quoted scalar is always a string, even if it looks numeric/boolean).
    private static func scalarValue(_ scalar: Node.Scalar) -> JSONValue {
        if scalar.style == .singleQuoted || scalar.style == .doubleQuoted {
            return .string(scalar.string)
        }
        let node = Node.scalar(scalar)
        let text = scalar.string
        if text.isEmpty { return .null }
        if let bool = node.bool { return .bool(bool) }
        if let int = node.int { return .number(Double(int)) }
        if let double = node.float { return .number(double) }
        if ["null", "Null", "NULL", "~"].contains(text) { return .null }
        return .string(text)
    }

    // MARK: - JSONValue → Any (for Yams.dump)

    private static func anyValue(_ value: JSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 {
                return Int(number)
            }
            return number
        case .string(let string):
            return string
        case .array(let array):
            return array.map(anyValue)
        case .object(let object):
            return object.mapValues(anyValue)
        }
    }
}
