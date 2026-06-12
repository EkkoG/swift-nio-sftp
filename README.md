# swift-nio-sftp

Standalone SFTP v3 client support built on top of [`swift-nio-ssh`](https://github.com/apple/swift-nio-ssh).

License: MIT

## What it provides

- `NIOSFTP` library target
- SFTP v3 client handshake over SSH `subsystem("sftp")`
- Typed file and directory operations
- Common OpenSSH extensions:
  - `posix-rename@openssh.com`
  - `fsync@openssh.com`
  - `statvfs@openssh.com`
  - `fstatvfs@openssh.com`
  - `hardlink@openssh.com`
  - `copy-data`
- `NIOSFTPWhiteboxDemo` for real-server verification
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

- Client-side SFTP only
- Protocol version: v3
- Built on public `swift-nio-ssh` APIs

## Development

Run tests:

```bash
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/module-cache \
swift test
```

Run the real-server whitebox demo:

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
