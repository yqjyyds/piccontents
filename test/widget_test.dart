import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:piccontents/models/app_settings.dart';
import 'package:piccontents/models/photo.dart';
import 'package:piccontents/models/photo_filter.dart';
import 'package:piccontents/services/database_service.dart';
import 'package:piccontents/services/image_indexer.dart';
import 'package:piccontents/utils/formatters.dart';

void main() {
  group('parseExifDate', () {
    test('解析标准 EXIF 时间', () {
      final millis = parseExifDate('2024:05:01 12:30:45');
      expect(millis, isNotNull);
      final parsed = DateTime.fromMillisecondsSinceEpoch(millis!);
      expect(parsed.year, 2024);
      expect(parsed.month, 5);
      expect(parsed.day, 1);
      expect(parsed.hour, 12);
      expect(parsed.minute, 30);
      expect(parsed.second, 45);
    });

    test('兼容横线分隔与缺失的秒', () {
      expect(parseExifDate('2021-11-09 08:05'), isNull);
      expect(parseExifDate('2021-11-09 08:05:00'), isNotNull);
    });

    test('无效或占位内容返回 null', () {
      expect(parseExifDate(null), isNull);
      expect(parseExifDate('0000:00:00 00:00:00'), isNull);
      expect(parseExifDate('not a date'), isNull);
    });
  });

  group('formatters', () {
    test('格式化文件大小', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.00 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.00 MB');
    });

    test('格式化快门速度', () {
      expect(formatExposureTime(0.004), '1/250 s');
      expect(formatExposureTime(2.5), '2.5 s');
      expect(formatExposureTime(null), '—');
    });

    test('格式化光圈与焦距', () {
      expect(formatFNumber(1.8), 'f/1.8');
      expect(formatFocalLength(24), '24 mm');
      expect(formatFocalLength(35.5), '35.5 mm');
    });
  });

  group('Photo', () {
    test('自动推导所在目录', () {
      expect(
        Photo.parentDirectoryOf(r'D:\photos\2024\01\a.jpg'),
        r'D:\photos\2024\01',
      );
      expect(Photo.parentDirectoryOf(r'D:\a.jpg'), r'D:\');
      expect(
        Photo(
          path: r'D:\photos\2024\a.jpg',
          fileName: 'a.jpg',
          folderPath: r'D:\photos',
        ).dirPath,
        r'D:\photos\2024',
      );
    });

    test('按方向标记换算显示分辨率', () {
      final landscape = Photo(
        path: r'C:\a.jpg',
        fileName: 'a.jpg',
        folderPath: r'C:\',
        width: 4000,
        height: 3000,
        orientation: 1,
      );
      expect(landscape.displayWidth, 4000);
      expect(landscape.displayHeight, 3000);

      final rotated = Photo(
        path: r'C:\b.jpg',
        fileName: 'b.jpg',
        folderPath: r'C:\',
        width: 4000,
        height: 3000,
        orientation: 6,
      );
      expect(rotated.displayWidth, 3000);
      expect(rotated.displayHeight, 4000);
    });

    test('往返序列化保持字段一致', () {
      final photo = Photo(
        path: r'C:\photos\a.jpg',
        fileName: 'a.jpg',
        folderPath: r'C:\photos',
        fileSize: 1024,
        fileModified: 1700000000000,
        width: 6000,
        height: 4000,
        captureTime: DateTime(2024, 5, 1, 12, 30, 45),
        cameraMake: 'NIKON CORPORATION',
        cameraModel: 'NIKON Z 6',
        fNumber: 1.8,
        exposureTime: 0.004,
        iso: 400,
        focalLength: 50,
        indexedAt: 1700000001000,
      );
      final restored = Photo.fromMap(photo.toMap()..['id'] = 1);
      expect(restored.path, photo.path);
      expect(restored.captureTime, photo.captureTime);
      expect(restored.cameraModel, 'NIKON Z 6');
      expect(restored.fNumber, 1.8);
      expect(restored.iso, 400);
    });
  });

  test('识别支持的图片扩展名', () {
    expect(isSupportedImage(r'C:\a\b.JPG'), isTrue);
    expect(isSupportedImage(r'C:\a\b.heic'), isTrue);
    expect(isSupportedImage(r'C:\a\b.txt'), isFalse);
    expect(isSupportedImage(r'C:\a\b'), isFalse);
  });

  group('目录树还原', () {
    test('自动补齐只有子目录的中间层级', () {
      final nodes = buildDirectoryTree(
        {r'D:\photos\2024\05\a': 3, r'D:\photos\2024\06': 2},
        scope: r'D:\photos',
        roots: const [],
      );

      expect(nodes[r'D:\photos']!.children, contains(r'D:\photos\2024'));
      expect(
        nodes[r'D:\photos\2024']!.children,
        containsAll(<String>[r'D:\photos\2024\05', r'D:\photos\2024\06']),
      );
      expect(
        nodes[r'D:\photos\2024\05']!.children,
        contains(r'D:\photos\2024\05\a'),
      );
      expect(nodes[r'D:\photos\2024\05']!.directCount, 0);
      expect(folderTreeCountOf(r'D:\photos\2024', nodes), 5);
      expect(folderTreeCountOf(r'D:\photos', nodes), 5);
    });

    test('同一层级不会被重复挂载', () {
      final nodes = buildDirectoryTree(
        {
          r'D:\photos\2024\05\a': 1,
          r'D:\photos\2024\05': 1,
          r'D:\photos\2024\06': 1,
        },
        scope: r'D:\photos',
        roots: const [],
      );

      expect(nodes[r'D:\photos']!.children.length, 1);
      expect(nodes[r'D:\photos\2024']!.children.length, 2);
      expect(folderTreeCountOf(r'D:\photos', nodes), 3);
    });

    test('scope 为空时以索引根目录为顶层边界', () {
      const roots = [r'D:\photos', r'E:\pics'];
      final nodes = buildDirectoryTree(
        {r'D:\photos\2024': 4, r'E:\pics\a': 1},
        scope: null,
        roots: roots,
      );

      expect(nodes[r'D:\photos']!.children, contains(r'D:\photos\2024'));
      expect(nodes[r'E:\pics']!.children, contains(r'E:\pics\a'));
      // 不应越过根目录继续向上层展开
      expect(nodes.containsKey(r'D:\'), isFalse);
      expect(nodes.containsKey(r'E:\'), isFalse);
      expect(roots.where(nodes.containsKey).toList(), roots);
    });

    test('封面优先取自身，否则取第一个含照片的后代', () {
      final nodes = buildDirectoryTree(
        {r'D:\photos\2024\05\a': 2, r'D:\photos\2024\06': 1},
        scope: r'D:\photos',
        roots: const [],
      );

      expect(
        coverDirectoryOf(r'D:\photos\2024\06', nodes),
        r'D:\photos\2024\06',
      );
      expect(
        coverDirectoryOf(r'D:\photos\2024', nodes),
        r'D:\photos\2024\05\a',
      );
    });

    test('取目录显示名', () {
      expect(displayFolderName(r'D:\photos\2024'), '2024');
      expect(displayFolderName(r'D:\'), r'D:\');
    });
  });

  group('筛选', () {
    test('解析手动输入的快门时间', () {
      expect(parseExposureTime('1/250'), closeTo(0.004, 1e-9));
      expect(parseExposureTime('1/250 s'), closeTo(0.004, 1e-9));
      expect(parseExposureTime(' 1 / 1000 '), closeTo(0.001, 1e-9));
      expect(parseExposureTime('2'), 2);
      expect(parseExposureTime('2.5s'), 2.5);
      expect(parseExposureTime('0.004'), closeTo(0.004, 1e-9));
      expect(parseExposureTime('1/0'), isNull);
      expect(parseExposureTime('0'), isNull);
      expect(parseExposureTime('-1'), isNull);
      expect(parseExposureTime('abc'), isNull);
      expect(parseExposureTime(''), isNull);
    });

    test('ISO 吸附到标准档位', () {
      expect(snapIso(98), 100);
      expect(snapIso(126), 125);
      expect(snapIso(398), 400);
      expect(snapIso(50), 50);
      expect(snapIso(6000), 6400);
    });

    test('统计已启用的筛选维度', () {
      expect(PhotoFilter.none.activeCount, 0);
      expect(PhotoFilter.none.isEmpty, isTrue);
      expect(
        const PhotoFilter(cameraModels: {'A'}, lensModels: {'B'}).activeCount,
        2,
      );
      expect(const PhotoFilter(fNumberMin: 1.8, fNumberMax: 4).activeCount, 1);
      expect(
        const PhotoFilter(
          exposureMin: 0.001,
          exposureMax: 0.01,
          isoMin: 100,
          isoMax: 800,
        ).activeCount,
        2,
      );
    });

    test('筛选选项的可用性判断', () {
      expect(const FilterOptions().isEmpty, isTrue);
      expect(
        const FilterOptions(fNumberMin: 1.8, fNumberMax: 1.8).hasFNumber,
        isFalse,
      );
      expect(
        const FilterOptions(fNumberMin: 1.8, fNumberMax: 16).hasFNumber,
        isTrue,
      );
      expect(
        const FilterOptions(exposureMin: 0.004, exposureMax: 1).hasExposure,
        isTrue,
      );
      expect(const FilterOptions(isoMin: 400, isoMax: 400).hasIso, isFalse);
    });

    group('滑条区间解析', () {
      const boundMin = 1.8;
      const boundMax = 22.0;

      test('两端都没拖动时不限制', () {
        final range = resolveSliderRange(
          sliderStart: boundMin,
          sliderEnd: boundMax,
          boundMin: boundMin,
          boundMax: boundMax,
        );
        expect(range.isActive, isFalse);
        expect(range.min, isNull);
        expect(range.max, isNull);
      });

      test('只拖动下界时上界用原始边界补齐', () {
        final range = resolveSliderRange(
          sliderStart: 4.0,
          sliderEnd: boundMax,
          boundMin: boundMin,
          boundMax: boundMax,
        );
        expect(range.isActive, isTrue);
        expect(range.min, 4.0);
        expect(range.max, boundMax);
        expect(range.minMoved, isTrue);
        expect(range.maxMoved, isFalse);
      });

      test('只拖动上界时下界用原始边界补齐', () {
        final range = resolveSliderRange(
          sliderStart: boundMin,
          sliderEnd: 8.0,
          boundMin: boundMin,
          boundMax: boundMax,
        );
        expect(range.isActive, isTrue);
        expect(range.min, boundMin);
        expect(range.max, 8.0);
        expect(range.minMoved, isFalse);
        expect(range.maxMoved, isTrue);
      });

      test('两端同时收窄', () {
        final range = resolveSliderRange(
          sliderStart: 2.8,
          sliderEnd: 11.0,
          boundMin: boundMin,
          boundMax: boundMax,
        );
        expect(range.min, 2.8);
        expect(range.max, 11.0);
        expect(range.minMoved, isTrue);
        expect(range.maxMoved, isTrue);
      });

      test('浮点误差不会把未拖动的端点误判为已拖动', () {
        final range = resolveSliderRange(
          sliderStart: boundMin + 1e-15,
          sliderEnd: boundMax,
          boundMin: boundMin,
          boundMax: boundMax,
        );
        expect(range.isActive, isFalse);
      });

      test('对数空间下的端点补齐', () {
        // 快门滑条使用 log10(秒)：0.001s ~ 1s
        final range = resolveSliderRange(
          sliderStart: -3.0,
          sliderEnd: math.log(0.01) / math.ln10,
          boundMin: -3.0,
          boundMax: 0.0,
        );
        expect(range.isActive, isTrue);
        expect(range.minMoved, isFalse);
        expect(math.pow(10, range.min!), closeTo(0.001, 1e-12));
        expect(math.pow(10, range.max!), closeTo(0.01, 1e-12));
      });
    });

    group('日期区间', () {
      test('取一天的起止时刻', () {
        final day = DateTime(2024, 5, 1, 13, 45, 30);
        expect(startOfDay(day), DateTime(2024, 5, 1));
        expect(endOfDay(day), DateTime(2024, 5, 1, 23, 59, 59, 999));
      });

      test('日期条件计入已启用维度', () {
        final filter = PhotoFilter(
          captureFrom: DateTime(2024, 5, 1),
          captureTo: DateTime(2024, 5, 31),
        );
        expect(filter.activeCount, 1);
        expect(filter.isEmpty, isFalse);
      });

      test('单边日期也会启用该维度', () {
        expect(PhotoFilter(captureFrom: DateTime(2024)).activeCount, 1);
        expect(PhotoFilter(captureTo: DateTime(2024)).activeCount, 1);
      });
    });

    group('日期输入框解析', () {
      test('全部留空表示不限制', () {
        final input = parseDateFields(year: '', month: '', day: '');
        expect(input.isEmpty, isTrue);
        expect(input.error, isNull);
        expect(dateRangeStart(input), isNull);
        expect(dateRangeEnd(input), isNull);
      });

      test('只填年份按整年处理', () {
        final input = parseDateFields(year: '2019', month: '', day: '');
        expect(dateRangeStart(input), DateTime(2019, 1, 1));
        expect(dateRangeEnd(input), DateTime(2019, 12, 31));
      });

      test('填到月份按整月处理', () {
        final input = parseDateFields(year: '2019', month: '2', day: '');
        expect(dateRangeStart(input), DateTime(2019, 2, 1));
        expect(dateRangeEnd(input), DateTime(2019, 2, 28));
      });

      test('闰年 2 月按 29 天处理', () {
        final input = parseDateFields(year: '2020', month: '2', day: '');
        expect(dateRangeEnd(input), DateTime(2020, 2, 29));
      });

      test('精确到日', () {
        final input = parseDateFields(year: '2021', month: '11', day: '9');
        expect(dateRangeStart(input), DateTime(2021, 11, 9));
        expect(dateRangeEnd(input), DateTime(2021, 11, 9));
      });

      test('前导零与空格不影响解析', () {
        final input = parseDateFields(year: ' 2019 ', month: '05', day: '01');
        expect(dateRangeStart(input), DateTime(2019, 5, 1));
        expect(dateRangeEnd(input), DateTime(2019, 5, 1));
      });

      test('非法输入给出提示', () {
        expect(
          parseDateFields(year: '19', month: '', day: '').error,
          isNotNull,
        );
        expect(
          parseDateFields(year: '2019', month: '13', day: '').error,
          isNotNull,
        );
        expect(
          parseDateFields(year: '2019', month: '', day: '5').error,
          isNotNull,
        );
        expect(
          parseDateFields(year: '2019', month: '2', day: '30').error,
          isNotNull,
        );
        expect(
          parseDateFields(year: '2019', month: '4', day: '31').error,
          isNotNull,
        );
        expect(
          parseDateFields(year: '2019', month: '4', day: '30').error,
          isNull,
        );
        expect(
          parseDateFields(year: '2019', month: '2', day: '29').error,
          isNotNull,
        );
        expect(
          parseDateFields(year: '2020', month: '2', day: '29').error,
          isNull,
        );
      });

      test('只有一边填写时另一边不受限制', () {
        final input = parseDateFields(year: '2020', month: '', day: '');
        expect(dateRangeStart(input), DateTime(2020, 1, 1));
        expect(
          dateRangeEnd(parseDateFields(year: '', month: '', day: '')),
          isNull,
        );
      });
    });

    group('滑条极值设置', () {
      test('设置优先于库中实际数据', () {
        const data = FilterOptions(
          cameraModels: ['A'],
          fNumberMin: 1.8,
          fNumberMax: 16,
          exposureMin: 0.001,
          exposureMax: 1,
          isoMin: 100,
          isoMax: 6400,
        );
        const bounds = SliderBounds(
          fNumberMin: 1.0,
          fNumberMax: 64,
          exposureMin: 1 / 8000,
          exposureMax: 30,
          isoMin: 50,
          isoMax: 204800,
        );
        final resolved = resolveFilterOptions(data, bounds);
        expect(resolved.fNumberMin, 1.0);
        expect(resolved.fNumberMax, 64);
        expect(resolved.isoMax, 204800);
        // 相机型号 / 镜头列表仍来自实际数据。
        expect(resolved.cameraModels, ['A']);
      });

      test('未设置时沿用实际数据范围', () {
        const data = FilterOptions(fNumberMin: 1.8, fNumberMax: 16);
        final resolved = resolveFilterOptions(data, null);
        expect(resolved.fNumberMin, 1.8);
        expect(resolved.fNumberMax, 16);
        expect(resolved.isoMin, isNull);
      });

      test('极值合法性校验', () {
        expect(
          const SliderBounds(
            fNumberMin: 1.4,
            fNumberMax: 32,
            exposureMin: 0.000125,
            exposureMax: 30,
            isoMin: 50,
            isoMax: 204800,
          ).isValid,
          isTrue,
        );
        expect(
          const SliderBounds(
            fNumberMin: 32,
            fNumberMax: 1.4,
            exposureMin: 0.000125,
            exposureMax: 30,
            isoMin: 50,
            isoMax: 204800,
          ).isValid,
          isFalse,
        );
      });
    });
  });
}
