// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import NIOCore
import XCTest

@testable import NIOSFTP

final class SFTPMessageTests: XCTestCase {
    private func buffer(_ string: String) -> ByteBuffer {
        ByteBuffer(string: string)
    }

    func testVersionFrameRoundTrip() throws {
        let allocator = ByteBufferAllocator()
        let encodedFrame = SFTPResponseEncoder.encodeVersion(
            .v3,
            extensions: [.init(name: "posix-rename@openssh.com", data: self.buffer("1"))],
            allocator: allocator
        )

        var buffer = encodedFrame
        let frame = try buffer.readSFTPFrame()
        XCTAssertEqual(
            frame,
            SFTPInboundPacket.version(.v3, [.init(name: "posix-rename@openssh.com", data: self.buffer("1"))])
        )
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testOpenRequestRoundTrip() throws {
        let allocator = ByteBufferAllocator()
        let attributes = SFTPAttributes(size: 7, permissions: 0o644)
        let requestFrame = SFTPRequestEncoder.encode(
            .open(path: "/tmp/file.txt", pflags: [.read, .write, .create], attributes: attributes),
            requestID: 42,
            allocator: allocator
        )

        var encoded = requestFrame
        guard let length = encoded.readInteger(as: UInt32.self),
            let type = encoded.readInteger(as: UInt8.self),
            let payload = encoded.readSlice(length: Int(length) - 1)
        else {
            XCTFail("Missing SFTP frame data")
            return
        }

        let decoded = try SFTPRequestDecoder.decode(type: type, payload: payload)
        XCTAssertEqual(decoded.0, 42)
        XCTAssertEqual(
            decoded.1,
            SFTPRequestMessage.open(path: "/tmp/file.txt", pflags: [.read, .write, .create], attributes: attributes)
        )
    }

    func testPartialFrameReturnsNil() throws {
        let allocator = ByteBufferAllocator()
        let fullFrame = SFTPResponseEncoder.encode(.status(.init(code: .ok)), requestID: 1, allocator: allocator)
        let bytes = Array(fullFrame.readableBytesView)
        var buffer = allocator.buffer(capacity: bytes.count)

        for byte in bytes.dropLast() {
            buffer.writeInteger(byte)
            XCTAssertNil(try buffer.readSFTPFrame())
        }

        buffer.writeInteger(bytes.last!)
        XCTAssertEqual(
            try buffer.readSFTPFrame(),
            SFTPInboundPacket.response(id: 1, .status(.init(code: .ok)))
        )
    }

    func testExtendedRequestRoundTripPreservesRawPayload() throws {
        let allocator = ByteBufferAllocator()
        var payload = allocator.buffer(capacity: 64)
        payload.writeSFTPString("/tmp/source")
        payload.writeSFTPString("/tmp/destination")

        let requestFrame = SFTPRequestEncoder.encode(
            .extended(name: SFTPExtensionName.posixRename.rawValue, data: payload),
            requestID: 7,
            allocator: allocator
        )

        var encoded = requestFrame
        guard let length = encoded.readInteger(as: UInt32.self),
            let type = encoded.readInteger(as: UInt8.self),
            let framePayload = encoded.readSlice(length: Int(length) - 1)
        else {
            XCTFail("Missing SFTP frame data")
            return
        }

        let decoded = try SFTPRequestDecoder.decode(type: type, payload: framePayload)
        XCTAssertEqual(decoded.0, 7)
        XCTAssertEqual(decoded.1, .extended(name: SFTPExtensionName.posixRename.rawValue, data: payload))
    }
}
