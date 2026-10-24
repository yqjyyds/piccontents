import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/photo.dart';
import '../utils/formatters.dart';

/// 右侧详情面板：展示照片路径、拍摄时间、器材与拍摄参数。
class PhotoDetailPanel extends StatelessWidget {
  const PhotoDetailPanel({
    super.key,
    required this.photo,
    required this.onOpenLocation,
    required this.onClose,
    required this.onShowMessage,
  });

  final Photo photo;
  final VoidCallback onOpenLocation;
  final VoidCallback onClose;
  final ValueChanged<String> onShowMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
          child: Row(
            children: [
              Text('照片信息', style: theme.textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: '关闭面板',
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              _Preview(photo: photo),
              const SizedBox(height: 12),
              _AvailabilityChip(photo: photo),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onOpenLocation,
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('打开所在文件夹'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: photo.path));
                        onShowMessage('已复制文件路径');
                      },
                      icon: const Icon(Icons.copy_all_outlined, size: 16),
                      label: const Text('复制路径'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: _plainText(photo)),
                        );
                        onShowMessage('已复制照片信息');
                      },
                      icon: const Icon(Icons.article_outlined, size: 16),
                      label: const Text('复制信息'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: '文件',
                children: [
                  _InfoRow(label: '文件名', value: photo.fileName),
                  _InfoRow(label: '完整路径', value: photo.path, selectable: true),
                  _InfoRow(
                    label: '所在文件夹',
                    value: photo.dirPath,
                    selectable: true,
                  ),
                  _InfoRow(
                    label: '索引根目录',
                    value: photo.folderPath,
                    selectable: true,
                  ),
                  if (photo.libraryLabel != null)
                    _InfoRow(label: '来源硬盘', value: photo.libraryLabel!),
                  _InfoRow(label: '文件大小', value: formatBytes(photo.fileSize)),
                  _InfoRow(
                    label: '文件修改时间',
                    value: formatDateTime(
                      photo.fileModified > 0
                          ? DateTime.fromMillisecondsSinceEpoch(
                              photo.fileModified,
                            )
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Section(
                title: '时间',
                children: [
                  _InfoRow(
                    label: '拍摄时间',
                    value: formatDateTime(photo.captureTime),
                  ),
                  _InfoRow(
                    label: '索引时间',
                    value: formatDateTime(
                      photo.indexedAt > 0
                          ? DateTime.fromMillisecondsSinceEpoch(photo.indexedAt)
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Section(
                title: '器材',
                children: [
                  _InfoRow(label: '相机品牌', value: photo.cameraMake ?? '—'),
                  _InfoRow(label: '相机型号', value: photo.cameraModel ?? '—'),
                  _InfoRow(label: '镜头', value: photo.lensModel ?? '—'),
                ],
              ),
              const SizedBox(height: 12),
              _Section(
                title: '拍摄参数',
                children: [
                  _InfoRow(label: '光圈', value: formatFNumber(photo.fNumber)),
                  _InfoRow(
                    label: '快门',
                    value: formatExposureTime(photo.exposureTime),
                  ),
                  _InfoRow(label: '感光度', value: formatIso(photo.iso)),
                  _InfoRow(
                    label: '焦距',
                    value: formatFocalLength(photo.focalLength),
                  ),
                  if (photo.focalLength35mm != null)
                    _InfoRow(
                      label: '等效焦距',
                      value: formatFocalLength(photo.focalLength35mm),
                    ),
                  _InfoRow(
                    label: '曝光补偿',
                    value: formatExposureBias(photo.exposureBias),
                  ),
                  _InfoRow(
                    label: '分辨率',
                    value: formatResolution(
                      photo.displayWidth,
                      photo.displayHeight,
                    ),
                  ),
                ],
              ),
              if (photo.hasGps) ...[
                const SizedBox(height: 12),
                _Section(
                  title: '位置',
                  children: [
                    _InfoRow(
                      label: 'GPS',
                      value: formatGps(
                        photo.gpsLat,
                        photo.gpsLon,
                        photo.gpsAltitude,
                      ),
                      selectable: true,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String _plainText(Photo photo) {
    return [
      '文件名: ${photo.fileName}',
      '路径: ${photo.path}',
      '拍摄时间: ${formatDateTime(photo.captureTime)}',
      '相机品牌: ${photo.cameraMake ?? '—'}',
      '相机型号: ${photo.cameraModel ?? '—'}',
      '镜头: ${photo.lensModel ?? '—'}',
      '光圈: ${formatFNumber(photo.fNumber)}',
      '快门: ${formatExposureTime(photo.exposureTime)}',
      'ISO: ${photo.iso ?? '—'}',
      '焦距: ${formatFocalLength(photo.focalLength)}',
      '分辨率: ${formatResolution(photo.displayWidth, photo.displayHeight)}',
    ].join('\n');
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.photo});

  final Photo photo;

  @override
  Widget build(BuildContext context) {
    final thumbnail = photo.thumbnail;
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: thumbnail == null
          ? const Center(
              child: Icon(
                Icons.image_not_supported_outlined,
                color: Colors.white38,
                size: 36,
              ),
            )
          : Image.memory(thumbnail, fit: BoxFit.contain, gaplessPlayback: true),
    );
  }
}

class _AvailabilityChip extends StatelessWidget {
  const _AvailabilityChip({required this.photo});

  final Photo photo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = photo.isFileAvailable;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: available
            ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.6)
            : theme.colorScheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            available ? Icons.check_circle_outline : Icons.cloud_off_outlined,
            size: 16,
            color: available
                ? theme.colorScheme.onSecondaryContainer
                : theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              available ? '原文件可访问' : '原文件当前不可访问（索引信息仍可用）',
              style: theme.textTheme.labelSmall?.copyWith(
                color: available
                    ? theme.colorScheme.onSecondaryContainer
                    : theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const Divider(height: 10),
        ...children,
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 1),
          selectable
              ? SelectableText(value, style: theme.textTheme.bodySmall)
              : Text(value, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
