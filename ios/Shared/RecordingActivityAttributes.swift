import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct RecordingActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var paused: Bool
    var elapsed: TimeInterval
    var runningSince: Date
  }

  var recordingId: String
  var label: String
}
