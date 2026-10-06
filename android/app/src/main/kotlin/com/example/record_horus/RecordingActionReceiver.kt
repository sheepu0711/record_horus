package com.example.record_horus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Nhận tap từ notification action (Pause / Resume / Stop) và đẩy lên Flutter
 * qua [RecordingChannel.sendAction]. Khi app đã bị dừng (process dead) sẽ
 * không có Flutter engine lắng nghe nên thao tác được bỏ qua an toàn.
 */
class RecordingActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            RecordingService.ACTION_PAUSE -> RecordingChannel.sendAction(
                RecordingChannel.ACTION_PAUSE,
            )

            RecordingService.ACTION_RESUME -> RecordingChannel.sendAction(
                RecordingChannel.ACTION_RESUME,
            )

            RecordingService.ACTION_STOP -> RecordingChannel.sendAction(
                RecordingChannel.ACTION_STOP,
            )
        }
    }
}
