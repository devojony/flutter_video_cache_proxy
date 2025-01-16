import 'dart:collection';
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// A simple example to show how buffering & initial black screen can be avoided by writing code effectively.

class Seamless extends StatefulWidget {
  const Seamless({super.key});

  @override
  State<Seamless> createState() => _SeamlessState();
}

class _SeamlessState extends State<Seamless> {
  final pageController = PageController(initialPage: 0);

  final configuration = ValueNotifier<VideoControllerConfiguration>(
    const VideoControllerConfiguration(enableHardwareAcceleration: true),
  );

  // To efficiently call [setState] if required for re-build.
  final early = HashSet<int>();
  final sources = [
    'https://user-images.githubusercontent.com/28951144/229373695-22f88f13-d18f-4288-9bf1-c3e078d83722.mp4',
    'https://user-images.githubusercontent.com/28951144/229373709-603a7a89-2105-4e1b-a5a5-a6c3567c9a59.mp4',
    'https://user-images.githubusercontent.com/28951144/229373716-76da0a4e-225a-44e4-9ee7-3e9006dbc3e3.mp4',
    'https://user-images.githubusercontent.com/28951144/229373718-86ce5e1d-d195-45d5-baa6-ef94041d0b90.mp4',
    'https://user-images.githubusercontent.com/28951144/229373720-14d69157-1a56-4a78-a2f4-d7a134d7c3e9.mp4',
  ];

  late final players = HashMap<int, Player>();
  late final controllers = HashMap<int, VideoController>();

  @override
  void initState() {
    // First two pages are loaded initially.
    Future.wait([
      createPlayer(0),
      createPlayer(1),
    ]).then((_) {
      // First video must be played initially.
      players[0]?.play();
    });

    super.initState();
  }

  @override
  void dispose() {
    for (final player in players.values) {
      player.dispose();
    }
    super.dispose();
  }

  // Just create a new [Player] & [VideoController], load the video & save it.
  Future<void> createPlayer(int page) async {
    final player = Player();
    final controller = VideoController(
      player,
      configuration: configuration.value,
    );
    await player.setVolume(0.0);
    await player.setPlaylistMode(PlaylistMode.loop);
    await player.open(
      // Load a random video from the list of sources.
      Media(sources[Random().nextInt(sources.length)]),
      play: false,
    );
    players[page] = player;
    controllers[page] = controller;

    if (early.contains(page)) {
      early.remove(page);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('package:media_kit'),
      ),
      body: Stack(
        children: [
          PageView.builder(
            onPageChanged: (i) {
              // Play the current page's video.
              players[i]?.play();
              // Pause other pages' videos.
              Future.wait(players.entries.map((e) async {
                if (e.key != i) {
                  await e.value.pause();
                  await e.value.seek(Duration.zero);
                }
              }));

              // Create the [Player]s & [VideoController]s for the next & previous page.
              // It is obvious that current page's [Player] & [VideoController] will already exist, still checking it redundantly
              if (!players.containsKey(i)) {
                createPlayer(i);
              }
              if (!players.containsKey(i + 1)) {
                createPlayer(i + 1);
              }
              if (!players.containsKey(i - 1)) {
                createPlayer(i - 1);
              }

              // Dispose the [Player]s & [VideoController]s of the pages that are not visible & not adjacent to the current page.
              players.removeWhere(
                (page, player) {
                  final remove = ![i, i - 1, i + 1].contains(page);
                  if (remove) {
                    player.dispose();
                  }
                  return remove;
                },
              );
              controllers.removeWhere(
                (page, controller) {
                  final remove = ![i, i - 1, i + 1].contains(page);
                  return remove;
                },
              );

              debugPrint('players: ${players.keys}');
              debugPrint('controllers: ${controllers.keys}');
            },
            itemBuilder: (context, i) {
              final controller = controllers[i];
              if (controller == null) {
                early.add(i);
                return const Center(
                  child: CircularProgressIndicator(
                    color: Color(0xffffffff),
                  ),
                );
              }

              return Video(
                controller: controller,
                controls: NoVideoControls,
                fit: BoxFit.cover,
              );
            },
            controller: pageController,
            scrollDirection: Axis.vertical,
          ),
          Positioned.fill(
            child: Column(
              children: [
                Expanded(
                  child: Material(
                    color: Colors.black38,
                    child: InkWell(
                      onTap: () {
                        pageController.previousPage(
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeInOut,
                        );
                      },
                      child: Container(
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.expand_less,
                          size: 28.0,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(flex: 8),
                Expanded(
                  child: Material(
                    color: Colors.black38,
                    child: InkWell(
                      onTap: () {
                        pageController.nextPage(
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeInOut,
                        );
                      },
                      child: Container(
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.expand_more,
                          size: 28.0,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
