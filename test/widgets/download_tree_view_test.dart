import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/widgets/download_tree_view.dart';
import '../test_helpers/media_items.dart';

DownloadTreeNode _episodeNode(String globalKey) => DownloadTreeNode(
  key: globalKey,
  title: 'Episode',
  type: DownloadNodeType.episode,
  status: DownloadStatus.completed,
);

DownloadTreeNode _seasonNode({required String key, required List<DownloadTreeNode> children}) => DownloadTreeNode(
  key: key,
  title: 'Season',
  type: DownloadNodeType.season,
  status: DownloadStatus.completed,
  children: children,
);

DownloadTreeNode _showNode({required String key, required List<DownloadTreeNode> children}) => DownloadTreeNode(
  key: key,
  title: 'Show',
  type: DownloadNodeType.show,
  status: DownloadStatus.completed,
  children: children,
);

MediaItem _episodeMeta({
  required String id,
  required ServerId? serverId,
  required String? grandparentId,
  required String? parentId,
}) => testMediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  title: 'Ep $id',
  serverId: serverId,
  grandparentId: grandparentId,
  parentId: parentId,
);

void main() {
  group('resolveDownloadContainerGlobalKey', () {
    test('show node: builds globalKey from leaf serverId + grandparentId', () {
      final ep = _episodeNode('plex1:ep100');
      final season = _seasonNode(key: 'show42:season7', children: [ep]);
      final show = _showNode(key: 'show42', children: [season]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: '7'),
      };

      expect(resolveDownloadContainerGlobalKey(show, metadata), 'plex1:42');
    });

    test('season node: builds globalKey from leaf serverId + parentId', () {
      final ep = _episodeNode('plex1:ep100');
      final season = _seasonNode(key: 'show42:season7', children: [ep]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: '7'),
      };

      expect(resolveDownloadContainerGlobalKey(season, metadata), 'plex1:7');
    });

    test('episode and movie nodes return null (not container types)', () {
      final ep = _episodeNode('plex1:ep100');
      final movie = DownloadTreeNode(
        key: 'plex1:movie5',
        title: 'M',
        type: DownloadNodeType.movie,
        status: DownloadStatus.completed,
      );
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: '7'),
      };

      expect(resolveDownloadContainerGlobalKey(ep, metadata), isNull);
      expect(resolveDownloadContainerGlobalKey(movie, metadata), isNull);
    });

    test('container with no leaves returns null', () {
      final empty = _showNode(key: 'show42', children: []);
      expect(resolveDownloadContainerGlobalKey(empty, {}), isNull);
    });

    test('leaf metadata missing in map returns null', () {
      final ep = _episodeNode('plex1:ep100');
      final show = _showNode(key: 'show42', children: [ep]);
      expect(resolveDownloadContainerGlobalKey(show, const {}), isNull);
    });

    test('leaf metadata missing serverId returns null', () {
      final ep = _episodeNode('plex1:ep100');
      final show = _showNode(key: 'show42', children: [ep]);
      final metadata = {'plex1:ep100': _episodeMeta(id: '100', serverId: null, grandparentId: '42', parentId: '7')};
      expect(resolveDownloadContainerGlobalKey(show, metadata), isNull);
    });

    test('show node with leaf missing grandparentId returns null', () {
      final ep = _episodeNode('plex1:ep100');
      final show = _showNode(key: 'show42', children: [ep]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: null, parentId: '7'),
      };
      expect(resolveDownloadContainerGlobalKey(show, metadata), isNull);
    });

    test('season node with leaf missing parentId returns null', () {
      final ep = _episodeNode('plex1:ep100');
      final season = _seasonNode(key: 'show42:season7', children: [ep]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: null),
      };
      expect(resolveDownloadContainerGlobalKey(season, metadata), isNull);
    });

    test('walks nested season for first leaf when show has multiple seasons', () {
      final ep1 = _episodeNode('plex1:ep100');
      final ep2 = _episodeNode('plex1:ep200');
      final s1 = _seasonNode(key: 'show42:season1', children: [ep1]);
      final s2 = _seasonNode(key: 'show42:season2', children: [ep2]);
      final show = _showNode(key: 'show42', children: [s1, s2]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: '1'),
        'plex1:ep200': _episodeMeta(id: '200', serverId: ServerId('plex1'), grandparentId: '42', parentId: '2'),
      };

      expect(resolveDownloadContainerGlobalKey(show, metadata), 'plex1:42');
    });
  });

  group('downloadLeafDetailLine', () {
    DownloadProgress progress({int totalBytes = 0, String? qualityPreset}) => DownloadProgress(
      globalKey: 'srv:1',
      status: DownloadStatus.completed,
      totalBytes: totalBytes,
      qualityPreset: qualityPreset,
    );

    test('joins size and quality label', () {
      final line = downloadLeafDetailLine(progress(totalBytes: 1288490189, qualityPreset: 'p720_2mbps'));
      expect(line, contains('1.20 GB'));
      expect(line, contains('·'));
      expect(line, contains('720p'));
    });

    test('an original download is labelled Original', () {
      expect(downloadLeafDetailLine(progress(totalBytes: 1000, qualityPreset: 'original')), contains('Original'));
    });

    test('degrades to whichever half is known', () {
      expect(downloadLeafDetailLine(progress(totalBytes: 2048)), isNot(contains('·')));
      expect(downloadLeafDetailLine(progress(qualityPreset: 'original')), 'Original');
      expect(downloadLeafDetailLine(progress()), isNull);
      expect(downloadLeafDetailLine(null), isNull);
    });

    test('unknown preset names fall back to Original rather than crashing', () {
      expect(downloadLeafDetailLine(progress(qualityPreset: 'p999_removed')), 'Original');
    });
  });

  group('multi-select', () {
    setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

    DownloadProgress completed(String globalKey) =>
        DownloadProgress(globalKey: globalKey, status: DownloadStatus.completed, progress: 100);

    // One show ("Show") with two episodes plus one movie ("Movie one-m") —
    // three selectable leaves in total.
    final downloads = {
      'srv:e1': completed('srv:e1'),
      'srv:e2': completed('srv:e2'),
      'srv:m1': completed('srv:m1'),
    };
    final metadata = {
      'srv:e1': testMediaItem(
        id: 'e1',
        backend: MediaBackend.plex,
        kind: MediaKind.episode,
        title: 'One',
        serverId: ServerId('srv'),
        grandparentId: 'show1',
        grandparentTitle: 'Show',
        parentId: 'season1',
        parentTitle: 'Season 1',
        parentIndex: 1,
        index: 1,
      ),
      'srv:e2': testMediaItem(
        id: 'e2',
        backend: MediaBackend.plex,
        kind: MediaKind.episode,
        title: 'Two',
        serverId: ServerId('srv'),
        grandparentId: 'show1',
        grandparentTitle: 'Show',
        parentId: 'season1',
        parentTitle: 'Season 1',
        parentIndex: 1,
        index: 2,
      ),
      'srv:m1': testMediaItem(
        id: 'm1',
        backend: MediaBackend.plex,
        kind: MediaKind.movie,
        title: 'Movie one-m',
        serverId: ServerId('srv'),
      ),
    };

    Future<void> pumpTree(WidgetTester tester, {void Function(String)? onDelete, void Function(String)? onPause}) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadTreeView(downloads: downloads, metadata: metadata, onDelete: onDelete, onPause: onPause),
          ),
        ),
      );
    }

    testWidgets('long-pressing a leaf enters selection mode with it selected', (tester) async {
      await pumpTree(tester, onDelete: (_) {});
      expect(find.byType(Checkbox), findsNothing);

      await tester.longPress(find.text('Movie one-m'));
      await tester.pumpAndSettle();

      // Visible rows (movie + collapsed show) now all show checkboxes.
      expect(find.byType(Checkbox), findsNWidgets(2));
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('long-pressing a container selects its whole subtree', (tester) async {
      await pumpTree(tester, onDelete: (_) {});

      await tester.longPress(find.text('Show'));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('select all covers every leaf and delete confirms once for all of them', (tester) async {
      final deleted = <String>[];
      await pumpTree(tester, onDelete: deleted.add);

      await tester.longPress(find.text('Movie one-m'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete 3 downloads from this device?'), findsOneWidget);
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      expect(deleted.toSet(), {'srv:e1', 'srv:e2', 'srv:m1'});
      // Selection mode exits after the action.
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('container checkbox is tri-state over its leaves', (tester) async {
      await pumpTree(tester, onDelete: (_) {});

      // Expand the show, then its season, then select one of two episodes.
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Season 1'));
      await tester.pumpAndSettle();
      await tester.longPress(find.textContaining('One'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // Rows render movies first, then the show tree:
      // 0 = movie, 1 = show, 2 = season, 3-4 = episodes.
      final showCheckbox = find.byType(Checkbox).at(1);
      expect(tester.widget<Checkbox>(showCheckbox).value, isNull);

      // Ticking the show's checkbox completes the subtree selection.
      await tester.tap(showCheckbox);
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      expect(tester.widget<Checkbox>(showCheckbox).value, isTrue);

      // Ticking again clears it.
      await tester.tap(showCheckbox);
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
      expect(tester.widget<Checkbox>(showCheckbox).value, isFalse);
    });

    testWidgets('close button exits selection mode and restores action buttons', (tester) async {
      await pumpTree(tester, onDelete: (_) {});

      await tester.longPress(find.text('Movie one-m'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(2));

      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('1 selected'), findsNothing);
    });
  });
}
