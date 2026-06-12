// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import Foundation
import NIOCore
import NIOPosix
import NIOSFTP
import NIOSSH

enum ServerDemoError: Error, CustomStringConvertible {
    case missingEnv(String)
    case invalidPort(String)
    case invalidRoot(String)

    var description: String {
        switch self {
        case .missingEnv(let name):
            return "Missing required environment variable \(name)"
        case .invalidPort(let value):
            return "Invalid SFTP_SERVER_PORT value \(value)"
        case .invalidRoot(let value):
            return "Invalid SFTP_SERVER_ROOT value \(value)"
        }
    }
}

private final class DemoPasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == self.username,
            case .password(let passwordRequest) = request.request,
            passwordRequest.password == self.password
        else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

private func requiredEnv(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw ServerDemoError.missingEnv(name)
    }
    return value
}

private func main() throws {
    let host = ProcessInfo.processInfo.environment["SFTP_SERVER_HOST"] ?? "127.0.0.1"
    let port: Int = {
        let raw = ProcessInfo.processInfo.environment["SFTP_SERVER_PORT"] ?? "2222"
        return Int(raw) ?? 2222
    }()

    let username = try requiredEnv("SFTP_SERVER_USER")
    let password = try requiredEnv("SFTP_SERVER_PASSWORD")
    let root = try requiredEnv("SFTP_SERVER_ROOT")

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ServerDemoError.invalidRoot(root)
    }

    let backend = try LocalFileSystemSFTPBackend(rootPath: root)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        try? group.syncShutdownGracefully()
    }

    let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
    let delegate = DemoPasswordDelegate(username: username, password: password)

    let channel = try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(
                NIOSSHHandler(
                    role: .server(.init(hostKeys: [hostKey], userAuthDelegate: delegate)),
                    allocator: channel.allocator
                ) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeSucceededFuture(())
                    }
                    return SFTPServer.start(on: childChannel, backend: backend).map { _ in () }
                }
            )
        }
        .bind(host: host, port: port)
        .wait()

    print("SFTP server listening on \(host):\(port), root \(root)")
    try channel.closeFuture.wait()
}

try main()
