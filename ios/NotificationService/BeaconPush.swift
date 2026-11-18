import CryptoKit
import Foundation
import Security

/// Opens and words Beacon push notices, the same way as lib/core/push_notice.dart.
enum BeaconPush {
  static let aadPrefix = "beacon-push/v1:"
  static let keychainService = "beacon.push"
  static let maxName = 40

  struct Notice {
    var kind = "", name = "", detail = "", targetKind = "", publicKey = "", id = ""
    var value: Int64?
    var tempUnit = "c"

    init?(json: Any?) {
      guard let map = json as? [String: Any] else { return nil }
      func text(_ key: String) -> String { map[key] as? String ?? "" }
      kind = text("kind")
      if kind.isEmpty { return nil }
      name = text("name")
      detail = text("detail")
      targetKind = text("targetKind")
      publicKey = text("publicKey")
      id = text("id")
      tempUnit = text("tempUnit") == "f" ? "f" : "c"
      // `is Bool` is true for any NSNumber 0 or 1, so ask CoreFoundation instead.
      if let number = map["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        value = number.int64Value
      }
    }
  }

  /// One stored registration, as the app writes it to the shared keychain group.
  struct Entry {
    let key: Data
    let name: String
  }

  // Go's unicode.IsSpace, so the server, the app and this extension agree.
  private static let spaces: Set<UInt32> = [
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003,
    0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
    0x3000,
  ]

  /// A name as a notification may show it: one line, no hidden characters, capped.
  static func capName(_ name: String) -> String {
    var out = String.UnicodeScalarView()
    var lastSpace = true
    for scalar in name.unicodeScalars {
      if spaces.contains(scalar.value) {
        if !lastSpace { out.append(" ") }
        lastSpace = true
        continue
      }
      let category = scalar.properties.generalCategory
      if category == .control || category == .format || scalar.value == 0xFFFD { continue }
      out.append(scalar)
      lastSpace = false
    }
    var scalars = Array(String(out).trimmingCharacters(in: [" "]).unicodeScalars)
    if scalars.count > maxName { scalars = Array(scalars.prefix(maxName)) }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view).trimmingCharacters(in: [" "])
  }

  private static func plural(_ n: Int64, _ unit: String) -> String {
    n == 1 ? "1 \(unit)" : "\(n) \(unit)s"
  }

  private static func duration(_ seconds: Int64) -> String {
    if seconds >= 86400 { return plural(seconds / 86400, "day") }
    if seconds >= 3600 { return plural(seconds / 3600, "hour") }
    return plural(seconds / 60, "minute")
  }

  // Only numbers go through a format string, never the name.
  private static func fixed(_ value: Double, _ places: Int) -> String {
    String(format: "%.\(places)f", value)
  }

  /// beacon-server's alerts.Sentence word for word; nil for a kind it does not know.
  static func sentence(_ n: Notice) -> String? {
    let name = capName(n.name)
    let v = n.value ?? 0
    switch n.kind {
    case "gone_quiet": return "\(name) has not been heard for \(plural(v, "hour"))."
    case "back_online": return "\(name) is back online."
    case "battery_low": return "\(name) battery is low: \(fixed(Double(v) / 1000, 2)) V."
    case "battery_falling":
      return "\(name) battery is falling by about \(fixed(Double(v) / 1000, 2)) V a day."
    case "rebooted": return "\(name) rebooted."
    case "temperature":
      if n.tempUnit == "f" {
        let f = Double(v) / 10 * 9 / 5 + 32
        return "\(name) temperature is \(fixed(f, 1)) F, outside your limits."
      }
      return "\(name) temperature is \(fixed(Double(v) / 10, 1)) C, outside your limits."
    case "noise_high": return "\(name) noise floor is high: \(v) dBm."
    case "clock": return "\(name) clock is off by \(duration(v))."
    case "observer_offline": return "\(name) has not reported for \(plural(v, "minute"))."
    case "request_attention":
      switch n.detail {
      case "login_failed":
        return "Telemetry request for \(name): the repeater did not accept the guest password."
      case "admin_stopped":
        return "Telemetry request for \(name): the password gave admin access and was deleted. Enter a guest password."
      case "disabled":
        return "Telemetry request for \(name) was turned off: no observer has heard the repeater for days."
      default:
        return "Telemetry request for \(name) needs your attention."
      }
    default: return nil
    }
  }

  /// Opens `ct` (base64 of nonce(12) || ciphertext || tag(16)); nil for anything else.
  static func open(key: Data, pushId: String, ct: String) -> Notice? {
    guard key.count == 32, let bytes = Data(base64Encoded: ct), bytes.count >= 28 else { return nil }
    do {
      let box = try AES.GCM.SealedBox(combined: bytes)
      let plain = try AES.GCM.open(
        box, using: SymmetricKey(data: key), authenticating: Data((aadPrefix + pushId).utf8))
      return Notice(json: try JSONSerialization.jsonObject(with: plain))
    } catch {
      return nil
    }
  }

  /// The entry the app stored for this Push ID (lib/core/push_store.dart).
  static func entry(pushId: String) -> Entry? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: keychainService,
      kSecAttrAccount: "beacon.push.\(pushId)",
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let key = (json["key"] as? String).flatMap({ Data(base64Encoded: $0) })
    else { return nil }
    return Entry(key: key, name: json["name"] as? String ?? "")
  }

  /// Title and body for one push, or nil when it does not open to a known kind.
  static func render(
    userInfo: [AnyHashable: Any], lookup: (String) -> Entry? = entry(pushId:)
  ) -> (title: String, body: String)? {
    guard userInfo["v"] as? String == "1",
      let pushId = userInfo["pushId"] as? String, !pushId.isEmpty,
      let ct = userInfo["ct"] as? String,
      let entry = lookup(pushId),
      let notice = open(key: entry.key, pushId: pushId, ct: ct),
      let body = sentence(notice)
    else { return nil }
    var title = capName(entry.name)
    if title.isEmpty { title = capName(userInfo["serverName"] as? String ?? "") }
    if title.isEmpty { title = "BEACON" }
    return (title, body)
  }

  /// What shows when a push cannot be opened: never the relay's placeholder.
  static func neutral(userInfo: [AnyHashable: Any]) -> (title: String, body: String) {
    let server = capName(userInfo["serverName"] as? String ?? "")
    let title = server.isEmpty ? "BEACON" : server
    return (title, "New alert from \(title)")
  }
}
