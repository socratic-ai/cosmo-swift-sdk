import Foundation
import Testing

/// The generated `CosmoRealtimeAPI` module is an implementation detail of
/// the REST client and the send path: no generated type reaches the public
/// surface, and every public type is hand-declared in `CosmoRealtime`.
///
/// A `public typealias` into the generated module does not satisfy this even
/// though it publishes the right name. An alias exports the name, not the
/// members, so a consumer that imports only the `CosmoRealtime` product
/// cannot read a case or a `rawValue` off one under
/// `MemberImportVisibility`. `ConsumerProbe` builds that consumer.
@Suite struct GeneratedSurfaceExposureTests {
    /// Empty, and meant to stay that way — the field exists so a proposed
    /// exception has to be written down here rather than inlined.
    static let allowedAliases: Set<String> = []

    @Test func noGeneratedTypeReachesThePublicSurface() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // this file
            .deletingLastPathComponent()  // CosmoRealtimeTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Sources/CosmoRealtime", isDirectory: true)
        let files = FileManager.default
            .enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 10, "source walk found too few files — wrong root?")

        var aliases: Set<String> = []
        var violations: [String] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let raw = try String(contentsOf: file, encoding: .utf8).split(
                separator: "\n", omittingEmptySubsequences: false
            )
            // Join `public typealias X =` with its wrapped right-hand side so
            // a multi-line alias reads as one declaration.
            var lines: [String] = []
            for line in raw.map(String.init) {
                if let last = lines.last, last.hasSuffix("=") {
                    lines[lines.count - 1] = last + " " + line.trimmingCharacters(in: .whitespaces)
                } else {
                    lines.append(line)
                }
            }
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                guard trimmed.contains("CosmoRealtimeAPI") || trimmed.contains("Components.Schemas")
                else { continue }
                guard trimmed.contains("public") else { continue }
                if trimmed.hasPrefix("public typealias "),
                    let name = trimmed.dropFirst("public typealias ".count)
                        .split(separator: " ").first.map(String.init),
                    Self.allowedAliases.contains(name)
                {
                    aliases.insert(name)
                    continue
                }
                violations.append("\(file.lastPathComponent): \(trimmed)")
            }
        }
        #expect(
            violations.isEmpty,
            "generated types on the public surface:\n\(violations.joined(separator: "\n"))"
        )
        #expect(aliases == Self.allowedAliases, "allowlisted enum aliases drifted")
    }
}
