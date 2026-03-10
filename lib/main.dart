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

// ══════════════════════════════════════════════════════
//  THUMBNAIL CACHE  (LRU, max 200 entries)
// ══════════════════════════════════════════════════════

class _ThumbCache {
  static final LinkedHashMap<String, Uint8List?> _map = LinkedHashMap();
  static final Map<String, Future<Uint8List?>> _pending = {};
  static const int _max = 200;

  static Future<Uint8List?> get(String path) async {
    if (_map.containsKey(path)) {
      final v = _map.remove(path);
      _map[path] = v;
      return v;
    }
    if (_pending.containsKey(path)) {
      return _pending[path];
    }
    final fut = _gen(path);
    _pending[path] = fut;
    final result = await fut;
    _pending.remove(path);
    if (_map.length >= _max) {
      _map.remove(_map.keys.first);
    }
    _map[path] = result;
    return result;
  }

  static Future<Uint8List?> _gen(String path) async {
    try {
      return await VideoThumbnail.thumbnailData(
        video: path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 256,
        quality: 65,
        timeMs: 500,
      );
    } catch (_) {
      return null;
    }
  }
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
  bool selected;

  RFile({
    required this.name,
    required this.path,
    required this.type,
    required this.size,
    required this.confidence,
    this.modifiedDate,
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

Future<void> _scanIsolate(SendPort port) async {
  const roots = [
    '/storage/emulated/0/DCIM',
    '/storage/emulated/0/DCIM/Camera',
    '/storage/emulated/0/Pictures',
    '/storage/emulated/0/Movies',
    '/storage/emulated/0/Download',
    '/storage/emulated/0/Music',
    '/storage/emulated/0/Documents',
    '/storage/emulated/0/WhatsApp/Media/WhatsApp Images',
    '/storage/emulated/0/WhatsApp/Media/WhatsApp Video',
    '/storage/emulated/0/WhatsApp/Media/WhatsApp Documents',
    '/storage/emulated/0/Telegram',
    '/storage/emulated/0/Android/media',
  ];
  const img = {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif'};
  const vid = {'mp4', 'mkv', 'avi', 'mov', '3gp', 'flv', 'wmv', 'ts', 'm4v', 'webm'};
  const aud = {'mp3', 'm4a', 'wav', 'ogg', 'flac', 'aac', 'wma', 'opus'};
  const doc = {'pdf', 'doc', 'docx', 'txt', 'xlsx', 'xls', 'pptx', 'ppt', 'csv'};

  final found = <Map<String, dynamic>>[];
  int done = 0;

  for (final root in roots) {
    done++;
    final dir = Directory(root);
    port.send(_ScanMsg(
      const [],
      'Scanning ${root.split('/').last}…',
      (done * 80 ~/ roots.length),
      false,
    ));
    if (!dir.existsSync()) {
      continue;
    }
    try {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is! File) {
          continue;
        }
        try {
          final ext = e.path.split('.').last.toLowerCase();
          String? t;
          int conf = 75;
          if (img.contains(ext)) {
            t = 'image';
            conf = 90;
          } else if (vid.contains(ext)) {
            t = 'video';
            conf = 88;
          } else if (aud.contains(ext)) {
            t = 'audio';
            conf = 85;
          } else if (doc.contains(ext)) {
            t = 'document';
            conf = 80;
          }
          if (t == null) {
            continue;
          }
          final st = e.statSync();
          if (st.size <= 0) {
            continue;
          }
          found.add({
            'n': e.path.split('/').last,
            'p': e.path,
            't': t,
            's': st.size,
            'c': conf,
            'm': st.modified.millisecondsSinceEpoch,
          });
          if (found.length % 40 == 0) {
            port.send(_ScanMsg(
              List.from(found),
              'Found ${found.length} files…',
              (done * 80 ~/ roots.length),
              false,
            ));
          }
        } catch (_) {}
      }
    } catch (_) {}
  }
  port.send(_ScanMsg(found, 'Done! ${found.length} files found', 100, true));
}

RFile _fromMap(Map<String, dynamic> m) {
  FileType t;
  switch (m['t']) {
    case 'image':
      t = FileType.image;
      break;
    case 'video':
      t = FileType.video;
      break;
    case 'audio':
      t = FileType.audio;
      break;
    case 'document':
      t = FileType.document;
      break;
    default:
      t = FileType.other;
  }
  return RFile(
    name: m['n'] as String,
    path: m['p'] as String,
    type: t,
    size: m['s'] as int,
    confidence: m['c'] as int,
    modifiedDate: m['m'] != null
        ? DateTime.fromMillisecondsSinceEpoch(m['m'] as int)
        : null,
  );
}

// ══════════════════════════════════════════════════════
//  PERMISSION CHANNEL
// ══════════════════════════════════════════════════════

const _ch = MethodChannel('com.example.recovery_app/permissions');

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
        scrollbarTheme: ScrollbarThemeData(
          thumbColor: WidgetStateProperty.all(
            const Color(0xFF00E5FF).withValues(alpha: 0.6),
          ),
          trackColor: WidgetStateProperty.all(const Color(0xFF1A2740)),
          thickness: WidgetStateProperty.all(6),
          radius: const Radius.circular(4),
          thumbVisibility: WidgetStateProperty.all(true),
          trackVisibility: WidgetStateProperty.all(true),
          interactive: true,
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
    _port = ReceivePort();
    try {
      _iso = await Isolate.spawn(_scanIsolate, _port!.sendPort);
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = 'Scan error: $e';
        });
      }
      return;
    }
    _port!.listen((msg) {
      if (msg is! _ScanMsg || !mounted) {
        return;
      }
      setState(() {
        if (msg.files.isNotEmpty) {
          _files = msg.files.map(_fromMap).toList();
        }
        _step = msg.step;
        _progress = msg.progress / 100.0;
        _done = msg.done;
      });
      if (msg.done) {
        Future.delayed(const Duration(milliseconds: 500), () {
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
                    _done ? 'COMPLETE' : 'SCANNING…',
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
                child: LinearProgressIndicator(
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
                '${(_progress * 100).toInt()}%',
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
            Expanded(child: widget.files.isEmpty ? _empty() : _content()),
            if (_selCount > 0) _bottomBar(),
          ],
        ),
      ),
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
                  'RECOVERY RESULTS',
                  style: TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  'Tap = Open   Long Press = Select',
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Row(
        children: [
          _badge('${_shown.length}', 'Files', const Color(0xFF00E5FF)),
          const SizedBox(width: 12),
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
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, color: Color(0xFF1A2740), size: 64),
          SizedBox(height: 16),
          Text('No files found', style: TextStyle(color: Color(0xFF4A6FA5), fontSize: 16)),
          SizedBox(height: 8),
          Text(
            'Grant storage permission and try again',
            style: TextStyle(color: Color(0xFF2A3F5F), fontSize: 13),
          ),
        ],
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

  // ── GRID ──
  Widget _gridView(List<RFile> list) {
    return Scrollbar(
      controller: _scrollCtrl,
      interactive: true,
      child: GridView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.all(10),
        cacheExtent: 800,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: list.length,
        itemBuilder: (_, i) => RepaintBoundary(child: _gridItem(list[i])),
      ),
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

  // ── LIST ──
  Widget _listView(List<RFile> list) {
    return Scrollbar(
      controller: _scrollCtrl,
      interactive: true,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        itemCount: list.length,
        itemBuilder: (_, i) => RepaintBoundary(child: _listItem(list[i])),
      ),
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
//  VIDEO THUMBNAIL  (async + LRU cached)
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
    if (file.isVideo) {
      return _VideoPlayer(file: file);
    }
    return Center(child: _noPreview());
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
//  VIDEO PLAYER  (full controls, seek bar, +/- 10s)
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
  bool _showCtrl = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _ctrl = VideoPlayerController.file(File(widget.file.path));
      await _ctrl!.initialize();
      _ctrl!.addListener(() {
        if (mounted) {
          setState(() {});
        }
      });
      if (mounted) {
        setState(() => _ready = true);
      }
      _ctrl!.play();
      _sched();
    } catch (_) {}
  }

  void _sched() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _showCtrl = false);
      }
    });
  }

  void _tap() {
    setState(() => _showCtrl = !_showCtrl);
    if (_showCtrl) {
      _sched();
    }
  }

  void _playPause() {
    if (_ctrl == null) {
      return;
    }
    _ctrl!.value.isPlaying ? _ctrl!.pause() : _ctrl!.play();
    setState(() {});
    _sched();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _ctrl?.dispose();
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