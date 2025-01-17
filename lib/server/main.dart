// ignore_for_file: avoid_print

import 'dart:io';

import 'cache_server.dart';

void main() async {
  final dir = Directory("./cache_file");
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }

  // 初始化缓存管理器和服务器
  final server = CacheServer(cacheDir: dir.path);

  print('Starting video cache server...');
  await server.start();
}
