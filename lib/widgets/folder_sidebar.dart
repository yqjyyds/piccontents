import 'dart:io';

import 'package:flutter/material.dart';

/// 左侧文件夹列表：显示已索引的根目录、照片数量与是否在线。
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
    required this.enabled,
  });

  final List<String> folders;
  final Map<String, int> counts;
  final int totalCount;

  /// 当前浏览位置所属的根目录。
  final String? selectedRoot;

  /// 是否处于"全部照片"。
  final bool allSelected;

  final ValueChanged<String?> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<String> onRescan;
  final ValueChanged<String> onRemove;
  final bool enabled;

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
                  count: counts[folder] ?? 0,
                  selected: selectedRoot == folder,
                  enabled: enabled,
                  onTap: () => onSelect(folder),
                  onRescan: () => onRescan(folder),
                  onRemove: () => onRemove(folder),
                ),
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

class _FolderEntry extends StatelessWidget {
  const _FolderEntry({
    required this.folder,
    required this.count,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.onRescan,
    required this.onRemove,
  });

  final String folder;
  final int count;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onRescan;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final online = Directory(folder).existsSync();
    final segments = folder
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty)
        .toList();
    final name = segments.isEmpty ? folder : segments.last;

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
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
          if (value == 'remove') onRemove();
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'rescan', child: Text('重新扫描')),
          PopupMenuItem(value: 'remove', child: Text('移除索引')),
        ],
      ),
      onTap: onTap,
    );
  }
}
