part of 'emby_pc_page.dart';

enum _LibraryAction { editImages, scan, refreshMetadata }

// 工作台内部使用的导航项、排序弹窗和状态视图。
class _SidebarButton extends StatefulWidget {
  final IconData icon;
  final String title;
  final int? count;
  final bool showCount;
  final bool active;
  final bool loading;
  final bool collapsed;
  final VoidCallback onPressed;

  const _SidebarButton({
    required this.icon,
    required this.title,
    required this.count,
    this.showCount = true,
    required this.active,
    this.loading = false,
    this.collapsed = false,
    required this.onPressed,
  });

  @override
  State<_SidebarButton> createState() => _SidebarButtonState();
}

class _SidebarButtonState extends State<_SidebarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    final active = widget.active;
    final highlight = active || _hovered;
    final button = Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: BoxDecoration(
              // 选中项用强调色渐变填充，悬浮只做轻微提亮。
              gradient: active ? skin.navActiveFill : null,
              color: !active && _hovered
                  ? skin.scheme.onSurface.withValues(alpha: 0.05)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active ? skin.tint(0.26) : Colors.transparent,
              ),
            ),
            child: InkWell(
              onTap: widget.onPressed,
              hoverColor: Colors.transparent,
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment: widget.collapsed
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    SizedBox(width: widget.collapsed ? 0 : 12),
                    Icon(
                      widget.icon,
                      size: 19,
                      color: active
                          ? skin.accent
                          : (highlight
                                ? skin.scheme.onSurface
                                : skin.textSecondary),
                    ),
                    if (!widget.collapsed) ...[
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            // 侧栏文字固定使用微软雅黑 UI，避免中英文混用不同字体。
                            fontFamily: 'Microsoft YaHei UI',
                            fontSize: 13.5,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: active
                                ? skin.scheme.onSurface
                                : (highlight
                                      ? skin.scheme.onSurface
                                      : skin.textSecondary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (widget.loading)
                        SizedBox.square(
                          dimension: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: skin.accent,
                          ),
                        )
                      else if (widget.showCount)
                        Container(
                          constraints: const BoxConstraints(minWidth: 24),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: active
                                ? skin.tint(0.22)
                                : skin.scheme.onSurface.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            widget.count == null ? '-' : '${widget.count}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: active ? skin.accent : skin.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      const SizedBox(width: 10),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return widget.collapsed
        ? Tooltip(message: widget.title, child: button)
        : button;
  }
}

// 首页媒体库使用横向封面入口，点击后仍复用现有媒体库详情加载逻辑。
class _HomeLibraryTile extends StatefulWidget {
  final EmbyPcItem library;
  final bool busy;
  final VoidCallback onPressed;
  final ValueChanged<_LibraryAction> onAction;

  const _HomeLibraryTile({
    required this.library,
    required this.busy,
    required this.onPressed,
    required this.onAction,
  });

  @override
  State<_HomeLibraryTile> createState() => _HomeLibraryTileState();
}

class _HomeLibraryTileState extends State<_HomeLibraryTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    final imageUrl = EmbyPcService.instance.imageUrl(
      widget.library.id,
      type: 'Primary',
      maxWidth: 640,
      cacheKey: widget.library.primaryImageTag.isNotEmpty
          ? widget.library.primaryImageTag
          : widget.library.imageTags['Primary']?.toString() ?? '',
    );
    return SizedBox(
      width: 246,
      child: Semantics(
        button: true,
        label: '打开媒体库 ${widget.library.name}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _hovered
                    ? skin.tint(0.55)
                    : skin.hairline.withValues(alpha: 0.7),
              ),
              boxShadow: [
                BoxShadow(
                  color: _hovered
                      ? skin.tint(0.28)
                      : Colors.black.withValues(alpha: skin.dark ? 0.34 : 0.08),
                  blurRadius: _hovered ? 26 : 14,
                  offset: Offset(0, _hovered ? 12 : 6),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onPressed,
                hoverColor: Colors.transparent,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AnimatedScale(
                        scale: _hovered ? 1.04 : 1,
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOut,
                        child: EmbyPcNetworkImage(
                          url: widget.library.hasPrimaryImage ? imageUrl : '',
                        ),
                      ),
                      // 底部渐变压暗，保证白色库名在任何封面上都可读。
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x00000000),
                                Color(0x22000000),
                                Color(0xE6000000),
                              ],
                              stops: [0.30, 0.62, 1],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 16,
                        right: 12,
                        bottom: 12,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.library.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Microsoft YaHei UI',
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  shadows: [
                                    Shadow(
                                      color: Color(0x99000000),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right_rounded,
                              size: 20,
                              color: Color(0xCCFFFFFF),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        right: 10,
                        top: 10,
                        // 卡片操作仅在鼠标悬浮时显示，隐藏期间禁用点击避免误触。
                        child: IgnorePointer(
                          ignoring: !_hovered,
                          child: AnimatedOpacity(
                            opacity: _hovered ? 1 : 0,
                            duration: const Duration(milliseconds: 180),
                            child: PopupMenuButton<_LibraryAction>(
                              enabled: !widget.busy,
                              tooltip: '媒体库操作',
                              onSelected: widget.onAction,
                              padding: EdgeInsets.zero,
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: _LibraryAction.editImages,
                                  child: _LibraryMenuEntry(
                                    icon: Icons.image_outlined,
                                    label: '编辑图像',
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _LibraryAction.scan,
                                  child: _LibraryMenuEntry(
                                    icon: Icons.manage_search_outlined,
                                    label: '扫描媒体库',
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _LibraryAction.refreshMetadata,
                                  child: _LibraryMenuEntry(
                                    icon: Icons.refresh_outlined,
                                    label: '刷新元数据',
                                  ),
                                ),
                              ],
                              // 触发按钮单独固定尺寸，菜单宽度继续按菜单项内容自适应。
                              child: SizedBox.square(
                                dimension: 34,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.22,
                                      ),
                                    ),
                                  ),
                                  child: Center(
                                    child: widget.busy
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.more_horiz_rounded,
                                            size: 21,
                                            color: Colors.white,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryMenuEntry extends StatelessWidget {
  final IconData icon;
  final String label;

  const _LibraryMenuEntry({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
  );
}

class _ItemMetadataDialog extends StatefulWidget {
  final String itemId;
  final Map<String, dynamic> item;

  const _ItemMetadataDialog({required this.itemId, required this.item});

  @override
  State<_ItemMetadataDialog> createState() => _ItemMetadataDialogState();
}

class _ItemMetadataDialogState extends State<_ItemMetadataDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _dateCreatedController;
  late final TextEditingController _ratingController;
  late final TextEditingController _overviewController;
  late final TextEditingController _premiereDateController;
  late final TextEditingController _imdbController;
  late final TextEditingController _tmdbController;
  late final TextEditingController _tvdbController;
  late final TextEditingController _genresController;
  late final TextEditingController _tagsController;
  late List<_EditablePerson> _people;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final providerIds = _map(widget.item['ProviderIds']);
    _titleController = TextEditingController(text: _text(widget.item['Name']));
    _dateCreatedController = TextEditingController(
      text: _formatDate(_text(widget.item['DateCreated']), includeTime: true),
    );
    _ratingController = TextEditingController(
      text: _numberText(widget.item['CommunityRating']),
    );
    _overviewController = TextEditingController(
      text: _text(widget.item['Overview']),
    );
    _premiereDateController = TextEditingController(
      text: _formatDate(_text(widget.item['PremiereDate'])),
    );
    _imdbController = TextEditingController(text: _text(providerIds['Imdb']));
    _tmdbController = TextEditingController(
      text: _text(providerIds['Tmdb'] ?? providerIds['MovieDb']),
    );
    _tvdbController = TextEditingController(text: _text(providerIds['Tvdb']));
    _genresController = TextEditingController(
      text: _stringList(widget.item['Genres']).join(', '),
    );
    _tagsController = TextEditingController(
      text: _stringList(widget.item['Tags']).join(', '),
    );
    _people = _mapList(
      widget.item['People'],
    ).map(_EditablePerson.fromJson).toList();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _dateCreatedController.dispose();
    _ratingController.dispose();
    _overviewController.dispose();
    _premiereDateController.dispose();
    _imdbController.dispose();
    _tmdbController.dispose();
    _tvdbController.dispose();
    _genresController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(
    TextEditingController controller, {
    bool includeTime = false,
  }) async {
    final current = DateTime.tryParse(controller.text.trim()) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    var selected = date;
    if (includeTime) {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(current),
      );
      if (time == null || !mounted) return;
      selected = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
        current.second,
      );
    }
    setState(() {
      controller.text = _formatLocalDate(selected, includeTime: includeTime);
    });
  }

  Future<void> _editPerson([int? index]) async {
    final person = await showDialog<_EditablePerson>(
      context: context,
      builder: (context) =>
          _PersonEditorDialog(person: index == null ? null : _people[index]),
    );
    if (person == null || !mounted) return;
    setState(() {
      if (index == null) {
        _people.add(person);
      } else {
        _people[index] = person;
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _saving) return;
    setState(() => _saving = true);
    final updated = Map<String, dynamic>.from(widget.item);
    final providerIds = _map(widget.item['ProviderIds']);
    _setProviderId(providerIds, 'Imdb', _imdbController.text);
    _setProviderId(providerIds, 'Tmdb', _tmdbController.text);
    providerIds.remove('MovieDb');
    _setProviderId(providerIds, 'Tvdb', _tvdbController.text);
    final premiereDate = DateTime.tryParse(_premiereDateController.text.trim());
    updated
      ..['Name'] = _titleController.text.trim()
      ..['DateCreated'] = _isoDate(
        _dateCreatedController.text,
        includeTime: true,
      )
      ..['CommunityRating'] = double.tryParse(_ratingController.text.trim())
      ..['Overview'] = _overviewController.text.trim()
      ..['PremiereDate'] = _isoDate(_premiereDateController.text)
      // 发行年份是发行日期的派生字段，两者需要同步保存。
      ..['ProductionYear'] = premiereDate?.year
      ..['ProviderIds'] = providerIds
      ..['Genres'] = _splitValues(_genresController.text)
      ..['People'] = _people.map((person) => person.toJson()).toList()
      ..['Tags'] = _splitValues(_tagsController.text);
    try {
      await EmbyPcService.instance.updateItemMetadata(widget.itemId, updated);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      EmbyPcToast.show(context, error.toString(), type: EmbyPcToastType.error);
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 32).clamp(320.0, 920.0).toDouble();
    final dialogHeight = (size.height - 32).clamp(460.0, 820.0).toDouble();
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 20, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '关闭',
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '编辑元数据 · ${_titleController.text}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: AbsorbPointer(
                absorbing: _saving,
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final fieldWidth = constraints.maxWidth >= 700
                            ? (constraints.maxWidth - 16) / 2
                            : constraints.maxWidth;
                        return Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            SizedBox(
                              width: fieldWidth,
                              child: TextFormField(
                                controller: _titleController,
                                decoration: const InputDecoration(
                                  labelText: '标题',
                                  border: OutlineInputBorder(),
                                ),
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                    ? '请输入标题'
                                    : null,
                              ),
                            ),
                            SizedBox(
                              width: fieldWidth,
                              child: _dateField(
                                controller: _dateCreatedController,
                                label: '加入日期',
                                includeTime: true,
                              ),
                            ),
                            SizedBox(
                              width: fieldWidth,
                              child: TextFormField(
                                controller: _ratingController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: '影视评分',
                                  hintText: '0 - 10',
                                  border: OutlineInputBorder(),
                                ),
                                validator: _validateRating,
                              ),
                            ),
                            SizedBox(
                              width: fieldWidth,
                              child: _dateField(
                                controller: _premiereDateController,
                                label: '发行日期',
                              ),
                            ),
                            SizedBox(
                              width: constraints.maxWidth,
                              child: TextFormField(
                                controller: _overviewController,
                                minLines: 4,
                                maxLines: 7,
                                decoration: const InputDecoration(
                                  labelText: '概要',
                                  alignLabelWithHint: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: fieldWidth,
                              child: TextFormField(
                                controller: _imdbController,
                                decoration: const InputDecoration(
                                  labelText: 'IMDb',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: fieldWidth,
                              child: TextFormField(
                                controller: _tmdbController,
                                decoration: const InputDecoration(
                                  labelText: 'TMDB / MovieDB',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: fieldWidth,
                              child: TextFormField(
                                controller: _tvdbController,
                                decoration: const InputDecoration(
                                  labelText: 'TVDB',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: fieldWidth,
                              child: TextFormField(
                                controller: _genresController,
                                decoration: const InputDecoration(
                                  labelText: '类型',
                                  hintText: '多个类型用逗号分隔',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: constraints.maxWidth,
                              child: _buildPeopleSection(context),
                            ),
                            SizedBox(
                              width: constraints.maxWidth,
                              child: TextFormField(
                                controller: _tagsController,
                                decoration: const InputDecoration(
                                  labelText: '标签',
                                  hintText: '多个标签用逗号分隔',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined, size: 19),
                    label: Text(_saving ? '保存中...' : '保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateField({
    required TextEditingController controller,
    required String label,
    bool includeTime = false,
  }) => TextFormField(
    controller: controller,
    readOnly: true,
    onTap: _saving
        ? null
        : () => _pickDate(controller, includeTime: includeTime),
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (controller.text.isNotEmpty)
            IconButton(
              tooltip: '清除$label',
              onPressed: _saving
                  ? null
                  : () => setState(() => controller.clear()),
              icon: const Icon(Icons.clear, size: 19),
            ),
          IconButton(
            tooltip: '选择$label',
            onPressed: _saving
                ? null
                : () => _pickDate(controller, includeTime: includeTime),
            icon: const Icon(Icons.calendar_today_outlined, size: 19),
          ),
        ],
      ),
    ),
  );

  Widget _buildPeopleSection(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '演员',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : _editPerson,
                  icon: const Icon(Icons.add, size: 19),
                  label: const Text('添加'),
                ),
              ],
            ),
          ),
          if (_people.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 18),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('暂无演员'),
              ),
            )
          else
            ...List.generate(_people.length, (index) {
              final person = _people[index];
              return Column(
                children: [
                  const Divider(height: 1),
                  ListTile(
                    title: Text(person.name),
                    subtitle: Text(
                      [
                        person.role,
                        _personTypeLabel(person.type),
                      ].where((value) => value.isNotEmpty).join(' · '),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '编辑演员',
                          onPressed: _saving ? null : () => _editPerson(index),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          tooltip: '移除演员',
                          onPressed: _saving
                              ? null
                              : () => setState(() => _people.removeAt(index)),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
        ],
      ),
    );
  }

  String? _validateRating(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final rating = double.tryParse(text);
    if (rating == null || rating < 0 || rating > 10) {
      return '请输入 0 到 10 之间的评分';
    }
    return null;
  }
}

class _EditablePerson {
  final Map<String, dynamic> source;
  final String name;
  final String role;
  final String type;

  const _EditablePerson({
    required this.source,
    required this.name,
    required this.role,
    required this.type,
  });

  factory _EditablePerson.fromJson(Map<String, dynamic> json) =>
      _EditablePerson(
        source: Map<String, dynamic>.from(json),
        name: _text(json['Name']),
        role: _text(json['Role']),
        type: _text(json['Type']).isEmpty ? 'Actor' : _text(json['Type']),
      );

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(source)
    ..['Name'] = name
    ..['Role'] = role
    ..['Type'] = type;
}

class _PersonEditorDialog extends StatefulWidget {
  final _EditablePerson? person;

  const _PersonEditorDialog({this.person});

  @override
  State<_PersonEditorDialog> createState() => _PersonEditorDialogState();
}

class _PersonEditorDialogState extends State<_PersonEditorDialog> {
  static const _personTypes = [
    'Actor',
    'Director',
    'Writer',
    'Producer',
    'GuestStar',
    'Composer',
    'Conductor',
    'Lyricist',
  ];
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _roleController;
  late String _type;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.person?.name ?? '');
    _roleController = TextEditingController(text: widget.person?.role ?? '');
    final initialType = widget.person?.type ?? 'Actor';
    _type = _personTypes.contains(initialType) ? initialType : 'Actor';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _roleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.person == null ? '添加演员' : '编辑演员'),
    content: SizedBox(
      width: 460,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '名称',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入名称' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _roleController,
              decoration: const InputDecoration(
                labelText: '角色',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: '类型',
                border: OutlineInputBorder(),
              ),
              items: _personTypes
                  .map(
                    (type) => DropdownMenuItem(
                      value: type,
                      child: Text(_personTypeLabel(type)),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _type = value);
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!_formKey.currentState!.validate()) return;
          Navigator.pop(
            context,
            _EditablePerson(
              source: widget.person?.source ?? const {},
              name: _nameController.text.trim(),
              role: _roleController.text.trim(),
              type: _type,
            ),
          );
        },
        child: const Text('确定'),
      ),
    ],
  );
}

Map<String, dynamic> _map(dynamic value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};

List<Map<String, dynamic>> _mapList(dynamic value) => value is List
    ? value.whereType<Map>().map(_map).toList()
    : <Map<String, dynamic>>[];

List<String> _stringList(dynamic value) => value is List
    ? value
          .map((entry) => entry.toString().trim())
          .where((entry) => entry.isNotEmpty)
          .toList()
    : <String>[];

String _text(dynamic value) => value?.toString().trim() ?? '';

String _numberText(dynamic value) {
  if (value is num) {
    return value == value.roundToDouble() ? '${value.toInt()}' : '$value';
  }
  return _text(value);
}

String _formatDate(String value, {bool includeTime = false}) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return '';
  return _formatLocalDate(parsed.toLocal(), includeTime: includeTime);
}

String _formatLocalDate(DateTime value, {bool includeTime = false}) {
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  final date =
      '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  if (!includeTime) return date;
  return '$date ${twoDigits(value.hour)}:${twoDigits(value.minute)}:'
      '${twoDigits(value.second)}';
}

String? _isoDate(String value, {bool includeTime = false}) {
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) return null;
  if (includeTime) return parsed.toUtc().toIso8601String();
  return DateTime.utc(parsed.year, parsed.month, parsed.day).toIso8601String();
}

List<String> _splitValues(String value) => value
    .split(RegExp(r'[,，]'))
    .map((entry) => entry.trim())
    .where((entry) => entry.isNotEmpty)
    .toSet()
    .toList();

void _setProviderId(Map<String, dynamic> ids, String key, String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    ids.remove(key);
  } else {
    ids[key] = normalized;
  }
}

String _personTypeLabel(String type) => switch (type) {
  'Actor' => '演员',
  'Director' => '导演',
  'Writer' => '编剧',
  'Producer' => '制片',
  'GuestStar' => '客串明星',
  'Composer' => '作曲家',
  'Conductor' => '指挥',
  'Lyricist' => '作词人',
  _ => type,
};

class _MetadataRefreshOptions {
  final String mode;
  final bool replaceImages;
  final bool replaceThumbnailImages;

  const _MetadataRefreshOptions({
    required this.mode,
    required this.replaceImages,
    required this.replaceThumbnailImages,
  });
}

class _MetadataRefreshDialog extends StatefulWidget {
  final String name;

  const _MetadataRefreshDialog({required this.name});

  @override
  State<_MetadataRefreshDialog> createState() => _MetadataRefreshDialogState();
}

class _MetadataRefreshDialogState extends State<_MetadataRefreshDialog> {
  String _mode = 'Default';
  bool _replaceImages = false;
  bool _replaceThumbnailImages = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('刷新元数据 · ${widget.name}'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: '刷新模式',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'Default', child: Text('搜索缺少的元数据')),
              DropdownMenuItem(value: 'FullRefresh', child: Text('替换所有元数据')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _mode = value);
            },
          ),
          const SizedBox(height: 14),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('替换现有图像'),
            subtitle: const Text('删除现有图像，并根据媒体库选项重新下载。'),
            value: _replaceImages,
            onChanged: (value) => setState(() => _replaceImages = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('替换现有视频预览缩略图'),
            subtitle: const Text('删除已有视频预览缩略图并重新生成。'),
            value: _replaceThumbnailImages,
            onChanged: (value) =>
                setState(() => _replaceThumbnailImages = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        onPressed: () => Navigator.pop(
          context,
          _MetadataRefreshOptions(
            mode: _mode,
            replaceImages: _replaceImages,
            replaceThumbnailImages: _replaceThumbnailImages,
          ),
        ),
        icon: const Icon(Icons.refresh, size: 19),
        label: const Text('刷新'),
      ),
    ],
  );
}

class _SidebarSectionTitle extends StatelessWidget {
  final String title;

  const _SidebarSectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Text(
        title,
        style: TextStyle(
          color: skin.textTertiary,
          fontFamily: 'Microsoft YaHei UI',
          fontSize: 11,
          letterSpacing: 1.2,
          // 小字号使用中等字重，避免微软雅黑 UI 的笔画显得拥挤。
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  // 有筛选条件时，空列表多半是筛出来的，需要提供一键恢复入口。
  final bool hasFilters;
  final VoidCallback onClearFilters;

  const _EmptyState({required this.hasFilters, required this.onClearFilters});

  @override
  Widget build(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [skin.tint(0.20), skin.tint(0.04)],
              ),
              shape: BoxShape.circle,
              border: Border.all(color: skin.hairline),
            ),
            child: Icon(
              Icons.movie_filter_outlined,
              size: 32,
              color: skin.accent,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '没有找到媒体',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: skin.scheme.onSurface,
            ),
          ),
          if (hasFilters) ...[
            const SizedBox(height: 6),
            Text(
              '当前筛选条件没有匹配到内容',
              style: TextStyle(fontSize: 12, color: skin.textSecondary),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onClearFilters,
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: const Text('清除筛选'),
            ),
          ],
        ],
      ),
    );
  }
}

// 首页主视觉：整块背景图 + 左侧信息层，点按进入详情，播放按钮直接起播。
class _HomeHeroBanner extends StatefulWidget {
  final EmbyPcItem item;
  final VoidCallback onPlay;
  final VoidCallback onOpen;
  final VoidCallback? onFavorite;
  final bool favoriteBusy;

  const _HomeHeroBanner({
    required this.item,
    required this.onPlay,
    required this.onOpen,
    this.onFavorite,
    this.favoriteBusy = false,
  });

  @override
  State<_HomeHeroBanner> createState() => _HomeHeroBannerState();
}

class _HomeHeroBannerState extends State<_HomeHeroBanner> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final progress = item.runTimeTicks <= 0
        ? 0.0
        : (item.playbackPositionTicks / item.runTimeTicks)
              .clamp(0.0, 1.0)
              .toDouble();
    final imageUrl = EmbyPcService.instance.imageUrlForItem(
      item,
      type: 'Backdrop',
      maxWidth: 1600,
    );
    final meta = <String>[
      if (item.productionYear != null) '${item.productionYear}',
      if (item.runtimeLabel.isNotEmpty) item.runtimeLabel,
      ...item.genres.take(2),
    ];
    // 窄屏收窄留白并把标题降级，避免主视觉在小窗口里只剩半行字。
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 12 : 28, 14, narrow ? 12 : 28, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 高度跟随窗口宽度，宽屏更像影院大屏，窄窗口也保留足够文字空间。
          final height = narrow
              ? (constraints.maxWidth * 0.66).clamp(280.0, 340.0)
              : (constraints.maxWidth * 0.30).clamp(336.0, 424.0);
          final compactHero = narrow || height < 380;
          return SizedBox(
            height: height,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                onTap: widget.onOpen,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AnimatedScale(
                        scale: _hovered ? 1.02 : 1,
                        duration: const Duration(milliseconds: 420),
                        curve: Curves.easeOut,
                        child: EmbyPcNetworkImage(url: imageUrl),
                      ),
                      // 左侧压暗保证文字可读，右侧保留画面细节。
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Color(0xF20A0C10),
                              Color(0x8C0A0C10),
                              Color(0x000A0C10),
                            ],
                            stops: [0, 0.48, 1],
                          ),
                        ),
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Color(0xD90A0C10), Color(0x000A0C10)],
                            stops: [0, 0.66],
                          ),
                        ),
                      ),
                      Positioned(
                        left: narrow ? 18 : 40,
                        right: narrow ? 18 : 40,
                        bottom: narrow ? 22 : 34,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _HeroTag(
                                  label: progress > 0
                                      ? '继续观看'
                                      : _heroTypeLabel(item.type),
                                  accent: progress > 0,
                                ),
                                if (item.communityRating != null) ...[
                                  const SizedBox(width: 12),
                                  const Icon(
                                    Icons.star_rounded,
                                    size: 16,
                                    color: Color(0xFFF5B942),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    item.communityRating!.toStringAsFixed(1),
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFF7C863),
                                    ),
                                  ),
                                ],
                                if (item.officialRating.isNotEmpty) ...[
                                  const SizedBox(width: 10),
                                  Text(
                                    item.officialRating,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white.withValues(
                                        alpha: 0.8,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Microsoft YaHei UI',
                                fontSize: compactHero ? 28 : 34,
                                fontWeight: FontWeight.w800,
                                height: 1.18,
                                letterSpacing: 0.5,
                                color: Colors.white,
                                shadows: const [
                                  Shadow(
                                    color: Color(0x99000000),
                                    blurRadius: 16,
                                    offset: Offset(0, 4),
                                  ),
                                ],
                              ),
                            ),
                            if (meta.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                meta.join('  ·  '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  letterSpacing: 0.3,
                                  color: Colors.white.withValues(alpha: 0.78),
                                ),
                              ),
                            ],
                            if (!narrow && item.overview.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 580,
                                ),
                                child: Text(
                                  item.overview.replaceAll('\n', ' '),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.55,
                                    color: Colors.white.withValues(alpha: 0.72),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            Wrap(
                              spacing: 12,
                              runSpacing: 10,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                FilledButton.icon(
                                  onPressed: widget.onPlay,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: const Color(0xFF12151A),
                                    minimumSize: const Size(140, 46),
                                    shape: const StadiumBorder(),
                                    textStyle: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 24,
                                  ),
                                  label: Text(progress > 0 ? '继续播放' : '播放正片'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: widget.onOpen,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(0, 46),
                                    backgroundColor: Colors.white.withValues(
                                      alpha: 0.10,
                                    ),
                                    side: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.34,
                                      ),
                                    ),
                                    shape: const StadiumBorder(),
                                    textStyle: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.info_outline_rounded,
                                    size: 19,
                                  ),
                                  label: const Text('详情'),
                                ),
                                if (widget.onFavorite != null)
                                  IconButton(
                                    tooltip: item.isFavorite ? '取消收藏' : '收藏',
                                    onPressed: widget.favoriteBusy
                                        ? null
                                        : widget.onFavorite,
                                    style: IconButton.styleFrom(
                                      minimumSize: const Size.square(46),
                                      backgroundColor: Colors.white.withValues(
                                        alpha: 0.10,
                                      ),
                                      foregroundColor: item.isFavorite
                                          ? const Color(0xFFFF5C7A)
                                          : Colors.white,
                                      side: BorderSide(
                                        color: Colors.white.withValues(
                                          alpha: 0.28,
                                        ),
                                      ),
                                    ),
                                    icon: widget.favoriteBusy
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : Icon(
                                            item.isFavorite
                                                ? Icons.favorite_rounded
                                                : Icons.favorite_border_rounded,
                                            size: 21,
                                          ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (progress > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 3,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.18,
                            ),
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _heroTypeLabel(String type) => switch (type) {
  'Movie' => '电影',
  'Series' => '剧集',
  'Video' => '视频',
  'BoxSet' => '合集',
  '' => '推荐',
  _ => '推荐',
};

// 主视觉左上角的小标签，用作类型或“继续观看”提示。
class _HeroTag extends StatelessWidget {
  final String label;
  final bool accent;

  const _HeroTag({required this.label, this.accent = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: accent
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.92)
          : Colors.black.withValues(alpha: 0.34),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: Colors.white,
      ),
    ),
  );
}

class _WorkspaceError extends StatelessWidget {
  final String message;
  // 原始异常文本：单行会撑破布局，改成可换行、可复制的小字。
  final String detail;
  final VoidCallback onRetry;
  // 初始化失败时整个工作台被错误页替换，侧栏与账号菜单一并消失，
  // 这里必须留一个回登录页的出口，否则服务器长期不可达时改不了地址、退不出去。
  final VoidCallback? onLogout;

  const _WorkspaceError({
    required this.message,
    this.detail = '',
    required this.onRetry,
    this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      // 窄窗口下长文案需要换行并允许整体滚动，避免横向溢出。
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 52),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 8),
                SelectableText(
                  detail,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: colors.outline),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                  if (onLogout != null)
                    TextButton.icon(
                      onPressed: onLogout,
                      icon: const Icon(Icons.login),
                      label: const Text('返回登录'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
