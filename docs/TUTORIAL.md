# Tutorial

This tutorial shows how to:

1. add `swift-nio-sftp` to a package
2. connect to an existing SFTP server as a client
3. expose an SFTP subsystem from your own SSH server
4. run the local demos for end-to-end validation

`swift-nio-sftp` is built on top of `swift-nio-ssh`, so the SFTP layer always
rides on an SSH session channel and the SSH `subsystem("sftp")` request.

## 1. Add the package

```swift
.package(url: "https://github.com/EkkoG/swift-nio-sftp.git", branch: "main")
```

Then add the products you need:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "NIOSFTP", package: "swift-nio-sftp"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "NIOPosix", package: "swift-nio"),
    ]
)
```

## 2. Build a minimal SFTP client

The client flow is:

1. create an SSH connection with `NIOSSHHandler(role: .client(...))`
2. get the installed `NIOSSHHandler`
3. open an SFTP session with `SFTPClient.openChannel(with:on:)`
4. use typed file and directory APIs

Example:

```swift
import NIOCore
import NIOPosix
import NIOSFTP
import NIOSSH

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

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer { try? group.syncShutdownGracefully() }

let bootstrap = ClientBootstrap(group: group)
    .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(
                NIOSSHHandler(
                    role: .client(
                        .init(
                            userAuthDelegate: PasswordAuthDelegate(username: "user", password: "secret"),
                            serverAuthDelegate: AcceptAllHostKeysDelegate()
                        )
                    ),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
            )
        }
    }

let channel = try bootstrap.connect(host: "127.0.0.1", port: 2222).wait()
defer { try? channel.close().wait() }

let sshHandler = try channel.pipeline.handler(type: NIOSSHHandler.self).wait()
let sftp = try SFTPClient.openChannel(with: sshHandler, on: channel).wait()

let canonicalRoot = try sftp.realpath(".").wait()
print("root:", canonicalRoot)

let directory = try sftp.openDirectory(path: "/").wait()
while let batch = try sftp.readDirectoryBatch(directory).wait() {
    for entry in batch {
        print(entry.filename)
    }
}
try sftp.closeDirectory(directory).wait()
```

### Common client operations

```swift
let file = try sftp.openFile(path: "/hello.txt", flags: [.read, .write]).wait()
let chunk = try sftp.read(file: file, offset: 0, length: 4096).wait()
try sftp.write(file: file, offset: 0, data: ByteBuffer(string: "hello nio sftp")).wait()
let attrs = try sftp.fstat(file: file).wait()
try sftp.closeFile(file).wait()
```

Extension operations are exposed as typed methods:

```swift
if sftp.supportsExtension(.fsync) {
    try sftp.fsync(file: file).wait()
}

if sftp.supportsExtension(.posixRename) {
    try sftp.posixRename(from: "/old.txt", to: "/new.txt").wait()
}
```

## 3. Build a minimal SFTP server

The server flow is:

1. create an SSH server with `NIOSSHHandler(role: .server(...))`
2. accept `.session` child channels
3. install `SFTPServer.start(on:backend:)`
4. back it with `LocalFileSystemSFTPBackend` or your own `SFTPServerBackend`

### Ready-made local filesystem backend

`LocalFileSystemSFTPBackend` exposes a virtual `/` rooted at a configured host
directory. Clients cannot escape that root through `..` traversal or symlink
resolution.

Example:

```swift
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSFTP
import NIOSSH

final class DemoPasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == "nio",
              case .password(let passwordRequest) = request.request,
              passwordRequest.password == "gottagofast"
        else {
            responsePromise.succeed(.failure)
            return
        }

        responsePromise.succeed(.success)
    }
}

let backend = try LocalFileSystemSFTPBackend(rootPath: "/tmp")
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer { try? group.syncShutdownGracefully() }

let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
let authDelegate = DemoPasswordDelegate()

let channel = try ServerBootstrap(group: group)
    .childChannelInitializer { channel in
        channel.pipeline.addHandler(
            NIOSSHHandler(
                role: .server(.init(hostKeys: [hostKey], userAuthDelegate: authDelegate)),
                allocator: channel.allocator
            ) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeSucceededFuture(())
                }

                return SFTPServer.start(on: childChannel, backend: backend).map { _ in () }
            }
        )
    }
    .bind(host: "127.0.0.1", port: 2222)
    .wait()

print("listening on 127.0.0.1:2222")
try channel.closeFuture.wait()
```

### Custom backend

If you do not want to expose the local filesystem, implement
`SFTPServerBackend`. The protocol is typed and future-based. You return normal
Swift values, not raw SFTP packets.

Skeleton:

```swift
import NIOCore
import NIOSFTP

struct MyBackend: SFTPServerBackend {
    let advertisedExtensions: [SFTPExtension] = []

    func open(
        path: String,
        flags: SFTPOpenFlags,
        attributes: SFTPAttributes,
        context: SFTPServerContext
    ) -> EventLoopFuture<SFTPServerFileHandle> {
        context.eventLoop.makeFailedFuture(SFTPError.status(.init(code: .operationUnsupported)))
    }

    func close(fileHandle: SFTPServerFileHandle, context: SFTPServerContext) -> EventLoopFuture<Void> {
        context.eventLoop.makeSucceededFuture(())
    }

    func close(directoryHandle: SFTPServerDirectoryHandle, context: SFTPServerContext) -> EventLoopFuture<Void> {
        context.eventLoop.makeSucceededFuture(())
    }

    func read(
        fileHandle: SFTPServerFileHandle,
        offset: UInt64,
        length: UInt32,
        context: SFTPServerContext
    ) -> EventLoopFuture<ByteBuffer?> {
        context.eventLoop.makeSucceededFuture(nil)
    }

    // Implement the rest of the protocol methods the same way.
}
```

The important constraint is semantic, not structural:

- `read` must return `nil` at EOF
- `readdir` must return `nil` at EOF
- plain `rename` must stay non-overwriting
- overwrite rename should only be exposed through `posixRename`

## 4. Run the shipped demos

### Start the local server demo

```bash
SFTP_SERVER_HOST=127.0.0.1 \
SFTP_SERVER_PORT=2222 \
SFTP_SERVER_USER=nio \
SFTP_SERVER_PASSWORD=gottagofast \
SFTP_SERVER_ROOT=/tmp \
swift run NIOSFTPServerDemo
```

### Run the whitebox client against that local server

Use `/` as the SFTP root because `LocalFileSystemSFTPBackend` maps the host root
directory to virtual `/`.

```bash
SFTP_TEST_HOST=127.0.0.1 \
SFTP_TEST_PORT=2222 \
SFTP_TEST_USER=nio \
SFTP_TEST_PASSWORD=gottagofast \
SFTP_TEST_ROOT=/ \
swift run NIOSFTPWhiteboxDemo
```

### Run the whitebox client against an external SFTP server

```bash
SFTP_TEST_HOST=host \
SFTP_TEST_PORT=22 \
SFTP_TEST_USER=user \
SFTP_TEST_PASSWORD=secret \
SFTP_TEST_ROOT=/tmp \
swift run NIOSFTPWhiteboxDemo
```

Optional CLI cross-checks:

```bash
SFTP_TEST_KEY_PATH=/path/to/private_key
```

## 5. Validate the package

Run the focused SFTP suite:

```bash
swift test --filter NIOSFTPTests
```

Run the full package tests:

```bash
swift test
```

If you are running in a restricted sandbox that blocks SwiftPM or clang cache
writes, add:

```bash
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache
SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/module-cache
```
