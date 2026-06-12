// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSFTP

final class SFTPClientStateMachineTests: XCTestCase {
    func testStartupFlowTransitionsToReady() {
        var stateMachine = SFTPClientStateMachine()
        let extensions = [SFTPExtension(name: SFTPExtensionName.fsync.rawValue, data: ByteBuffer(string: "1"))]

        assertAction(stateMachine.beginStartupIfNeeded(channelIsActive: false), matches: .none)
        assertAction(stateMachine.beginStartupIfNeeded(channelIsActive: true), matches: .sendSubsystemRequest)
        assertAction(stateMachine.receiveSubsystemSuccess(), matches: .sendInit)
        assertAction(stateMachine.receivePacket(.version(.v3, extensions)), matches: .startupSucceeded(extensions))
    }

    func testSubsystemFailureFailsStartup() {
        var stateMachine = SFTPClientStateMachine()
        _ = stateMachine.beginStartupIfNeeded(channelIsActive: true)

        guard case .sessionFailed(let error, let failStartup, let pendingPromises) = stateMachine.receiveSubsystemFailure() else {
            return XCTFail("Expected session failure")
        }

        XCTAssertTrue(failStartup)
        XCTAssertTrue(pendingPromises.isEmpty)
        XCTAssertEqual(error as? SFTPError, .subsystemRejected)
    }

    func testInvalidResponseFamilyFailsSession() {
        let loop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try loop.syncShutdownGracefully()) }

        var stateMachine = SFTPClientStateMachine()
        _ = stateMachine.beginStartupIfNeeded(channelIsActive: true)
        _ = stateMachine.receiveSubsystemSuccess()
        _ = stateMachine.receivePacket(.version(.v3, []))

        let promise = loop.makePromise(of: SFTPResponseMessage.self)
        let requestID = try! stateMachine.enqueueRequest(.open(path: "/tmp/file", pflags: [.read], attributes: .init()), promise: promise)

        guard case .sessionFailed(let error, let failStartup, let pendingPromises) = stateMachine.receivePacket(.response(id: requestID, .attributes(.init()))) else {
            return XCTFail("Expected invalid response family to fail the session")
        }

        XCTAssertFalse(failStartup)
        XCTAssertEqual(pendingPromises.count, 1)
        pendingPromises.forEach { $0.fail(error) }
        XCTAssertEqual(
            error as? SFTPError,
            .unexpectedResponse("Received invalid response for OPEN")
        )
    }

    func testUnknownRequestIDFailsSessionAndDrainsPending() {
        let loop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try loop.syncShutdownGracefully()) }

        var stateMachine = SFTPClientStateMachine()
        _ = stateMachine.beginStartupIfNeeded(channelIsActive: true)
        _ = stateMachine.receiveSubsystemSuccess()
        _ = stateMachine.receivePacket(.version(.v3, []))

        let promise = loop.makePromise(of: SFTPResponseMessage.self)
        _ = try! stateMachine.enqueueRequest(.stat(path: "/tmp/file"), promise: promise)

        guard case .sessionFailed(let error, let failStartup, let pendingPromises) = stateMachine.receivePacket(.response(id: 999, .status(.init(code: .ok)))) else {
            return XCTFail("Expected unknown request id to fail the session")
        }

        XCTAssertFalse(failStartup)
        XCTAssertEqual(pendingPromises.count, 1)
        pendingPromises.forEach { $0.fail(error) }
        XCTAssertEqual(
            error as? SFTPError,
            .unexpectedResponse("Received response for unknown request id 999")
        )
    }

    func testReadAcceptsDataResponse() {
        let loop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try loop.syncShutdownGracefully()) }

        var stateMachine = SFTPClientStateMachine()
        _ = stateMachine.beginStartupIfNeeded(channelIsActive: true)
        _ = stateMachine.receiveSubsystemSuccess()
        _ = stateMachine.receivePacket(.version(.v3, []))

        let promise = loop.makePromise(of: SFTPResponseMessage.self)
        let requestID = try! stateMachine.enqueueRequest(.read(handle: ByteBuffer(bytes: [1, 2, 3]), offset: 0, length: 8), promise: promise)

        let payload = ByteBuffer(bytes: [1, 2, 3])
        guard case .requestSucceeded(let promise, let response) = stateMachine.receivePacket(.response(id: requestID, .data(payload))) else {
            return XCTFail("Expected successful read response")
        }

        promise.succeed(response)
        XCTAssertEqual(response, .data(payload))
    }

    private func assertAction(_ action: SFTPClientStateMachine.Action, matches expected: StaticAction) {
        switch (action, expected) {
        case (.none, .none), (.sendSubsystemRequest, .sendSubsystemRequest), (.sendInit, .sendInit):
            return
        case (.startupSucceeded(let actual), .startupSucceeded(let expectedExtensions)):
            XCTAssertEqual(actual, expectedExtensions)
        default:
            XCTFail("Unexpected action \(action) for expected \(expected)")
        }
    }
}

private enum StaticAction {
    case none
    case sendSubsystemRequest
    case sendInit
    case startupSucceeded([SFTPExtension])
}
