// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import NIOCore

extension ByteBuffer {
    mutating func readSFTPStringBuffer() -> ByteBuffer? {
        guard let length = self.readInteger(as: UInt32.self) else {
            return nil
        }
        return self.readSlice(length: Int(length))
    }

    mutating func readSFTPString() -> String? {
        guard let bytes = self.readSFTPStringBuffer() else {
            return nil
        }
        return String(buffer: bytes)
    }

    @discardableResult
    mutating func writeSFTPString<Buffer: Collection>(_ bytes: Buffer) -> Int where Buffer.Element == UInt8 {
        let written = self.writeInteger(UInt32(bytes.count))
        return written + self.writeBytes(bytes)
    }

    @discardableResult
    mutating func writeSFTPString(_ value: String) -> Int {
        self.writeSFTPString(value.utf8)
    }

    @discardableResult
    mutating func writeSFTPStringBuffer(_ value: inout ByteBuffer) -> Int {
        let written = self.writeInteger(UInt32(value.readableBytes))
        let bufferWritten = self.writeBuffer(&value)
        return written + bufferWritten
    }

    @discardableResult
    mutating func writeSFTPImmutableStringBuffer(_ value: ByteBuffer) -> Int {
        var copy = value
        return self.writeSFTPStringBuffer(&copy)
    }

    mutating func readSFTPFrame() throws -> SFTPInboundPacket? {
        guard let length = self.getInteger(at: self.readerIndex, as: UInt32.self) else {
            return nil
        }

        guard length >= 1 else {
            throw SFTPError.protocolViolation("SFTP packet length must include a type byte")
        }

        let frameLength = Int(length)
        guard self.readableBytes >= frameLength + 4 else {
            return nil
        }

        _ = self.readInteger(as: UInt32.self)
        guard let typeRaw = self.readInteger(as: UInt8.self) else {
            return nil
        }
        guard let payload = self.readSlice(length: frameLength - 1) else {
            return nil
        }
        return try SFTPInboundPacketParser.parse(type: typeRaw, payload: payload)
    }

    @discardableResult
    mutating func writeSFTPFrame(type: UInt8, bodyWriter: (inout ByteBuffer) throws -> Void) rethrows -> Int {
        let lengthIndex = self.writerIndex
        self.writeInteger(UInt32(0))
        self.writeInteger(type)
        let bodyStart = self.writerIndex
        try bodyWriter(&self)
        let totalLength = self.writerIndex - bodyStart + 1
        self.setInteger(UInt32(totalLength), at: lengthIndex)
        return totalLength + 4
    }
}
