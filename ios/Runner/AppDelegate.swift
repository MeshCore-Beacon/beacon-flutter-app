import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Set before launch ends so the tap that launched the app is not missed.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    PushChannel.shared.attach(engineBridge.applicationRegistrar.messenger())
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    PushChannel.shared.registered(deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    PushChannel.shared.failed(error)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard PushChannel.isAlert(notification.request.content.userInfo) else {
      return super.userNotificationCenter(
        center, willPresent: notification, withCompletionHandler: completionHandler)
    }
    // The extension already rewrote the alert; show it in the foreground too.
    completionHandler([.banner, .list, .sound])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    guard PushChannel.isAlert(info) else {
      return super.userNotificationCenter(
        center, didReceive: response, withCompletionHandler: completionHandler)
    }
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      PushChannel.shared.tapped(info)
    }
    completionHandler()
  }
}

/// The `beacon/push` channel: APNs permission, device token and alert taps.
final class PushChannel {
  static let shared = PushChannel()

  private var channel: FlutterMethodChannel?
  private var waiting: [FlutterResult] = []
  private var token: String?
  // Taps wait here until Dart asks for the launch tap.
  private var launchTap: [String: Any]?
  private var dartReady = false
  // Bumped whenever the waiting results are answered, so a stale timeout does nothing.
  private var registration = 0
  private static let lastTokenKey = "beacon.push.apnsToken"

  /// A notice from a Beacon push server, as opposed to a local notification.
  static func isAlert(_ info: [AnyHashable: Any]) -> Bool {
    (info["pushId"] as? String).map { !$0.isEmpty } ?? false
  }

  func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "beacon/push", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "permission":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        DispatchQueue.main.async { result(Self.permission(settings.authorizationStatus)) }
      }
    case "requestPermission":
      let center = UNUserNotificationCenter.current()
      center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
        center.getNotificationSettings { settings in
          DispatchQueue.main.async { result(Self.permission(settings.authorizationStatus)) }
        }
      }
    case "token":
      if let token = token { return result(token) }
      waiting.append(result)
      // One registration at a time; later callers share its answer.
      guard waiting.count == 1 else { return }
      UIApplication.shared.registerForRemoteNotifications()
      let round = registration
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        guard let self = self, self.registration == round else { return }
        self.answerWaiting(nil)
      }
    case "initialMessage":
      dartReady = true
      result(launchTap)
      launchTap = nil
    case "apnsEnvironment":
      result(Self.apnsEnvironment())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func permission(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized, .provisional, .ephemeral: return "granted"
    case .denied: return "denied"
    default: return "notAsked"
    }
  }

  func registered(_ deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    token = hex
    answerWaiting(hex)
    // Like FCM's refresh: only a token that differs from the last one known.
    let defaults = UserDefaults.standard
    let last = defaults.string(forKey: Self.lastTokenKey)
    defaults.set(hex, forKey: Self.lastTokenKey)
    if let last = last, last != hex { channel?.invokeMethod("onToken", arguments: hex) }
  }

  func failed(_ error: Error) {
    answerWaiting(
      FlutterError(code: "register_failed", message: error.localizedDescription, details: nil))
  }

  /// Answers every waiting token request exactly once.
  private func answerWaiting(_ answer: Any?) {
    registration += 1
    let results = waiting
    waiting = []
    results.forEach { $0(answer) }
  }

  func tapped(_ info: [AnyHashable: Any]) {
    var data: [String: Any] = [:]
    for (key, value) in info {
      if let key = key as? String, key != "aps" { data[key] = value }
    }
    if dartReady, let channel = channel {
      channel.invokeMethod("onOpened", arguments: data)
    } else {
      launchTap = data
    }
  }

  /// sandbox or production, from the provisioning profile the build was signed with.
  static func apnsEnvironment() -> String {
    // The simulator has no profile and gets its pushes from the sandbox.
    #if targetEnvironment(simulator)
      return "sandbox"
    #else
      return profileEnvironment()
    #endif
  }

  private static func profileEnvironment() -> String {
    // App Store builds carry no profile and always use production.
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url)
    else { return "production" }
    var fallback = "production"
    #if DEBUG
      fallback = "sandbox"
    #endif
    // The profile is a signed CMS blob with the plist inside.
    guard let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
      let plist = try? PropertyListSerialization.propertyList(
        from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil)
        as? [String: Any],
      let entitlements = plist["Entitlements"] as? [String: Any],
      let env = entitlements["aps-environment"] as? String
    else { return fallback }
    return env == "development" ? "sandbox" : "production"
  }
}
