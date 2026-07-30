import CosmoRealtime
import Foundation
import os

/// Why ``NoteDocumentStore/append(text:id:kind:title:header:)`` refused to
/// write. Every case preserves the existing file untouched.
public enum NoteAppendRefusal: Equatable, Sendable {
    /// The existing file could not be read (e.g. its Data Protection class
    /// while the device is locked); writing would overwrite the only copy.
    case unreadable
    /// The file was written by a build with a newer schema; writing would
    /// lossily downgrade it.
    case newerSchema
    /// The file is not a note document and moving it aside failed; writing
    /// would destroy the original bytes.
    case quarantineFailed
    /// Encoding or writing the updated document failed; the append did not
    /// persist and the file keeps its previous contents.
    case writeFailed
}

/// Outcome of one ``NoteDocumentStore/append(text:id:kind:title:header:)``.
public enum NoteAppendOutcome: Equatable, Sendable {
    /// The note as persisted after the append; `created` is true when this
    /// call created the note file.
    case appended(Note, created: Bool)
    case refused(NoteAppendRefusal)
}

/// CRUD + listing for standalone ``Note`` documents. All ops are best-effort so
/// storage can never break a live session. Each call is serialized on its own:
/// a ``loadOrCreate(id:kind:title:)`` followed by ``save(_:)`` is two
/// independent operations, not one atomic read-modify-write —
/// ``append(text:id:kind:title:header:)`` is the read-modify-write primitive.
public protocol NoteDocumentStore: Sendable {
    /// The note with `id`, creating (and persisting) an empty one with the given
    /// `kind`/`title` if absent. Concurrent callers for the same id converge on
    /// one document.
    func loadOrCreate(id: String, kind: Note.Kind, title: String) async -> Note
    /// One note, or nil — including for a valid file stamped with a newer
    /// schemaVersion than this build supports, which is preserved untouched
    /// rather than lossily downgraded.
    func load(id: String) async -> Note?
    /// Rewrite a note's full file (`<id>.json`) and its summary sidecar
    /// (`<id>.summary.json`) — two independent best-effort atomic writes (each
    /// atomic on its own; not one atomic pair). A last-write-wins upsert: it
    /// writes whether or not the note exists, so saving over a concurrent
    /// ``delete(id:)`` recreates the note. Returns whether the note document
    /// itself persisted — false means the file keeps its previous contents, so
    /// a caller saving a user's edit can refuse to claim success. The sidecar
    /// stays best-effort on its own, as in
    /// ``append(text:id:kind:title:header:)``.
    @discardableResult
    func save(_ note: Note) async -> Bool
    /// Append `text` as its own block to the note with `id`, creating the note
    /// (with the given `kind`/`title`) when absent, as one atomic
    /// read-modify-write: read-classify, compose via
    /// ``MarkdownSections/appendBlock(to:text:header:)`` (`header` seeds an
    /// empty or fresh note), stamp `modifiedAt`, write. Concurrent appends to
    /// the same id serialize instead of losing blocks. Refuses — rather than
    /// overwrites — a file it must not touch (``NoteAppendRefusal``); an
    /// undecodable file is quarantined first, as in
    /// ``loadOrCreate(id:kind:title:)``.
    func append(
        text: String, id: String, kind: Note.Kind, title: String, header: String
    ) async -> NoteAppendOutcome
    /// Every note's lightweight summary, most recently modified first. Reads
    /// only the `<id>.summary.json` sidecars, never the bodies.
    func list() async -> [NoteSummary]
    /// Remove a note (user delete).
    func delete(id: String) async
}

/// File-based ``NoteDocumentStore`` under the `docs/` subdirectory of the same
/// notes root ``DocumentsNoteStore`` uses (default: `Documents/notes/docs`).
/// Layout:
/// ```
/// <root>/docs/<id>.json          full note, `{meta, body}`
/// <root>/docs/<id>.summary.json  list summary
/// ```
/// Mirrors ``DocumentsNoteStore``'s file mechanics — sanitized ids, atomic
/// best-effort writes, backup exclusion on the root, sidecar self-heal in
/// ``list()`` — with all IO funneled through ``NotesFileGate`` off the calling
/// actor. "Encrypted" means iOS Data Protection: files are written
/// `.completeFileProtectionUnlessOpen` and the directories carry the
/// `.completeUnlessOpen` class; a macOS build has no Data Protection and
/// writes plain atomic files. Holds only immutable state, so it is `Sendable`.
///
/// The file gate is per store instance, so the load-or-create convergence and
/// no-torn-write guarantees hold only when exactly one instance owns a given
/// root: hold a single shared instance, as with ``DocumentsNoteStore``.
public final class EncryptedNoteDocumentStore: NoteDocumentStore {
    private let root: URL
    private let docsDir: URL
    private let gate = NotesFileGate()

    /// Same subsystem as ``DocumentsNoteStore`` so one `log` predicate captures
    /// all notes IO. NEVER logs note text or titles — only the note `id` and
    /// the error.
    private static let log = Logger(
        subsystem: CosmoRealtimeLog.subsystem, category: "note-doc-store")

    private static func logFailure(_ op: String, id: String, _ error: Error) {
        NotesFileMechanics.logFailure(op, id: id, error, log: log)
    }

    public init(root: URL = DocumentsNoteStore.defaultRoot()) {
        self.root = root
        self.docsDir = root.appendingPathComponent("docs", isDirectory: true)
        // Create the directories eagerly so the backup-exclusion (and, on iOS,
        // the data-protection class) is in place before any note is written.
        Self.ensureRoot(root, op: "init")
        Self.ensureDirectory(at: docsDir, op: "init")
    }

    public func loadOrCreate(id: String, kind: Note.Kind, title: String) async -> Note {
        let root = self.root
        let docsDir = self.docsDir
        let fullURL = noteURL(id)
        let summaryURL = summaryURL(id)
        return await gate.run { () -> Note in
            let fresh = { () -> Note in
                let now = Date()
                return Note(
                    id: id, kind: kind, title: title, createdAt: now, modifiedAt: now, body: "")
            }
            switch Self.readNote(at: fullURL, id: id) {
            case .note(let existing):
                return existing
            case .unreadable, .newerSchema:
                // Unreadable: e.g. the file's Data Protection class while the
                // device is locked; creating would overwrite the only copy —
                // the root is backup-excluded, so there is no other. Newer
                // schema: the file is valid, just from a newer build; writing
                // would lossily downgrade it. Either way, hand back an
                // in-memory note and persist nothing.
                return fresh()
            case .undecodable:
                // Bytes exist but aren't a note. Move them aside before
                // recreating; if that fails, don't risk the original.
                guard Self.quarantine(fullURL, id: id) else { return fresh() }
                fallthrough
            case .absent:
                let note = fresh()
                Self.ensureRoot(root, op: "loadOrCreate")
                Self.ensureDirectory(at: docsDir, op: "loadOrCreate")
                Self.writeNote(note, fullURL: fullURL, summaryURL: summaryURL, op: "loadOrCreate")
                // Return the persisted representation so every caller — creator
                // included — observes the same (whole-second ISO-8601) timestamps.
                if case .note(let persisted) = Self.readNote(at: fullURL, id: id) {
                    return persisted
                }
                return note
            }
        }
    }

    public func load(id: String) async -> Note? {
        let url = noteURL(id)
        return await gate.run { () -> Note? in
            if case .note(let note) = Self.readNote(at: url, id: id) { return note }
            return nil
        }
    }

    @discardableResult
    public func save(_ note: Note) async -> Bool {
        let root = self.root
        let docsDir = self.docsDir
        let fullURL = noteURL(note.id)
        let summaryURL = summaryURL(note.id)
        return await gate.run {
            Self.ensureRoot(root, op: "save")
            Self.ensureDirectory(at: docsDir, op: "save")
            return Self.writeNote(note, fullURL: fullURL, summaryURL: summaryURL, op: "save")
        }
    }

    public func append(
        text: String, id: String, kind: Note.Kind, title: String, header: String
    ) async -> NoteAppendOutcome {
        let root = self.root
        let docsDir = self.docsDir
        let fullURL = noteURL(id)
        let summaryURL = summaryURL(id)
        return await gate.run { () -> NoteAppendOutcome in
            let base: Note
            let created: Bool
            switch Self.readNote(at: fullURL, id: id) {
            case .note(let existing):
                base = existing
                created = false
            case .unreadable:
                return .refused(.unreadable)
            case .newerSchema:
                return .refused(.newerSchema)
            case .undecodable:
                guard Self.quarantine(fullURL, id: id) else {
                    return .refused(.quarantineFailed)
                }
                fallthrough
            case .absent:
                let now = Date()
                base = Note(
                    id: id, kind: kind, title: title, createdAt: now, modifiedAt: now, body: "")
                created = true
            }
            var updated = base
            updated.body = MarkdownSections.appendBlock(to: base.body, text: text, header: header)
            updated.modifiedAt = Date()
            Self.ensureRoot(root, op: "append")
            Self.ensureDirectory(at: docsDir, op: "append")
            guard Self.writeNote(updated, fullURL: fullURL, summaryURL: summaryURL, op: "append")
            else {
                return .refused(.writeFailed)
            }
            // Return the persisted representation so every caller observes the
            // same (whole-second ISO-8601) timestamps.
            if case .note(let persisted) = Self.readNote(at: fullURL, id: id) {
                return .appended(persisted, created: created)
            }
            return .appended(updated, created: created)
        }
    }

    public func list() async -> [NoteSummary] {
        let docsDir = self.docsDir
        return await gate.run { () -> [NoteSummary] in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: docsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            let decoder = NotesFileMechanics.makeDecoder()
            // Keyed off the full notes (`<id>.json`), not the sidecars, so a
            // note whose sidecar is missing or corrupt — the summary write is an
            // independent best-effort op that can fail on its own — is still
            // returned. Prefer the cheap sidecar; if it is absent/undecodable,
            // derive the summary from the full note and best-effort write the
            // sidecar back so it self-heals on the next listing.
            let summaries: [NoteSummary] = entries.compactMap { url in
                guard url.pathExtension == "json",
                      !url.lastPathComponent.hasSuffix(Self.summarySuffix) else { return nil }
                let id = url.deletingPathExtension().lastPathComponent
                let summaryURL = docsDir.appendingPathComponent("\(id)\(Self.summarySuffix)")
                if let data = try? Data(contentsOf: summaryURL),
                   let summary = try? decoder.decode(NoteSummary.self, from: data) {
                    return summary
                }
                do {
                    let data = try Data(contentsOf: url)
                    let note = try decoder.decode(Note.self, from: data)
                    let summary = note.summary
                    do {
                        let encoded = try NotesFileMechanics.makeEncoder().encode(summary)
                        try encoded.write(to: summaryURL, options: NotesFileMechanics.writeOptions)
                    } catch {
                        Self.logFailure("list-heal", id: id, error)
                    }
                    return summary
                } catch {
                    Self.logFailure("list", id: id, error)
                    return nil
                }
            }
            // Timestamps persist at whole-second precision, so ties are common;
            // the id tie-break keeps the order deterministic.
            return summaries.sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.id < $1.id
            }
        }
    }

    public func delete(id: String) async {
        let url = noteURL(id)
        let summaryURL = summaryURL(id)
        await gate.run {
            let fm = FileManager.default
            do { try fm.removeItem(at: url) }
            catch { Self.logFailure("delete", id: id, error) }
            do { try fm.removeItem(at: summaryURL) }
            catch { Self.logFailure("delete", id: id, error) }
        }
    }

    // MARK: - Internals

    private static let summarySuffix = ".summary.json"

    private func noteURL(_ id: String) -> URL {
        docsDir.appendingPathComponent("\(sanitize(id)).json")
    }

    private func summaryURL(_ id: String) -> URL {
        docsDir.appendingPathComponent("\(sanitize(id))\(Self.summarySuffix)")
    }

    /// One read of a note file, split into the outcomes ``loadOrCreate`` must
    /// treat differently: only `absent` may create; `unreadable` and
    /// `newerSchema` must leave the file alone; `undecodable` is quarantined
    /// before recreating. Failures (everything but absence) are logged here.
    private enum ReadOutcome {
        case note(Note)
        case absent
        case unreadable
        case undecodable
        case newerSchema
    }

    /// A valid note file stamped by a build with a newer schema than this one.
    private struct NewerSchemaError: Error, LocalizedError {
        let version: Int
        var errorDescription: String? {
            "schemaVersion \(version) is newer than supported \(Note.currentSchemaVersion)"
        }
    }

    private static func readNote(at url: URL, id: String) -> ReadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
                return .absent
            }
            logFailure("read", id: id, error)
            return .unreadable
        }
        do {
            let note = try NotesFileMechanics.makeDecoder().decode(Note.self, from: data)
            // Decoding ignores unknown meta keys, so a newer build's note would
            // decode "cleanly" here and a later save would silently drop its
            // extra fields. Refuse it instead; the file stays as written.
            guard note.schemaVersion <= Note.currentSchemaVersion else {
                logFailure(
                    "read-newer-schema", id: id, NewerSchemaError(version: note.schemaVersion))
                return .newerSchema
            }
            return .note(note)
        } catch {
            logFailure("read", id: id, error)
            return .undecodable
        }
    }

    /// Move an undecodable note file to `<id>.json.corrupt` so recreating the
    /// id never destroys the original bytes. Sanitized filenames always end in
    /// `.json`, so the name can't collide with a live note, and ``list()``
    /// skips it (extension is not `json`). Returns false when the move failed
    /// and the original must not be overwritten.
    private static func quarantine(_ url: URL, id: String) -> Bool {
        let fm = FileManager.default
        let dest = url.appendingPathExtension("corrupt")
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: url)
            } else {
                try fm.moveItem(at: url, to: dest)
            }
            return true
        } catch {
            logFailure("quarantine", id: id, error)
            return false
        }
    }

    /// Encode and atomically write a note's full file and its summary sidecar.
    /// Failures are swallowed and logged (best-effort storage), but the return
    /// reports whether the note document itself persisted so ``append`` can
    /// refuse instead of claiming a dropped write succeeded. The sidecar stays
    /// best-effort on its own — ``list()`` self-heals it.
    @discardableResult
    private static func writeNote(_ note: Note, fullURL: URL, summaryURL: URL, op: String) -> Bool {
        let encoder = NotesFileMechanics.makeEncoder()
        do {
            let data = try encoder.encode(note)
            try data.write(to: fullURL, options: NotesFileMechanics.writeOptions)
        } catch {
            logFailure(op, id: note.id, error)
            return false
        }
        do {
            let summaryData = try encoder.encode(note.summary)
            try summaryData.write(to: summaryURL, options: NotesFileMechanics.writeOptions)
        } catch {
            logFailure(op, id: note.id, error)
        }
        return true
    }

    /// ``NotesFileMechanics/sanitize(_:)``. Note ids are code-generated and
    /// already safe, so this is defense in depth. `internal` so the no-escape
    /// invariant is unit-testable.
    func sanitize(_ id: String) -> String {
        NotesFileMechanics.sanitize(id)
    }

    private static func ensureDirectory(at dir: URL, op: String) {
        NotesFileMechanics.ensureDirectory(at: dir, op: op, log: log)
    }

    /// Shared with ``DocumentsNoteStore`` so the root's backup exclusion and
    /// protection hold whichever store touches it first.
    private static func ensureRoot(_ root: URL, op: String) {
        NotesFileMechanics.ensureRoot(root, op: op, log: log)
    }
}
