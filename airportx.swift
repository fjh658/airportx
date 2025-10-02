
/*
 airportx — Wi‑Fi state & reporting (aligned with latest resolver logic)

 State machine
 - powerOff
 - unassociated
 - associatedNoRuntime
 - associatedOnline

 Evidence & precedence
 - CoreWLAN: only SSID/BSSID count as association (wlanChannel alone is not proof).
 - SystemConfiguration (runtime): Router or DHCP from the dynamic store counts as runtime evidence.
 - IORegistry: radio/environment properties; scrubbed when offline.
 - Known Networks (system scope): /Library/Preferences/com.apple.wifi.known-networks.plist
   Used only on degraded/fallback path; reading requires sudo (or setuid root). We open with O_NOFOLLOW
   and verify root ownership; any temporary privileges are dropped immediately. If not permitted, this source is skipped.
 - Derived: band from channel, snr from rssi−noise.

 Early exits
 1) powerOff (CWInterface.powerOn() == false) → state=powerOff, return.
 2) Selected interface is not Wi‑Fi → state=unassociated, return.
 3) Radio on but no CoreWLAN SSID/BSSID and no runtime evidence → state=unassociated, return.

 Backstop scrub (post-merge)
 - When no runtime and no CoreWLAN SSID/BSSID, clear potentially stale fields:
   ssid, bssid, rssi, noise, snr, txRate, security, phy, channel, band, ssidLastSeen.

 Output policy
 - Default (`airportx`):
   STATE=<state>
   SSID=<ssid>               # only when state == associatedOnline
 - Value-only (`--ssid`, `--bssid`):
   Always print STATE=<state>, and only print requested values when state == associatedOnline.
 - JSON (`--json`):
   Always emit an object with "state" and "iface". Optional fields appear only when known.
   `--detail` adds `<key>Source` origin keys (CoreWLAN/SystemConfiguration/IORegistry/KnownNetworks/Derived).
 - `--state`: prints only the consolidated state.
 - `-v` / `--verbose`: prints selection diagnostics to stderr.

 Notes
 - SSID nil ≠ radio off.
 - wlanChannel may be non-nil while unassociated; do not treat it as association evidence.
 - Version string is declared in this file as: `private static let version = "…"`.

 ./airportx
 ./airportx --ssid
 ./airportx --bssid
 ./airportx --ssid --bssid
 ./airportx --json --detail
 ./airportx --json --no-live
 ./airportx --state
*/

import Foundation
import SystemConfiguration
import IOKit
import Darwin
#if canImport(CoreWLAN)
import CoreWLAN
#endif

@inline(__always) private func isTerminal(_ fd: Int32) -> Bool {
    return isatty(fd) != 0
}

/// Enumerates the provenance of a field so JSON `*Source` keys can be mapped back
/// to the origin of the data. This lets callers reason about confidence levels
/// without reverse-engineering the resolver pipeline.
private enum FieldOrigin: String {
    /// Live telemetry read directly from CoreWLAN (if allowed).
    case coreWLAN = "CoreWLAN"
    /// Values pulled from the hardware-facing IORegistry (IO80211Interface).
    case ioRegistry = "IORegistry"
    /// Data obtained from SystemConfiguration dynamic store (runtime network state).
    case systemConfiguration = "SystemConfiguration"
    /// Information inferred from the system known-networks database.
    case knownNetworks = "KnownNetworks"
    /// Server identifiers recovered from historical DHCP lease files.
    case leaseFile = "LeaseFile"
    /// Last-resort heuristics when no authoritative source is available.
    case heuristic = "Heuristic"
    /// Values derived from other fields (e.g., SNR or frequency band).
    case derived = "Derived"
}

private struct Ansi {
    static var enabled: Bool {
        if getenv("NO_COLOR") != nil { return false }
        return isTerminal(STDERR_FILENO)
    }

    @inline(__always) private static func wrap(_ text: String, code: String) -> String {
        guard enabled else { return text }
        return "\u{001B}[" + code + "m" + text + "\u{001B}[0m"
    }

    static func bold(_ text: String) -> String { wrap(text, code: "1") }
    static func dim(_ text: String) -> String { wrap(text, code: "2") }
    static func cyan(_ text: String) -> String { wrap(text, code: "36") }
    static func green(_ text: String) -> String { wrap(text, code: "32") }
    static func yellow(_ text: String) -> String { wrap(text, code: "33") }
    static func magenta(_ text: String) -> String { wrap(text, code: "35") }
}

/// Represent the consolidated Wi-Fi state emitted by the resolver. The struct is
/// intentionally Codable so JSON output can be deterministic and field ordering
/// can be enforced by a custom `encode(to:)` implementation.
private struct WiFiSnapshot {
    var iface: String = ""
    var state: String?
    var serviceID: String?
    var ssid: String?
    var ssidLastSeen: Date?
    var bssid: String?
    var channel: Int?
    var band: String?
    var phy: String?
    var countryCode: String?
    var security: String?
    var routerIPv4: String?
    var dhcpServerIPv4: String?
    var dhcpSource: String?
    var rssi: Int?
    var noise: Int?
    var snr: Int?
    var txRate: Double?
}

/// Convenience alias for the `<field>: <origin>` map that powers the `--detail`
/// output. Keys mirror the payload field names so they can be paired easily.
private typealias FieldSources = [String: String]

@inline(__always) private func ipv4String(from data: Data) -> String {
    let bytes = [UInt8](data.prefix(4))
    guard bytes.count == 4 else { return "" }
    return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
}

@inline(__always) private func ipv4Data(from string: String) -> Data? {
    var address = in_addr()
    guard inet_aton(string, &address) == 1 else { return nil }
    var raw = address.s_addr
    return Data(bytes: &raw, count: MemoryLayout.size(ofValue: raw))
}

#if os(macOS)
private let ioDefaultPort: mach_port_t = {
    #if swift(>=5.5)
    if #available(macOS 12.0, *) {
        return kIOMainPortDefault
    }
    #endif
    return kIOMasterPortDefault
}()
#endif

@inline(__always) private func normalizedCountryCode(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let filtered = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
    guard filtered.count == 2 else { return nil }
    return String(String.UnicodeScalarView(filtered)).uppercased()
}

@inline(__always) private func countryCodeString(from data: Data) -> String? {
    if let string = String(data: data, encoding: .utf8), !string.isEmpty { return string }
    if let string = String(data: data, encoding: .ascii), !string.isEmpty { return string }
    let trimmed = data.prefix { $0 != 0 }
    if let string = String(bytes: trimmed, encoding: .ascii), !string.isEmpty { return string }
    return nil
}

@inline(__always) private func assignIfEmpty<T>(_ field: inout T?, key: String, value: T?, origin: FieldOrigin, sources: inout FieldSources) {
    guard field == nil, let value = value else { return }
    field = value
    sources[key] = origin.rawValue
}

/// Captures the network environment chosen by `EnvironmentReader`. This is the
/// authoritative view of the active interface/service and is populated using the
/// SystemConfiguration dynamic store exclusively.
private struct EnvironmentInfo {
    var iface: String
    var serviceID: String?
    var routerIPv4: String?
    var dhcpServerIPv4: String?
    var dhcpSource: String?
    var dhcpOrigin: FieldOrigin?
    var isWiFi: Bool
}

/// Central orchestrator that merges all data sources in descending precedence.
/// Callers receive both the resolved snapshot and a dictionary describing where
/// each field came from (when available).
private final class WiFiResolver {
    /// Query radio power state via CoreWLAN without triggering scans.
    /// Returns true/false when known, or nil if CoreWLAN/interface is unavailable.
    private static func radioPowerOn(iface: String) -> Bool? {
#if canImport(CoreWLAN)
        let client = CWWiFiClient.shared()
        let cw = client.interface(withName: iface) ?? client.interface()
        return cw?.powerOn()
#else
        return nil
#endif
    }
    /// Early offline gate: if there's no runtime evidence and no live CoreWLAN,
    /// return true to skip all later enrichments (IORegistry/KnownNetworks).
    private static func shouldEarlyExitOffline(env: EnvironmentInfo, liveCoreWLAN: Bool) -> Bool {
        let hasRuntime = (env.routerIPv4 != nil) || (env.dhcpOrigin == .systemConfiguration)
        var hasLiveCW = false
#if canImport(CoreWLAN)
        if liveCoreWLAN {
            let client = CWWiFiClient.shared()
            let interface = client.interface(withName: env.iface) ?? client.interface()
            if let cw = interface {
                if let s = cw.ssid(), !s.isEmpty { hasLiveCW = true }
                else if let ch = cw.wlanChannel()?.channelNumber, ch > 0 { hasLiveCW = true }
            }
        }
#endif
        // If selected interface isn't Wi‑Fi, we still treat as "unassociated"
        // unless CoreWLAN proves a live link.
        if !env.isWiFi {
            return !hasLiveCW
        }
        return !hasRuntime && !hasLiveCW
    }
    /// Produce a snapshot for the requested interface (or the best Wi-Fi choice)
    /// using the configured source precedence. The `liveCoreWLAN` parameter lets
    /// callers disable CoreWLAN enrichment (`--no-live`).
    static func collect(preferredInterface: String, strict: Bool, liveCoreWLAN: Bool) -> (WiFiSnapshot, FieldSources) {
        var snapshot = WiFiSnapshot()
        var sources: FieldSources = [:]

        let env = EnvironmentReader.fetch(preferred: preferredInterface, strict: strict)
        snapshot.iface = env.iface
        sources["iface"] = FieldOrigin.systemConfiguration.rawValue
        assignIfEmpty(&snapshot.serviceID, key: "serviceID", value: env.serviceID, origin: .systemConfiguration, sources: &sources)
        assignIfEmpty(&snapshot.routerIPv4, key: "routerIPv4", value: env.routerIPv4, origin: .systemConfiguration, sources: &sources)
        if let dhcp = env.dhcpServerIPv4 {
            let origin = env.dhcpOrigin ?? .systemConfiguration
            assignIfEmpty(&snapshot.dhcpServerIPv4, key: "dhcpServerIPv4", value: dhcp, origin: origin, sources: &sources)
            assignIfEmpty(&snapshot.dhcpSource, key: "dhcpSource", value: env.dhcpSource, origin: origin, sources: &sources)
        } else {
            assignIfEmpty(&snapshot.dhcpSource, key: "dhcpSource", value: env.dhcpSource, origin: .systemConfiguration, sources: &sources)
        }

        // ---- Early state gate (power / association / runtime) ----
        // 1) Radio power
        if let power = radioPowerOn(iface: env.iface), power == false {
            snapshot.state = "powerOff"
            return (snapshot, sources)
        }
        // 2) Runtime evidence (router or DHCP from SystemConfiguration)
        let hasRuntime = (env.routerIPv4 != nil) || (env.dhcpOrigin == .systemConfiguration)
        // 3) Association evidence from CoreWLAN (only SSID/BSSID; channel is unreliable for association)
        var preAssocCW: Bool? = nil
#if canImport(CoreWLAN)
        if liveCoreWLAN {
            let client = CWWiFiClient.shared()
            let interface = client.interface(withName: env.iface) ?? client.interface()
            if let cw = interface {
                let ss = cw.ssid()
                let bb = cw.bssid()
                preAssocCW = (bb != nil) || (ss != nil && !(ss!.isEmpty))
            }
        }
#endif
        // 4) Not a Wi‑Fi selection → treat as unassociated
        if !env.isWiFi {
            snapshot.state = "unassociated"
            return (snapshot, sources)
        }
        // 5) If we can tell we're not associated and also have no runtime, exit early as unassociated
        if let assoc = preAssocCW, assoc == false, !hasRuntime {
            snapshot.state = "unassociated"
            return (snapshot, sources)
        }
        // ----------------------------------------------------------

        #if canImport(CoreWLAN)
        if liveCoreWLAN && env.isWiFi {
            CoreWLANReader.populate(into: &snapshot,
                                    sources: &sources,
                                    iface: env.iface,
                                    allowFallback: !strict,
                                    expectedRouter: env.routerIPv4,
                                    expectedDHCP: env.dhcpServerIPv4)
        }
        #endif

        IORegistryReader.populate(into: &snapshot, sources: &sources, iface: env.iface)

        if env.isWiFi {
            KnownNetworksStore.enrich(into: &snapshot, sources: &sources, env: env)
        }

        // If we appear to be offline/unassociated, purge stale fields inferred
        // from IORegistry/KnownNetworks so output reflects the current state.
        scrubIfUnassociated(snapshot: &snapshot, sources: &sources, env: env)

        if let channel = snapshot.channel {
            assignIfEmpty(&snapshot.band, key: "band", value: BandCalculator.band(for: channel), origin: .derived, sources: &sources)
        }
        if let rssi = snapshot.rssi, let noise = snapshot.noise {
            assignIfEmpty(&snapshot.snr, key: "snr", value: rssi - noise, origin: .derived, sources: &sources)
        }

        // ---- Final state stamping ----
        let hasRuntime2 = (env.routerIPv4 != nil) || (env.dhcpOrigin == .systemConfiguration)
        let assocCWPost = (sources["bssid"] == FieldOrigin.coreWLAN.rawValue) || (sources["ssid"] == FieldOrigin.coreWLAN.rawValue)
        if let power = radioPowerOn(iface: env.iface), power == false {
            snapshot.state = "powerOff"
        } else if hasRuntime2 {
            snapshot.state = "associatedOnline"
        } else if assocCWPost {
            snapshot.state = "associatedNoRuntime"
        } else {
            snapshot.state = "unassociated"
        }
        // --------------------------------

        return (snapshot, sources)
    }

    private static func scrubIfUnassociated(snapshot: inout WiFiSnapshot,
                                             sources: inout FieldSources,
                                             env: EnvironmentInfo) {
        // Only treat CoreWLAN SSID/BSSID as live association evidence; channel alone is not reliable.
        let hasRuntime = (env.routerIPv4 != nil) || (env.dhcpOrigin == .systemConfiguration)
        let ssidOrigin = sources["ssid"]
        let bssidOrigin = sources["bssid"]
        let hasLiveSSID  = (ssidOrigin == FieldOrigin.coreWLAN.rawValue)
        let hasLiveBSSID = (bssidOrigin == FieldOrigin.coreWLAN.rawValue)

        // Consider non‑Wi‑Fi selections and lack of runtime+live association as offline → scrub.
        let likelyOffline = (!env.isWiFi) || (!hasRuntime && !hasLiveSSID && !hasLiveBSSID)
        if likelyOffline {
            // Drop fields that are often stale when pulled from IORegistry or
            // KnownNetworks, so CLI output falls back to "Unknown (not associated)"
            snapshot.ssid = nil
            snapshot.bssid = nil
            snapshot.rssi = nil
            snapshot.noise = nil
            snapshot.snr = nil
            snapshot.txRate = nil
            snapshot.security = nil
            snapshot.phy = nil
            snapshot.channel = nil
            snapshot.band = nil
            snapshot.ssidLastSeen = nil

            for k in ["ssid","bssid","rssi","noise","snr","txRate","security","phy","channel","band"] {
                sources.removeValue(forKey: k)
            }
        }
    }
}

/// Lightweight helper that maps IEEE 802.11 channels to user-friendly bands.
private struct BandCalculator {
    static func band(for channel: Int) -> String {
        switch channel {
        case 1...14:
            return "2.4GHz"
        case 36...64, 100...144, 149...165:
            return "5GHz"
        case 1...233:
            return "6GHz"
        default:
            return "Unknown"
        }
    }
}

/// Responsible for selecting the active Wi-Fi interface/service (VPN aware) and
/// capturing DHCP/router metadata from the dynamic store.
private enum EnvironmentReader {
    static func fetch(preferred: String, strict: Bool) -> EnvironmentInfo {
        var info = EnvironmentInfo(iface: preferred,
                                   serviceID: nil,
                                   routerIPv4: nil,
                                   dhcpServerIPv4: nil,
                                   dhcpSource: nil,
                                   dhcpOrigin: nil,
                                   isWiFi: false)
        guard let store = SCDynamicStoreCreate(kCFAllocatorDefault, "airportx" as CFString, nil, nil) else { return info }

        if strict {
            if isTunnelInterface(preferred), let wifi = pickActiveWiFi(store: store) {
                info.iface = wifi.iface
                info.serviceID = wifi.serviceID
            } else if let sid = serviceID(for: preferred, store: store) {
                info.iface = preferred
                info.serviceID = sid
            } else {
                return info
            }
        } else {
            if let wifi = pickActiveWiFi(store: store) {
                info.iface = wifi.iface
                info.serviceID = wifi.serviceID
            } else if let sid = serviceID(for: preferred, store: store) {
                info.serviceID = sid
            }
        }

        info.isWiFi = isWiFiBSDNameFast(info.iface, store: store)

        if info.serviceID == nil {
            if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
                if let iface = global["PrimaryInterface"] as? String, !strict {
                    info.iface = iface
                }
                info.serviceID = global["PrimaryService"] as? String
                info.routerIPv4 = global["Router"] as? String
                info.isWiFi = isWiFiBSDNameFast(info.iface, store: store)
            }
        }

        guard let sid = info.serviceID else {
            info.dhcpServerIPv4 = LeaseFileReader.lookupDHCPServer(interface: info.iface)
            if info.dhcpServerIPv4 != nil { info.dhcpSource = "lease" }
            if info.dhcpServerIPv4 != nil { info.dhcpOrigin = .leaseFile }
            return info
        }

        let baseKey = "State:/Network/Service/" + sid
        if let ipv4 = SCDynamicStoreCopyValue(store, (baseKey + "/IPv4") as CFString) as? [String: Any] {
            if info.routerIPv4 == nil { info.routerIPv4 = ipv4["Router"] as? String }
        }

        if info.dhcpServerIPv4 == nil,
           let dhcp = SCDynamicStoreCopyValue(store, (baseKey + "/DHCP") as CFString) as? [String: Any],
           let (ip, src) = parseDHCP(dict: dhcp) {
            info.dhcpServerIPv4 = ip
            info.dhcpSource = src
            info.dhcpOrigin = .systemConfiguration
        }

        if info.dhcpServerIPv4 == nil,
           let dhcp4 = SCDynamicStoreCopyValue(store, (baseKey + "/DHCPv4") as CFString) as? [String: Any],
           let (ip, src) = parseDHCP(dict: dhcp4) {
            info.dhcpServerIPv4 = ip
            info.dhcpSource = src
            info.dhcpOrigin = .systemConfiguration
        }

        if info.dhcpServerIPv4 == nil,
           let fromLease = LeaseFileReader.lookupDHCPServer(interface: info.iface) {
            info.dhcpServerIPv4 = fromLease
            info.dhcpSource = "lease"
            info.dhcpOrigin = .leaseFile
        }

        if info.dhcpServerIPv4 == nil, let router = info.routerIPv4 {
            info.dhcpServerIPv4 = router
            info.dhcpSource = "router"
            info.dhcpOrigin = .heuristic
        }

        return info
    }

    private static func parseDHCP(dict: [String: Any]?) -> (String, String)? {
        guard let dict = dict else { return nil }
        let keys = [
            "ServerIdentifier", "server_identifier", "ServerID",
            "DHCPServerIdentifier", "DHCPServerID",
            "Option_54", "option_54", "Option 54", "54"
        ]
        for key in keys {
            guard let value = dict[key] else { continue }
            let sourceKey = key.replacingOccurrences(of: " ", with: "_")
            if let string = value as? String, !string.isEmpty {
                return (string, "store:" + sourceKey)
            }
            if let data = value as? Data, data.count >= 4 {
                return (ipv4String(from: data), "store:" + sourceKey)
            }
            if let bytes = value as? [UInt8], bytes.count >= 4 {
                return (ipv4String(from: Data(bytes.prefix(4))), "store:" + sourceKey)
            }
            if let number = value as? NSNumber {
                let raw = number.uint32Value.bigEndian
                let a = UInt8((raw >> 24) & 0xFF)
                let b = UInt8((raw >> 16) & 0xFF)
                let c = UInt8((raw >> 8) & 0xFF)
                let d = UInt8(raw & 0xFF)
                return ("\(a).\(b).\(c).\(d)", "store:" + sourceKey)
            }
        }
        if let options = dict["DHCPOptions"] as? [String: Any] {
            if let (ip, src) = parseDHCP(dict: options) { return (ip, src) }
        }
        return nil
    }

    private static func serviceID(for iface: String, store: SCDynamicStore) -> String? {
        let pattern = "State:/Network/Service/.*/IPv4" as CFString
        guard let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] else { return nil }
        for key in keys {
            guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { continue }
            if let name = dict["InterfaceName"] as? String, name == iface {
                if let range1 = key.range(of: "Service/"), let range2 = key.range(of: "/IPv4"), range1.upperBound < range2.lowerBound {
                    return String(key[range1.upperBound..<range2.lowerBound])
                }
            }
        }
        return nil
    }

    private static func pickActiveWiFi(store: SCDynamicStore) -> (iface: String, serviceID: String)? {
        if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let iface = global["PrimaryInterface"] as? String,
           let sid = global["PrimaryService"] as? String,
           isWiFiInterface(iface: iface, store: store),
           interfaceHasIPv4(serviceID: sid, store: store) {
            return (iface, sid)
        }

        let pattern = "State:/Network/Service/.*/IPv4" as CFString
        guard let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] else { return nil }
        struct Candidate { let iface: String; let sid: String; let hasRouter: Bool; let order: Int }
        var priority: [String: Int] = [:]
        if let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
           let serviceOrder = setup["ServiceOrder"] as? [String] {
            for (index, sid) in serviceOrder.enumerated() { priority[sid] = index }
        }

        var list: [Candidate] = []
        for key in keys {
            guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let iface = dict["InterfaceName"] as? String,
                  !isTunnelInterface(iface),
                  isWiFiInterface(iface: iface, store: store),
                  let addresses = dict["Addresses"] as? [String], !addresses.isEmpty,
                  let range1 = key.range(of: "Service/"),
                  let range2 = key.range(of: "/IPv4") else { continue }
            let sid = String(key[range1.upperBound..<range2.lowerBound])
            let hasRouter = dict["Router"] as? String != nil
            let order = priority[sid] ?? Int.max
            list.append(Candidate(iface: iface, sid: sid, hasRouter: hasRouter, order: order))
        }

        list.sort {
            if $0.hasRouter != $1.hasRouter { return $0.hasRouter && !$1.hasRouter }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.iface < $1.iface
        }
        return list.first.map { ($0.iface, $0.sid) }
    }

    private static func interfaceHasIPv4(serviceID: String, store: SCDynamicStore) -> Bool {
        let key = "State:/Network/Service/\(serviceID)/IPv4" as CFString
        guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return false }
        if let addresses = dict["Addresses"] as? [String] { return !addresses.isEmpty }
        return false
    }

    private static func isWiFiInterface(iface: String, store: SCDynamicStore) -> Bool {
        let key = "State:/Network/Interface/\(iface)/AirPort" as CFString
        if SCDynamicStoreCopyValue(store, key) != nil { return true }
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return false }
        for ifaceRef in all {
            if let name = SCNetworkInterfaceGetBSDName(ifaceRef) as String?, name == iface,
               let type = SCNetworkInterfaceGetInterfaceType(ifaceRef) as String? {
                if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return true }
            }
        }
        return false
    }

    @inline(__always) private static func isWiFiBSDNameFast(_ iface: String, store: SCDynamicStore) -> Bool {
        guard !iface.isEmpty else { return false }
        let key = "State:/Network/Interface/\(iface)/AirPort" as CFString
        if SCDynamicStoreCopyValue(store, key) != nil { return true }
        return isWiFiInterface(iface: iface, store: store)
    }

    private static func isTunnelInterface(_ iface: String) -> Bool {
        return iface.hasPrefix("utun")
    }

    static func classification(for iface: String, store: SCDynamicStore) -> String {
        if isTunnelInterface(iface) { return "VPN" }
        if isWiFiInterface(iface: iface, store: store) { return "Wi-Fi" }
        if let type = interfaceType(iface: iface) {
            let ethernet = kSCNetworkInterfaceTypeEthernet as String
            if type == ethernet { return "wired" }
            let firewire = kSCNetworkInterfaceTypeFireWire as String
            if type == firewire { return "FireWire" }
            let bluetooth = kSCNetworkInterfaceTypeBluetooth as String
            if type == bluetooth { return "Bluetooth" }
            let ppp = kSCNetworkInterfaceTypePPP as String
            let l2tp = kSCNetworkInterfaceTypeL2TP as String
            let ipsec = kSCNetworkInterfaceTypeIPSec as String
            if type == ppp || type == l2tp || type == ipsec { return "VPN" }
        }
        if iface.hasPrefix("bridge") { return "bridge" }
        if iface.hasPrefix("en") { return "wired" }
        return "other"
    }

    static func isTunnel(_ iface: String) -> Bool {
        return isTunnelInterface(iface)
    }

    private static func interfaceType(iface: String) -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for ifaceRef in all {
            if let name = SCNetworkInterfaceGetBSDName(ifaceRef) as String?, name == iface,
               let type = SCNetworkInterfaceGetInterfaceType(ifaceRef) as String? {
                return type
            }
        }
        return nil
    }
}

/// Extracts radio properties from the IORegistry. This API provides a fallback
/// when CoreWLAN is unavailable or redacted by the system.
private enum IORegistryReader {
    static func populate(into snapshot: inout WiFiSnapshot, sources: inout FieldSources, iface: String) {
        if let channel = channelNumber(iface: iface) {
            assignIfEmpty(&snapshot.channel, key: "channel", value: channel, origin: .ioRegistry, sources: &sources)
        }
        if let code = countryCode(iface: iface) {
            assignIfEmpty(&snapshot.countryCode, key: "countryCode", value: code, origin: .ioRegistry, sources: &sources)
        }
        if let bssid = bssidValue(iface: iface) {
            assignIfEmpty(&snapshot.bssid, key: "bssid", value: bssid, origin: .ioRegistry, sources: &sources)
        }
        if let ssid = ssidValue(iface: iface) {
            assignIfEmpty(&snapshot.ssid, key: "ssid", value: ssid, origin: .ioRegistry, sources: &sources)
        }
    }

    private static func channelNumber(iface: String) -> Int? {
        let keys = ["IO80211Channel", "Channel"]
        if let entry = interfaceEntry(iface: iface) {
            defer { IOObjectRelease(entry) }
            if let value = propertyOnEntryOrParents(entry: entry, keys: keys) {
                if let number = value as? NSNumber { return number.intValue }
                if let string = value as? String, let parsed = Int(string) { return parsed }
            }
        }
        if let value = findAnyInterfaceProperty(keys: keys) {
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String, let parsed = Int(string) { return parsed }
        }
        return nil
    }

    private static func countryCode(iface: String) -> String? {
        let keys = ["IO80211CountryCode", "countryCode", "CountryCode", "IO80211Locale", "Locale"]
        if let entry = interfaceEntry(iface: iface) {
            defer { IOObjectRelease(entry) }
            if let value = propertyOnEntryOrParents(entry: entry, keys: keys) {
                if let string = value as? String, let normalized = normalizedCountryCode(string) { return normalized }
                if let data = value as? Data, let string = countryCodeString(from: data), let normalized = normalizedCountryCode(string) { return normalized }
            }
        }
        if let value = findAnyInterfaceProperty(keys: keys) {
            if let string = value as? String, let normalized = normalizedCountryCode(string) { return normalized }
            if let data = value as? Data, let string = countryCodeString(from: data), let normalized = normalizedCountryCode(string) { return normalized }
        }
        return nil
    }

    private static func bssidValue(iface: String) -> String? {
        let keys = ["IO80211BSSID", "BSSID"]
        if let entry = interfaceEntry(iface: iface) {
            defer { IOObjectRelease(entry) }
            if let value = propertyOnEntryOrParents(entry: entry, keys: keys) {
                if let string = normalizeBSSID(string: value as? String) { return string }
                if let data = value as? Data, let string = normalizeBSSID(data: data) { return string }
            }
        }
        if let value = findAnyInterfaceProperty(keys: keys) {
            if let string = normalizeBSSID(string: value as? String) { return string }
            if let data = value as? Data, let string = normalizeBSSID(data: data) { return string }
        }
        return nil
    }

    private static func ssidValue(iface: String) -> String? {
        if let entry = interfaceEntry(iface: iface) {
            defer { IOObjectRelease(entry) }
            if let value = propertyOnEntryOrParents(entry: entry, keys: ["IO80211SSID_STR", "IO80211SSID", "SSID_STR"]) {
                if let string = normalizedSSID(from: value) { return string }
            }
        }
        if let value = findAnyInterfaceProperty(keys: ["IO80211SSID_STR", "IO80211SSID", "SSID_STR"]) {
            if let string = normalizedSSID(from: value) { return string }
        }
        return nil
    }

    private static func normalizedSSID(from any: Any) -> String? {
        if let string = any as? String, !string.isEmpty, string != "<SSID Redacted>" {
            return normalizeSSID(string)
        }
        if let data = any as? Data, !data.isEmpty, let string = String(data: data, encoding: .utf8), !string.isEmpty, string != "<SSID Redacted>" {
            return normalizeSSID(string)
        }
        return nil
    }

    private static func normalizeBSSID(string: String?) -> String? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        if raw == "00:00:00:00:00:00" { return nil }
        return raw
    }

    private static func normalizeBSSID(data: Data) -> String? {
        guard data.count >= 6 else { return nil }
        let bytes = [UInt8](data.prefix(6))
        let formatted = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        return normalizeBSSID(string: formatted)
    }

    private static func normalizeSSID(_ text: String) -> String {
        return text.replacingOccurrences(of: "’", with: "'")
                   .replacingOccurrences(of: "‘", with: "'")
                   .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func interfaceEntry(iface: String) -> io_registry_entry_t? {
        guard let match = IOServiceMatching("IOService") as NSMutableDictionary? else { return nil }
        match.setValue(["BSD Name": iface], forKey: "IOPropertyMatch")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(ioDefaultPort, match, &iterator)
        guard kr == KERN_SUCCESS, iterator != 0 else { return nil }
        let entry = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        return entry == 0 ? nil : entry
    }

    private static func propertyOnEntryOrParents(entry: io_registry_entry_t, keys: [String]) -> Any? {
        var current: io_registry_entry_t = entry
        var releaseCurrent = false
        while true {
            if let value = property(keys: keys, entry: current) {
                if releaseCurrent { IOObjectRelease(current) }
                return value
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if releaseCurrent { IOObjectRelease(current) }
            guard status == KERN_SUCCESS, parent != 0 else { return nil }
            current = parent
            releaseCurrent = true
        }
    }

    private static func property(keys: [String], entry: io_registry_entry_t) -> Any? {
        for key in keys {
            if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                return value
            }
        }
        return nil
    }

    private static func findAnyInterfaceProperty(keys: [String]) -> Any? {
        guard let matching = IOServiceMatching("IO80211Interface") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(ioDefaultPort, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            if let value = propertyOnEntryOrParents(entry: entry, keys: keys) {
                IOObjectRelease(entry)
                return value
            }
            IOObjectRelease(entry)
        }
        return nil
    }
}

/// Parses historical DHCP lease files as a secondary source for server
/// identifiers when SystemConfiguration no longer has the information cached.
private enum LeaseFileReader {
    static func lookupDHCPServer(interface: String) -> String? {
        let directory = "/var/db/dhcpclient/leases"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        for file in files where file.hasPrefix(interface) {
            let path = directory + "/" + file
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
                  let dict = plist as? [String: Any] else { continue }
            if let string = dict["ServerIdentifier"] as? String { return string }
            if let data = dict["ServerIdentifier"] as? Data, data.count == 4 { return ipv4String(from: data) }
            if let string = dict["server_identifier"] as? String { return string }
            if let data = dict["server_identifier"] as? Data, data.count == 4 { return ipv4String(from: data) }
        }
        return nil
    }
}

/// Optional live enrichment via CoreWLAN. All reads are safe (no scans) and the
/// resolver gracefully degrades when CoreWLAN is unavailable.
 #if canImport(CoreWLAN)
private enum CoreWLANReader {
    static func populate(into snapshot: inout WiFiSnapshot,
                         sources: inout FieldSources,
                         iface: String,
                         allowFallback: Bool,
                         expectedRouter: String?,
                         expectedDHCP: String?) {
        let client = CWWiFiClient.shared()
        let interface: CWInterface?
        if allowFallback {
            interface = client.interface(withName: iface) ?? client.interface()
        } else {
            interface = client.interface(withName: iface)
        }
        guard let cw = interface else { return }

        // Capture channel first so we can score profile BSSIDs against it.
        let expectedChannel: Int? = {
            if let ch = cw.wlanChannel()?.channelNumber { return Int(ch) }
            return nil
        }()

        if let ch = expectedChannel {
            assignIfEmpty(&snapshot.channel, key: "channel", value: ch, origin: .coreWLAN, sources: &sources)
        }

        // Live SSID/BSSID
        assignIfEmpty(&snapshot.ssid, key: "ssid", value: cw.ssid(), origin: .coreWLAN, sources: &sources)
        if let bssidRaw = cw.bssid()?.lowercased(), !bssidRaw.isEmpty, bssidRaw != "00:00:00:00:00:00" {
            assignIfEmpty(&snapshot.bssid, key: "bssid", value: bssidRaw, origin: .coreWLAN, sources: &sources)
        }

        // SSID from profiles when redacted
        if (snapshot.ssid == nil || snapshot.ssid?.isEmpty == true),
           let profileSSID = ssidFromProfiles(cw) {
            assignIfEmpty(&snapshot.ssid, key: "ssid", value: profileSSID, origin: .coreWLAN, sources: &sources)
        }

        // BSSID from profiles ranked by DHCP match → router signature → channel → recency
        if snapshot.bssid == nil,
           let profileBSSID = bssidFromProfiles(cw,
                                                expectedChannel: expectedChannel,
                                                expectedRouter: expectedRouter,
                                                expectedDHCP: expectedDHCP) {
            assignIfEmpty(&snapshot.bssid, key: "bssid", value: profileBSSID, origin: .coreWLAN, sources: &sources)
        }

        assignIfEmpty(&snapshot.rssi, key: "rssi", value: cw.rssiValue(), origin: .coreWLAN, sources: &sources)
        assignIfEmpty(&snapshot.noise, key: "noise", value: cw.noiseMeasurement(), origin: .coreWLAN, sources: &sources)
        assignIfEmpty(&snapshot.txRate, key: "txRate", value: cw.transmitRate(), origin: .coreWLAN, sources: &sources)
        if let country = cw.countryCode(), let normalized = normalizedCountryCode(country) {
            assignIfEmpty(&snapshot.countryCode, key: "countryCode", value: normalized, origin: .coreWLAN, sources: &sources)
        }
        if let security = securityString(for: cw) {
            assignIfEmpty(&snapshot.security, key: "security", value: security, origin: .coreWLAN, sources: &sources)
        }
        if let phy = phyString(for: cw) {
            assignIfEmpty(&snapshot.phy, key: "phy", value: phy, origin: .coreWLAN, sources: &sources)
        }
    }

    // Pull SSID from saved profiles (public API; no scanning). Useful when cw.ssid() is redacted.
    private static func ssidFromProfiles(_ cw: CWInterface) -> String? {
        guard let cfg = cw.configuration(),
              let set = (cfg.value(forKey: "networkProfiles") as? NSOrderedSet),
              let first = set.firstObject as? CWNetworkProfile,
              let raw = first.ssid, !raw.isEmpty else {
            return nil
        }
        // Normalize smart quotes and whitespace to match our other sources.
        return raw.replacingOccurrences(of: "’", with: "'")
                  .replacingOccurrences(of: "‘", with: "'")
                  .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Ranked BSSID selection from profile: DHCP match > router signature > channel > recency
    private static func bssidFromProfiles(_ cw: CWInterface,
                                          expectedChannel: Int?,
                                          expectedRouter: String?,
                                          expectedDHCP: String?) -> String? {
        guard let cfg = cw.configuration(),
              let set = (cfg.value(forKey: "networkProfiles") as? NSOrderedSet) else {
            return nil
        }

        // Filter to the profile matching the current SSID when available
        let targetSSID: String? = cw.ssid().flatMap { normalizeSSIDLocal($0) }
        let dhcpTarget: Data? = expectedDHCP.flatMap { ipv4Data(from: $0) }

        var bestBSSID: String? = nil
        var bestRank: Int = .min
        var bestDate: Date = .distantPast

        for case let profile as NSObject in set {
            if let t = targetSSID,
               let pSSID = (profile.value(forKey: "ssid") as? String).flatMap({ normalizeSSIDLocal($0) }),
               !pSSID.isEmpty, pSSID != t {
                continue
            }

            guard let list = profile.value(forKey: "bssidList") as? [[String: Any]] else { continue }
            for entry in list {
                guard let raw = (entry["BSSID"] as? String)?.lowercased(),
                      let bssid = normalizeBSSIDString(raw) else { continue }

                var rank = 0

                // 1) Exact DHCP server match (strongest signal)
                if let data = entry["DHCPServerID"] as? Data, let target = dhcpTarget, data == target {
                    rank += 300
                }

                // 2) Router signature match
                if rank < 300, let router = expectedRouter,
                   let sig = entry["IPv4NetworkSignature"] as? String,
                   sig.contains("IPv4.Router=\(router)") {
                    rank += 200
                }

                // 3) Channel match
                if let exp = expectedChannel {
                    if let n = entry["Channel"] as? NSNumber, n.intValue == exp { rank += 100 }
                    else if let n = entry["Channel"] as? Int, n == exp { rank += 100 }
                }

                // 4) Recency (prefer most recent association; accept multiple possible keys)
                let ts = dateFromBSSIDEntry(entry) ?? .distantPast

                if rank > bestRank || (rank == bestRank && ts > bestDate) {
                    bestRank = rank
                    bestDate = ts
                    bestBSSID = bssid
                }
            }
        }

        return bestBSSID
    }

    // Extract a useful timestamp from a BSS entry; different macOS versions use different keys
    @inline(__always)
    private static func dateFromBSSIDEntry(_ entry: [String: Any]) -> Date? {
        let keys = [
            "LastAssociatedAt",
            "lastAssociatedAt",
            "LastJoinedAt",
            "LastJoined",
            "LastSeen",
            "Timestamp",
            "AWDLRealTimeModeTimestamp"
        ]
        var best: Date? = nil
        for k in keys {
            if let d = entry[k] as? Date {
                if let cur = best {
                    if d > cur { best = d }
                } else {
                    best = d
                }
            }
        }
        return best
    }

    @inline(__always) private static func normalizeSSIDLocal(_ text: String) -> String {
        return text.replacingOccurrences(of: "’", with: "'")
                   .replacingOccurrences(of: "‘", with: "'")
                   .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @inline(__always) private static func normalizeBSSIDString(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s != "00:00:00:00:00:00" else { return nil }
        return s
    }

    private static func securityString(for interface: CWInterface) -> String? {
        if let selector = selector(on: interface, names: ["security", "securityType"]) {
            switch selector {
            case 0: return "Open"
            case 1: return "WEP"
            case 2: return "WPA-Personal"
            case 3: return "WPA/WPA2 Mixed"
            case 4: return "WPA2-Personal"
            case 10: return "WPA3-Personal"
            case 12: return "WPA2/WPA3"
            default: return nil
            }
        }
        return nil
    }

    private static func phyString(for interface: CWInterface) -> String? {
        if let selector = selector(on: interface, names: ["activePHYMode", "phyMode"]) {
            switch selector {
            case 1: return "802.11a"
            case 2: return "802.11b"
            case 3: return "802.11g"
            case 4: return "802.11n"
            case 5: return "802.11ac"
            case 6: return "802.11ax"
            default: return nil
            }
        }
        return nil
    }

    private static func selector(on object: NSObject, names: [String]) -> Int? {
        for name in names {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector) {
                let impl = object.method(for: selector)
                typealias Fn = @convention(c) (AnyObject, Selector) -> Int32
                let fn = unsafeBitCast(impl, to: Fn.self)
                return Int(fn(object, selector))
            }
        }
        return nil
    }
}
#endif

/// Handles access to `/Library/Preferences/com.apple.wifi.known-networks.plist`
/// and performs the inference heuristics used to recover SSID/BSSID/security
/// when live APIs refuse to disclose them.
private enum KnownNetworksStore {
    private static var cached: [String: Any]? = nil

    static func enrich(into snapshot: inout WiFiSnapshot, sources: inout FieldSources, env: EnvironmentInfo) {
        guard env.isWiFi else { return }
        // Origin-aware offline heuristic:
        // - Only treat SystemConfiguration DHCP as runtime (ignore lease-file/heuristic)
        // - Require a live CoreWLAN channel to consider the radio "active"
        let noRuntime = (env.routerIPv4 == nil) && (env.dhcpOrigin != .systemConfiguration)
        let channelIsLive = (sources["channel"] == FieldOrigin.coreWLAN.rawValue)
        if noRuntime && !channelIsLive {
            return
        }

        // Determine if we need KnownNetworks at all *before* touching disk.
        var needSSID = (snapshot.ssid == nil || snapshot.ssid?.isEmpty == true)
        var needBSSID = (!needSSID && snapshot.bssid == nil)
        var needSec = (!needSSID && (snapshot.security == nil || snapshot.phy == nil))

        // If CoreWLAN/IORegistry already filled everything, skip loading.
        if !(needSSID || needBSSID || needSec) { return }

        // Lazy load the known-networks store only when required.
        guard let store = load() else { return }

        // 1) SSID inference first; it unlocks BSSID/security inference.
        if needSSID, let inferred = inferSSID(store: store, env: env, currentChannel: snapshot.channel) {
            assignIfEmpty(&snapshot.ssid, key: "ssid", value: inferred.value, origin: .knownNetworks, sources: &sources)
            if snapshot.ssidLastSeen == nil { snapshot.ssidLastSeen = inferred.lastAssociated }
            needSSID = false
            needBSSID = (snapshot.bssid == nil)
            needSec = (snapshot.security == nil || snapshot.phy == nil)
        }

        // 2) BSSID inference (requires SSID).
        if needBSSID, let ssid = snapshot.ssid,
           let bssid = inferBSSID(store: store, ssid: ssid, env: env, channel: snapshot.channel) {
            assignIfEmpty(&snapshot.bssid, key: "bssid", value: bssid, origin: .knownNetworks, sources: &sources)
        }

        // 3) Security/PHY (requires SSID).
        if needSec, let ssid = snapshot.ssid, let sec = fetchSecurity(store: store, ssid: ssid) {
            if snapshot.security == nil, let s = sec.security {
                snapshot.security = s
                sources["security"] = FieldOrigin.knownNetworks.rawValue
            }
            if snapshot.phy == nil, let p = sec.phy {
                snapshot.phy = p
                sources["phy"] = FieldOrigin.knownNetworks.rawValue
            }
        }
    }

    private static func load() -> [String: Any]? {
        if let cached = cached { return cached }
        guard let data = secureRead() else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              let dict = plist as? [String: Any] else { return nil }
        cached = dict
        return dict
    }

    private static func secureRead() -> Data? {
        let path = "/Library/Preferences/com.apple.wifi.known-networks.plist"
        let O_CLOEXEC = Int32(0x01000000)
        let O_NOFOLLOW = Int32(0x00000100)
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { return nil }
        defer { close(fd) }
        var statBuffer = stat()
        if fstat(fd, &statBuffer) != 0 { return nil }
        if (statBuffer.st_mode & S_IFMT) != S_IFREG { return nil }
        if statBuffer.st_uid != 0 { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let readCount = read(fd, &buffer, buffer.count)
            if readCount == 0 { break }
            if readCount < 0 { return nil }
            data.append(buffer, count: readCount)
        }
        _ = setgid(getgid())
        _ = setuid(getuid())
        return data
    }

    private struct SSIDInference {
        let value: String
        let lastAssociated: Date?
        let score: Double
    }

    private static func inferSSID(store: [String: Any], env: EnvironmentInfo, currentChannel: Int?) -> SSIDInference? {
        var candidates: [SSIDInference] = []
        let targetDHCP = env.dhcpServerIPv4.flatMap { ipv4Data(from: $0) }
        let router = env.routerIPv4
        let epoch = Date(timeIntervalSince1970: 0)

        for (_, value) in store {
            guard let network = value as? [String: Any] else { continue }
            guard let rawSSID = extractSSID(from: network) else { continue }

            var baseScore: Double = 0.0
            var bestDate = epoch

            if let bssList = network["BSSList"] as? [[String: Any]] {
                for entry in bssList {
                    if let data = entry["DHCPServerID"] as? Data, let target = targetDHCP, data == target {
                        baseScore = max(baseScore, 0.85)
                        if let date = entry["LastAssociatedAt"] as? Date { bestDate = max(bestDate, date) }
                    }
                    if baseScore < 0.72,
                       let signature = entry["IPv4NetworkSignature"] as? String,
                       let router,
                       signature.contains("IPv4.Router=\(router)") {
                        baseScore = max(baseScore, 0.72)
                        if let date = entry["LastAssociatedAt"] as? Date { bestDate = max(bestDate, date) }
                    }
                    if baseScore > 0.0,
                       let channel = currentChannel,
                       let bssChannel = entry["Channel"] as? Int,
                       channel == bssChannel {
                        baseScore = min(baseScore + 0.05, 1.0)
                        if let date = entry["LastAssociatedAt"] as? Date { bestDate = max(bestDate, date) }
                    }
                }
            }

            if baseScore < 0.70,
               let router,
               let signature = network["IPv4NetworkSignature"] as? String,
               signature.contains("IPv4.Router=\(router)") {
                baseScore = max(baseScore, 0.70)
            }

            if baseScore > 0.0 {
                if bestDate == epoch, let updated = network["UpdatedAt"] as? Date {
                    bestDate = updated
                }
                let lastAssociated = (bestDate > epoch) ? bestDate : nil
                candidates.append(SSIDInference(value: rawSSID, lastAssociated: lastAssociated, score: baseScore))
            }
        }

        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            let lhsDate = lhs.lastAssociated ?? epoch
            let rhsDate = rhs.lastAssociated ?? epoch
            return lhsDate < rhsDate
        }
    }

    private static func entries(forSSID target: String, store: [String: Any]) -> [[String: Any]] {
        var matches: [[String: Any]] = []
        let normalizedTarget = normalizeSSID(target)
        let directKey = "wifi.network.ssid.\(target)"

        if let direct = store[directKey] as? [String: Any] {
            matches.append(direct)
        }

        for (key, value) in store {
            guard let dict = value as? [String: Any] else { continue }
            if key == directKey { continue }

            if let extracted = extractSSID(from: dict), extracted == normalizedTarget {
                matches.append(dict)
                continue
            }

            if key.hasPrefix("wifi.network.ssid.") {
                let suffix = String(key.dropFirst("wifi.network.ssid.".count))
                if normalizeSSID(suffix) == normalizedTarget {
                    matches.append(dict)
                }
            }
        }

        return matches
    }

    private static func inferBSSID(store: [String: Any], ssid: String, env: EnvironmentInfo, channel: Int?) -> String? {
        let entries = entries(forSSID: ssid, store: store)
        guard !entries.isEmpty else { return nil }
        let targetDHCP = env.dhcpServerIPv4.flatMap { ipv4Data(from: $0) }
        var candidates: [String: (rank: Int, time: Date)] = [:]

        for entry in entries {
            guard let list = entry["BSSList"] as? [[String: Any]] else { continue }
            for bss in list {
                guard let raw = (bss["BSSID"] as? String)?.lowercased(), !raw.isEmpty,
                      raw != "00:00:00:00:00:00" else { continue }
                var rank = 0
                if let id = bss["DHCPServerID"] as? Data, let target = targetDHCP, id == target {
                    rank = max(rank, 3)
                }
                if rank < 2, let router = env.routerIPv4, let signature = bss["IPv4NetworkSignature"] as? String, signature.contains("IPv4.Router=\(router)") {
                    rank = max(rank, 2)
                }
                if rank < 1, let channel = channel, let bssChannel = bss["Channel"] as? Int, channel == bssChannel {
                    rank = max(rank, 1)
                }
                let time = (bss["LastAssociatedAt"] as? Date) ?? Date(timeIntervalSince1970: 0)
                if let existing = candidates[raw] {
                    if rank > existing.rank || (rank == existing.rank && time > existing.time) {
                        candidates[raw] = (rank, time)
                    }
                } else {
                    candidates[raw] = (rank, time)
                }
            }
        }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.value.rank != rhs.value.rank { return lhs.value.rank > rhs.value.rank }
            return lhs.value.time > rhs.value.time
        }
        return sorted.first?.key
    }

    private struct SecurityInfo { let security: String?; let phy: String? }

    private static func fetchSecurity(store: [String: Any], ssid: String) -> SecurityInfo? {
        guard let entry = entry(forSSID: ssid, store: store) else { return nil }
        return security(from: entry)
    }

    private static func security(from dict: [String: Any]) -> SecurityInfo? {
        let security: String? = {
            if let string = dict["SupportedSecurityTypes"] as? String, !string.isEmpty { return string }
            if let osSpecific = dict["__OSSpecific__"] as? [String: Any], let string = osSpecific["SupportedSecurityTypes"] as? String, !string.isEmpty { return string }
            if let string = dict["Security"] as? String { return mapSecurityString(string) }
            if let number = dict["SecurityType"] as? NSNumber { return mapSecurityType(number.intValue) }
            return nil
        }()
        let phy = dict["PHY"] as? String
        if security == nil && phy == nil { return nil }
        return SecurityInfo(security: security, phy: phy)
    }

    private static func extractSSID(from dict: [String: Any]) -> String? {
        if let ssid = dict["SSID"] as? String, !ssid.isEmpty { return normalizeSSID(ssid) }
        if let data = dict["SSID"] as? Data, let ssid = String(data: data, encoding: .utf8), !ssid.isEmpty { return normalizeSSID(ssid) }
        return nil
    }

    /// Locate the known-network entry for a given SSID, normalizing quote variants
    /// so smart-quote keys still match the plain apostrophe values we emit.
    private static func entry(forSSID target: String, store: [String: Any]) -> [String: Any]? {
        let matches = entries(forSSID: target, store: store)
        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0] }

        func recencyScore(for dict: [String: Any]) -> Date {
            var best = Date(timeIntervalSince1970: 0)
            let topLevelKeys = ["UpdatedAt", "JoinedByUserAt", "LastDisconnectTimestamp", "LastDiscoveredAt", "AddedAt", "WasHiddenBefore"]
            for key in topLevelKeys {
                if let date = dict[key] as? Date { best = max(best, date) }
            }
            if let userPreferred = dict["UserPreferredNetworkNames"] as? [String: Date] {
                for (_, date) in userPreferred { best = max(best, date) }
            }
            if let list = dict["BSSList"] as? [[String: Any]] {
                for entry in list {
                    if let date = entry["LastAssociatedAt"] as? Date { best = max(best, date) }
                }
            }
            if let osSpecific = dict["__OSSpecific__"] as? [String: Any],
               let history = osSpecific["ChannelHistory"] as? [[String: Any]] {
                for item in history {
                    if let date = item["Timestamp"] as? Date { best = max(best, date) }
                }
            }
            return best
        }

        return matches.max { lhs, rhs in
            let lhsDate = recencyScore(for: lhs)
            let rhsDate = recencyScore(for: rhs)
            return lhsDate < rhsDate
        }
    }

    private static func mapSecurityString(_ string: String) -> String {
        let upper = string.uppercased()
        if upper.contains("WPA3") && upper.contains("WPA2") { return "WPA2/WPA3" }
        if upper.contains("WPA3") { return "WPA3-Personal" }
        if upper.contains("WPA2") && upper.contains("WPA") { return "WPA/WPA2 Mixed" }
        if upper.contains("WPA2") { return "WPA2-Personal" }
        if upper.contains("WPA") { return "WPA-Personal" }
        if upper.contains("WEP") { return "WEP" }
        if upper.contains("OPEN") || upper.contains("NONE") { return "Open" }
        return string
    }

    private static func mapSecurityType(_ value: Int) -> String? {
        switch value {
        case 0: return "Open"
        case 1: return "WEP"
        case 2: return "WPA-Personal"
        case 3: return "WPA2-Personal"
        case 4: return "WPA/WPA2 Mixed"
        case 6: return "WPA3-Personal"
        default: return nil
        }
    }

    private static func normalizeSSID(_ text: String) -> String {
        return text.replacingOccurrences(of: "’", with: "'")
                   .replacingOccurrences(of: "‘", with: "'")
                   .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Serialises the resolver result to deterministic JSON. `--detail` adds the
/// provenance metadata without altering field order guarantees.
private struct JSONEmitter {
    private enum ValueKind {
        case string
        case number
        case bool
        case null
        case other
    }

    static func emit(snapshot: WiFiSnapshot, sources: FieldSources?, handle: FileHandle = .standardOutput) {
        func encode<T: Encodable>(_ value: T) -> String {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(Box(value)), let string = String(data: data, encoding: .utf8) else { return "null" }
            return string
        }

        func kind(of value: Any) -> ValueKind {
            switch value {
            case is String: return .string
            case is Int, is Int8, is Int16, is Int32, is Int64,
                 is UInt, is UInt8, is UInt16, is UInt32, is UInt64,
                 is Float, is Double: return .number
            case is Bool: return .bool
            default: return .other
            }
        }

        var items: [(String, String, ValueKind)] = []
        let stateEncoded = encode(snapshot.state ?? "unknown")
        items.append(("state", stateEncoded, .string))

        let ifaceEncoded = encode(snapshot.iface)
        items.append(("iface", ifaceEncoded, .string))
        if let sources = sources, let origin = sources["iface"] {
            items.append(("ifaceSource", encode(origin), .string))
        }

        func add<T: Encodable>(_ key: String, value: T?) {
            guard let value = value else { return }
            let encoded = encode(value)
            let valueKind = (encoded == "null") ? .null : kind(of: value)
            items.append((key, encoded, valueKind))
            if let sources = sources, let origin = sources[key] {
                items.append((key + "Source", encode(origin), .string))
            }
        }

        add("band", value: snapshot.band)
        add("bssid", value: snapshot.bssid)
        add("channel", value: snapshot.channel)
        add("countryCode", value: snapshot.countryCode)
        add("dhcpServerIPv4", value: snapshot.dhcpServerIPv4)
        add("dhcpSource", value: snapshot.dhcpSource)
        add("noise", value: snapshot.noise)
        add("phy", value: snapshot.phy)
        add("routerIPv4", value: snapshot.routerIPv4)
        add("rssi", value: snapshot.rssi)
        add("security", value: snapshot.security)
        add("serviceID", value: snapshot.serviceID)
        add("snr", value: snapshot.snr)
        add("ssid", value: snapshot.ssid)
        add("txRate", value: snapshot.txRate)

        let prefixCount = (sources == nil) ? 2 : 3
        let head = items.prefix(prefixCount)
        var tail = Array(items.dropFirst(prefixCount))
        tail.sort { $0.0 < $1.0 }

        let ordered = Array(head) + tail
        let lines = ordered.map { key, encoded, kind -> String in
            let keyLiteral = "\"\(key)\""
            let coloredKey = JSONColor.key(keyLiteral)
            let coloredValue: String
            switch kind {
            case .string:
                coloredValue = JSONColor.string(encoded)
            case .number:
                coloredValue = JSONColor.number(encoded)
            case .bool:
                coloredValue = JSONColor.bool(encoded)
            case .null:
                coloredValue = JSONColor.null(encoded)
            case .other:
                coloredValue = JSONColor.other(encoded)
            }
            return "  \(coloredKey) : \(coloredValue)"
        }

        handle.write(Data("{\n".utf8))
        handle.write(Data(lines.joined(separator: ",\n").utf8))
        handle.write(Data("\n}\n".utf8))
    }

    private struct Box<T: Encodable>: Encodable {
        let value: T
        init(_ value: T) { self.value = value }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }
}

private struct JSONColor {
    private static var enabled: Bool {
        return getenv("NO_COLOR") == nil && isTerminal(STDOUT_FILENO)
    }

    @inline(__always) private static func wrap(_ text: String, code: String) -> String {
        guard enabled else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    static func key(_ text: String) -> String { wrap(text, code: "34;1") }      // bold blue
    static func string(_ text: String) -> String { wrap(text, code: "32") }     // green
    static func number(_ text: String) -> String { wrap(text, code: "35") }     // magenta
    static func bool(_ text: String) -> String { wrap(text, code: "33") }       // yellow
    static func null(_ text: String) -> String { wrap(text, code: "31") }       // red
    static func other(_ text: String) -> String { wrap(text, code: "36") }      // cyan
}

/// Builds the human-readable diagnostics banner printed in `-v` mode so users
/// can understand how interface selection and data fusion were performed.
private func activeInterfaceSummaryLine() -> String? {
    guard let store = SCDynamicStoreCreate(kCFAllocatorDefault, "airportx-diag" as CFString, nil, nil) else { return nil }

    var ptr: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ptr) == 0, let head = ptr else { return nil }
    defer { freeifaddrs(ptr) }

    struct Item { let name: String }
    var seen: Set<String> = []
    var items: [Item] = []

    var current = head
    while true {
        let entry = current.pointee
        if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
            let flags = UInt32(entry.ifa_flags)
            if (flags & UInt32(IFF_UP)) != 0 && (flags & UInt32(IFF_LOOPBACK)) == 0 {
                let name = String(cString: entry.ifa_name)
                if !name.isEmpty && seen.insert(name).inserted {
                    items.append(Item(name: name))
                }
            }
        }
        if let next = entry.ifa_next {
            current = next
        } else {
            break
        }
    }

    if items.isEmpty { return nil }

    var interfaceToService: [String: String] = [:]
    let servicePattern = "State:/Network/Service/.*/IPv4" as CFString
    if let keys = SCDynamicStoreCopyKeyList(store, servicePattern) as? [String] {
        for key in keys {
            guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let iface = dict["InterfaceName"] as? String else { continue }
            if interfaceToService[iface] != nil { continue }
            if let range1 = key.range(of: "Service/"), let range2 = key.range(of: "/IPv4"), range1.upperBound < range2.lowerBound {
                let sid = String(key[range1.upperBound..<range2.lowerBound])
                interfaceToService[iface] = sid
            }
        }
    }

    var servicePriority: [String: Int] = [:]
    if let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
       let order = setup["ServiceOrder"] as? [String] {
        for (index, sid) in order.enumerated() {
            servicePriority[sid] = index
        }
    }

    func priority(for name: String) -> Int {
        if EnvironmentReader.isTunnel(name) { return -100 }
        if let sid = interfaceToService[name], let index = servicePriority[sid] { return index }
        return Int.max - 100
    }

    items.sort {
        let lhsPriority = priority(for: $0.name)
        let rhsPriority = priority(for: $1.name)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return $0.name < $1.name
    }

    let parts = items.map { item -> String in
        let label = EnvironmentReader.classification(for: item.name, store: store)
        let coloredName = Ansi.cyan(item.name)
        let lower = label.lowercased()
        let coloredLabel: String
        switch lower {
        case "wi-fi":
            coloredLabel = Ansi.green(label)
        case "wired":
            coloredLabel = Ansi.yellow(label)
        case "vpn":
            coloredLabel = Ansi.magenta(label)
        case "bluetooth":
            coloredLabel = Ansi.magenta(label)
        case "firewire":
            coloredLabel = Ansi.yellow(label)
        case "bridge":
            coloredLabel = Ansi.dim(label)
        default:
            coloredLabel = Ansi.dim(label)
        }
        return "\(coloredName)[\(coloredLabel)]"
    }

    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

private func verboseReport(snapshot: WiFiSnapshot, preferIface: String, strict: Bool) -> String {
    var lines: [String] = []
    let summary = activeInterfaceSummaryLine()
    lines.append(Ansi.bold("airportx diagnostics"))
    if let summary = summary {
        lines.append("Network interfaces: \(summary)")
    }
    let iface = snapshot.iface.isEmpty ? "-" : snapshot.iface
    lines.append("iface=\(Ansi.cyan(iface))  serviceID=\(snapshot.serviceID ?? "-")")
    let router = snapshot.routerIPv4 ?? "-"
    let dhcp = snapshot.dhcpServerIPv4 ?? "-"
    let dhcpSrc = snapshot.dhcpSource.map { " (\($0))" } ?? ""
    lines.append("router=\(Ansi.cyan(router))  dhcp=\(Ansi.cyan(dhcp))\(dhcpSrc)")
    let ssid = snapshot.ssid ?? "Unknown (not associated)"
    let bssid = snapshot.bssid ?? "-"
    let channel = snapshot.channel.map(String.init) ?? "-"
    let band = snapshot.band ?? "-"
    let country = snapshot.countryCode ?? "-"
    let security = snapshot.security ?? "-"
    lines.append("ssid=\(Ansi.green(ssid))  bssid=\(Ansi.cyan(bssid))  channel=\(Ansi.cyan(channel))  band=\(Ansi.cyan(band))  country=\(Ansi.cyan(country))  security=\(Ansi.cyan(security))")
    if let rssi = snapshot.rssi, let noise = snapshot.noise {
        var liveLine = "rssi=\(Ansi.cyan(String(rssi))) dBm  noise=\(Ansi.cyan(String(noise))) dBm"
        if let snr = snapshot.snr { liveLine += "  snr=\(Ansi.cyan(String(snr))) dB" }
        if let rate = snapshot.txRate {
            liveLine += "  txRate=\(Ansi.cyan(String(format: "%.1f", rate))) Mbps"
        }
        lines.append(liveLine)
    }
    lines.append(strict ? "mode=strict" : "mode=auto (prefer active Wi-Fi)")
    return lines.joined(separator: "\n")
}

/// Strongly-typed representation of command line options after parsing.
private struct CLIOptions {
    enum Mode { case run, help, version }
    var mode: Mode = .run
    var interface: String = "en0"
    var explicitInterface: Bool = false
    var verbose: Bool = false
    var json: Bool = false
    var detail: Bool = false
    var ssidOnly: Bool = false
    var bssidOnly: Bool = false
    var stateOnly: Bool = false
    var live: Bool = true
}

/// Basic command-line parser that honours GNU-style long options while keeping
/// argument handling predictable for shell usage.
private func parseCLI() -> CLIOptions {
    var options = CLIOptions()
    let args = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-h", "--help":
            options.mode = .help
        case "-V", "--version":
            options.mode = .version
        case "-v", "--verbose":
            options.verbose = true
        case "--json":
            options.json = true
        case "--detail":
            options.detail = true
        case "--ssid":
            options.ssidOnly = true
        case "--bssid":
            options.bssidOnly = true
        case "--state":
            options.stateOnly = true
        case "--no-live":
            options.live = false
        case "--no-color":
            setenv("NO_COLOR", "1", 1)
        case "--":
            let rest = args.dropFirst(index + 1)
            if let next = rest.first {
                if options.explicitInterface { fail("too many positional arguments") }
                options.interface = next
                options.explicitInterface = true
            }
            if rest.count > 1 { fail("too many positional arguments") }
            index = args.count
            continue
        default:
            if arg.hasPrefix("-") {
                fail("unknown option: \(arg)")
            }
            if options.explicitInterface {
                fail("too many positional arguments")
            }
            options.interface = arg
            options.explicitInterface = true
        }
        index += 1
    }
    return options
}

/// Emit a usage error and terminate with exit code 2.
private func fail(_ message: String) -> Never {
    fputs("error: \(message)\ntry 'airportx --help'\n", stderr)
    exit(2)
}

@inline(__always) private func interfaceExists(_ name: String) -> Bool {
    var ptr: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ptr) == 0, let head = ptr else { return false }
    defer { freeifaddrs(ptr) }
    var current = head
    while true {
        let ifaceName = String(cString: current.pointee.ifa_name)
        if ifaceName == name { return true }
        if let next = current.pointee.ifa_next {
            current = next
        } else {
            break
        }
    }
    return false
}

@main
/// Command-line entry point for airportx. Dispatches to the resolver, manages
/// output format, and implements interface selection error handling.
struct AirportXCLI {
    private static let version = "0.0.2"

    static func main() {
        let options = parseCLI()
        switch options.mode {
        case .help:
            printHelp()
        case .version:
            print("airportx \(version)")
        case .run:
            if options.explicitInterface && !interfaceExists(options.interface) {
                fputs("error: interface '\(options.interface)' not found\n", stderr)
                exit(3)
            }

            let (snapshot, sources) = WiFiResolver.collect(preferredInterface: options.interface,
                                                           strict: options.explicitInterface,
                                                           liveCoreWLAN: options.live)
            if options.verbose {
                fputs(verboseReport(snapshot: snapshot,
                                 preferIface: options.interface,
                                 strict: options.explicitInterface) + "\n", stderr)
            }

            if options.json {
                // JSON always as an object with state + optional fields
                JSONEmitter.emit(snapshot: snapshot, sources: options.detail ? sources : nil)
            } else if options.stateOnly {
                // Explicit state-only output
                print(snapshot.state ?? "unassociated")
            } else if options.ssidOnly || options.bssidOnly {
                // Value-only modes: always surface state; only print SSID/BSSID when associatedOnline
                let state = snapshot.state ?? "unassociated"
                print("STATE=\(state)")
                if state == "associatedOnline" {
                    if options.ssidOnly, let ssid = snapshot.ssid {
                        print("SSID=\(ssid)")
                    }
                    if options.bssidOnly, let bssid = snapshot.bssid {
                        print("BSSID=\(bssid)")
                    }
                }
            } else {
                // Default human-readable: Always print STATE=..., and only print SSID when associatedOnline
                let state = snapshot.state ?? "unassociated"
                print("STATE=\(state)")
                if state == "associatedOnline" {
                    if let ssid = snapshot.ssid {
                        print("SSID=\(ssid)")
                    }
                }
            }
        }
    }

    private static func printHelp() {
        let text = [
            "airportx — Wi-Fi info without Location permission",
            "",
            "USAGE:",
            "  airportx [options] [iface]",
            "",
            "OPTIONS:",
            "  -h, --help         Show this help and exit",
            "  -V, --version      Show version and exit",
            "  -v, --verbose      Print selection diagnostics to stderr",
            "  --json             Emit JSON (iface first; rest alphabetical)",
            "  --detail           With --json, also emit <key>Source fields",
            "  --ssid             Print only the SSID",
            "  --bssid            Print only the BSSID",
            "  --state            Print only the consolidated state (powerOff/unassociated/associatedNoRuntime/associatedOnline)",
            "  --no-live          Disable CoreWLAN enrichment",
            "  --no-color         Disable ANSI colors in verbose output",
            "",
            "ARGS:",
            "  iface              BSD interface name (default: en0)",
            "",
            "EXIT CODES:",
            "  0  success (including Unknown (not associated))",
            "  2  usage error",
            "  3  interface not found (when iface explicitly provided)"
        ].joined(separator: "\n")
        print(text)
    }
}
