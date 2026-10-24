# PicContents / 图片检索

一个面向 Windows 的本地图片索引与检索工具：把硬盘里照片的缩略图、EXIF 与文件信息写入本地 SQLite，之后即使硬盘不在线，也能快速浏览、搜索和筛选。

A Windows desktop photo indexer: it stores thumbnails, EXIF metadata and file information in a local SQLite database, so your library stays searchable even when the drives are offline.

[中文](#中文) · [English](#english)

---

## 中文

### 1. 项目简介

PicContents 面向"照片分散在多块硬盘、经常换盘"的使用场景。它不修改、不移动、不删除原图，只建立一个可重建的本地索引：

- 扫描目录时提取缩略图、EXIF 拍摄参数、文件大小与修改时间；
- 所有内容存入单个 SQLite 文件，可脱机检索；
- 同一盘符接入不同硬盘时会识别卷身份，避免两块盘的索引互相覆盖；
- 换下来的硬盘索引可以归档，随时恢复，也可离线浏览。

技术栈：Flutter（Windows 桌面）+ SQLite（`sqflite_common_ffi`）+ `dart:ffi`（卷身份）+ `dart:ui` / `image`（解码与缩略图）。

### 2. 功能特性

**索引与扫描**

- 添加任意本地文件夹或磁盘根目录（支持 `C:\` 这类根路径）；
- 递归扫描子目录，自动跳过无权限目录、系统目录与符号链接/junction；
- 增量扫描：文件大小与修改时间未变则复用已有记录；
- 可随时取消；连续读取失败 12 张会判定磁盘异常并中止，弹窗提示坏块/线材问题；
- 扫描完成输出分阶段耗时（枚举、stat、读文件、EXIF、解码、编码、写库）。

**浏览与检索**

- 「全部照片」跨所有索引库展示，包含已归档硬盘的照片；
- 「文件夹」视图按目录展示封面、照片数与子目录数；
- 关键词搜索：文件名、完整路径、相机品牌/型号、镜头、拍摄日期；
- 相机型号、镜头多选筛选；
- 光圈、快门、ISO 区间筛选：滑条 + 手动输入，支持只填一端；
- 拍摄日期筛选：直接输入年 / 月 / 日，不依赖日历翻页；
- 六种排序：拍摄时间升降序、文件名、修改时间、文件大小、索引时间；
- 照片详情：路径、拍摄时间、分辨率、相机与镜头、光圈/快门/ISO/焦距/曝光补偿、GPS、来源硬盘；
- 双击照片打开文件所在位置，文件离线时自动退回到所在文件夹。

**多硬盘与归档**

- 通过卷 GUID + 卷序列号 + 卷标识别"同一盘符是否换了硬盘"；
- 换盘后弹窗选择：作为独立硬盘（归档现有索引）/ 合并到现有索引 / 取消；
- 如果这块盘以前索引过，会提示直接恢复旧索引并增量扫描；
- 已归档硬盘在侧栏单独分组，可离线浏览、恢复为主索引或删除归档；
- 归档与恢复只更新状态，不复制缩略图，瞬间完成；
- 同一路径在不同硬盘上各保留一份记录，互不覆盖。

**数据管理**

- 数据库完整导出 / 导入（导入前自动备份原库）；
- 设置窗口中可查看当前索引文件位置、更改位置、打开所在文件夹；
- 更改位置时自动迁移数据库（同盘改名，跨盘复制后校验再删旧文件），失败自动回滚；
- 可调整光圈 / 快门 / ISO 滑条的取值范围；
- 索引目录可设置显示名（只改界面显示，不改磁盘文件夹）。

**可靠性**

- 数据库目录不可写时自动回退到其它可写位置；
- 启动、扫描、查询、导入导出均有异常捕获与可复制的错误详情；
- 关键错误写入 `diagnostics.log`，从资源管理器启动也有排错线索；
- SQLite 使用 WAL + `synchronous=NORMAL`，兼顾批量写入速度与基本安全。

### 3. 界面与操作

| 区域 | 说明 |
|---|---|
| 左侧栏 | 「全部照片」、各索引根目录、已归档硬盘；条目右侧 `⋯` 菜单可重新扫描、重命名显示名、移除索引 |
| 顶部工具栏 | 添加文件夹、导出/导入数据库、设置、扫描全部、视图切换、排序、关键词搜索 |
| 筛选面板 | 日期（年/月/日输入框）、相机型号、镜头、光圈、快门、ISO |
| 照片网格 | 缩略图、文件名、拍摄时间、GPS 标记；跨库浏览时左上角显示来源硬盘 |
| 文件夹视图 | 子文件夹封面、照片数量、子目录数量，可逐级进入 |
| 右侧详情 | 文件信息、拍摄时间、器材、曝光参数、分辨率、GPS、来源硬盘 |

基本流程：添加文件夹 → 等待扫描完成 → 在「全部照片」或某个根目录下浏览/筛选 → 需要换盘时直接接入新硬盘并按提示选择处理方式。

### 4. 工作原理

**扫描流水线**

1. 逐层遍历目录（跳过无权限目录与链接），收集受支持的图片路径；
2. 分批读取文件大小与修改时间，与库中签名比较，得到待处理列表；
3. 每张照片只读一次文件：主 isolate 负责解码，随后把同一份字节交给 worker 解析 EXIF；
4. worker 池并行完成 EXIF 解析与 JPEG 编码，避免每张图新建 isolate 的开销；
5. 按批（128 条）写入 SQLite，元数据与缩略图分表写入；
6. 扫描结束后清理该库中已不存在的记录；若中途换盘或出现读取错误则跳过清理，避免误删。

并发读盘控制在 2~3 路，优先照顾机械盘与移动盘；进度刷新节流到 250ms，避免频繁重建界面。

**数据库结构（schema v6）**

| 表 | 作用 |
|---|---|
| `libraries` | 一块硬盘一份索引；`archived_at` 为空表示当前接入，非空表示已归档 |
| `photos` | 照片元数据，按 `library_id` 区分硬盘，唯一键 `(library_id, path)` |
| `photo_thumbnails` | 缩略图 BLOB，按 `photo_id` 单独存放 |
| `settings` | 滑条极值等偏好 |

关键索引：`(library_id, capture_time)`、`(library_id, dir_path)`、`(library_id, folder_path)`、`camera_model`、`lens_model`、`iso`、`f_number`，以及活动库路径的部分唯一索引。

列表查询只扫描元数据表，拿到当前页 120 条 id 后再点查缩略图，因此筛选和排序不会触碰大块 BLOB。

### 5. 支持的文件格式

`.jpg` `.jpeg` `.jpe` `.jfif` `.png` `.bmp` `.gif` `.webp` `.tif` `.tiff` `.heic` `.heif` `.avif`

能否生成缩略图取决于平台解码能力；解码失败时仍会保留文件元数据记录（缩略图为空）。常见 JPEG/PNG/WebP/GIF/BMP 可直接生成缩略图。

缩略图规格：最长边 400px，JPEG 质量 82。

### 6. 数据存储

**数据库文件**

- 文件名：`piccontents_library.db`（WAL 模式，运行时伴随 `-wal` / `-shm`）
- 每条记录约 20KB 左右（主要是缩略图），5 万张约 1GB

**目录优先级**

1. 用户在设置中指定的位置（记录在 `index_location.json`）
2. exe 同目录下已存在数据库的 `piccontents_data`
3. 应用支持目录（`path_provider` 的 application support 目录下 `piccontents`）
4. `%LOCALAPPDATA%\PicContents\piccontents`
5. exe 同目录 `piccontents_data`

每次启动都会做写入探测；目录不可写（例如被安全软件限制）时自动尝试下一个位置，并把已有数据库迁移过去。

**位置配置文件**

`index_location.json` 内容形如：

```json
{ "dir": "D:\\PicContentsData" }
```

它存放在上述可写目录之一，独立于数据库，避免"必须先知道数据库在哪才能读到位置"的循环依赖。

**备份与迁移**

- 数据库结构升级前自动备份为 `piccontents_library.db.bak_v6`；
- v6 迁移会校验照片数与缩略图数，失败则回滚并保留旧库；
- 迁移成功后自动 VACUUM 回收旧表留下的空闲页；
- 导入数据库前会把当前库备份为 `.bak`，导入失败自动恢复。

**导出 / 导入**

- 导出：生成一个包含全部缩略图与 EXIF 的独立 `.db` 文件；
- 导入：用所选文件替换当前索引（原库先备份），旧版本数据库会在打开时自动升级。

### 7. 多硬盘与同盘符

很多移动硬盘会被系统分配同一个盘符（例如都挂成 `E:\`）。PicContents 的处理方式：

1. 扫描前读取当前卷的 GUID、序列号和卷标；
2. 与索引中记录的卷身份比较：
   - 一致：同一块盘，正常增量扫描；
   - 不一致：弹窗选择「作为独立硬盘」「合并到现有索引」或「取消」；
   - 该盘以前索引过：优先提示恢复旧索引并增量扫描。
3. 「作为独立硬盘」会把当前活动索引归档，再为这块盘新建索引；
4. 归档库在侧栏「已归档的硬盘」中，可离线浏览、恢复或删除。

唯一键是 `(library_id, path)`，因此两块盘上完全相同的路径会各自保留一条记录。在「全部照片」中它们都会显示，并用角落标签和详情面板中的「来源硬盘」区分；默认不做去重。

### 8. 构建与运行

**环境要求**

- Windows 10/11 x64
- Flutter SDK（Dart `^3.13.3`）
- Visual Studio 2022，安装「使用 C++ 的桌面开发」工作负载

**获取依赖**

```bash
flutter pub get
```

**开发运行**

```bash
flutter run -d windows
```

**构建发布版**

```bash
flutter build windows --release
```

产物位于 `build\windows\x64\runner\Release`。

> 部署时必须复制整个输出目录（包含 `data\flutter_assets`、DLL 与 `sqlite3.dll`），只复制 exe 无法启动。日常使用建议 Release 版；Debug 版常驻内存更高、纯 Dart 编码也更慢。

### 9. 测试

```bash
flutter analyze
flutter test
```

测试覆盖：路径规范化、EXIF 日期解析、格式化、筛选区间与日期解析、滑条极值、目录树还原、worker 池解码/编码、v5 → v6 数据库迁移（含同路径双副本、缩略图与索引校验）。

### 10. 日志与排障

`diagnostics.log` 按以下顺序尝试写入：

1. exe 同目录
2. 应用数据目录
3. 系统临时目录 `piccontents_diagnostics.log`

扫描结束会在日志中输出 `[ScanTiming]`，包含枚举、stat、读文件、EXIF、解码、编码、写库各阶段耗时，便于定位瓶颈。

常见问题：

| 现象 | 处理 |
|---|---|
| 无法添加目录 / 提示拒绝访问 | 多为安全软件拦截数据目录写入；在设置中更换索引文件位置，或把程序放到可写目录 |
| 扫描很慢、磁盘占用 100% | 先用 `[ScanTiming]` 判断是否读盘阶段占主导；移动机械盘/坏块盘本身较慢，程序会限制并发并在连续失败后中止 |
| 换盘后旧照片"消失" | 检查侧栏「已归档的硬盘」，或对根目录重新扫描并按提示选择独立/合并 |
| 启动失败 | 查看 `diagnostics.log`，界面上的错误信息可直接复制 |
| 界面语言 | 当前界面为中文，日期控件已本地化为中文 |

### 11. 性能设计

- **每张照片只读一次盘**：解码与 EXIF 共用同一份字节，避免慢盘双倍寻道；
- **常驻 worker 池**：EXIF 解析与 JPEG 编码并行，省去每张图创建 isolate 的开销；
- **低并发读盘**：2~3 路并发，减少机械盘寻道风暴与坏块重试叠加；
- **元数据与缩略图分表**：筛选、排序、计数只扫元数据；当前页再点查缩略图；
- **针对性索引**：库 + 时间、库 + 目录、相机、镜头、ISO、光圈；
- **批量写入**：128 条一批，WAL + `NORMAL`；
- **进度节流**：250ms 一次，避免扫描时界面频繁重建；
- **异常保护**：连续 12 张读取失败即中止；换盘或读取出错时不做失效清理。

### 12. 项目结构

```text
lib/
  main.dart                    应用入口、启动异常页
  models/
    photo.dart                 照片模型与排序方式
    photo_filter.dart          筛选条件
    app_settings.dart          滑条极值等设置
  pages/
    home_page.dart             主界面与业务编排
  services/
    database_service.dart      SQLite、迁移、查询、归档、导入导出
    scanner_service.dart       目录遍历、增量扫描流水线
    image_indexer.dart         单张照片索引
    image_codec.dart           原生解码、缩略图编码、EXIF
    index_worker_pool.dart     常驻 isolate 池
    volume_identity.dart       卷 GUID / 序列号 / 卷标
    scan_timings.dart          分阶段耗时统计
    diagnostics.dart           诊断日志
  utils/
    formatters.dart            时间、大小、光圈、快门等格式化
    index_paths.dart           索引根路径规范化
  widgets/
    folder_sidebar.dart        侧栏：根目录与归档硬盘
    filter_panel.dart          筛选面板
    photo_grid.dart            照片网格
    photo_detail_panel.dart    照片详情
    folder_grid.dart           文件夹视图
    folder_breadcrumb.dart     路径面包屑
    settings_dialog.dart       设置
test/
  widget_test.dart             单元测试
  database_migration_test.dart v5 → v6 迁移测试
```

### 13. 已知限制

- 仅支持 Windows 桌面；
- 只做元数据索引，不做人脸/场景识别或图像内容搜索；
- 归档记录保留原始路径，恢复与"打开位置"依赖原盘符；硬盘不在线时只能查看缩略图与 EXIF；
- HEIC/HEIF/AVIF 的缩略图生成取决于系统解码能力，可能只有元数据；
- 「全部照片」默认不去重，同一路径的两块盘副本会显示为两条；
- 程序不备份原图，删除磁盘上的照片不会自动同步，需重新扫描；
- 坏块、CRC 错误等硬件问题无法通过软件修复，程序只会减少读盘次数并尽早提示。

---

## English

### 1. Overview

PicContents is built for people whose photo libraries live across several external drives that are swapped frequently. It never modifies, moves or deletes original files; it only builds a rebuildable local index:

- extracts thumbnails, EXIF shooting data, file size and modification time;
- stores everything in a single SQLite file for offline browsing;
- identifies the actual volume behind a drive letter, so two different disks mounted as `E:\` never overwrite each other's index;
- archives the index of a disconnected drive and restores it later; archived libraries stay browsable offline.

Stack: Flutter for Windows desktop, SQLite via `sqflite_common_ffi`, `dart:ffi` for volume identity, and `dart:ui` / `image` for decoding and thumbnail generation.

### 2. Features

**Indexing and scanning**

- Add any local folder or a drive root such as `C:\`;
- Recursive scan that skips inaccessible directories, system folders and junctions/symlinks;
- Incremental scanning: unchanged size + modification time reuses existing records;
- Cancellable at any time; 12 consecutive read failures abort the scan with a disk-health warning;
- Per-stage timing in the log (enumeration, stat, read, EXIF, decode, encode, database).

**Browsing and filtering**

- "All photos" spans every library, including archived drives;
- Folder view with cover thumbnails, photo counts and subfolder counts;
- Keyword search over filename, full path, camera make/model, lens and capture date;
- Multi-select camera and lens filters;
- Aperture, shutter speed and ISO range filters with sliders and manual input (one-sided ranges supported);
- Capture-date filter with plain year / month / day text fields instead of a calendar;
- Six sort orders: capture time ascending/descending, filename, modified time, file size, indexed time;
- Detail panel: path, capture time, dimensions, camera/lens, exposure parameters, GPS and source drive;
- Double-click opens the file location; falls back to the containing folder when the file is offline.

**Multiple drives and archiving**

- Volume GUID, serial number and label detect when a drive letter now points to a different physical disk;
- On a mismatch you choose: independent drive (archive the current index) / merge into the current index / cancel;
- If that disk was indexed before, PicContents offers to restore its old index and scan incrementally;
- Archived drives appear in their own sidebar group and can be browsed offline, restored or deleted;
- Archiving and restoring only flip a status flag, so they are instant and never duplicate thumbnails;
- Identical paths on different disks are stored as separate rows with the key `(library_id, path)`.

**Data management**

- Full database export and import (the current database is backed up before import);
- Settings shows the current index file location, allows changing it, and opens its folder;
- Changing the location migrates the database (rename on the same volume, copy + verify otherwise) with automatic rollback on failure;
- Configurable slider ranges for aperture, shutter speed and ISO;
- Custom display names for indexed folders (UI only; disk folders are never renamed).

**Reliability**

- Falls back to another writable directory when the preferred data directory is blocked;
- Errors during startup, scanning, querying and import/export are surfaced with copyable details;
- Critical errors are appended to `diagnostics.log`, which also works when launched from Explorer;
- SQLite runs in WAL mode with `synchronous=NORMAL` for fast batched writes.

### 3. UI at a glance

| Area | Description |
|---|---|
| Sidebar | All photos, indexed roots, archived drives; rescan, rename, remove |
| Toolbar | Add folder, export/import database, settings, rescan all, view switch, sort, search |
| Filter panel | Date (Y/M/D inputs), camera, lens, aperture, shutter, ISO |
| Photo grid | Thumbnail, filename, capture time, GPS badge, source-drive label in cross-library view |
| Folder view | Covers, photo counts and subfolder counts, navigable |
| Detail panel | File info, capture data, gear, exposure, dimensions, GPS, source drive |

Typical flow: add a folder, wait for indexing, browse or filter in "All photos" or under a specific root, then plug in another drive and follow the on-screen choice.

### 4. How it works

**Scan pipeline**

1. Walk directories level by level, skipping inaccessible folders and links;
2. Stat files in batches, compare size + mtime with stored signatures, build the pending list;
3. Read each file exactly once: the main isolate decodes it, then hands the same bytes to a worker for EXIF parsing;
4. A persistent worker pool parses EXIF and encodes JPEG thumbnails in parallel, avoiding a new isolate per photo;
5. Write metadata and thumbnails in batches of 128 into SQLite;
6. After the scan, delete records that no longer exist — unless the volume changed or read errors occurred, in which case cleanup is skipped.

Concurrent reads are capped at 2–3 to avoid seek storms on hard drives and to prevent bad-block retries from piling up. Progress updates are throttled to 250 ms.

**Database schema (v6)**

| Table | Purpose |
|---|---|
| `libraries` | One row per drive; `archived_at` is null for the attached/active library |
| `photos` | Photo metadata, scoped by `library_id`, unique on `(library_id, path)` |
| `photo_thumbnails` | Thumbnail BLOBs keyed by `photo_id` |
| `settings` | Slider bounds and other preferences |

Key indexes: `(library_id, capture_time)`, `(library_id, dir_path)`, `(library_id, folder_path)`, `camera_model`, `lens_model`, `iso`, `f_number`, plus a partial unique index on active library paths.

List queries only touch metadata; thumbnails are fetched by id for the current page, so filtering and sorting never scan large BLOBs.

### 5. Supported formats

`.jpg` `.jpeg` `.jpe` `.jfif` `.png` `.bmp` `.gif` `.webp` `.tif` `.tiff` `.heic` `.heif` `.avif`

Thumbnail generation depends on the platform decoder. If decoding fails, the metadata record is still kept without a thumbnail. Common JPEG/PNG/WebP/GIF/BMP files decode normally.

Thumbnail settings: longest edge 400 px, JPEG quality 82.

### 6. Data storage

**Database file**

- `piccontents_library.db` (WAL mode, with `-wal` / `-shm` while running)
- Roughly 20 KB per photo (mostly thumbnails), about 1 GB per 50,000 photos

**Directory priority**

1. User-selected location (`index_location.json`)
2. `piccontents_data` next to the executable, if it already contains a database
3. Application support directory (`piccontents` under `path_provider`'s application support path)
4. `%LOCALAPPDATA%\PicContents\piccontents`
5. `piccontents_data` next to the executable

A write probe runs on startup; if a directory is not writable (for example, blocked by security software), the next candidate is tried and an existing database is migrated there.

**Location config**

```json
{ "dir": "D:\\PicContentsData" }
```

It lives outside the database, so the app never needs to know where the database is in order to find out where it should be.

**Backups and migration**

- Before a schema upgrade the database is copied to `piccontents_library.db.bak_v6`;
- The v6 migration validates photo and thumbnail counts and rolls back on mismatch;
- After a successful migration, `VACUUM` reclaims pages left by dropped tables;
- Before an import, the current database is copied to `.bak` and restored automatically on failure.

**Export / import**

- Export produces a standalone `.db` containing thumbnails and EXIF;
- Import replaces the current index (after backing it up); older databases are upgraded on open.

### 7. Multiple drives sharing a letter

Portable drives are often assigned the same letter, for example `E:\`. PicContents handles this as follows:

1. Read the current volume's GUID, serial number and label before scanning;
2. Compare with the identity stored in the index:
   - match: same disk, normal incremental scan;
   - mismatch: choose independent drive, merge into the existing index, or cancel;
   - previously indexed: prefer restoring the archived index and scanning incrementally.
3. "Independent drive" archives the current active index, then creates a new one for the attached disk;
4. Archived libraries live under "Archived drives" in the sidebar and can be browsed offline, restored or deleted.

Because the unique key is `(library_id, path)`, identical paths on two disks are stored separately. Both appear in "All photos", distinguished by the corner label and the "Source drive" row in the detail panel. Deduplication across libraries is intentionally not performed.

### 8. Build and run

**Requirements**

- Windows 10/11 x64
- Flutter SDK with Dart `^3.13.3`
- Visual Studio 2022 with the "Desktop development with C++" workload

**Dependencies**

```bash
flutter pub get
```

**Run during development**

```bash
flutter run -d windows
```

**Build a release**

```bash
flutter build windows --release
```

Output: `build\windows\x64\runner\Release`.

> Deploy the entire output directory (including `data\flutter_assets`, DLLs and `sqlite3.dll`); copying only the exe will not start. Prefer release builds for daily use — debug builds use more memory and run pure-Dart encoding much slower.

### 9. Tests

```bash
flutter analyze
flutter test
```

Coverage includes path normalization, EXIF date parsing, formatting, filter ranges and date parsing, slider bounds, directory tree reconstruction, worker-pool decode/encode, and the v5 → v6 migration (same-path duplicates, thumbnails and indexes).

### 10. Logs and troubleshooting

`diagnostics.log` is written to the first available location:

1. Next to the executable
2. Application data directory
3. `piccontents_diagnostics.log` in the system temp directory

At the end of a scan the log receives a `[ScanTiming]` line with per-stage totals (enumerate, stat, read, EXIF, decode, encode, database).

| Symptom | What to do |
|---|---|
| Cannot add a folder / access denied | Usually security software blocking the data directory; change the index location in Settings or place the app in a writable folder |
| Very slow scan with 100% disk usage | Check `[ScanTiming]`; external hard drives and failing disks are inherently slow. The app limits concurrency and aborts after repeated read failures |
| Photos seem to disappear after swapping drives | Check "Archived drives" in the sidebar, or rescan the root and choose independent/merge |
| Startup failure | Inspect `diagnostics.log`; the error dialog also lets you copy the details |
| UI language | The UI is currently Chinese; date widgets are localized |

### 11. Performance notes

- **One disk read per photo**: decoding and EXIF parsing share the same byte buffer;
- **Persistent worker pool**: parallel EXIF parsing and JPEG encoding without per-photo isolate startup;
- **Low read concurrency**: 2–3 workers to avoid seek storms and overlapping bad-block retries;
- **Metadata / thumbnail split**: filtering, sorting and counting only scan metadata; thumbnails are fetched for the visible page;
- **Targeted indexes**: library + time, library + directory, camera, lens, ISO, aperture;
- **Batched writes**: 128 rows per batch, WAL + `NORMAL`;
- **Throttled progress**: 250 ms, so the UI is not rebuilt per photo;
- **Failure guards**: abort after 12 consecutive read errors; skip stale-record cleanup when the volume changes or reads fail.

### 12. Project layout

```text
lib/
  main.dart                    App entry point and startup error page
  models/
    photo.dart                 Photo model and sort orders
    photo_filter.dart          Filter state
    app_settings.dart          Slider bounds and preferences
  pages/
    home_page.dart             Main screen and orchestration
  services/
    database_service.dart      SQLite, migrations, queries, archiving, import/export
    scanner_service.dart       Directory walk and incremental scan pipeline
    image_indexer.dart         Indexing a single photo
    image_codec.dart           Native decode, thumbnail encoding, EXIF
    index_worker_pool.dart     Persistent isolate pool
    volume_identity.dart       Volume GUID / serial / label
    scan_timings.dart          Per-stage timing
    diagnostics.dart           Diagnostic logging
  utils/
    formatters.dart            Date, size, aperture, shutter formatting
    index_paths.dart           Index root path normalization
  widgets/
    folder_sidebar.dart        Sidebar: roots and archived drives
    filter_panel.dart          Filter panel
    photo_grid.dart            Photo grid
    photo_detail_panel.dart    Photo details
    folder_grid.dart           Folder view
    folder_breadcrumb.dart     Breadcrumb
    settings_dialog.dart       Settings
test/
  widget_test.dart             Unit tests
  database_migration_test.dart v5 → v6 migration test
```

### 13. Known limitations

- Windows desktop only;
- Metadata indexing only — no face, scene or content-based image search;
- Archived records keep their original paths; restoring and "open location" depend on the original drive letter, and offline archives only provide thumbnails and EXIF;
- HEIC/HEIF/AVIF thumbnail generation depends on platform decoding support and may produce metadata-only records;
- "All photos" does not deduplicate; the same path on two drives appears twice by design;
- The app does not back up originals and does not watch drives for changes; rescan after files change;
- Bad blocks and CRC errors are hardware failures: the software only reduces reads and reports the problem earlier.
