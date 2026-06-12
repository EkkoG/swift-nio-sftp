// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import Crypto
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

@testable import NIOSFTP

private enum SFTPTestError: Error {
    case missingChannel
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
    var serverChildChannels: [Channel] = []
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
            self.serverChildChannels.append(channel)
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

private final class FakeSFTPServerHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    private struct FileEntry {
        var contents: [UInt8]
        var attributes: SFTPAttributes
    }

    private var inboundBuffer: ByteBuffer
    private var files: [String: FileEntry] = [
        "/tmp/hello.txt": .init(contents: Array("hello world".utf8), attributes: .init(size: 11, permissions: 0o644)),
        "/tmp/existing.txt": .init(contents: Array("exists".utf8), attributes: .init(size: 6, permissions: 0o644)),
    ]
    private var directories: Set<String> = ["/", "/tmp"]
    private var fileHandles: [String: String] = [:]
    private var directoryHandles: [String: (path: String, emitted: Bool)] = [:]
    private var nextHandle = 0
    private let fileSystemAttributes = SFTPFileSystemAttributes(
        blockSize: 4096,
        fundamentalBlockSize: 4096,
        totalBlocks: 1024,
        freeBlocks: 768,
        availableBlocks: 768,
        totalFileNodes: 256,
        freeFileNodes: 200,
        availableFileNodes: 200,
        fileSystemID: 42,
        flags: [.readOnly],
        maximumNameLength: 255
    )
    private let supportedExtensions: [SFTPExtension] = [
        .init(name: SFTPExtensionName.posixRename.rawValue, data: ByteBuffer(string: "1")),
        .init(name: SFTPExtensionName.statvfs.rawValue, data: ByteBuffer(string: "2")),
        .init(name: SFTPExtensionName.fstatvfs.rawValue, data: ByteBuffer(string: "2")),
        .init(name: SFTPExtensionName.hardlink.rawValue, data: ByteBuffer(string: "1")),
        .init(name: SFTPExtensionName.fsync.rawValue, data: ByteBuffer(string: "1")),
        .init(name: SFTPExtensionName.copyData.rawValue, data: ByteBuffer(string: "1")),
    ]

    init(allocator: ByteBufferAllocator) {
        self.inboundBuffer = allocator.buffer(capacity: 0)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let subsystem = event as? SSHChannelRequestEvent.SubsystemRequest, subsystem.subsystem == "sftp" {
            context.triggerUserOutboundEvent(ChannelSuccessEvent()).whenFailure { _ in }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard case .byteBuffer(let incomingBytes) = channelData.data else {
            XCTFail("Unsupported IOData")
            return
        }
        guard channelData.type == .channel else {
            return
        }

        var bytes = incomingBytes
        self.inboundBuffer.writeBuffer(&bytes)
        do {
            try self.processInbound(context: context)
        } catch {
            XCTFail("Unexpected fake server error: \(error)")
        }
    }

    private func processInbound(context: ChannelHandlerContext) throws {
        while let length = self.inboundBuffer.getInteger(at: self.inboundBuffer.readerIndex, as: UInt32.self) {
            guard self.inboundBuffer.readableBytes >= Int(length) + 4 else {
                return
            }
            _ = self.inboundBuffer.readInteger(as: UInt32.self)
            let type = self.inboundBuffer.readInteger(as: UInt8.self)!
            var payload = self.inboundBuffer.readSlice(length: Int(length) - 1)!

            if type == SFTPPacketType.`init` {
                let version = payload.readInteger(as: UInt32.self)
                XCTAssertEqual(version, 3)
                let versionPacket = SFTPResponseEncoder.encodeVersion(.v3, extensions: self.supportedExtensions, allocator: context.channel.allocator)
                self.write(versionPacket, context: context)
                continue
            }

            let (requestID, request) = try SFTPRequestDecoder.decode(type: type, payload: payload)
            let response = self.handle(request: request)
            self.write(SFTPResponseEncoder.encode(response, requestID: requestID, allocator: context.channel.allocator), context: context)
        }
    }

    private func handle(request: SFTPRequestMessage) -> SFTPResponseMessage {
        switch request {
        case .realpath(let path):
            let canonical = path == "." ? "/tmp" : path
            return .name([.init(filename: canonical, longname: canonical, attributes: .init())])
        case .opendir(let path):
            guard self.directories.contains(path) else {
                return .status(.init(code: .noSuchFile, message: "missing directory"))
            }
            let handle = self.makeHandle(prefix: "dir")
            self.directoryHandles[handle] = (path: path, emitted: false)
            return .handle(ByteBuffer(string: handle))
        case .readdir(let handle):
            let key = String(buffer: handle)
            guard var entry = self.directoryHandles[key] else {
                return .status(.init(code: .failure, message: "invalid directory handle"))
            }
            guard !entry.emitted else {
                return .status(.init(code: .eof))
            }
            entry.emitted = true
            self.directoryHandles[key] = entry
            let names = self.files.keys
                .filter { $0.hasPrefix(entry.path == "/" ? "/" : entry.path + "/") }
                .map { path in
                    let filename = path.split(separator: "/").last.map(String.init) ?? path
                    return SFTPNameEntry(filename: filename, longname: filename, attributes: self.files[path]?.attributes ?? .init())
                }
            return .name(names.sorted { $0.filename < $1.filename })
        case .open(let path, let flags, _):
            if self.files[path] == nil {
                guard flags.contains(.create) else {
                    return .status(.init(code: .noSuchFile, message: "missing file"))
                }
                self.files[path] = .init(contents: [], attributes: .init(size: 0, permissions: 0o644))
            }
            let handle = self.makeHandle(prefix: "file")
            self.fileHandles[handle] = path
            return .handle(ByteBuffer(string: handle))
        case .read(let handle, let offset, let length):
            guard let path = self.fileHandles[String(buffer: handle)],
                let entry = self.files[path]
            else {
                return .status(.init(code: .failure, message: "invalid file handle"))
            }
            let start = Int(offset)
            guard start < entry.contents.count else {
                return .status(.init(code: .eof))
            }
            let end = min(entry.contents.count, start + Int(length))
            return .data(ByteBuffer(bytes: entry.contents[start..<end]))
        case .write(let handle, let offset, let data):
            guard let key = self.fileHandles[String(buffer: handle)],
                var entry = self.files[key]
            else {
                return .status(.init(code: .failure, message: "invalid file handle"))
            }
            let start = Int(offset)
            if entry.contents.count < start {
                entry.contents.append(contentsOf: repeatElement(0, count: start - entry.contents.count))
            }
            let bytes = Array(data.readableBytesView)
            let end = start + bytes.count
            if entry.contents.count < end {
                entry.contents.append(contentsOf: repeatElement(0, count: end - entry.contents.count))
            }
            entry.contents.replaceSubrange(start..<end, with: bytes)
            entry.attributes.size = UInt64(entry.contents.count)
            self.files[key] = entry
            return .status(.init(code: .ok))
        case .close:
            return .status(.init(code: .ok))
        case .stat(let path), .lstat(let path):
            guard let entry = self.files[path] else {
                return .status(.init(code: .noSuchFile))
            }
            return .attributes(entry.attributes)
        case .fstat(let handle):
            guard let path = self.fileHandles[String(buffer: handle)],
                let entry = self.files[path]
            else {
                return .status(.init(code: .failure))
            }
            return .attributes(entry.attributes)
        case .setstat(let path, let attributes):
            guard var entry = self.files[path] else {
                return .status(.init(code: .noSuchFile))
            }
            if let permissions = attributes.permissions {
                entry.attributes.permissions = permissions
            }
            self.files[path] = entry
            return .status(.init(code: .ok))
        case .fsetstat(let handle, let attributes):
            guard let path = self.fileHandles[String(buffer: handle)] else {
                return .status(.init(code: .failure))
            }
            return self.handle(request: .setstat(path: path, attributes: attributes))
        case .rename(let oldPath, let newPath):
            guard let entry = self.files[oldPath] else {
                return .status(.init(code: .noSuchFile))
            }
            guard self.files[newPath] == nil else {
                return .status(.init(code: .failure, message: "destination exists"))
            }
            self.files.removeValue(forKey: oldPath)
            self.files[newPath] = entry
            return .status(.init(code: .ok))
        case .mkdir(let path, _):
            self.directories.insert(path)
            return .status(.init(code: .ok))
        case .rmdir(let path):
            self.directories.remove(path)
            return .status(.init(code: .ok))
        case .remove(let path):
            self.files.removeValue(forKey: path)
            return .status(.init(code: .ok))
        case .readlink:
            return .name([.init(filename: "/tmp/hello.txt", longname: "/tmp/hello.txt", attributes: .init())])
        case .symlink:
            return .status(.init(code: .ok))
        case .extended(let name, let data):
            return self.handleExtendedRequest(name: name, data: data)
        }
    }

    private func handleExtendedRequest(name: String, data: ByteBuffer) -> SFTPResponseMessage {
        var payload = data

        switch name {
        case SFTPExtensionName.posixRename.rawValue:
            guard let oldPath = payload.readSFTPString(), let newPath = payload.readSFTPString(), let entry = self.files[oldPath] else {
                return .status(.init(code: .noSuchFile))
            }
            self.files.removeValue(forKey: oldPath)
            self.files[newPath] = entry
            return .status(.init(code: .ok))
        case SFTPExtensionName.fsync.rawValue:
            guard let handle = payload.readSFTPStringBuffer() else {
                return .status(.init(code: .failure, message: "invalid fsync payload"))
            }
            let handleKey = String(buffer: handle)
            return self.fileHandles[handleKey] == nil ? .status(.init(code: .failure, message: "invalid file handle")) : .status(.init(code: .ok))
        case SFTPExtensionName.statvfs.rawValue:
            guard let path = payload.readSFTPString(), self.directories.contains(path) || self.files[path] != nil else {
                return .status(.init(code: .noSuchFile))
            }
            return .extendedReply(self.encodedFileSystemAttributes())
        case SFTPExtensionName.fstatvfs.rawValue:
            guard let handle = payload.readSFTPStringBuffer() else {
                return .status(.init(code: .failure, message: "invalid fstatvfs payload"))
            }
            let handleKey = String(buffer: handle)
            return self.fileHandles[handleKey] == nil ? .status(.init(code: .failure, message: "invalid file handle")) : .extendedReply(self.encodedFileSystemAttributes())
        case SFTPExtensionName.hardlink.rawValue:
            guard let oldPath = payload.readSFTPString(), let newPath = payload.readSFTPString(), let entry = self.files[oldPath] else {
                return .status(.init(code: .noSuchFile))
            }
            self.files[newPath] = entry
            return .status(.init(code: .ok))
        case SFTPExtensionName.copyData.rawValue:
            guard
                let readHandle = payload.readSFTPStringBuffer(),
                let readOffset = payload.readInteger(as: UInt64.self),
                let readLength = payload.readInteger(as: UInt64.self),
                let writeHandle = payload.readSFTPStringBuffer(),
                let writeOffset = payload.readInteger(as: UInt64.self)
            else {
                return .status(.init(code: .failure, message: "invalid copy-data payload"))
            }
            let readKey = String(buffer: readHandle)
            let writeKey = String(buffer: writeHandle)
            guard let readPath = self.fileHandles[readKey], let writePath = self.fileHandles[writeKey], var destination = self.files[writePath], let source = self.files[readPath] else {
                return .status(.init(code: .failure, message: "invalid file handle"))
            }
            let start = Int(readOffset)
            guard start <= source.contents.count else {
                return .status(.init(code: .eof))
            }
            let sourceEnd = readLength == 0 ? source.contents.count : min(source.contents.count, start + Int(readLength))
            let copiedBytes = Array(source.contents[start..<sourceEnd])
            let destinationStart = Int(writeOffset)
            if destination.contents.count < destinationStart {
                destination.contents.append(contentsOf: repeatElement(0, count: destinationStart - destination.contents.count))
            }
            let destinationEnd = destinationStart + copiedBytes.count
            if destination.contents.count < destinationEnd {
                destination.contents.append(contentsOf: repeatElement(0, count: destinationEnd - destination.contents.count))
            }
            destination.contents.replaceSubrange(destinationStart..<destinationEnd, with: copiedBytes)
            destination.attributes.size = UInt64(destination.contents.count)
            self.files[writePath] = destination
            return .status(.init(code: .ok))
        default:
            return .status(.init(code: .operationUnsupported))
        }
    }

    private func encodedFileSystemAttributes() -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        buffer.writeSFTPFileSystemAttributes(self.fileSystemAttributes)
        return buffer
    }

    private func write(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        context.writeAndFlush(self.wrapOutboundOut(.init(type: .channel, data: .byteBuffer(buffer))), promise: nil)
    }

    private func makeHandle(prefix: String) -> String {
        defer {
            self.nextHandle += 1
        }
        return "\(prefix)-\(self.nextHandle)"
    }
}

final class SFTPEndToEndTests: XCTestCase {
    fileprivate var harness: EmbeddedSSHHarness!

    override func setUp() {
        self.harness = EmbeddedSSHHarness()
    }

    override func tearDown() {
        try? self.harness.finish()
        self.harness = nil
    }

    private func resolve<T: Sendable>(_ future: EventLoopFuture<T>) throws -> T {
        let box = ResultBox<T>()
        future.whenComplete { result in
            box.result = result
        }

        for _ in 0..<8 where box.result == nil {
            try self.harness.pump()
        }

        guard let result = box.result else {
            throw SFTPTestError.unresolvedFuture
        }
        return try result.get()
    }

    func testSFTPClientHandshakeAndFileOperations() throws {
        self.harness.serverChildInitializer = { channel in
            try channel.pipeline.syncOperations.addHandler(FakeSFTPServerHandler(allocator: channel.allocator))
        }
        try self.harness.configure()
        try self.harness.activate()
        try self.harness.pump()

        let client = try self.resolve(SFTPClient.openChannel(with: self.harness.clientSSHHandler, on: self.harness.client))
        XCTAssertTrue(client.supportsExtension(.posixRename))
        XCTAssertTrue(client.supportsExtension(.fsync))
        XCTAssertTrue(client.supportsExtension(.statvfs))
        XCTAssertEqual(client.serverCapabilities.advertisedVersions(for: .statvfs), ["2"])

        XCTAssertEqual(try self.resolve(client.realpath(".")), "/tmp")

        let directory = try self.resolve(client.openDirectory(path: "/tmp"))
        let names = try self.resolve(client.readDirectoryBatch(directory))
        XCTAssertEqual(names?.map(\.filename).sorted(), ["existing.txt", "hello.txt"])
        XCTAssertNil(try self.resolve(client.readDirectoryBatch(directory)))
        try self.resolve(client.closeDirectory(directory))

        let file = try self.resolve(client.openFile(path: "/tmp/hello.txt", flags: [.read, .write]))
        let initial = try self.resolve(client.read(file: file, offset: 0, length: 5))
        XCTAssertEqual(initial.map { String(buffer: $0) }, "hello")
        try self.resolve(client.write(file: file, offset: 6, data: ByteBuffer(string: "swift")))
        let full = try self.resolve(client.read(file: file, offset: 0, length: 32))
        XCTAssertEqual(full.map { String(buffer: $0) }, "hello swift")
        let attrs = try self.resolve(client.fstat(file: file))
        XCTAssertEqual(attrs.size, 11)
        try self.resolve(client.fsetstat(file: file, attributes: .init(permissions: 0o600)))
        XCTAssertEqual(try self.resolve(client.stat(path: "/tmp/hello.txt")).permissions, 0o600)
        try self.resolve(client.fsync(file: file))
        XCTAssertEqual(
            try self.resolve(client.fstatvfs(file: file)),
            try self.resolve(client.statvfs(path: "/tmp/hello.txt"))
        )
        try self.resolve(client.closeFile(file))

        XCTAssertThrowsError(try self.resolve(client.rename(from: "/tmp/hello.txt", to: "/tmp/existing.txt"))) { error in
            XCTAssertEqual(error as? SFTPError, .status(.init(code: .failure, message: "destination exists")))
        }

        try self.resolve(client.posixRename(from: "/tmp/hello.txt", to: "/tmp/existing.txt"))
        let renamed = try self.resolve(client.openFile(path: "/tmp/existing.txt", flags: [.read]))
        XCTAssertEqual(try self.resolve(client.read(file: renamed, offset: 0, length: 32)).map { String(buffer: $0) }, "hello swift")

        let hardlinkPath = "/tmp/hardlink.txt"
        try self.resolve(client.hardlink(from: "/tmp/existing.txt", to: hardlinkPath))
        let hardlink = try self.resolve(client.openFile(path: hardlinkPath, flags: [.read]))
        XCTAssertEqual(try self.resolve(client.read(file: hardlink, offset: 0, length: 32)).map { String(buffer: $0) }, "hello swift")
        try self.resolve(client.closeFile(hardlink))

        let copied = try self.resolve(client.openFile(path: "/tmp/copied.txt", flags: [.create, .read, .write, .truncate]))
        try self.resolve(client.copyData(from: renamed, readOffset: 0, length: 0, to: copied, writeOffset: 0))
        XCTAssertEqual(try self.resolve(client.read(file: copied, offset: 0, length: 32)).map { String(buffer: $0) }, "hello swift")
        try self.resolve(client.closeFile(copied))
        try self.resolve(client.closeFile(renamed))
    }
}
