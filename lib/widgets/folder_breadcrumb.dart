import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 路径面包屑：显示当前位置并支持逐级返回。
class FolderBreadcrumb extends StatelessWidget {
  const FolderBreadcrumb({
    super.key,
    required this.scopePath,
    required this.rootPaths,
    required this.onSelect,
    this.displayNames = const {},
  });

  /// 当前所在目录；null 表示"全部照片"。
  final String? scopePath;

  /// 已索引的根目录列表。
  final List<String> rootPaths;

  /// 索引目录的自定义显示名（路径 → 名称）。
  final Map<String, String> displayNames;

  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crumbs = _buildCrumbs(scopePath, rootPaths, displayNames);
    return SizedBox(
      height: 34,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          children: [
            for (var i = 0; i < crumbs.length; i++) ...[
              if (i > 0)
                Icon(Icons.chevron_right, size: 16, color: theme.hintColor),
              _CrumbButton(
                label: crumbs[i].label,
                current: i == crumbs.length - 1,
                onTap: () => onSelect(crumbs[i].path),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static List<_Crumb> _buildCrumbs(
    String? scope,
    List<String> roots,
    Map<String, String> displayNames,
  ) {
    final crumbs = <_Crumb>[const _Crumb(label: '全部照片', path: null)];
    if (scope == null || scope.isEmpty) return crumbs;

    final root = _bestRoot(scope, roots);
    if (root != null) {
      crumbs.add(_Crumb(label: displayNames[root] ?? _name(root), path: root));
      var accumulated = root;
      for (final part in _relativeParts(scope, root)) {
        accumulated = p.join(accumulated, part);
        crumbs.add(_Crumb(label: part, path: accumulated));
      }
      return crumbs;
    }

    // 不在任何已注册根目录下时，退化为逐段展示绝对路径。
    var accumulated = '';
    for (final part
        in scope.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty)) {
      accumulated = accumulated.isEmpty
          ? '$part${p.separator}'
          : p.join(accumulated, part);
      crumbs.add(_Crumb(label: part, path: accumulated));
    }
    return crumbs;
  }

  static String? _bestRoot(String scope, List<String> roots) {
    String? best;
    for (final root in roots) {
      if (scope == root || _isInside(scope, root)) {
        if (best == null || root.length > best.length) best = root;
      }
    }
    return best;
  }

  static bool _isInside(String path, String parent) {
    final prefix = parent.endsWith(p.separator)
        ? parent
        : '$parent${p.separator}';
    return path.startsWith(prefix);
  }

  static Iterable<String> _relativeParts(String scope, String root) {
    final rest = scope == root
        ? ''
        : scope.substring(
            root.endsWith(p.separator) ? root.length : root.length + 1,
          );
    return rest.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
  }

  static String _name(String path) {
    final name = p.basename(path);
    return name.isEmpty ? path : name;
  }
}

class _Crumb {
  const _Crumb({required this.label, required this.path});

  final String label;
  final String? path;
}

class _CrumbButton extends StatelessWidget {
  const _CrumbButton({
    required this.label,
    required this.current,
    required this.onTap,
  });

  final String label;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextButton(
      onPressed: current ? null : onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: current ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
