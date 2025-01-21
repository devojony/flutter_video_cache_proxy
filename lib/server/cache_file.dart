import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:media_kit_demo/server/stream_transformer.dart';

class CacheFile {
  final int chunkSize = 5 * 1024 * 1024;
  final String cacheDir;
  final String url;
  Map<String, dynamic> metadata = {};

  CacheFile(this.cacheDir, this.url) {
    Directory(_cacheFolder).createSync(recursive: true);
    if (!File(metaPath).existsSync()) {
      File(metaPath)
        ..createSync(recursive: true)
        ..writeAsString('{}');
    }
  }

  // 公共属性
  String get fileName => md5.convert(utf8.encode(url)).toString();
  String get _cacheFolder => '$cacheDir${Platform.pathSeparator}$fileName';
  String get cachePath => '$_cacheFolder${Platform.pathSeparator}data';
  String get metaPath => '$_cacheFolder${Platform.pathSeparator}meta.json';

  // 私有方法
  void _writeMeta(Map<String, dynamic> metaData) {
    final metaFile = File(metaPath);
    metaFile.writeAsStringSync(jsonEncode(metaData));
  }

  Map<String, dynamic>? _readMeta() {
    try {
      final metaFile = File(metaPath);
      final content = metaFile.readAsStringSync();
      return jsonDecode(content);
    } catch (e, t) {
      print("$e\n$t");
      return null;
    }
  }

  /// 读取缓存文件
  Stream<List<int>> readCache() {
    final cacheFile = File(cachePath);
    return cacheFile.openRead();
  }

  Map<String, dynamic> _meta = {};

  /// 获取缓存元数据
  Map<String, dynamic> get meta {
    _meta = _readMeta() ?? _meta;
    return _meta;
  }

  set meta(Map<String, dynamic> val) {
    _meta = val;
    _writeMeta(_meta);
  }

  /// 获取缓存文件大小
  int getFileSize() {
    final cacheDir = Directory(cachePath);
    final files = cacheDir.listSync();
    return files.map((e) {
      return (e as File).lengthSync();
    }).reduce((value, element) {
      return value + element;
    });
  }

  /// 检查缓存是否有效
  Future<bool> get isValid async {
    final cacheFile = File(cachePath);
    final metaFile = File(metaPath);

    if (!await cacheFile.exists() || !await metaFile.exists()) {
      return false;
    }

    return true;
  }

  /// 写入分块缓存
  Future<void> writeChunkedCache(Stream<List<int>> dataStream, Map<String, dynamic> metaData) async {
    try {
      // 写入数据流
      var index = 0;
      await dataStream.transform(ChunkedStreamTransformer(chunkSize)).forEach((chunk) {
        File(
          [cachePath, index].join(Platform.pathSeparator),
        )
          ..createSync(recursive: true)
          ..writeAsBytesSync(chunk);
        index++;
      });

      // 写入元数据
      metaData['chunkCount'] = index;
      _writeMeta(metaData);
    } catch (e, t) {
      print("$e\n$t");
    }
  }

  /// 读取分块缓存
  Stream<List<int>> readChunkedCache() {
    final chunkDir = Directory(cachePath);

    StreamController<List<int>> controller = StreamController();

    chunkDir.listSync()
      ..sort((a, b) {
        final aInt = int.tryParse(a.path.substring(a.path.lastIndexOf(Platform.pathSeparator))) ?? 0;
        final bInt = int.tryParse(b.path.substring(b.path.lastIndexOf(Platform.pathSeparator))) ?? 0;
        return aInt - bInt;
      })
      ..forEach((e) {
        controller.add((e as File).readAsBytesSync());
      });

    return controller.stream;
  }
}
