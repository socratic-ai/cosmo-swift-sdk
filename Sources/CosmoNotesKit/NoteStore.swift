import CosmoRealtime
import Foundation
import os

/// Serializes every note file read-modify-write so concurrent client-tool
/// calls and the end-of-session draft write can't observe a half-written file
/// or lose updates. Ported from the macOS app's `NotesFileGate`; ops are
/// sub-millisecond, so a single gate per store has no meaningful contention.
public actor NotesFileGate {
    public init() {}
    public func run<T: Sendable>(_ body: @Sendable () throws -> T) async rethrows -> T {
        try body()
    }
}

/// The draft → keep/discard storage lifecycle for ``SessionNote`` records.
/// A draft is written when a session ends; the user promotes it to a kept note
/// (Keep) or it is removed (Discard / launch sweep). All ops are best-effort so
/// storage can never break a live session.
public protocol NoteStore: Sendable {
    /// Write `note` as a draft (ephemeral, under `drafts/`).
    func saveDraft(_ note: SessionNote) async
    /// Rewrite an existing note's full file (`<id>.json`) and its summary
    /// sidecar (`<id>.summary.json`) — the note-mutation primitive. Targets the
    /// kept location if the kept full note exists, else the draft location. The
    /// two files are two independent best-effort atomic writes (each atomic on
    /// its own; not one atomic pair). No-op if the note exists in neither
    /// location, so a stray caller can't resurrect a discarded note as a draft.
    func update(_ note: SessionNote) async
    /// Promote a draft to a kept note (atomic rename).
    func keep(id: String) async
    /// Remove a draft without keeping it.
    func discard(id: String) async
    /// Remove every draft outright. Retained as a primitive; the app applies its
    /// `reconcileDrafts` keep-or-discard policy at launch instead of sweeping.
    func sweepDrafts() async
    /// Every kept note's lightweight summary, newest first. Reads only the
    /// `<id>.summary.json` sidecars, never the full transcripts, so listing a
    /// large archive stays cheap. For full content use ``load(id:)`` or
    /// ``loadAll()``.
    func list() async -> [SessionNoteSummary]
    /// Every draft's lightweight summary, newest first — the draft-side mirror of
    /// ``list()``. Reads only the `drafts/<id>.summary.json` sidecars.
    func listDraftSummaries() async -> [SessionNoteSummary]
    /// Every kept note in full (transcript included), newest first — for the
    /// search/read path that genuinely needs the content. Decodes the full
    /// `<id>.json` files; prefer ``list()`` for the UI.
    func loadAll() async -> [SessionNote]
    /// One kept note, or nil.
    func load(id: String) async -> SessionNote?
    /// Remove a kept note (user delete).
    func delete(id: String) async
}

/// File-based ``NoteStore`` rooted at a configurable directory (default:
/// `Documents/notes`). Layout:
/// ```
/// <root>/drafts/<id>.json           ephemeral, full note
/// <root>/drafts/<id>.summary.json   ephemeral, list summary
/// <root>/<id>.json                  kept, full note
/// <root>/<id>.summary.json          kept, list summary
/// ```
/// Each session keeps a lightweight `<id>.summary.json` sidecar next to its full
/// `<id>.json` so ``list()`` can show the archive without decoding any
/// transcript (mirrors the macOS app's `session.json` vs `transcript.jsonl`
/// split). The two files are written, promoted, and removed together.
/// Writes are atomic and best-effort; Keep moves the draft into place (or
/// atomically replaces an existing kept note) so it can't corrupt or lose data.
/// All IO is funneled through ``NotesFileGate`` off the calling actor. Holds only
/// immutable state, so it is `Sendable`.
public final class DocumentsNoteStore: NoteStore {
    private let root: URL
    private let gate = NotesFileGate()

    /// Same `socratic.cosmo-realtime` subsystem as the rest of the SDK so one
    /// `log` predicate captures notes IO alongside the session. Best-effort
    /// storage swallows IO/codec errors to never break a live session; logging
    /// them here keeps those drops diagnosable. NEVER logs note text, transcript,
    /// or recap content — only the note `id` and the error.
    private static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "notes-store")

    private static func logFailure(_ op: String, id: String, _ error: Error) {
        NotesFileMechanics.logFailure(op, id: id, error, log: log)
    }

    public init(root: URL = DocumentsNoteStore.defaultRoot()) {
        self.root = root
        // Create the root eagerly so the backup-exclusion (and, on iOS, the
        // data-protection class) is in place before any note is written, even
        // for a session that never writes. Best-effort + logged.
        Self.ensureRoot(root, op: "init")
    }

    /// `Documents/notes` (falls back to the temp dir if Documents is absent).
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("notes", isDirectory: true)
    }

    public func saveDraft(_ note: SessionNote) async {
        let draftsDir = self.draftsDir
        let url = draftURL(note.id)
        let summaryURL = draftSummaryURL(note.id)
        await gate.run {
            Self.ensureDirectory(at: draftsDir, op: "saveDraft")
            Self.writeNote(note, fullURL: url, summaryURL: summaryURL, op: "saveDraft")
        }
    }

    public func update(_ note: SessionNote) async {
        let root = self.root
        let draftsDir = self.draftsDir
        let keptFull = keptURL(note.id)
        let keptSummary = keptSummaryURL(note.id)
        let draftFull = draftURL(note.id)
        let draftSummary = draftSummaryURL(note.id)
        let id = note.id
        await gate.run {
            let fm = FileManager.default
            let isKept = fm.fileExists(atPath: keptFull.path)
            // Harden the public method: refuse to write when the note exists in
            // neither location, so a stray caller can't resurrect a discarded or
            // never-existed note as a fresh draft.
            guard isKept || fm.fileExists(atPath: draftFull.path) else {
                Self.log.debug("notes update skipped, no file id=\(id, privacy: .public)")
                return
            }
            // Rewrite wherever the note currently lives: the kept location if the
            // kept full note exists, else the draft location. The summary sidecar
            // rides along so the two files don't drift.
            let fullURL = isKept ? keptFull : draftFull
            let summaryURL = isKept ? keptSummary : draftSummary
            if isKept {
                Self.ensureRoot(root, op: "update")
            } else {
                Self.ensureDirectory(at: draftsDir, op: "update")
            }
            Self.writeNote(note, fullURL: fullURL, summaryURL: summaryURL, op: "update")
        }
    }

    /// Encode and atomically write a note's full file and its summary sidecar —
    /// two independent best-effort writes shared by ``saveDraft(_:)`` and
    /// ``update(_:)``. A failure on either is swallowed and logged.
    private static func writeNote(_ note: SessionNote, fullURL: URL, summaryURL: URL, op: String) {
        do {
            let encoder = NotesFileMechanics.makeEncoder()
            let data = try encoder.encode(note)
            try data.write(to: fullURL, options: NotesFileMechanics.writeOptions)
            let summaryData = try encoder.encode(note.summary)
            try summaryData.write(to: summaryURL, options: NotesFileMechanics.writeOptions)
        } catch {
            logFailure(op, id: note.id, error)
        }
    }

    public func keep(id: String) async {
        let root = self.root
        let fullSrc = draftURL(id)
        let fullDest = keptURL(id)
        let summarySrc = draftSummaryURL(id)
        let summaryDest = keptSummaryURL(id)
        await gate.run {
            Self.ensureRoot(root, op: "keep")
            // Promote both files independently and best-effort: a missing
            // summary (e.g. a draft written by an older build) must not block
            // promoting the full note, and vice versa.
            Self.promote(from: fullSrc, to: fullDest, op: "keep", id: id)
            Self.promote(from: summarySrc, to: summaryDest, op: "keep", id: id)
        }
    }

    /// Move `src` over `dest`, replacing an existing `dest` atomically rather
    /// than remove-then-move so a failed swap can never leave neither file in
    /// place. Best-effort + logged; a missing `src` is an expected no-op.
    private static func promote(from src: URL, to dest: URL, op: String, id: String) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: src)
            } else {
                try fm.moveItem(at: src, to: dest)
            }
        } catch {
            logFailure(op, id: id, error)
        }
    }

    public func discard(id: String) async {
        let url = draftURL(id)
        let summaryURL = draftSummaryURL(id)
        await gate.run {
            let fm = FileManager.default
            do { try fm.removeItem(at: url) }
            catch { Self.logFailure("discard", id: id, error) }
            do { try fm.removeItem(at: summaryURL) }
            catch { Self.logFailure("discard", id: id, error) }
        }
    }

    public func sweepDrafts() async {
        let draftsDir = self.draftsDir
        await gate.run {
            do { try FileManager.default.removeItem(at: draftsDir) }
            catch { Self.logFailure("sweepDrafts", id: "<drafts>", error) }
        }
    }

    public func list() async -> [SessionNoteSummary] {
        let root = self.root
        return await gate.run { () -> [SessionNoteSummary] in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            let decoder = NotesFileMechanics.makeDecoder()
            // The list is keyed off the kept full notes (`<id>.json`), not the
            // summary sidecars, so a note whose sidecar is missing or corrupt —
            // the summary write is an independent best-effort op that can fail on
            // its own — is still returned. For each full note, prefer its cheap
            // `<id>.summary.json` sidecar; if that is absent/undecodable, derive
            // the summary from the full note and best-effort write the sidecar
            // back so it self-heals on the next listing.
            let summaries: [SessionNoteSummary] = entries.compactMap { url in
                guard url.pathExtension == "json",
                      !url.lastPathComponent.hasSuffix(Self.summarySuffix) else { return nil }
                let id = url.deletingPathExtension().lastPathComponent
                let summaryURL = root.appendingPathComponent("\(id)\(Self.summarySuffix)")
                if let data = try? Data(contentsOf: summaryURL),
                   let summary = try? decoder.decode(SessionNoteSummary.self, from: data) {
                    return summary
                }
                // No valid sidecar: fall back to the full note and heal it.
                do {
                    let data = try Data(contentsOf: url)
                    let note = try decoder.decode(SessionNote.self, from: data)
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
            return summaries.sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func listDraftSummaries() async -> [SessionNoteSummary] {
        let draftsDir = self.draftsDir
        return await gate.run { () -> [SessionNoteSummary] in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: draftsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            let decoder = NotesFileMechanics.makeDecoder()
            // Decode only the draft `<id>.summary.json` sidecars; mirrors list()
            // over the drafts dir.
            let summaries: [SessionNoteSummary] = entries.compactMap { url in
                guard url.lastPathComponent.hasSuffix(Self.summarySuffix) else { return nil }
                let id = String(url.lastPathComponent.dropLast(Self.summarySuffix.count))
                do {
                    let data = try Data(contentsOf: url)
                    return try decoder.decode(SessionNoteSummary.self, from: data)
                } catch {
                    Self.logFailure("listDraftSummaries", id: id, error)
                    return nil
                }
            }
            return summaries.sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func loadAll() async -> [SessionNote] {
        let root = self.root
        return await gate.run { () -> [SessionNote] in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            let decoder = NotesFileMechanics.makeDecoder()
            // Decode the full notes; skip the `<id>.summary.json` sidecars.
            let notes: [SessionNote] = entries.compactMap { url in
                guard url.pathExtension == "json",
                      !url.lastPathComponent.hasSuffix(Self.summarySuffix) else { return nil }
                let id = url.deletingPathExtension().lastPathComponent
                do {
                    let data = try Data(contentsOf: url)
                    return try decoder.decode(SessionNote.self, from: data)
                } catch {
                    Self.logFailure("loadAll", id: id, error)
                    return nil
                }
            }
            return notes.sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func load(id: String) async -> SessionNote? {
        let url = keptURL(id)
        return await gate.run { () -> SessionNote? in
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                Self.logFailure("load", id: id, error)
                return nil
            }
            do {
                return try NotesFileMechanics.makeDecoder().decode(SessionNote.self, from: data)
            } catch {
                Self.logFailure("load", id: id, error)
                return nil
            }
        }
    }

    public func delete(id: String) async {
        let url = keptURL(id)
        let summaryURL = keptSummaryURL(id)
        await gate.run {
            let fm = FileManager.default
            do { try fm.removeItem(at: url) }
            catch { Self.logFailure("delete", id: id, error) }
            do { try fm.removeItem(at: summaryURL) }
            catch { Self.logFailure("delete", id: id, error) }
        }
    }

    // MARK: - Internals

    private var draftsDir: URL { root.appendingPathComponent("drafts", isDirectory: true) }

    /// Suffix marking a summary sidecar; used to tell summary files apart from
    /// the full `<id>.json` notes when scanning a directory.
    private static let summarySuffix = ".summary.json"

    private func draftURL(_ id: String) -> URL {
        draftsDir.appendingPathComponent("\(sanitize(id)).json")
    }

    private func draftSummaryURL(_ id: String) -> URL {
        draftsDir.appendingPathComponent("\(sanitize(id))\(Self.summarySuffix)")
    }

    private func keptURL(_ id: String) -> URL {
        root.appendingPathComponent("\(sanitize(id)).json")
    }

    private func keptSummaryURL(_ id: String) -> URL {
        root.appendingPathComponent("\(sanitize(id))\(Self.summarySuffix)")
    }

    /// ``NotesFileMechanics/sanitize(_:)``; `internal` so the no-escape
    /// invariant is unit-testable.
    func sanitize(_ id: String) -> String {
        NotesFileMechanics.sanitize(id)
    }

    private static func ensureDirectory(at dir: URL, op: String) {
        NotesFileMechanics.ensureDirectory(at: dir, op: op, log: log)
    }

    private static func ensureRoot(_ root: URL, op: String) {
        NotesFileMechanics.ensureRoot(root, op: op, log: log)
    }
}
