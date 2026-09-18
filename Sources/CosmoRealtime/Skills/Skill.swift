import Foundation

/// One skill (the Agent Skills standard): ``name`` + ``description`` are the
/// resident routing signal; ``body`` is loaded on demand via ``cosmo_sdk_load_skill``.
public struct Skill: Sendable, Equatable {
    /// How the skill is identified. Unique across the agent's skills.
    public let name: String
    /// What the skill is for. Stays resident in the model's context — this is
    /// what it reads to decide whether to load ``body`` at all, so it has to
    /// be specific enough to route on.
    public let description: String
    /// The skill's full text, loaded only once the model asks for it.
    public let body: String

    /// Creates a skill from its parts, bypassing `SKILL.md` parsing.
    public init(name: String, description: String, body: String) {
        self.name = name
        self.description = description
        self.body = body
    }
}

/// Stable codes clients match on to tell one skills failure from another.
///
/// The set is closed: every one is raised by this SDK, never by the server,
/// so it changes only when the SDK does.
public enum SkillErrorCode: String, Sendable, Equatable {
    /// The skills path does not point at a directory.
    case notADirectory = "not_a_directory"
    /// A `SKILL.md` exists but could not be read from disk.
    case cannotRead = "cannot_read"
    /// `SKILL.md` does not open with a `---` fence.
    case missingFrontmatter = "missing_frontmatter"
    /// The opening `---` fence is never closed.
    case unterminatedFrontmatter = "unterminated_frontmatter"
    /// A frontmatter line is not `key: value`.
    case malformedFrontmatterLine = "malformed_frontmatter_line"
    /// The same frontmatter key appears twice.
    case duplicateFrontmatterKey = "duplicate_frontmatter_key"
    /// Frontmatter has no `description`. It is the routing signal the model
    /// reads to decide whether to load the skill, so it is required.
    case missingDescription = "missing_description"
    /// Two skills resolved to the same name.
    case duplicateSkillName = "duplicate_skill_name"
}

/// The `skills` input is unusable: the path is not a directory, a SKILL.md
/// cannot be read or is malformed (no frontmatter, missing required field),
/// or two skills share a name.
///
/// ``code`` names which of those it was — match on it rather than on the
/// message, which is written for a human and is not part of the contract.
public struct SkillError: RealtimeError, LocalizedError, Equatable {
    /// Which failure it was. A closed set this SDK raises — switch on it
    /// rather than on the message.
    public let code: SkillErrorCode
    /// Human-readable explanation, for logs and display.
    public let message: String

    /// Creates a skill error.
    public init(code: SkillErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// The message, for `LocalizedError` presentation.
    /// The message, for `LocalizedError` presentation.
    /// The message, for `LocalizedError` presentation.
    public var errorDescription: String? { message }
}

/// Parse a SKILL.md document. ``defaultName`` is used when frontmatter omits
/// ``name`` (Agent Skills convention: default to the directory name). Unknown
/// frontmatter keys (``tier``, ``allowed-tools``, ``license``, …) are accepted
/// and ignored — including list-valued ones — and CRLF line endings are
/// normalized, so files authored for other harnesses stay valid.
public func parseSkillMd(_ text: String, defaultName: String) throws -> Skill {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard normalized.hasPrefix("---\n") else {
        throw SkillError(
            code: .missingFrontmatter,
            message: "SKILL.md must start with a '---' frontmatter fence"
        )
    }
    let afterOpen = String(normalized.dropFirst(4))
    let frontmatter: String
    let body: String
    if let range = afterOpen.range(of: "\n---\n") {
        frontmatter = String(afterOpen[..<range.lowerBound])
        body = String(afterOpen[range.upperBound...])
    } else if afterOpen.hasSuffix("\n---") {
        frontmatter = String(afterOpen.dropLast(4))
        body = ""
    } else {
        throw SkillError(
            code: .unterminatedFrontmatter,
            message: "SKILL.md frontmatter fence is not closed with '---'"
        )
    }

    var fields: [String: String] = [:]
    for rawLine in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        // A YAML list item under an ignored key (e.g. allowed-tools).
        if line == "-" || line.hasPrefix("- ") { continue }
        guard let colon = line.firstIndex(of: ":") else {
            throw SkillError(
                code: .malformedFrontmatterLine,
                message: "malformed frontmatter line: \(String(reflecting: line))"
            )
        }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if fields[key] != nil {
            throw SkillError(
                code: .duplicateFrontmatterKey,
                message: "duplicate frontmatter key: \(String(reflecting: key))"
            )
        }
        fields[key] = value
    }

    guard let description = fields["description"], !description.isEmpty else {
        throw SkillError(
            code: .missingDescription,
            message: "SKILL.md frontmatter must include a 'description'"
        )
    }
    let name = (fields["name"].map { $0.isEmpty ? defaultName : $0 }) ?? defaultName
    return Skill(
        name: name,
        description: description,
        body: body.trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

extension Array where Element == Skill {
    /// Skills read from a directory, for the ``skills:`` argument — a folder
    /// whose own ``SKILL.md`` exists IS that one skill, otherwise each
    /// ``<child>/SKILL.md`` is one. Mirrors the Python SDK, where the same
    /// directory is handed to ``skills=`` directly.
    ///
    ///     let agent = try client.agent(skills: .directory(skillsURL))
    ///     let agent = try client.agent(skills: .directory(url) + [inline])
    ///
    /// A directory yielding no skills returns empty — an unpopulated per-user
    /// skills folder is a valid state. A missing or unreadable path, or a
    /// malformed ``SKILL.md``, throws ``SkillError``.
    public static func directory(_ url: URL) throws -> [Skill] {
        try loadSkills(fromDirectory: url)
    }
}

/// The directory read behind ``Array/directory(_:)``.
func loadSkills(fromDirectory url: URL) throws -> [Skill] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        throw SkillError(
            code: .notADirectory,
            message: "skills path is not a directory: \(url.path)"
        )
    }
    let own = url.appendingPathComponent("SKILL.md")
    if fm.fileExists(atPath: own.path) {
        return [try parseSkillMd(readSkillFile(own), defaultName: url.lastPathComponent)]
    }
    let listing: [URL]
    do {
        listing = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
    } catch {
        throw SkillError(
            code: .cannotRead,
            message: "\(url.path): cannot list: \(error.localizedDescription)"
        )
    }
    // Only a directory can be a skill. `contentsOfDirectory` returns every
    // entry, so a README beside the skill folders — or a .DS_Store, on any
    // directory someone has opened in Finder — reaches this loop too, and
    // asking it for a SKILL.md is a failure rather than a miss. Python
    // filters the same way (`if p.is_dir()`).
    let children = listing
        .filter { child in
            var isDir: ObjCBool = false
            // Stats the child, not its contents, so an unreadable skill
            // folder still answers here and fails on the read below.
            return fm.fileExists(atPath: child.path, isDirectory: &isDir) && isDir.boolValue
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var skills: [Skill] = []
    for child in children {
        let md = child.appendingPathComponent("SKILL.md")
        // Read rather than test-then-read: `fileExists` answers false both for
        // a directory that holds no SKILL.md and one the process cannot see
        // into, and those are a skip and an error respectively.
        guard let text = try readSkillFileIfPresent(md) else { continue }
        skills.append(try parseSkillMd(text, defaultName: child.lastPathComponent))
    }
    return skills
}

/// A `SKILL.md` that exists but cannot be read — permissions, or bytes that
/// are not UTF-8. Mirrors the Python SDK, which raises `SkillError`
/// around the same read.
private func readSkillFile(_ url: URL) throws -> String {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw SkillError(
            code: .cannotRead,
            message: "\(url.path): cannot read: \(error.localizedDescription)"
        )
    }
}

/// The document, or nil when there is none there. Absence is how a directory
/// says it is not a skill; anything else — a permission wall, undecodable
/// bytes — is a failure to report rather than a skill to drop.
private func readSkillFileIfPresent(_ url: URL) throws -> String? {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return nil
    } catch {
        throw SkillError(
            code: .cannotRead,
            message: "\(url.path): cannot read: \(error.localizedDescription)"
        )
    }
}

/// Normalize a ``skills`` array — duplicates throw when the agent is built,
/// not mid-call.
func resolveSkills(_ skills: [Skill]) throws -> [Skill] {
    var seen = Set<String>()
    for skill in skills {
        guard seen.insert(skill.name).inserted else {
            throw SkillError(
                code: .duplicateSkillName,
                message: "duplicate skill name: \(String(reflecting: skill.name))"
            )
        }
    }
    return skills
}

/// The resident prompt menu; empty when there are no skills.
func skillsMenuText(_ skills: [Skill]) -> String {
    if skills.isEmpty { return "" }
    let header = "## Skills\nCall cosmo_sdk_load_skill(name) to load private instructions when the conversation reaches the matching path:"
    return header + "\n" + skills.map { "- \($0.name): \(singleLine($0.description))" }.joined(separator: "\n")
}

/// Collapse newlines so a description can never inject extra lines into the
/// menu block embedded in the system instructions.
private func singleLine(_ s: String) -> String {
    s.split(whereSeparator: \.isNewline).joined(separator: " ")
}
