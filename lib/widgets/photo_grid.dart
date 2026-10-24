import 'package:flutter/material.dart';

import '../models/photo.dart';
import '../utils/formatters.dart';

/// 缩略图网格。
class PhotoGrid extends StatelessWidget {
  const PhotoGrid({
    super.key,
    required this.photos,
    required this.selected,
    required this.onSelect,
    required this.onOpenLocation,
    required this.scrollController,
    required this.loadingMore,
    this.showLibraryLabels = false,
  });

  final List<Photo> photos;
  final Photo? selected;
  final ValueChanged<Photo> onSelect;
  final ValueChanged<Photo> onOpenLocation;
  final ScrollController scrollController;
  final bool loadingMore;

  /// 是否显示照片所属硬盘（"全部照片"跨库时用于区分同路径副本）。
  final bool showLibraryLabels;

  @override
  Widget build(BuildContext context) {
    final itemCount = photos.length + (loadingMore ? 1 : 0);
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.82,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index >= photos.length) {
          return const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final photo = photos[index];
        return _PhotoTile(
          photo: photo,
          selected: identical(photo, selected),
          showLibraryLabel: showLibraryLabels,
          onTap: () => onSelect(photo),
          onDoubleTap: () => onOpenLocation(photo),
        );
      },
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.photo,
    required this.selected,
    required this.showLibraryLabel,
    required this.onTap,
    required this.onDoubleTap,
  });

  final Photo photo;
  final bool selected;
  final bool showLibraryLabel;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = photo.thumbnail;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    thumbnail == null
                        ? Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: theme.hintColor,
                              size: 28,
                            ),
                          )
                        : Image.memory(
                            thumbnail,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            filterQuality: FilterQuality.low,
                          ),
                    if (photo.hasGps)
                      const Positioned(
                        right: 4,
                        top: 4,
                        child: _Badge(icon: Icons.place_outlined),
                      ),
                    if (showLibraryLabel && photo.libraryLabel != null)
                      Positioned(
                        left: 4,
                        top: 4,
                        child: _TextBadge(text: photo.libraryLabel!),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      photo.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      photo.captureTime != null
                          ? formatDateTime(photo.captureTime)
                          : '无拍摄时间',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextBadge extends StatelessWidget {
  const _TextBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 10),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(icon, size: 12, color: Colors.white),
    );
  }
}
