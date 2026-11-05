import 'package:flutter/material.dart';

import 'emby_pc_detail_page.dart';
import 'emby_pc_models.dart';
import 'emby_pc_player_page.dart';

// 播放上下文：把“播哪个条目、从哪个位置、用哪个媒体版本”收敛成一个对象。
// 工作台与详情页共用同一入口，后续接剧集连播时只需在这里扩展队列字段。
class EmbyPcPlaybackRequest {
  final EmbyPcItem item;
  // Emby 的 ticks 单位为 100ns；fromBeginning 为 true 时忽略 startPositionTicks。
  final int startPositionTicks;
  final String? mediaSourceId;
  final bool fromBeginning;

  const EmbyPcPlaybackRequest({
    required this.item,
    this.startPositionTicks = 0,
    this.mediaSourceId,
    this.fromBeginning = false,
  });
}

// 打开播放器并等待本次播放结束；返回 true 表示播放过，调用方应刷新进度。
Future<bool> openEmbyPcPlayer(
  BuildContext context,
  EmbyPcPlaybackRequest request,
) async {
  final played = await Navigator.of(context).push<bool>(
    embyPcFadeRoute(
      context,
      (_) => EmbyPcPlayerPage(
        item: request.item,
        startPositionTicks: request.fromBeginning
            ? 0
            : request.startPositionTicks,
        mediaSourceId: request.mediaSourceId,
      ),
    ),
  );
  return played == true;
}
