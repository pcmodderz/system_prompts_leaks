# Requirement status

Legend: ✅ implemented and tested in HearthCore / CLI · 🟨 implemented in the Apple app source
(not yet compiled) or partially done · ⬜ not built yet.

| # | Requirement | Status | Where / notes |
|---|---|---|---|
| 1 | Data sovereignty | ✅ | No server component exists. Data and keys live on household devices. |
| 2 | Local-first | ✅ | Every read path is local. Live values degrade to OFFLINE/STALE and never disappear (`LiveDataTests`). |
| 3 | Native Apple app | 🟨 | SwiftUI iPhone/iPad app in `Apple/`, no WebView. Not yet compiled in Xcode. |
| 4 | Device database | ✅ | SQLite with op log, records, field heads, conflicts, observations, blobs and backup log. Additive migrations. |
| 5 | Encryption at rest | ✅ / 🟨 | App-level AES-GCM for all record values (tested). Keychain, Secure Enclave and Data Protection in the app source. |
| 6 | Biometric access | 🟨 | Vault key unwrapped by the Secure Enclave with user presence. `VaultGate` UI. Per-category defaults in `SensitivityPolicy`. |
| 7 | Media local by default | ✅ | No upload path exists. Sync copies ciphertext only to folders the user picks. |
| 8 | Original preservation | ✅ | Write-once blobs, separate derivative roles, derivative deletion leaves the original (`MediaTests`). |
| 9 | Content addressing | ✅ | SHA-256 identity, deduplication, verify-all. |
| 10 | Local processing | 🟨 | Thumbnails, OCR, keyframes, duration and on-device transcription in `OnDeviceProcessing`. Capability report types. Embeddings ⬜. |
| 11 | AI privacy boundary | ✅ | `ProcessingLocation`, `DisclosureClassification`, minimal context (`AIPolicyTests`). |
| 12 | Approval for external AI | ✅ / 🟨 | Engine supports allow once / allow for source / deny, with a summary. The approval sheet UI ⬜. |
| 13 | Local AI | ✅ / ⬜ | OpenAI-compatible client for Mac or home-server endpoints. No in-app chat UI or endpoint editor yet. |
| 14 | No mandatory Hearth cloud | ✅ | Device-only is the default. The CLI runs the same core on a Mac, server or NAS. |
| 15 | Sync | ✅ | `SyncTransport` abstraction plus a directory transport. Peer-to-peer ⬜, HTTPS household server ⬜. |
| 16 | Offline changes | ✅ | Ops recorded locally and pushed later. Concurrent edits surface as conflicts and nothing is discarded (`SyncTests`). |
| 17 | Multi-device household | ✅ / 🟨 | Enrollment and sync tested. Per-device filtering is by encryption: vault records only reach devices holding the vault key. Per-identity keys for `private` ACL records ⬜. Today `private` records are hidden by policy on other identities' devices but still replicated. |
| 18 | Family identities | ✅ | Roles, identity switching, device revocation (`testRevokedDeviceChangesAreRejected`). Household key rotation after a revocation ⬜. |
| 19 | No lock-in / export | ✅ | JSON, JSONL history, Markdown, graph (JSON + DOT), originals named by hash, manifest with checksums. |
| 20 | Complete backup | ✅ | Backup, verify, test restore, restore. Marked verified only after a test restore. |
| 21 | Encrypted backups, user-owned recovery | ✅ | scrypt-wrapped key, passphrase **or** recovery key. Hearth holds neither. |
| 22 | Share sheet | 🟨 | Share extension seals items to the app's inbox key (sealing tested in core). Inbox UI asks what each item belongs to. Very large videos may exceed the extension's memory limit ⬜. |
| 23 | Camera-first capture | 🟨 | One-tap photo, video, scan and audio. Items are stored immediately and attached afterwards. |
| 24 | Photo library import | 🟨 | PhotosPicker file representation (original encoding), creation date and location from PHAsset or EXIF, library untouched. |
| 25 | Location privacy | ✅ / 🟨 | Opt-in per capture, coarsened for connectors, stripped from exports (tested), EXIF stripping helper for share/export in the app. |
| 26 | Background live data | 🟨 | BGAppRefresh, NWPathMonitor refresh on reconnect, freshness shown everywhere. Push, local-network subscriptions and websockets ⬜. |
| 27 | App Intents / Shortcuts | 🟨 | Show procedure, what's due, record maintenance, add to Hearth, show water shutoff. All require authentication. |
| 28 | Widgets | ⬜ | Planned: redacted on a locked device unless configured. |
| 29 | Emergency mode | ✅ / 🟨 | Emergency records can't be vault-sealed, are readable offline without AI, and print as Markdown (tested). Emergency tab in the app. |
| 30 | Sovereign live data | ✅ | Observations normalized and stored sealed locally with full history. |
| 31 | Source credentials | ✅ / 🟨 | `CredentialStore` plus Keychain implementation. Records hold only a reference. |
| 32 | No secret telemetry | ✅ | No analytics code or SDK at all. |
| 33 | Deletion means deletion | ✅ | Purge removes the current state, history values, index, blobs and derivatives, propagates to replicas, and lists backups that may still hold the data. |
| 34 | Sovereign architecture | ✅ | See ARCHITECTURE.md. |
| 35 | Core package | ✅ | `HearthCore` builds on Linux and Apple platforms. The app and CLI both consume it. |
| 36 | First working build | ✅ (CLI) / 🟨 (iPhone) | `scripts/acceptance.sh` runs the whole path with real files. The iPhone run needs Xcode. |
| 37 | Airplane-mode acceptance test | 🟨 | Core behaviour is proven by tests and the CLI script. It must be run on a real iPhone once the app builds. |
| 38 | Sovereignty rule | ✅ | Export and backup READMEs explain the data without Hearth. |

## Known gaps, in priority order

1. Compile and run the Apple app in Xcode and fix whatever breaks, then run requirement 37 on a real iPhone.
2. Rotate the household key after a device is revoked. The household key is the trust root, so revocation alone doesn't stop a stolen device that still holds it.
3. Build the external-AI approval sheet and the endpoint editor. The engine already exists.
4. Add per-identity keys so `private` ACL records aren't replicated to devices whose user can't read them.
5. Stream-seal large files in the share extension.
6. Build widgets (with locked-device redaction), peer-to-peer sync, and on-device embeddings.
