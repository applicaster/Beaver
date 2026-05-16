# LoggerNext

Successor to the macOS `Logger` desktop app. Receives log events and
storage snapshots from a mobile client SDK over WebSocket, persists them
to SQLite, and renders a virtualized live feed plus a storages inspector.

## Status

Scaffolding in progress. The architecture and feature set are locked
(see `DECISIONS.md`); the working source tree is being built up under
`LoggerNext/`.

## Documents

| File              | Purpose                                                       |
|-------------------|---------------------------------------------------------------|
| `DECISIONS.md`    | Numbered, dated decision log (D1–D13). Source of truth.       |
| `ARCHITECTURE.md` | Layered design synthesizing the decisions.                    |
| `PROTOCOL.md`     | Wire-protocol contract with the mobile SDK.                   |
| `SCAFFOLD.md`     | One-time Xcode project setup steps.                           |

## Quick start

```bash
# After SCAFFOLD.md is followed:
open LoggerNext.xcodeproj
# ⌘R to build and run.
```

The app starts a WebSocket listener on `ws://<your-ip>:9080`. Use
**App ▸ Copy WebSocket URL** (⇧⌘C) to copy the address, then point your
mobile client at it.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 17 or later
- Swift 6 toolchain

## License

Same as the original `Logger` repository.
