import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:photo_view/photo_view.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:share_plus/share_plus.dart';

// ══════════════════════════════════════════════════════
//  THUMBNAIL CACHE  (LRU, max 200 entries, concurrent 4)
// ══════════════════════════════════════════════════════

class _ThumbCache {
  static final LinkedHashMap<String, Uint8List?> _map = LinkedHashMap();
  static final Map<String, Future<Uint8List?>> _pending = {};
  static const int _max = 200;
  static const int _maxActive = 4;
  static int _activeCount = 0;
  static final List<_QueuedTask> _queue = [];

  static Future<Uint8List?> get(String path) async {
    if (_map.containsKey(path)) {
      final v = _map.remove(path);
      _map[path] = v;
      return v;
    }
    if (_pending.containsKey(path)) {
      return _pending[path];
    }
    final completer = Completer<Uint8List?>();
    _pending[path] = completer.future;
    _queue.add(_QueuedTask(path, completer));
    _processQueue();
    return completer.future;
  }

  static void _processQueue() {
    while (_activeCount < _maxActive && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      _activeCount++;
      _generate(task.path, task.completer);
    }
  }

  static void _generate(String path, Completer<Uint8List?> completer) async {
    Uint8List? result;
    try {
      result = await VideoThumbnail.thumbnailData(
        video: path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 256,
        quality: 65,
        timeMs: 500,
      );
    } catch (_) {
      result = null;
    } finally {
      if (_map.length >= _max) {
        _map.remove(_map.keys.first);
      }
      _map[path] = result;
      _pending.remove(path);
      completer.complete(result);
      _activeCount--;
      _processQueue();
    }
  }
}

class _QueuedTask {
  final String path;
  final Completer<Uint8List?> completer;
  _QueuedTask(this.path, this.completer);
}

// ══════════════════════════════════════════════════════
//  MODELS
// ══════════════════════════════════════════════════════

enum FileType { image, video, audio, document, other }

extension FTP on FileType {
  IconData get icon {
    switch (this) {
      case FileType.image:
        return Icons.image_rounded;
      case FileType.video:
        return Icons.videocam_rounded;
      case FileType.audio:
        return Icons.audiotrack_rounded;
      case FileType.document:
        return Icons.description_rounded;
      case FileType.other:
        return Icons.insert_drive_file_rounded;
    }
  }

  Color get color {
    switch (this) {
      case FileType.image:
        return const Color(0xFF00E5FF);
      case FileType.video:
        return const Color(0xFFFF4081);
      case FileType.audio:
        return const Color(0xFFFFD740);
      case FileType.document:
        return const Color(0xFF69FF47);
      case FileType.other:
        return const Color(0xFFE040FB);
    }
  }

  String get label {
    switch (this) {
      case FileType.image:
        return 'Images';
      case FileType.video:
        return 'Videos';
      case FileType.audio:
        return 'Audio';
      case FileType.document:
        return 'Docs';
      case FileType.other:
        return 'Other';
    }
  }
}

class RFile {
  final String name;
  final String path;
  final FileType type;
  final int size;
  final int confidence;
  final DateTime? modifiedDate;
  final bool isDeleted; // true = confirmed deleted/trashed, false = orphaned/unknown
  bool selected;

  RFile({
    required this.name,
    required this.path,
    required this.type,
    required this.size,
    required this.confidence,
    this.modifiedDate,
    this.isDeleted = true,
    this.selected = false,
  });

  String get sizeLabel {
    if (size <= 0) return '---';
    if (size < 1024) return '$size B';
    if (size < 1048576) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1073741824) return '${(size / 1048576).toStringAsFixed(1)} MB';
    return '${(size / 1073741824).toStringAsFixed(1)} GB';
  }

  String get dateLabel {
    if (modifiedDate == null) return '';
    return DateFormat('dd MMM yyyy  hh:mm a').format(modifiedDate!);
  }

  String get shortDate {
    if (modifiedDate == null) return '';
    return DateFormat('dd/MM/yy').format(modifiedDate!);
  }

  bool get isImage => type == FileType.image;
  bool get isVideo => type == FileType.video;
  bool get isAudio => type == FileType.audio;
  bool get isDocument => type == FileType.document;
  bool get isPdf => name.split('.').last.toLowerCase() == 'pdf';

  // HEIC/HEIF detection
  bool get isHeic {
    final ext = name.split('.').last.toLowerCase();
    return ext == 'heic' || ext == 'heif';
  }
}

extension _CA on Color {
  Color withA(double a) => withValues(alpha: a);
}

// ══════════════════════════════════════════════════════
//  SORT OPTIONS
// ══════════════════════════════════════════════════════

enum SortBy { date, name, size, type }

// ══════════════════════════════════════════════════════
//  ISOLATE SCANNER
// ══════════════════════════════════════════════════════

class _ScanMsg {
  final List<Map<String, dynamic>> files;
  final String step;
  final int progress;
  final bool done;
  const _ScanMsg(this.files, this.step, this.progress, this.done);
}

// Startup message sent TO the isolate carrying the live-paths set
class _IsolateArgs {
  final SendPort port;
  final Set<String> livePaths; // files currently in MediaStore (to exclude)
  _IsolateArgs(this.port, this.livePaths);
}

// ── Junk path filter ──
bool _isJunkPath(String path) {
  final p = path.toLowerCase();
  return p.contains('/.thumbnails/') ||
      p.contains('/thumbnails/') ||
      p.contains('/.trashed') ||
      p.contains('/.trash/') ||
      p.contains('/cache/') ||
      p.contains('/.cache/') ||
      p.contains('/android/data/com.') ||
      p.contains('/android/data/org.') ||
      p.contains('/android/obb/') ||
      p.contains('/.android_secure/') ||
      p.contains('/lost+found/') ||
      p.contains('/.nomedia') ||
      p.contains('/albumthumbs/') ||
      p.endsWith('.tmp') ||
      p.endsWith('.partial') ||
      p.endsWith('.crdownload') ||
      p.endsWith('.download');
}

bool _isInNomediaDir(String path, Set<String> nomediaDirs) {
  for (final d in nomediaDirs) {
    if (path.startsWith(d)) return true;
  }
  return false;
}

// ── Orphan scanner isolate ──
// Walks the filesystem and returns ONLY files that are NOT in MediaStore's
// live set — i.e. files that exist on disk but MediaStore no longer tracks.
// These are orphaned/deleted files that weren't caught by the trash query.
Future<void> _scanIsolate(_IsolateArgs args) async {
  final SendPort port    = args.port;
  final Set<String> live = args.livePaths; // excluded set

  const img = {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'tiff', 'tif'};
  const vid = {'mp4', 'mkv', 'avi', 'mov', '3gp', 'flv', 'wmv', 'ts', 'm4v', 'webm', 'vob', 'mpg', 'mpeg', 'rm', 'rmvb', 'f4v'};
  const aud = {'mp3', 'm4a', 'wav', 'ogg', 'flac', 'aac', 'wma', 'opus', 'amr', 'mid', 'midi', 'ape', 'ac3'};
  const doc = {'pdf', 'doc', 'docx', 'txt', 'xlsx', 'xls', 'pptx', 'ppt', 'csv', 'rtf', 'odt', 'ods', 'odp', 'epub'};

  const roots = [
    '/storage/emulated/0',
    '/storage/sdcard0',
    '/storage/sdcard1',
    '/storage/extSdCard',
    '/storage/external_SD',
    '/mnt/sdcard',
    '/mnt/extSdCard',
  ];

  const skipDirs = {
    'Android/obb', '.thumbnails', 'thumbnails', 'cache', '.cache',
    '.trash', '.Trash', 'lost+found', '.android_secure', 'albumthumbs',
    'AlbumArt', 'tmp', '.tmp', 'Recycler', 'RECYCLER', r'$RECYCLE.BIN',
  };

  final found       = <Map<String, dynamic>>[];
  final seen        = <String>{};
  final nomediaDirs = <String>{};

  void scanDir(Directory dir, int depth) {
    if (depth > 8) return;

    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(recursive: false, followLinks: false);
    } catch (_) { return; }

    // Detect .nomedia — skip whole directory
    if (entries.any((e) => e is File && e.path.split('/').last == '.nomedia')) {
      nomediaDirs.add(dir.path.endsWith('/') ? dir.path : '${dir.path}/');
      return;
    }

    for (final e in entries) {
      final name      = e.path.split('/').last;
      final nameLower = name.toLowerCase();

      if (e is Directory) {
        if (skipDirs.any((s) => nameLower == s.toLowerCase() || e.path.contains('/$s'))) continue;
        if (name.startsWith('.')) continue;
        scanDir(e, depth + 1);
        continue;
      }

      if (e is! File) continue;
      if (_isJunkPath(e.path)) continue;
      if (_isInNomediaDir(e.path, nomediaDirs)) continue;

      // ── KEY FILTER: skip files that are still live in MediaStore ──
      // live set is empty on Android < 10 so this never wrongly excludes.
      if (live.contains(e.path)) continue;

      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      final ext = name.substring(dot + 1).toLowerCase();

      String? t; int conf;
      if (img.contains(ext))      { t = 'image';    conf = 88; }
      else if (vid.contains(ext)) { t = 'video';    conf = 85; }
      else if (aud.contains(ext)) { t = 'audio';    conf = 83; }
      else if (doc.contains(ext)) { t = 'document'; conf = 80; }
      else continue;

      final absPath = e.path;
      if (seen.contains(absPath)) continue;
      seen.add(absPath);

      try {
        final st = e.statSync();
        if (st.size <= 0) continue;
        if (t == 'image'    && st.size < 1024)  continue;
        if (t == 'video'    && st.size < 10240) continue;
        if (t == 'audio'    && st.size < 4096)  continue;
        if (t == 'document' && st.size < 512)   continue;

        found.add({
          'n':   name,
          'p':   absPath,
          't':   t,
          's':   st.size,
          'c':   conf,
          'm':   st.modified.millisecondsSinceEpoch,
          'del': false, // orphaned — not confirmed deleted by MediaStore
        });

        if (found.length % 50 == 0) {
          port.send(_ScanMsg(List.from(found), 'Found ${found.length} orphaned files…', -1, false));
        }
      } catch (_) {}
    }
  }

  int rootsDone = 0;
  for (final rootPath in roots) {
    rootsDone++;
    final dir = Directory(rootPath);
    if (!dir.existsSync()) continue;
    port.send(_ScanMsg(const [], 'Deep scanning ${rootPath.split('/').last}…', (rootsDone * 60 ~/ roots.length), false));
    scanDir(dir, 0);
  }

  found.sort((a, b) => (b['m'] as int).compareTo(a['m'] as int));
  port.send(_ScanMsg(found, 'Deep scan done — ${found.length} orphaned files', 100, true));
}

RFile _fromMap(Map<String, dynamic> m) {
  FileType t;
  switch (m['t']) {
    case 'image':    t = FileType.image;    break;
    case 'video':    t = FileType.video;    break;
    case 'audio':    t = FileType.audio;    break;
    case 'document': t = FileType.document; break;
    default:         t = FileType.other;
  }
  return RFile(
    name: m['n'] as String,
    path: m['p'] as String,
    type: t,
    size: m['s'] as int,
    confidence: m['c'] as int,
    isDeleted: m['del'] == true,
    modifiedDate: m['m'] != null
        ? DateTime.fromMillisecondsSinceEpoch(m['m'] as int)
        : null,
  );
}

// ══════════════════════════════════════════════════════
//  PERMISSION / SCAN CHANNEL
// ══════════════════════════════════════════════════════

const _ch = MethodChannel('com.example.recovery_app/permissions');

// ── Fetch deleted/trashed files from MediaStore (Android 10+) ──
// Returns only files where IS_TRASHED=1 or IS_PENDING=1.
// On older Android or on error, returns empty list.
Future<List<RFile>> _fetchDeletedFiles() async {
  try {
    final raw = await _ch.invokeMethod<List<dynamic>>('scanDeletedFiles');
    if (raw == null || raw.isEmpty) return [];
    return raw.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      FileType t;
      switch (m['t'] as String?) {
        case 'image':    t = FileType.image;    break;
        case 'video':    t = FileType.video;    break;
        case 'audio':    t = FileType.audio;    break;
        case 'document': t = FileType.document; break;
        default:         t = FileType.other;
      }
      return RFile(
        name: m['n'] as String? ?? '',
        path: m['p'] as String? ?? '',
        type: t,
        size: (m['s'] as num?)?.toInt() ?? 0,
        confidence: 92,
        isDeleted: true,
        modifiedDate: m['m'] != null
            ? DateTime.fromMillisecondsSinceEpoch((m['m'] as num).toInt())
            : null,
      );
    }).where((f) => f.path.isNotEmpty && f.size > 0).toList();
  } catch (_) {
    return [];
  }
}

// ── Fetch all live (non-deleted) paths from MediaStore ──
// Used by the isolate scanner to subtract live files, leaving only
// orphaned files that are no longer tracked by MediaStore.
Future<Set<String>> _fetchLivePaths() async {
  try {
    final raw = await _ch.invokeMethod<List<dynamic>>('getLivePaths');
    if (raw == null) return {};
    return raw.cast<String>().toSet();
  } catch (_) {
    return {};
  }
}

// ══════════════════════════════════════════════════════
//  MAIN
// ══════════════════════════════════════════════════════

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const RecoveryApp());
}

class RecoveryApp extends StatelessWidget {
  const RecoveryApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepRecover',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF080C14),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          surface: Color(0xFF0D1321),
        ),
        // 🔴 FIXED: disable built‑in scrollbars so only custom one appears
        scrollbarTheme: ScrollbarThemeData(
          thumbVisibility: WidgetStateProperty.all(false),
          trackVisibility: WidgetStateProperty.all(false),
          thickness: WidgetStateProperty.all(0),
        ),
      ),
      home: const PermissionScreen(),
    );
  }
}

// ══════════════════════════════════════════════════════
//  PERMISSION SCREEN
// ══════════════════════════════════════════════════════

class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});
  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _loading = true;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final ok = await _ch.invokeMethod<bool>('checkStoragePermission') ?? false;
      if (ok && mounted) {
        _go();
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _loading = false;
        _msg = 'Allow storage access to scan deleted files';
      });
    }
  }

  Future<void> _request() async {
    setState(() {
      _loading = true;
      _msg = 'Requesting…';
    });
    try {
      final ok = await _ch.invokeMethod<bool>('requestStoragePermission') ?? false;
      if (ok && mounted) {
        _go();
        return;
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _msg = 'Permission denied. Please allow in Settings.';
        });
      }
    } catch (_) {
      _go();
    }
  }

  void _go() => Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080C14),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF00E5FF).withA(0.08),
                    border: Border.all(
                      color: const Color(0xFF00E5FF).withA(0.4),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.security_rounded,
                    color: Color(0xFF00E5FF),
                    size: 52,
                  ),
                ),
                const SizedBox(height: 32),
                const Text(
                  'DEEP RECOVER',
                  style: TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Android File Recovery',
                  style: TextStyle(
                    color: Color(0xFF4A6FA5),
                    fontSize: 13,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  _msg,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF4A6FA5),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 40),
                if (_loading)
                  const CircularProgressIndicator(color: Color(0xFF00E5FF))
                else ...[
                  GestureDetector(
                    onTap: _request,
                    child: Container(
                      width: double.infinity,
                      height: 56,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF00B8D4), Color(0xFF00E5FF)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00E5FF).withA(0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.folder_open, color: Colors.black, size: 20),
                          SizedBox(width: 10),
                          Text(
                            'GRANT PERMISSION',
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _go,
                    child: const Text(
                      'Skip (limited scan)',
                      style: TextStyle(color: Color(0xFF4A6FA5), fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  HOME SCREEN
// ══════════════════════════════════════════════════════

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late AnimationController _pulse;
  late AnimationController _glow;
  late Animation<double> _pulseA;
  late Animation<double> _glowA;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseA = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
    _glowA = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _glow, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.3),
            radius: 1.2,
            colors: [Color(0xFF0D1F3C), Color(0xFF080C14)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E5FF).withA(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF00E5FF).withA(0.3)),
                      ),
                      child: const Icon(Icons.radar, color: Color(0xFF00E5FF), size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DEEP RECOVER',
                          style: TextStyle(
                            color: Color(0xFF00E5FF),
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 3,
                          ),
                        ),
                        Text(
                          'Android File Recovery Engine',
                          style: TextStyle(
                            color: Color(0xFF4A6FA5),
                            fontSize: 10,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      const SizedBox(height: 30),
                      GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const ScanScreen()),
                        ),
                        child: AnimatedBuilder(
                          animation: Listenable.merge([_pulseA, _glowA]),
                          builder: (_, _) => Transform.scale(
                            scale: _pulseA.value,
                            child: SizedBox(
                              width: 220,
                              height: 220,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  for (int i = 0; i < 4; i++)
                                    Container(
                                      width: 50.0 + i * 50,
                                      height: 50.0 + i * 50,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: const Color(0xFF00E5FF).withA(
                                            (0.05 + i * 0.04) * _glowA.value,
                                          ),
                                          width: 1,
                                        ),
                                      ),
                                    ),
                                  Container(
                                    width: 110,
                                    height: 110,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: RadialGradient(
                                        colors: [
                                          const Color(0xFF00E5FF).withA(0.25),
                                          const Color(0xFF0D3B5E).withA(0.9),
                                        ],
                                      ),
                                      border: Border.all(
                                        color: const Color(0xFF00E5FF)
                                            .withA(0.5 * _glowA.value),
                                        width: 1.5,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF00E5FF)
                                              .withA(0.25 * _glowA.value),
                                          blurRadius: 30,
                                          spreadRadius: 8,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.manage_search_rounded,
                                      color: Color(0xFF00E5FF),
                                      size: 48,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap to start scanning',
                        style: TextStyle(
                          color: Color(0xFF4A6FA5),
                          fontSize: 12,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 32),
                      Row(
                        children: [
                          _card(Icons.image_rounded, 'Photos', 'JPG PNG HEIC', const Color(0xFF00E5FF)),
                          const SizedBox(width: 10),
                          _card(Icons.videocam_rounded, 'Videos', 'MP4 MKV AVI', const Color(0xFFFF4081)),
                          const SizedBox(width: 10),
                          _card(Icons.audiotrack_rounded, 'Audio', 'MP3 WAV AAC', const Color(0xFFFFD740)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _card(Icons.description_rounded, 'Docs', 'PDF DOCX TXT', const Color(0xFF69FF47)),
                          const SizedBox(width: 10),
                          _card(Icons.chat_rounded, 'WhatsApp', 'Media files', const Color(0xFF25D366)),
                          const SizedBox(width: 10),
                          _card(Icons.send, 'Telegram', 'Media files', const Color(0xFF2AABEE)),
                        ],
                      ),
                      const SizedBox(height: 32),
                      GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const ScanScreen()),
                        ),
                        child: Container(
                          width: double.infinity,
                          height: 60,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            gradient: const LinearGradient(
                              colors: [Color(0xFF00B8D4), Color(0xFF00E5FF)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF00E5FF).withA(0.4),
                                blurRadius: 24,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.radar, color: Colors.black, size: 24),
                              SizedBox(width: 12),
                              Text(
                                'START DEEP SCAN',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  letterSpacing: 2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(IconData icon, String title, String sub, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1321),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF1A2740)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  SCAN SCREEN
// ══════════════════════════════════════════════════════

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with TickerProviderStateMixin {
  late AnimationController _radar;
  double _progress = 0;
  bool _indeterminate = false; // true = show indeterminate progress bar
  String _step = 'Starting scan…';
  List<RFile> _files = [];
  bool _done = false;
  Isolate? _iso;
  ReceivePort? _port;

  @override
  void initState() {
    super.initState();
    _radar = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _startScan();
  }

  Future<void> _startScan() async {
    // ── Phase 1: MediaStore trash query (Android 10+) ──
    // Fast, authoritative — returns files user deleted (moved to trash).
    setState(() {
      _step = 'Checking trash & deleted items…';
      _progress = 0.05;
      _indeterminate = false;
    });

    final deletedFiles = await _fetchDeletedFiles();
    if (deletedFiles.isNotEmpty && mounted) {
      setState(() {
        _files = deletedFiles;
        _step = 'Found ${deletedFiles.length} deleted items, deep scanning…';
        _progress = 0.20;
      });
    }

    // ── Phase 2: Get live paths from MediaStore ──
    // We send this set to the isolate so it can exclude live files.
    setState(() {
      _step = 'Building live file index…';
      _progress = 0.25;
    });
    final livePaths = await _fetchLivePaths();

    // ── Phase 3: Filesystem orphan scan (background isolate) ──
    // Finds files on disk that MediaStore no longer tracks (orphaned).
    _port = ReceivePort();
    try {
      _iso = await Isolate.spawn(
        _scanIsolate,
        _IsolateArgs(_port!.sendPort, livePaths),
      );
    } catch (e) {
      // Isolate failed — use trash results only
      if (mounted) {
        if (deletedFiles.isNotEmpty) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => ResultScreen(files: List.from(deletedFiles)),
            ),
          );
        } else {
          setState(() => _step = 'Scan error: $e');
        }
      }
      return;
    }

    _port!.listen((msg) {
      if (msg is! _ScanMsg || !mounted) return;

      setState(() {
        if (msg.files.isNotEmpty) {
          // Merge: trash results (del:true, conf:92) + orphaned filesystem
          // results (del:false, lower conf). Dedup by path — trash wins.
          final merged = <String, RFile>{};
          for (final f in deletedFiles) {
            merged[f.path] = f;
          }
          for (final raw in msg.files) {
            final f = _fromMap(raw);
            if (!merged.containsKey(f.path)) {
              merged[f.path] = f;
            }
          }
          _files = merged.values.toList();
        }

        _step = msg.step;
        if (msg.progress < 0) {
          _indeterminate = true;
        } else {
          _indeterminate = false;
          _progress = 0.25 + (msg.progress / 100.0) * 0.75;
        }
        _done = msg.done;
      });

      if (msg.done) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => ResultScreen(files: List.from(_files)),
              ),
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _iso?.kill(priority: Isolate.immediate);
    _port?.close();
    _radar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080C14),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      _iso?.kill();
                      Navigator.pop(context);
                    },
                    child: const Icon(
                      Icons.arrow_back_ios_new,
                      color: Color(0xFF4A6FA5),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    _done ? 'SCAN COMPLETE' : 'SCANNING DELETED FILES…',
                    style: const TextStyle(
                      color: Color(0xFF00E5FF),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 40),
              RotationTransition(
                turns: _radar,
                child: SizedBox(
                  width: 180,
                  height: 180,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      for (int i = 0; i < 3; i++)
                        Container(
                          width: 60.0 + i * 50,
                          height: 60.0 + i * 50,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFF00E5FF).withA(0.12 + i * 0.06),
                              width: 1,
                            ),
                          ),
                        ),
                      Container(
                        width: 80,
                        height: 2,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.transparent, Color(0xFF00E5FF)],
                          ),
                        ),
                      ),
                      Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Color(0xFF00E5FF),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: _indeterminate
                    ? const LinearProgressIndicator(
                        backgroundColor: Color(0xFF1A2740),
                        valueColor: AlwaysStoppedAnimation(Color(0xFF00E5FF)),
                        minHeight: 8,
                      )
                    : LinearProgressIndicator(
                        value: _progress,
                        backgroundColor: const Color(0xFF1A2740),
                        valueColor: const AlwaysStoppedAnimation(Color(0xFF00E5FF)),
                        minHeight: 8,
                      ),
              ),
              const SizedBox(height: 14),
              Text(
                _step,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                _indeterminate
                    ? '…'
                    : '${(_progress * 100).toInt()}%',
                style: const TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (_files.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF69FF47).withA(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF69FF47).withA(0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_circle, color: Color(0xFF69FF47), size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Found ${_files.length} files…',
                        style: const TextStyle(color: Color(0xFF69FF47), fontSize: 13),
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

// ══════════════════════════════════════════════════════
//  RESULT SCREEN
// ══════════════════════════════════════════════════════

class ResultScreen extends StatefulWidget {
  final List<RFile> files;
  const ResultScreen({super.key, required this.files});
  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  FileType? _filter;
  bool _gallery = true;
  SortBy _sortBy = SortBy.date;
  bool _sortAsc = false;
  String _search = '';
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  bool _showSearch = false;

  // custom scrollbar state
  double _scrollFraction = 0.0;
  bool _isDraggingScrollbar = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      if (_scrollCtrl.hasClients &&
          _scrollCtrl.position.maxScrollExtent > 0 &&
          !_isDraggingScrollbar) {
        setState(() {
          _scrollFraction =
              _scrollCtrl.offset / _scrollCtrl.position.maxScrollExtent;
        });
      }
    });
  }

  List<RFile> get _shown {
    var list = _filter == null
        ? widget.files
        : widget.files.where((f) => f.type == _filter).toList();

    if (_search.isNotEmpty) {
      list = list
          .where((f) => f.name.toLowerCase().contains(_search.toLowerCase()))
          .toList();
    }

    list.sort((a, b) {
      int cmp;
      switch (_sortBy) {
        case SortBy.date:
          cmp = (a.modifiedDate ?? DateTime(0))
              .compareTo(b.modifiedDate ?? DateTime(0));
          break;
        case SortBy.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortBy.size:
          cmp = a.size.compareTo(b.size);
          break;
        case SortBy.type:
          cmp = a.type.index.compareTo(b.type.index);
          break;
      }
      return _sortAsc ? cmp : -cmp;
    });
    return list;
  }

  int get _selCount => widget.files.where((f) => f.selected).length;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _deleteSelected() async {
    final sel = widget.files.where((f) => f.selected).toList();
    if (sel.isEmpty) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Delete ${sel.length} file${sel.length > 1 ? 's' : ''}?',
        body: 'This will permanently delete the selected files from your device.',
        confirm: 'DELETE',
        confirmColor: const Color(0xFFFF4081),
      ),
    );
    if (ok != true) {
      return;
    }
    int deleted = 0;
    for (final f in sel) {
      try {
        File(f.path).deleteSync();
        deleted++;
      } catch (_) {}
    }
    setState(() => widget.files.removeWhere((f) => f.selected));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Deleted $deleted file${deleted != 1 ? 's' : ''}'),
        backgroundColor: const Color(0xFFFF4081),
      ));
    }
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D1321),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sort & Order',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: SortBy.values.map((s) {
                  final labels = {
                    SortBy.date: 'Date',
                    SortBy.name: 'Name',
                    SortBy.size: 'Size',
                    SortBy.type: 'Type',
                  };
                  final active = _sortBy == s;
                  return GestureDetector(
                    onTap: () {
                      setS(() {});
                      setState(() {
                        if (_sortBy == s) {
                          _sortAsc = !_sortAsc;
                        } else {
                          _sortBy = s;
                        }
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(0xFF00E5FF).withA(0.15)
                            : const Color(0xFF1A2740),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: active
                              ? const Color(0xFF00E5FF).withA(0.6)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            labels[s]!,
                            style: TextStyle(
                              color: active
                                  ? const Color(0xFF00E5FF)
                                  : const Color(0xFF4A6FA5),
                              fontSize: 13,
                              fontWeight: active
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          if (active) ...[
                            const SizedBox(width: 4),
                            Icon(
                              _sortAsc
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              color: const Color(0xFF00E5FF),
                              size: 14,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080C14),
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            if (_showSearch) _searchBar(),
            _filterBar(),
            _viewToggle(),
            _stats(),
            Expanded(
              child: widget.files.isEmpty
                  ? _empty()
                  : Stack(children: [
                      _content(),
                      _customScrollbar(), // 🔴 FIXED: direct child of Stack
                    ]),
            ),
            if (_selCount > 0) _bottomBar(),
          ],
        ),
      ),
    );
  }

  // 🔴 FIXED: Positioned is direct child of Stack; LayoutBuilder inside it
  Widget _customScrollbar() {
    return Positioned(
      right: 1,
      top: 0,
      bottom: 0,
      width: 18,
      child: LayoutBuilder(builder: (ctx, constraints) {
        const thumbH = 56.0;
        const edgePad = 12.0;
        final trackH = constraints.maxHeight - edgePad * 2;
        final maxOffset = (trackH - thumbH).clamp(0.0, double.infinity);
        final thumbTop = edgePad + (_scrollFraction * maxOffset).clamp(0.0, maxOffset);

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (_) => setState(() => _isDraggingScrollbar = true),
          onVerticalDragUpdate: (d) {
            if (!_scrollCtrl.hasClients) return;
            final frac = ((d.localPosition.dy - thumbH / 2 - edgePad) / maxOffset)
                .clamp(0.0, 1.0);
            setState(() => _scrollFraction = frac);
            _scrollCtrl.jumpTo(frac * _scrollCtrl.position.maxScrollExtent);
          },
          onVerticalDragEnd: (_) => setState(() => _isDraggingScrollbar = false),
          onVerticalDragCancel: () => setState(() => _isDraggingScrollbar = false),
          child: Stack(clipBehavior: Clip.none, children: [
            // Track
            Positioned(
              top: edgePad,
              bottom: edgePad,
              left: 7,
              width: 3,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1A2740),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            // Thumb
            AnimatedPositioned(
              duration: const Duration(milliseconds: 30),
              top: thumbTop,
              left: 2,
              width: 13,
              height: thumbH,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  color: _isDraggingScrollbar
                      ? const Color(0xFF00E5FF)
                      : const Color(0xFF00E5FF).withA(0.55),
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: _isDraggingScrollbar
                      ? [BoxShadow(
                          color: const Color(0xFF00E5FF).withA(0.5),
                          blurRadius: 12,
                        )]
                      : [],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (int i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(height: 3),
                      Container(
                        width: 7,
                        height: 1.5,
                        decoration: BoxDecoration(
                          color: Colors.white.withA(0.7),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Floating % label while dragging
            if (_isDraggingScrollbar)
              Positioned(
                top: (thumbTop + thumbH / 2 - 14)
                    .clamp(0.0, constraints.maxHeight - 28.0),
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D1321),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF00E5FF).withA(0.5)),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withA(0.4), blurRadius: 8),
                    ],
                  ),
                  child: Text(
                    '${(_scrollFraction * 100).toInt()}%',
                    style: const TextStyle(
                      color: Color(0xFF00E5FF),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ]),
        );
      }),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: const Icon(
              Icons.arrow_back_ios_new,
              color: Color(0xFF4A6FA5),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DELETED FILES',
                  style: TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  'Tap = Preview   Long Press = Select',
                  style: TextStyle(color: Color(0xFF4A6FA5), fontSize: 10),
                ),
              ],
            ),
          ),
          // Search toggle
          GestureDetector(
            onTap: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _search = '';
                _searchCtrl.clear();
              }
            }),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _showSearch
                    ? const Color(0xFF00E5FF).withA(0.15)
                    : const Color(0xFF0D1321),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _showSearch
                      ? const Color(0xFF00E5FF).withA(0.5)
                      : const Color(0xFF1A2740),
                ),
              ),
              child: Icon(
                Icons.search,
                color: _showSearch
                    ? const Color(0xFF00E5FF)
                    : const Color(0xFF4A6FA5),
                size: 18,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Sort button
          GestureDetector(
            onTap: _showSortSheet,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1321),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1A2740)),
              ),
              child: const Icon(Icons.sort, color: Color(0xFF4A6FA5), size: 18),
            ),
          ),
          const SizedBox(width: 8),
          // Select all
          GestureDetector(
            onTap: () => setState(() {
              final all = widget.files.every((f) => f.selected);
              for (final f in widget.files) {
                f.selected = !all;
              }
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1321),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1A2740)),
              ),
              child: const Text(
                'ALL',
                style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0xFF0D1321),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF00E5FF).withA(0.3)),
        ),
        child: TextField(
          controller: _searchCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'Search files…',
            hintStyle: TextStyle(color: Color(0xFF4A6FA5), fontSize: 13),
            prefixIcon: Icon(Icons.search, color: Color(0xFF4A6FA5), size: 18),
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 10),
          ),
          onChanged: (v) => setState(() => _search = v),
        ),
      ),
    );
  }

  Widget _filterBar() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        children: [
          _chip(null, 'All', Icons.apps),
          for (final t in FileType.values) _chip(t, t.label, t.icon),
        ],
      ),
    );
  }

  Widget _chip(FileType? t, String label, IconData icon) {
    final sel = _filter == t;
    final c = t?.color ?? const Color(0xFF00E5FF);
    return GestureDetector(
      onTap: () => setState(() {
        _filter = t;
        _scrollCtrl.jumpTo(0);
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: sel ? c.withA(0.15) : const Color(0xFF0D1321),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: sel ? c.withA(0.6) : const Color(0xFF1A2740),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: sel ? c : const Color(0xFF4A6FA5), size: 13),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: sel ? c : const Color(0xFF4A6FA5),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _viewToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        children: [
          // Sort label
          Text(
            '${_sortBy.name[0].toUpperCase()}${_sortBy.name.substring(1)} ${_sortAsc ? '↑' : '↓'}',
            style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 11),
          ),
          const Spacer(),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0D1321),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF1A2740)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _togBtn(Icons.grid_view_rounded, true),
                _togBtn(Icons.list_rounded, false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _togBtn(IconData icon, bool isGrid) {
    final active = _gallery == isGrid;
    return GestureDetector(
      onTap: () => setState(() => _gallery = isGrid),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF00E5FF).withA(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          color: active ? const Color(0xFF00E5FF) : const Color(0xFF4A6FA5),
          size: 18,
        ),
      ),
    );
  }

  Widget _stats() {
    final deletedCount = _shown.where((f) => f.isDeleted).length;
    final orphanCount  = _shown.where((f) => !f.isDeleted).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Row(
        children: [
          _badge('${_shown.length}', 'Total', const Color(0xFF00E5FF)),
          const SizedBox(width: 12),
          if (deletedCount > 0) ...[
            _badge('$deletedCount', 'Deleted', const Color(0xFFFF4081)),
            const SizedBox(width: 12),
          ],
          if (orphanCount > 0) ...[
            _badge('$orphanCount', 'Orphaned', const Color(0xFFFFD740)),
            const SizedBox(width: 12),
          ],
          _badge('$_selCount', 'Selected', const Color(0xFF69FF47)),
        ],
      ),
    );
  }

  Widget _badge(String v, String l, Color c) {
    return Row(
      children: [
        Text(v, style: TextStyle(color: c, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(width: 4),
        Text(l, style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 11)),
      ],
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, color: Color(0xFF1A2740), size: 64),
            const SizedBox(height: 16),
            const Text(
              'No deleted files found',
              style: TextStyle(color: Color(0xFF4A6FA5), fontSize: 16),
            ),
            const SizedBox(height: 12),
            const Text(
              'On Android 11+, grant "All Files Access" for best results.\n'
              'Recently deleted files may appear in Gallery trash.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF2A3F5F), fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.4),
                  ),
                ),
                child: const Text(
                  'Back & Try Again',
                  style: TextStyle(
                    color: Color(0xFF00E5FF),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    final list = _shown;
    if (list.isEmpty) {
      return const Center(
        child: Text('No files here', style: TextStyle(color: Color(0xFF4A6FA5))),
      );
    }
    return _gallery ? _gridView(list) : _listView(list);
  }

  // ── GRID ── (no built‑in scrollbar, custom scrollbar only)
  Widget _gridView(List<RFile> list) {
    return GridView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(10, 10, 22, 10),
      cacheExtent: 800,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => RepaintBoundary(child: _gridItem(list[i])),
    );
  }

  Widget _gridItem(RFile f) {
    return GestureDetector(
      onTap: () => _open(f),
      onLongPress: () => setState(() => f.selected = !f.selected),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: _thumb(f),
          ),
          if (f.selected)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: f.type.color.withA(0.45),
                border: Border.all(color: f.type.color, width: 2),
              ),
              child: const Center(
                child: Icon(Icons.check_circle, color: Colors.white, size: 26),
              ),
            ),
          if (f.isVideo && !f.selected)
            const Center(
              child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 30),
            ),
          if (f.isAudio && !f.selected)
            const Center(
              child: Icon(Icons.music_note_rounded, color: Color(0xFFFFD740), size: 30),
            ),
          // Deleted / Orphan badge — top left
          if (!f.selected)
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withA(0.65),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  f.isDeleted ? '🗑' : '👻',
                  style: const TextStyle(fontSize: 9),
                ),
              ),
            ),
          if (!f.isImage && !f.isVideo)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: f.type.color.withA(0.9),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Icon(f.type.icon, color: Colors.black, size: 11),
              ),
            ),
          if (f.modifiedDate != null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(7),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black.withA(0.75), Colors.transparent],
                  ),
                ),
                child: Text(
                  f.shortDate,
                  style: const TextStyle(color: Colors.white70, fontSize: 7),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── LIST ── (no built‑in scrollbar, custom scrollbar only)
  Widget _listView(List<RFile> list) {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(14, 8, 22, 8),
      itemCount: list.length,
      itemBuilder: (_, i) => RepaintBoundary(child: _listItem(list[i])),
    );
  }

  Widget _listItem(RFile f) {
    return GestureDetector(
      onTap: () => _open(f),
      onLongPress: () => setState(() => f.selected = !f.selected),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: f.selected ? f.type.color.withA(0.08) : const Color(0xFF0D1321),
          border: Border.all(
            color: f.selected
                ? f.type.color.withA(0.4)
                : const Color(0xFF1A2740),
          ),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 56, height: 56, child: _thumb(f)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  if (f.modifiedDate != null)
                    Text(
                      f.dateLabel,
                      style: const TextStyle(
                        color: Color(0xFF4A6FA5),
                        fontSize: 10,
                      ),
                    ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        f.sizeLabel,
                        style: const TextStyle(
                          color: Color(0xFF4A6FA5),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 48,
                        height: 3,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: f.confidence / 100,
                            backgroundColor: const Color(0xFF1A2740),
                            valueColor: AlwaysStoppedAnimation(f.type.color),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${f.confidence}%',
                        style: TextStyle(color: f.type.color, fontSize: 10),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: f.isDeleted
                              ? const Color(0xFFFF4081).withA(0.15)
                              : const Color(0xFFFFD740).withA(0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: f.isDeleted
                                ? const Color(0xFFFF4081).withA(0.5)
                                : const Color(0xFFFFD740).withA(0.5),
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          f.isDeleted ? 'DELETED' : 'ORPHAN',
                          style: TextStyle(
                            color: f.isDeleted
                                ? const Color(0xFFFF4081)
                                : const Color(0xFFFFD740),
                            fontSize: 7,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: f.selected ? f.type.color : Colors.transparent,
                border: Border.all(
                  color: f.selected ? f.type.color : const Color(0xFF1A2740),
                  width: 2,
                ),
              ),
              child: f.selected
                  ? const Icon(Icons.check, size: 12, color: Colors.black)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumb(RFile f) {
    if (f.isImage) {
      // 🔴 FIXED: HEIC/HEIF files cause crash – show a styled placeholder
      if (f.isHeic) {
        return Container(
          color: f.type.color.withA(0.12),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(f.type.icon, color: f.type.color.withA(0.7), size: 32),
                const SizedBox(height: 4),
                const Text(
                  'HEIC/HEIF',
                  style: TextStyle(color: Colors.white70, fontSize: 8),
                ),
                const Text(
                  'Save to view',
                  style: TextStyle(color: Colors.white54, fontSize: 6),
                ),
              ],
            ),
          ),
        );
      }
      return Image.file(
        File(f.path),
        fit: BoxFit.cover,
        cacheWidth: 300,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(f),
      );
    }
    if (f.isVideo) {
      return _VideoThumb(path: f.path, file: f);
    }
    return _placeholder(f);
  }

  Widget _placeholder(RFile f) {
    return Container(
      color: f.type.color.withA(0.08),
      child: Center(child: Icon(f.type.icon, color: f.type.color, size: 28)),
    );
  }

  void _open(RFile f) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PreviewScreen(file: f)),
    );
  }

  Widget _bottomBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1321),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A2740)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$_selCount selected',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const Text(
                '/Download/Recovered/',
                style: TextStyle(color: Color(0xFF4A6FA5), fontSize: 10),
              ),
            ],
          ),
          const Spacer(),
          GestureDetector(
            onTap: _deleteSelected,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: const Color(0xFFFF4081).withA(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFF4081).withA(0.4)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_rounded, color: Color(0xFFFF4081), size: 18),
                  SizedBox(width: 4),
                  Text(
                    'DELETE',
                    style: TextStyle(
                      color: Color(0xFFFF4081),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => RecoveryDialog(
                files: widget.files.where((f) => f.selected).toList(),
              ),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00B8D4), Color(0xFF00E5FF)],
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withA(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download_rounded, color: Colors.black, size: 18),
                  SizedBox(width: 4),
                  Text(
                    'RECOVER',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  VIDEO THUMBNAIL  (async + LRU cached + concurrency limit)
// ══════════════════════════════════════════════════════

class _VideoThumb extends StatefulWidget {
  final String path;
  final RFile file;
  const _VideoThumb({required this.path, required this.file});
  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  Uint8List? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await _ThumbCache.get(widget.path);
    if (mounted) {
      setState(() {
        _data = d;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: const Color(0xFFFF4081).withA(0.06),
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              color: Color(0xFFFF4081),
              strokeWidth: 2,
            ),
          ),
        ),
      );
    }
    if (_data != null) {
      return Image.memory(_data!, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return Container(
      color: const Color(0xFFFF4081).withA(0.08),
      child: const Center(
        child: Icon(Icons.videocam_rounded, color: Color(0xFFFF4081), size: 26),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  PREVIEW SCREEN
// ══════════════════════════════════════════════════════

class PreviewScreen extends StatelessWidget {
  final RFile file;
  const PreviewScreen({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              file.name,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
            if (file.modifiedDate != null)
              Text(
                file.dateLabel,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded, color: Color(0xFF00E5FF)),
            onPressed: () => _showInfo(context),
          ),
          IconButton(
            icon: const Icon(Icons.share_rounded, color: Color(0xFFFFD740)),
            onPressed: () => _share(context),
          ),
          IconButton(
            icon: const Icon(Icons.download_rounded, color: Color(0xFF00E5FF)),
            onPressed: () => _save(context),
          ),
          IconButton(
            icon: const Icon(Icons.delete_rounded, color: Color(0xFFFF4081)),
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (file.isImage) {
      // 🔴 FIXED: Show a clear message for HEIC instead of crashing
      if (file.isHeic) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: file.type.color.withA(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  file.type.icon,
                  color: file.type.color,
                  size: 60,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'HEIC/HEIF Preview Unavailable',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                'Save to view in Gallery app',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ],
          ),
        );
      }
      return PhotoView(
        imageProvider: FileImage(File(file.path)),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 5,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (_, ev) => Center(
          child: CircularProgressIndicator(
            value: ev?.expectedTotalBytes != null
                ? ev!.cumulativeBytesLoaded / ev.expectedTotalBytes!
                : null,
            color: const Color(0xFF00E5FF),
          ),
        ),
        errorBuilder: (_, _, _) => Center(child: _noPreview()),
      );
    }
    if (file.isVideo) return _VideoPlayer(file: file);
    if (file.isAudio) return _AudioPlayerWidget(file: file);
    if (file.isPdf)   return _PdfViewerWidget(file: file);
    return Center(child: _noPreview());
  }

  void _showInfo(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (_) => Dialog(
        backgroundColor: const Color(0xFF0D1321),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(file.type.icon, color: file.type.color, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    file.name,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ]),
              const Divider(color: Color(0xFF1A2740), height: 24),
              _infoRow('Type',       file.type.label),
              _infoRow('Size',       file.sizeLabel),
              _infoRow('Date',       file.dateLabel.isEmpty ? 'Unknown' : file.dateLabel),
              _infoRow('Confidence','${file.confidence}%'),
              _infoRow('Path',       file.path),
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A2740),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('CLOSE',
                        style: TextStyle(color: Color(0xFF4A6FA5),
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 80,
            child: Text(k, style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 12))),
        Expanded(child: Text(v, style: const TextStyle(color: Colors.white, fontSize: 12))),
      ]),
    );
  }

  void _share(BuildContext ctx) async {
    try {
      // ignore: deprecated_member_use
      await Share.shareXFiles([XFile(file.path)], text: file.name);
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text('Share failed: $e'),
          backgroundColor: const Color(0xFFFF4081),
        ));
      }
    }
  }

  void _save(BuildContext ctx) {
    try {
      Directory('/storage/emulated/0/Download/Recovered').createSync(recursive: true);
      File(file.path)
          .copySync('/storage/emulated/0/Download/Recovered/${file.name}');
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
        content: Text('Saved to /Download/Recovered/'),
        backgroundColor: Color(0xFF69FF47),
      ));
    } catch (e) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('Save failed: $e'),
        backgroundColor: const Color(0xFFFF4081),
      ));
    }
  }

  void _confirmDelete(BuildContext ctx) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (_) => const _ConfirmDialog(
        title: 'Delete this file?',
        body: 'This action cannot be undone.',
        confirm: 'DELETE',
        confirmColor: Color(0xFFFF4081),
      ),
    );
    if (ok != true) {
      return;
    }
    try {
      File(file.path).deleteSync();
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
          content: Text('File deleted'),
          backgroundColor: Color(0xFFFF4081),
        ));
        Navigator.pop(ctx);
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: const Color(0xFFFF4081),
        ));
      }
    }
  }

  Widget _noPreview() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(file.type.icon, color: file.type.color, size: 80),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            file.name,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        Text(file.sizeLabel, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        if (file.modifiedDate != null) ...[
          const SizedBox(height: 4),
          Text(file.dateLabel, style: const TextStyle(color: Colors.grey, fontSize: 11)),
        ],
        const SizedBox(height: 4),
        Text(
          '${file.confidence}% confidence',
          style: TextStyle(color: file.type.color, fontSize: 12),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════
//  VIDEO PLAYER  (surface‑released bug fixed)
// ══════════════════════════════════════════════════════

class _VideoPlayer extends StatefulWidget {
  final RFile file;
  const _VideoPlayer({required this.file});
  @override
  State<_VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<_VideoPlayer> {
  VideoPlayerController? _ctrl;
  bool _ready = false;
  bool _error = false;
  String _errorMsg = '';
  bool _showCtrl = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final ctrl = VideoPlayerController.file(
        File(widget.file.path),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      await ctrl.initialize();
      if (!mounted) {
        ctrl.dispose();
        return;
      }
      ctrl.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() {
        _ctrl = ctrl;
        _ready = true;
      });
      await ctrl.play();
      _sched();
    } catch (e) {
      if (mounted) setState(() { _error = true; _errorMsg = e.toString(); });
    }
  }

  void _sched() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showCtrl = false);
    });
  }

  void _tap() {
    setState(() => _showCtrl = !_showCtrl);
    if (_showCtrl) _sched();
  }

  void _playPause() {
    if (_ctrl == null) return;
    _ctrl!.value.isPlaying ? _ctrl!.pause() : _ctrl!.play();
    setState(() {});
    _sched();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    final c = _ctrl;
    _ctrl = null;
    Future.delayed(const Duration(milliseconds: 300), () => c?.dispose());
    super.dispose();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_rounded, color: Color(0xFFFF4081), size: 64),
            const SizedBox(height: 16),
            const Text('Video could not be played',
                style: TextStyle(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 8),
            Text(_errorMsg,
                style: const TextStyle(color: Colors.grey, fontSize: 11),
                textAlign: TextAlign.center),
          ]),
        ),
      );
    }

    if (!_ready || _ctrl == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFFF4081)),
            SizedBox(height: 14),
            Text(
              'Loading video…',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      );
    }

    final pos = _ctrl!.value.position;
    final dur = _ctrl!.value.duration;
    final playing = _ctrl!.value.isPlaying;

    return GestureDetector(
      onTap: _tap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: _ctrl!.value.aspectRatio,
              child: VideoPlayer(_ctrl!),
            ),
          ),
          AnimatedOpacity(
            opacity: _showCtrl ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 250),
            child: IgnorePointer(
              ignoring: !_showCtrl,
              child: Column(
                children: [
                  const Spacer(),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withAlpha(210),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
                    child: Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: const Color(0xFFFF4081),
                            inactiveTrackColor: Colors.white24,
                            thumbColor: const Color(0xFFFF4081),
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 8,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 18,
                            ),
                            trackHeight: 3,
                          ),
                          child: Slider(
                            value: dur.inMilliseconds > 0
                                ? pos.inMilliseconds
                                    .toDouble()
                                    .clamp(0, dur.inMilliseconds.toDouble())
                                : 0,
                            min: 0,
                            max: dur.inMilliseconds > 0
                                ? dur.inMilliseconds.toDouble()
                                : 1,
                            onChanged: (v) {
                              _ctrl!.seekTo(Duration(milliseconds: v.toInt()));
                              _sched();
                            },
                          ),
                        ),
                        Row(
                          children: [
                            Text(
                              _fmt(pos),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                            Text(
                              ' / ',
                              style: TextStyle(
                                color: Colors.white.withA(0.3),
                                fontSize: 11,
                              ),
                            ),
                            Text(
                              _fmt(dur),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: () {
                                _ctrl!.seekTo(
                                  pos - const Duration(seconds: 10),
                                );
                                _sched();
                              },
                              child: const Icon(
                                Icons.replay_10,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                            const SizedBox(width: 14),
                            GestureDetector(
                              onTap: _playPause,
                              child: Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFF4081).withAlpha(220),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  color: Colors.white,
                                  size: 30,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            GestureDetector(
                              onTap: () {
                                _ctrl!.seekTo(
                                  pos + const Duration(seconds: 10),
                                );
                                _sched();
                              },
                              child: const Icon(
                                Icons.forward_10,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  AUDIO PLAYER
// ══════════════════════════════════════════════════════

class _AudioPlayerWidget extends StatefulWidget {
  final RFile file;
  const _AudioPlayerWidget({required this.file});
  @override
  State<_AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<_AudioPlayerWidget>
    with TickerProviderStateMixin {
  final _player = AudioPlayer();
  bool _ready = false;
  bool _error = false;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.88, end: 1.12)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _init();
  }

  Future<void> _init() async {
    try {
      await _player.setFilePath(widget.file.path);
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration? d) {
    if (d == null) return '00:00';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_rounded, color: Color(0xFFFFD740), size: 64),
          const SizedBox(height: 16),
          const Text('Audio could not be played',
              style: TextStyle(color: Colors.white, fontSize: 15)),
        ]),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.3,
          colors: [Color(0xFF1A1200), Color(0xFF080C14)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(children: [
            const SizedBox(height: 20),
            StreamBuilder<PlayerState>(
              stream: _player.playerStateStream,
              builder: (_, snap) {
                final playing = snap.data?.playing ?? false;
                return AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, _) => Transform.scale(
                    scale: playing ? _pulseAnim.value : 1.0,
                    child: Container(
                      width: 200,
                      height: 200,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [
                          const Color(0xFFFFD740).withA(0.12),
                          const Color(0xFF120E00),
                        ]),
                        border: Border.all(
                          color: const Color(0xFFFFD740)
                              .withA(playing ? 0.8 : 0.3),
                          width: 2.5,
                        ),
                        boxShadow: playing
                            ? [
                                BoxShadow(
                                  color: const Color(0xFFFFD740).withA(0.28),
                                  blurRadius: 50,
                                  spreadRadius: 12,
                                )
                              ]
                            : [],
                      ),
                      child: Icon(
                        Icons.music_note_rounded,
                        color: const Color(0xFFFFD740).withA(playing ? 1.0 : 0.5),
                        size: 90,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 28),
            Text(
              widget.file.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
            const SizedBox(height: 4),
            Text(widget.file.sizeLabel,
                style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 12)),
            const SizedBox(height: 28),
            if (_ready)
              StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (_, posSnap) {
                  final pos = posSnap.data ?? Duration.zero;
                  final dur = _player.duration ?? Duration.zero;
                  final progress = dur.inMilliseconds > 0
                      ? pos.inMilliseconds / dur.inMilliseconds
                      : 0.0;
                  return Column(children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFFFFD740),
                        inactiveTrackColor: Colors.white12,
                        thumbColor: const Color(0xFFFFD740),
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 8),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 20),
                        trackHeight: 4,
                      ),
                      child: Slider(
                        value: progress.clamp(0.0, 1.0),
                        onChanged: (v) => _player.seek(Duration(
                            milliseconds:
                                (v * dur.inMilliseconds).toInt())),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_fmt(pos),
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11)),
                            Text(_fmt(dur),
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11)),
                          ]),
                    ),
                  ]);
                },
              )
            else
              Column(children: [
                const SizedBox(height: 16),
                const LinearProgressIndicator(
                    color: Color(0xFFFFD740),
                    backgroundColor: Colors.white12),
                const SizedBox(height: 16),
              ]),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              GestureDetector(
                onTap: () => _player
                    .seek(_player.position - const Duration(seconds: 15)),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD740).withA(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.replay_10,
                      color: Color(0xFFFFD740), size: 26),
                ),
              ),
              const SizedBox(width: 24),
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (_, snap) {
                  final playing = snap.data?.playing ?? false;
                  final loading =
                      snap.data?.processingState == ProcessingState.loading ||
                          snap.data?.processingState ==
                              ProcessingState.buffering;
                  return GestureDetector(
                    onTap: () =>
                        playing ? _player.pause() : _player.play(),
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFD740),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFFD740).withA(0.4),
                            blurRadius: 24,
                            spreadRadius: 4,
                          )
                        ],
                      ),
                      child: loading
                          ? const CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 3)
                          : Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.black,
                              size: 44),
                    ),
                  );
                },
              ),
              const SizedBox(width: 24),
              GestureDetector(
                onTap: () => _player
                    .seek(_player.position + const Duration(seconds: 15)),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD740).withA(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.forward_10,
                      color: Color(0xFFFFD740), size: 26),
                ),
              ),
            ]),
            const SizedBox(height: 20),
            StreamBuilder<double>(
              stream: _player.speedStream,
              builder: (_, snap) {
                final speed = snap.data ?? 1.0;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Speed: ',
                        style: TextStyle(
                            color: Color(0xFF4A6FA5), fontSize: 12)),
                    for (final s in [0.5, 0.75, 1.0, 1.5, 2.0])
                      GestureDetector(
                        onTap: () => _player.setSpeed(s),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 5),
                          decoration: BoxDecoration(
                            color: speed == s
                                ? const Color(0xFFFFD740).withA(0.15)
                                : const Color(0xFF1A2740),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: speed == s
                                  ? const Color(0xFFFFD740)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Text(
                            '${s}x',
                            style: TextStyle(
                              color: speed == s
                                  ? const Color(0xFFFFD740)
                                  : const Color(0xFF4A6FA5),
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const Spacer(),
          ]),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  PDF VIEWER
// ══════════════════════════════════════════════════════

class _PdfViewerWidget extends StatefulWidget {
  final RFile file;
  const _PdfViewerWidget({required this.file});
  @override
  State<_PdfViewerWidget> createState() => _PdfViewerWidgetState();
}

class _PdfViewerWidgetState extends State<_PdfViewerWidget> {
  int _totalPages = 0;
  int _currentPage = 1;
  bool _ready = false;
  bool _error = false;
  PDFViewController? _pdfCtrl;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      PDFView(
        filePath: widget.file.path,
        enableSwipe: true,
        swipeHorizontal: false,
        autoSpacing: true,
        pageFling: true,
        pageSnap: true,
        fitPolicy: FitPolicy.BOTH,
        backgroundColor: Colors.black,
        onRender: (pages) =>
            setState(() { _totalPages = pages ?? 0; _ready = true; }),
        onViewCreated: (ctrl) => setState(() => _pdfCtrl = ctrl),
        onPageChanged: (page, _) =>
            setState(() => _currentPage = (page ?? 0) + 1),
        onError: (_) => setState(() => _error = true),
        onPageError: (_, _) {},
      ),
      if (!_ready && !_error)
        Container(
          color: Colors.black87,
          child: const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(color: Color(0xFF69FF47)),
              SizedBox(height: 14),
              Text('Loading PDF…',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
            ]),
          ),
        ),
      if (_error)
        Container(
          color: Colors.black87,
          child: const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.broken_image_rounded,
                  color: Color(0xFF69FF47), size: 64),
              SizedBox(height: 16),
              Text('Could not open PDF',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              SizedBox(height: 8),
              Text('File may be corrupted or unsupported',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          ),
        ),
      if (_ready && _totalPages > 0)
        Positioned(
          bottom: 16,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1321).withA(0.92),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFF1A2740)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                GestureDetector(
                  onTap: () {
                    if (_currentPage > 1) _pdfCtrl?.setPage(_currentPage - 2);
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _currentPage > 1
                          ? const Color(0xFF69FF47).withA(0.12)
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.chevron_left,
                        color: _currentPage > 1
                            ? const Color(0xFF69FF47)
                            : const Color(0xFF1A2740),
                        size: 22),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    '$_currentPage / $_totalPages',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    if (_currentPage < _totalPages) {
                      _pdfCtrl?.setPage(_currentPage);
                    }
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _currentPage < _totalPages
                          ? const Color(0xFF69FF47).withA(0.12)
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.chevron_right,
                        color: _currentPage < _totalPages
                            ? const Color(0xFF69FF47)
                            : const Color(0xFF1A2740),
                        size: 22),
                  ),
                ),
              ]),
            ),
          ),
        ),
    ]);
  }
}

// ══════════════════════════════════════════════════════
//  CONFIRM DIALOG
// ══════════════════════════════════════════════════════

class _ConfirmDialog extends StatelessWidget {
  final String title;
  final String body;
  final String confirm;
  final Color confirmColor;
  const _ConfirmDialog({
    required this.title,
    required this.body,
    required this.confirm,
    required this.confirmColor,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0D1321),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_rounded, color: confirmColor, size: 48),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              body,
              style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context, false),
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A2740),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Center(
                        child: Text(
                          'CANCEL',
                          style: TextStyle(
                            color: Color(0xFF4A6FA5),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context, true),
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: confirmColor.withA(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: confirmColor.withA(0.5)),
                      ),
                      child: Center(
                        child: Text(
                          confirm,
                          style: TextStyle(
                            color: confirmColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  RECOVERY DIALOG
// ══════════════════════════════════════════════════════

class RecoveryDialog extends StatefulWidget {
  final List<RFile> files;
  const RecoveryDialog({super.key, required this.files});
  @override
  State<RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<RecoveryDialog> {
  int _cur = 0;
  int _ok = 0;
  bool _done = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _run() {
    _t = Timer.periodic(const Duration(milliseconds: 150), (t) {
      if (_cur >= widget.files.length) {
        t.cancel();
        setState(() => _done = true);
        return;
      }
      final f = widget.files[_cur];
      try {
        Directory('/storage/emulated/0/Download/Recovered')
            .createSync(recursive: true);
        File(f.path).copySync(
          '/storage/emulated/0/Download/Recovered/${f.name}',
        );
        setState(() {
          _ok++;
          _cur++;
        });
      } catch (_) {
        setState(() => _cur++);
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prog =
        widget.files.isEmpty ? 1.0 : _cur / widget.files.length;
    return Dialog(
      backgroundColor: const Color(0xFF0D1321),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _done ? Icons.check_circle_rounded : Icons.download_rounded,
              color:
                  _done ? const Color(0xFF69FF47) : const Color(0xFF00E5FF),
              size: 52,
            ),
            const SizedBox(height: 14),
            Text(
              _done ? 'Recovery Complete!' : 'Recovering…',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$_cur / ${widget.files.length}',
              style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 13),
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: prog,
                backgroundColor: const Color(0xFF1A2740),
                valueColor: AlwaysStoppedAnimation(
                  _done ? const Color(0xFF69FF47) : const Color(0xFF00E5FF),
                ),
                minHeight: 6,
              ),
            ),
            if (_done) ...[
              const SizedBox(height: 14),
              Text(
                '$_ok file${_ok != 1 ? 's' : ''} → /Download/Recovered/',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF4A6FA5),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF00B8D4), Color(0xFF00E5FF)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'DONE',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}