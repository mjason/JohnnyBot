import CryptoKit
import Foundation

struct ACPReplyTiming: Codable, Equatable {
    let elapsed: Duration
    let wasStopped: Bool
}

struct ACPReplyTimingStore {
    private let defaults = UserDefaults.standard

    func timings(endpoint: URL, sessionID: String) -> [String: ACPReplyTiming] {
        guard let data = defaults.data(forKey: storageKey(endpoint: endpoint, sessionID: sessionID)) else { return [:] }
        return (try? JSONDecoder().decode([String: ACPReplyTiming].self, from: data)) ?? [:]
    }

    func record(_ timing: ACPReplyTiming, for entryID: String, endpoint: URL, sessionID: String) {
        var saved = timings(endpoint: endpoint, sessionID: sessionID)
        saved[entryID] = timing
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: storageKey(endpoint: endpoint, sessionID: sessionID))
        }
    }

    func remove(endpoint: URL, sessionID: String) {
        defaults.removeObject(forKey: storageKey(endpoint: endpoint, sessionID: sessionID))
    }

    private func storageKey(endpoint: URL, sessionID: String) -> String {
        let identity = Data("\(endpoint.absoluteString)\u{0}\(sessionID)".utf8)
        let digest = Data(SHA256.hash(data: identity)).base64EncodedString()
        return "acpReplyTimings.v1.\(digest)"
    }
}
