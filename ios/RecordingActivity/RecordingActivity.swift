import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RecordingActivityBundle: WidgetBundle {
  var body: some Widget { RecordingActivityWidget() }
}

struct RecordingActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Image(systemName: "mic.fill").foregroundStyle(.red)
          VStack(alignment: .leading) {
            Text(context.attributes.label).font(.headline).lineLimit(1)
            Text(context.state.paused ? "Đã tạm dừng" : "Đang ghi âm").font(.caption)
          }
          Spacer()
          RecordingTimer(state: context.state).font(.title2.monospacedDigit())
        }
        RecordingButtons(context: context)
      }
      .padding()
      .activityBackgroundTint(Color.black.opacity(0.85))
      .activitySystemActionForegroundColor(.white)
      .foregroundStyle(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(context.attributes.label, systemImage: "mic.fill").lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) { RecordingTimer(state: context.state) }
        DynamicIslandExpandedRegion(.bottom) { RecordingButtons(context: context) }
      } compactLeading: {
        Image(systemName: context.state.paused ? "pause.fill" : "mic.fill").foregroundStyle(.red)
      } compactTrailing: {
        RecordingTimer(state: context.state).frame(width: 55)
      } minimal: {
        Image(systemName: context.state.paused ? "pause.fill" : "mic.fill")
      }
    }
  }
}

struct RecordingTimer: View {
  let state: RecordingActivityAttributes.ContentState
  var body: some View {
    if state.paused {
      Text(String(format: "%02d:%02d", Int(state.elapsed) / 60, Int(state.elapsed) % 60))
        .monospacedDigit()
    } else {
      // SwiftUI renders the timer without waking the recorder every second.
      Text(state.runningSince.addingTimeInterval(-state.elapsed), style: .timer).monospacedDigit()
    }
  }
}

struct RecordingButtons: View {
  let context: ActivityViewContext<RecordingActivityAttributes>
  var body: some View {
    HStack {
      control(context.state.paused ? "resume" : "pause",
              title: context.state.paused ? "Tiếp tục" : "Tạm dừng",
              icon: context.state.paused ? "play.fill" : "pause.fill")
      Spacer()
      control("stop", title: "Dừng / Lưu", icon: "stop.fill")
      Spacer()
      control("cancel", title: "Hủy bản ghi", icon: "trash")
    }
    .font(.caption)
    .buttonStyle(.bordered)
  }

  @ViewBuilder
  private func control(_ action: String, title: String, icon: String) -> some View {
    if #available(iOS 17.0, *) {
      Button(intent: RecordingActionIntent(action: action, recordingId: context.attributes.recordingId)) {
        Label(title, systemImage: icon)
      }
    } else {
      Link(destination: actionURL(action)) { Label(title, systemImage: icon) }
    }
  }

  private func actionURL(_ action: String) -> URL {
    var url = URLComponents()
    url.scheme = "recordhorus"
    url.host = "recording"
    url.queryItems = [URLQueryItem(name: "action", value: action),
                      URLQueryItem(name: "id", value: context.attributes.recordingId)]
    return url.url!
  }
}
