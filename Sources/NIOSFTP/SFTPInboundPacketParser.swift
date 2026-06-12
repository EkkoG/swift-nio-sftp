// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import NIOCore

enum SFTPInboundPacket: Equatable {
    case version(SFTPVersion, [SFTPExtension])
    case response(id: UInt32, SFTPResponseMessage)
}

enum SFTPInboundPacketParser {
    static func parse(type: UInt8, payload: ByteBuffer) throws -> SFTPInboundPacket {
        var payload = payload

        switch type {
        case SFTPPacketType.version:
            guard let version = payload.readInteger(as: UInt32.self) else {
                throw SFTPError.protocolViolation("Missing SFTP version field")
            }
            var extensions: [SFTPExtension] = []
            while payload.readableBytes > 0 {
                guard let name = payload.readSFTPString(), let data = payload.readSFTPStringBuffer() else {
                    throw SFTPError.protocolViolation("Invalid SFTP extension payload")
                }
                extensions.append(.init(name: name, data: data))
            }
            return .version(.init(version), extensions)
        case SFTPPacketType.status:
            guard let id = payload.readInteger(as: UInt32.self),
                let codeRaw = payload.readInteger(as: UInt32.self),
                let message = payload.readSFTPString(),
                let languageTag = payload.readSFTPString()
            else {
                throw SFTPError.protocolViolation("Invalid STATUS packet")
            }
            return .response(id: id, .status(.init(code: .init(rawValue: codeRaw), message: message, languageTag: languageTag)))
        case SFTPPacketType.handle:
            guard let id = payload.readInteger(as: UInt32.self),
                let handle = payload.readSFTPStringBuffer()
            else {
                throw SFTPError.protocolViolation("Invalid HANDLE packet")
            }
            return .response(id: id, .handle(handle))
        case SFTPPacketType.data:
            guard let id = payload.readInteger(as: UInt32.self),
                let data = payload.readSFTPStringBuffer()
            else {
                throw SFTPError.protocolViolation("Invalid DATA packet")
            }
            return .response(id: id, .data(data))
        case SFTPPacketType.name:
            guard let id = payload.readInteger(as: UInt32.self),
                let count = payload.readInteger(as: UInt32.self)
            else {
                throw SFTPError.protocolViolation("Invalid NAME packet")
            }
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let filename = payload.readSFTPString(),
                    let longname = payload.readSFTPString()
                else {
                    throw SFTPError.protocolViolation("Invalid NAME entry")
                }
                let attributes = try payload.readSFTPAttributes()
                entries.append(.init(filename: filename, longname: longname, attributes: attributes))
            }
            return .response(id: id, .name(entries))
        case SFTPPacketType.attrs:
            guard let id = payload.readInteger(as: UInt32.self) else {
                throw SFTPError.protocolViolation("Invalid ATTRS packet")
            }
            let attributes = try payload.readSFTPAttributes()
            return .response(id: id, .attributes(attributes))
        case SFTPPacketType.extendedReply:
            guard let id = payload.readInteger(as: UInt32.self) else {
                throw SFTPError.protocolViolation("Invalid EXTENDED_REPLY packet")
            }
            return .response(id: id, .extendedReply(payload))
        default:
            throw SFTPError.protocolViolation("Unsupported SFTP packet type \(type)")
        }
    }
}
