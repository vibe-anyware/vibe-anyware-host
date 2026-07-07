import Foundation

struct OfficialRelaySetupKey: Codable, Equatable, Sendable {
    let v: Int
    let endpoint: String
    let serverId: String
    let accessToken: String
    let commandKey: String

    init(
        v: Int = 1,
        endpoint: String,
        serverId: String,
        accessToken: String,
        commandKey: String
    ) {
        self.v = v
        self.endpoint = endpoint
        self.serverId = serverId
        self.accessToken = accessToken
        self.commandKey = commandKey
    }

    static func encode(
        endpoint: String,
        serverId: String,
        accessToken: String,
        commandKey: String
    ) throws -> String {
        let payload = OfficialRelaySetupKey(
            endpoint: endpoint,
            serverId: serverId,
            accessToken: accessToken,
            commandKey: commandKey
        )
        let data = try JSONEncoder().encode(payload)
        return data.base64URLEncodedString()
    }

    static func decode(_ value: String) throws -> OfficialRelaySetupKey {
        guard let data = Data(base64URLEncoded: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OfficialRelaySetupKeyError.invalidEncoding
        }

        let payload: OfficialRelaySetupKey
        do {
            payload = try JSONDecoder().decode(OfficialRelaySetupKey.self, from: data)
        } catch {
            throw OfficialRelaySetupKeyError.invalidPayload
        }

        guard payload.v == 1,
              !payload.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.serverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.commandKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfficialRelaySetupKeyError.invalidPayload
        }

        return payload
    }
}

enum OfficialRelaySetupKeyError: LocalizedError, Equatable {
    case invalidEncoding
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "Official relay setup key is not valid base64url."
        case .invalidPayload:
            "Official relay setup key is invalid or incomplete."
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        let base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64.padding(
            toLength: base64.count + (4 - base64.count % 4) % 4,
            withPad: "=",
            startingAt: 0
        )
        self.init(base64Encoded: padded)
    }
}
