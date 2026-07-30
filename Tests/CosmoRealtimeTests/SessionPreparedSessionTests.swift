import Foundation
import LiveKit
import Testing

@testable import CosmoRealtime

/// Pins the new surface's prepared-session park/consume/discard state
/// machine (``RealtimeSession/prepareSession`` parks; the transport's
/// connect consumes). The guards are what keep a press safe: a handle
/// for another backend or an aged-out token must never be joined on.
/// Serialized because the parked handle is process-global.
@Suite("RealtimeSession prepared session handoff", .serialized)
struct SessionPreparedSessionTests {

    private static let baseURL = URL(string: "https://api.example.com")!
    private static let otherURL = URL(string: "https://other.example.com")!

    init() {
        RealtimeSession.discardPreparedSession()
    }

    private func makeHandle(
        preparedAt: Date = Date(),
        baseURL: URL = SessionPreparedSessionTests.baseURL,
        room: Room = Room()
    ) -> RealtimeSession.PreparedSessionHandle {
        RealtimeSession.PreparedSessionHandle(
            roomName: "cosmo-prep",
            roomGrant: "grant-xyz",
            token: "tok",
            livekitURL: "wss://a.example",
            room: room,
            preparedAt: preparedAt,
            baseURL: baseURL
        )
    }

    private func park(_ handle: RealtimeSession.PreparedSessionHandle) -> Bool {
        RealtimeSession._storePreparedSession(
            handle, epoch: RealtimeSession._preparedSessionCurrentEpoch()
        )
    }

    @Test func parkThenTakeRoundtrips() throws {
        let room = Room()
        #expect(park(makeHandle(room: room)) == true)
        let taken = try #require(
            RealtimeSession._takePreparedSession(baseURL: Self.baseURL)
        )
        #expect(taken.roomName == "cosmo-prep")
        #expect(taken.roomGrant == "grant-xyz")
        #expect(taken.token == "tok")
        #expect(taken.livekitURL == "wss://a.example")
        #expect(taken.room === room)
        // Consumed: a second take finds nothing.
        #expect(RealtimeSession._takePreparedSession(baseURL: Self.baseURL) == nil)
    }

    @Test func takeForDifferentBackendClearsAndReturnsNil() {
        // The room + grant only exist on the preparing backend; a start
        // pointed elsewhere must fall back to the serialized path.
        _ = park(makeHandle())
        #expect(RealtimeSession._takePreparedSession(baseURL: Self.otherURL) == nil)
        // The mismatched handle was dropped, not left parked.
        #expect(RealtimeSession._takePreparedSession(baseURL: Self.baseURL) == nil)
    }

    @Test func takeDiscardsHandleOlderThanMaxAge() {
        _ = park(makeHandle(
            preparedAt: Date(timeIntervalSinceNow: -(RealtimeSession._preparedSessionMaxAge + 1))
        ))
        #expect(RealtimeSession._takePreparedSession(baseURL: Self.baseURL) == nil)
    }

    @Test func takeAcceptsHandleJustUnderMaxAge() throws {
        _ = park(makeHandle(
            preparedAt: Date(timeIntervalSinceNow: -(RealtimeSession._preparedSessionMaxAge - 60))
        ))
        _ = try #require(RealtimeSession._takePreparedSession(baseURL: Self.baseURL))
    }

    @Test func discardClearsParkedHandle() {
        _ = park(makeHandle())
        RealtimeSession.discardPreparedSession()
        #expect(RealtimeSession._takePreparedSession(baseURL: Self.baseURL) == nil)
    }

    @Test func storeFromBeforeADiscardIsDropped() {
        // A prepare that was in flight when the user signed out (epoch
        // snapshotted before ``discardPreparedSession``) must not park the
        // previous identity's handle afterwards — the next user would join
        // a room whose grant the backend rejects.
        let epoch = RealtimeSession._preparedSessionCurrentEpoch()
        RealtimeSession.discardPreparedSession()
        #expect(
            RealtimeSession._storePreparedSession(makeHandle(), epoch: epoch) == false
        )
        #expect(RealtimeSession._takePreparedSession(baseURL: Self.baseURL) == nil)
    }

    // The max-age guard must sit safely under the server's prepared
    // join-token TTL (30 min) so a press never joins on a near-expired
    // token, and above the ~20-min refresh cadence so fresh handles are
    // consumed rather than discarded.
    @Test func maxAgeIsUnderTokenTtlAndAboveRefreshCadence() {
        #expect(RealtimeSession._preparedSessionMaxAge < 30 * 60)
        #expect(RealtimeSession._preparedSessionMaxAge >= 20 * 60)
    }
}
