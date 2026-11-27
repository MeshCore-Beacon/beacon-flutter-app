import XCTest

/// The same cases as test/core/push_notice_test.dart, from the same fixture,
/// so the Swift and Dart sentences cannot drift apart.
final class BeaconPushTests: XCTestCase {
  private var fixture: [String: Any] = [:]

  override func setUpWithError() throws {
    // Bundled into RunnerTests; read from the checkout when built outside Xcode.
    let url =
      Bundle(for: Self.self).url(forResource: "push_notice", withExtension: "json")
      ?? URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("test/fixtures/push_notice.json")
    let data = try Data(contentsOf: url)
    fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testEverySentenceMatchesTheServer() throws {
    let cases = try XCTUnwrap(fixture["sentences"] as? [[String: Any]])
    XCTAssertGreaterThan(cases.count, 50)
    for c in cases {
      var json = c
      json["targetKind"] = "node"
      json["publicKey"] = "aa"
      let notice = try XCTUnwrap(BeaconPush.Notice(json: json))
      XCTAssertEqual(BeaconPush.sentence(notice), c["want"] as? String, "\(c)")
    }
  }

  func testUnknownKindHasNoSentence() throws {
    let notice = try XCTUnwrap(BeaconPush.Notice(json: ["kind": "future_kind", "name": "N"]))
    XCTAssertNil(BeaconPush.sentence(notice))
  }

  func testNamesAreCappedAndCleaned() {
    let long = String(repeating: "é", count: 45) + "🛰️"
    XCTAssertEqual(BeaconPush.capName(long), String(repeating: "é", count: 40))
    XCTAssertEqual(BeaconPush.capName("Hill\ntop\u{202E}"), "Hill top")
    XCTAssertEqual(BeaconPush.capName("  a \t  b  "), "a b")
  }

  func testSealedVectorsOpen() throws {
    let sealed = try XCTUnwrap(fixture["sealed"] as? [[String: Any]])
    for s in sealed {
      let key = try XCTUnwrap(Data(base64Encoded: s["key"] as! String))
      let pushId = s["pushId"] as! String
      let ct = s["ct"] as! String
      let notice = try XCTUnwrap(BeaconPush.open(key: key, pushId: pushId, ct: ct))
      XCTAssertEqual(BeaconPush.sentence(notice), s["want"] as? String)
      XCTAssertNil(BeaconPush.open(key: key, pushId: "inst_other", ct: ct))
      var wrong = key
      wrong[0] ^= 1
      XCTAssertNil(BeaconPush.open(key: wrong, pushId: pushId, ct: ct))
    }
    XCTAssertNil(BeaconPush.open(key: Data(count: 32), pushId: "p", ct: "not base64!"))
    XCTAssertNil(BeaconPush.open(key: Data(count: 2), pushId: "p", ct: "AAAA"))
  }

  func testRenderUsesTheStoredNameAndFallsBack() throws {
    let s = try XCTUnwrap((fixture["sealed"] as? [[String: Any]])?.first)
    let key = try XCTUnwrap(Data(base64Encoded: s["key"] as! String))
    let info: [AnyHashable: Any] = [
      "v": "1", "pushId": s["pushId"]!, "serverName": "Ottawa Mesh", "messageId": "m_1", "ct": s["ct"]!,
    ]
    let shown = try XCTUnwrap(
      BeaconPush.render(userInfo: info) { _ in .init(key: key, name: "My Ottawa") })
    XCTAssertEqual(shown.title, "My Ottawa")
    XCTAssertEqual(shown.body, s["want"] as? String)
    let unnamed = BeaconPush.render(userInfo: info) { _ in .init(key: key, name: "") }
    XCTAssertEqual(unnamed?.title, "Ottawa Mesh")
    XCTAssertNil(BeaconPush.render(userInfo: info) { _ in nil })
    XCTAssertNil(
      BeaconPush.render(userInfo: info) { _ in .init(key: Data(count: 32), name: "x") })
    XCTAssertEqual(BeaconPush.neutral(userInfo: info).body, "New alert from Ottawa Mesh")
    XCTAssertEqual(BeaconPush.neutral(userInfo: [:]).title, "BEACON")
  }
}
