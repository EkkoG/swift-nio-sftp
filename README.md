# swift-nio-sftp

Standalone SFTP v3 client support built on top of [`swift-nio-ssh`](https://github.com/apple/swift-nio-ssh).

License: MIT

## What is included

- `NIOSFTP` library target
- SFTP v3 client pipeline and typed file APIs
- Common OpenSSH extensions:
  - `posix-rename@openssh.com`
  - `fsync@openssh.com`
  - `statvfs@openssh.com`
  - `fstatvfs@openssh.com`
  - `hardlink@openssh.com`
  - `copy-data`
- `NIOSFTPWhiteboxDemo` for real-server verification
- Embedded/unit tests in `NIOSFTPTests`

## Package dependency

```swift
.package(url: "https://github.com/<you>/swift-nio-sftp.git", branch: "main")
```

Then depend on `NIOSFTP` in your target.

## Development

Run embedded tests:

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

Optional for CLI cross-checks:

```bash
SFTP_TEST_KEY_PATH=/path/to/private_key
```
