import ActivityKit
import Flutter
import UIKit

enum RecordingControlError: Error {
  case unavailable
  case failed
}

@MainActor
final class RecordingControl {
  static let shared = RecordingControl()
  private var channel: FlutterMethodChannel?
  private var ready = false
  private var pendingURL: URL?
  private var recordingId: String?
  private var activity: Any?
  private var elapsed: TimeInterval = 0
  private var runningSince = Date()
  private var paused = false
  private var actionInFlight = false

  func configure(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.example.record_horus/recording_control", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "ready":
        self.ready = true
        result(nil)
        if let url = self.pendingURL {
          self.pendingURL = nil
          self.handle(url: url)
        }
      case "update":
        let args = call.arguments as? [String: Any] ?? [:]
        Task { @MainActor in
          do {
            let enabled = try await self.update(
              id: args["recordingId"] as? String,
              label: args["label"] as? String ?? "Chung",
              paused: args["paused"] as? Bool ?? false)
            result(enabled)
          } catch {
            result(FlutterError(code: "live_activity", message: error.localizedDescription, details: nil))
          }
        }
      case "stop":
        Task { @MainActor in
          await self.end()
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func update(id: String?, label: String, paused nextPaused: Bool) async throws -> Bool {
    guard let id = id else { return false }
    guard #available(iOS 16.2, *) else { return false }
    if recordingId != id {
      await end()
      recordingId = id
      elapsed = 0
      runningSince = Date()
      paused = false
    }
    let now = Date()
    if !paused { elapsed += now.timeIntervalSince(runningSince) }
    runningSince = now
    paused = nextPaused
    let state = RecordingActivityAttributes.ContentState(
      paused: paused, elapsed: elapsed, runningSince: runningSince)
    if let current = activity as? Activity<RecordingActivityAttributes> {
      await current.update(ActivityContent(state: state, staleDate: nil))
      return true
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
    activity = try Activity.request(
      attributes: RecordingActivityAttributes(recordingId: id, label: label),
      content: ActivityContent(state: state, staleDate: nil), pushType: nil)
    return true
  }

  private func end() async {
    if #available(iOS 16.2, *) {
      // Remove stale activities too, for example after the OS terminated the app.
      for current in Activity<RecordingActivityAttributes>.activities {
        await current.end(nil, dismissalPolicy: .immediate)
      }
    }
    activity = nil
    recordingId = nil
  }

  func handle(url: URL) {
    guard url.scheme == "recordhorus", url.host == "recording" else { return }
    guard ready else {
      pendingURL = url
      return
    }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let action = items.first(where: { $0.name == "action" })?.value,
          let id = items.first(where: { $0.name == "id" })?.value else { return }
    Task { @MainActor in
      try? await perform(action: action, recordingId: id)
    }
  }

  func perform(action: String, recordingId id: String) async throws {
    guard ready, let channel = channel, recordingId == id, !actionInFlight,
          ["pause", "resume", "stop", "cancel"].contains(action) else {
      throw RecordingControlError.unavailable
    }
    actionInFlight = true
    defer { actionInFlight = false }

    // Pausing/stopping removes the audio background execution allowance.
    // Keep the app alive while Dart saves the recording locally.
    var taskId = UIBackgroundTaskIdentifier.invalid
    var completion: CheckedContinuation<Void, Error>?
    var timeout: DispatchWorkItem?
    func finish(_ error: Error?) {
      guard let waiting = completion else { return }
      completion = nil
      timeout?.cancel()
      if taskId != .invalid {
        UIApplication.shared.endBackgroundTask(taskId)
        taskId = .invalid
      }
      if let error = error { waiting.resume(throwing: error) }
      else { waiting.resume() }
    }
    try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, Error>) in
      completion = waiting
      taskId = UIApplication.shared.beginBackgroundTask(withName: "Recording action") {
        finish(RecordingControlError.failed)
      }
      let deadline = DispatchWorkItem { finish(RecordingControlError.failed) }
      timeout = deadline
      DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: deadline)
      channel.invokeMethod("performAction", arguments: ["action": action, "recordingId": id]) { response in
        finish((response as? Bool) == true ? nil : RecordingControlError.failed)
      }
    }
  }

  func clearStaleActivities() {
    Task { @MainActor in await end() }
  }
}
