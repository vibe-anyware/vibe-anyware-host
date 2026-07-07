import CryptoKit
import Foundation

public struct RemoteCommandEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let sequence: Int
    public let issuedAtMillis: Int64
    public let command: RemoteCommand

    public init(
        version: Int = RemoteCommandEnvelope.currentVersion,
        sequence: Int,
        issuedAtMillis: Int64,
        command: RemoteCommand
    ) {
        self.version = version
        self.sequence = sequence
        self.issuedAtMillis = issuedAtMillis
        self.command = command
    }
}

public enum RemoteCommandCodec {
    public static func encodeLine(_ envelope: RemoteCommandEnvelope) throws -> Data {
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        return data
    }

    public static func encodeWireFrame(
        _ envelope: RemoteCommandEnvelope,
        accessToken: String? = nil
    ) throws -> Data {
        let plainFrame = try encodePlainWireFrame(envelope)
        guard let key = secureKey(accessToken: accessToken) else {
            return plainFrame
        }
        return try encodeSecureLine(plainFrame, key: key)
    }

    private static func encodePlainWireFrame(_ envelope: RemoteCommandEnvelope) throws -> Data {
        switch envelope.command {
        case let .mouseMove(delta):
            return encodeFastLine([
                "m",
                "\(envelope.sequence)",
                "\(envelope.issuedAtMillis)",
                encodeNumber(delta.dx),
                encodeNumber(delta.dy)
            ])
        case let .mouseScroll(delta):
            return encodeFastScrollLine(envelope: envelope, delta: delta, phase: .change)
        case let .mouseScrollPhase(delta, phase):
            return encodeFastScrollLine(envelope: envelope, delta: delta, phase: phase)
        case let .mouseButton(command):
            return encodeFastLine([
                "b",
                "\(envelope.sequence)",
                "\(envelope.issuedAtMillis)",
                command.button.rawValue,
                command.phase.rawValue,
                "\(command.clickCount)"
            ])
        case .text, .key, .keyCombo, .shortcut, .ping:
            return try encodeLine(envelope)
        }
    }

    public static func decodeLine(
        _ data: Data,
        accessToken: String? = nil,
        requiresSecure: Bool = false
    ) throws -> RemoteCommandEnvelope {
        let line = data.last == 0x0A ? data.dropLast() : data[...]
        if line.starts(with: secureFramePrefix) {
            guard let key = secureKey(accessToken: accessToken) else {
                throw RemoteCommandCodecError.missingSecureAccessToken
            }
            let decryptedFrame = try decodeSecureLine(Data(line.dropFirst(secureFramePrefix.count)), key: key)
            return try decodeLine(decryptedFrame)
        }
        if requiresSecure {
            throw RemoteCommandCodecError.invalidSecureFrame
        }
        if let first = line.first, first != 0x7B {
            return try decodeFastLine(Data(line))
        }
        return try decoder.decode(RemoteCommandEnvelope.self, from: Data(line))
    }

    private static func encodeFastScrollLine(
        envelope: RemoteCommandEnvelope,
        delta: PointerDelta,
        phase: ScrollPhase
    ) -> Data {
        encodeFastLine([
            "s",
            "\(envelope.sequence)",
            "\(envelope.issuedAtMillis)",
            encodeNumber(delta.dx),
            encodeNumber(delta.dy),
            phase.rawValue
        ])
    }

    private static func encodeFastLine(_ parts: [String]) -> Data {
        Data((parts.joined(separator: " ") + "\n").utf8)
    }

    private static func encodeSecureLine(_ data: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw RemoteCommandCodecError.invalidSecureFrame
        }
        return Data("e \(combined.base64EncodedString())\n".utf8)
    }

    private static func decodeSecureLine(_ data: Data, key: SymmetricKey) throws -> Data {
        let encoded = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let combined = Data(base64Encoded: encoded) else {
            throw RemoteCommandCodecError.invalidSecureFrame
        }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
        } catch {
            throw RemoteCommandCodecError.invalidSecureFrame
        }
    }

    private static func decodeFastLine(_ data: Data) throws -> RemoteCommandEnvelope {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: " ")
        guard parts.count >= 3,
              let sequence = Int(parts[1]),
              let issuedAtMillis = Int64(parts[2]) else {
            throw RemoteCommandCodecError.invalidFastFrame
        }

        let command: RemoteCommand
        switch parts[0] {
        case "m":
            guard parts.count == 5,
                  let dx = Double(parts[3]),
                  let dy = Double(parts[4]) else {
                throw RemoteCommandCodecError.invalidFastFrame
            }
            command = .mouseMove(PointerDelta(dx: dx, dy: dy))
        case "s":
            guard parts.count == 6,
                  let dx = Double(parts[3]),
                  let dy = Double(parts[4]),
                  let phase = ScrollPhase(rawValue: String(parts[5])) else {
                throw RemoteCommandCodecError.invalidFastFrame
            }
            command = .mouseScrollPhase(PointerDelta(dx: dx, dy: dy), phase)
        case "b":
            guard parts.count == 6,
                  let button = MouseButton(rawValue: String(parts[3])),
                  let phase = MouseButtonPhase(rawValue: String(parts[4])),
                  let clickCount = Int(parts[5]) else {
                throw RemoteCommandCodecError.invalidFastFrame
            }
            command = .mouseButton(
                MouseButtonCommand(button: button, phase: phase, clickCount: clickCount)
            )
        default:
            throw RemoteCommandCodecError.invalidFastFrame
        }

        return RemoteCommandEnvelope(
            sequence: sequence,
            issuedAtMillis: issuedAtMillis,
            command: command
        )
    }

    private static func encodeNumber(_ value: Double) -> String {
        String(value)
    }

    private static func secureKey(accessToken: String?) -> SymmetricKey? {
        guard let accessToken else {
            return nil
        }
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return nil
        }
        let keyMaterial = Data("VibeAnyware relay command v1:\(trimmedToken)".utf8)
        return SymmetricKey(data: Data(SHA256.hash(data: keyMaterial)))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
    private static let secureFramePrefix = Data("e ".utf8)
}

public enum RemoteCommandCodecError: Error, Equatable {
    case invalidFastFrame
    case missingSecureAccessToken
    case invalidSecureFrame
}

extension RemoteCommandCodecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFastFrame:
            "The command frame is malformed."
        case .missingSecureAccessToken:
            "The host is missing the command key required to decrypt this frame."
        case .invalidSecureFrame:
            "The command frame could not be decrypted. The phone and Mac are probably using different command keys."
        }
    }
}

public struct LineFrameBuffer: Equatable, Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[..<newlineIndex]
            if !frame.isEmpty {
                frames.append(Data(frame))
            }
            buffer.removeSubrange(buffer.startIndex ... newlineIndex)
        }

        return frames
    }
}
