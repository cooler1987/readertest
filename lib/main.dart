import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

void main() => runApp(const ReaderApp());

const _booksKey = 'reader.books.v1';
const _booksDirKey = 'reader.booksDirectory';
const _backupDirKey = 'reader.backupDirectory';

class ReaderBook {
  ReaderBook({
    required this.path,
    required this.title,
    required this.format,
    this.progress = 0,
    this.lastOpened,
    List<double>? bookmarks,
  }) : bookmarks = bookmarks ?? <double>[];

  final String path;
  String title;
  String format;
  double progress;
  DateTime? lastOpened;
  final List<double> bookmarks;

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'format': format,
        'progress': progress,
        'lastOpened': lastOpened?.toIso8601String(),
        'bookmarks': bookmarks,
      };

  factory ReaderBook.fromJson(Map<String, dynamic> json) => ReaderBook(
        path: json['path'] as String,
        title: json['title'] as String? ?? '未命名书籍',
        format: json['format'] as String? ?? '',
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        lastOpened: DateTime.tryParse(json['lastOpened'] as String? ?? ''),
        bookmarks: (json['bookmarks'] as List<dynamic>? ?? const [])
            .whereType<num>()
            .map((value) => value.toDouble())
            .toList(),
      );
}

class ReaderApp extends StatelessWidget {
  const ReaderApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '简阅',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff496a58)),
          useMaterial3: true,
        ),
        home: const LibraryPage(),
      );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final List<ReaderBook> _books = [];
  String? _booksDirectory;
  String? _backupDirectory;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_booksKey);

    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _books
          ..clear()
          ..addAll(list.map((item) =>
              ReaderBook.fromJson(Map<String, dynamic>.from(item as Map))));
      } catch (_) {
        _message('书架数据无法读取；原有图书文件未受影响。');
      }
    }

    if (!mounted) return;

    setState(() {
      _booksDirectory = prefs.getString(_booksDirKey);
      _backupDirectory = prefs.getString(_backupDirKey);
      _loading = false;
    });
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _booksKey,
      jsonEncode(_books.map((book) => book.toJson()).toList()),
    );
  }

  void _message(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _chooseBooksDirectory() async {
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择默认图书目录',
      );
      if (selected == null) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_booksDirKey, selected);

      if (!mounted) return;

      setState(() => _booksDirectory = selected);
      await _scanBooksDirectory(selected);
    } catch (error) {
      _message('选择目录失败：$error');
    }
  }

  Future<void> _chooseBackupDirectory() async {
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择备份文件目录',
      );
      if (selected == null) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_backupDirKey, selected);

      if (!mounted) return;

      setState(() => _backupDirectory = selected);
      _message('备份目录已设置。');
    } catch (error) {
      _message('选择目录失败：$error');
    }
  }

  Future<void> _scanBooksDirectory(String directory) async {
    try {
      final dir = Directory(directory);
      if (!await dir.exists()) {
        _message('目录不可访问，请重新选择图书目录。');
        return;
      }

      var added = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && _supported(entity.path)) {
          if (_addBookPath(entity.path)) added++;
        }
      }

      await _saveLibrary();

      if (!mounted) return;
      setState(() {});
      _message(
        added == 0 ? '没有发现新的 TXT、EPUB 或 MD 文件。' : '已添加 $added 本书。',
      );
    } catch (error) {
      _message('扫描目录失败：$error。可尝试使用“选择文件”添加书籍。');
    }
  }

  bool _supported(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    return const {'.txt', '.epub', '.md', '.markdown'}.contains(ext);
  }

  bool _addBookPath(String filePath) {
    if (!_supported(filePath) || _books.any((book) => book.path == filePath)) {
      return false;
    }

    final ext = path.extension(filePath).toLowerCase();
    _books.add(
      ReaderBook(
        path: filePath,
        title: path.basenameWithoutExtension(filePath),
        format: ext.replaceFirst('.', '').toUpperCase(),
      ),
    );
    return true;
  }

  Future<void> _pickBooks() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['txt', 'epub', 'md', 'markdown'],
        allowMultiple: true,
        withData: false,
      );

      if (result == null) return;

      var added = 0;
      for (final file in result.files) {
        final filePath = file.path;
        if (filePath != null && _addBookPath(filePath)) added++;
      }

      await _saveLibrary();

      if (!mounted) return;
      setState(() {});
      _message(added == 0 ? '没有添加新书。' : '已添加 $added 本书（未复制原文件）。');
    } catch (error) {
      _message('选择文件失败：$error');
    }
  }

  Future<void> _updateBook(ReaderBook book, {double? progress, bool? bookmark}) async {
    if (progress != null) {
      book.progress = progress.clamp(0, 1).toDouble();
      book.lastOpened = DateTime.now();
    }

    if (bookmark != null && bookmark) {
      if (!book.bookmarks.any((value) => (value - book.progress).abs() < .01)) {
        book.bookmarks.add(book.progress);
        book.bookmarks.sort();
      }
    }

    await _saveLibrary();

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _removeBook(ReaderBook book) async {
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从书架移除？'),
        content: const Text('只会移除书架记录，不会删除图书文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    _books.remove(book);
    await _saveLibrary();

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _backup() async {
    final directory = _backupDirectory;
    if (directory == null || directory.isEmpty) {
      _message('请先设置备份文件目录。');
      await _chooseBackupDirectory();
      return;
    }

    try {
      final dir = Directory(directory);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File(path.join(directory, 'reader-backup-$stamp.json'));

      final payload = {
        'app': '简阅',
        'version': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'booksDirectory': _booksDirectory,
        'books': _books.map((book) => book.toJson()).toList(),
      };

      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
      _message('备份完成：${path.basename(file.path)}（不包含图书文件）。');
    } catch (error) {
      _message('备份失败：$error');
    }
  }

  Future<void> _restore() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );

      if (result == null || result.files.single.bytes == null) return;

      final decoded = jsonDecode(utf8.decode(result.files.single.bytes!));
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['books'] is! List) {
        throw const FormatException('不支持的备份文件格式');
      }

      final restored = (decoded['books'] as List<dynamic>)
          .map((item) => ReaderBook.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();

      if (!mounted) return;

      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('恢复阅读数据'),
          content: Text(
            '备份中有 ${restored.length} 本书的记录。选择“合并”保留现有书架；选择“覆盖”以备份内容替换。不会复制图书文件。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('合并'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('覆盖'),
            ),
          ],
        ),
      );

      if (replace == null) return;

      if (replace) {
        _books
          ..clear()
          ..addAll(restored);
      } else {
        for (final book in restored) {
          final index = _books.indexWhere((item) => item.path == book.path);
          if (index < 0) {
            _books.add(book);
          } else {
            _books[index] = book;
          }
        }
      }

      final restoredDirectory = decoded['booksDirectory'] as String?;
      if (restoredDirectory != null && restoredDirectory.isNotEmpty) {
        _booksDirectory = restoredDirectory;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_booksDirKey, restoredDirectory);
      }

      await _saveLibrary();

      if (!mounted) return;
      setState(() {});
      _message('阅读数据恢复完成。如图书路径不可用，请重新选择图书目录或添加文件。');
    } catch (error) {
      _message('恢复失败：$error');
    }
  }

  Future<void> _showSettings() async {
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('存储设置', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('默认图书目录'),
                subtitle: Text(_booksDirectory ?? '尚未设置'),
                onTap: () {
                  Navigator.pop(context);
                  _chooseBooksDirectory();
                },
              ),
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: const Text('备份文件目录'),
                subtitle: Text(_backupDirectory ?? '尚未设置'),
                onTap: () {
                  Navigator.pop(context);
                  _chooseBackupDirectory();
                },
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '书籍始终保留在原位置。应用仅保存路径和阅读数据；Android 若撤销目录访问授权，重新选择目录即可。',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openBook(ReaderBook book) async {
    try {
      if (!await File(book.path).exists()) {
        _message('找不到图书文件，请检查目录或重新添加该书。');
        return;
      }

      final text = await _readBook(book.path);

      if (!mounted) return;
      book.lastOpened = DateTime.now();
      await _saveLibrary();

      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ReadingPage(
            book: book,
            text: text,
            onProgress: (value) => _updateBook(book, progress: value),
          ),
        ),
      );

      if (!mounted) return;
      setState(() {});
    } catch (error) {
      _message('打开失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [..._books]
      ..sort((a, b) =>
          (b.lastOpened ?? DateTime(2000)).compareTo(a.lastOpened ?? DateTime(2000)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('简阅'),
        actions: [
          IconButton(
            tooltip: '备份',
            onPressed: _backup,
            icon: const Icon(Icons.backup_outlined),
          ),
          IconButton(
            tooltip: '恢复',
            onPressed: _restore,
            icon: const Icon(Icons.settings_backup_restore),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: _showSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : sorted.isEmpty
              ? _emptyState()
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: sorted.length,
                  itemBuilder: (context, index) {
                    final book = sorted[index];
                    final recent =
                        book.lastOpened == null ? '尚未阅读' : '最近阅读 ${_formatDate(book.lastOpened!)}';

                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(book.format.substring(0, book.format.length.clamp(0, 3))),
                      ),
                      title: Text(
                        book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(recent),
                          const SizedBox(height: 5),
                          LinearProgressIndicator(value: book.progress),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              '${(book.progress * 100).round()}%',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ),
                      isThreeLine: true,
                      onTap: () => _openBook(book),
                      onLongPress: () => _removeBook(book),
                      trailing: IconButton(
                        tooltip: '移除书架记录',
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => _removeBook(book),
                      ),
                    );
                  },
                ),
      floatingActionButton: PopupMenuButton<String>(
        tooltip: '添加图书',
        icon: const Icon(Icons.add),
        onSelected: (value) {
          if (value == 'folder') {
            if (_booksDirectory == null) {
              _chooseBooksDirectory();
            } else {
              _scanBooksDirectory(_booksDirectory!);
            }
          } else {
            _pickBooks();
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'folder',
            child: ListTile(
              leading: Icon(Icons.folder_open),
              title: Text('扫描默认目录'),
            ),
          ),
          PopupMenuItem(
            value: 'files',
            child: ListTile(
              leading: Icon(Icons.file_open),
              title: Text('选择文件'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.menu_book_outlined, size: 64),
              const SizedBox(height: 16),
              const Text(
                '书架还是空的',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '选择图书目录或直接添加文件。书籍不会被复制到应用中。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _chooseBooksDirectory,
                icon: const Icon(Icons.folder_open),
                label: const Text('设置图书目录'),
              ),
            ],
          ),
        ),
      );
}

class ReadingPage extends StatefulWidget {
  const ReadingPage({
    super.key,
    required this.book,
    required this.text,
    required this.onProgress,
  });

  final ReaderBook book;
  final String text;
  final ValueChanged<double> onProgress;

  @override
  State<ReadingPage> createState() => _ReadingPageState();
}

class _ReadingPageState extends State<ReadingPage> {
  final ScrollController _controller = ScrollController();
  Timer? _saveTimer;
  double _fontSize = 19;
  bool _dark = false;
  bool _restoredPosition = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_controller.hasClients || _controller.position.maxScrollExtent <= 0) return;

    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), () {
      if (_controller.hasClients) {
        widget.onProgress(
          (_controller.offset / _controller.position.maxScrollExtent)
              .clamp(0, 1)
              .toDouble(),
        );
      }
    });
  }

  void _restorePosition() {
    if (_restoredPosition || !_controller.hasClients) return;

    _restoredPosition = true;
    final max = _controller.position.maxScrollExtent;
    if (max > 0) {
      _controller.jumpTo(max * widget.book.progress.clamp(0, 1));
    }
  }

  void _addBookmark() {
    final progress = _controller.hasClients && _controller.position.maxScrollExtent > 0
        ? (_controller.offset / _controller.position.maxScrollExtent)
            .clamp(0, 1)
            .toDouble()
        : 0.0;

    widget.book.progress = progress;

    if (!widget.book.bookmarks.any((value) => (value - progress).abs() < .01)) {
      widget.book.bookmarks.add(progress);
      widget.book.bookmarks.sort();
    }

    widget.onProgress(progress);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('书签已添加')),
    );
  }

  Future<void> _showBookmarks() async {
    if (widget.book.bookmarks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有书签')),
      );
      return;
    }

    final selected = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('书签')),
            ...widget.book.bookmarks.asMap().entries.map((entry) => ListTile(
                  leading: const Icon(Icons.bookmark_outline),
                  title: Text('书签 ${entry.key + 1}'),
                  subtitle: Text('约 ${(entry.value * 100).round()}%'),
                  onTap: () => Navigator.pop(context, entry.value),
                )),
          ],
        ),
      ),
    );

    if (selected != null && _controller.hasClients) {
      _controller.jumpTo(_controller.position.maxScrollExtent * selected);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: _dark ? const Color(0xff171914) : const Color(0xfffaf8f2),
        appBar: AppBar(
          backgroundColor: _dark ? const Color(0xff171914) : const Color(0xfffaf8f2),
          title: Text(
            widget.book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: '书签',
              onPressed: _showBookmarks,
              icon: const Icon(Icons.bookmarks_outlined),
            ),
            IconButton(
              tooltip: '添加书签',
              onPressed: _addBookmark,
              icon: const Icon(Icons.bookmark_add_outlined),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                setState(() {
                  if (value == 'smaller') {
                    _fontSize = (_fontSize - 1).clamp(14, 32).toDouble();
                  }
                  if (value == 'larger') {
                    _fontSize = (_fontSize + 1).clamp(14, 32).toDouble();
                  }
                  if (value == 'theme') {
                    _dark = !_dark;
                  }
                });
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'smaller', child: Text('缩小字号')),
                PopupMenuItem(value: 'larger', child: Text('放大字号')),
                PopupMenuItem(value: 'theme', child: Text('切换明暗主题')),
              ],
            ),
          ],
        ),
        body: Scrollbar(
          controller: _controller,
          child: ListView(
            controller: _controller,
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
            children: [
              Text(
                widget.text,
                style: TextStyle(
                  fontSize: _fontSize,
                  height: 1.8,
                  color: _dark ? const Color(0xffe6e2d7) : const Color(0xff292a26),
                ),
              ),
              Builder(
                builder: (context) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _restorePosition());
                  return const SizedBox(height: 1);
                },
              ),
            ],
          ),
        ),
      );
}

Future<String> _readBook(String filePath) async {
  final ext = path.extension(filePath).toLowerCase();
  if (ext != '.epub') {
    return utf8.decode(await File(filePath).readAsBytes(), allowMalformed: true);
  }

  final archive = ZipDecoder().decodeBytes(await File(filePath).readAsBytes());
  final entries = <String, ArchiveFile>{
    for (final entry in archive) if (entry.isFile) entry.name: entry,
  };

  String? opfPath;
  final container = entries['META-INF/container.xml'];
  if (container != null) {
    try {
      final xml = XmlDocument.parse(
        utf8.decode(container.content as List<int>, allowMalformed: true),
      );
      opfPath = xml.findAllElements('rootfile').firstOrNull?.getAttribute('full-path');
    } catch (_) {}
  }

  final orderedHtml = <String>[];
  if (opfPath != null && entries.containsKey(opfPath)) {
    try {
      final opf = XmlDocument.parse(
        utf8.decode(entries[opfPath]!.content as List<int>, allowMalformed: true),
      );
      final base = path.posix.dirname(opfPath);
      final manifest = <String, String>{};

      for (final item in opf.findAllElements('item')) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        final media = item.getAttribute('media-type') ?? '';

        if (id != null &&
            href != null &&
            (media.contains('html') ||
                href.toLowerCase().endsWith('.html') ||
                href.toLowerCase().endsWith('.xhtml'))) {
          manifest[id] = path.posix.normalize(
            path.posix.join(base, Uri.decodeComponent(href.split('#').first)),
          );
        }
      }

      for (final itemref in opf.findAllElements('itemref')) {
        final idref = itemref.getAttribute('idref');
        final href = idref == null ? null : manifest[idref];
        if (href != null && entries.containsKey(href)) {
          orderedHtml.add(href);
        }
      }
    } catch (_) {}
  }

  if (orderedHtml.isEmpty) {
    orderedHtml.addAll(
      entries.keys.where((name) {
        final lower = name.toLowerCase();
        return lower.endsWith('.html') ||
            lower.endsWith('.xhtml') ||
            lower.endsWith('.htm');
      }).toList()
        ..sort(),
    );
  }

  if (orderedHtml.isEmpty) {
    throw const FormatException('EPUB 中没有找到可读章节');
  }

  final chapters = <String>[];
  for (final name in orderedHtml) {
    final html = utf8.decode(entries[name]!.content as List<int>, allowMalformed: true);
    final document = html_parser.parse(html);
    final text = document.body?.text.trim() ??
        document.documentElement?.text.trim() ??
        '';
    if (text.isNotEmpty) {
      chapters.add(text);
    }
  }

  return chapters.join('\n\n');
}

String _formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
