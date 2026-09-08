import 'package:flutter_test/flutter_test.dart';
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
}
