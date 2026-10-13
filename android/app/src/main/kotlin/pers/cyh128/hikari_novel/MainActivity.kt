package pers.cyh128.hikari_novel

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.KeyEvent
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val intentChannelName = "hikari/system_intents"
    private val readerVolumeChannelName = "hikari/reader_volume_keys"
    private var readerVolumeChannel: MethodChannel? = null
    private var readerVolumeKeyHandlingEnabled = false

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        readerVolumeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, readerVolumeChannelName)
        readerVolumeChannel?.setMethodCallHandler { call, result ->
            if (call.method == "setEnabled") {
                readerVolumeKeyHandlingEnabled = call.argument<Boolean>("enabled") ?: false
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, intentChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openTtsSettings" -> {
                        try {
                            val candidates = arrayListOf(
                                Intent("android.speech.tts.engine.TTS_SETTINGS"),
                                Intent("com.android.settings.TTS_SETTINGS"),
                                Intent(android.provider.Settings.ACTION_SETTINGS)
                            )
                            var launched = false
                            var lastErr: Exception? = null
                            for (it in candidates) {
                                try {
                                    it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(it)
                                    launched = true
                                    break
                                } catch (e: Exception) {
                                    lastErr = e
                                }
                            }
                            if (launched) {
                                result.success(true)
                            } else {
                                result.error(
                                    "INTENT_FAILED",
                                    lastErr?.message ?: "no activity found",
                                    null
                                )
                            }
                        } catch (e: Exception) {
                            result.error("INTENT_FAILED", e.message, null)
                        }
                    }

                    "openApp" -> {
                        val pkg = call.argument<String>("package")
                        if (pkg.isNullOrBlank()) {
                            result.error("ARG_ERROR", "package is null/blank", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val pm: PackageManager = applicationContext.packageManager
                            val launchIntent = pm.getLaunchIntentForPackage(pkg)
                            if (launchIntent != null) {
                                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(launchIntent)
                                result.success(true)
                            } else {
                                result.error("NOT_FOUND", "app not found: $pkg", null)
                            }
                        } catch (e: Exception) {
                            result.error("INTENT_FAILED", e.message, null)
                        }
                    }

                    "installApk" -> {
                        // 内置更新：把缓存目录里已下载的 APK 交给系统安装器
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("ARG_ERROR", "path is null/blank", null)
                            return@setMethodCallHandler
                        }
                        val apkFile = File(path)
                        if (!apkFile.exists()) {
                            result.error("FILE_NOT_FOUND", "apk not found: $path", null)
                            return@setMethodCallHandler
                        }
                        try {
                            // Android 8.0+ 需要「安装未知应用」授权，未授权时跳设置页并告知 Dart 侧
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                                !packageManager.canRequestPackageInstalls()
                            ) {
                                val settingsIntent = Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName")
                                )
                                settingsIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(settingsIntent)
                                result.success("need_permission")
                                return@setMethodCallHandler
                            }
                            // Android 7.0+ 禁止 file:// URI，必须走 FileProvider
                            val apkUri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apkFile)
                            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(apkUri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(installIntent)
                            result.success("ok")
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (readerVolumeKeyHandlingEnabled &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) &&
            (event?.repeatCount ?: 0) > 0
        ) {
            // Ignore long-press repeats so one press turns exactly one page.
            return true
        }
        if (event?.repeatCount ?: 0 > 0) {
            return super.onKeyDown(keyCode, event)
        }
        when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> {
                if (readerVolumeKeyHandlingEnabled) {
                    readerVolumeChannel?.invokeMethod("volumeUp", null)
                    return true
                }
            }
            KeyEvent.KEYCODE_VOLUME_DOWN -> {
                if (readerVolumeKeyHandlingEnabled) {
                    readerVolumeChannel?.invokeMethod("volumeDown", null)
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
