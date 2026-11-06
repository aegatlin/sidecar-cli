# sidecar

Connect an iPad as a Sidecar display from the command line.

## Build

```sh
swiftc -O sidecar.swift -o ~/.local/bin/sidecar
```

No dependencies. macOS only.

## Use

```sh
sidecar connect       # connect to the first reachable iPad
sidecar disconnect
```

Run `sidecar --help` for exit codes.

## Gotcha

Connecting fails if the iPad is locked or asleep, even though it is still
reachable. Wake and unlock it first. The error says so.
