part of 'emby_pc_page.dart';

enum _LibraryAction { editImages, scan, refreshMetadata }

// 工作台内部使用的导航项、排序弹窗和状态视图。
class _SidebarButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final button = Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Stack(
        children: [
          Material(
            color: active
                ? colors.primary.withValues(alpha: 0.11)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment: collapsed
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    SizedBox(width: collapsed ? 0 : 14),
                    Icon(
                      icon,
                      size: 20,
                      color: active ? colors.primary : colors.onSurfaceVariant,
                    ),
                    if (!collapsed) ...[
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            // 侧栏文字固定使用微软雅黑 UI，避免中英文混用不同字体。
                            fontFamily: 'Microsoft YaHei UI',
                            fontSize: 14,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (loading)
                        const SizedBox.square(
                          dimension: 13,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (showCount)
                        Container(
                          constraints: const BoxConstraints(minWidth: 24),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.onSurface.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            count == null ? '-' : '$count',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontFamily: 'Microsoft YaHei UI',
                              fontSize: 11,
                            ),
                          ),
                        ),
                      const SizedBox(width: 11),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (active)
            Positioned(
              left: 0,
              top: 9,
              bottom: 9,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
    return collapsed ? Tooltip(message: title, child: button) : button;
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
    final colors = Theme.of(context).colorScheme;
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
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onPressed,
            onHover: (hovered) => setState(() => _hovered = hovered),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: colors.outlineVariant),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: EmbyPcNetworkImage(
                            url: widget.library.hasPrimaryImage ? imageUrl : '',
                          ),
                        ),
                      ),
                      Positioned(
                        right: 8,
                        bottom: 8,
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
                                dimension: 38,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colors.surfaceContainerHighest
                                        .withValues(alpha: 0.94),
                                    shape: BoxShape.circle,
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x24000000),
                                        blurRadius: 5,
                                      ),
                                    ],
                                  ),
                                  child: Center(
                                    child: widget.busy
                                        ? const SizedBox.square(
                                            dimension: 17,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.more_horiz,
                                            size: 23,
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 9, 4, 3),
                  child: Text(
                    widget.library.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
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
      builder: (context) => _PersonEditorDialog(
        person: index == null ? null : _people[index],
      ),
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
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.toString())));
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
                              keyboardType: const TextInputType.numberWithOptions(
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

  factory _EditablePerson.fromJson(Map<String, dynamic> json) => _EditablePerson(
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
              validator: (value) => value == null || value.trim().isEmpty
                  ? '请输入名称'
                  : null,
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
  final date = '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
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

class _ItemImageSlot {
  final String type;
  final String label;

  const _ItemImageSlot(this.type, this.label);
}

const _itemImageSlots = [
  _ItemImageSlot('Primary', '海报'),
  _ItemImageSlot('Logo', '徽标'),
  _ItemImageSlot('Thumb', '缩略图'),
  _ItemImageSlot('Banner', '横幅图'),
  _ItemImageSlot('Disc', '光盘封面'),
  _ItemImageSlot('Art', '艺术图'),
];

// Emby 允许同一项目保存多张背景图，不能像其他类型一样压缩成单个槽位。
const _backdropImageSlot = _ItemImageSlot('Backdrop', '背景图');

class _ItemImagesDialog extends StatefulWidget {
  final EmbyPcItem item;

  const _ItemImagesDialog({required this.item});

  @override
  State<_ItemImagesDialog> createState() => _ItemImagesDialogState();
}

class _ItemImagesDialogState extends State<_ItemImagesDialog> {
  List<EmbyPcImageInfo> _images = const [];
  final Set<String> _busyTypes = {};
  bool _loading = true;
  bool _changed = false;
  int _imageRevision = 0;

  @override
  void initState() {
    super.initState();
    // 图像列表仅在用户打开编辑弹窗时按需获取。
    _loadImages();
  }

  Future<void> _loadImages({bool showProgress = true}) async {
    if (showProgress && mounted) setState(() => _loading = true);
    try {
      final images = await EmbyPcService.instance.getItemImages(
        widget.item.id,
      );
      if (!mounted) return;
      setState(() {
        _images = images;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage(error.toString());
    }
  }

  EmbyPcImageInfo? _imageFor(String type) {
    for (final image in _images) {
      if (image.type == type) return image;
    }
    return null;
  }

  List<EmbyPcImageInfo> _imagesFor(String type) {
    final images = _images.where((image) => image.type == type).toList();
    images.sort((a, b) => a.index.compareTo(b.index));
    return images;
  }

  Future<void> _upload(
    _ItemImageSlot slot,
    EmbyPcImageInfo? currentImage,
  ) async {
    if (_busyTypes.contains(slot.type)) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      _showMessage('无法读取所选图片');
      return;
    }

    setState(() => _busyTypes.add(slot.type));
    try {
      await EmbyPcService.instance.uploadItemImage(
        widget.item.id,
        type: slot.type,
        index: currentImage?.index,
        bytes: bytes,
        contentType: _imageContentType(file.extension),
      );
      _changed = true;
      _imageRevision++;
      await _loadImages(showProgress: false);
      if (mounted) _showMessage('${slot.label}上传成功');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busyTypes.remove(slot.type));
    }
  }

  Future<void> _delete(_ItemImageSlot slot, EmbyPcImageInfo image) async {
    if (_busyTypes.contains(slot.type)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除${slot.label}？'),
        content: const Text('删除后无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyTypes.add(slot.type));
    try {
      await EmbyPcService.instance.deleteItemImage(
        widget.item.id,
        type: image.type,
        index: image.index,
      );
      _changed = true;
      _imageRevision++;
      await _loadImages(showProgress: false);
      if (mounted) _showMessage('${slot.label}已删除');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busyTypes.remove(slot.type));
    }
  }

  String _imageContentType(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      default:
        return 'image/jpeg';
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 32).clamp(300.0, 1000.0).toDouble();
    final dialogHeight = (size.height - 32).clamp(420.0, 760.0).toDouble();
    final backdropImages = _imagesFor(_backdropImageSlot.type);
    const gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 230,
      mainAxisExtent: 224,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
    );
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
                    onPressed: () => Navigator.pop(context, _changed),
                    icon: const Icon(Icons.close),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '编辑图像 · ${widget.item.name}',
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
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                          sliver: SliverGrid.builder(
                            gridDelegate: gridDelegate,
                            itemCount: _itemImageSlots.length,
                            itemBuilder: (context, index) {
                              final slot = _itemImageSlots[index];
                              return _buildImageSlot(
                                slot,
                                _imageFor(slot.type),
                              );
                            },
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                          sliver: SliverToBoxAdapter(
                            child: Text(
                              _backdropImageSlot.label,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                          sliver: SliverGrid.builder(
                            gridDelegate: gridDelegate,
                            itemCount: backdropImages.length + 1,
                            itemBuilder: (context, index) {
                              if (index == backdropImages.length) {
                                return _buildAddBackdropSlot();
                              }
                              final image = backdropImages[index];
                              final title = image.fileName.trim().isEmpty
                                  ? '${_backdropImageSlot.label} ${index + 1}'
                                  : image.fileName;
                              return _buildImageSlot(
                                _backdropImageSlot,
                                image,
                                title: title,
                              );
                            },
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // 新增入口作为背景图列表的最后一格，位置不会随图片数量变化而产生歧义。
  Widget _buildAddBackdropSlot() {
    final colors = Theme.of(context).colorScheme;
    final busy = _busyTypes.contains(_backdropImageSlot.type);
    return Semantics(
      button: true,
      enabled: !busy,
      label: '添加背景图',
      child: Material(
        color: colors.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : () => _upload(_backdropImageSlot, null),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.add, size: 30, color: colors.primary),
                ),
                const SizedBox(height: 12),
                Text(
                  busy ? '处理中...' : '添加背景图',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageSlot(
    _ItemImageSlot slot,
    EmbyPcImageInfo? image, {
    String? title,
  }) {
    final colors = Theme.of(context).colorScheme;
    final busy = _busyTypes.contains(slot.type);
    final imageUrl = image == null
        ? ''
        : EmbyPcService.instance.imageUrl(
            widget.item.id,
            type: image.type,
            index: image.index,
            maxWidth: 520,
            cacheKey: '$_imageRevision',
          );
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: image == null
                ? Center(
                    child: Icon(
                      Icons.image_outlined,
                      size: 36,
                      color: colors.onSurfaceVariant,
                    ),
                  )
                : EmbyPcNetworkImage(url: imageUrl),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 6, 7),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title ?? slot.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (image?.dimensions.isNotEmpty == true)
                        Text(
                          image!.dimensions,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else ...[
                  IconButton(
                    tooltip: image == null
                        ? '上传${slot.label}'
                        : '替换${slot.label}',
                    onPressed: () => _upload(slot, image),
                    icon: Icon(
                      image == null
                          ? Icons.add_circle_outline
                          : Icons.upload_outlined,
                    ),
                  ),
                  if (image != null)
                    IconButton(
                      tooltip: '删除${slot.label}',
                      onPressed: () => _delete(slot, image),
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarSectionTitle extends StatelessWidget {
  final String title;

  const _SidebarSectionTitle(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
    child: Text(
      title,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFamily: 'Microsoft YaHei UI',
        fontSize: 12,
        // 小字号使用中等字重，避免微软雅黑 UI 的笔画显得拥挤。
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

class _LibraryOrderDialog extends StatefulWidget {
  final List<EmbyPcItem> libraries;

  const _LibraryOrderDialog({required this.libraries});

  @override
  State<_LibraryOrderDialog> createState() => _LibraryOrderDialogState();
}

class _LibraryOrderDialogState extends State<_LibraryOrderDialog> {
  late final List<EmbyPcItem> _libraries = List.of(widget.libraries);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('调整媒体库顺序'),
    content: SizedBox(
      width: 420,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 500),
        child: _libraries.isEmpty
            ? const Text('暂无媒体库')
            : ReorderableListView.builder(
                shrinkWrap: true,
                itemCount: _libraries.length,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final item = _libraries.removeAt(oldIndex);
                    _libraries.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, index) => ListTile(
                  key: ValueKey(_libraries[index].id),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(_libraries[index].name),
                  trailing: const Icon(Icons.drag_handle),
                ),
              ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _libraries),
        child: const Text('保存'),
      ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.movie_filter_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        const Text('没有找到媒体'),
      ],
    ),
  );
}

class _WorkspaceError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _WorkspaceError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off_outlined, size: 52),
        const SizedBox(height: 12),
        Text(message),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      ],
    ),
  );
}
