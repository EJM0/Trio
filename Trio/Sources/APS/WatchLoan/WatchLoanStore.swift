import Foundation

/// One loan state file per device, written atomically. The only IO in `WatchLoan`.
struct WatchLoanStore<State: Codable> {
    let url: URL

    /// `nil` when there is no file. A file that exists but can't be decoded is a failure, never `nil`.
    func load() -> Result<State?, Error> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
        return Result { try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) }
    }

    func save(_ state: State) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

extension WatchLoanStore where State == PhoneLoanState {
    static var phone: WatchLoanStore {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return WatchLoanStore(url: documents.appendingPathComponent("watch-loan-state.json"))
    }
}
