import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cache_file.dart';

class CacheManager {
  static const int chunkSize = 5 * 1024 * 1024; // 5MB
  late Directory _cacheRootDir;
  final Map<String, CacheFile> _cacheFiles = {};

  CacheManager() {
    getApplicationCacheDirectory().then((value) {
      _cacheRootDir = value;
      CacheFile.rootPath = _cacheRootDir.path;
      _initializeCacheFiles().then((_) {
        // clear temp files
        for (var e in _cacheFiles.values) {
          _cleanTemp(e.dir);
        }
      });
    });
  }

  Future<void> _initializeCacheFiles() async {
    await for (final entity in _cacheRootDir.list()) {
      if (entity is Directory) {
        final metadataFile = File('${entity.path}/metadata.json');
        if (await metadataFile.exists()) {
          try {
            final metadata = jsonDecode(await metadataFile.readAsString());
            final url = metadata['url'] as String?;
            if (url != null && url.isNotEmpty) {
              _cacheFiles[entity.uri.pathSegments.last] = CacheFile.fromUrl(src: url);
            }
          } catch (e) {
            log('Error loading cache file ${entity.path}: $e');
          }
        }
      }
    }
  }

  CacheFile? getCacheFile(String url) {
    return _cacheFiles[CacheFile.generateName(url)]!;
  }

  Future<void> updateCacheInBackground(String url, Stream<List<int>> videoStream) async {
    try {
      final cacheFile = getCacheFile(url);
      await cacheFile?.writeStream(videoStream);
    } catch (e) {
      log('Error updating cache: $e');
    }
  }

  Future<void> _cleanTemp(Directory dir) async {
    // Clean up temp files
    if (dir.existsSync()) {
      final tempFiles = dir.listSync().where((file) => file.path.endsWith('.temp'));

      for (final file in tempFiles) {
        try {
          file.deleteSync();
        } catch (e) {
          // Ignore deletion errors
        }
      }
    }
  }
}
