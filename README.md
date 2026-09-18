# Galaxy Watch Bridge

iOS companion app that exchanges telemetry with a Samsung Galaxy Watch over raw BLE GATT,
plus the Wear OS peripheral it talks to.

---

## Read this first: what actually works

**A Galaxy Watch 4 or newer cannot pair with an iPhone.** Samsung dropped iOS support when
it moved to Wear OS 3. There is no Galaxy Wearable app for iPhone, no companion protocol,
and no Samsung SDK for iOS. Nothing in this project changes that.

What *does* work is bypassing the companion ecosystem entirely and speaking raw BLE:

| | |
|---|---|
| **Works** | Wear OS app opens a `BluetoothGattServer` with a custom service → iPhone connects as a CoreBluetooth central and exchanges data |
| **Works** | Reading standard GATT services the watch already exposes (Battery `180F`, Heart Rate `180D`) — *if* it exposes them unpaired, which varies by model and firmware |
| **Does not work** | Using Samsung Health data, notifications, or any first-party watch feature from iOS |
| **Does not work** | Pairing through the system Bluetooth settings and expecting app-level access |
| **Does not work** | Classic Bluetooth / SPP serial. iOS gives third-party apps BLE GATT only |

So this is a **two-sided project**. `GalaxyWatchBridge/` is useless on its own —
`WearOS-Peripheral/` is what gives it something to discover.

### Build target reality

The iOS side needs **Xcode on macOS**. It cannot be built on Windows, where these files
currently live, and CoreBluetooth reports `.unsupported` forever in the Simulator, so
testing requires a physical iPhone.

---

## Layout

```
GalaxyWatchBridge/
├── GalaxyWatchBridge/
│   ├── GalaxyWatchBridgeApp.swift       @main entry
│   ├── Resources/Info.plist             Bluetooth usage keys — see notes inside
│   ├── Core/
│   │   ├── BLE/
│   │   │   ├── BLEConstants.swift       Service + characteristic UUIDs, timeouts
│   │   │   ├── BluetoothState.swift     Sendable mirror of CBManagerState
│   │   │   ├── BLEError.swift           Typed, user-presentable failures
│   │   │   ├── BLEEvent.swift           The Sendable event stream vocabulary
│   │   │   ├── Concurrency.swift        withTimeout + single-shot continuation box
│   │   │   └── BLEManager.swift         CoreBluetooth central, async/await surface
│   │   └── Models/
│   │       ├── DiscoveredPeripheral.swift
│   │       ├── WireFormat.swift         Framing, reassembly, byte readers/writers
│   │       ├── TelemetryPacket.swift    The 16-byte telemetry payload + commands
│   │       └── LogEntry.swift
│   └── Features/Watch/
│       ├── WatchViewModel.swift         @MainActor @Observable
│       └── Views/
│           ├── ContentView.swift
│           ├── DeviceRowView.swift
│           ├── TelemetryCardView.swift
│           ├── ControlPanelView.swift
│           └── LogConsoleView.swift
└── WearOS-Peripheral/
    ├── GattServerService.kt             The other half — Kotlin GATT server
    └── AndroidManifest-snippet.xml      Permissions (note the API 31 split)
```

---

## Architecture

### Threading — the part that matters

CoreBluetooth delivers delegate callbacks on whatever queue you hand
`CBCentralManager(delegate:queue:)`. This project passes a **private serial queue**, not
`nil`, so BLE work stays off the main thread.

That creates the problem every CoreBluetooth app has to solve: callbacks arrive on a
background queue, and SwiftUI state must be mutated on the main actor. The usual answer is
`DispatchQueue.main.async` scattered through the delegate methods, which is easy to get
wrong and impossible to verify.

Instead there is exactly **one** crossing point:

```
CBCentralManagerDelegate ──┐
                           ├─► BLEManager (private serial queue)
CBPeripheralDelegate ──────┘        │
                                    │  AsyncStream<BLEEvent>   ← only Sendable value types
                                    ▼
                          WatchViewModel (@MainActor @Observable)
                                    │
                                    ▼
                              SwiftUI views
```

Consequences worth noting:

- **`BLEManager` publishes nothing.** No `@Published`, no `ObservableObject`. All state
  leaves as `BLEEvent` values through the stream.
- **Every event payload is a value type.** No `CBPeripheral`, no `CBUUID`, no `NSError`
  crosses the boundary — which is why `BLEEvent: Sendable` is real rather than
  `@unchecked`.
- **Every stored property in `BLEManager` is confined to its queue.** The serial queue
  provides mutual exclusion, so there are no locks. `@unchecked Sendable` is the assertion
  of that contract, and `dispatchPrecondition` checks assert it at runtime in debug builds.
- **`WatchViewModel` has no `DispatchQueue.main.async` anywhere**, because there is no code
  path that reaches it off the main actor.

### async/await over a callback API

CoreBluetooth's operations are fire-and-forget with results arriving in delegate callbacks.
Each is bridged with `withCheckedThrowingContinuation`, which introduces three hazards this
code handles explicitly:

1. **No timeouts exist.** `connect(_:options:)` waits forever — if the peripheral stopped
   advertising, *neither* `didConnect` nor `didFailToConnect` is ever called. Every bridged
   operation goes through `withTimeout`.
2. **Double-resume traps.** One logical operation can be ended by several callbacks (a
   write completes, *or* the peripheral disconnects, *or* the timeout fires).
   `PendingOperation` makes the second resume a no-op instead of a crash.
3. **Cancellation races the dispatch.** `withTaskCancellationHandler`'s handler can run
   before the `queue.async` body that stores the continuation, which would strand it
   forever — hence the `Task.isCancelled` check inside the body.

`connect(to:)` resolves only once the peripheral is genuinely usable: link up, profile
discovered, notifications enabled. A bare `didConnect` is not enough, because no
characteristic handles exist until discovery completes.

### Wire format

Length-prefixed frames, little-endian:

```
 offset  size  field
 0       1     opcode
 1       1     sequence         (wraps at 256; loss detection only)
 2       2     payload length
 4       n     payload
```

Telemetry payload is a fixed 16 bytes (timestamp, HR, steps, battery, flags) — chosen to
fit, with the 4-byte header, inside the **20-byte** default ATT payload, so a sample never
needs fragmenting even before MTU negotiation. JSON would not fit; that is why this is
binary.

The length prefix is what makes `FrameReassembler` possible. BLE notifications are capped
at `ATT_MTU - 3`, so a larger payload arrives as several packets with no framing of its
own.

---

## Setup

### iOS

Requires **Xcode 16 or later** (Swift Testing, and the `@retroactive` attribute in
`BLEConstants.swift`) on macOS. There is no way to build this on Windows or Linux.

Either generate the project:

```sh
brew install xcodegen
cd GalaxyWatchBridge && xcodegen generate
open GalaxyWatchBridge.xcodeproj
```

…or create it by hand: new **iOS App**, SwiftUI, named `GalaxyWatchBridge`, minimum
**iOS 17** (required for `@Observable` and `ContentUnavailableView`); drag in `Core/` and
`Features/`; then set `INFOPLIST_FILE` to `Resources/Info.plist` and
`GENERATE_INFOPLIST_FILE` to `NO` — Xcode 15+ otherwise synthesises its own plist that
collides with the one here.

**`NSBluetoothAlwaysUsageDescription` is mandatory.** Without it the app crashes the moment
`CBCentralManager` is instantiated — no build error, no exception, just a console line
about a missing usage description.

Then: set your team under Signing & Capabilities, change `PRODUCT_BUNDLE_IDENTIFIER` to
something of your own, and run on a **physical iPhone**. The Simulator reports
`.unsupported` forever.

On iOS 16+, enable **Settings → Privacy & Security → Developer Mode** on the phone first
(it requires a restart). Without it the app installs and then refuses to launch.

### Wear OS

1. New Android Studio project, **Wear OS** template, Kotlin.
2. Add `GattServerService.kt`, fixing the package name.
3. Merge `AndroidManifest-snippet.xml`.
4. **Request `BLUETOOTH_ADVERTISE` and `BLUETOOTH_CONNECT` at runtime** before starting
   the service. Declaring them in the manifest is not sufficient on API 31+ — without the
   grant, `openGattServer` returns `null` and advertising fails silently.
5. Start the service and keep the watch app in the foreground. Wear OS suspends background
   work aggressively.

### Changing the UUIDs

`BLEConstants.swift` and `GattServerService.kt` must agree byte-for-byte. A mismatch
presents as a watch that advertises but exposes no services — the most confusing failure
mode in this project. Generate a fresh set with `uuidgen` and change both.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Crash on launch, no error | `NSBluetoothAlwaysUsageDescription` missing from Info.plist |
| `.unsupported` state forever | Running in the Simulator. CoreBluetooth needs real hardware |
| Watch never appears in a filtered scan | Service UUID not in the *advertisement*. It must be in `AdvertiseData`, not only the GATT table |
| Appears, connects, no services | UUID mismatch between `BLEConstants.swift` and `GattServerService.kt` |
| Connects but no telemetry arrives | CCCD descriptor (`0x2902`) missing on the notify characteristic — iOS `setNotifyValue(true:)` fails without it |
| Values look like plausible garbage | Byte order. `ByteBuffer` defaults to **big**-endian; every buffer needs `.order(ByteOrder.LITTLE_ENDIAN)` |
| Write times out | Wear OS handler working before calling `sendResponse`. Respond first, then do the work |
| Works foreground, dies backgrounded | Background scans must be **filtered**. `scanForPeripherals(withServices: nil)` returns nothing, and `allowDuplicates` is ignored |
| `openGattServer` returns null | Runtime Bluetooth permissions not granted (API 31+), or Bluetooth is off |

---

## Not implemented

Deliberate omissions, so the gaps are visible rather than assumed:

- **Real sensors.** `readSensors()` returns synthetic values. Wire up Health Services
  (`androidx.health.services.client`) for HR and steps, `ACTION_BATTERY_CHANGED` for
  battery, `TYPE_LOW_LATENCY_OFFBODY_DETECT` for on-wrist.
- **Pairing / bonding and encryption.** Characteristics use open permissions. Anything
  carrying health data should require `PERMISSION_READ_ENCRYPTED` and a bonded link.
- **Persistence.** Telemetry is in-memory only; history is capped at 120 samples.
- **Tests beyond the wire format.** `GalaxyWatchBridgeTests/WireFormatTests.swift` covers
  the codec, framing and reassembly (Swift Testing; add it to a test target). `BLEManager`
  itself is untested — testing it means abstracting `CBCentralManager` behind a protocol
  and injecting a fake, which is worth doing before this grows.

## Build status

The iOS side **compiles and its tests pass** — 21 tests across 4 suites, run on CI against
an iPhone 17 Pro simulator. `.github/workflows/build.yml` builds an unsigned `.ipa` on
every push; download it from the run summary and re-sign locally with Sideloadly (the
workflow deliberately holds no certificates, since this repo is public).

Getting there took three CI runs, and two of the failures are worth knowing about:

- **A green build job produced an uninstallable app.** With `GENERATE_INFOPLIST_FILE=NO`,
  Xcode does not supply the bundle identity keys it would otherwise synthesise. A plist
  missing `CFBundleIdentifier` compiles, packages into an `.ipa`, and raises no warning —
  it fails only at install time with "Missing bundle ID". The simulator install in the
  test job caught it; the device build had no way to notice.
- **`armv7` in `UIRequiredDeviceCapabilities`** — old boilerplate that is now actively
  harmful. Modern iPhones are arm64-only and do not report that capability, so iOS rejects
  the install as incompatible.

**Still unverified: everything requiring real hardware.** The app has not been run against
an actual watch, so the GATT interaction — discovery, subscription, framing over a real
MTU — is untested end-to-end. The Wear OS side has never been compiled at all.
