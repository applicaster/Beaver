# SCAFFOLD.md — Xcode project setup

The repo is now flat: the Xcode project sits at the root, and all source,
test, and UI test folders are immediate siblings of it. This document
lists the remaining one-time steps in Xcode to bring everything into
the project navigator and get a green build.

---

## Final layout

```
LoggerNext/                                  ← repo root
├── .git/
├── .gitignore
├── ARCHITECTURE.md
├── DECISIONS.md
├── PROTOCOL.md
├── README.md
├── SCAFFOLD.md                              (this file)
├── Package.swift                            (SPM, for headless CI / `swift test`)
├── scripts/
│   └── release.sh
├── LoggerNext.xcodeproj/                    ← double-click to open
├── LoggerNext/                              ← target: LoggerNext
│   ├── LoggerNextApp.swift                  (the real app entry)
│   ├── AppEnvironment.swift
│   ├── Assets.xcassets/                     (Xcode resource bundle)
│   ├── LoggerNext.entitlements              (App Sandbox entitlements)
│   ├── Domain/                              EventRecord, Filter, LogLevel, Session, StorageSnapshot
│   ├── Features/                            MainWindow + LogFeed / Storages / Sessions / DetailPane / CommandBar
│   ├── Store/                               LogStore (GRDB actor), Schema (migrations)
│   ├── Support/                             Highlighting, NetworkInterface
│   └── Transport/                           WSServer, ProtocolDecoder
├── LoggerNextTests/                         ← target: LoggerNextTests (Swift Testing)
│   ├── LogStoreTests.swift
│   └── ProtocolDecoderTests.swift
└── LoggerNextUITests/                       ← target: LoggerNextUITests (XCTest)
    ├── LoggerNextUITests.swift
    └── LoggerNextUITestsLaunchTests.swift
```

---

## Open the project

```bash
cd /Users/antonkononenko/Work/Applicaster/LoggerNext
open LoggerNext.xcodeproj
```

---

## Steps remaining in Xcode

1. **Add the new source folders to the project navigator.**
   In Xcode the project navigator will show `LoggerNext` as a group
   containing `LoggerNextApp.swift` and `ContentView.swift` (which is
   now red — see step 2). The new folders on disk (`Domain`,
   `Features`, `Store`, `Support`, `Transport`) aren't referenced yet.
   - In Finder, navigate to `LoggerNext/LoggerNext/`.
   - Drag **Domain**, **Features**, **Store**, **Support**, **Transport**,
     and the loose **AppEnvironment.swift** into the `LoggerNext` group
     in Xcode's navigator.
   - Dialog: select **Create groups** (not "Create folder references"),
     and **Add to target: LoggerNext**.
2. **Remove `ContentView.swift` from the project.**
   It's already deleted from disk; the navigator will show it red.
   Right-click → **Delete** → **Remove Reference**.
3. **Confirm `LoggerNextApp.swift` is the real one.**
   Xcode's auto-generated copy was overwritten on disk. If Xcode warns
   that the file changed externally, click **Keep Disk Version** /
   **Revert**, or just close and reopen the project.
4. **Add GRDB as a Swift Package Dependency.**
   - **File ▸ Add Package Dependencies…**
   - URL: `https://github.com/groue/GRDB.swift`
   - Rule: **Up to Next Major Version**, starting at `7.0.0`.
   - Add to target **LoggerNext** (not the test targets).
5. **Add the test files to the test target.**
   - Drag `LogStoreTests.swift` and `ProtocolDecoderTests.swift` from
     Finder into the `LoggerNextTests` group in Xcode.
   - Add to target **LoggerNextTests** only.
   - Remove the boilerplate `LoggerNextTests.swift` reference (file is
     already deleted from disk).
6. **Project settings.**
   - Select the **LoggerNext** project, then the **LoggerNext** target.
   - **General ▸ Minimum Deployments**: macOS **26.0**.
   - **Build Settings ▸ Swift Language Version**: **Swift 6**.
   - **Build Settings ▸ Strict Concurrency Checking**: **Complete**.
   - **Signing & Capabilities**: if App Sandbox is enabled, ensure the
     **Incoming Connections (Server)** capability is on under Network.
7. **Build.** `⌘B`. Expected: green, possibly with Swift 6 sendability
   warnings to track as TODOs.
8. **Run.** `⌘R`. A window opens. Status bar shows "Listening". Point
   your mobile client at `ws://<your-ip>:9080`.

---

## Headless `swift test` (optional)

To run the unit tests without Xcode (useful for CI):

```bash
cd /Users/antonkononenko/Work/Applicaster/LoggerNext
swift test
```

This builds the `LoggerNextCore` library + `LoggerNextCoreTests` target
declared in `Package.swift`. The full app target only builds in Xcode
(SwiftUI views, `@main` entry, entitlements).

---

## Troubleshooting

- **"Module 'GRDB' not found"** — re-resolve packages via
  **File ▸ Packages ▸ Resolve Package Versions**.
- **Files appearing red in the navigator** — those references point to
  on-disk paths that no longer exist (Xcode's deleted boilerplate).
  Right-click → **Delete** → **Remove Reference**.
- **`@Observable` macro errors** — make sure Swift Language Version is
  6 and Strict Concurrency Checking is Complete. Older settings won't
  expose the Observation framework macros.
- **"This file was modified outside Xcode"** — the on-disk file is the
  correct version. Choose **Keep Disk Version**.
