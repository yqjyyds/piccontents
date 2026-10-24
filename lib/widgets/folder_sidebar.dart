import 'dart:io';

import 'package:flutter/material.dart';

import '../services/database_service.dart';

/// 左侧文件夹列表：显示已索引的根目录、照片数量与是否在线，
/// 以及已归档（当前未接入）的硬盘索引。
class FolderSidebar extends StatelessWidget {
  const FolderSidebar({
    super.key,
    required this.folders,
    required this.counts,
    required this.totalCount,
    required this.selectedRoot,
    required this.allSelected,
    required this.onSelect,
    required this.onAdd,
    required this.onRescan,
    required this.onRemove,
    required this.onRename,
    required this.enabled,
    this.displayNames = const {},
    this.archivedLibraries = const [],
    this.selectedArchivedId,
    this.onSelectArchived,
    this.onRestoreArchived,
    this.onDeleteArchived,
  });

  final List<String> folders;
  final Map<String, int> counts;
  final int totalCount;

  /// 索引目录的自定义显示名（路径 → 名称）。
  final Map<String, String> displayNames;

  /// 当前浏览位置所属的根目录。
  final String? selectedRoot;

  /// 是否处于"全部照片"。
  final bool allSelected;

  final ValueChanged<String?> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<String> onRescan;
  final ValueChanged<String> onRemove;
  final ValueChanged<String> onRename;
  final bool enabled;

  /// 已归档的硬盘索引。
  final List<ArchivedLibrarySummary> archivedLibraries;

  /// 当前正在浏览的归档库 id。
  final int? selectedArchivedId;

  final ValueChanged<int>? onSelectArchived;
  final ValueChanged<int>? onRestoreArchived;
  final ValueChanged<int>? onDeleteArchived;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
          child: Row(
            children: [
              Text('索引目录', style: theme.textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: '添加文件夹（含全部子文件夹）',
                onPressed: enabled ? onAdd : null,
                icon: const Icon(Icons.create_new_folder_outlined, size: 20),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            children: [
              _Entry(
                icon: Icons.photo_library_outlined,
                title: '全部照片',
                subtitle: '$totalCount 张',
                selected: allSelected,
                onTap: () => onSelect(null),
              ),
              const Divider(height: 12),
              if (folders.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '还没有添加文件夹。\n点击右上角图标选择图片目录，\n其下所有子文件夹都会被扫描。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ),
              for (final folder in folders)
                _FolderEntry(
                  folder: folder,
                  name: displayNames[folder],
                  count: counts[folder] ?? 0,
                  selected: selectedRoot == folder,
                  enabled: enabled,
                  onTap: () => onSelect(folder),
                  onRescan: () => onRescan(folder),
                  onRename: () => onRename(folder),
                  onRemove: () => onRemove(folder),
                ),
              if (archivedLibraries.isNotEmpty) ...[
                const Divider(height: 20),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
                  child: Text(
                    '已归档的硬盘',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ),
                for (final library in archivedLibraries)
                  _ArchivedEntry(
                    library: library,
                    selected: selectedArchivedId == library.id,
                    enabled: enabled,
                    onTap: () => onSelectArchived?.call(library.id),
                    onRestore: () => onRestoreArchived?.call(library.id),
                    onDelete: () => onDeleteArchived?.call(library.id),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.5,
      ),
      leading: Icon(icon, size: 20),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }
}

class _ArchivedEntry extends StatelessWidget {
  const _ArchivedEntry({
    required this.library,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.onRestore,
    required this.onDelete,
  });

  final ArchivedLibrarySummary library;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.5,
      ),
      leading: Icon(
        Icons.inventory_2_outlined,
        size: 20,
        color: theme.hintColor,
      ),
      title: Tooltip(
        message: library.path,
        child: Text(library.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      subtitle: Text(
        '${library.photoCount} 张 · ${_archiveStamp(library.archivedTime)} 归档',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
      ),
      trailing: PopupMenuButton<String>(
        enabled: enabled,
        tooltip: '归档操作',
        iconSize: 18,
        onSelected: (value) {
          if (value == 'restore') onRestore();
          if (value == 'delete') onDelete();
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'restore', child: Text('恢复为主索引')),
          PopupMenuItem(value: 'delete', child: Text('删除归档')),
        ],
      ),
      onTap: onTap,
    );
  }

  static String _archiveStamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

class _FolderEntry extends StatelessWidget {
  const _FolderEntry({
    required this.folder,
    required this.name,
    required this.count,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.onRescan,
    required this.onRename,
    required this.onRemove,
  });

  final String folder;

  /// 自定义显示名；null 表示用真实文件夹名。
  final String? name;

  final int count;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onRescan;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final online = Directory(folder).existsSync();
    final segments = folder
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty)
        .toList();
    final realName = segments.isEmpty ? folder : segments.last;
    final displayName = name ?? realName;

    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.5,
      ),
      leading: Icon(
        online ? Icons.folder_outlined : Icons.folder_off_outlined,
        size: 20,
        color: online ? null : theme.colorScheme.error,
      ),
      title: Tooltip(
        message: folder,
        child: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      subtitle: Text(
        online ? '$count 张' : '$count 张 · 当前不可访问',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: online
            ? null
            : TextStyle(color: theme.colorScheme.error, fontSize: 11),
      ),
      trailing: PopupMenuButton<String>(
        enabled: enabled,
        tooltip: '更多操作',
        iconSize: 18,
        onSelected: (value) {
          if (value == 'rescan') onRescan();
          if (value == 'rename') onRename();
          if (value == 'remove') onRemove();
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'rescan', child: Text('重新扫描')),
          PopupMenuItem(value: 'rename', child: Text('重命名显示名')),
          PopupMenuItem(value: 'remove', child: Text('移除索引')),
        ],
      ),
      onTap: onTap,
    );
  }
}
