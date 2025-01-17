// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'cache_file.dart';

class CacheManager {
  late String cacheRoot;
  final Map<String, CacheFile> _cacheFiles = {};

  CacheManager({required this.cacheRoot}) {
    print('CacheManager init: $cacheRoot');
    _scanCacheDirectory();
  }

  Future<void> _scanCacheDirectory() async {
    final dir = Directory(cacheRoot);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      return;
    }

    await for (final entity in dir.list()) {
      final id = p.basename(entity.path);
      if (entity is Directory && id.length == 27) {
        print("scaned id:$id");
        _cacheFiles[id] = CacheFile(cacheRoot, id: id);
      }
    }
  }

  Future<void> cacheVideo(String url, Stream<Uint8List> videoStream, {int start = 0}) async {
    final cacheId = CacheFile.getCacheId(url);
    var cacheFile = _cacheFiles[cacheId];

    cacheFile ??= CacheFile(cacheRoot, id: cacheId);
    _cacheFiles[cacheId] = cacheFile;

    await cacheFile.write(url, videoStream, start: start);
  }

  Future<bool> isCached(String url) async {
    return _cacheFiles.containsKey(CacheFile.getCacheId(url));
  }

  Stream<List<int>>? getCachedVideo(String url, {int? start, int? end}) {
    return _cacheFiles[CacheFile.getCacheId(url)]?.read(url, start: start, end: end);
  }

  Future<int> getCachedVideoSize(String url) async {
    final cacheFile = _cacheFiles[CacheFile.getCacheId(url)];
    if (cacheFile == null) return 0;
    return await cacheFile.getSize();
  }

  Future<int> getCachedRangeSize(String url, int start, int end) async {
    final cacheFile = _cacheFiles[CacheFile.getCacheId(url)];
    if (cacheFile == null) return 0;
    return await cacheFile.getRangeSize(start, end);
  }
}
