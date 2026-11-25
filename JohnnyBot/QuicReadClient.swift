import CryptoKit
import Foundation
import Network
import Security

/// One reliable bidirectional QUIC stream for a file or a replication scope.
@MainActor final class QuicReadClient {
    private let endpoint: NWEndpoint
    private let service: String
    private let pin: String
    private let identity: DeviceIdentity
    private var connections: [UUID: NWConnection] = [:]

    init?(address: String, fingerprint: String, identity: DeviceIdentity) {
        guard let parts = URLComponents(string: address), let host = parts.host,
              let port = UInt16(exactly: parts.port ?? 8883).flatMap(NWEndpoint.Port.init(rawValue:)) else { return nil }
        endpoint = .hostPort(host: .init(host), port: port)
        service = String(parts.path.dropFirst())
        pin = fingerprint.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.identity = identity
    }

    func close() {
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func read(_ count: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error.map { $0 as Error } ?? URLError(.networkConnectionLost)) }
            }
        }
    }

    private func stream(_ op: String, fields: [String: Any], follow: Bool = false,
                        consume: (UInt8, Data) throws -> Void) async throws {
        var command = fields
        command["cmd_id"] = UUID().uuidString
        command["op"] = op
        let body = try JSONSerialization.data(withJSONObject: ["Host": service, "Device": identity.id,
                    "Proof": try identity.password(pin: pin, context: "johnnybot-read-v1"), "Follow": follow, "Command": command])
        guard body.count <= 16384 else { throw URLError(.dataLengthExceedsMaximum) }
        var size = UInt32(body.count).bigEndian
        let request = withUnsafeBytes(of: &size) { Data($0) } + body
        let options = NWProtocolQUIC.Options(alpn: ["johnnybot-read-v1"])
        let expected = pin
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, done in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            done(chain?.first.map { SHA256.hash(data: SecCertificateCopyData($0) as Data).hexString == expected } == true)
        }, .global())
        let connection = NWConnection(to: endpoint, using: NWParameters(quic: options))
        let id = UUID()
        connections[id] = connection
        defer { connections[id] = nil; connection.cancel() }
        connection.start(queue: .global())
        let timeout = Task {
            try await Task.sleep(for: .seconds(3))
            connection.cancel()
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error { waiter.resume(throwing: error) } else { waiter.resume() }
                })
            }
            while true {
                let header = try await read(5, from: connection)
                timeout.cancel()
                let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
                guard length <= 256 * 1024 else { throw URLError(.cannotParseResponse) }
                let data = length == 0 ? Data() : try await read(length, from: connection)
                try Task.checkCancellation()
                switch header[0] {
                case 3 where length == 0: return
                case 4: throw ACPFailure(message: "服务器无法继续读取", reason: String(decoding: data, as: UTF8.self))
                default: try consume(header[0], data)
                }
            }
        } onCancel: { connection.cancel() }
    }

    func file(_ fields: [String: Any], firstPage: ((String) -> Void)? = nil) async throws -> String {
        var data = Data()
        try await stream("file.read", fields: fields) { kind, chunk in
            guard kind == 1 else { throw URLError(.cannotParseResponse) }
            if data.isEmpty, chunk.count == 64 * 1024, let firstPage,
               let newline = chunk.lastIndex(of: 10) {
                firstPage(String(decoding: chunk[...newline], as: UTF8.self))
            }
            data.append(chunk)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func pages(_ fields: [String: Any], follow: Bool, receive: ([String: Any]) throws -> Void) async throws {
        try await stream("sync.pull", fields: fields, follow: follow) { kind, chunk in
            guard kind == 2, let page = try JSONSerialization.jsonObject(with: chunk) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            try receive(page)
        }
    }
}
