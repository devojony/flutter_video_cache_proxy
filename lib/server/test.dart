import 'package:media_kit_demo/server/video_cache_server.dart';

void main(List<String> args) async {
  final server = VideoCacheServer(port: 8080,cacheRoot: './cache');
  await server.start();
}
