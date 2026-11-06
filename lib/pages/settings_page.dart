import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'emby-pc/emby_pc_detail_page.dart';
import 'emby-pc/emby_pc_library_admin_page.dart';
import 'emby-pc/emby_pc_person_scrape_page.dart';
import 'emby-pc/emby_pc_service.dart';
import 'emby-pc/emby_pc_thumbnail_job_page.dart';
import 'user_profile_page.dart';
import '../utils/theme_manager.dart';

// 设置项枚举驱动左侧导航与右侧内容的对应关系，避免两处文案走样。
enum _SettingId {
  server,
  avatar,
  libraryOrder,
  libraryAdmin,
  thumbnail,
  personScrape,
  darkMode,
  backgroundColor,
  seedColor,
}

extension _SettingMeta on _SettingId {
  IconData get icon => switch (this) {
    _SettingId.server => Icons.dns_outlined,
    _SettingId.avatar => Icons.person_outline,
    _SettingId.libraryOrder => Icons.swap_vert,
    _SettingId.libraryAdmin => Icons.video_library_outlined,
    _SettingId.thumbnail => Icons.movie_filter_outlined,
    _SettingId.personScrape => Icons.person_search_outlined,
    _SettingId.darkMode => Icons.dark_mode_outlined,
    _SettingId.backgroundColor => Icons.format_color_fill_outlined,
    _SettingId.seedColor => Icons.palette_outlined,
  };

  String get title => switch (this) {
    _SettingId.server => '服务器地址',
    _SettingId.avatar => '修改头像',
    _SettingId.libraryOrder => '调整媒体库顺序',
    _SettingId.libraryAdmin => '媒体库管理',
    _SettingId.thumbnail => '进度条缩略图',
    _SettingId.personScrape => '演员刮削',
    _SettingId.darkMode => '深色模式',
    _SettingId.backgroundColor => '背景色',
    _SettingId.seedColor => '主题色',
  };

  // 描述同时用作右侧面板说明，标题只保留极短的名词。
  String get description => switch (this) {
    _SettingId.server => 'Emby 服务端地址只保存在本地，修改后需要重新登录。',
    _SettingId.avatar => '头像上传到 Emby 服务端账号，客户端只做裁剪与压缩。',
    _SettingId.libraryOrder => '自定义侧栏中媒体库的排列顺序，仅影响当前设备展示。',
    _SettingId.libraryAdmin => '新建、编辑、删除与扫描媒体库，需要管理员权限。',
    _SettingId.thumbnail => '按媒体库批量预生成进度条缩略图，可控抽帧间隔并查看进度。',
    _SettingId.personScrape => '从 TMDB 补齐演员简介、生日与头像写真，按需手动触发。',
    _SettingId.darkMode => '深色模式同时影响页面画布、卡片与导航的明暗层次。',
    _SettingId.backgroundColor => '画布底色，卡片与导航会基于它自动派生层级。',
    _SettingId.seedColor => '主题色决定按钮、选中态与强调文字的颜色。',
  };
}

const Map<String, List<_SettingId>> _settingGroups = {
  '账户': [_SettingId.server, _SettingId.avatar],
  '媒体库': [
    _SettingId.libraryOrder,
    _SettingId.libraryAdmin,
    _SettingId.thumbnail,
    _SettingId.personScrape,
  ],
  '外观': [_SettingId.darkMode, _SettingId.backgroundColor, _SettingId.seedColor],
};

String _hexOf(Color color) {
  String component(double channel) =>
      (channel * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${component(color.r)}${component(color.g)}${component(color.b)}'
      .toUpperCase();
}

class SettingsPage extends StatefulWidget {
  final Future<void> Function() onAdjustLibraryOrder;

  const SettingsPage({super.key, required this.onAdjustLibraryOrder});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _tm = ThemeManager();
  final _serverController = TextEditingController(
    text: EmbyPcService.instance.serverUrl,
  );

  // 左侧选中的设置项，默认落在最常用的服务器地址。
  _SettingId _selected = _SettingId.server;
  bool _savingServer = false;
  // 取色器先改草稿色，点“应用”才写入主题并持久化。
  Color? _colorDraft;
  // 重置草稿时换 key 重建取色器，避免其内部状态覆盖外部颜色。
  int _pickerEpoch = 0;

  @override
  void dispose() {
    _serverController.dispose();
    super.dispose();
  }

  void _selectSetting(_SettingId id) {
    if (_selected == id) return;
    setState(() {
      _selected = id;
      _colorDraft = null;
      _pickerEpoch++;
    });
  }

  Future<void> _saveServerUrl() async {
    if (_savingServer) return;
    final value = _serverController.text.trim();
    setState(() => _savingServer = true);
    try {
      await EmbyPcService.instance.updateServerUrl(value);
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingServer = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }
    if (!mounted) return;
    // 地址已变，当前登录状态作废，直接退出设置页由工作台切回登录界面。
    Navigator.of(context).pop();
  }

  Future<void> _editAvatar() async {
    final updated = await showAvatarEditorBottomSheet(context);
    if (!mounted || !updated) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('头像已更新')));
  }

  void _openPage(Widget page) {
    Navigator.of(context).push(embyPcFadeRoute(context, (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: _tm,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            // 窄屏改为顶部横向标签，宽屏使用固定左侧导航。
            final compact = constraints.maxWidth < 760;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!compact) ...[
                  SizedBox(width: 236, child: _buildSideNavigation(context)),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ],
                Expanded(
                  child: Column(
                    children: [
                      if (compact) _buildTopNavigation(context),
                      Expanded(child: _buildDetail(context)),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSideNavigation(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
        children: [
          for (final entry in _settingGroups.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
              child: Text(
                entry.key,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            for (final id in entry.value)
              _SettingsNavItem(
                icon: id.icon,
                title: id.title,
                selected: _selected == id,
                onTap: () => _selectSetting(id),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildTopNavigation(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            for (final entry in _settingGroups.entries)
              for (final id in entry.value) ...[
                _SettingsNavChip(
                  icon: id.icon,
                  title: id.title,
                  selected: _selected == id,
                  onTap: () => _selectSetting(id),
                ),
                const SizedBox(width: 8),
              ],
          ],
        ),
      ),
    );
  }

  Widget _buildDetail(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colors.secondaryContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _selected.icon,
                      size: 20,
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selected.title,
                          style: Theme.of(
                            context,
                          ).textTheme.titleLarge?.copyWith(fontSize: 16),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _selected.description,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.onSurfaceVariant,
                                height: 1.5,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _buildDetailBody(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailBody(BuildContext context) => switch (_selected) {
    _SettingId.server => _buildServerPane(context),
    _SettingId.avatar => _buildAvatarPane(context),
    _SettingId.libraryOrder => _buildActionPane(
      context,
      description: '排序结果保存在本地，仅在当前设备生效。',
      actionLabel: '调整顺序',
      actionIcon: Icons.swap_vert,
      onPressed: widget.onAdjustLibraryOrder,
    ),
    _SettingId.libraryAdmin => _buildActionPane(
      context,
      description: '需要管理员账号，非管理员进入后只能查看现有媒体库。',
      actionLabel: '打开媒体库管理',
      actionIcon: Icons.video_library_outlined,
      onPressed: () => _openPage(const EmbyPcLibraryAdminPage()),
    ),
    _SettingId.thumbnail => _buildActionPane(
      context,
      description: '任务在服务端后台执行，可随时离开页面，进度会持续更新。',
      actionLabel: '打开缩略图任务',
      actionIcon: Icons.movie_filter_outlined,
      onPressed: () => _openPage(const EmbyPcThumbnailJobPage()),
    ),
    _SettingId.personScrape => _buildActionPane(
      context,
      description: '刮削为联网操作，仅在手动触发时执行，不影响正常扫描。',
      actionLabel: '打开演员刮削',
      actionIcon: Icons.person_search_outlined,
      onPressed: () => _openPage(const EmbyPcPersonScrapePage()),
    ),
    _SettingId.darkMode => _buildDarkModePane(context),
    _SettingId.backgroundColor => _buildColorPane(context, isBackground: true),
    _SettingId.seedColor => _buildColorPane(context, isBackground: false),
  };

  Widget _buildServerPane(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _serverController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: 'http://192.168.1.10:8096',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '保存后当前登录立即失效，需要使用新地址重新登录。',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton(
              onPressed: _savingServer ? null : _saveServerUrl,
              child: _savingServer
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存并重新登录'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(
                () => _serverController.text = EmbyPcService.instance.serverUrl,
              ),
              child: const Text('撤销修改'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAvatarPane(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final service = EmbyPcService.instance;
    final avatarUrl = service.userAvatarUrl();
    final avatarImage = avatarUrl == null ? null : NetworkImage(avatarUrl);
    final userName = service.currentUserName.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: colors.surfaceContainerHighest,
          foregroundImage: avatarImage,
          // 加载失败后标记为不可用并重建，避免反复请求 404 地址。
          onForegroundImageError: avatarImage == null
              ? null
              : (_, _) {
                  service.markUserAvatarUnavailable();
                  if (mounted) setState(() {});
                },
          child: Icon(
            Icons.person_outline,
            size: 32,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                userName.isEmpty ? '当前用户' : userName,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '支持 JPG、PNG，上传前可自由裁剪方圆。',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: _editAvatar,
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('更换头像'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActionPane(
    BuildContext context, {
    required String description,
    required String actionLabel,
    required IconData actionIcon,
    required VoidCallback onPressed,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            description,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(actionIcon, size: 18),
            label: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildDarkModePane(BuildContext context) {
    final isDark = _tm.brightness == Brightness.dark;
    return Row(
      children: [
        Expanded(
          child: _ModeCard(
            icon: Icons.light_mode_outlined,
            title: '浅色',
            selected: !isDark,
            onTap: () => _tm.setBrightness(Brightness.light),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ModeCard(
            icon: Icons.dark_mode_outlined,
            title: '深色',
            selected: isDark,
            onTap: () => _tm.setBrightness(Brightness.dark),
          ),
        ),
      ],
    );
  }

  Widget _buildColorPane(BuildContext context, {required bool isBackground}) {
    final colors = Theme.of(context).colorScheme;
    final current = isBackground ? _tm.backgroundColor : _tm.seedColor;
    final draft = _colorDraft ?? current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: ColorPicker(
            key: ValueKey('color-picker-$isBackground-$_pickerEpoch'),
            pickerColor: draft,
            onColorChanged: (color) => setState(() => _colorDraft = color),
            enableAlpha: false,
            hexInputBar: true,
            portraitOnly: true,
            pickerAreaHeightPercent: 0.55,
            pickerAreaBorderRadius: BorderRadius.circular(6),
            labelTypes: const [],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: draft,
                shape: BoxShape.circle,
                border: Border.all(color: colors.outline),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _hexOf(draft),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                _colorDraft = null;
                _pickerEpoch++;
              }),
              child: const Text('重置'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => setState(() {
                if (isBackground) {
                  _tm.setBackgroundColor(draft);
                } else {
                  _tm.setSeedColor(draft);
                }
                _colorDraft = draft;
              }),
              child: const Text('应用'),
            ),
          ],
        ),
      ],
    );
  }
}

// 左侧导航条目：选中态用主题容器色，保持与工作台侧栏一致的克制样式。
class _SettingsNavItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsNavItem({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? colors.secondaryContainer.withValues(alpha: 0.7)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: selected
                      ? colors.onSecondaryContainer
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? colors.onSecondaryContainer
                          : colors.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 窄屏顶部标签，复用同一套选中语义。
class _SettingsNavChip extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsNavChip({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.secondaryContainer.withValues(alpha: 0.7)
          : colors.surface,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected
                  ? colors.secondaryContainer
                  : colors.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: selected
                    ? colors.onSecondaryContainer
                    : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? colors.onSecondaryContainer
                      : colors.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 明暗模式的整块可选卡片，比开关更直观地表达当前模式。
class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.secondaryContainer.withValues(alpha: 0.7)
          : colors.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? colors.secondaryContainer
                  : colors.outlineVariant,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 24,
                color: selected
                    ? colors.onSecondaryContainer
                    : colors.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? colors.onSecondaryContainer
                      : colors.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
