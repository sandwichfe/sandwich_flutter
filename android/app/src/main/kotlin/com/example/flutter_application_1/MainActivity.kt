package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    companion object {
        private const val PLAYER_BRIGHTNESS_CHANNEL = "helloworld_flutter/player_brightness"
        private const val PLAYER_VOLUME_CHANNEL = "helloworld_flutter/player_volume"
        private const val VOLUME_CHANGED_ACTION = "android.media.VOLUME_CHANGED_ACTION"
        private const val EXTRA_VOLUME_STREAM_TYPE = "android.media.EXTRA_VOLUME_STREAM_TYPE"
    }

    private lateinit var playerVolumeChannel: MethodChannel
    private var volumeReceiver: BroadcastReceiver? = null

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

        playerVolumeChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLAYER_VOLUME_CHANNEL)
        playerVolumeChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getVolume" -> result.success(getMediaVolume())

                "setVolume" -> {
                    val volume = call.argument<Number>("volume")?.toDouble()
                    if (volume == null) {
                        result.error("INVALID_VOLUME", "缺少音量参数", null)
                        return@setMethodCallHandler
                    }
                    setMediaVolume(volume)
                    result.success(getMediaVolume())
                }

                "startObserving" -> {
                    startObservingMediaVolume()
                    result.success(getMediaVolume())
                }

                "stopObserving" -> {
                    stopObservingMediaVolume()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun getMediaVolume(): Double {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val maximumVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (maximumVolume <= 0) return 0.0
        return audioManager.getStreamVolume(AudioManager.STREAM_MUSIC) * 100.0 / maximumVolume
    }

    private fun setMediaVolume(volume: Double) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val maximumVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        // Android 音量使用离散档位，四舍五入后再交给系统设置实际媒体音量。
        val targetVolume = (volume.coerceIn(0.0, 100.0) * maximumVolume / 100.0)
            .roundToInt()
            .coerceIn(0, maximumVolume)
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, targetVolume, 0)
    }

    private fun startObservingMediaVolume() {
        if (volumeReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val streamType = intent?.getIntExtra(EXTRA_VOLUME_STREAM_TYPE, -1)
                if (streamType == AudioManager.STREAM_MUSIC) {
                    // 手机音量键或系统面板发生变化后，主动刷新 Flutter 播放器音量 UI。
                    playerVolumeChannel.invokeMethod("onVolumeChanged", getMediaVolume())
                }
            }
        }
        val filter = IntentFilter(VOLUME_CHANGED_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
        volumeReceiver = receiver
        // 即使播放器暂停，手机实体音量键也继续调整媒体音量而不是铃声音量。
        volumeControlStream = AudioManager.STREAM_MUSIC
    }

    private fun stopObservingMediaVolume() {
        val receiver = volumeReceiver ?: return
        unregisterReceiver(receiver)
        volumeReceiver = null
        volumeControlStream = AudioManager.USE_DEFAULT_STREAM_TYPE
    }

    override fun onResume() {
        super.onResume()
        if (::playerVolumeChannel.isInitialized && volumeReceiver != null) {
            // 从系统设置返回应用时再次同步，覆盖设备未发送音量广播的情况。
            playerVolumeChannel.invokeMethod("onVolumeChanged", getMediaVolume())
        }
    }

    override fun onDestroy() {
        stopObservingMediaVolume()
        super.onDestroy()
    }
}
