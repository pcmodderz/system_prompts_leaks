# Hearth

A household's information on the household's own devices, not on anyone else's servers:
entities, relationships, photos, videos, documents, procedures, maintenance, live data and emergency information.

There is no Hearth account, Hearth cloud or telemetry. Every major design decision answers one
question: *if the company building Hearth disappeared tomorrow, would the family still have and
understand its data?* The answer has to be yes.

```
hearth/
├── Package.swift            Swift package (iOS 17+, macOS 14+, watchOS, tvOS, visionOS, Linux)
├── Sources/HearthCore/      The reusable core: every platform uses this
│   ├── Storage/             encrypted SQLite store, op log, merge, search, share inbox
│   ├── Crypto/              key hierarchy, AES-GCM sealing, chunked file encryption
│   ├── Model/               household graph, records, HLC clock, operations
│   ├── Media/               content-addressed, write-once, encrypted media + derivatives
│   ├── Live/                live data with freshness, Open-Meteo connector
│   ├── Sync/                transport-agnostic sync (shared folder implemented)
│   ├── Security/            identities, roles, permissions, device enrollment/revocation
│   ├── AI/                  routing policy, disclosure classification, approvals
│   ├── Backup/              encrypted backup, verify, test-restore, restore
│   └── Export/              open export (JSON, JSONL, Markdown, originals, checksums)
├── Sources/hearthctl/       CLI for a Mac, home server or NAS
├── Tests/HearthCoreTests/   24 tests covering the acceptance path
├── Apple/                   native SwiftUI iPhone/iPad app + share extension (XcodeGen)
├── scripts/                 Docker build helper, end-to-end acceptance script
└── docs/                    architecture, requirement status, file formats
```

## Status

| Part | State |
|---|---|
| **HearthCore** | Builds and passes all 24 tests on Linux (Swift 6.1). No Apple-only APIs; `Crypto` is CryptoKit on Apple platforms. |
| **hearthctl** | Built. The full acceptance path runs end to end with real files (`scripts/acceptance.sh`). |
| **Apple app** | Complete SwiftUI source for iPhone/iPad: capture, library import, entities, media playback, procedures, emergency, search, live data, sync, backup/restore, export, devices, Face ID vault, share extension, App Intents. **Not yet compiled.** It was written on Linux with no Xcode, so expect a round of compile fixes on first build. |

See [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) for the status of every requirement. It says plainly what is done, what is partial and what isn't built yet.

## Build and test

**Mac (Xcode 15+):**

```sh
cd hearth
swift test                         # core tests
swift run hearthctl help
brew install xcodegen
cd Apple && xcodegen && open Hearth.xcodeproj    # set your Team, then run on an iPhone
```

**Linux, or any machine with Docker:**

```sh
cd hearth
scripts/swift-docker.sh test
scripts/swift-docker.sh build
```

**The acceptance path with your own files:**

```sh
swift build
scripts/acceptance.sh ~/Pictures/valve.heic ~/Movies/generator.mov
```

It creates a household, attaches your media to real entities, connects live weather, simulates
losing the network, edits offline, reconnects, pairs a second device through a shared folder and
produces a real conflict. It then exports, backs up, verifies, test-restores and restores onto a
"new phone", and reopens the store. The weather API default is `https://api.open-meteo.com`;
set `WEATHER_BASE_URL` to point elsewhere.

## Using the CLI on a home server or NAS

```sh
hearthctl init ~/Hearth --household "Maple Street" --owner "Jimmy"
hearthctl add-entity ~/Hearth --kind utility --name "Water main shutoff" --notes "Basement NE corner" --emergency
hearthctl import ~/Hearth ~/valve.heic --entity <id>
hearthctl add-weather ~/Hearth --name "Home" --lat 40.71 --lon -74.00
hearthctl refresh ~/Hearth
HEARTH_BACKUP_PASSPHRASE='…' hearthctl backup ~/Hearth /Volumes/USB
hearthctl test-restore ~/Hearth /Volumes/USB/Hearth-Backup-….hearthbackup --recovery-key XXXX-…
hearthctl export ~/Hearth ~/Desktop --strip-location
```

Keys are stored in `~/Hearth.keys/`, never inside the store.
