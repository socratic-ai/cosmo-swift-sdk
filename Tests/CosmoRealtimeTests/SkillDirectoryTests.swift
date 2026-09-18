import Foundation
import Testing

@testable import CosmoRealtime

/// The filesystem arm of `skills:`. Mirrors the Python SDK's
/// `test_unreadable_directory_*`, which is where these cases were pinned
/// first — Swift had no test touching `cannotRead` or `notADirectory`, so an
/// unreadable child skill was dropped silently and the suite stayed green.
@Suite("Skills directory loading")
struct SkillDirectoryTests {
    private let fm = FileManager.default

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skilldir-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(_ dir: URL, name: String) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(name) desc.\n---\nbody"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func code(of block: () throws -> Void) -> SkillErrorCode? {
        do {
            try block()
            return nil
        } catch let error as SkillError {
            return error.code
        } catch {
            return nil
        }
    }

    @Test func rootOfSkillFoldersLoadsEachOne() throws {
        let root = try makeRoot()
        try writeSkill(root.appendingPathComponent("alpha"), name: "alpha")
        try writeSkill(root.appendingPathComponent("beta"), name: "beta")
        try fm.createDirectory(  // no SKILL.md — not a skill, and not an error
            at: root.appendingPathComponent("not-a-skill"), withIntermediateDirectories: true)

        #expect(try [Skill].directory(root).map(\.name) == ["alpha", "beta"])
    }

    /// `contentsOfDirectory` returns files as well as folders, so anything
    /// sitting beside the skill folders reaches the loop. A README is the
    /// obvious one; a `.DS_Store` appears on any directory someone has opened
    /// in Finder, which makes this reachable without the author doing
    /// anything unusual.
    @Test func looseFilesBesideTheSkillFoldersAreIgnored() throws {
        let root = try makeRoot()
        try writeSkill(root.appendingPathComponent("alpha"), name: "alpha")
        try writeSkill(root.appendingPathComponent("beta"), name: "beta")
        try fm.createDirectory(
            at: root.appendingPathComponent("empty-dir"), withIntermediateDirectories: true)
        try "readme".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))

        #expect(try [Skill].directory(root).map(\.name) == ["alpha", "beta"])
    }

    @Test func directoryWithItsOwnDocumentIsThatOneSkill() throws {
        let root = try makeRoot()
        try writeSkill(root.appendingPathComponent("activate-card"), name: "activate-card")

        let skills = try [Skill].directory(root.appendingPathComponent("activate-card"))
        #expect(skills.map(\.name) == ["activate-card"])
    }

    @Test func emptyDirectoryIsNotAnError() throws {
        #expect(try [Skill].directory(makeRoot()).isEmpty)
    }

    @Test func missingPathIsNotADirectory() throws {
        let root = try makeRoot()
        #expect(code(of: { _ = try [Skill].directory(root.appendingPathComponent("nope")) })
            == .notADirectory)
    }

    @Test func aFileIsNotADirectory() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("loose.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(code(of: { _ = try [Skill].directory(file) }) == .notADirectory)
    }

    @Test func unreadableRootCannotBeRead() throws {
        let root = try makeRoot()
        try writeSkill(root.appendingPathComponent("alpha"), name: "alpha")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        #expect(code(of: { _ = try [Skill].directory(root) }) == .cannotRead)
    }

    /// The arm that regressed: `fileExists` answers false for a directory the
    /// process cannot see into exactly as it does for one holding no
    /// `SKILL.md`, so the skill was skipped and the agent built without it.
    @Test func unreadableChildCannotBeRead() throws {
        let root = try makeRoot()
        try writeSkill(root.appendingPathComponent("alpha"), name: "alpha")
        let beta = root.appendingPathComponent("beta")
        try writeSkill(beta, name: "beta")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: beta.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: beta.path) }

        #expect(code(of: { _ = try [Skill].directory(root) }) == .cannotRead)
    }

    @Test func unreadableDocumentCannotBeRead() throws {
        let root = try makeRoot()
        let alpha = root.appendingPathComponent("alpha")
        try writeSkill(alpha, name: "alpha")
        let doc = alpha.appendingPathComponent("SKILL.md")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: doc.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: doc.path) }

        #expect(code(of: { _ = try [Skill].directory(root) }) == .cannotRead)
    }

    @Test func malformedDocumentNamesItsOwnFault() throws {
        let root = try makeRoot()
        let bad = root.appendingPathComponent("bad")
        try fm.createDirectory(at: bad, withIntermediateDirectories: true)
        try "no frontmatter".write(
            to: bad.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        #expect(code(of: { _ = try [Skill].directory(root) }) == .missingFrontmatter)
    }
}
