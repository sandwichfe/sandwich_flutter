我先看一下当前目录结构，然后把这部分内容整理成一份独立 Markdown 文档，方便你直接放到项目文档里。下面是一份可直接保存为 `media_kit_player_design.md` 的 Markdown 文档：

```markdown
# Flutter media_kit 跨平台播放器设计说明

## 1. 为什么 Web 能直接播放，Windows 需要具体实现

Flutter 的播放器插件通常只是 Dart 层的统一接口，真正播放能力依赖各个平台自己的底层实现。

以播放器插件为例：

```text
Flutter Dart API
    |
    | Web -> 浏览器 <video> / HTMLMediaElement
    |
    | Windows -> 需要 Media Foundation / mpv / VLC / FFmpeg 等原生实现
```

Web 端可以直接调用浏览器原生 `<video>` 能力，浏览器已经内置了解码、渲染、网络加载、播放控制等能力。

Windows 端 Flutter 本身不内置视频播放能力，如果插件没有提供 Windows 的平台实现，就只有 Dart 接口，没有真正负责播放视频的底层代码，所以无法播放。

## 2. media_kit 跨平台是否方便

`media_kit` 跨平台比较方便，普通播放场景通常不需要每个平台单独写一套播放器代码。

播放器逻辑可以统一：

```dart
final player = Player();
final controller = VideoController(player);

await player.open(Media('https://example.com/video.mp4'));
```

界面也可以统一：

```dart
Video(controller: controller)
```

但不同平台需要添加对应的底层依赖包。

示例：

```yaml
dependencies:
  media_kit: ^1.1.10
  media_kit_video: ^1.2.5

  media_kit_libs_android_video: ^1.3.7
  media_kit_libs_ios_video: ^1.1.4
  media_kit_libs_macos_video: ^1.1.4
  media_kit_libs_windows_video: ^1.0.11
  media_kit_libs_linux: ^1.1.3
  media_kit_libs_web_video: ^1.0.9
```

总结：

```text
播放器逻辑：一套代码
UI 控制层：一套代码
平台底层：通过 media_kit_libs_* 包适配
特殊能力：少量平台判断
```

## 3. 什么时候需要分平台写代码

普通播放、暂停、进度、倍速、全屏，一般可以一套代码处理。

以下情况通常需要分平台适配：

```text
桌面端：窗口置顶、无边框、快捷键
移动端：后台播放、锁屏控制、耳机线控
Web 端：浏览器自动播放限制
不同平台：视频格式、硬件解码策略差异
```

推荐不要在播放器页面到处写平台判断，而是封装平台适配层。

目录示例：

```text
lib/
  platform/
    player_platform.dart
    player_platform_stub.dart
    player_platform_io.dart
    player_platform_web.dart
```

入口文件：

```dart
// lib/platform/player_platform.dart
export 'player_platform_stub.dart'
    if (dart.library.io) 'player_platform_io.dart'
    if (dart.library.html) 'player_platform_web.dart';
```

默认实现：

```dart
// lib/platform/player_platform_stub.dart
class PlayerPlatformFeature {
  Future<void> init() async {}

  Future<void> enterFullscreen() async {}

  Future<void> dispose() async {}
}
```

Web 实现：

```dart
// lib/platform/player_platform_web.dart
class PlayerPlatformFeature {
  Future<void> init() async {
    // 处理 Web 自动播放限制、浏览器全屏等
  }

  Future<void> enterFullscreen() async {}

  Future<void> dispose() async {}
}
```

桌面 / 移动实现：

```dart
// lib/platform/player_platform_io.dart
import 'dart:io' show Platform;

class PlayerPlatformFeature {
  Future<void> init() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await _initDesktop();
    } else if (Platform.isAndroid || Platform.isIOS) {
      await _initMobile();
    }
  }

  Future<void> _initDesktop() async {
    // 桌面端：窗口置顶、无边框、快捷键
  }

  Future<void> _initMobile() async {
    // 移动端：后台播放、锁屏控制、耳机线控
  }

  Future<void> enterFullscreen() async {}

  Future<void> dispose() async {}
}
```

播放器页面中只调用统一接口：

```dart
final platformFeature = PlayerPlatformFeature();

Future<void> initPlayer() async {
  await platformFeature.init();
}
```

## 4. 桌面端能力示例

桌面端常用插件：

```yaml
dependencies:
  window_manager: ^0.4.3
  hotkey_manager: ^0.2.3
```

窗口置顶：

```dart
import 'dart:io' show Platform;
import 'package:window_manager/window_manager.dart';

Future<void> initDesktopWindow() async {
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    return;
  }

  await windowManager.ensureInitialized();

  await windowManager.setTitle('播放器');
  await windowManager.setAlwaysOnTop(true);
  await windowManager.setFullScreen(false);
}
```

无边框窗口：

```dart
await windowManager.waitUntilReadyToShow(
  const WindowOptions(
    titleBarStyle: TitleBarStyle.hidden,
  ),
  () async {
    await windowManager.show();
    await windowManager.focus();
  },
);
```

快捷键：

```dart
import 'package:hotkey_manager/hotkey_manager.dart';

Future<void> registerDesktopHotkeys() async {
  await hotKeyManager.unregisterAll();

  final playPauseHotKey = HotKey(
    key: PhysicalKeyboardKey.space,
    scope: HotKeyScope.inapp,
  );

  await hotKeyManager.register(
    playPauseHotKey,
    keyDownHandler: (_) {
      // 调用 player.playOrPause()
    },
  );
}
```

## 5. 移动端后台播放与锁屏控制

移动端常用插件：

```yaml
dependencies:
  audio_service: ^0.18.15
  audio_session: ^0.1.21
```

初始化音频会话：

```dart
import 'package:audio_session/audio_session.dart';

Future<void> initMobileAudioSession() async {
  final session = await AudioSession.instance;

  await session.configure(
    const AudioSessionConfiguration.music(),
  );
}
```

锁屏控制、通知栏控制通常用 `audio_service` 封装一个 `AudioHandler`：

```dart
class PlayerAudioHandler extends BaseAudioHandler {
  Future<void> play() async {
    // player.play()
  }

  Future<void> pause() async {
    // player.pause()
  }

  Future<void> seek(Duration position) async {
    // player.seek(position)
  }
}
```

初始化：

```dart
final audioHandler = await AudioService.init(
  builder: () => PlayerAudioHandler(),
  config: const AudioServiceConfig(
    androidNotificationChannelId: 'com.example.player.channel',
    androidNotificationChannelName: 'Player',
    androidNotificationOngoing: true,
  ),
);
```

## 6. Web 自动播放限制

浏览器通常禁止没有用户手势的有声自动播放。

推荐通过用户点击触发播放：

```dart
Future<void> playAfterUserTap(Player player, String url) async {
  await player.open(
    Media(url),
    play: true,
  );
}
```

如果必须自动播放，通常需要先静音：

```dart
await player.setVolume(0);

await player.open(
  Media(videoUrl),
  play: true,
);
```

## 7. 不同平台的视频格式选择

可以封装一个统一方法，根据平台选择合适的视频地址。

```dart
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/foundation.dart' show TargetPlatform;

String choosePlayableUrl({
  required String mp4Url,
  required String hlsUrl,
}) {
  if (kIsWeb) {
    return hlsUrl;
  }

  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    return hlsUrl;
  }

  if (defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux) {
    return mp4Url;
  }

  return mp4Url;
}
```

调用：

```dart
final url = choosePlayableUrl(
  mp4Url: video.mp4Url,
  hlsUrl: video.hlsUrl,
);

await player.open(Media(url));
```

## 8. media_kit 是否支持视频进度预览图

`media_kit` 本身主要负责播放、暂停、seek、音量、字幕、轨道、视频渲染。

它不直接提供类似 YouTube 那种拖动进度条显示缩略图的完整组件。

但可以自己实现：

```text
media_kit 负责播放
自定义控制层负责进度条交互
Emby 接口 / BIF 文件负责缩略图数据
进度条上方显示预览图浮层
```

推荐结构：

```text
PlayerPage
  ├─ media_kit 播放器
  ├─ 自定义进度条
  └─ ThumbnailPreviewController
       ├─ 调 Emby 接口
       ├─ 解析 BIF
       └─ 根据时间返回 Uint8List 图片
```

## 9. Emby 缩略图来源

常见有两类。

第一类是 Emby 图片 / Trickplay 接口。

如果 Emby 已经生成了缩略图，可以通过接口按时间点取图。具体接口需要根据 Emby 版本、媒体库配置、是否开启缩略图生成来确认。

第二类是 BIF 文件。

BIF 本质上是一个缩略图索引文件：

```text
一个 BIF 文件里包含很多张缩略图
每张缩略图对应一个时间点
客户端根据播放时间找到对应图片
```

简化逻辑：

```text
当前播放秒数 -> 计算缩略图 index -> 从 BIF 取出对应图片 -> 显示
```

`media_kit` 不会帮你解析 BIF，需要自己解析或找 Dart 相关解析库。

## 10. 缩略图控制器设计

示例：

```dart
class ThumbnailPreviewController {
  final Map<int, Uint8List> _cache = {};

  Future<Uint8List?> getThumbnailAt(Duration position) async {
    final index = position.inSeconds ~/ 10;

    final cached = _cache[index];
    if (cached != null) {
      return cached;
    }

    final imageBytes = await _loadThumbnail(index);

    if (imageBytes != null) {
      _cache[index] = imageBytes;
    }

    return imageBytes;
  }

  Future<Uint8List?> _loadThumbnail(int index) async {
    // 可以调用 Emby thumbnail/trickplay 接口
    // 也可以解析 BIF 文件
    return null;
  }
}
```

时间计算：

```dart
Duration calculateTimelinePosition({
  required double localDx,
  required double width,
  required Duration duration,
}) {
  final percent = (localDx / width).clamp(0.0, 1.0);

  return Duration(
    milliseconds: (duration.inMilliseconds * percent).round(),
  );
}
```

## 11. Windows hover 与移动端拖动预览如何设计

不要把 Windows 和移动端写成两套播放器。

推荐：

```text
缩略图数据获取：统一
进度位置计算：统一
预览浮层显示：统一
触发交互方式：按平台区分
```

平台策略：

```text
Windows / macOS / Linux：鼠标 hover / move 显示缩略图
Android / iOS：进度条拖动时显示缩略图
Web：hover 和拖动都可以支持
```

平台判断建议用 `defaultTargetPlatform`，UI 层尽量不要直接用 `dart:io`：

```dart
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/foundation.dart' show TargetPlatform;

bool get isDesktopLike {
  if (kIsWeb) {
    return true;
  }

  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

bool get isMobileLike {
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
```

## 12. 进度条预览状态模型

```dart
class TimelinePreviewState {
  const TimelinePreviewState({
    required this.visible,
    required this.position,
    required this.dx,
    this.imageBytes,
  });

  final bool visible;
  final Duration position;
  final double dx;
  final Uint8List? imageBytes;
}
```

## 13. PreviewTimelineBar 组件骨架

```dart
class PreviewTimelineBar extends StatefulWidget {
  const PreviewTimelineBar({
    super.key,
    required this.duration,
    required this.position,
    required this.onSeek,
    required this.thumbnailController,
  });

  final Duration duration;
  final Duration position;
  final ValueChanged<Duration> onSeek;
  final ThumbnailPreviewController thumbnailController;

  @override
  State<PreviewTimelineBar> createState() => _PreviewTimelineBarState();
}
```

State 核心逻辑：

```dart
class _PreviewTimelineBarState extends State<PreviewTimelineBar> {
  TimelinePreviewState? previewState;
  int? lastPreviewIndex;

  Future<void> _updatePreview({
    required double localDx,
    required double width,
  }) async {
    final position = calculateTimelinePosition(
      localDx: localDx,
      width: width,
      duration: widget.duration,
    );

    final index = position.inSeconds ~/ 10;

    setState(() {
      previewState = TimelinePreviewState(
        visible: true,
        position: position,
        dx: localDx,
        imageBytes: previewState?.imageBytes,
      );
    });

    if (index == lastPreviewIndex) {
      return;
    }

    lastPreviewIndex = index;

    final imageBytes = await widget.thumbnailController.getThumbnailAt(position);

    if (!mounted) {
      return;
    }

    setState(() {
      previewState = TimelinePreviewState(
        visible: true,
        position: position,
        dx: localDx,
        imageBytes: imageBytes,
      );
    });
  }

  void _hidePreview() {
    setState(() {
      previewState = null;
    });
  }
}
```

## 14. 桌面端 hover 触发

```dart
Widget _buildDesktopTimeline(BuildContext context) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;

      return MouseRegion(
        onHover: (event) {
          _updatePreview(
            localDx: event.localPosition.dx,
            width: width,
          );
        },
        onExit: (_) {
          _hidePreview();
        },
        child: _buildTimelineBody(width),
      );
    },
  );
}
```

## 15. 移动端拖动触发

```dart
Widget _buildMobileTimeline(BuildContext context) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;

      return GestureDetector(
        onHorizontalDragStart: (details) {
          _updatePreview(
            localDx: details.localPosition.dx,
            width: width,
          );
        },
        onHorizontalDragUpdate: (details) {
          _updatePreview(
            localDx: details.localPosition.dx,
            width: width,
          );
        },
        onHorizontalDragEnd: (_) {
          if (previewState != null) {
            widget.onSeek(previewState!.position);
          }

          _hidePreview();
        },
        onTapDown: (details) {
          final position = calculateTimelinePosition(
            localDx: details.localPosition.dx,
            width: width,
            duration: widget.duration,
          );

          widget.onSeek(position);
        },
        child: _buildTimelineBody(width),
      );
    },
  );
}
```

统一 build：

```dart
@override
Widget build(BuildContext context) {
  if (isMobileLike) {
    return _buildMobileTimeline(context);
  }

  return _buildDesktopTimeline(context);
}
```

## 16. 缩略图浮层 UI

```dart
Widget _buildTimelineBody(double width) {
  final durationMs = widget.duration.inMilliseconds;
  final positionMs = widget.position.inMilliseconds;
  final progress = durationMs == 0 ? 0.0 : positionMs / durationMs;

  return SizedBox(
    height: 120,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 20,
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
          ),
        ),
        if (previewState?.visible == true)
          _buildPreviewPopup(width),
      ],
    ),
  );
}
```

```dart
Widget _buildPreviewPopup(double width) {
  const previewWidth = 160.0;
  const previewHeight = 90.0;

  final left = (previewState!.dx - previewWidth / 2)
      .clamp(0.0, width - previewWidth);

  return Positioned(
    left: left,
    bottom: 40,
    child: Container(
      width: previewWidth,
      height: previewHeight + 24,
      color: const Color(0xFF111111),
      child: Column(
        children: [
          SizedBox(
            width: previewWidth,
            height: previewHeight,
            child: previewState!.imageBytes == null
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Image.memory(
                    previewState!.imageBytes!,
                    fit: BoxFit.cover,
                  ),
          ),
          SizedBox(
            height: 24,
            child: Center(
              child: Text(
                formatDuration(previewState!.position),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
```

时间格式化：

```dart
String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
```

## 17. 最终推荐架构

```text
media_kit
  只负责播放核心：open / play / pause / seek / volume / subtitle / render

PlayerControls
  负责播放器 UI、进度条、按钮、全屏、倍速

PreviewTimelineBar
  负责进度条 hover / drag 交互

ThumbnailPreviewController
  负责 Emby 缩略图接口、BIF 解析、缓存

PlatformFeature
  负责桌面窗口、快捷键、移动端后台播放、Web 自动播放限制
```

最终原则：

```text
不要把每个平台写成不同播放器
播放器核心保持统一
平台差异集中封装
控制层根据平台选择交互方式
缩略图获取与缓存独立于 media_kit
```
```