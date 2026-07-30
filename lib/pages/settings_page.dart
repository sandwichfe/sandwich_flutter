import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'emby-pc/emby_pc_service.dart';
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
      builder:
          (_) => AlertDialog(
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: _tm,
        builder:
            (context, _) => ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const _SettingsSectionTitle('账户'),
                ListTile(
                  leading: CircleAvatar(
                    radius: 20,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    foregroundImage: NetworkImage(
                      EmbyPcService.instance.userAvatarUrl(),
                    ),
                    onForegroundImageError: (_, _) {},
                    child: const Icon(Icons.person_outline),
                  ),
                  title: const Text('用户信息'),
                  subtitle: Text(
                    EmbyPcService.instance.currentUserName.isEmpty
                        ? '修改用户头像'
                        : EmbyPcService.instance.currentUserName,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  // 返回设置页时刷新头像 URL，及时显示刚上传的新头像。
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const UserProfilePage(),
                      ),
                    );
                    if (mounted) setState(() {});
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
                const _SettingsSectionTitle('显示'),
                SwitchListTile(
                  secondary: const Icon(Icons.dark_mode_outlined),
                  title: const Text('深色模式'),
                  subtitle: Text(
                    _tm.brightness == Brightness.dark ? '已开启' : '已关闭',
                  ),
                  value: _tm.brightness == Brightness.dark,
                  onChanged:
                      (v) => _tm.setBrightness(
                        v ? Brightness.dark : Brightness.light,
                      ),
                ),
                const Divider(height: 1, indent: 72),
                const _SettingsSectionTitle('颜色'),
                _ColorSettingTile(
                  icon: Icons.format_color_fill_outlined,
                  title: '背景色',
                  color: _tm.backgroundColor,
                  onTap:
                      () => _pickColor(
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
                  onTap:
                      () => _pickColor(
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
