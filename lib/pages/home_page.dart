import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/app_settings.dart';
import '../models/photo.dart';
import '../models/photo_filter.dart';
import '../services/database_service.dart';
import '../services/scanner_service.dart';
import '../widgets/filter_panel.dart';
import '../widgets/folder_breadcrumb.dart';
import '../widgets/folder_grid.dart';
import '../widgets/folder_sidebar.dart';
import '../widgets/photo_detail_panel.dart';
import '../widgets/photo_grid.dart';
import '../widgets/settings_dialog.dart';

/// 主区域的两种浏览方式。
enum ViewMode {
  photos('照片', Icons.photo_outlined),
  folders('文件夹', Icons.folder_outlined);

  const ViewMode(this.label, this.icon);

  final String label;
  final IconData icon;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _pageSize = 120;

  final DatabaseService _db = DatabaseService.instance;
  late final ScannerService _scanner = ScannerService(_db);

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  /// 已索引的根目录。
  List<String> _rootFolders = const [];
  Map<String, int> _folderCounts = const {};
  int _totalCount = 0;

  /// 当前浏览的目录；null 表示"全部照片"。
  String? _scopePath;
  ViewMode _viewMode = ViewMode.photos;

  final List<Photo> _photos = [];
  List<FolderSummary> _subFolders = const [];
  Photo? _selected;

  String _keyword = '';
  PhotoSort _sort = PhotoSort.captureTimeDesc;

  /// 当前的筛选条件与可选项。
  PhotoFilter _filter = PhotoFilter.none;

  /// 用户设置；为空表示滑条范围按库中实际数据。
  SliderBounds? _sliderBounds;

  /// 界面实际使用的滑条范围（设置优先）。
  FilterOptions _filterOptions = const FilterOptions();
  bool _filterExpanded = false;

  /// 当前条件下命中的照片总数。
  int _visibleCount = 0;

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;

  bool _busy = false;
  bool _scanning = false;
  bool _cancelRequested = false;
  String? _scanningFolder;
  ScanProgress? _progress;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _reloadFolders();
    _reloadFilterOptions();
    _reloadContent();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 数据

  Future<void> _reloadFolders() async {
    final folders = await _db.getFolders();
    final counts = await _db.folderCounts();
    final total = await _db.totalCount();
    if (!mounted) return;
    setState(() {
      _rootFolders = folders;
      _folderCounts = counts;
      _totalCount = total;
      // 根目录被移除后，退回到全部照片。
      if (_scopePath != null && !_isUnderAnyRoot(_scopePath!)) {
        _scopePath = null;
      }
    });
  }

  bool _isUnderAnyRoot(String path) {
    for (final root in _rootFolders) {
      if (path == root || _isInside(path, root)) return true;
    }
    return false;
  }

  static bool _isInside(String path, String parent) {
    final prefix = parent.endsWith(p.separator)
        ? parent
        : '$parent${p.separator}';
    return path.startsWith(prefix);
  }

  /// 当前浏览位置所属的根目录。
  String? get _selectedRoot {
    final scope = _scopePath;
    if (scope == null) return null;
    String? best;
    for (final root in _rootFolders) {
      if (scope == root || _isInside(scope, root)) {
        if (best == null || root.length > best.length) best = root;
      }
    }
    return best;
  }

  /// 同时刷新照片列表与子文件夹列表。
  Future<void> _reloadContent() async {
    await _reloadPhotos();
    if (_viewMode == ViewMode.folders) {
      await _reloadSubFolders();
    }
  }

  Future<void> _reloadPhotos() async {
    setState(() {
      _loading = true;
      _hasMore = false;
    });
    final keyword = _keyword;
    final scope = _scopePath;
    final sort = _sort;
    final filter = _filter;
    try {
      final photos = await _db.queryPhotos(
        scopePath: scope,
        keyword: keyword,
        filter: filter,
        sort: sort,
        offset: 0,
        limit: _pageSize,
      );
      final count = await _db.countPhotos(
        scopePath: scope,
        keyword: keyword,
        filter: filter,
      );
      if (!mounted) return;
      setState(() {
        _photos
          ..clear()
          ..addAll(photos);
        _hasMore = photos.length >= _pageSize;
        _visibleCount = count;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('读取数据库失败：$e');
    }
  }

  /// 后台重新读取可筛选的相机型号 / 镜头 / 参数范围，以及滑条极值设置。
  Future<void> _reloadFilterOptions() async {
    try {
      final data = await _db.loadFilterOptions();
      final bounds = await _db.loadSliderBounds();
      if (!mounted) return;
      setState(() {
        _sliderBounds = bounds;
        _filterOptions = resolveFilterOptions(data, bounds);
      });
    } catch (_) {
      // 筛选选项加载失败不影响主流程。
    }
  }

  Future<void> _openSettings() async {
    final result = await showDialog<SliderBoundsResult>(
      context: context,
      builder: (context) => SliderBoundsDialog(
        effectiveOptions: _filterOptions,
        currentBounds: _sliderBounds,
      ),
    );
    if (result == null) return;

    setState(() => _busy = true);
    try {
      await _db.saveSliderBounds(result.bounds);
      await _reloadFilterOptions();
      if (!mounted) return;
      _showMessage(result.bounds == null ? '已恢复为按实际数据范围' : '滑条极值已保存');
    } catch (e) {
      _showMessage('保存设置失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyFilter(PhotoFilter filter) {
    setState(() => _filter = filter);
    _reloadPhotos();
  }

  void _clearFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _filter = PhotoFilter.none;
      _keyword = '';
    });
    _reloadPhotos();
  }

  Future<void> _reloadSubFolders() async {
    try {
      final folders = await _db.listSubFolders(
        scope: _scopePath,
        roots: _rootFolders,
      );
      if (!mounted) return;
      setState(() => _subFolders = folders);
    } catch (e) {
      if (!mounted) return;
      setState(() => _subFolders = const []);
      _showMessage('读取文件夹失败：$e');
    }
  }

  void _onScroll() {
    if (_viewMode != ViewMode.photos) return;
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    _loadingMore = true;
    setState(() {});
    try {
      final photos = await _db.queryPhotos(
        scopePath: _scopePath,
        keyword: _keyword,
        filter: _filter,
        sort: _sort,
        offset: _photos.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _photos.addAll(photos);
        _hasMore = photos.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      _showMessage('加载更多失败：$e');
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 320), () {
      _keyword = value;
      _reloadPhotos();
    });
  }

  Future<void> _selectPhoto(Photo photo) async {
    setState(() => _selected = photo);
    final exists = await File(photo.path).exists();
    if (!mounted || !identical(_selected, photo)) return;
    setState(() => photo.isFileAvailable = exists);
  }

  /// 切换浏览位置。[mode] 不为空时同时切换视图。
  void _navigateTo(String? path, {ViewMode? mode}) {
    setState(() {
      _scopePath = path;
      if (mode != null) _viewMode = mode;
      _selected = null;
      _subFolders = const [];
    });
    _reloadContent();
  }

  Future<void> _switchView(ViewMode mode) async {
    if (_viewMode == mode) return;
    setState(() => _viewMode = mode);
    if (mode == ViewMode.folders && _subFolders.isEmpty) {
      await _reloadSubFolders();
    }
  }

  // ------------------------------------------------------------------ 扫描

  Future<void> _addFolder() async {
    final path = await getDirectoryPath(confirmButtonText: '选择该文件夹');
    if (path == null) return;
    await _db.addFolder(path);
    await _reloadFolders();
    if (!mounted) return;
    _navigateTo(p.normalize(path), mode: ViewMode.folders);
    await _scanFolder(p.normalize(path));
  }

  Future<void> _scanFolder(String path, {bool resetCancel = true}) async {
    if (_scanning) {
      _showMessage('已有扫描任务在进行中');
      return;
    }
    setState(() {
      _scanning = true;
      if (resetCancel) _cancelRequested = false;
      _scanningFolder = path;
      _progress = null;
    });

    ScanSummary? summary;
    Object? error;
    try {
      summary = await _scanner.scan(
        path,
        isCancelled: () => _cancelRequested,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
    } catch (e) {
      error = e;
    }

    if (!mounted) return;
    setState(() {
      _scanning = false;
      _scanningFolder = null;
      _progress = null;
    });

    await _reloadFolders();
    await _reloadFilterOptions();
    await _reloadContent();

    if (error != null) {
      _showMessage('扫描失败：$error');
      return;
    }
    if (summary == null) return;
    final prefix = summary.cancelled ? '已取消' : '扫描完成';
    _showMessage(
      '$prefix：共 ${summary.total} 张，新增/更新 ${summary.indexed} 张，'
      '跳过 ${summary.skipped} 张，失败 ${summary.failed} 张，'
      '清理失效记录 ${summary.removed} 条',
    );
  }

  Future<void> _removeFolder(String path) async {
    final confirmed = await _confirm(
      title: '移除索引',
      content: '将删除 $path 及其所有子文件夹下已索引的缩略图与元数据（不会删除原图）。是否继续？',
    );
    if (confirmed != true) return;
    await _db.removeFolder(path);
    if (!mounted) return;
    setState(() {
      _selected = null;
      _filter = PhotoFilter.none;
    });
    await _reloadFolders();
    await _reloadFilterOptions();
    await _reloadContent();
    _showMessage('已移除该文件夹的索引');
  }

  // ------------------------------------------------------------ 导出 / 导入

  Future<void> _exportDatabase() async {
    final now = DateTime.now();
    final stamp =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final location = await getSaveLocation(
      suggestedName: 'piccontents_library_$stamp.db',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SQLite 数据库', extensions: ['db']),
      ],
    );
    if (location == null) return;
    setState(() => _busy = true);
    try {
      await _db.exportTo(location.path);
      _showMessage('数据库已导出到 ${location.path}');
    } catch (e) {
      _showMessage('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importDatabase() async {
    final file = await openFile(
      confirmButtonText: '导入',
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'SQLite 数据库',
          extensions: ['db', 'sqlite', 'sqlite3'],
        ),
      ],
    );
    if (file == null) return;
    final confirmed = await _confirm(
      title: '导入数据库',
      content: '导入后当前的索引数据会被所选文件替换（原数据库会先备份）。是否继续？',
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await _db.importFrom(file.path);
      if (!mounted) return;
      setState(() {
        _selected = null;
        _scopePath = null;
        _filter = PhotoFilter.none;
      });
      await _reloadFolders();
      await _reloadFilterOptions();
      await _reloadContent();
      _showMessage('导入完成，共 $_totalCount 条记录');
    } catch (e) {
      _showMessage('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearDatabase() async {
    final confirmed = await _confirm(
      title: '清空数据库',
      content: '将删除全部索引记录与缩略图（不会删除原始照片文件）。是否继续？',
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _db.clearAll();
      if (!mounted) return;
      setState(() {
        _selected = null;
        _scopePath = null;
        _filter = PhotoFilter.none;
      });
      await _reloadFolders();
      await _reloadFilterOptions();
      await _reloadContent();
      _showMessage('数据库已清空');
    } catch (e) {
      _showMessage('清空失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ 工具

  Future<void> _openLocation(String path) async {
    final file = File(path);
    var target = path;
    if (!await file.exists()) {
      final parent = file.parent;
      if (!await parent.exists()) {
        _showMessage('原文件与所在文件夹均不可访问');
        return;
      }
      target = parent.path;
      if (mounted) _showMessage('原文件不可访问，已打开其所在文件夹');
    }
    try {
      await Process.run('explorer.exe', ['/select,$target']);
    } catch (e) {
      _showMessage('打开资源管理器失败：$e');
    }
  }

  Future<bool?> _confirm({required String title, required String content}) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
      );
  }

  // ------------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const Icon(Icons.photo_library_outlined, size: 20),
            const SizedBox(width: 8),
            const Text('图片检索'),
            const SizedBox(width: 12),
            Text(
              _totalCount > 0 ? '共 $_totalCount 张' : '暂无索引',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            tooltip: '设置',
            onPressed: _busy || _scanning ? null : _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: '导出数据库',
            onPressed: _busy || _scanning ? null : _exportDatabase,
            icon: const Icon(Icons.upload_file_outlined),
          ),
          IconButton(
            tooltip: '导入数据库',
            onPressed: _busy || _scanning ? null : _importDatabase,
            icon: const Icon(Icons.download_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            enabled: !_busy && !_scanning,
            onSelected: (value) {
              if (value == 'clear') _clearDatabase();
              if (value == 'scanAll') _scanAllFolders();
              if (value == 'refresh') {
                _reloadFolders();
                _reloadContent();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'scanAll', child: Text('重新扫描全部索引目录')),
              PopupMenuItem(value: 'refresh', child: Text('刷新列表')),
              PopupMenuItem(value: 'clear', child: Text('清空数据库')),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (_scanning) _buildScanBanner(theme),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 260,
                  child: FolderSidebar(
                    folders: _rootFolders,
                    counts: _folderCounts,
                    totalCount: _totalCount,
                    selectedRoot: _selectedRoot,
                    allSelected: _scopePath == null,
                    enabled: !_busy && !_scanning,
                    onSelect: (folder) => _navigateTo(folder),
                    onAdd: _addFolder,
                    onRescan: _scanFolder,
                    onRemove: _removeFolder,
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _buildMainArea(theme)),
                if (_selected != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 340,
                    child: PhotoDetailPanel(
                      photo: _selected!,
                      onOpenLocation: () => _openLocation(_selected!.path),
                      onClose: () => setState(() => _selected = null),
                      onShowMessage: _showMessage,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanBanner(ThemeData theme) {
    final progress = _progress;
    final ratio = progress?.ratio ?? 0;
    final text = progress == null
        ? '正在扫描文件夹：${_scanningFolder ?? ''}'
        : '${progress.processed}/${progress.total} · 新增 ${progress.indexed} · 跳过 ${progress.skipped} · 失败 ${progress.failed}';
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _cancelRequested = true),
                  child: const Text('取消'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress == null ? null : ratio),
          ],
        ),
      ),
    );
  }

  Widget _buildMainArea(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: FolderBreadcrumb(
                  scopePath: _scopePath,
                  rootPaths: _rootFolders,
                  onSelect: (path) => _navigateTo(path),
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<ViewMode>(
                segments: [
                  for (final mode in ViewMode.values)
                    ButtonSegment(
                      value: mode,
                      icon: Icon(mode.icon, size: 16),
                      label: Text(mode.label),
                    ),
                ],
                selected: {_viewMode},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onSelectionChanged: _busy
                    ? null
                    : (selection) => _switchView(selection.first),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '在当前范围内搜索文件名、路径或日期（如 2024-05-01）',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _searchController,
                      builder: (context, value, child) {
                        if (value.text.isEmpty) return const SizedBox.shrink();
                        return IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _searchController.clear();
                            _keyword = '';
                            _reloadPhotos();
                          },
                        );
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => setState(() => _filterExpanded = !_filterExpanded),
                icon: Badge(
                  isLabelVisible: _filter.activeCount > 0,
                  label: Text('${_filter.activeCount}'),
                  child: Icon(
                    _filterExpanded ? Icons.filter_alt_off : Icons.filter_alt,
                    size: 18,
                  ),
                ),
                label: const Text('筛选'),
              ),
              const SizedBox(width: 10),
              if (_viewMode == ViewMode.photos) ...[
                DropdownButton<PhotoSort>(
                  value: _sort,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(8),
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _sort = value);
                          _reloadPhotos();
                        },
                  items: [
                    for (final sort in PhotoSort.values)
                      DropdownMenuItem(value: sort, child: Text(sort.label)),
                  ],
                ),
                const SizedBox(width: 10),
                Text(
                  '$_visibleCount 张',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_filterExpanded)
          // 限制最大高度，避免窗口较小时筛选面板把照片区域挤到溢出。
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: SingleChildScrollView(
              child: FilterPanel(
                filter: _filter,
                options: _filterOptions,
                onChanged: _applyFilter,
                onClear: _clearFilters,
              ),
            ),
          ),
        Expanded(child: _buildBody(theme)),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_viewMode == ViewMode.folders) {
      if (_subFolders.isEmpty) {
        return _EmptyState(
          icon: Icons.folder_off_outlined,
          title: _rootFolders.isEmpty ? '还没有添加任何索引目录' : '当前目录下没有子文件夹',
          description: _rootFolders.isEmpty
              ? '添加文件夹后会扫描其下所有子文件夹，\n提取每张照片的缩略图与 EXIF 信息。'
              : '可切换到「照片」视图查看该目录下的照片。',
          actionLabel: _rootFolders.isEmpty ? '添加文件夹' : '查看照片',
          actionIcon: _rootFolders.isEmpty
              ? Icons.create_new_folder_outlined
              : Icons.photo_outlined,
          onAction: _rootFolders.isEmpty
              ? _addFolder
              : () => _switchView(ViewMode.photos),
        );
      }
      return FolderGrid(
        folders: _subFolders,
        onOpen: (folder) => _navigateTo(folder.path, mode: ViewMode.photos),
        onOpenLocation: (folder) => _openLocation(folder.path),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_photos.isEmpty) {
      final hasFilter =
          _keyword.isNotEmpty || _scopePath != null || !_filter.isEmpty;
      return _EmptyState(
        icon: Icons.image_not_supported_outlined,
        title: hasFilter ? '没有匹配的照片' : '还没有索引任何照片',
        description: hasFilter
            ? '可以放宽筛选条件或返回到上层目录。'
            : '添加文件夹后会提取每张照片的缩略图与 EXIF 信息，\n之后即使文件夹离线也能检索并查看参数。',
        actionLabel: hasFilter ? '清除筛选条件' : '添加文件夹',
        actionIcon: hasFilter
            ? Icons.filter_alt_off_outlined
            : Icons.create_new_folder_outlined,
        onAction: hasFilter
            ? () {
                _searchDebounce?.cancel();
                _searchController.clear();
                setState(() {
                  _keyword = '';
                  _filter = PhotoFilter.none;
                  _scopePath = null;
                });
                _reloadContent();
              }
            : _addFolder,
      );
    }
    return PhotoGrid(
      photos: _photos,
      selected: _selected,
      onSelect: _selectPhoto,
      onOpenLocation: (photo) => _openLocation(photo.path),
      scrollController: _scrollController,
      loadingMore: _loadingMore,
    );
  }

  Future<void> _scanAllFolders() async {
    setState(() => _cancelRequested = false);
    for (final folder in _rootFolders) {
      if (_cancelRequested) break;
      await _scanFolder(folder, resetCancel: false);
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onAction,
    this.actionIcon = Icons.create_new_folder_outlined,
  });

  final IconData icon;
  final String title;
  final String description;
  final IconData actionIcon;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: theme.hintColor),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            description,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: onAction,
            icon: Icon(actionIcon, size: 18),
            label: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}
