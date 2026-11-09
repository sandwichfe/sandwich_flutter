import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/windows_title_bar.dart';
import 'emby_pc_models.dart';
import 'emby_pc_person_page.dart';
import 'emby_pc_playback.dart';
import 'emby_pc_service.dart';
import 'emby_pc_toast.dart';
import 'emby_pc_widgets.dart';

part 'emby_pc_detail_layout.dart';
part 'emby_pc_detail_chapters.dart';
part 'emby_pc_detail_parts.dart';
part 'emby_pc_detail_people_artwork.dart';
part 'emby_pc_detail_information.dart';
part 'emby_pc_artwork_preview.dart';

// Emby 桌面页面统一使用短淡入，避免 Windows 默认 Zoom 放大页面结构差异。
Route<T> embyPcFadeRoute<T>(BuildContext context, WidgetBuilder builder) {
  final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  return PageRouteBuilder<T>(
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180),
    reverseTransitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 140),
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
        child: child,
      );
    },
  );
}

// 详情页和人物页共用常驻顶部层，加载期间也立即提供返回和当前标题。
class EmbyPcImmersiveTopBar extends StatelessWidget {
  final String title;
  final bool loading;

  const EmbyPcImmersiveTopBar({
    super.key,
    required this.title,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    // 工作台内嵌窗口按钮后，详情页也要自带按钮，避免全屏页面无法最小化/关闭。
    final windowsChrome =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final titleWidget = Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          title.isEmpty ? '详情' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
    // 与工作台页头共用外壳，高度由统一常量控制，切页时不会跳动。
    return EmbyPcTopBarShell(
      color: colors.surface.withValues(alpha: 0.78),
      hairline: colors.outlineVariant.withValues(alpha: 0.56),
      showWindowButtons: windowsChrome,
      child: Padding(
        padding: EdgeInsets.only(left: 14, right: windowsChrome ? 0 : 14),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              onPressed: navigator.canPop() ? () => navigator.pop() : null,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: windowsChrome
                  ? WindowsDragArea(child: titleWidget)
                  : titleWidget,
            ),
            if (loading) ...[
              const SizedBox(width: 16),
              Semantics(
                label: '正在加载',
                child: const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              const SizedBox(width: 10),
            ],
          ],
        ),
      ),
    );
  }
}

class EmbyPcDetailPage extends StatefulWidget {
  final EmbyPcItem item;
  final Future<bool> Function(EmbyPcItem, EmbyPcMediaAction) onMediaAction;

  const EmbyPcDetailPage({
    super.key,
    required this.item,
    required this.onMediaAction,
  });

  @override
  State<EmbyPcDetailPage> createState() => _EmbyPcDetailPageState();
}

class _EmbyPcDetailPageState extends State<EmbyPcDetailPage> {
  EmbyPcItem? _detail;
  List<EmbyPcItem> _similar = const [];
  // 同一部影片的分片（含当前条目）；只有 2 段以上才渲染区块。
  List<EmbyPcItem> _parts = const [];
  bool _loading = true;
  bool _favoriteBusy = false;
  bool _actionBusy = false;
  String _error = '';
  // 静默刷新进行中时忽略重复触发，避免管理动作与图片通知各请求一次。
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // 任何入口改了条目图片都通知一次，这里静默重取，保证详情页不会停在旧图上。
    EmbyPcService.instance.imagesRevision.addListener(_handleImagesChanged);
    _loadDetail();
  }

  @override
  void dispose() {
    EmbyPcService.instance.imagesRevision.removeListener(_handleImagesChanged);
    super.dispose();
  }

  // 图片变更后只刷新数据，不切回整页加载态，避免打断正在浏览的内容。
  void _handleImagesChanged() {
    if (!mounted) return;
    _loadDetail(silent: true);
  }

  Future<void> _loadDetail({bool silent = false}) async {
    if (silent && _refreshing) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    _refreshing = true;
    try {
      final results = await Future.wait<dynamic>([
        EmbyPcService.instance.getItemDetail(widget.item.id),
        EmbyPcService.instance.getSimilarItems(widget.item.id),
        _loadParts(widget.item.id),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as EmbyPcItem;
        _similar = results[1] as List<EmbyPcItem>;
        _parts = results[2] as List<EmbyPcItem>;
        _error = '';
      });
    } catch (error) {
      // 静默刷新失败时保留已有内容，只有首次加载才展示错误页。
      if (mounted && !silent) setState(() => _error = error.toString());
    } finally {
      _refreshing = false;
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  // 分片列表是旁路信息：服务端未升级或请求失败时按"不分片"处理，不能影响整页详情。
  Future<List<EmbyPcItem>> _loadParts(String itemId) async {
    try {
      return await EmbyPcService.instance.getItemSiblings(itemId);
    } catch (_) {
      return const <EmbyPcItem>[];
    }
  }

  // 跳出去的页面可能改了图片或元数据，返回时静默重取，回到详情页即是最新内容。
  Future<void> _pushAndRefresh(Widget page) async {
    await Navigator.of(context).push(embyPcFadeRoute(context, (_) => page));
    if (mounted) await _loadDetail(silent: true);
  }

  Future<void> _toggleFavorite() async {
    final detail = _detail;
    if (detail == null || _favoriteBusy) return;
    setState(() => _favoriteBusy = true);
    try {
      final value = await EmbyPcService.instance.setFavorite(
        detail.id,
        !detail.isFavorite,
      );
      if (mounted) setState(() => _detail = detail.copyWith(isFavorite: value));
    } catch (error) {
      if (mounted) {
        EmbyPcToast.show(
          context,
          error.toString(),
          type: EmbyPcToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  Future<void> _selectMediaSource(String mediaSourceId) async {
    final detail = _detail;
    if (detail == null || mediaSourceId.isEmpty || _loading) return;
    final currentIndex = detail.mediaSources.indexWhere(
      (source) => source.id == mediaSourceId,
    );
    if (currentIndex == 0) return;

    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final selected = await EmbyPcService.instance.getMediaSourceInfo(
        itemId: detail.id,
        mediaSourceId: mediaSourceId,
      );
      if (!mounted || selected == null) return;

      final sourceList = [...detail.mediaSources];
      sourceList.removeWhere((source) => source.id == selected.id);
      sourceList.insert(0, selected);
      EmbyPcMediaStream? video;
      for (final stream in selected.streams) {
        if (stream.type == 'Video') {
          video = stream;
          break;
        }
      }
      setState(() {
        _detail = detail.copyWith(
          mediaSources: sourceList,
          runTimeTicks: selected.runTimeTicks > 0
              ? selected.runTimeTicks
              : detail.runTimeTicks,
          width: video?.width ?? detail.width,
          height: video?.height ?? detail.height,
        );
      });
    } catch (error) {
      if (mounted) {
        EmbyPcToast.show(
          context,
          error.toString(),
          type: EmbyPcToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleAction(EmbyPcMediaAction action) async {
    final detail = _detail;
    if (detail == null || _actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      // 管理动作复用工作台逻辑，详情页只在内容变更后静默重取展示数据。
      final changed = await widget.onMediaAction(detail, action);
      if (changed && mounted) await _loadDetail(silent: true);
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _play([int? positionTicks, String? mediaSourceId]) async {
    final detail = _detail;
    if (detail == null) return;
    final played = await openEmbyPcPlayer(
      context,
      EmbyPcPlaybackRequest(
        item: detail,
        startPositionTicks: positionTicks ?? detail.playbackPositionTicks,
        mediaSourceId: mediaSourceId,
      ),
    );
    // 播放器已完成停止上报后重新请求详情，立即展示服务端保存的进度。
    if (played && mounted) await _loadDetail();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final displayItem = detail ?? widget.item;
    final colors = Theme.of(context).colorScheme;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final contentDuration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 220);

    final Widget pageContent;
    if (_loading) {
      pageContent = const Center(
        key: ValueKey('detail-loading'),
        child: CircularProgressIndicator(),
      );
    } else if (_error.isNotEmpty) {
      pageContent = KeyedSubtree(
        key: const ValueKey('detail-error'),
        child: _DetailError(message: _error, onRetry: _loadDetail),
      );
    } else if (detail == null) {
      pageContent = const Center(
        key: ValueKey('detail-empty'),
        child: Text('没有可显示的媒体详情'),
      );
    } else {
      pageContent = EmbyPcScrollToTop(
        key: ValueKey('detail-${detail.id}'),
        builder: (context, scrollController) => CustomScrollView(
          controller: scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _DetailContent(
                      detail: detail,
                      similar: _similar,
                      parts: _parts,
                      favoriteBusy: _favoriteBusy,
                      actionBusy: _actionBusy,
                      onFavorite: _toggleFavorite,
                      onAction: _handleAction,
                      onPlay: _play,
                      onSelectMediaSource: _selectMediaSource,
                      onOpenSimilar: (item) => _pushAndRefresh(
                        EmbyPcDetailPage(
                          item: item,
                          onMediaAction: widget.onMediaAction,
                        ),
                      ),
                      onOpenPerson: (person) => _pushAndRefresh(
                        EmbyPcPersonPage(
                          personId: person.id,
                          personName: person.name,
                          onMediaAction: widget.onMediaAction,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: colors.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 列表条目已有图片信息时，路由首帧就开始展示背景；详情返回后仅渐变替换图片。
          _DetailBackdrop(
            item: displayItem,
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 260),
          ),
          // 使用主题色渐变压暗图片，保证浅色和深色主题下的正文都清晰可读。
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  colors.surface.withValues(alpha: 0.58),
                  colors.surface.withValues(alpha: 0.86),
                  colors.surface.withValues(alpha: 0.98),
                ],
                stops: const [0, 0.48, 1],
              ),
            ),
          ),
          Column(
            children: [
              EmbyPcImmersiveTopBar(title: displayItem.name, loading: _loading),
              Expanded(
                child: AnimatedSwitcher(
                  duration: contentDuration,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: pageContent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
