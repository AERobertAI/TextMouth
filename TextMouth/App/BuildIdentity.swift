import Foundation

/// Immutable provenance embedded in each app bundle. Startup diagnostics use
/// this instead of file modification dates, which can change during copying.
struct BuildIdentity: Equatable {
    let version: String
    let buildNumber: String
    let gitCommit: String
    let buildDate: String
    let configuration: String
    let executablePath: String

    /// Reads build metadata from an arbitrary dictionary for deterministic
    /// tests and from Bundle.main in production.
    init(info: [String: Any], executablePath: String?) {
        version = Self.normalized(info["CFBundleShortVersionString"]) ?? "unknown"
        buildNumber = Self.normalized(info["CFBundleVersion"]) ?? "unknown"
        gitCommit = Self.normalized(info["TextMouthGitCommit"]) ?? "unknown"
        buildDate = Self.normalized(info["TextMouthBuildDate"]) ?? "unknown"
        configuration = Self.normalized(info["TextMouthBuildConfiguration"]) ?? "unknown"
        self.executablePath = executablePath ?? "unknown"
    }

    static var current: BuildIdentity {
        BuildIdentity(
            info: Bundle.main.infoDictionary ?? [:],
            executablePath: Bundle.main.executableURL?.path
        )
    }

    /// A single searchable line keeps support log collection screen-reader
    /// friendly and avoids requiring bundle inspection.
    var diagnosticLine: String {
        "BUILD_IDENTITY "
            + "version=\(version) build=\(buildNumber) configuration=\(configuration) "
            + "commit=\(gitCommit) builtAt=\(buildDate) executable=\(executablePath)"
    }

    /// Treats unresolved Xcode substitutions as missing rather than logging a
    /// misleading literal such as "$(TEXTMOUTH_GIT_COMMIT)".
    private static func normalized(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.isEmpty,
              !string.contains("$(") else {
            return nil
        }
        return string
    }
}

