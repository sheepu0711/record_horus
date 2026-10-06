package com.example.record_horus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.util.Locale

/**
 * Foreground service giữ tiến trình foreground khi ghi âm (type = microphone)
 * và hiển thị notification có:
 *  - thời gian đã ghi (tự cập nhật mỗi giây)
 *  - nút Pause / Resume
 *  - nút Stop
 *
 * Notification actions được chuyển tiếp về Flutter qua [RecordingChannel]
 * để app điều khiển đúng AudioRecorder của plugin `record`.
 */
class RecordingService : Service() {

    companion object {
        const val NOTIFICATION_CHANNEL_ID = "record_horus_recording"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "com.example.record_horus.action.START"
        const val ACTION_PAUSE = "com.example.record_horus.action.PAUSE"
        const val ACTION_RESUME = "com.example.record_horus.action.RESUME"
        const val ACTION_STOP = "com.example.record_horus.action.STOP"
        const val ACTION_SET_PAUSED = "com.example.record_horus.action.SET_PAUSED"

        const val EXTRA_LABEL = "extra_label"
        const val EXTRA_PAUSED = "extra_paused"

        private const val REQUEST_OPEN = 100
        private const val REQUEST_PAUSE = 101
        private const val REQUEST_RESUME = 102
        private const val REQUEST_STOP = 103

        fun start(context: Context, label: String) {
            val intent = Intent(context, RecordingService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_LABEL, label)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun setPaused(context: Context, paused: Boolean, label: String) {
            val intent = Intent(context, RecordingService::class.java).apply {
                action = ACTION_SET_PAUSED
                putExtra(EXTRA_PAUSED, paused)
                putExtra(EXTRA_LABEL, label)
            }
            context.startService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, RecordingService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    private val mHandler = Handler(Looper.getMainLooper())

    private val ticker = object : Runnable {
        override fun run() {
            if (!paused) {
                updateNotification()
                mHandler.postDelayed(this, 1000L)
            }
        }
    }

    private var label: String = ""
    private var paused: Boolean = false
    private var accumulatedMs: Long = 0L
    private var lastStartRealtimeMs: Long = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                label = intent.getStringExtra(EXTRA_LABEL) ?: ""
                paused = false
                accumulatedMs = 0L
                lastStartRealtimeMs = SystemClock.elapsedRealtime()
                startAsForeground()
                startTicker()
            }

            ACTION_SET_PAUSED -> {
                val nowPaused = intent.getBooleanExtra(EXTRA_PAUSED, paused)
                intent.getStringExtra(EXTRA_LABEL)?.let { label = it }

                if (nowPaused && !paused) {
                    // Bắt đầu pause: chốt thời gian đã ghi.
                    accumulatedMs += SystemClock.elapsedRealtime() - lastStartRealtimeMs
                    paused = true
                    stopTicker()
                } else if (!nowPaused && paused) {
                    // Resume: đặt lại mốc thời gian.
                    lastStartRealtimeMs = SystemClock.elapsedRealtime()
                    paused = false
                    startTicker()
                }
                updateNotification()
            }

            ACTION_STOP -> {
                stopTicker()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopTicker()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Ghi âm",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Thông báo trạng thái ghi âm"
                setShowBadge(false)
            }
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun elapsedMs(): Long {
        return if (paused) {
            accumulatedMs
        } else {
            accumulatedMs + (SystemClock.elapsedRealtime() - lastStartRealtimeMs)
        }
    }

    private fun formatTime(ms: Long): String {
        val totalSeconds = (ms / 1000).coerceAtLeast(0L)
        val h = totalSeconds / 3600
        val m = (totalSeconds % 3600) / 60
        val s = totalSeconds % 60
        return if (h > 0) {
            String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s)
        } else {
            String.format(Locale.ROOT, "%02d:%02d", m, s)
        }
    }

    private fun buildNotification(): Notification {
        val openAppIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openAppPi = openAppIntent?.let {
            PendingIntent.getActivity(
                this,
                REQUEST_OPEN,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_mic)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(openAppPi)

        if (paused) {
            builder
                .setContentTitle("Đã tạm dừng ghi âm")
                .setContentText("$label • ${formatTime(elapsedMs())}")
                .addAction(R.drawable.ic_play, "Tiếp tục", actionPi(ACTION_RESUME, REQUEST_RESUME))
        } else {
            builder
                .setContentTitle("Đang ghi âm…")
                .setContentText("$label • ${formatTime(elapsedMs())}")
                .addAction(R.drawable.ic_pause, "Tạm dừng", actionPi(ACTION_PAUSE, REQUEST_PAUSE))
        }
        builder.addAction(R.drawable.ic_stop, "Dừng", actionPi(ACTION_STOP, REQUEST_STOP))

        return builder.build()
    }

    private fun actionPi(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, RecordingActionReceiver::class.java).apply {
            this.action = action
        }
        return PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun updateNotification() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun startTicker() {
        stopTicker()
        mHandler.post(ticker)
    }

    private fun stopTicker() {
        mHandler.removeCallbacksAndMessages(null)
    }
}
