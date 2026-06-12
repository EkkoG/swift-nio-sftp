# swift-nio-sftp

Standalone SFTP v3 client and server support built on top of [`swift-nio-ssh`](https://github.com/apple/swift-nio-ssh).

License: MIT

Tutorial: [docs/TUTORIAL.md](docs/TUTORIAL.md)

## What it provides

- `NIOSFTP` library target
- SFTP v3 client handshake over SSH `subsystem("sftp")`
- SFTP v3 server subsystem handler over SSH `subsystem("sftp")`
- Typed file and directory operations for both client and server-side backend SPI
- Common OpenSSH extensions:
  - `posix-rename@openssh.com`
  - `fsync@openssh.com`
  - `statvfs@openssh.com`
  - `fstatvfs@openssh.com`
  - `hardlink@openssh.com`
  - `copy-data`
- `LocalFileSystemSFTPBackend` rooted-jail server backend
- `NIOSFTPWhiteboxDemo` for whitebox verification
- `NIOSFTPServerDemo` for local server startup and end-to-end validation
- Embedded and end-to-end tests in `NIOSFTPTests`

## Package dependency

Add the package:

```swift
.package(url: "https://github.com/EkkoG/swift-nio-sftp.git", branch: "main")
```

Then depend on `NIOSFTP`:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "NIOSFTP", package: "swift-nio-sftp"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
    ]
)
```

## Current scope

- Protocol version: v3
- Built on public `swift-nio-ssh` APIs
- Client and server support live in the same `NIOSFTP` module
- Default server backend is a rooted local filesystem jail

## Server API

The package now exposes:

- `SFTPClient`
- `SFTPServer`
- `SFTPServerBackend`
- `LocalFileSystemSFTPBackend`

`SFTPServer.start(on:backend:)` installs the SFTP subsystem handler on an SSH
session child channel. `LocalFileSystemSFTPBackend` provides a ready-to-use
rooted filesystem implementation.

## Development

Run tests:

```bash
swift test
```

Run the test suite:

```bash
swift test --filter NIOSFTPTests
```

Run the whitebox client demo against an external SFTP server:

```bash
SFTP_TEST_HOST=host \
SFTP_TEST_USER=user \
SFTP_TEST_PASSWORD=secret \
SFTP_TEST_ROOT=/tmp \
swift run NIOSFTPWhiteboxDemo
```

Optional for `sftp` CLI cross-checks:

```bash
SFTP_TEST_KEY_PATH=/path/to/private_key
```

Run the local SFTP server demo:

```bash
SFTP_SERVER_HOST=127.0.0.1 \
SFTP_SERVER_PORT=2222 \
SFTP_SERVER_USER=nio \
SFTP_SERVER_PASSWORD=gottagofast \
SFTP_SERVER_ROOT=/tmp \
swift run NIOSFTPServerDemo
```

Run the whitebox client against the local server demo:

```bash
SFTP_TEST_HOST=127.0.0.1 \
SFTP_TEST_PORT=2222 \
SFTP_TEST_USER=nio \
SFTP_TEST_PASSWORD=gottagofast \
SFTP_TEST_ROOT=/ \
swift run NIOSFTPWhiteboxDemo
```

If you are running in a restricted sandbox that blocks SwiftPM or clang cache
writes, you may need temporary overrides such as:

```bash
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache
SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/module-cache
```
