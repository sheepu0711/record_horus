import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      RecordingControl.shared.handle(url: context.url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let otherURLs = Set(URLContexts.filter { $0.url.scheme != "recordhorus" })
    if !otherURLs.isEmpty { super.scene(scene, openURLContexts: otherURLs) }
    for context in URLContexts where context.url.scheme == "recordhorus" {
      RecordingControl.shared.handle(url: context.url)
    }
  }
}
