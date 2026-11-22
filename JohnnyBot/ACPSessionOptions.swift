import Foundation

struct ACPCommand: Decodable, Identifiable {
    struct Input: Decodable {
        let hint: String
    }

    let name: String
    let description: String
    let input: Input?
    var id: String { name }
    var invocation: String { "/" + name }

    static func matches(in draft: String, commands: [Self]) -> [Self] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        return commands.filter { $0.invocation.lowercased().hasPrefix(draft.lowercased()) }
    }
}

struct ACPConfigOption: Identifiable {
    struct Choice: Decodable, Identifiable {
        let value: String
        let name: String
        let description: String?
        var id: String { value }
    }

    struct Group: Identifiable {
        let id: String
        let name: String?
        let choices: [Choice]
    }

    enum Control {
        case select(current: String, groups: [Group])
        case boolean(Bool)
    }

    let id: String
    let name: String
    let description: String?
    let control: Control

    var currentLabel: String {
        switch control {
        case let .select(current, groups):
            return groups.lazy.flatMap(\.choices).first { $0.id == current }?.name ?? current
        case let .boolean(enabled):
            return enabled ? "开" : "关"
        }
    }

    static func decode(_ values: [[String: Any]]) -> [Self] {
        values.compactMap { fields in
            guard let id = fields["id"] as? String, let name = fields["name"] as? String else { return nil }
            let control: Control
            switch fields["type"] as? String {
            case "select":
                guard let current = fields["currentValue"] as? String,
                      let options = fields["options"] as? [[String: Any]] else { return nil }
                let groups: [Group]
                if options.first?["group"] != nil {
                    groups = options.compactMap { group in
                        guard let id = group["group"] as? String, let name = group["name"] as? String,
                              let options = group["options"] as? [[String: Any]] else { return nil }
                        return Group(id: id, name: name, choices: options.compactMap { decodeACP(Choice.self, from: $0) })
                    }
                } else {
                    groups = [Group(id: "", name: nil, choices: options.compactMap { decodeACP(Choice.self, from: $0) })]
                }
                control = .select(current: current, groups: groups)
            case "boolean":
                guard let current = fields["currentValue"] as? Bool else { return nil }
                control = .boolean(current)
            default:
                return nil
            }
            return Self(id: id, name: name, description: fields["description"] as? String,
                        control: control)
        }
    }
}

struct ACPSessionModes: Decodable {
    struct Mode: Decodable, Identifiable {
        let id: String
        let name: String
        let description: String?
    }

    let currentModeId: String
    let availableModes: [Mode]
}

struct ACPSessionOptions {
    var commands: [ACPCommand] = []
    var config: [ACPConfigOption]?
    var modes: ACPSessionModes?
    var currentModeID: String?
}

func decodeACP<T: Decodable>(_ type: T.Type, from object: Any) -> T? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
