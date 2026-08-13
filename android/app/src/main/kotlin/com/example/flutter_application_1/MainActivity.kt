package com.example.flutter_application_1

import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val PLAYER_BRIGHTNESS_CHANNEL = "helloworld_flutter/player_brightness"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 播放器仅调整当前应用窗口亮度，不修改系统全局亮度，也不需要系统设置权限。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLAYER_BRIGHTNESS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBrightness" -> {
                        val windowBrightness = window.attributes.screenBrightness
                        val brightness = try {
                            if (windowBrightness >= 0f) {
                                windowBrightness
                            } else {
                                Settings.System.getInt(
                                    contentResolver,
                                    Settings.System.SCREEN_BRIGHTNESS,
                                    128,
                                ) / 255f
                            }
                        } catch (_: SecurityException) {
                            // 少数定制系统禁止读取系统亮度时使用中间值，手势设置仍可正常工作。
                            0.5f
                        }
                        result.success(brightness.toDouble())
                    }

                    "setBrightness" -> {
                        val brightness = call.argument<Number>("brightness")?.toFloat()
                        if (brightness == null) {
                            result.error("INVALID_BRIGHTNESS", "缺少亮度参数", null)
                            return@setMethodCallHandler
                        }
                        val attributes = window.attributes
                        attributes.screenBrightness = brightness.coerceIn(0.01f, 1f)
                        window.attributes = attributes
                        result.success(null)
                    }

                    "resetBrightness" -> {
                        // 负值表示重新跟随 Android 系统亮度。
                        val attributes = window.attributes
                        attributes.screenBrightness = -1f
                        window.attributes = attributes
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
