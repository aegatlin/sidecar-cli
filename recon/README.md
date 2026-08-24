# recon

Throwaway diagnostics, not part of the tool. Nothing here is built or shipped.

- `probe.swift` — dumps SidecarCore's Objective-C method, property and ivar lists,
  then prints the live device/connection state.
- `probe-dump.txt` — its output, captured on macOS 26.6.2 / Swift 6.3.3.

Run it when a macOS update breaks `sidecar`, to see what changed:

```sh
swiftc -O recon/probe.swift -o /tmp/probe && /tmp/probe
```

Read the "Gotchas hit during reconnaissance" section of `../CLAUDE.md` before editing it.
