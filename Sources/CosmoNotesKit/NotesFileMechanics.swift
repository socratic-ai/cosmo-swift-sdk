import Foundation
import os

/// File mechanics shared by the notes stores (``DocumentsNoteStore`` and
/// ``EncryptedNoteDocumentStore``): path-safe ids, atomic protected writes,
/// directory setup, and the JSON coding strategy. Stateless; each store keeps
/// its own `Logger` category and passes it in for failure logging.
enum NotesFileMechanics {
    /// Log a swallowed best-effort failure. A missing file/dir is an expected
    /// no-op (e.g. keep with no draft, discard of an already-gone draft), not a
    /// dropped write, so it is not logged. NEVER logs note text, transcript, or
    /// recap content — only the note `id` and the error.
    static func logFailure(_ op: String, id: String, _ error: Error, log: Logger) {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
            return
        }
        log.error(
            "notes \(op, privacy: .public) failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }

    /// Defend the layout against path traversal: keep only letters, digits, and
    /// `-`, dropping every path metacharacter so a store can't escape its root.
    /// The allowlist filter alone isn't injective — distinct ids can reduce to
    /// the same string (`a.b` and `ab`, `sess_1` and `sess1`), colliding onto one
    /// file — so whenever the filter alters the id at all, mix in a stable hash of
    /// the original to keep the mapping collision-free. An already-safe id (e.g. a
    /// server UUID) passes through unchanged.
    static func sanitize(_ id: String) -> String {
        let allowed = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        if allowed == id, !allowed.isEmpty { return allowed }
        let suffix = stableHash(id)
        return allowed.isEmpty ? "id-\(suffix)" : "\(allowed)-\(suffix)"
    }

    /// Deterministic (across processes) FNV-1a hash, so the fallback filename for
    /// an id is stable between launches — `Hasher` is per-process seeded and
    /// would not be.
    private static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// `Data.WritingOptions` for every note write. On iOS combine `.atomic` with
    /// `.completeFileProtectionUnlessOpen` so the file is encrypted at rest yet a
    /// write/read that races the screen lock at session end still completes
    /// (`UnlessOpen` keeps an already-open handle usable after lock). On macOS,
    /// which has no Data Protection, just `.atomic`.
    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUnlessOpen]
        #else
        return [.atomic]
        #endif
    }

    /// Create `dir` (if absent) and, on iOS, stamp it with the
    /// `.completeUnlessOpen` data-protection class so files created inside inherit
    /// at-rest encryption. Best-effort + logged; never throws so storage can't
    /// break a live session.
    static func ensureDirectory(at dir: URL, op: String, log: Logger) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logFailure(op, id: "<dir>", error, log: log)
        }
        #if os(iOS)
        do {
            try fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: dir.path)
        } catch {
            logFailure(op, id: "<dir-protection>", error, log: log)
        }
        #endif
    }

    /// Ensure a notes root exists with the same protection as any subdirectory
    /// (``ensureDirectory(at:op:log:)``) and, additionally, exclude it from
    /// device backup (iCloud/iTunes) so note PII never leaves the device. Backup
    /// exclusion works on both iOS and macOS. Best-effort + logged.
    static func ensureRoot(_ root: URL, op: String, log: Logger) {
        ensureDirectory(at: root, op: op, log: log)
        var url = root
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            logFailure(op, id: "<backup-exclude>", error, log: log)
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
