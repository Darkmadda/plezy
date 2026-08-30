import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/media_list_playback_launcher.dart';
import 'package:plezy/services/offline_shuffle_launcher.dart';

/// Recording fake that satisfies [DownloadProvider] via `implements` +
/// `noSuchMethod`. The launcher only needs the
/// [DownloadProvider.getDownloadedEpisodesForShow] surface.
class _FakeDownloadProvider implements DownloadProvider {
  final Map<String, List<MediaItem>> episodesByShow;
  final List<String> calls = [];

  _FakeDownloadProvider(this.episodesByShow);

  @override
  List<MediaItem> getDownloadedEpisodesForShow(String showRatingKey) {
    calls.add(showRatingKey);
    return episodesByShow[showRatingKey] ?? const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaItem _ep(String id, {int? seasonIndex, int? episodeIndex, String? serverId, String? serverName}) =>
    MediaItem.plex(
      id: id,
      kind: MediaKind.episode,
      title: 'Episode $id',
      parentIndex: seasonIndex,
      index: episodeIndex,
      grandparentId: 'show-1',
      serverId: serverId,
      serverName: serverName,
    );

MediaItem _show(String id, {String? serverId = 'srv-1', String? serverName = 'My Server'}) =>
    MediaItem.plex(id: id, kind: MediaKind.show, serverId: serverId, serverName: serverName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext capturedContext;
    // Wrap in MaterialApp + Scaffold so ScaffoldMessenger is available
    // for the error-path snackbars the launcher emits.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return capturedContext;
  }

  group('OfflineShuffleLauncher', () {
    testWidgets('rejects non-show/season kinds', (tester) async {
      final ctx = await pumpContext(tester);
      final launcher = OfflineShuffleLauncher(context: ctx);

      final movie = MediaItem.plex(id: 'm1', kind: MediaKind.movie, serverId: 'srv-1');

      final result = await launcher.launchShuffledShow(metadata: movie);

      expect(result, isA<PlayQueueError>());
      expect((result as PlayQueueError).error.toString(), contains('shows and seasons'));
    });

    testWidgets('rejects season missing parentId', (tester) async {
      final ctx = await pumpContext(tester);
      final launcher = OfflineShuffleLauncher(context: ctx);

      final season = MediaItem.plex(id: 's1', kind: MediaKind.season, serverId: 'srv-1');

      final result = await launcher.launchShuffledShow(metadata: season);

      expect(result, isA<PlayQueueError>());
      expect((result as PlayQueueError).error.toString(), contains('parentId'));
    });

    testWidgets('collections/playlists are rejected offline', (tester) async {
      final ctx = await pumpContext(tester);
      final launcher = OfflineShuffleLauncher(context: ctx);

      final collection = MediaItem.plex(id: 'col-1', kind: MediaKind.collection);

      final result = await launcher.launchFromCollectionOrPlaylist(item: collection, shuffle: true);

      expect(result, isA<PlayQueueError>());
    });

    testWidgets('show builds a shuffled queue from downloaded episodes only', (tester) async {
      final ctx = await pumpContext(tester);
      // 50 episodes makes a coincident-original ordering effectively impossible.
      final originalIds = List.generate(50, (i) => 'ep$i');
      final downloads = _FakeDownloadProvider({
        'show-1': [for (var i = 0; i < originalIds.length; i++) _ep(originalIds[i], seasonIndex: 1, episodeIndex: i)],
      });
      final playback = PlaybackStateProvider();
      final navigated = <MediaItem>[];

      final launcher = OfflineShuffleLauncher(
        context: ctx,
        downloadProviderForTesting: downloads,
        playbackStateForTesting: playback,
        navigateForTesting: (m) async => navigated.add(m),
      );

      final result = await launcher.launchShuffledShow(metadata: _show('show-1'));

      expect(result, isA<PlayQueueSuccess>());
      expect(downloads.calls, ['show-1']);
      // Same set of episode ids, just reordered.
      final shuffledIds = playback.loadedItems.map((m) => m.id).toList();
      expect(shuffledIds.toSet(), originalIds.toSet());
      expect(shuffledIds.length, originalIds.length);
      expect(shuffledIds, isNot(equals(originalIds)));
      expect(playback.isQueueActive, isTrue);
      expect(playback.isShuffleActive, isTrue);
      expect(playback.shuffleContextKey, 'show-1');
      // The player is entered at the head of the shuffled queue.
      expect(navigated.single.id, shuffledIds.first);
    });

    testWidgets('season filters the queue to its own episodes', (tester) async {
      final ctx = await pumpContext(tester);
      final downloads = _FakeDownloadProvider({
        'show-1': [
          _ep('s1e1', seasonIndex: 1, episodeIndex: 1),
          _ep('s1e2', seasonIndex: 1, episodeIndex: 2),
          _ep('s2e1', seasonIndex: 2, episodeIndex: 1),
          _ep('s2e2', seasonIndex: 2, episodeIndex: 2),
        ],
      });
      final playback = PlaybackStateProvider();

      final launcher = OfflineShuffleLauncher(
        context: ctx,
        downloadProviderForTesting: downloads,
        playbackStateForTesting: playback,
        navigateForTesting: (_) async {},
      );

      final season = MediaItem.plex(
        id: 'season-2',
        kind: MediaKind.season,
        parentId: 'show-1',
        index: 2,
        serverId: 'srv-1',
      );

      final result = await launcher.launchShuffledShow(metadata: season);

      expect(result, isA<PlayQueueSuccess>());
      expect(downloads.calls, ['show-1']);
      expect(playback.loadedItems.map((m) => m.id).toSet(), {'s2e1', 's2e2'});
      expect(playback.isShuffleActive, isTrue);
      expect(playback.shuffleContextKey, 'show-1');
    });

    testWidgets('no downloaded episodes returns PlayQueueEmpty without seeding queue', (tester) async {
      final ctx = await pumpContext(tester);
      final downloads = _FakeDownloadProvider({});
      final playback = PlaybackStateProvider();
      var didNavigate = false;

      final launcher = OfflineShuffleLauncher(
        context: ctx,
        downloadProviderForTesting: downloads,
        playbackStateForTesting: playback,
        navigateForTesting: (_) async {
          didNavigate = true;
        },
      );

      final result = await launcher.launchShuffledShow(metadata: _show('show-1'));

      expect(result, isA<PlayQueueEmpty>());
      expect(playback.isQueueActive, isFalse);
      expect(didNavigate, isFalse);
    });

    testWidgets('server identity is carried onto queue items', (tester) async {
      final ctx = await pumpContext(tester);
      final downloads = _FakeDownloadProvider({
        'show-1': [_ep('e1', seasonIndex: 1, episodeIndex: 1)],
      });
      final playback = PlaybackStateProvider();

      final launcher = OfflineShuffleLauncher(
        context: ctx,
        downloadProviderForTesting: downloads,
        playbackStateForTesting: playback,
        navigateForTesting: (_) async {},
      );

      final result = await launcher.launchShuffledShow(
        metadata: _show('show-1', serverId: 'srv-9', serverName: 'Offline Server'),
      );

      expect(result, isA<PlayQueueSuccess>());
      expect(playback.loadedItems.single.serverId, 'srv-9');
      expect(playback.loadedItems.single.serverName, 'Offline Server');
    });

    testWidgets('published queue resolves adjacency fully in-memory', (tester) async {
      // Anchors the offline player contract: prev/next walk the shuffled
      // LocalPlayQueue via PlaybackStateProvider with no window fetcher
      // (i.e. no server round trip), and the queue edges are confirmed
      // boundaries — not failures.
      final ctx = await pumpContext(tester);
      final downloads = _FakeDownloadProvider({
        'show-1': [for (var i = 0; i < 5; i++) _ep('ep$i', seasonIndex: 1, episodeIndex: i)],
      });
      final playback = PlaybackStateProvider();

      final launcher = OfflineShuffleLauncher(
        context: ctx,
        downloadProviderForTesting: downloads,
        playbackStateForTesting: playback,
        navigateForTesting: (_) async {},
      );

      final result = await launcher.launchShuffledShow(metadata: _show('show-1'));
      expect(result, isA<PlayQueueSuccess>());

      final queue = playback.loadedItems;
      // Head of queue: previous is a boundary, next is the second item.
      final head = queue.first;
      expect(playback.isItemInActiveQueue(head), isTrue);
      expect((await playback.getPreviousEpisode(head.id)).status, QueueNavigationStatus.boundary);
      expect((await playback.getNextEpisode(head.id)).item?.id, queue[1].id);

      // Walk the cursor to the middle, as the player does per transition.
      playback.setCurrentItem(queue[2]);
      expect((await playback.getNextEpisode(queue[2].id)).item?.id, queue[3].id);
      expect((await playback.getPreviousEpisode(queue[2].id)).item?.id, queue[1].id);

      // Tail of queue: next is a confirmed boundary.
      playback.setCurrentItem(queue.last);
      expect((await playback.getNextEpisode(queue.last.id)).status, QueueNavigationStatus.boundary);
    });
  });
}
