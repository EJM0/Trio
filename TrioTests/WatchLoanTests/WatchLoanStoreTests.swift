import Foundation
import Testing

@testable import Trio

@Suite("Watch loan: persistence and wire format") struct WatchLoanStoreTests {
    typealias F = LoanFixture

    static func temporaryStore<State: Codable>(_: State.Type = PhoneLoanState.self) -> WatchLoanStore<State> {
        WatchLoanStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("watch-loan-\(UUID()).json"))
    }

    @Test("No file loads as nil, which the phone reads as home (today's behaviour)") func missingFile() throws {
        let store: WatchLoanStore<PhoneLoanState> = Self.temporaryStore()
        #expect(try store.load().get() == nil)
        #expect(WatchLoanGate(store: store).phoneState == .initial)
    }

    @Test("Every phone state round-trips", arguments: [
        PhoneLoanState.initial,
        .home(epoch: 5, lastLoan: LoanRecord(epoch: 4, supersededUntil: LoanFixture.window)),
        .lending(epoch: 4, requestID: LoanFixture.requestA),
        .lent(epoch: 4),
        .takingBack(epoch: 5, loan: LoanRecord(epoch: 4)),
        .takingBack(epoch: 99, loan: nil)
    ]) func phoneRoundTrip(state: PhoneLoanState) throws {
        let store: WatchLoanStore<PhoneLoanState> = Self.temporaryStore()
        try store.save(state)
        #expect(try store.load().get() == state)
    }

    @Test("Every watch state round-trips", arguments: [
        WatchLoanState.initial,
        .requesting(epoch: 3, requestID: LoanFixture.requestA),
        .holding(epoch: 4),
        .returning(epoch: 4),
        .stopped(epoch: 4, reason: .foreignSession)
    ]) func watchRoundTrip(state: WatchLoanState) throws {
        let store = Self.temporaryStore(WatchLoanState.self)
        try store.save(state)
        #expect(try store.load().get() == state)
    }

    @Test("A corrupt or truncated file is a failure, never home (V2-15)", arguments: [
        "", "{", "not json", #"{"lent":{"epoch":"four"}}"#, #"{"somethingElse":{}}"#
    ]) func corruptFile(contents: String) throws {
        let store: WatchLoanStore<PhoneLoanState> = Self.temporaryStore()
        try Data(contents.utf8).write(to: store.url)
        if case .success = store.load() { Issue.record("A corrupt file loaded") }
        let gate = WatchLoanGate(store: store)
        #expect(gate.phoneState == .unreadable)
        #expect(!gate.phoneMayCommandPump)
        #expect(!gate.permits("Test"))
    }

    @Test("Saving replaces the file atomically; the last state wins") func overwrite() throws {
        let store: WatchLoanStore<PhoneLoanState> = Self.temporaryStore()
        try store.save(.lent(epoch: 4))
        try store.save(.home(epoch: 5, lastLoan: nil))
        #expect(try store.load().get() == .home(epoch: 5, lastLoan: nil))
    }

    @Test("The phone's file lives in Documents") func phoneLocation() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #expect(WatchLoanStore<PhoneLoanState>.phone.url == documents.appendingPathComponent("watch-loan-state.json"))
    }

    @Test("Envelope round-trips with protocol version, epoch, message id and sent time") func envelope() throws {
        let envelope = WatchLoanEnvelope(
            protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
            messageID: F.requestB,
            sentAt: F.now,
            message: F.message(4, .grant(requestID: F.requestA, expiresAt: F.now.addingTimeInterval(30)))
        )
        #expect(WatchLoanWire.decode(try WatchLoanWire.encode(envelope)) == .message(envelope))
    }

    @Test("Another protocol version is reported, not decoded") func otherVersion() throws {
        let envelope = WatchLoanEnvelope(
            protocolVersion: 2,
            messageID: F.requestB,
            sentAt: F.now,
            message: F.message(4, .holding)
        )
        #expect(WatchLoanWire.decode(try WatchLoanWire.encode(envelope)) == .unsupportedVersion(2))
    }

    @Test("Stop and revoke parse regardless of protocol version and extra fields (V2-10)") func stopEnvelope() throws {
        let revoke = WatchLoanStop(kind: .revoke, epoch: 7)
        #expect(WatchLoanWire.decode(try WatchLoanWire.encode(revoke)) == .stop(revoke))
        let future = #"{"protocolVersion":99,"stop":{"kind":"stop","epoch":3,"reason":"new"},"extra":[1,2]}"#
        #expect(WatchLoanWire.decode(Data(future.utf8)) == .stop(WatchLoanStop(kind: .stop, epoch: 3)))
    }

    @Test("Garbage is malformed") func malformed() {
        #expect(WatchLoanWire.decode(Data("nope".utf8)) == .malformed)
        #expect(WatchLoanWire.decode(Data(#"{"protocolVersion":1}"#.utf8)) == .malformed)
    }
}
