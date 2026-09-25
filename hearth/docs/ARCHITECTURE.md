# Hearth architecture

```
            ┌──────────────────────────────────────┐
            │  iPhone / iPad  (SwiftUI app)        │
            │  Capture · Views · Face ID · Intents │
            │  Keychain + Secure Enclave keys      │
            │ ┌──────────────────────────────────┐ │
            │ │ HearthCore (same code everywhere)│ │
            │ │ op log · merge · search · media  │ │
            │ │ live data · AI policy · backup   │ │
            │ └──────────────────────────────────┘ │
            └───────────────┬──────────────────────┘
                     optional sync (encrypted bundles)
         ┌──────────────────┼───────────────────────┐
         ▼                  ▼                       ▼
   NAS / SMB share     Mac (hearthctl)        any folder you pick
                                             (Syncthing, drive, cloud)

External systems (weather, AI) connect *to* this environment. It never depends on them.
```

## 1. Data model: an operation log is the source of truth

Every change is an immutable `Operation`: *set these fields of this record*. Each operation carries:

- a **hybrid logical clock** timestamp (`HLC`), which gives a total order across devices even when device clocks are wrong
- the **actor** (family member) and **device** that made it
- **provenance**: how it happened (manual, capture, photo-library import, share sheet, connector, AI, sync, restore, conflict resolution)
- **per-field parents**: the last operation the author had seen for each field it changes
- the values, **sealed** with AES-256-GCM, using the operation ID as additional authenticated data

The current state (`records`) is a materialized view of the log. History is simply the log, so
nothing is ever overwritten.

**Merge.** Each field is a last-writer-wins register ordered by HLC, with ancestry tracked through
the per-field parents:

- If the new op descends from the current head, it is a normal sequential edit.
- If neither op descends from the other, the edits were concurrent. A `Conflict` is recorded naming
  both ops. The HLC winner is shown until a person decides, and **both values remain in history**.
- Edits to *different* fields of the same record never conflict. Jimmy's note and Yvonne's oil type
  both survive.

Applying an operation is idempotent. Replicas converge regardless of order or duplication. This is
tested in `SyncTests.testOfflineEditsMergeAndConcurrentEditsAreSurfacedNotLost`.

**Schema evolution.** Record content is a generic `[field: JSON]` map, so most model changes need no
SQL migration. `save()` only clears fields the saving app version knows about. Fields written by a
newer version survive edits from an older one
(`StoreTests.testUnknownFieldsFromNewerVersionsArePreserved`). SQL migrations are append-only
and additive (`Storage/Schema.swift`).

## 2. Keys and encryption

| Key | Where | Protects |
|---|---|---|
| household root | Keychain, `AfterFirstUnlockThisDeviceOnly`, never synced to iCloud Keychain | HKDF subkeys for records, media, media naming, sync bundles and observations |
| vault root | Keychain blob wrapped by a **Secure Enclave** P-256 key requiring user presence (Face ID / Touch ID / passcode) | `restricted` records: financial, identity, insurance, security, network |
| backup key | random per backup; wrapped by scrypt(passphrase) **and** by scrypt(recovery key) | backup contents, including a copy of the root keys |
| inbox key | X25519; private half in Keychain, public half in the App Group | items shared from other apps before Hearth files them |

- Keys are never in source code, the bundle, the database, logs or exports.
- On iOS the database file uses `completeUnlessOpen` Data Protection and media files use `complete`.
  Record values are additionally sealed at the application level, so the SQLite file contains no
  plaintext household content (`StoreTests.testNothingReadableWithoutKeysAndNoPlaintextOnDisk`).
- There is **no persistent plaintext search index**. Search is an in-memory inverted index built
  from decrypted records at launch. Restricted records are indexed only while the vault is
  unlocked, and are dropped when it locks.
- Leaving the app locks the vault and deletes decrypted playback files.

**Trade-off.** The household key is readable after first unlock so background refresh and share
filing work while the phone is locked. A stricter mode (`WhenUnlocked`) would disable those. The
vault is always biometric-gated.

## 3. Media

- **Identity:** SHA-256 of the plaintext bytes. This gives integrity checks, deduplication (the same
  photo imported twice is stored once) and stable references.
- **On disk:** `media/<ab>/<HMAC(namingKey, sha256)>.hblob`, a chunked AES-GCM stream (1 MiB
  chunks). Truncation and reordering are detected. Keyed file names mean the blob directory doesn't
  reveal *which* well-known files a household owns.
- **Write-once:** blobs are chmod 0400 and never rewritten. Thumbnails, transcodes, OCR text,
  transcripts and AI analysis are separate `MediaObject`s with `derivedFrom`. Deleting a derivative
  can't touch the original. Editing a caption changes metadata only.
- **Video playback** decrypts to a Data-Protection-`complete` cache file that is deleted on dismiss
  and on backgrounding.
- **On-device processing** (Apple app) uses ImageIO thumbnails, Vision OCR, AVFoundation keyframes
  and duration, and Speech with `requiresOnDeviceRecognition = true`. If on-device recognition is
  unavailable, transcription is **skipped, never uploaded**. Capabilities are reported as
  `onDeviceAvailable / onDeviceDegraded / externalProcessingAvailable / processingDisabled`.

## 4. Live data

```
Open-Meteo API → OpenMeteoConnector → ObservationDraft → sealed row in `observations` (kept forever)
                                                   ↘ source_status (last attempt / success / error kind)
```

Freshness is computed on every read: `fresh`, `stale` (older than `maxAge` or erroring), `offline`
(the last attempt failed for connectivity reasons), `unavailable` (never fetched) or `disabled`. A
value **never disappears** because a source is unreachable. Only a coarsened coordinate (2 decimals,
about 1 km) is sent. No key or account is needed. Connector credentials, when a connector needs
them, go in `CredentialStore` (the Keychain), referenced by name.

iOS decides when background refresh runs. The UI shows each value's last successful update, not a
claim of continuous monitoring.

## 5. Sync

`SyncTransport` is a protocol. The implemented transport is a **directory**: a NAS share opened in
Files, a Syncthing folder, an external drive, or a cloud folder the household chooses.

- Each device writes only the ops it authored, as bundles sealed with the household sync key, to
  `bundles/<deviceID>/…`. Media blobs are copied as-is (already encrypted).
- On pull, all new bundles are read and applied **as one batch**, device records first, so a newly
  enrolled device's operations can be verified whatever the file order.
- Ops from a **revoked** device with a timestamp after its revocation are rejected.
- Restricted ops stay sealed with the vault key. A device without the vault key stores them and
  materializes them only when it can.
- Devices keep complete local copies. The folder only relays changes, so ownership doesn't move.

Future transports plug in with no model changes: peer-to-peer via Network.framework/Multipeer,
HTTPS to a household server, CloudKit as a user-chosen relay.

## 6. People, devices, permissions

Permissions attach to **identities** (owner, adult, child, guest, emergency access), not to devices.
`AccessPolicy` gates reads and writes. Private records can carry an ACL. To add a device, a trusted
owner device creates an **enrollment** sealed with a one-time pairing code (scrypt), sent by AirDrop
or a file while the code is said aloud. The vault key is included only for owner or adult
identities, and only if the owner has just unlocked the vault. Revocation is a normal synced
operation.

The household key is the trust root. Anyone holding it can write valid sync bundles, including a
device record for themselves. Revocation stops a *known* device, but a stolen, unlocked device's key
remains valid until the household key is rotated. That is why household key rotation is the first
core item on the gaps list in REQUIREMENTS.md.

## 7. AI boundary

Before any processing, a request declares its endpoint's location: `device`, `householdMac`,
`householdServer` or `external`. `AIRequest.classification` is the disclosure record. It covers
mode, destination, provider, purpose, whether media, documents, personal context or location are
included, the maximum sensitivity, the record IDs and the size.

`AIPolicyEngine` enforces these rules:

- Household and device endpoints are allowed.
- External providers are **off by default**.
- Restricted records are never sent externally. `ContextBuilder` excludes them before the policy
  even runs.
- Media is never sent externally unless explicitly enabled, and even then it asks every time.
- Private data, media or location always asks: **Allow once / Allow for this source / Deny**, with a
  "what, why, where, who" summary.
- Every decision is written to a local audit table.

A model client can only be called with an `AuthorizedAIRequest`, which only the policy engine can
create. `ContextBuilder.minimal` includes only records matching the question, never the whole
household.

## 8. Backup, restore, export, deletion

- **Backup:** a self-contained folder containing the header (salts and wrapped keys), a sealed
  manifest with the SHA-256 of every file, the sealed root keys, an encrypted SQLite snapshot, the
  encrypted media, and a plain-language README. It opens with the passphrase **or** the recovery key.
  Hearth stores neither.
- **Verify** checks file hashes, database integrity and op counts, and decrypts every media blob
  against its SHA-256. **Test restore** restores into a throwaway location and checks that every
  record decrypts and every blob verifies. Only then is the backup marked verified.
- **Export** writes open formats that need no Hearth software (see the export README).
- **Purge** removes the record, redacts every historical value, removes the search entry and the
  media blob plus derivatives, and emits a content-free purge op to other devices. It reports which
  backups may still contain the data.

## 9. Platform reach

HearthCore depends only on Foundation, SQLite and swift-crypto, so macOS, watchOS, tvOS, visionOS
and Linux servers use the same model. The iOS app is one consumer. `hearthctl` is another.
