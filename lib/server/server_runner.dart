import 'video_cache_server.dart';

class ServerRunner {
  static Future<void> start() async {
    // 在新线程中启动服务器
    await _startServer();
  }

  static Future<void> _startServer() async {
    final server = VideoCacheServer();
    await server.start();
  }
}
