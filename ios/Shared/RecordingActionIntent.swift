import AppIntents

@available(iOS 17.0, *)
struct RecordingActionIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Điều khiển ghi âm"
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Thao tác") var action: String
  @Parameter(title: "Bản ghi") var recordingId: String

  init() {}

  init(action: String, recordingId: String) {
    self.action = action
    self.recordingId = recordingId
  }

  func perform() async throws -> some IntentResult {
    // LiveActivityIntent runs in Runner, where the Flutter recorder lives.
    #if !WIDGET_EXTENSION
    try await RecordingControl.shared.perform(action: action, recordingId: recordingId)
    #endif
    return .result()
  }
}
