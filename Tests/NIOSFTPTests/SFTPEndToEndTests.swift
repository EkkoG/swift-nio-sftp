// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import Crypto
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

@testable import NIOSFTP

private enum SFTPTestError: Error {
    case unresolvedFuture
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private final class PasswordDelegate: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(
            .init(
                username: "nio",
                serviceName: "ssh-connection",
                offer: .password(.init(password: "gottagofast"))
            )
        )
    }
}

private final class HardcodedPasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == "nio", case .password(let password) = request.request, password.password == "gottagofast" else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

private final class EmbeddedSSHHarness {
    let loop = EmbeddedEventLoop()
    let client: EmbeddedChannel
    let server: EmbeddedChannel
    var serverChildInitializer: ((Channel) throws -> Void)?

    init() {
        self.client = EmbeddedChannel(loop: self.loop)
        self.server = EmbeddedChannel(loop: self.loop)
    }

    var clientSSHHandler: NIOSSHHandler {
        try! self.client.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
    }

    func configure() throws {
        let clientHandler = NIOSSHHandler(
            role: .client(.init(userAuthDelegate: PasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())),
            allocator: self.client.allocator,
            inboundChildChannelInitializer: nil
        )
        let serverHandler = NIOSSHHandler(
            role: .server(.init(hostKeys: [.init(ed25519Key: .init())], userAuthDelegate: HardcodedPasswordDelegate())),
            allocator: self.server.allocator
        ) { channel, _ in
            do {
                try self.serverChildInitializer?(channel)
                return channel.eventLoop.makeSucceededFuture(())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        try self.client.pipeline.syncOperations.addHandler(clientHandler)
        try self.server.pipeline.syncOperations.addHandler(serverHandler)
    }

    func activate() throws {
        try self.client.connect(to: .init(unixDomainSocketPath: "/fake")).wait()
        try self.server.connect(to: .init(unixDomainSocketPath: "/fake")).wait()
    }

    func pump() throws {
        var work = true
        while work {
            work = false
            self.loop.run()
            let clientDatum = try self.client.readOutbound(as: IOData.self)
            let serverDatum = try self.server.readOutbound(as: IOData.self)
            if let clientDatum {
                try self.server.writeInbound(clientDatum)
                work = true
            }
            if let serverDatum {
                try self.client.writeInbound(serverDatum)
                work = true
            }
        }
    }

    func finish() throws {
        XCTAssertTrue(try self.client.finish(acceptAlreadyClosed: true).isClean)
        XCTAssertTrue(try self.server.finish(acceptAlreadyClosed: true).isClean)
        XCTAssertNoThrow(try self.loop.syncShutdownGracefully())
    }
}

final class SFTPEndToEndTests: XCTestCase {
    private var harness: EmbeddedSSHHarness!
    private var rootURL: URL!

    override func setUpWithError() throws {
        self.harness = EmbeddedSSHHarness()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-nio-sftp-server-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello world".data(using: .utf8)?.write(to: root.appendingPathComponent("hello.txt"))
        try "exists".data(using: .utf8)?.write(to: root.appendingPathComponent("existing.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        self.rootURL = root
    }

    override func tearDownWithError() throws {
        try? self.harness.finish()
        self.harness = nil

        if let rootURL = self.rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        self.rootURL = nil
    }

    private func resolve<T: Sendable>(_ future: EventLoopFuture<T>) throws -> T {
        let box = ResultBox<T>()
        future.whenComplete { result in
            box.result = result
        }

        for _ in 0..<12 where box.result == nil {
            try self.harness.pump()
        }

        guard let result = box.result else {
            throw SFTPTestError.unresolvedFuture
        }
        return try result.get()
    }

    func testSFTPClientAgainstRealServerHandler() throws {
        let backend = try LocalFileSystemSFTPBackend(rootPath: self.rootURL.path)
        self.harness.serverChildInitializer = { channel in
            _ = try self.resolve(SFTPServer.start(on: channel, backend: backend))
        }

        try self.harness.configure()
        try self.harness.activate()
        try self.harness.pump()

        let client = try self.resolve(SFTPClient.openChannel(with: self.harness.clientSSHHandler, on: self.harness.client))
        XCTAssertTrue(client.supportsExtension(.posixRename))
        XCTAssertTrue(client.supportsExtension(.fsync))
        XCTAssertTrue(client.supportsExtension(.statvfs))
        XCTAssertTrue(client.supportsExtension(.fstatvfs))
        XCTAssertTrue(client.supportsExtension(.hardlink))
        XCTAssertTrue(client.supportsExtension(.copyData))

        XCTAssertEqual(try self.resolve(client.realpath(".")), "/")

        let directory = try self.resolve(client.openDirectory(path: "/"))
        let names = try self.resolve(client.readDirectoryBatch(directory))?.map(\.filename).sorted()
        XCTAssertEqual(names, [".", "..", "existing.txt", "hello.txt", "nested"])
        XCTAssertNil(try self.resolve(client.readDirectoryBatch(directory)))
        try self.resolve(client.closeDirectory(directory))

        let file = try self.resolve(client.openFile(path: "/hello.txt", flags: [.read, .write]))
        XCTAssertEqual(try self.resolve(client.read(file: file, offset: 0, length: 5)).map { String(buffer: $0) }, "hello")
        try self.resolve(client.write(file: file, offset: 6, data: ByteBuffer(string: "swift")))
        XCTAssertEqual(try self.resolve(client.read(file: file, offset: 0, length: 32)).map { String(buffer: $0) }, "hello swift")

        let attrs = try self.resolve(client.fstat(file: file))
        XCTAssertEqual(attrs.size, 11)

        try self.resolve(client.fsetstat(file: file, attributes: .init(permissions: 0o600)))
        let statAfterFSet = try self.resolve(client.stat(path: "/hello.txt"))
        XCTAssertEqual(statAfterFSet.permissions.map { $0 & 0o7777 }, 0o600)

        try self.resolve(client.setstat(path: "/hello.txt", attributes: .init(permissions: 0o644)))
        let statAfterSet = try self.resolve(client.lstat(path: "/hello.txt"))
        XCTAssertEqual(statAfterSet.permissions.map { $0 & 0o7777 }, 0o644)

        try self.resolve(client.fsync(file: file))
        XCTAssertEqual(
            try self.resolve(client.fstatvfs(file: file)),
            try self.resolve(client.statvfs(path: "/hello.txt"))
        )
        try self.resolve(client.closeFile(file))

        try self.resolve(client.mkdir(path: "/created", attributes: .init(permissions: 0o755)))
        let createdAttrs = try self.resolve(client.stat(path: "/created"))
        XCTAssertEqual(createdAttrs.permissions.map { $0 & 0o170000 }, 0o040000)
        XCTAssertThrowsError(try self.resolve(client.rmdir(path: "/"))) { _ in }

        XCTAssertThrowsError(try self.resolve(client.rename(from: "/hello.txt", to: "/existing.txt"))) { error in
            XCTAssertEqual(error as? SFTPError, .status(.init(code: .failure, message: "Failure")))
        }

        try self.resolve(client.posixRename(from: "/hello.txt", to: "/existing.txt"))
        let renamed = try self.resolve(client.openFile(path: "/existing.txt", flags: [.read]))
        XCTAssertEqual(try self.resolve(client.read(file: renamed, offset: 0, length: 32)).map { String(buffer: $0) }, "hello swift")

        let hardlinkPath = "/hardlink.txt"
        try self.resolve(client.hardlink(from: "/existing.txt", to: hardlinkPath))
        let hardlink = try self.resolve(client.openFile(path: hardlinkPath, flags: [.read]))
        XCTAssertEqual(try self.resolve(client.read(file: hardlink, offset: 0, length: 32)).map { String(buffer: $0) }, "hello swift")
        try self.resolve(client.closeFile(hardlink))

        let copied = try self.resolve(client.openFile(path: "/copied.txt", flags: [.create, .read, .write, .truncate]))
        try self.resolve(client.copyData(from: renamed, readOffset: 0, length: 0, to: copied, writeOffset: 0))
        XCTAssertEqual(try self.resolve(client.read(file: copied, offset: 0, length: 32)).map { String(buffer: $0) }, "hello swift")
        try self.resolve(client.closeFile(copied))
        try self.resolve(client.closeFile(renamed))

        try self.resolve(client.symlink(linkPath: "/payload-link", targetPath: "/existing.txt"))
        XCTAssertEqual(try self.resolve(client.readlink(path: "/payload-link")), "/existing.txt")
        let symlinkAttrs = try self.resolve(client.lstat(path: "/payload-link"))
        XCTAssertEqual(symlinkAttrs.permissions.map { $0 & 0o170000 }, 0o120000)

        let throughLink = try self.resolve(client.openFile(path: "/payload-link", flags: [.read]))
        XCTAssertEqual(try self.resolve(client.read(file: throughLink, offset: 0, length: 32)).map { String(buffer: $0) }, "hello swift")
        try self.resolve(client.closeFile(throughLink))

        try self.resolve(client.remove(path: "/copied.txt"))
        try self.resolve(client.remove(path: "/hardlink.txt"))
        try self.resolve(client.remove(path: "/payload-link"))
        try self.resolve(client.rmdir(path: "/created"))

        XCTAssertThrowsError(try self.resolve(client.stat(path: "/copied.txt"))) { error in
            XCTAssertEqual(error as? SFTPError, .status(.init(code: .noSuchFile, message: "No such file")))
        }
    }
}
