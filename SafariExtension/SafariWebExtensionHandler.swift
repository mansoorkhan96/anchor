import Foundation

/// Safari requires a native handler in every web extension. Drift's extension talks to the app over the
/// local bridge instead of native messaging, so this only acknowledges requests.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: [], completionHandler: nil)
    }
}
