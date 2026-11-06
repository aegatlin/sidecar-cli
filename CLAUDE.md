# CLAUDE.md

Implementation notes for `sidecar`. Read this before changing `sidecar.swift`.

## What this is

A single-file Swift CLI that connects and disconnects an iPad Sidecar display by
driving Apple's **private** `SidecarCore` framework through the Objective-C runtime.
There is no public API for this. Assume Apple will eventually break it.

- Source: `sidecar.swift` (one file, no SwiftPM manifest, no Xcode project)
- Build: `swiftc -O sidecar.swift -o ~/.local/bin/sidecar`
- Diagnostics: `recon/` — not built, not shipped. See `recon/README.md`.

## Architecture

All private-API contact is confined to the `SidecarCore` class in `sidecar.swift`.
It exposes a typed Swift interface:

```swift
init() throws
func devices() throws -> [Device]
func connectedDevices() throws -> [Device]
func connect(_ device: Device, timeout: TimeInterval) throws
func disconnect(_ device: Device, timeout: TimeInterval) throws
```

`Device` carries `name`, `id`, and a `fileprivate` `NSObject` handle. Nothing outside
that class references `dlopen`, `perform(Selector(...))`, `NSClassFromString`, or the
framework's existence. **Keep it that way** — the command layer must stay testable and
free of Objective-C.

Selector names are `private static let` constants at the top of the class, so a macOS
update that renames one is a one-line fix.

## The private API surface (verified on macOS 26.6.2)

`/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore`

**`SidecarDisplayManager`** (`+sharedManager`, `+isSupported`, `+model`)

| Member | Notes |
|---|---|
| `devices` → NSArray | All reachable devices. Includes disconnected ones. |
| `connectedDevices` → NSArray | **The status mechanism.** Empty when nothing is connected. |
| `recentDevices` → NSArray | Not used. |
| `configForDevice:` → SidecarDisplayConfig | Non-nil only while connected. Not used. |
| `connectToDevice:completion:` | completion is `@convention(block) (NSError?) -> Void` |
| `connectToDevice:withConfig:completion:` | **Deliberately unused** — see Non-goals. |
| `disconnectFromDevice:completion:` | |

**`SidecarDevice`**: `name`, `identifier` (NSUUID), `model`, `version`, `deviceType`
(UTType), `status` (opaque `unsigned long long`), plus camera and capability accessors.

`SidecarDisplayConfig` exists with 22 properties including `transport`. Unused.

## Why `connectedDevices` and not `system_profiler`

Measured both states against `system_profiler SPDisplaysDataType` ground truth:

| | connected | disconnected |
|---|---|---|
| `devices` | 1 | 1 |
| `connectedDevices` | **1** | **0** |
| `configForDevice:` | displayID 4 | nil |
| `status` | `0x8000880302` | `0x880302` |

`connectedDevices` is exact. `system_profiler` costs 1–2s per call, which is
unacceptable for a hotkey-bound toggle, and is only a fallback if this ever breaks.

Bit 39 of `SidecarDevice.status` is evidently the connected flag. **Do not depend on
it** — it is an undocumented bitfield with no stable meaning.

There is no notification, delegate, or observer API. A 3-second listen on both
`NotificationCenter` and `DistributedNotificationCenter` produced nothing, and the
manager exposes no observer registration. Do not go looking again.

## Timeouts

The prior art (`Ocasio-J/SidecarLauncher`) uses a bare `DispatchGroup.wait()` and hangs
forever if the completion block never fires. `SidecarCore.invoke` instead:

1. Installs a 0.05s repeating `Timer` as a run-loop source. Without a source,
   `RunLoop.run(mode:before:)` returns instantly and the loop spins hot on CPU.
2. Polls a lock-guarded `finished` flag until the deadline, running the loop in
   0.05s slices. Do not pass the full deadline to `run(mode:before:)`: a timer firing
   does not make it return (only an input source does), so a completion delivered on
   another queue would go unnoticed until the timeout.

Spinning the run loop rather than blocking the thread means a completion delivered on
the **main queue** would still land, instead of deadlocking. In practice SidecarCore
delivers on its own queue, but this costs nothing and removes the failure mode.

**A timed-out connect is not cancelled.** SidecarCore has no cancel API, so the
connection may still complete a second after exit 5. This is inherent. It is why the
default timeout is a generous 15s.

## Name matching

`normalize()` folds case, diacritics and width, maps six apostrophe variants
(`' ' ‛ ＇ ´ \``) to ASCII `'`, and collapses whitespace runs. The real-world case is
`Joe's iPad` typed against the device's actual `Joe‘s iPad`.

`selectDevice()` prefers an exact normalized match, then an unambiguous substring
match. It **never guesses** between candidates — multiple matches is exit 3 with the
candidates listed. Note that substring means `austin's ipad` does *not* match
`Austin Gatlin's iPad`; that is correct, not a bug.

Bare device names are joined from all non-flag words, so quoting is optional.

## Exit codes

`0` success · `1` bad usage · `2` no devices reachable · `3` device not found or
ambiguous · `4` SidecarCore error **or private API unavailable** · `5` timed out.

Codes 4 and 5 are deliberately merged/kept per the original spec's table. Every code is
documented in `--help`; do not add an undocumented one.

`status` **always exits 0**, connected or not — scripts rely on this.
Errors go to stderr, machine-readable output to stdout.

## Known SidecarCore error codes

| Code | Meaning | Handling |
|---|---|---|
| `-100` | "The device is already in use." | `localizedDescription` is already plain English; passed through |
| `-102` | "The device is not connected." | Same |
| `-203` | `SidecarErrorDeviceWiFiNotEnabled` | **Special-cased.** Really means the iPad is locked or asleep. Replaced with a plain-English hint. |

## Failure when the API is gone

`SidecarCore.init` validates the dlopen, the class, `+sharedManager`, and all four
instance selectors up front, throwing `.unavailable(String)` naming exactly what was
missing. No `fatalError`, no force-unwraps on private-API results, no crash report.
Preserve this property.

## Verified vs unverified

Exercised on real hardware: all read-only commands, `--json` on both, toggle round-trips
(connect ~1.5s, disconnect ~0.03s), fuzzy name matching, exit 1, exit 3, exit 5, and the
`-100`/`-102` paths.

**Not yet exercised:** exit 2 (needs Wi-Fi/Bluetooth off) and the `-203` hint (needs a
locked iPad). The `-203` string is written from the documented behaviour, not observed.

## Gotchas hit during reconnaissance

If you rewrite `recon/probe.swift`, these will bite again:

- **Never call `NSStringFromClass` while iterating `objc_copyClassList`.** It aborts on
  internal classes (`__NSGenericDeallocHandler` does not implement
  `methodSignatureForSelector:`). Use `class_getName`, or better
  `objc_copyClassNamesForImage` — though that returns nothing here, since SidecarCore
  lives in the dyld shared cache rather than being separately loaded.
- **Never `perform()` a selector whose return type is not an object.** Check the type
  encoding starts with `@` first; call `B`/`Q`/`q` returns through a typed
  `@convention(c)` function pointer instead. `SidecarDevice.status` is `Q`.
- **`setvbuf(stdout, nil, _IONBF, 0)`** when probing. Redirected stdout is block
  buffered, so a crash truncates output at a 4KB boundary and makes the crash look like
  it happened somewhere it didn't.
- `String(cString:)` needs an optional-unwrapping helper for the runtime's
  `UnsafePointer<CChar>?` returns.

## Non-goals

Do not add, unless asked: the wired transport (`SidecarDisplayConfig` + `setTransport:`
value 2 + `connectToDevice:withConfig:completion:`), a GUI, a menu bar item, a launchd
agent, a login item, an installer script, window-moving logic (Rectangle handles that),
or any external dependency including ArgumentParser. Arg parsing stays hand-rolled.

The binary lives at `~/.local/bin/sidecar`, which is on PATH via `.zshrc`. It is invoked
manually; there is intentionally no hotkey binding committed to this repo.
