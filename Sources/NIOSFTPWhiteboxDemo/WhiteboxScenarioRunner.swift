// Copyright (c) 2026 EkkoG.
// SPDX-License-Identifier: MIT

import Foundation
import NIOCore
import NIOPosix
import NIOSFTP
import NIOSSH

struct WhiteboxScenarioRunner {
    func run() throws {
        let config = try loadConfig()
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let sanitizedRoot = config.root.hasSuffix("/") ? String(config.root.dropLast()) : config.root
        let basePath = "\(sanitizedRoot)/swift-nio-sftp-whitebox-\(timestamp)"
        let nestedDirectory = "\(basePath)/nested"
        let filePath = "\(nestedDirectory)/payload.txt"
        let renamedFilePath = "\(nestedDirectory)/payload-renamed.txt"
        let conflictingFilePath = "\(nestedDirectory)/already-there.txt"
        let posixSourcePath = "\(nestedDirectory)/payload-posix-source.txt"
        let posixTargetPath = "\(nestedDirectory)/payload-posix-target.txt"
        let hardlinkPath = "\(nestedDirectory)/payload-hardlink.txt"
        let copyDataPath = "\(nestedDirectory)/payload-copy.txt"
        let symlinkPath = "\(basePath)/payload-link"

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: PasswordAuthDelegate(username: config.user, password: config.password),
                                    serverAuthDelegate: AcceptAllHostKeysDelegate()
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let channel = try bootstrap.connect(host: config.host, port: config.port).wait()
        defer {
            try? channel.close().wait()
        }

        let sshHandler = try channel.pipeline.handler(type: NIOSSHHandler.self).wait()
        let sftp = try SFTPClient.openChannel(with: sshHandler, on: channel).wait()

        var results: [OperationResult] = []
        var createdBaseDirectory = false
        var createdNestedDirectory = false
        var createdFile = false
        var createdSymlink = false

        defer {
            if createdSymlink {
                try? sftp.remove(path: symlinkPath).wait()
            }
            if createdFile {
                try? sftp.remove(path: renamedFilePath).wait()
                try? sftp.remove(path: filePath).wait()
            }
            if createdNestedDirectory {
                try? sftp.rmdir(path: nestedDirectory).wait()
            }
            if createdBaseDirectory {
                try? sftp.rmdir(path: basePath).wait()
            }
        }

        let canonicalRoot = try sftp.realpath(config.root).wait()
        results.append(.init(name: "REALPATH", detail: canonicalRoot))
        let supportedExtensions = SFTPExtensionName.allCases.filter { sftp.supportsExtension($0) }.map(\.rawValue)
        results.append(.init(name: "EXTENSIONS", detail: supportedExtensions.isEmpty ? "none" : supportedExtensions.joined(separator: ",")))

        try sftp.mkdir(path: basePath).wait()
        createdBaseDirectory = true
        results.append(.init(name: "MKDIR", detail: basePath))

        try sftp.mkdir(path: nestedDirectory, attributes: .init(permissions: 0o755)).wait()
        createdNestedDirectory = true
        results.append(.init(name: "MKDIR nested", detail: nestedDirectory))

        let baseAttributes = try sftp.stat(path: basePath).wait()
        results.append(.init(name: "STAT dir", detail: "perms=\(baseAttributes.permissions.map { String($0, radix: 8) } ?? "nil")"))
        let nestedLstat = try sftp.lstat(path: nestedDirectory).wait()
        results.append(.init(name: "LSTAT dir", detail: "perms=\(nestedLstat.permissions.map { String($0, radix: 8) } ?? "nil")"))

        let initialPrefix = "hello "
        let suffixPayload = "nio sftp"
        let finalPayload = initialPrefix + suffixPayload
        let fileHandle = try sftp.openFile(path: filePath, flags: [.create, .write, .read, .truncate]).wait()
        createdFile = true
        results.append(.init(name: "OPEN create", detail: filePath))

        try sftp.write(file: fileHandle, offset: 0, data: exactBuffer(initialPrefix)).wait()
        try sftp.write(file: fileHandle, offset: UInt64(initialPrefix.utf8.count), data: exactBuffer(suffixPayload)).wait()
        results.append(.init(name: "WRITE", detail: finalPayload))

        let fileAttributes = try sftp.fstat(file: fileHandle).wait()
        try assertCondition(fileAttributes.size == UInt64(finalPayload.utf8.count), "FSTAT size mismatch after write")
        results.append(.init(name: "FSTAT", detail: "size=\(fileAttributes.size.map(String.init) ?? "nil")"))

        try sftp.fsetstat(file: fileHandle, attributes: .init(permissions: 0o640)).wait()
        results.append(.init(name: "FSETSTAT", detail: "perms=640"))

        if sftp.supportsExtension(.fsync) {
            try sftp.fsync(file: fileHandle).wait()
            results.append(.init(name: "FSYNC", detail: filePath))
        } else {
            results.append(.init(name: "FSYNC", detail: "skipped: unsupported"))
        }

        if sftp.supportsExtension(.statvfs) {
            let statvfs = try sftp.statvfs(path: nestedDirectory).wait()
            try assertCondition(statvfs.blockSize > 0, "STATVFS block size must be nonzero")
            results.append(.init(name: "STATVFS", detail: "bsize=\(statvfs.blockSize) namemax=\(statvfs.maximumNameLength)"))
        } else {
            results.append(.init(name: "STATVFS", detail: "skipped: unsupported"))
        }

        if sftp.supportsExtension(.fstatvfs) && sftp.supportsExtension(.statvfs) {
            let pathStats = try sftp.statvfs(path: filePath).wait()
            let handleStats = try sftp.fstatvfs(file: fileHandle).wait()
            try assertCondition(pathStats == handleStats, "FSTATVFS mismatch")
            results.append(.init(name: "FSTATVFS", detail: "bsize=\(handleStats.blockSize) flags=\(handleStats.flags.rawValue)"))
        } else {
            results.append(.init(name: "FSTATVFS", detail: "skipped: unsupported"))
        }

        let readPrefix = try sftp.read(file: fileHandle, offset: 0, length: 5).wait()
        try assertCondition(string(from: readPrefix) == "hello", "READ prefix mismatch")
        results.append(.init(name: "READ prefix", detail: string(from: readPrefix) ?? "nil"))

        let readCrossBoundary = try sftp.read(file: fileHandle, offset: 4, length: 6).wait()
        try assertCondition(string(from: readCrossBoundary) == "o nio ", "READ cross-boundary mismatch")
        results.append(.init(name: "READ cross", detail: string(from: readCrossBoundary) ?? "nil"))

        let readFull = try sftp.read(file: fileHandle, offset: 0, length: 64).wait()
        try assertCondition(string(from: readFull) == finalPayload, "READ full mismatch")
        results.append(.init(name: "READ full", detail: string(from: readFull) ?? "nil"))

        let readEOF = try sftp.read(file: fileHandle, offset: 1024, length: 8).wait()
        try assertCondition(readEOF == nil, "READ EOF should be nil")
        results.append(.init(name: "READ EOF", detail: "nil"))

        try sftp.closeFile(fileHandle).wait()
        results.append(.init(name: "CLOSE file", detail: filePath))

        let pathStat = try sftp.stat(path: filePath).wait()
        try assertCondition(permissionBits(pathStat.permissions) == 0o640, "STAT permissions mismatch after FSETSTAT")
        try assertCondition(fileTypeBits(pathStat.permissions) == 0o100000, "STAT file type mismatch")
        results.append(.init(name: "STAT file", detail: "size=\(pathStat.size.map(String.init) ?? "nil") perms=\(pathStat.permissions.map { String($0, radix: 8) } ?? "nil")"))

        try sftp.setstat(path: filePath, attributes: .init(permissions: 0o600)).wait()
        let updatedLstat = try sftp.lstat(path: filePath).wait()
        try assertCondition(permissionBits(updatedLstat.permissions) == 0o600, "LSTAT permissions mismatch after SETSTAT")
        try assertCondition(fileTypeBits(updatedLstat.permissions) == 0o100000, "LSTAT file type mismatch")
        results.append(.init(name: "SETSTAT/LSTAT file", detail: "perms=\(updatedLstat.permissions.map { String($0, radix: 8) } ?? "nil")"))

        let duplicateMkdirError = try expectFailure("MKDIR duplicate", matching: "") {
            try sftp.mkdir(path: nestedDirectory).wait()
        }
        results.append(.init(name: "MKDIR duplicate", detail: duplicateMkdirError))

        let missingOpenError = try expectFailure("OPEN missing", matching: "") {
            _ = try sftp.openFile(path: "\(nestedDirectory)/missing.txt", flags: [.read]).wait()
        }
        results.append(.init(name: "OPEN missing", detail: missingOpenError))

        let nonEmptyRmdirError = try expectFailure("RMDIR non-empty", matching: "") {
            try sftp.rmdir(path: nestedDirectory).wait()
        }
        results.append(.init(name: "RMDIR non-empty", detail: nonEmptyRmdirError))

        let directoryHandle = try sftp.openDirectory(path: nestedDirectory).wait()
        results.append(.init(name: "OPENDIR", detail: nestedDirectory))
        let directoryEntries = try collectDirectoryEntries(sftp, handle: directoryHandle)
        let payloadMatches = directoryEntries.filter { $0.filename == "payload.txt" }
        try assertCondition(payloadMatches.count == 1, "READDIR expected payload.txt exactly once")
        results.append(.init(name: "READDIR", detail: directoryEntries.map(\.filename).sorted().joined(separator: ",")))
        let directoryEOF = try sftp.readDirectoryBatch(directoryHandle).wait()
        try assertCondition(directoryEOF == nil, "READDIR extra batch after EOF should be nil")
        results.append(.init(name: "READDIR EOF", detail: "nil"))
        try sftp.closeDirectory(directoryHandle).wait()
        results.append(.init(name: "CLOSE dir", detail: nestedDirectory))

        try sftp.rename(from: filePath, to: renamedFilePath).wait()
        let renameOldMissing = try expectMissing(sftp, path: filePath, operationName: "RENAME old path")
        let renamedPathStat = try sftp.stat(path: renamedFilePath).wait()
        try assertCondition(permissionBits(renamedPathStat.permissions) == 0o600, "Renamed file permissions mismatch")
        results.append(.init(name: "RENAME", detail: "\(filePath) -> \(renamedFilePath)"))
        results.append(.init(name: "RENAME old path", detail: renameOldMissing))

        let renamedHandle = try sftp.openFile(path: renamedFilePath, flags: [.read]).wait()
        let renamedContents = try sftp.read(file: renamedHandle, offset: 0, length: 64).wait()
        try assertCondition(string(from: renamedContents) == finalPayload, "Renamed file content mismatch")
        results.append(.init(name: "OPEN renamed", detail: string(from: renamedContents) ?? "nil"))
        try sftp.closeFile(renamedHandle).wait()

        let conflictingHandle = try sftp.openFile(path: conflictingFilePath, flags: [.create, .write, .read, .truncate, .exclusive]).wait()
        try sftp.write(file: conflictingHandle, offset: 0, data: exactBuffer("occupied")).wait()
        try sftp.closeFile(conflictingHandle).wait()
        results.append(.init(name: "OPEN conflict", detail: conflictingFilePath))

        let renameConflictError = try expectFailure("RENAME existing destination", matching: "") {
            try sftp.rename(from: renamedFilePath, to: conflictingFilePath).wait()
        }
        let conflictContentsHandle = try sftp.openFile(path: conflictingFilePath, flags: [.read]).wait()
        let conflictContents = try sftp.read(file: conflictContentsHandle, offset: 0, length: 64).wait()
        try assertCondition(string(from: conflictContents) == "occupied", "Conflict file content changed after failed rename")
        try sftp.closeFile(conflictContentsHandle).wait()
        results.append(.init(name: "RENAME existing destination", detail: renameConflictError))

        if sftp.supportsExtension(.posixRename) {
            let posixSource = try sftp.openFile(path: posixSourcePath, flags: [.create, .read, .write, .truncate]).wait()
            try sftp.write(file: posixSource, offset: 0, data: exactBuffer(finalPayload)).wait()
            try sftp.closeFile(posixSource).wait()

            let posixTarget = try sftp.openFile(path: posixTargetPath, flags: [.create, .read, .write, .truncate]).wait()
            try sftp.write(file: posixTarget, offset: 0, data: exactBuffer("old target")).wait()
            try sftp.closeFile(posixTarget).wait()

            try sftp.posixRename(from: posixSourcePath, to: posixTargetPath).wait()
            let replacedHandle = try sftp.openFile(path: posixTargetPath, flags: [.read]).wait()
            let replacedContents = try sftp.read(file: replacedHandle, offset: 0, length: 64).wait()
            try assertCondition(string(from: replacedContents) == finalPayload, "POSIX_RENAME target mismatch")
            try sftp.closeFile(replacedHandle).wait()
            let posixSourceMissing = try expectMissing(sftp, path: posixSourcePath, operationName: "POSIX_RENAME source")
            results.append(.init(name: "POSIX_RENAME", detail: "\(posixSourcePath) -> \(posixTargetPath)"))
            results.append(.init(name: "POSIX_RENAME source", detail: posixSourceMissing))
            try sftp.remove(path: posixTargetPath).wait()
        } else {
            results.append(.init(name: "POSIX_RENAME", detail: "skipped: unsupported"))
        }

        if sftp.supportsExtension(.hardlink) {
            try sftp.hardlink(from: renamedFilePath, to: hardlinkPath).wait()
            let hardlinkHandle = try sftp.openFile(path: hardlinkPath, flags: [.read]).wait()
            let hardlinkContents = try sftp.read(file: hardlinkHandle, offset: 0, length: 64).wait()
            try assertCondition(string(from: hardlinkContents) == finalPayload, "HARDLINK content mismatch")
            try sftp.closeFile(hardlinkHandle).wait()
            results.append(.init(name: "HARDLINK", detail: "\(renamedFilePath) -> \(hardlinkPath)"))
        } else {
            results.append(.init(name: "HARDLINK", detail: "skipped: unsupported"))
        }

        if sftp.supportsExtension(.copyData) {
            let copyDestination = try sftp.openFile(path: copyDataPath, flags: [.create, .read, .write, .truncate]).wait()
            let copySource = try sftp.openFile(path: renamedFilePath, flags: [.read]).wait()
            try sftp.copyData(from: copySource, readOffset: 0, length: 0, to: copyDestination, writeOffset: 0).wait()
            let copiedContents = try sftp.read(file: copyDestination, offset: 0, length: 64).wait()
            try assertCondition(string(from: copiedContents) == finalPayload, "COPY_DATA content mismatch")
            try sftp.closeFile(copySource).wait()
            try sftp.closeFile(copyDestination).wait()
            results.append(.init(name: "COPY_DATA", detail: "\(renamedFilePath) -> \(copyDataPath)"))
        } else {
            results.append(.init(name: "COPY_DATA", detail: "skipped: unsupported"))
        }

        do {
            try sftp.symlink(linkPath: symlinkPath, targetPath: renamedFilePath).wait()
            createdSymlink = true
            results.append(.init(name: "SYMLINK", detail: "\(symlinkPath) -> \(renamedFilePath)"))

            let linkTarget = try sftp.readlink(path: symlinkPath).wait()
            try assertCondition(linkTarget == renamedFilePath, "READLINK target mismatch")
            results.append(.init(name: "READLINK", detail: linkTarget))

            let symlinkStat = try sftp.lstat(path: symlinkPath).wait()
            try assertCondition(fileTypeBits(symlinkStat.permissions) == 0o120000, "LSTAT symlink type mismatch")
            results.append(.init(name: "LSTAT symlink", detail: "perms=\(symlinkStat.permissions.map { String($0, radix: 8) } ?? "nil")"))

            let symlinkHandle = try sftp.openFile(path: symlinkPath, flags: [.read]).wait()
            let symlinkReadback = try sftp.read(file: symlinkHandle, offset: 0, length: 64).wait()
            try assertCondition(string(from: symlinkReadback) == finalPayload, "Opening symlink did not resolve target content")
            try sftp.closeFile(symlinkHandle).wait()
            results.append(.init(name: "OPEN symlink", detail: string(from: symlinkReadback) ?? "nil"))

            if config.keyPath != nil {
                let cliNestedListing = try runSFTPCli(config: config, commands: ["ls -la \(nestedDirectory)"])
                try assertCondition(cliNestedListing.contains("payload-renamed.txt"), "CLI nested listing missing renamed file")
                results.append(.init(name: "CLI nested listing", detail: cliNestedListing.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        } catch {
            results.append(.init(name: "SYMLINK/READLINK", detail: "unsupported or failed: \(error)"))
        }

        try sftp.remove(path: renamedFilePath).wait()
        let removedFileCheck = try expectMissing(sftp, path: renamedFilePath, operationName: "REMOVE file")
        createdFile = false
        results.append(.init(name: "REMOVE file", detail: renamedFilePath))
        results.append(.init(name: "REMOVE file verify", detail: removedFileCheck))

        let removeMissingError = try expectFailure("REMOVE missing", matching: "") {
            try sftp.remove(path: renamedFilePath).wait()
        }
        results.append(.init(name: "REMOVE missing", detail: removeMissingError))

        try sftp.remove(path: conflictingFilePath).wait()
        results.append(.init(name: "REMOVE conflict", detail: conflictingFilePath))
        let removedConflictCheck = try expectMissing(sftp, path: conflictingFilePath, operationName: "REMOVE conflict")
        results.append(.init(name: "REMOVE conflict verify", detail: removedConflictCheck))

        if sftp.supportsExtension(.hardlink) {
            try sftp.remove(path: hardlinkPath).wait()
            let removedHardlinkCheck = try expectMissing(sftp, path: hardlinkPath, operationName: "REMOVE hardlink")
            results.append(.init(name: "REMOVE hardlink", detail: hardlinkPath))
            results.append(.init(name: "REMOVE hardlink verify", detail: removedHardlinkCheck))
        }

        if sftp.supportsExtension(.copyData) {
            try sftp.remove(path: copyDataPath).wait()
            let removedCopyCheck = try expectMissing(sftp, path: copyDataPath, operationName: "REMOVE copied file")
            results.append(.init(name: "REMOVE copied file", detail: copyDataPath))
            results.append(.init(name: "REMOVE copied file verify", detail: removedCopyCheck))
        }

        if createdSymlink {
            try sftp.remove(path: symlinkPath).wait()
            let removedSymlinkCheck = try expectMissing(sftp, path: symlinkPath, operationName: "REMOVE symlink")
            createdSymlink = false
            results.append(.init(name: "REMOVE symlink", detail: symlinkPath))
            results.append(.init(name: "REMOVE symlink verify", detail: removedSymlinkCheck))
        }

        try sftp.rmdir(path: nestedDirectory).wait()
        let removedNestedCheck = try expectMissing(sftp, path: nestedDirectory, operationName: "RMDIR nested")
        createdNestedDirectory = false
        results.append(.init(name: "RMDIR nested", detail: nestedDirectory))
        results.append(.init(name: "RMDIR nested verify", detail: removedNestedCheck))

        try sftp.rmdir(path: basePath).wait()
        let removedBaseCheck = try expectMissing(sftp, path: basePath, operationName: "RMDIR base")
        createdBaseDirectory = false
        results.append(.init(name: "RMDIR base", detail: basePath))
        results.append(.init(name: "RMDIR base verify", detail: removedBaseCheck))

        if config.keyPath != nil {
            let cliRootListing = try runSFTPCli(config: config, commands: ["ls -la \(sanitizedRoot)"])
            try assertCondition(!cliRootListing.contains("swift-nio-ssh-whitebox-\(timestamp)"), "CLI listing still shows cleaned test root")
            results.append(.init(name: "CLI cleanup listing", detail: "verified absence under \(sanitizedRoot)"))
        } else {
            results.append(.init(name: "CLI cross-check", detail: "skipped: SFTP_TEST_KEY_PATH not set"))
        }

        print("connected to \(config.host):\(config.port) as \(config.user)")
        print("root \(config.root) resolved to \(canonicalRoot)")
        for result in results {
            print("[\(result.name)] \(result.detail)")
        }
    }
}
