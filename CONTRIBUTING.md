# Contributing to BarLens

Thank you for your interest in contributing to **BarLens**!

## Quick Start for Contributors

BarLens is a pure Swift Package Manager (`Package.swift`) + AppKit/SwiftUI project with zero external dependencies.

```bash
# 1. Clone the repository
git clone https://github.com/outx-sec/BarLens.git
cd BarLens

# 2. Run the unit test suite (50 tests; no code-signing or private API execution required)
swift test

# 3. Build and install /Applications/BarLens.app
#    If you haven't created the local "BarLens Dev" certificate yet,
#    build.sh automatically falls back to ad-hoc signing ("-").
./build.sh
```

## Project Layout & Architecture

| Component | Location | Identifier / Name |
| :--- | :--- | :--- |
| **Product Bundle** | `/Applications/BarLens.app` (`Resources/Info.plist`) | `BarLens` (`com.barlens.app`) |
| **Main UI Target** | [`Sources/BarLens/`](Sources/BarLens) | Executable: `BarLens` |
| **Guardian Helper** | [`Sources/BarLensAgent/`](Sources/BarLensAgent) | Executable: `BarLensAgent` |
| **Private API Bridge** | [`Sources/CMenuBarPrivate/`](Sources/CMenuBarPrivate) | Objective-C target: `CMenuBarPrivate` |
| **IPC & Diagnostics** | [`Sources/DividerIPC/`](Sources/DividerIPC) | `~/Library/Application Support/BarLens/` |
| **Unit Tests** | [`Tests/BarLensTests/`](Tests/BarLensTests) | `BarLensTests` |

If you are forking BarLens under your own bundle identifier, update:
1. `CFBundleIdentifier` in [`Resources/Info.plist`](Resources/Info.plist)
2. `--identifier` in [`build.sh`](build.sh)
3. `Logger(subsystem:)` in [`Sources/DividerIPC/DiagnosticLog.swift`](Sources/DividerIPC/DiagnosticLog.swift)

## Pull Request Guidelines

- Ensure `swift test` passes with zero failures before opening a PR.
- Keep user-facing strings localized in both **Simplified Chinese (`简体中文`)** and **English (`English`)** using `tr("中文", "English")` (see [`Sources/BarLens/Localization.swift`](Sources/BarLens/Localization.swift)).
- Never commit private signing certificates (`*.p12`, `*.pem`, `*.key`) or local build artifacts.
