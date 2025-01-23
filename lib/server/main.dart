import 'dart:io';
import 'video_cache_server.dart';

void main(List<String> args) async {
  // 获取端口号，默认8080
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  
  // 获取缓存目录，默认为当前目录下的cache
  String basePath = 'cache';
  
  // 解析命令行参数
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--cache-dir' && i + 1 < args.length) {
      basePath = args[i + 1];
      break;
    }
  }
  
  final server = VideoCacheServer(
    port: port,
    basePath: basePath,
  );
  
  // 处理进程信号以优雅关闭
  ProcessSignal.sigint.watch().listen((_) async {
    print('\n正在关闭服务器...');
    await server.stop();
    exit(0);
  });

  try {
    print('缓存目录: $basePath');
    await server.start();
  } catch (e) {
    print('启动服务器时出错: $e');
    exit(1);
  }
}