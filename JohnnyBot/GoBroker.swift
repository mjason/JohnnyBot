import CryptoKit
import Foundation
import Network
import Security

struct DeviceIdentity {
    let key: Curve25519.Signing.PrivateKey

    var id: String { SHA256.hash(data: key.publicKey.rawRepresentation).prefix(16).hexString }
    var publicLine: String {
        let algorithm = Data("ssh-ed25519".utf8)
        func field(_ data: Data) -> Data { Data([0, 0, 0, UInt8(data.count)]) + data }
        return "ssh-ed25519 " + (field(algorithm) + field(key.publicKey.rawRepresentation)).base64EncodedString() + " JohnnyBot"
    }

    func password(pin: String) throws -> String {
        func url64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let seconds = String(Int(Date().timeIntervalSince1970))
        let nonce = url64(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let message = ["johnnybot-mqtt-auth-v1", pin, id, seconds, nonce].joined(separator: "\n")
        return [seconds, nonce, url64(try key.signature(for: Data(message.utf8)))].joined(separator: ".")
    }
}

extension Sequence where Element == UInt8 {
    nonisolated var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private struct PacketReader {
    let bytes: [UInt8]
    var index = 0

    mutating func byte() throws -> Int {
        guard index < bytes.count else { throw ACPFailure(message: "MQTT 数据包不完整") }
        defer { index += 1 }
        return Int(bytes[index])
    }

    mutating func word() throws -> Int { try byte() * 256 + byte() }

    mutating func length() throws -> Int {
        var value = 0
        for shift in [0, 7, 14, 21] {
            let b = try byte()
            value |= (b & 127) << shift
            if b < 128 { return value }
        }
        throw ACPFailure(message: "MQTT 数据包长度无效")
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count <= bytes.count - index else { throw ACPFailure(message: "MQTT 数据包不完整") }
        defer { index += count }
        return bytes[index..<(index + count)]
    }
}

@MainActor
final class GoBroker {
    let deviceID: String
    let prefix: String
    private let connection: NWConnection
    private let identity: DeviceIdentity
    private let pin: String
    var onHint: ((String) -> Void)?
    var onClose: ((Error) -> Void)?
    private var handshake: CheckedContinuation<Void, Error>?
    private var replies: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var subscriptions: [Int: CheckedContinuation<Void, Error>] = [:]
    private var publishes: [Int: String] = [:]
    private var sequence = 0
    private var buffer = Data()
    private var closed = false
    private var heartbeat: Task<Void, Never>?
    private var lastPacket = ContinuousClock.now

    init(address: String, fingerprint: String, identity: DeviceIdentity) throws {
        guard let url = URLComponents(string: address), url.scheme == "mqtts", let host = url.host,
              let port = UInt16(exactly: url.port ?? 8883).flatMap(NWEndpoint.Port.init(rawValue:)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: #"^/[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else {
            throw ACPFailure(message: "地址格式应为 mqtts://主机:8883/服务标识")
        }
        let pin = fingerprint.lowercased().replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard pin.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw ACPFailure(message: "请填写服务器的 SHA-256 证书指纹")
        }
        self.pin = pin
        self.identity = identity
        deviceID = identity.id
        prefix = "jb/v1" + url.path + "/"
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first else { complete(false); return }
            complete(SHA256.hash(data: SecCertificateCopyData(leaf) as Data).hexString == pin)
        }, DispatchQueue.main)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: .init(host), port: port, using: NWParameters(tls: tls, tcp: tcp))
    }

    func start() async throws {
        let password = try identity.password(pin: pin)
        var body = string("MQTT") + [5, 0xC2, 0, 30, 0]
        body += string(deviceID) + string("ed25519-v1") + string(password)
        let connectBody = body
        let deadline = Task {
            try await Task.sleep(for: .seconds(15))
            close(ACPFailure(message: "MQTT 连接超时，请核对服务器地址和证书指纹"))
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            handshake = continuation
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    switch state {
                    case .ready: self.receive(); self.send(0x10, connectBody)
                    case let .failed(error): self.close(error)
                    case .cancelled: self.close(URLError(.cancelled))
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
        }
        try await subscribe("reply/" + deviceID)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                guard let self, !self.closed else { return }
                if self.lastPacket.duration(to: .now) > .seconds(40) { self.close(URLError(.timedOut)); return }
                self.send(0xc0, [])
            }
        }
    }

    private func word(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
    private func string(_ s: String) -> [UInt8] { word(s.utf8.count) + s.utf8 }

    private func nextID() throws -> Int {
        for _ in 0..<65535 {
            sequence = sequence % 65535 + 1
            if subscriptions[sequence] == nil && publishes[sequence] == nil { return sequence }
        }
        throw ACPFailure(message: "MQTT 正在处理过多请求")
    }

    func subscribe(_ topic: String, enabled: Bool = true) async throws {
        guard !closed else { throw URLError(.notConnectedToInternet) }
        let id = try nextID()
        let deadline = Task {
            try await Task.sleep(for: .seconds(15))
            close(URLError(.timedOut))
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            subscriptions[id] = continuation
            let body = word(id) + [0] + string(prefix + topic)
            if enabled { send(0x82, body + [1]) }
            else { send(0xa2, body) }
        }
    }

    func request(id: String, payload: Data, timeout: Duration = .seconds(45)) async throws -> [String: Any] {
        guard !closed else { throw URLError(.notConnectedToInternet) }
        guard payload.count <= 128 * 1024 else { throw ACPFailure(message: "请求超过服务端的 128 KiB 上限") }
        guard replies[id] == nil else { throw ACPFailure(message: "命令正在执行") }
        let packet = try nextID()
        let deadline = Task {
            try await Task.sleep(for: timeout)
            replies.removeValue(forKey: id)?.resume(throwing: URLError(.timedOut))
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            replies[id] = continuation
            publishes[packet] = id
            send(0x32, string(prefix + "cmd/" + deviceID) + word(packet) + [0] + payload)
        }
    }

    private func send(_ header: UInt8, _ body: [UInt8]) {
        var n = body.count
        var data = Data([header])
        repeat {
            let digit = n % 128
            n /= 128
            data.append(UInt8(digit + (n == 0 ? 0 : 128)))
        } while n > 0
        data.append(contentsOf: body)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { MainActor.assumeIsolated { self?.close(error) } }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, end, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                do {
                    if let data { self.buffer.append(data); try self.drain() }
                    if let error { throw error }
                    if end { throw URLError(.networkConnectionLost) }
                    self.receive()
                } catch { self.close(error) }
            }
        }
    }

    private func drain() throws {
        while buffer.count >= 2 {
            var header = PacketReader(bytes: Array(buffer.prefix(5)), index: 1)
            guard header.bytes.dropFirst().contains(where: { $0 < 128 }) || header.bytes.count == 5 else { return }
            let size = try header.length()
            guard size <= 256 * 1024 else { throw ACPFailure(message: "MQTT 数据包过大") }
            let total = size + header.index
            guard buffer.count >= total else { return }
            let type = header.bytes[0]
            var reader = PacketReader(bytes: Array(buffer.prefix(total).dropFirst(header.index)))
            buffer.removeFirst(total)
            lastPacket = .now
            switch type >> 4 {
            case 2:
                _ = try reader.byte()
                guard try reader.byte() == 0 else { throw ACPFailure(message: "设备认证失败，请确认服务器已添加此设备公钥，并核对系统时间") }
                handshake?.resume()
                handshake = nil
            case 9, 11:
                let id = try reader.word()
                let length = try reader.length()
                _ = try reader.take(length)
                guard try reader.byte() < 128 else { throw ACPFailure(message: "服务器拒绝订阅，请核对服务标识") }
                subscriptions.removeValue(forKey: id)?.resume()
            case 4:
                let id = try reader.word()
                if let cmd = publishes.removeValue(forKey: id), reader.index < reader.bytes.count, try reader.byte() >= 128 {
                    replies.removeValue(forKey: cmd)?.resume(throwing: ACPFailure(message: "服务器拒绝 MQTT 命令"))
                }
            case 3:
                let count = try reader.word()
                let topic = String(decoding: try reader.take(count), as: UTF8.self)
                let qos = (type >> 1) & 3
                guard qos <= 1 else { throw ACPFailure(message: "不支持的 MQTT QoS") }
                let id = qos == 1 ? try reader.word() : nil
                let properties = try reader.length()
                _ = try reader.take(properties)
                let data = Data(reader.bytes.dropFirst(reader.index))
                if let id { send(0x40, word(id)) }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if topic == prefix + "reply/" + deviceID, let cmd = json["cmd_id"] as? String {
                    replies.removeValue(forKey: cmd)?.resume(returning: json)
                } else if let scope = json["scope"] as? String, topic == prefix + "ev/" + scope { onHint?(scope) }
            case 13: break
            case 14: throw URLError(.networkConnectionLost)
            default: throw ACPFailure(message: "MQTT 包类型无效")
            }
        }
    }

    func close(_ error: Error = URLError(.cancelled)) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        connection.cancel()
        handshake?.resume(throwing: error)
        handshake = nil
        for waiter in subscriptions.values { waiter.resume(throwing: error) }
        for waiter in replies.values { waiter.resume(throwing: error) }
        subscriptions.removeAll()
        replies.removeAll()
        onClose?(error)
    }
}
