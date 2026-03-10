import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:photo_view/photo_view.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

// ─────────────────────────────────────────────
//  Models
// ─────────────────────────────────────────────

enum FileType { image, video, audio, document, other }

extension FTP on FileType {
  IconData get icon {
    switch (this) {
      case FileType.image:    return Icons.image_rounded;
      case FileType.video:    return Icons.videocam_rounded;
      case FileType.audio:    return Icons.audiotrack_rounded;
      case FileType.document: return Icons.description_rounded;
      case FileType.other:    return Icons.insert_drive_file_rounded;
    }
  }

  Color get color {
    switch (this) {
      case FileType.image:    return const Color(0xFF00E5FF);
      case FileType.video:    return const Color(0xFFFF4081);
      case FileType.audio:    return const Color(0xFFFFD740);
      case FileType.document: return const Color(0xFF69FF47);
      case FileType.other:    return const Color(0xFFE040FB);
    }
  }

  String get label {
    switch (this) {
      case FileType.image:    return 'Images';
      case FileType.video:    return 'Videos';
      case FileType.audio:    return 'Audio';
      case FileType.document: return 'Docs';
      case FileType.other:    return 'Other';
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
    if (size <= 0)                 return '---';
    if (size < 1024)               return '${size}B';
    if (size < 1024 * 1024)        return '${(size / 1024).toStringAsFixed(1)}KB';
    if (size < 1024 * 1024 * 1024) return '${(size / 1048576).toStringAsFixed(1)}MB';
    return '${(size / 1073741824).toStringAsFixed(1)}GB';
  }

  String get dateLabel {
    if (modifiedDate == null) return '';
    return DateFormat('dd MMM yyyy, hh:mm a').format(modifiedDate!);
  }

  bool get isImage => type == FileType.image;
  bool get isVideo => type == FileType.video;
}

extension CA on Color {
  Color withA(double a) => withValues(alpha: a);
}

// ─────────────────────────────────────────────
//  Thumbnail Cache
// ─────────────────────────────────────────────

class ThumbnailCache {
  static final Map<String, Uint8List?> _cache = {};
  static final Map<String, Future<Uint8List?>> _pending = {};

  static Future<Uint8List?> get(String path) async {
    if (_cache.containsKey(path)) return _cache[path];
    if (_pending.containsKey(path)) return _pending[path];

    final future = VideoThumbnail.thumbnailData(
      video: path,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 200,
      quality: 60,
      timeMs: 1000,
    );
    _pending[path] = future;
    final result = await future;
    _cache[path] = result;
    _pending.remove(path);
    return result;
  }
}

// ─────────────────────────────────────────────
//  Background Scanner (Isolate)
// ─────────────────────────────────────────────

class ScanMessage {
  final List<Map<String, dynamic>> files;
  final String step;
  final int progress;
  final bool done;
  ScanMessage({required this.files, required this.step,
      required this.progress, required this.done});
}

Future<void> _scanIsolate(SendPort port) async {
  final scanPaths = [
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
    '/storage/emulated/0/.thumbnails',
    '/storage/emulated/0/DCIM/.thumbnails',
  ];

  const imageExts = {'jpg','jpeg','png','gif','bmp','webp','heic','heif'};
  const videoExts = {'mp4','mkv','avi','mov','3gp','flv','wmv','ts','m4v'};
  const audioExts = {'mp3','m4a','wav','ogg','flac','aac','wma','opus'};
  const docExts   = {'pdf','doc','docx','txt','xlsx','xls','pptx','ppt','csv'};

  final found = <Map<String, dynamic>>[];
  int total = scanPaths.length;
  int done = 0;

  for (final scanPath in scanPaths) {
    done++;
    final dir = Directory(scanPath);
    if (!dir.existsSync()) {
      port.send(ScanMessage(
        files: [], step: 'Checking $scanPath...',
        progress: (done * 80 ~/ total), done: false));
      continue;
    }

    port.send(ScanMessage(
      files: [], step: 'Scanning ${scanPath.split('/').last}...',
      progress: (done * 80 ~/ total), done: false));

    try {
      final entities = dir.listSync(recursive: true, followLinks: false);
      for (final entity in entities) {
        if (entity is! File) continue;
        try {
          final ext = entity.path.split('.').last.toLowerCase();
          String? typeStr;
          int conf = 75;
          if (imageExts.contains(ext)) { typeStr = 'image';    conf = 90; }
          else if (videoExts.contains(ext)) { typeStr = 'video'; conf = 88; }
          else if (audioExts.contains(ext)) { typeStr = 'audio'; conf = 85; }
          else if (docExts.contains(ext))   { typeStr = 'document'; conf = 80; }

          if (typeStr == null) continue;
          final stat = entity.statSync();
          if (stat.size <= 0) continue;

          found.add({
            'name': entity.path.split('/').last,
            'path': entity.path,
            'type': typeStr,
            'size': stat.size,
            'confidence': conf,
            'modified': stat.modified.millisecondsSinceEpoch,
          });

          if (found.length % 50 == 0) {
            port.send(ScanMessage(
              files: List.from(found),
              step: 'Found ${found.length} files...',
              progress: (done * 80 ~/ total),
              done: false,
            ));
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  port.send(ScanMessage(
    files: found,
    step: 'Scan complete! Found ${found.length} files',
    progress: 100,
    done: true,
  ));
}

RFile _mapToRFile(Map<String, dynamic> m) {
  FileType type;
  switch (m['type']) {
    case 'image': type = FileType.image; break;
    case 'video': type = FileType.video; break;
    case 'audio': type = FileType.audio; break;
    case 'document': type = FileType.document; break;
    default: type = FileType.other;
  }
  return RFile(
    name: m['name'] as String,
    path: m['path'] as String,
    type: type,
    size: m['size'] as int,
    confidence: m['confidence'] as int,
    modifiedDate: m['modified'] != null
        ? DateTime.fromMillisecondsSinceEpoch(m['modified'] as int)
        : null,
  );
}

// ─────────────────────────────────────────────
//  Permission Channel
// ─────────────────────────────────────────────

const _ch = MethodChannel('com.example.recovery_app/permissions');

// ─────────────────────────────────────────────
//  Main
// ─────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
      ),
      home: const PermissionScreen(),
    );
  }
}

// ─────────────────────────────────────────────
//  Permission Screen
// ─────────────────────────────────────────────

class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});
  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _loading = true;
  String _msg = '';

  @override
  void initState() { super.initState(); _check(); }

  Future<void> _check() async {
    try {
      final ok = await _ch.invokeMethod<bool>('checkStoragePermission') ?? false;
      if (ok && mounted) { _go(); return; }
    } catch (_) {}
    if (mounted) setState(() { _loading = false; _msg = 'Allow storage access to scan deleted files'; });
  }

  Future<void> _request() async {
    setState(() { _loading = true; _msg = 'Requesting...'; });
    try {
      final ok = await _ch.invokeMethod<bool>('requestStoragePermission') ?? false;
      if (ok && mounted) { _go(); return; }
      setState(() { _loading = false; _msg = 'Denied. Please allow from Settings.'; });
    } catch (_) { _go(); }
  }

  void _go() => Navigator.pushReplacement(
      context, MaterialPageRoute(builder: (_) => const HomeScreen()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080C14),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 110, height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF00E5FF).withA(0.08),
                  border: Border.all(color: const Color(0xFF00E5FF).withA(0.4), width: 2),
                ),
                child: const Icon(Icons.security_rounded, color: Color(0xFF00E5FF), size: 52),
              ),
              const SizedBox(height: 32),
              const Text('DEEP RECOVER', style: TextStyle(
                color: Color(0xFF00E5FF), fontSize: 24,
                fontWeight: FontWeight.bold, letterSpacing: 3,
              )),
              const SizedBox(height: 8),
              const Text('Android File Recovery', style: TextStyle(
                color: Color(0xFF4A6FA5), fontSize: 13, letterSpacing: 1,
              )),
              const SizedBox(height: 32),
              Text(_msg, textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 13, height: 1.5)),
              const SizedBox(height: 40),
              if (_loading)
                const CircularProgressIndicator(color: Color(0xFF00E5FF))
              else ...[
                _btn('GRANT PERMISSION', Icons.folder_open, _request, const Color(0xFF00E5FF)),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _go,
                  child: const Text('Skip (limited scan)',
                      style: TextStyle(color: Color(0xFF4A6FA5), fontSize: 12)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback fn, Color color) {
    return GestureDetector(
      onTap: fn,
      child: Container(
        width: double.infinity, height: 56,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(colors: [color.withA(0.8), color]),
          boxShadow: [BoxShadow(color: color.withA(0.3), blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.black, size: 20),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(
            color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1.5,
          )),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  Home Screen
// ─────────────────────────────────────────────

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
    _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _glow  = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);
    _pulseA = Tween<double>(begin: 0.95, end: 1.05).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
    _glowA  = Tween<double>(begin: 0.3, end: 1.0).animate(CurvedAnimation(parent: _glow, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _pulse.dispose(); _glow.dispose(); super.dispose(); }

  void _startScan() => Navigator.push(
      context, MaterialPageRoute(builder: (_) => const ScanScreen()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.3), radius: 1.2,
            colors: [Color(0xFF0D1F3C), Color(0xFF080C14)],
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withA(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF00E5FF).withA(0.3)),
                  ),
                  child: const Icon(Icons.radar, color: Color(0xFF00E5FF), size: 20),
                ),
                const SizedBox(width: 12),
                const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('DEEP RECOVER', style: TextStyle(
                    color: Color(0xFF00E5FF), fontSize: 16,
                    fontWeight: FontWeight.bold, letterSpacing: 3,
                  )),
                  Text('Android File Recovery Engine', style: TextStyle(
                    color: Color(0xFF4A6FA5), fontSize: 10, letterSpacing: 1,
                  )),
                ]),
              ]),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(children: [
                  const SizedBox(height: 30),
                  AnimatedBuilder(
                    animation: Listenable.merge([_pulseA, _glowA]),
                    builder: (_, a) => Transform.scale(
                      scale: _pulseA.value,
                      child: SizedBox(
                        width: 220, height: 220,
                        child: Stack(alignment: Alignment.center, children: [
                          for (int i = 0; i < 4; i++)
                            Container(
                              width: 50.0 + i * 50, height: 50.0 + i * 50,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xFF00E5FF).withA((0.05 + i * 0.04) * _glowA.value),
                                  width: 1,
                                ),
                              ),
                            ),
                          Container(
                            width: 110, height: 110,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(colors: [
                                const Color(0xFF00E5FF).withA(0.25),
                                const Color(0xFF0D3B5E).withA(0.9),
                              ]),
                              border: Border.all(
                                color: const Color(0xFF00E5FF).withA(0.5 * _glowA.value),
                                width: 1.5,
                              ),
                              boxShadow: [BoxShadow(
                                color: const Color(0xFF00E5FF).withA(0.25 * _glowA.value),
                                blurRadius: 30, spreadRadius: 8,
                              )],
                            ),
                            child: const Icon(Icons.manage_search_rounded,
                                color: Color(0xFF00E5FF), size: 48),
                          ),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Tap to start scanning', style: TextStyle(
                    color: Color(0xFF4A6FA5), fontSize: 12, letterSpacing: 1,
                  )),
                  const SizedBox(height: 32),
                  Row(children: [
                    _card(Icons.image_rounded,    'Photos',   'JPG PNG HEIC', const Color(0xFF00E5FF)),
                    const SizedBox(width: 10),
                    _card(Icons.videocam_rounded, 'Videos',   'MP4 MKV AVI',  const Color(0xFFFF4081)),
                    const SizedBox(width: 10),
                    _card(Icons.audiotrack_rounded,'Audio',   'MP3 WAV AAC',  const Color(0xFFFFD740)),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    _card(Icons.description_rounded,'Docs',   'PDF DOCX TXT', const Color(0xFF69FF47)),
                    const SizedBox(width: 10),
                    _card(Icons.chat_rounded,     'WhatsApp', 'Media files',  const Color(0xFF25D366)),
                    const SizedBox(width: 10),
                    _card(Icons.send,             'Telegram', 'Media files',  const Color(0xFF2AABEE)),
                  ]),
                  const SizedBox(height: 32),
                  GestureDetector(
                    onTap: _startScan,
                    child: Container(
                      width: double.infinity, height: 60,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const LinearGradient(
                            colors: [Color(0xFF00B8D4), Color(0xFF00E5FF)]),
                        boxShadow: [BoxShadow(
                          color: const Color(0xFF00E5FF).withA(0.4),
                          blurRadius: 24, offset: const Offset(0, 10),
                        )],
                      ),
                      child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.radar, color: Colors.black, size: 24),
                        SizedBox(width: 12),
                        Text('START DEEP SCAN', style: TextStyle(
                          color: Colors.black, fontWeight: FontWeight.bold,
                          fontSize: 15, letterSpacing: 2,
                        )),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 20),
                ]),
              ),
            ),
          ]),
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
        child: Column(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(title, style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
          const SizedBox(height: 2),
          Text(sub, textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 9)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  Scan Screen
// ─────────────────────────────────────────────

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with TickerProviderStateMixin {
  late AnimationController _radar;
  late Animation<double> _radarA;

  double _progress = 0;
  String _step = 'Starting scan...';
  List<RFile> _files = [];
  bool _done = false;
  Isolate? _iso;
  ReceivePort? _port;

  @override
  void initState() {
    super.initState();
    _radar = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    _radarA = Tween<double>(begin: 0, end: 1).animate(_radar);
    _startScan();
  }

  Future<void> _startScan() async {
    _port = ReceivePort();
    _iso = await Isolate.spawn(_scanIsolate, _port!.sendPort);

    _port!.listen((msg) {
      if (msg is ScanMessage) {
        if (!mounted) return;
        setState(() {
          if (msg.files.isNotEmpty) {
            _files = msg.files.map(_mapToRFile).toList();
          }
          _step = msg.step;
          _progress = msg.progress / 100.0;
          _done = msg.done;
        });
        if (msg.done) {
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted) {
              Navigator.pushReplacement(context,
                  MaterialPageRoute(builder: (_) => ResultScreen(files: _files)));
            }
          });
        }
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
          child: Column(children: [
            Row(children: [
              GestureDetector(
                onTap: () { Navigator.pop(context); },
                child: const Icon(Icons.arrow_back_ios_new,
                    color: Color(0xFF4A6FA5), size: 20),
              ),
              const SizedBox(width: 16),
              Text(_done ? 'COMPLETE' : 'SCANNING...',
                  style: const TextStyle(
                    color: Color(0xFF00E5FF), fontSize: 14,
                    fontWeight: FontWeight.bold, letterSpacing: 3,
                  )),
            ]),
            const SizedBox(height: 40),
            AnimatedBuilder(
              animation: _radarA,
              builder: (_, a) => SizedBox(
                width: 200, height: 200,
                child: Stack(alignment: Alignment.center, children: [
                  for (int i = 0; i < 3; i++)
                    Container(
                      width: 60.0 + i * 50, height: 60.0 + i * 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF00E5FF).withA(0.1 + i * 0.05),
                          width: 1,
                        ),
                      ),
                    ),
                  Transform.rotate(
                    angle: _radarA.value * 2 * 3.14159,
                    child: Container(
                      width: 80, height: 2,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                            colors: [Colors.transparent, Color(0xFF00E5FF)]),
                      ),
                    ),
                  ),
                  Container(
                    width: 12, height: 12,
                    decoration: const BoxDecoration(
                        color: Color(0xFF00E5FF), shape: BoxShape.circle),
                  ),
                ]),
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
            const SizedBox(height: 16),
            Text(_step, textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 12)),
            const SizedBox(height: 8),
            Text('${(_progress * 100).toInt()}%', style: const TextStyle(
              color: Color(0xFF00E5FF), fontSize: 40, fontWeight: FontWeight.bold,
            )),
            const Spacer(),
            if (_files.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF69FF47).withA(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF69FF47).withA(0.3)),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.check_circle, color: Color(0xFF69FF47), size: 18),
                  const SizedBox(width: 8),
                  Text('Found ${_files.length} files so far...',
                      style: const TextStyle(color: Color(0xFF69FF47), fontSize: 13)),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  Result Screen — Gallery + List view
// ─────────────────────────────────────────────

class ResultScreen extends StatefulWidget {
  final List<RFile> files;
  const ResultScreen({super.key, required this.files});
  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen>
    with SingleTickerProviderStateMixin {
  FileType? _filter;
  bool _galleryMode = true;
  final ScrollController _scrollController = ScrollController();

  List<RFile> get _filtered => _filter == null
      ? widget.files
      : widget.files.where((f) => f.type == _filter).toList();

  int get _selectedCount => widget.files.where((f) => f.selected).length;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080C14),
      body: SafeArea(
        child: Column(children: [
          _buildHeader(),
          _buildFilterBar(),
          _buildViewToggle(),
          _buildStats(),
          Expanded(child: widget.files.isEmpty ? _empty() : _buildContent()),
          if (_selectedCount > 0) _buildBottomBar(),
        ]),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: const Icon(Icons.arrow_back_ios_new,
              color: Color(0xFF4A6FA5), size: 20),
        ),
        const SizedBox(width: 16),
        const Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('RECOVERY RESULTS', style: TextStyle(
              color: Color(0xFF00E5FF), fontSize: 14,
              fontWeight: FontWeight.bold, letterSpacing: 2,
            )),
            Text('Tap = Open  •  Long Press = Select',
                style: TextStyle(color: Color(0xFF4A6FA5), fontSize: 11)),
          ]),
        ),
        GestureDetector(
          onTap: () => setState(() {
            final all = widget.files.every((f) => f.selected);
            for (final f in widget.files) { f.selected = !all; }
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1321),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF1A2740)),
            ),
            child: const Text('ALL',
                style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11)),
          ),
        ),
      ]),
    );
  }

  Widget _buildFilterBar() {
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

  Widget _chip(FileType? type, String label, IconData icon) {
    final sel = _filter == type;
    final color = type?.color ?? const Color(0xFF00E5FF);
    return GestureDetector(
      onTap: () => setState(() => _filter = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: sel ? color.withA(0.15) : const Color(0xFF0D1321),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: sel ? color.withA(0.6) : const Color(0xFF1A2740)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: sel ? color : const Color(0xFF4A6FA5), size: 13),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
              color: sel ? color : const Color(0xFF4A6FA5),
              fontSize: 11, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }

  Widget _buildViewToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Row(children: [
        const Spacer(),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0D1321),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF1A2740)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _toggleBtn(Icons.grid_view_rounded, true),
            _toggleBtn(Icons.list_rounded, false),
          ]),
        ),
      ]),
    );
  }

  Widget _toggleBtn(IconData icon, bool isGallery) {
    final active = _galleryMode == isGallery;
    return GestureDetector(
      onTap: () => setState(() => _galleryMode = isGallery),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF00E5FF).withA(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            color: active ? const Color(0xFF00E5FF) : const Color(0xFF4A6FA5),
            size: 18),
      ),
    );
  }

  Widget _buildStats() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Row(children: [
        _badge('${_filtered.length}', 'Files', const Color(0xFF00E5FF)),
        const SizedBox(width: 12),
        _badge('$_selectedCount', 'Selected', const Color(0xFF69FF47)),
      ]),
    );
  }

  Widget _badge(String v, String l, Color c) {
    return Row(children: [
      Text(v, style: TextStyle(color: c, fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(width: 4),
      Text(l, style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 11)),
    ]);
  }

  Widget _empty() {
    return const Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.search_off, color: Color(0xFF1A2740), size: 64),
        SizedBox(height: 16),
        Text('No files found', style: TextStyle(color: Color(0xFF4A6FA5), fontSize: 16)),
        SizedBox(height: 8),
        Text('Grant storage permission and try again',
            style: TextStyle(color: Color(0xFF2A3F5F), fontSize: 13)),
      ]),
    );
  }

  Widget _buildContent() {
    if (_filtered.isEmpty) {
      return const Center(child: Text('No files in this category',
          style: TextStyle(color: Color(0xFF4A6FA5))));
    }
    return _galleryMode ? _buildGallery() : _buildList();
  }

  // ── Gallery Grid — with scrollbar ──
  Widget _buildGallery() {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      thickness: 6,
      radius: const Radius.circular(4),
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
          childAspectRatio: 1,
        ),
        itemCount: _filtered.length,
        // cacheExtent helps pre-load nearby items off screen
        cacheExtent: 600,
        itemBuilder: (ctx, i) => _galleryItem(_filtered[i]),
      ),
    );
  }

  Widget _galleryItem(RFile file) {
    return GestureDetector(
      // Tap = open/preview
      onTap: () => _preview(file),
      // Long press = select/deselect
      onLongPress: () => setState(() => file.selected = !file.selected),
      child: Stack(fit: StackFit.expand, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _buildThumbnail(file),
        ),
        // Selection overlay
        if (file.selected)
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: file.type.color.withA(0.5),
              border: Border.all(color: file.type.color, width: 2),
            ),
            child: const Center(
              child: Icon(Icons.check_circle, color: Colors.white, size: 28),
            ),
          ),
        // Video play icon
        if (file.isVideo && !file.selected)
          const Center(
            child: Icon(Icons.play_circle_fill,
                color: Colors.white70, size: 32),
          ),
        // Type badge for non-image/video
        if (!file.isImage && !file.isVideo)
          Positioned(
            top: 4, right: 4,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: file.type.color.withA(0.9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(file.type.icon, color: Colors.black, size: 12),
            ),
          ),
        // Date on hover (bottom)
        if (file.modifiedDate != null)
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black.withA(0.7), Colors.transparent],
                ),
              ),
              child: Text(
                DateFormat('dd/MM/yy').format(file.modifiedDate!),
                style: const TextStyle(color: Colors.white70, fontSize: 7),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ]),
    );
  }

  // Optimized thumbnail builder — image loads fast, video uses async thumbnail
  Widget _buildThumbnail(RFile file) {
    if (file.isImage) {
      return Image.file(
        File(file.path),
        fit: BoxFit.cover,
        cacheWidth: 200,
        errorBuilder: (_, e, s) => _thumbPlaceholder(file),
      );
    }
    if (file.isVideo) {
      return _VideoThumb(path: file.path, file: file);
    }
    return _thumbPlaceholder(file);
  }

  Widget _thumbPlaceholder(RFile file) {
    return Container(
      decoration: BoxDecoration(
        color: file.type.color.withA(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: file.type.color.withA(0.2)),
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(file.type.icon, color: file.type.color, size: 28),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(file.name,
            style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 8),
            maxLines: 2, overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ]),
    );
  }

  // ── List View ──
  Widget _buildList() {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      thickness: 6,
      radius: const Radius.circular(4),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _filtered.length,
        itemBuilder: (ctx, i) => _listItem(_filtered[i]),
      ),
    );
  }

  Widget _listItem(RFile file) {
    return GestureDetector(
      onTap: () => _preview(file),
      onLongPress: () => setState(() => file.selected = !file.selected),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: file.selected ? file.type.color.withA(0.08) : const Color(0xFF0D1321),
          border: Border.all(
            color: file.selected ? file.type.color.withA(0.4) : const Color(0xFF1A2740),
          ),
        ),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56, height: 56,
              child: _buildThumbnail(file),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(file.name, style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              if (file.modifiedDate != null)
                Text(file.dateLabel,
                    style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 10)),
              const SizedBox(height: 3),
              Row(children: [
                Text(file.sizeLabel,
                    style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 11)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 50, height: 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: file.confidence / 100,
                      backgroundColor: const Color(0xFF1A2740),
                      valueColor: AlwaysStoppedAnimation(file.type.color),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text('${file.confidence}%',
                    style: TextStyle(color: file.type.color, fontSize: 10)),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 22, height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: file.selected ? file.type.color : Colors.transparent,
              border: Border.all(
                color: file.selected ? file.type.color : const Color(0xFF1A2740),
                width: 2,
              ),
            ),
            child: file.selected
                ? const Icon(Icons.check, size: 12, color: Colors.black)
                : null,
          ),
        ]),
      ),
    );
  }

  void _preview(RFile file) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => PreviewScreen(file: file)));
  }

  Widget _buildBottomBar() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1321),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A2740)),
      ),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, children: [
          Text('$_selectedCount selected',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          const Text('/Download/Recovered/',
              style: TextStyle(color: Color(0xFF4A6FA5), fontSize: 10)),
        ]),
        const Spacer(),
        GestureDetector(
          onTap: _recover,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFF00B8D4), Color(0xFF00E5FF)]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(
                color: const Color(0xFF00E5FF).withA(0.3),
                blurRadius: 12, offset: const Offset(0, 4),
              )],
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.download_rounded, color: Colors.black, size: 18),
              SizedBox(width: 6),
              Text('RECOVER', style: TextStyle(
                color: Colors.black, fontWeight: FontWeight.bold,
                fontSize: 13, letterSpacing: 1,
              )),
            ]),
          ),
        ),
      ]),
    );
  }

  void _recover() {
    final sel = widget.files.where((f) => f.selected).toList();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => RecoveryDialog(files: sel),
    );
  }
}

// ─────────────────────────────────────────────
//  Video Thumbnail Widget (async, cached)
// ─────────────────────────────────────────────

class _VideoThumb extends StatefulWidget {
  final String path;
  final RFile file;
  const _VideoThumb({required this.path, required this.file});
  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  Uint8List? _thumb;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await ThumbnailCache.get(widget.path);
    if (mounted) setState(() { _thumb = data; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: widget.file.type.color.withA(0.08),
        child: const Center(
          child: SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(
                color: Color(0xFFFF4081), strokeWidth: 2),
          ),
        ),
      );
    }
    if (_thumb != null) {
      return Image.memory(_thumb!, fit: BoxFit.cover);
    }
    return Container(
      color: widget.file.type.color.withA(0.08),
      child: Icon(widget.file.type.icon, color: widget.file.type.color, size: 28),
    );
  }
}

// ─────────────────────────────────────────────
//  Preview Screen — Photo zoom + Video player
// ─────────────────────────────────────────────

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
            Text(file.name,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis),
            if (file.modifiedDate != null)
              Text(file.dateLabel,
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded, color: Color(0xFF00E5FF)),
            onPressed: () => _saveFile(context),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  void _saveFile(BuildContext context) {
    try {
      final out = '/storage/emulated/0/Download/Recovered/${file.name}';
      final dir = Directory('/storage/emulated/0/Download/Recovered');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(file.path).copySync(out);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved to $out'),
          backgroundColor: const Color(0xFF69FF47),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'),
            backgroundColor: const Color(0xFFFF4081)),
      );
    }
  }

  Widget _buildBody(BuildContext context) {
    if (file.isImage) {
      return PhotoView(
        imageProvider: FileImage(File(file.path)),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (_, event) => Center(
          child: CircularProgressIndicator(
            value: event?.expectedTotalBytes != null
                ? event!.cumulativeBytesLoaded / event.expectedTotalBytes!
                : null,
            color: const Color(0xFF00E5FF),
          ),
        ),
        errorBuilder: (_, e, s) => _noPreview(),
      );
    }
    if (file.isVideo) {
      return VideoPlayerScreen(file: file);
    }
    return Center(child: _noPreview());
  }

  Widget _noPreview() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(file.type.icon, color: file.type.color, size: 80),
      const SizedBox(height: 16),
      Text(file.name, style: const TextStyle(color: Colors.white, fontSize: 14),
          textAlign: TextAlign.center),
      const SizedBox(height: 8),
      Text(file.sizeLabel, style: const TextStyle(color: Colors.grey, fontSize: 12)),
      const SizedBox(height: 4),
      Text(file.dateLabel, style: const TextStyle(color: Colors.grey, fontSize: 11)),
      const SizedBox(height: 4),
      Text('${file.confidence}% confidence',
          style: TextStyle(color: file.type.color, fontSize: 12)),
    ]);
  }
}

// ─────────────────────────────────────────────
//  Video Player Screen — full controls
// ─────────────────────────────────────────────

class VideoPlayerScreen extends StatefulWidget {
  final RFile file;
  const VideoPlayerScreen({super.key, required this.file});
  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.file.path))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
        _controller.play();
        _scheduleHide();
      });
    _controller.addListener(() { if (mounted) setState(() {}); });
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _togglePlay() {
    setState(() {
      _controller.value.isPlaying ? _controller.pause() : _controller.play();
    });
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: Color(0xFFFF4081)),
          SizedBox(height: 16),
          Text('Loading video...', style: TextStyle(color: Colors.white54)),
        ]),
      );
    }

    final pos = _controller.value.position;
    final dur = _controller.value.duration;
    final playing = _controller.value.isPlaying;

    return GestureDetector(
      onTap: _toggleControls,
      child: Stack(fit: StackFit.expand, children: [
        // Video
        Center(
          child: AspectRatio(
            aspectRatio: _controller.value.aspectRatio,
            child: VideoPlayer(_controller),
          ),
        ),

        // Controls overlay
        AnimatedOpacity(
          opacity: _showControls ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: IgnorePointer(
            ignoring: !_showControls,
            child: Column(children: [
              const Spacer(),
              // Progress + time
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black.withAlpha(200), Colors.transparent],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                child: Column(children: [
                  // Seek bar
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFFFF4081),
                      inactiveTrackColor: Colors.white24,
                      thumbColor: const Color(0xFFFF4081),
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: dur.inMilliseconds > 0
                          ? pos.inMilliseconds.toDouble().clamp(0, dur.inMilliseconds.toDouble())
                          : 0,
                      min: 0,
                      max: dur.inMilliseconds.toDouble(),
                      onChanged: (v) {
                        _controller.seekTo(Duration(milliseconds: v.toInt()));
                        _scheduleHide();
                      },
                    ),
                  ),
                  // Time + controls
                  Row(children: [
                    Text(_fmt(pos), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    const Text(' / ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                    Text(_fmt(dur), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    const Spacer(),
                    // Rewind 10s
                    GestureDetector(
                      onTap: () {
                        _controller.seekTo(pos - const Duration(seconds: 10));
                        _scheduleHide();
                      },
                      child: const Icon(Icons.replay_10, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 16),
                    // Play/Pause
                    GestureDetector(
                      onTap: _togglePlay,
                      child: Container(
                        width: 52, height: 52,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF4081).withAlpha(220),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          playing ? Icons.pause : Icons.play_arrow,
                          color: Colors.white, size: 30,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Forward 10s
                    GestureDetector(
                      onTap: () {
                        _controller.seekTo(pos + const Duration(seconds: 10));
                        _scheduleHide();
                      },
                      child: const Icon(Icons.forward_10, color: Colors.white, size: 28),
                    ),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────
//  Recovery Dialog
// ─────────────────────────────────────────────

class RecoveryDialog extends StatefulWidget {
  final List<RFile> files;
  const RecoveryDialog({super.key, required this.files});
  @override
  State<RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<RecoveryDialog> {
  int _current = 0;
  int _success = 0;
  bool _done = false;
  Timer? _t;

  @override
  void initState() { super.initState(); _process(); }

  void _process() {
    _t = Timer.periodic(const Duration(milliseconds: 200), (t) {
      if (_current >= widget.files.length) {
        t.cancel();
        setState(() => _done = true);
        return;
      }
      final f = widget.files[_current];
      try {
        final out = '/storage/emulated/0/Download/Recovered/${f.name}';
        final dir = Directory('/storage/emulated/0/Download/Recovered');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        File(f.path).copySync(out);
        setState(() { _success++; _current++; });
      } catch (_) {
        setState(() => _current++);
      }
    });
  }

  @override
  void dispose() { _t?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final prog = widget.files.isEmpty ? 1.0 : _current / widget.files.length;
    return Dialog(
      backgroundColor: const Color(0xFF0D1321),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            _done ? Icons.check_circle_rounded : Icons.download_rounded,
            color: _done ? const Color(0xFF69FF47) : const Color(0xFF00E5FF),
            size: 52,
          ),
          const SizedBox(height: 16),
          Text(_done ? 'Recovery Complete!' : 'Recovering...',
              style: const TextStyle(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('$_current / ${widget.files.length}',
              style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 13)),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: prog,
              backgroundColor: const Color(0xFF1A2740),
              valueColor: AlwaysStoppedAnimation(
                  _done ? const Color(0xFF69FF47) : const Color(0xFF00E5FF)),
              minHeight: 6,
            ),
          ),
          if (_done) ...[
            const SizedBox(height: 16),
            Text('$_success files → /Download/Recovered/',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF4A6FA5), fontSize: 12)),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFF00B8D4), Color(0xFF00E5FF)]),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('DONE', style: TextStyle(
                  color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 2,
                )),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}