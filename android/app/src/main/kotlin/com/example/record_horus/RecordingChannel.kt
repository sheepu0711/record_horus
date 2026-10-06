package com.example.record_horus

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Cầu nối Flutter <-> Android notification:
 *
 *  - Flutter -> native (MethodChannel):
 *      "notificationStatus"        - trạng thái bật/tắt thông báo của app + channel
 *      "requestNotificationPermission" - xin quyền POST_NOTIFICATIONS (Android 13+),
 *                                        trả kết quả {granted, needsSettings}
 *      "openNotificationSettings"  - mở màn cài đặt thông báo của app (MIUI thường
 *                                        yêu cầu người dùng bật thủ công)
 *      "start"     - khởi tạo foreground service + notification
 *      "setPaused" - cập nhật trạng thái Pause/Resume + thời gian
 *      "stop"      - dừng foreground service + xoá notification
 *
 *  - native -> Flutter (EventChannel): "pause" / "resume" / "stop"
 *    khi người dùng bấm nút trên notification.
 */
object RecordingChannel {
    const val METHOD_CHANNEL = "com.example.record_horus/recording_control"
    const val EVENT_CHANNEL = "com.example.record_horus/recording_actions"

    const val ACTION_PAUSE = "pause"
    const val ACTION_RESUME = "resume"
    const val ACTION_STOP = "stop"

    private const val REQUEST_CODE_NOTIFICATIONS = 2001

    private var activity: Activity? = null
    private var appContext: Context? = null

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    // Kết quả MethodChannel đang chờ onRequestPermissionsResult.
    private var pendingPermissionResult: MethodChannel.Result? = null

    /** Được gọi khi MainActivity configure FlutterEngine. */
    fun configure(engine: FlutterEngine, activity: Activity) {
        this.activity = activity
        appContext = activity.applicationContext

        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            val ctx = appContext ?: return@setMethodCallHandler result.error(
                "no_context",
                "Application context is not ready.",
                null,
            )
            when (call.method) {
                "notificationStatus" -> {
                    result.success(notificationStatus(ctx))
                }

                "requestNotificationPermission" -> {
                    requestNotificationPermission(ctx, result)
                }

                "openNotificationSettings" -> {
                    openNotificationSettings(ctx)
                    result.success(null)
                }

                "start" -> {
                    val label = call.argument<String>("label") ?: ""
                    RecordingService.start(ctx, label)
                    result.success(null)
                }

                "setPaused" -> {
                    val paused = call.argument<Boolean>("paused") ?: false
                    val label = call.argument<String>("label") ?: ""
                    RecordingService.setPaused(ctx, paused, label)
                    result.success(null)
                }

                "stop" -> {
                    RecordingService.stop(ctx)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    /** MainActivity gọi lại sau khi người dùng trả lời popup quyền. */
    fun onPermissionResult(granted: Boolean) {
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null

        val ctx = appContext
        val enabled = ctx?.let { notificationsEnabled(it) } ?: granted
        result.success(
            mapOf(
                "granted" to granted,
                "enabled" to enabled,
                "needsSettings" to (!granted || !enabled),
            ),
        )
    }

    /** Gửi action từ notification tới Flutter engine đang chạy. */
    fun sendAction(action: String) {
        eventSink?.success(action)
    }

    private fun notificationStatus(ctx: Context): Map<String, Any> {
        val enabled = notificationsEnabled(ctx)
        return mapOf(
            "enabled" to enabled,
            "permissionGranted" to permissionGranted(ctx),
        )
    }

    private fun requestNotificationPermission(ctx: Context, result: MethodChannel.Result) {
        // Android < 13: không có runtime permission, chỉ cần app/channel đang bật.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            val enabled = notificationsEnabled(ctx)
            result.success(
                mapOf(
                    "granted" to enabled,
                    "enabled" to enabled,
                    "needsSettings" to !enabled,
                ),
            )
            return
        }

        val act = activity
        if (act == null) {
            result.success(
                mapOf("granted" to false, "enabled" to false, "needsSettings" to true),
            )
            return
        }

        val granted = permissionGranted(ctx)
        if (granted) {
            val enabled = notificationsEnabled(ctx)
            result.success(
                mapOf("granted" to true, "enabled" to enabled, "needsSettings" to !enabled),
            )
            return
        }

        // Chưa có quyền: nếu đã từ chối hẳn (không thể hỏi lại) thì mở cài đặt.
        val canAsk = act.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS) ||
            !permissionEverAsked(ctx)
        if (!canAsk) {
            openNotificationSettings(ctx)
            result.success(
                mapOf("granted" to false, "enabled" to false, "needsSettings" to true),
            )
            return
        }

        pendingPermissionResult = result
        act.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE_NOTIFICATIONS)
    }

    private fun openNotificationSettings(ctx: Context) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
            }
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.parse("package:${ctx.packageName}")
            }
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
    }

    private fun permissionGranted(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    /**
     * Đã từng hỏi quyền POST_NOTIFICATIONS chưa (để phân biệt "chưa hỏi lần nào"
     * với "đã bị từ chối hẳn"). Lưu bằng SharedPreferences vì Android không có API
     * trực tiếp cho việc này.
     */
    private fun permissionEverAsked(ctx: Context): Boolean {
        val prefs = ctx.getSharedPreferences("record_horus_prefs", Context.MODE_PRIVATE)
        return prefs.getBoolean("notif_permission_asked", false)
    }

    fun markPermissionAsked(ctx: Context) {
        ctx.getSharedPreferences("record_horus_prefs", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("notif_permission_asked", true)
            .apply()
    }

    /** App + channel "Ghi âm" có đang được phép hiện notification không. */
    private fun notificationsEnabled(ctx: Context): Boolean {
        val managerCompat = NotificationManagerCompat.from(ctx)
        if (!managerCompat.areNotificationsEnabled()) {
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = manager.getNotificationChannel(RecordingService.NOTIFICATION_CHANNEL_ID)
            if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) {
                return false
            }
        }
        return true
    }
}
