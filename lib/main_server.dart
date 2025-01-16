import 'package:media_kit_demo/server/server_runner.dart';

void main() async {
  // Start the video cache server
  await ServerRunner.start();
  
  print('Video cache server running at http://localhost:8080');
  print('Test with: http://localhost:8080?url={video_url}');
}
