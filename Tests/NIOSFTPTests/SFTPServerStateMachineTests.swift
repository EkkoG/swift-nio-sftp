// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import NIOCore
import XCTest

@testable import NIOSFTP

final class SFTPServerStateMachineTests: XCTestCase {
    func testSubsystemSuccessAndInitTransitionToReady() {
        var stateMachine = SFTPServerStateMachine()
        let extensions = [SFTPExtension(name: SFTPExtensionName.fsync.rawValue, data: ByteBuffer(string: "1"))]

        assertAction(stateMachine.receiveSubsystemRequest(subsystem: "sftp", wantReply: true), matches: .sendSubsystemSuccess)
        assertAction(stateMachine.receivePacket( .`init`(.v3), extensions: extensions), matches: .sendVersion(.v3, extensions))
    }

    func testWrongSubsystemIsRejected() {
        var stateMachine = SFTPServerStateMachine()
        assertAction(stateMachine.receiveSubsystemRequest(subsystem: "exec", wantReply: true), matches: .sendSubsystemFailure)
    }

    func testLowerVersionFailsSession() {
        var stateMachine = SFTPServerStateMachine()
        _ = stateMachine.receiveSubsystemRequest(subsystem: "sftp", wantReply: true)

        guard case .failSession(let error) = stateMachine.receivePacket( .`init`(SFTPVersion(2)), extensions: []) else {
            return XCTFail("Expected unsupported version failure")
        }

        XCTAssertEqual(error as? SFTPError, .unsupportedVersion(2))
    }

    func testRequestBeforeInitFailsSession() {
        var stateMachine = SFTPServerStateMachine()
        _ = stateMachine.receiveSubsystemRequest(subsystem: "sftp", wantReply: true)

        guard case .failSession(let error) = stateMachine.receivePacket(.request(id: 1, .stat(path: "/file")), extensions: []) else {
            return XCTFail("Expected request-before-init failure")
        }

        XCTAssertEqual(
            error as? SFTPError,
            .unexpectedResponse("Received request before startup completed")
        )
    }

    func testDataBeforeSubsystemFailsSession() {
        var stateMachine = SFTPServerStateMachine()

        guard case .failSession(let error) = stateMachine.validateDataPacketBeforeParse() else {
            return XCTFail("Expected pre-subsystem data failure")
        }

        XCTAssertEqual(
            error as? SFTPError,
            .protocolViolation("Received SFTP data before subsystem accepted")
        )
    }

    private func assertAction(_ action: SFTPServerStateMachine.Action, matches expected: ExpectedAction) {
        switch (action, expected) {
        case (.sendSubsystemSuccess, .sendSubsystemSuccess), (.sendSubsystemFailure, .sendSubsystemFailure):
            return
        case (.sendVersion(let actualVersion, let actualExtensions), .sendVersion(let expectedVersion, let expectedExtensions)):
            XCTAssertEqual(actualVersion, expectedVersion)
            XCTAssertEqual(actualExtensions, expectedExtensions)
        default:
            XCTFail("Unexpected action \(action) for expected \(expected)")
        }
    }
}

private enum ExpectedAction {
    case sendSubsystemSuccess
    case sendSubsystemFailure
    case sendVersion(SFTPVersion, [SFTPExtension])
}
