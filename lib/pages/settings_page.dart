import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'emby-pc/emby_pc_detail_page.dart';
import 'emby-pc/emby_pc_library_admin_page.dart';
import 'emby-pc/emby_pc_person_scrape_page.dart';
import 'emby-pc/emby_pc_service.dart';
import 'emby-pc/emby_pc_thumbnail_job_page.dart';
import 'user_profile_page.dart';
import '../utils/theme_manager.dart';

class SettingsPage extends StatefulWidget {
  final Future<void> Function() onAdjustLibraryOrder;

  const SettingsPage({super.key, required this.onAdjustLibraryOrder});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _tm = ThemeManager();

  // 背景色和主题色共用选择器，但确认后写入各自的主题配置。
  void _pickColor({
    required String title,
    required Color initialColor,
    required ValueChanged<Color> onConfirmed,
  }) {
    Color temp = initialColor;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: temp,
            onColorChanged: (c) => temp = c,
            labelTypes: const [],
            pickerAreaHeightPercent: 0.8,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              onConfirmed(temp);
              Navigator.pop(context);
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  // 服务器地址不再写死在代码里：这里修改后会清除会话，返回工作台自动回登录页。
  Future<void> _editServerUrl() async {
    final controller = TextEditingController(
      text: EmbyPcService.instance.serverUrl,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('服务器地址'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.10:8096',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (text) => Navigator.pop(dialogContext, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;

    try {
      await EmbyPcService.instance.updateServerUrl(value);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }
    if (!mounted) return;
    // 地址已变，当前登录状态作废，直接退出设置页由工作台切回登录界面。
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // 没有头像标记时地址为空，列表项直接显示占位图标，不发起图片请求。
    final avatarUrl = EmbyPcService.instance.userAvatarUrl();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: _tm,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const _SettingsSectionTitle('账户'),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('服务器地址'),
              subtitle: Text(
                EmbyPcService.instance.serverUrl.isEmpty
                    ? '未设置'
                    : EmbyPcService.instance.serverUrl,
              ),
              trailing: const Icon(Icons.chevron_right),
              // 地址只存本地；改动后旧令牌不再适用，保存时直接注销当前会话。
              onTap: _editServerUrl,
            ),
            const Divider(height: 1, indent: 72),
            ListTile(
              leading: CircleAvatar(
                radius: 20,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                foregroundImage: avatarUrl == null
                    ? null
                    : NetworkImage(avatarUrl),
                // 加载失败后标记为不可用并重建，避免设置页反复请求 404 地址。
                onForegroundImageError: avatarUrl == null
                    ? null
                    : (_, _) {
                        EmbyPcService.instance.markUserAvatarUnavailable();
                        if (mounted) setState(() {});
                      },
                child: const Icon(Icons.person_outline),
              ),
              title: const Text('修改头像'),
              subtitle: Text(
                EmbyPcService.instance.currentUserName.isEmpty
                    ? '当前用户'
                    : EmbyPcService.instance.currentUserName,
              ),
              trailing: const Icon(Icons.edit_outlined),
              // 头像属于轻量设置项，使用底部弹层避免多进入一层用户信息页面。
              onTap: () async {
                final updated = await showAvatarEditorBottomSheet(context);
                if (!mounted || !updated) return;
                setState(() {});
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(content: Text('头像已更新')));
              },
            ),
            const Divider(height: 1, indent: 72),
            const _SettingsSectionTitle('媒体库'),
            ListTile(
              leading: const Icon(Icons.swap_vert),
              title: const Text('调整媒体库顺序'),
              trailing: const Icon(Icons.chevron_right),
              // 排序状态仍由媒体工作台维护，设置页只承载功能入口。
              onTap: widget.onAdjustLibraryOrder,
            ),
            const Divider(height: 1, indent: 72),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('媒体库管理'),
              subtitle: const Text('新建、编辑、删除与扫描媒体库'),
              trailing: const Icon(Icons.chevron_right),
              // 管理页需要管理员权限，失败时由服务层统一提示。
              onTap: () => Navigator.of(context).push(
                embyPcFadeRoute(context, (_) => const EmbyPcLibraryAdminPage()),
              ),
            ),
            const Divider(height: 1, indent: 72),
            ListTile(
              leading: const Icon(Icons.movie_filter_outlined),
              title: const Text('进度条缩略图'),
              subtitle: const Text('按媒体库批量预生成，可控抽帧间隔并查看进度'),
              trailing: const Icon(Icons.chevron_right),
              // 预生成任务在服务端后台执行，页面只负责提交参数与轮询进度。
              onTap: () => Navigator.of(context).push(
                embyPcFadeRoute(context, (_) => const EmbyPcThumbnailJobPage()),
              ),
            ),
            const Divider(height: 1, indent: 72),
            ListTile(
              leading: const Icon(Icons.person_search_outlined),
              title: const Text('演员刮削'),
              subtitle: const Text('从 TMDB 补齐演员简介、生日与头像写真'),
              trailing: const Icon(Icons.chevron_right),
              // 刮削是联网操作，只在手动触发时执行，扫描流程不受影响。
              onTap: () => Navigator.of(context).push(
                embyPcFadeRoute(context, (_) => const EmbyPcPersonScrapePage()),
              ),
            ),
            const Divider(height: 1, indent: 72),
            const _SettingsSectionTitle('显示'),
            SwitchListTile(
              secondary: const Icon(Icons.dark_mode_outlined),
              title: const Text('深色模式'),
              subtitle: Text(_tm.brightness == Brightness.dark ? '已开启' : '已关闭'),
              value: _tm.brightness == Brightness.dark,
              onChanged: (v) =>
                  _tm.setBrightness(v ? Brightness.dark : Brightness.light),
            ),
            const Divider(height: 1, indent: 72),
            const _SettingsSectionTitle('颜色'),
            _ColorSettingTile(
              icon: Icons.format_color_fill_outlined,
              title: '背景色',
              color: _tm.backgroundColor,
              onTap: () => _pickColor(
                title: '选择背景色',
                initialColor: _tm.backgroundColor,
                onConfirmed: _tm.setBackgroundColor,
              ),
            ),
            const Divider(height: 1, indent: 72),
            _ColorSettingTile(
              icon: Icons.palette_outlined,
              title: '主题色',
              color: _tm.seedColor,
              onTap: () => _pickColor(
                title: '选择主题色',
                initialColor: _tm.seedColor,
                onConfirmed: _tm.setSeedColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSectionTitle extends StatelessWidget {
  final String title;

  const _SettingsSectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// 用同一行展示颜色用途、当前 HEX 值和可点击的颜色预览。
class _ColorSettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  const _ColorSettingTile({
    required this.icon,
    required this.title,
    required this.color,
    required this.onTap,
  });

  String _colorHex(Color value) {
    String component(int channel) => channel.toRadixString(16).padLeft(2, '0');
    return '#${component(value.red)}${component(value.green)}${component(value.blue)}'
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final hex = _colorHex(color);
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(hex),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: '$title $hex',
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}
