import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'emby_pc_models.dart';
import 'emby_pc_person_page.dart';
import 'emby_pc_player_page.dart';
import 'emby_pc_service.dart';
import 'emby_pc_toast.dart';
import 'emby_pc_widgets.dart';

part 'emby_pc_detail_layout.dart';
part 'emby_pc_detail_chapters.dart';
part 'emby_pc_detail_people_artwork.dart';
part 'emby_pc_detail_information.dart';
part 'emby_pc_artwork_preview.dart';

// Emby 桌面页面统一使用短淡入，避免 Windows 默认 Zoom 放大页面结构差异。
Route<T> embyPcFadeRoute<T>(BuildContext context, WidgetBuilder builder) {
  final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  return PageRouteBuilder<T>(
    transitionDuration:
        reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
    reverseTransitionDuration:
        reduceMotion ? Duration.zero : const Duration(milliseconds: 140),
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
    return Material(
      color: colors.surface.withValues(alpha: 0.78),
      child: Container(
        height: 68,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.56),
            ),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              onPressed: navigator.canPop() ? () => navigator.pop() : null,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title.isEmpty ? '详情' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
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
  bool _loading = true;
  bool _favoriteBusy = false;
  bool _actionBusy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final results = await Future.wait<dynamic>([
        EmbyPcService.instance.getItemDetail(widget.item.id),
        EmbyPcService.instance.getSimilarItems(widget.item.id),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as EmbyPcItem;
        _similar = results[1] as List<EmbyPcItem>;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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

  Future<void> _handleAction(EmbyPcMediaAction action) async {
    final detail = _detail;
    if (detail == null || _actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      // 管理动作复用工作台逻辑，详情页只在内容变更后重新加载展示数据。
      final changed = await widget.onMediaAction(detail, action);
      if (changed && mounted) await _loadDetail();
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _play([int? positionTicks, String? mediaSourceId]) async {
    final detail = _detail;
    if (detail == null) return;
    final played = await Navigator.of(context).push<bool>(
      embyPcFadeRoute(
        context,
        (_) => EmbyPcPlayerPage(
          item: detail,
          startPositionTicks: positionTicks ?? detail.playbackPositionTicks,
          mediaSourceId: mediaSourceId,
        ),
      ),
    );
    // 播放器已完成停止上报后重新请求详情，立即展示服务端保存的进度。
    if (played == true && mounted) await _loadDetail();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final displayItem = detail ?? widget.item;
    final colors = Theme.of(context).colorScheme;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final contentDuration =
        reduceMotion ? Duration.zero : const Duration(milliseconds: 220);

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
      pageContent = CustomScrollView(
        key: ValueKey('detail-${detail.id}'),
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
                    favoriteBusy: _favoriteBusy,
                    actionBusy: _actionBusy,
                    onFavorite: _toggleFavorite,
                    onAction: _handleAction,
                    onPlay: _play,
                    onOpenSimilar:
                        (item) => Navigator.of(context).push(
                          embyPcFadeRoute(
                            context,
                            (_) => EmbyPcDetailPage(
                              item: item,
                              onMediaAction: widget.onMediaAction,
                            ),
                          ),
                        ),
                    onOpenPerson:
                        (person) => Navigator.of(context).push(
                          embyPcFadeRoute(
                            context,
                            (_) => EmbyPcPersonPage(
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
          ),
        ],
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
            duration:
                reduceMotion
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
