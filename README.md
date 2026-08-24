# sidecar

Toggle an iPad on and off as a second display from the command line.

## Build

```sh
swiftc -O sidecar.swift -o ~/.local/bin/sidecar
```

No dependencies. macOS only.

## Use

```sh
sidecar toggle        # connect if off, disconnect if on
sidecar status        # device name, or "disconnected"
sidecar devices       # list reachable iPads
sidecar connect
sidecar disconnect
```

Any command takes an optional device name if you have more than one iPad:

```sh
sidecar toggle "gatlin's ipad"
```

Matching ignores case, accents and curly-vs-straight apostrophes, and accepts
any unambiguous substring. `--json` works on `devices` and `status`.

Run `sidecar --help` for the rest, including exit codes.

## Gotcha

Connecting fails if the iPad is locked or asleep, even though it still shows up
in `sidecar devices`. Wake and unlock it first. The error says so.
