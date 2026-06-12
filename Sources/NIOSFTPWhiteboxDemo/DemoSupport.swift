// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import Foundation
import NIOCore
import NIOSFTP
import NIOSSH

enum DemoError: Error, CustomStringConvertible {
    case missingEnv(String)
    case invalidPort(String)
    case assertionFailed(String)

    var description: String {
        switch self {
        case .missingEnv(let name):
            return "Missing required environment variable \(name)"
        case .invalidPort(let value):
            return "Invalid SFTP_TEST_PORT value \(value)"
        case .assertionFailed(let message):
            return "Assertion failed: \(message)"
        }
    }
}

final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var attempted = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !self.attempted, availableMethods.contains(.password) else {
            nextChallengePromise.succeed(nil)
            return
        }

        self.attempted = true
        nextChallengePromise.succeed(
            .init(
                username: self.username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: self.password))
            )
        )
    }
}

struct DemoConfig {
    let host: String
    let port: Int
    let user: String
    let password: String
    let root: String
    let keyPath: String?
}

struct OperationResult {
    let name: String
    let detail: String
}

func requireEnv(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw DemoError.missingEnv(name)
    }
    return value
}

func loadConfig() throws -> DemoConfig {
    let host = try requireEnv("SFTP_TEST_HOST")
    let user = try requireEnv("SFTP_TEST_USER")
    let password = try requireEnv("SFTP_TEST_PASSWORD")
    let root = try requireEnv("SFTP_TEST_ROOT")
    let portString = ProcessInfo.processInfo.environment["SFTP_TEST_PORT"] ?? "22"

    guard let port = Int(portString) else {
        throw DemoError.invalidPort(portString)
    }

    return .init(
        host: host,
        port: port,
        user: user,
        password: password,
        root: root,
        keyPath: ProcessInfo.processInfo.environment["SFTP_TEST_KEY_PATH"]
    )
}

func assertCondition(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw DemoError.assertionFailed(message)
    }
}

func permissionBits(_ value: UInt32?) -> UInt32? {
    value.map { $0 & 0o7777 }
}

func fileTypeBits(_ value: UInt32?) -> UInt32? {
    value.map { $0 & 0o170000 }
}

func string(from buffer: ByteBuffer?) -> String? {
    buffer.map(String.init(buffer:))
}

func exactBuffer(_ string: String) -> ByteBuffer {
    ByteBuffer(string: string)
}

func status(from error: Error) -> SFTPStatus? {
    guard case .status(let status) = error as? SFTPError else {
        return nil
    }
    return status
}

func isMissingStatus(_ status: SFTPStatus) -> Bool {
    switch status.code {
    case .noSuchFile:
        return true
    case .failure:
        let lowercased = status.message.lowercased()
        return lowercased.contains("no such file") || lowercased.contains("not found")
    default:
        return false
    }
}

func expectFailure(
    _ name: String,
    matching description: String,
    operation: () throws -> Void
) throws -> String {
    do {
        try operation()
        throw DemoError.assertionFailed("\(name) unexpectedly succeeded")
    } catch let demoError as DemoError {
        throw demoError
    } catch {
        try assertCondition(
            description.isEmpty || String(describing: error).lowercased().contains(description.lowercased()),
            "\(name) failed with unexpected error: \(error)"
        )
        return String(describing: error)
    }
}

func expectMissing(_ sftp: SFTPClient, path: String, operationName: String) throws -> String {
    do {
        _ = try sftp.stat(path: path).wait()
        throw DemoError.assertionFailed("\(operationName) expected missing path at \(path)")
    } catch let demoError as DemoError {
        throw demoError
    } catch {
        guard let sftpStatus = status(from: error), isMissingStatus(sftpStatus) else {
            throw DemoError.assertionFailed("\(operationName) expected missing-path error, got \(error)")
        }
        _ = try expectFailure("\(operationName) lstat missing", matching: "") {
            _ = try sftp.lstat(path: path).wait()
        }
        return "\(sftpStatus.code): \(sftpStatus.message)"
    }
}

func collectDirectoryEntries(_ sftp: SFTPClient, handle: SFTPDirectoryHandle) throws -> [SFTPNameEntry] {
    var entries: [SFTPNameEntry] = []
    while let batch = try sftp.readDirectoryBatch(handle).wait() {
        entries.append(contentsOf: batch)
    }
    return entries
}

func runSFTPCli(config: DemoConfig, commands: [String]) throws -> String {
    guard let keyPath = config.keyPath, !keyPath.isEmpty else {
        throw DemoError.missingEnv("SFTP_TEST_KEY_PATH")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
    process.arguments = ["-i", keyPath, "-P", String(config.port), "-b", "-", "\(config.user)@\(config.host)"]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.standardInput = inputPipe

    try process.run()
    let batch = commands.joined(separator: "\n") + "\n"
    inputPipe.fileHandleForWriting.write(Data(batch.utf8))
    try inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    let stdout = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")

    guard process.terminationStatus == 0 else {
        throw DemoError.assertionFailed("sftp CLI failed for commands \(commands): \(combined)")
    }

    return combined
}
