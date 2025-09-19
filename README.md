# airportx

**English** | [中文](./README_zh.md)

`airportx` is a macOS Wi‑Fi inspector designed to surface the currently active
service, SSID, BSSID, security, signal quality, channel, DHCP metadata, and the
provenance of every field — all **without** using CoreLocation, the private
`airport` command, or Location-gated CoreWLAN operations.

## Features

- **TCC-friendly:** Never calls CoreLocation. Optional CoreWLAN reads are
  passive (no scans, no power toggles) and can be disabled with `--no-live`.
- **Source precedence:** Values come from SystemConfiguration → CoreWLAN →
  IORegistry → Known Networks → Derived/Heuristic. `--detail` shows exactly
  which source supplied each field.
- **VPN-aware selection:** Automatically chooses the active Wi‑Fi service,
  skipping primary VPN/tunnel interfaces (`utun*`).
- **Deterministic JSON:** `--json` emits a single, ordered object suitable for
  scripting or telemetry pipelines.
- **Documented & auditable:** Single-file Swift implementation with inline
  documentation, no external dependencies.

## Installation

### Homebrew tap (recommended)

```bash
brew tap fjh658/airportx https://github.com/fjh658/airportx
brew install fjh658/airportx/airportx
```

During `brew install`, the formula compiles `airportx.swift` and then elevates
`${HOMEBREW_PREFIX}/bin/airportx` so it can read the system known-networks plist
without needing `sudo` each time:

```bash
sudo chown root $(which airportx)
sudo chmod 4755 $(which airportx)
```

If those commands fail (for example due to corporate security policies), the
formula prints instructions so you can re-run them manually.

### Build from source

```bash
# Universal binary (x86_64 + arm64)
make universal

# Optional: install and raise privileges manually
sudo install -m 0755 airportx /usr/local/bin/airportx
sudo chown root:wheel /usr/local/bin/airportx
sudo chmod u+s /usr/local/bin/airportx
```

The resulting binary targets macOS 10.13+ (x86_64) and 11.0+ (arm64). Remove the
setuid bit if you prefer to invoke `sudo airportx` on demand.

### Swift Package Manager

```bash
swift build -c release --arch x86_64 --arch arm64
cp .build/apple/Products/Release/airportx ./airportx
```

SwiftPM now targets macOS 11+, so both architectures share the same deployment
baseline and the release output matches `make universal` without extra scripts.

## Usage

```text
airportx [options] [iface]

Options:
  -h, --help        Show help
  -V, --version     Print version
  -v, --verbose     Print diagnostics to stderr (interface selection, environment)
      --json        Emit a single JSON object (iface first, alphabetical remainder)
      --detail      When combined with --json, add `<key>Source` provenance fields
      --ssid        Print only the SSID (value-only mode)
      --bssid       Print only the BSSID (value-only mode)
      --no-live     Disable CoreWLAN enrichment
      --no-color    Disable ANSI colours in verbose output
```

- No positional iface: the tool picks the active Wi‑Fi service.
- Explicit iface (`airportx en1`): binds strictly to that service, even if wired.
  The result may be `Unknown (not associated)` — still exit code `0`.
- Non-existent iface: exit `3`. Usage errors: exit `2`.

### JSON detail example

```bash
sudo airportx --json --detail
{
  "iface" : "en0",
  "ifaceSource" : "SystemConfiguration",
  "bssid" : "aa:bb:cc:dd:ee:ff",
  "bssidSource" : "CoreWLAN",
  …
}
```

`*Source` keys map back to the following origins:

| Source                 | Description                                                     |
| ---------------------- | --------------------------------------------------------------- |
| `SystemConfiguration`  | Dynamic store (runtime network state)                           |
| `CoreWLAN`             | Live telemetry from `CWWiFiClient` (passive reads)              |
| `IORegistry`           | Hardware properties via `IO80211Interface`                     |
| `KnownNetworks`        | Inferred from `/Library/Preferences/com.apple.wifi.known-networks.plist` |
| `LeaseFile`            | DHCP server derived from `/var/db/dhcpclient/leases`           |
| `Heuristic`            | Last-resort guess (e.g. router equals DHCP server)             |
| `Derived`              | Computed from other fields (band, SNR, etc.)                    |

## How it works

1. Query SystemConfiguration to discover the active service/interface, router,
   and DHCP metadata.
2. Optionally query CoreWLAN for live metrics (SSID, BSSID, RSSI, noise, channel,
   PHY, security). If disabled or redacted, continue.
3. Consult IORegistry for channel/country/BSSID fallbacks.
4. Read `/Library/Preferences/com.apple.wifi.known-networks.plist` (system
   scope) and correlate DHCP Server Identifier, Router signatures, and channels
   to infer SSID/BSSID/security when live APIs decline to share them. The plist
   is opened with `O_NOFOLLOW` and owner checks; privileges are dropped after
   the read.
5. Compute derived values (band, SNR) only when necessary.

## Security considerations

- No CoreLocation calls and no private `airport` binary usage.
- Known-networks plist read is the only privileged operation. If you do not set
  the binary to setuid, run `sudo airportx …` when you need it.
- The tool does **not** mutate Wi‑Fi state. All data access is read-only.

## Development

```bash
swiftc -typecheck -parse-as-library airportx.swift
swiftc airportx.swift -o airportx
OR
make universal

sudo chown root ./airportx && sudo chmod +s ./airportx
./airportx --json --detail
```

The project is intentionally single-file; feel free to open issues or send pull
requests.

## License

MIT License – see [LICENSE](LICENSE) if present, or include attribution in your
own distributions.

## Acknowledgements

- Apple SystemConfiguration, IOKit, and CoreWLAN teams for the underlying APIs.
- The macOS community for documenting Wi‑Fi diagnostics internals.
