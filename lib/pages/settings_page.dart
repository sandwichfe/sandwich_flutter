import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import '../utils/theme_manager.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _tm = ThemeManager();

  void _pickColor() {
    Color temp = _tm.seedColor;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('选择主题色'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: temp,
            onColorChanged: (c) => temp = c,
            labelTypes: const [],
            pickerAreaHeightPercent: 0.8,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () {
              _tm.setSeedColor(temp);
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
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              title: const Text('深色模式'),
              value: _tm.brightness == Brightness.dark,
              onChanged: (v) => _tm.setBrightness(v ? Brightness.dark : Brightness.light),
            ),
            ListTile(
              title: const Text('主题色'),
              trailing: GestureDetector(
                onTap: _pickColor,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _tm.seedColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.grey),
                  ),
                ),
              ),
              onTap: _pickColor,
            ),
          ],
        ),
      ),
    );
  }
}
