import UserNotifications

/// Replaces the push server's placeholder with the alert this phone decrypts.
class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var content: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    let info = request.content.userInfo
    // Neutral first, so running out of time never shows the placeholder.
    let neutral = BeaconPush.neutral(userInfo: info)
    content.title = neutral.title
    content.body = neutral.body
    self.contentHandler = contentHandler
    self.content = content
    if let shown = BeaconPush.render(userInfo: info) {
      content.title = shown.title
      content.body = shown.body
    }
    contentHandler(content)
    self.contentHandler = nil
  }

  override func serviceExtensionTimeWillExpire() {
    if let handler = contentHandler, let content = content { handler(content) }
    contentHandler = nil
  }
}
