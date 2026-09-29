import Foundation

/// Decodes the fields of one JSON object that people, or other versions of
/// TextMouth, may have edited.
///
/// A missing or null field quietly takes its default. A field of the wrong
/// type, a number too large to represent, or a value its rule rejects is
/// replaced and logged once, instead of failing the whole object: one bad
/// field must never discard the fields around it.
struct LenientFields<Key: CodingKey> {
    /// The object being decoded.
    private let container: KeyedDecodingContainer<Key>
    /// Names the data in log lines, such as "config.json".
    private let source: String

    /// Wraps `container`; `source` names the data in log lines.
    init(_ container: KeyedDecodingContainer<Key>, source: String) {
        self.container = container
        self.source = source
    }

    /// Decodes `key` and returns it after `validate`.
    ///
    /// - Parameters:
    ///   - fallback: The value when the field is missing or null, and also
    ///     when it is unreadable unless `unreadableFallback` says otherwise.
    ///   - unreadableFallback: A separate replacement for an unreadable
    ///     field, for a field whose default would make the app do work the
    ///     file never asked for.
    ///   - supported: Describes the accepted values in log lines.
    ///   - validate: Maps a decoded value to a supported one.
    func value<T: Decodable & Equatable>(
        _ key: Key,
        default fallback: T,
        ifUnreadable unreadableFallback: T? = nil,
        supported: String? = nil,
        validate: (T) -> T = { $0 }
    ) -> T {
        switch read(T.self, forKey: key) {
        case .missing:
            return fallback
        case .unreadable:
            let replacement = unreadableFallback ?? fallback
            log(key, "could not be read as \(T.self); using \(StoredValueRepair.describe(replacement))",
                supported: supported)
            return replacement
        case .decoded(let value):
            return repaired(value, forKey: key, supported: supported) { validate($0) } ?? fallback
        }
    }

    /// Decodes an optional `key`. `validate` returns nil to drop a value the
    /// field can never hold; a missing, null, or unreadable field is nil too.
    func optionalValue<T: Decodable & Equatable>(
        _ key: Key,
        validate: (T) -> T?
    ) -> T? {
        switch read(T.self, forKey: key) {
        case .missing:
            return nil
        case .unreadable:
            log(key, "could not be read as \(T.self); using no value", supported: nil)
            return nil
        case .decoded(let value):
            return repaired(value, forKey: key, supported: nil, validate: validate)
        }
    }

    // MARK: - Private

    /// What decoding one field produced.
    private enum Reading<Value> {
        case missing
        case unreadable
        case decoded(Value)
    }

    /// Decodes `key` without throwing. Missing and null fields are `.missing`;
    /// a wrong type or an unrepresentable number is `.unreadable`.
    private func read<T: Decodable>(_ type: T.Type, forKey key: Key) -> Reading<T> {
        do {
            guard let value = try container.decodeIfPresent(type, forKey: key) else { return .missing }
            return .decoded(value)
        } catch {
            return .unreadable
        }
    }

    /// Validates a decoded field, logging when validation changed it.
    private func repaired<T: Equatable>(
        _ value: T,
        forKey key: Key,
        supported: String?,
        validate: (T) -> T?
    ) -> T? {
        StoredValueRepair.validated(
            value,
            source: source,
            codingPath: container.codingPath + [key],
            supported: supported,
            validate: validate
        )
    }

    /// Logs one repair of `key`.
    private func log(_ key: Key, _ detail: String, supported: String?) {
        StoredValueRepair.log(
            source: source,
            codingPath: container.codingPath + [key],
            detail: detail,
            supported: supported
        )
    }
}

// MARK: - Settings fields

extension LenientFields {
    /// A `config.json` number validated by `rule`. A missing, null, or
    /// unreadable field is the rule's config default; any other number is
    /// validated, which keeps the unset value and clamps the rest.
    func number(_ key: Key, rule: NumericSettingRule) -> Double {
        value(key, default: rule.configDefault, supported: rule.supportedDescription,
              validate: rule.validatedConfigValue)
    }

    /// A `config.json` raw value for an enum-backed preference. A missing,
    /// unreadable, or unsupported value becomes "" ("not chosen yet"), so
    /// applying the file keeps the app's current choice.
    func rawChoice<Value>(_ key: Key, rule: EnumSettingRule<Value>) -> String {
        value(key, default: "", supported: rule.supportedDescription,
              validate: rule.validatedConfigRawValue)
    }

    /// An enum-typed field stored as its raw value: the rule's default when
    /// the field is missing, unreadable, or names no case.
    func choice<Value>(_ key: Key, rule: EnumSettingRule<Value>) -> Value {
        let defaultRawValue = rule.defaultValue.rawValue
        let rawValue = value(key, default: defaultRawValue, supported: rule.supportedDescription) {
            Value(rawValue: $0) == nil ? defaultRawValue : $0
        }
        return rule.value(fromRaw: rawValue)
    }
}

// MARK: - Saved book state fields

extension LenientFields {
    /// A chapter index or character offset every saved position has: 0 when
    /// the field is missing or unreadable (a number no `Int` can hold, for
    /// example), and never negative.
    func position(_ key: Key) -> Int {
        value(key, default: 0, validate: SettingsPolicy.validatedPosition)
    }

    /// An optional index or offset, never negative; nil when the field is
    /// missing or unreadable.
    func optionalPosition(_ key: Key) -> Int? {
        optionalValue(key) { SettingsPolicy.validatedPosition($0) }
    }
}

// MARK: - Repair log

/// Records every repair of a stored value in the debug log, so a preference
/// or a reading position that changed while loading can be traced to the
/// value that was on disk.
enum StoredValueRepair {
    /// Returns `validate(value)`, logging one line when validation changed it.
    static func validated<T: Equatable>(
        _ value: T,
        source: String,
        codingPath: [CodingKey],
        supported: String? = nil,
        validate: (T) -> T?
    ) -> T? {
        let validated = validate(value)
        if validated != value {
            let replacement = validated.map { describe($0) } ?? "no value"
            log(source: source, codingPath: codingPath,
                detail: "replaced unsupported value \(describe(value)) with \(replacement)",
                supported: supported)
        }
        return validated
    }

    /// Appends one repair line to the debug log. Logging runs on a background
    /// queue, so this is safe from any thread and never blocks decoding.
    static func log(source: String, codingPath: [CodingKey], detail: String, supported: String? = nil) {
        var message = "STORED_VALUE_REPAIRED \(source) \(pathDescription(codingPath)): \(detail)"
        if let supported {
            message += " (supported: \(supported))"
        }
        TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: message)
    }

    /// A value as log lines show it: text is quoted, so an empty string is
    /// visible as "".
    static func describe<Value>(_ value: Value) -> String {
        String(reflecting: value)
    }

    /// Renders a coding path the way it reads in the file, for example
    /// `books[3].readingPosition.characterOffset`.
    static func pathDescription(_ codingPath: [CodingKey]) -> String {
        codingPath.reduce(into: "") { path, key in
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }
}
