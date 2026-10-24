import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/app_settings.dart';
import '../models/photo.dart';
import '../models/photo_filter.dart';
import '../services/database_service.dart';
import '../services/diagnostics.dart';
import '../services/scanner_service.dart';
import '../services/volume_identity.dart';
import '../utils/index_paths.dart';
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

  /// 索引目录的自定义显示名（路径 → 名称）。
  Map<String, String> _folderNames = const {};

  /// 已归档（当前未接入）的硬盘索引。
  List<ArchivedLibrarySummary> _archivedLibraries = const [];

  /// 当前活动库的路径 → id，用于按硬盘隔离查询。
  Map<String, int> _activeLibraryIds = const {};

  /// 当前正在浏览的归档库；null 表示浏览活动索引。
  int? _archivedLibraryId;

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
    try {
      final folders = await _db.getFolders();
      final names = await _db.folderDisplayNames();
      final counts = await _db.folderCounts();
      final total = await _db.totalCount();
      final archived = await _db.archivedLibraries();
      final libraryIds = await _db.activeLibraryIds();
      if (!mounted) return;
      setState(() {
        _rootFolders = folders;
        _folderNames = names;
        _folderCounts = counts;
        _totalCount = total;
        _archivedLibraries = archived;
        _activeLibraryIds = libraryIds;
        // 正在浏览的归档被删除后，退回到全部照片。
        if (_archivedLibraryId != null &&
            !archived.any((library) => library.id == _archivedLibraryId)) {
          _archivedLibraryId = null;
        }
        // 根目录被移除后，退回到全部照片（浏览归档时不受活动目录影响）。
        if (_archivedLibraryId == null &&
            _scopePath != null &&
            !_isUnderAnyRoot(_scopePath!)) {
          _scopePath = null;
        }
      });
    } catch (e, stack) {
      _logError('Folders', e, stack);
      if (!mounted) return;
      _showMessage('读取索引目录失败：$e');
    }
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

  /// 当前正在浏览的归档库；未选择归档时返回 null。
  ArchivedLibrarySummary? get _archivedLibrary {
    final id = _archivedLibraryId;
    if (id == null) return null;
    for (final library in _archivedLibraries) {
      if (library.id == id) return library;
    }
    return null;
  }

  /// 当前浏览范围对应的库 id。
  ///
  /// - 归档浏览：归档库 id；
  /// - 某个根目录：该根目录的活动库 id（即使另一块盘挂同一盘符也不会串）；
  /// - 全部照片：null，表示不限制库。
  int? get _scopeLibraryId {
    final archivedId = _archivedLibraryId;
    if (archivedId != null) return archivedId;
    final scope = _scopePath;
    if (scope == null) return null;
    int? bestId;
    var bestLength = -1;
    for (final entry in _activeLibraryIds.entries) {
      final root = entry.key;
      if ((scope == root || _isInside(scope, root)) &&
          root.length > bestLength) {
        bestId = entry.value;
        bestLength = root.length;
      }
    }
    return bestId;
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
    final libraryId = _scopeLibraryId;
    try {
      final photos = await _db.queryPhotos(
        libraryId: libraryId,
        scopePath: scope,
        keyword: keyword,
        filter: filter,
        sort: sort,
        offset: 0,
        limit: _pageSize,
      );
      final count = await _db.countPhotos(
        libraryId: libraryId,
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
    } catch (e, stack) {
      _logError('QueryPhotos', e, stack);
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('读取数据库失败：$e');
    }
  }

  /// 后台重新读取可筛选的相机型号 / 镜头 / 参数范围，以及滑条极值设置。
  Future<void> _reloadFilterOptions() async {
    try {
      final data = await _db.loadFilterOptions(libraryId: _scopeLibraryId);
      final bounds = await _db.loadSliderBounds();
      if (!mounted) return;
      setState(() {
        _sliderBounds = bounds;
        _filterOptions = resolveFilterOptions(data, bounds);
      });
    } catch (e, stack) {
      _logError('FilterOptions', e, stack);
      // 筛选选项加载失败不影响主流程。
    }
  }

  Future<void> _openSettings() async {
    final result = await showDialog<SettingsResult>(
      context: context,
      builder: (context) => SliderBoundsDialog(
        effectiveOptions: _filterOptions,
        currentBounds: _sliderBounds,
        dataPath: _db.dbPath,
      ),
    );
    if (result == null) return;

    setState(() => _busy = true);
    final newDir = result.newDataDir;
    final previousPath = _db.dbPath;
    var relocated = false;
    try {
      if (result.boundsChanged) {
        await _db.saveSliderBounds(result.bounds);
        await _reloadFilterOptions();
      }
      if (newDir != null) {
        await _db.relocateTo(newDir);
        relocated = previousPath != _db.dbPath;
        // 迁移后重新加载，确保界面用的是新库里的数据。
        await _reloadFolders();
        await _reloadFilterOptions();
        await _reloadContent();
      }
      if (!mounted) return;
      if (newDir != null) {
        _showMessage(
          relocated ? '索引已迁移到 ${_db.dbPath}' : '索引仍保存在 ${_db.dbPath}',
        );
      } else if (result.boundsChanged) {
        _showMessage(result.bounds == null ? '已恢复为按实际数据范围' : '滑条极值已保存');
      }
    } catch (e, stack) {
      _logError('Settings', e, stack);
      if (!mounted) return;
      await _showErrorDialog('保存设置失败', '$e', stack);
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
      final archived = _archivedLibrary;
      final allScope = _archivedLibraryId == null && _scopePath == null;
      final folders = await _db.listSubFolders(
        libraryId: _scopeLibraryId,
        // 「全部照片」的文件夹视图只统计当前接入的库。
        libraryIds: allScope ? _activeLibraryIds.values.toSet() : null,
        scope: _scopePath,
        roots: archived == null ? _rootFolders : [archived.path],
      );
      if (!mounted) return;
      setState(() => _subFolders = folders);
    } catch (e, stack) {
      _logError('SubFolders', e, stack);
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
        libraryId: _scopeLibraryId,
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
    final wasArchived = _archivedLibraryId != null;
    setState(() {
      _archivedLibraryId = null;
      _scopePath = path;
      if (mode != null) _viewMode = mode;
      _selected = null;
      _subFolders = const [];
    });
    if (wasArchived) _reloadFilterOptions();
    _reloadContent();
  }

  /// 在当前位置内切换目录；浏览归档库时保持在归档数据源里。
  void _navigateScope(String? path, {ViewMode? mode}) {
    if (_archivedLibraryId == null) {
      _navigateTo(path, mode: mode);
      return;
    }
    setState(() {
      _scopePath = path;
      if (mode != null) _viewMode = mode;
      _selected = null;
      _subFolders = const [];
    });
    _reloadContent();
  }

  /// 打开一份归档索引（离线浏览，不改变活动索引）。
  void _openArchived(int id) {
    setState(() {
      _archivedLibraryId = id;
      _scopePath = null;
      _viewMode = ViewMode.photos;
      _selected = null;
      _subFolders = const [];
    });
    _reloadFilterOptions();
    _reloadContent();
  }

  /// 退出归档浏览，回到当前接入硬盘的全部照片。
  void _openActiveScope() {
    setState(() {
      _archivedLibraryId = null;
      _scopePath = null;
      _viewMode = ViewMode.photos;
      _selected = null;
      _subFolders = const [];
    });
    _reloadFilterOptions();
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
    debugPrint('[AddFolder] 开始选择文件夹');
    final path = await _pickFolder();
    if (path == null) return;
    // 磁盘根目录的写法不固定（C: / C:\ / c:/），统一后再入库和扫描。
    final normalized = normalizeIndexRootPath(path);
    debugPrint('[AddFolder] 已选择：$path → $normalized');

    try {
      // 盘符可能被不同硬盘重复使用，扫描前先确认这次接的是不是同一块盘。
      final proceed = await _prepareRootForScan(normalized);
      if (!proceed) return;
      await _db.addFolder(normalized);
      final identity = identifyVolume(normalized);
      if (identity != null) await _db.setFolderVolume(normalized, identity);
      await _reloadFolders();
    } catch (e, stack) {
      _logError('AddFolder', e, stack);
      if (!mounted) return;
      await _showErrorDialog('添加目录失败', '目录：$normalized\n\n$e', stack);
      return;
    }

    if (!mounted) return;
    _navigateTo(normalized, mode: ViewMode.folders);
    await _scanFolder(normalized);
  }

  /// 调用系统文件夹选择器。
  ///
  /// 返回 null 表示用户取消；选择器本身报错时会弹出错误详情，
  /// 而不是像以前那样静默失败。
  Future<String?> _pickFolder() async {
    try {
      final path = await getDirectoryPath(confirmButtonText: '选择该文件夹');
      if (path == null) {
        debugPrint('[AddFolder] 用户取消，或选择器未返回任何路径');
        return null;
      }
      final trimmed = path.trim();
      if (trimmed.isEmpty) {
        throw StateError('文件夹选择器返回了空路径');
      }
      return trimmed;
    } catch (e, stack) {
      _logError('PickFolder', e, stack);
      if (mounted) {
        await _showErrorDialog(
          '无法选择文件夹',
          '系统文件夹选择器调用失败：\n$e\n\n'
              '如果所选位置是网络位置或 OneDrive 等虚拟目录，'
              '可以改为选择本机的普通文件夹后重试。',
          stack,
        );
      }
      return null;
    }
  }

  // -------------------------------------------------- 硬盘身份与独立索引

  /// 扫描前确认盘符上接的硬盘和索引记录是否一致。
  ///
  /// 返回 false 表示用户取消了本次操作；true 表示可以继续入库/扫描。
  Future<bool> _prepareRootForScan(String path) async {
    final identity = identifyVolume(path);
    // 网络盘、无法识别的卷：沿用旧行为，不做拦截。
    if (identity == null) return true;

    final stored = await _db.folderVolume(path);
    // 新目录：调用方入库时再记录卷身份。
    if (stored == null) return true;
    if (stored.matches(identity)) {
      await _db.setFolderVolume(path, identity);
      return true;
    }

    final archived = await _db.findArchivedLibrary(
      path: path,
      identity: identity,
    );
    if (archived != null) {
      final count = await _db.archivedPhotoCount(archived.id);
      if (!mounted) return false;
      final choice = await _showChoiceDialog(
        title: '检测到曾经索引过的硬盘',
        message:
            '$path 现在接入的是「${identity.displayName}」，'
            '与现有索引所在的硬盘不是同一块。\n\n'
            '找到这块硬盘之前的索引（$count 张照片）。'
            '恢复后只需要增量扫描，不会重复处理。',
        options: const {
          'restore': '恢复旧索引并扫描',
          'independent': '归档现有索引，重新扫描',
          'cancel': '取消',
        },
      );
      if (choice == 'restore') {
        debugPrint('[Volume] 恢复归档索引：$path');
        await _db.archiveFolder(path);
        await _db.restoreLibrary(archived);
        await _reloadFolders();
        await _reloadContent();
        return true;
      }
      if (choice == 'independent') {
        debugPrint('[Volume] 归档现有索引并扫描新盘：$path');
        await _db.archiveFolder(path);
        await _db.addFolder(path);
        await _db.setFolderVolume(path, identity);
        await _reloadFolders();
        await _reloadContent();
        return true;
      }
      return false;
    }

    final reason = stored.isKnown ? '与索引时记录的硬盘不一致' : '现有索引没有记录硬盘信息，无法确认是不是同一块盘';
    if (!mounted) return false;
    final choice = await _showChoiceDialog(
      title: '同一盘符上检测到另一块硬盘',
      message:
          '$path 现在接入的是「${identity.displayName}」，$reason。\n\n'
          '作为独立硬盘：先把现有索引归档保存（不会动原图），再扫描这块盘；\n'
          '合并：保留现有记录继续扫描。同名路径会被覆盖，扫描结束时'
          '旧盘上已不存在的记录会被清理。',
      options: const {
        'independent': '作为独立硬盘',
        'merge': '合并到现有索引',
        'cancel': '取消',
      },
    );
    if (choice == 'independent') {
      debugPrint('[Volume] 视作独立硬盘：$path');
      await _db.archiveFolder(path);
      await _db.addFolder(path);
      await _db.setFolderVolume(path, identity);
      await _reloadFolders();
      await _reloadContent();
      return true;
    }
    if (choice == 'merge') {
      debugPrint('[Volume] 合并到现有索引：$path');
      await _db.setFolderVolume(path, identity);
      return true;
    }
    return false;
  }

  /// 多选一对话框；返回被点击选项的 key，关闭时返回 null。
  Future<String?> _showChoiceDialog({
    required String title,
    required String message,
    required Map<String, String> options,
  }) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(child: Text(message)),
        ),
        actions: [
          for (final entry in options.entries)
            if (entry.key == 'cancel')
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, entry.key),
                child: Text(entry.value),
              )
            else
              FilledButton.tonal(
                onPressed: () => Navigator.pop(dialogContext, entry.key),
                child: Text(entry.value),
              ),
        ],
      ),
    );
  }

  /// 展示可复制的错误详情，避免异常只被打印到控制台。
  Future<void> _showErrorDialog(
    String title,
    String message,
    StackTrace? stack,
  ) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: SelectableText(
              message,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              final detail = stack == null ? message : '$message\n\n$stack';
              Clipboard.setData(ClipboardData(text: detail));
              Navigator.pop(dialogContext);
              _showMessage('错误详情已复制');
            },
            child: const Text('复制详情'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanFolder(
    String path, {
    bool resetCancel = true,
    bool checkVolume = true,
  }) async {
    if (_scanning) {
      _showMessage('已有扫描任务在进行中');
      return;
    }
    if (checkVolume) {
      final proceed = await _prepareRootForScan(path);
      if (!proceed) return;
      await _reloadFolders();
    }
    debugPrint('[Scan] 开始扫描：$path');
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
      _logError('Scan', error, null);
      _showMessage('扫描失败：$error');
      return;
    }
    if (summary == null) return;
    final elapsedSeconds = summary.elapsedMs / 1000;
    final secondsText = elapsedSeconds < 1
        ? '${summary.elapsedMs}ms'
        : '${elapsedSeconds.toStringAsFixed(1)}s';
    debugPrint(
      '[Scan] 用时 $secondsText，处理 ${summary.processed} 张，'
      '${summary.photosPerSecond.toStringAsFixed(1)} 张/秒；'
      '阶段耗时：${summary.timingsMs.entries.map((e) => '${e.key}=${e.value}ms').join(', ')}',
    );
    // 从资源管理器启动时没有控制台，把性能数据也写进日志。
    writeDiagnosticLog(
      'ScanTiming',
      '共 ${summary.total} 张（实际处理 ${summary.processed} 张），'
          '用时 $secondsText，'
          '${summary.photosPerSecond.toStringAsFixed(1)} 张/秒；'
          '${summary.timingsMs.entries.map((e) => '${e.key}=${e.value}ms').join(', ')}',
    );
    final prefix = summary.diskError
        ? '已中止'
        : (summary.cancelled ? '已取消' : '扫描完成');
    final skippedDirsText = summary.skippedDirs > 0
        ? '，跳过 ${summary.skippedDirs} 个无权限目录'
        : '';
    final message =
        '$prefix：共 ${summary.total} 张，新增/更新 ${summary.indexed} 张，'
        '跳过 ${summary.skipped} 张，失败 ${summary.failed} 张，'
        '清理失效记录 ${summary.removed} 条$skippedDirsText，用时 $secondsText';
    _showMessage(message);
    if (summary.diskError) {
      await _showErrorDialog(
        '扫描已中止：磁盘读取异常',
        '$message\n\n'
            '连续 ${summary.failed} 张照片读取失败，通常意味着硬盘有坏块，'
            '或 USB 线材/接口不稳定。\n\n'
            '建议：\n'
            '1. 换一根 USB 数据线和另一个 USB 3.0 接口后重试；\n'
            '2. 用 CrystalDiskInfo 查看 SMART 中的重映射扇区、待映射扇区；\n'
            '3. 尽快把这块盘里重要的照片备份到其他硬盘。',
        null,
      );
    }
  }

  Future<void> _removeFolder(String path) async {
    final confirmed = await _confirm(
      title: '移除索引',
      content: '将删除 $path 及其所有子文件夹下已索引的缩略图与元数据（不会删除原图）。是否继续？',
    );
    if (confirmed != true) return;
    try {
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
    } catch (e, stack) {
      _logError('RemoveFolder', e, stack);
      if (!mounted) return;
      await _showErrorDialog('移除索引失败', '目录：$path\n\n$e', stack);
    }
  }

  /// 修改索引目录的显示名。只影响界面，不重命名磁盘上的文件夹。
  Future<void> _renameFolder(String path) async {
    final controller = TextEditingController(
      text: _folderNames[path] ?? _folderRealName(path),
    );
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名显示名'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '显示名',
                  helperText: '留空则恢复为真实文件夹名；不会改名磁盘上的文件夹',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) => Navigator.pop(dialogContext, value),
              ),
              const SizedBox(height: 12),
              Text(
                '实际路径：$path',
                style: Theme.of(dialogContext).textTheme.labelSmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null) return;

    try {
      await _db.setFolderDisplayName(path, newName);
      await _reloadFolders();
      if (!mounted) return;
      _showMessage(newName.trim().isEmpty ? '已恢复为真实文件夹名' : '显示名已更新');
    } catch (e, stack) {
      _logError('RenameFolder', e, stack);
      if (!mounted) return;
      await _showErrorDialog('重命名失败', '目录：$path\n\n$e', stack);
    }
  }

  /// 取路径最后一级作为文件夹名；盘符根（C:\）显示为「C:」。
  static String _folderRealName(String path) {
    final segments = path
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty)
        .toList();
    return segments.isEmpty ? path : segments.last;
  }

  // ---------------------------------------------------------- 归档索引管理

  static String _archivedName(ArchivedLibrary library) {
    final display = library.displayName?.trim() ?? '';
    if (display.isNotEmpty) return display;
    final label = library.volumeLabel?.trim() ?? '';
    if (label.isNotEmpty) return label;
    return library.path;
  }

  /// 把归档库恢复成该路径的活动索引；原有活动索引会先归档。
  Future<void> _restoreArchived(int id) async {
    final library = await _db.libraryById(id);
    if (library == null) return;
    final name = _archivedName(library);
    final count = await _db.archivedPhotoCount(id);
    final identity = identifyVolume(library.path);
    final attached = identity != null && library.matches(identity);

    final confirmed = await _confirm(
      title: '恢复归档索引',
      content:
          '将把「$name」（$count 张）恢复为主索引。\n\n'
          '同一路径上当前的活动索引会先被归档保存，不会丢失。'
          '${attached ? '' : '\n\n注意：当前盘符上的硬盘无法确认就是这块硬盘，'
                    '恢复后先做离线浏览，扫描前请确认硬盘。'}',
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await _db.archiveFolder(library.path);
      await _db.restoreLibrary(library);
      if (!mounted) return;
      setState(() {
        _archivedLibraryId = null;
        _scopePath = library.path;
      });
      await _reloadFolders();
      await _reloadFilterOptions();
      await _reloadContent();
      _showMessage('已恢复「$name」的索引');
    } catch (e, stack) {
      _logError('RestoreArchive', e, stack);
      if (!mounted) return;
      await _showErrorDialog('恢复归档失败', '$e', stack);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删除归档索引（只删缩略图与元数据，不动原图）。
  Future<void> _deleteArchived(int id) async {
    final library = await _db.libraryById(id);
    if (library == null) return;
    final name = _archivedName(library);
    final count = await _db.archivedPhotoCount(id);
    final confirmed = await _confirm(
      title: '删除归档索引',
      content:
          '将删除「$name」的 $count 张索引记录（缩略图与 EXIF 元数据，'
          '不会删除原始照片）。是否继续？',
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await _db.deleteLibrary(id);
      if (!mounted) return;
      if (_archivedLibraryId == id) {
        setState(() {
          _archivedLibraryId = null;
          _scopePath = null;
        });
      }
      await _reloadFolders();
      await _reloadFilterOptions();
      await _reloadContent();
      _showMessage('已删除归档索引');
    } catch (e, stack) {
      _logError('DeleteArchive', e, stack);
      if (!mounted) return;
      await _showErrorDialog('删除归档失败', '$e', stack);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  /// 同时输出到控制台和日志文件：从资源管理器启动时没有控制台，
  /// 只有写文件才能保留排错线索。
  void _logError(String tag, Object error, StackTrace? stack) {
    debugPrint('[$tag] $error\n$stack');
    writeDiagnosticLog(tag, error, stack: stack);
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
          if (_archivedLibraryId != null) _buildArchivedBanner(theme),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 260,
                  child: FolderSidebar(
                    folders: _rootFolders,
                    displayNames: _folderNames,
                    counts: _folderCounts,
                    totalCount: _totalCount,
                    selectedRoot: _archivedLibraryId != null
                        ? null
                        : _selectedRoot,
                    allSelected:
                        _scopePath == null && _archivedLibraryId == null,
                    enabled: !_busy && !_scanning,
                    onSelect: (folder) => _navigateTo(folder),
                    onAdd: _addFolder,
                    onRescan: _scanFolder,
                    onRename: _renameFolder,
                    onRemove: _removeFolder,
                    archivedLibraries: _archivedLibraries,
                    selectedArchivedId: _archivedLibraryId,
                    onSelectArchived: _openArchived,
                    onRestoreArchived: _restoreArchived,
                    onDeleteArchived: _deleteArchived,
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

  Widget _buildArchivedBanner(ThemeData theme) {
    final library = _archivedLibrary;
    if (library == null) return const SizedBox.shrink();
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 16,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '正在浏览已归档的「${library.name}」索引'
                '（${library.photoCount} 张）· 只读浏览，不会改动当前活动索引',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: _openActiveScope,
              child: const Text('返回当前索引'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainArea(ThemeData theme) {
    final archived = _archivedLibrary;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: FolderBreadcrumb(
                  scopePath: _scopePath,
                  rootPaths: archived == null ? _rootFolders : [archived.path],
                  displayNames: archived == null
                      ? _folderNames
                      : {archived.path: archived.name},
                  onSelect: _navigateScope,
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
        onOpen: (folder) => _navigateScope(folder.path, mode: ViewMode.photos),
        onOpenLocation: (folder) => _openLocation(folder.path),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_photos.isEmpty) {
      final archived = _archivedLibrary;
      final hasFilter =
          _keyword.isNotEmpty || _scopePath != null || !_filter.isEmpty;
      if (archived != null && !hasFilter) {
        return _EmptyState(
          icon: Icons.inventory_2_outlined,
          title: '这份归档索引里没有照片',
          description: '可以返回当前索引，或重新扫描对应的硬盘。',
          actionLabel: '返回当前索引',
          actionIcon: Icons.arrow_back,
          onAction: _openActiveScope,
        );
      }
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
      // "全部照片"跨库显示时，用角落标签区分同路径的不同硬盘副本。
      showLibraryLabels: _archivedLibraryId == null && _scopePath == null,
    );
  }

  Future<void> _scanAllFolders() async {
    setState(() => _cancelRequested = false);
    final skipped = <String>[];
    for (final folder in _rootFolders) {
      if (_cancelRequested) break;
      final identity = identifyVolume(folder);
      if (identity == null) {
        // 盘符不在、盘未接：跳过；网络路径等识别不了但仍可访问的照旧扫描。
        if (!Directory(folder).existsSync()) {
          skipped.add('$folder（未接入）');
          continue;
        }
        await _scanFolder(folder, resetCancel: false, checkVolume: false);
        continue;
      }

      final stored = await _db.folderVolume(folder);
      if (stored == null || !stored.isKnown) {
        // 老库没有卷信息，批量扫描时不擅自合并，提示手动确认一次。
        skipped.add('$folder（需先手动扫描确认硬盘）');
        continue;
      }
      if (!stored.matches(identity)) {
        skipped.add('$folder（盘符上不是索引时的硬盘）');
        continue;
      }
      await _scanFolder(folder, resetCancel: false, checkVolume: false);
    }
    if (skipped.isNotEmpty && mounted) {
      _showMessage('已跳过 ${skipped.length} 个目录：${skipped.join('；')}');
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
