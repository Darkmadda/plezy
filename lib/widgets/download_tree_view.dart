import 'package:flutter/material.dart';
import '../media/ids.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../focus/focusable_wrapper.dart';
import '../i18n/strings.g.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../models/download_models.dart';
import '../models/transcode_quality_preset.dart';
import '../utils/dialogs.dart';
import '../utils/formatters.dart';
import '../utils/global_key_utils.dart';
import '../utils/quality_preset_labels.dart';
import '../mixins/unsuppress_focus_mixin.dart';
import '../services/watch_actions.dart';
import '../utils/app_logger.dart';
import '../utils/snackbar_helper.dart';
import 'download_status_icon.dart';

/// Represents a node in the download tree
class DownloadTreeNode {
  final String key;
  final String title;
  final DownloadNodeType type;
  final double progress; // 0.0-1.0
  final DownloadStatus status;
  final List<DownloadTreeNode> children;
  final MediaItem? metadata;
  final DownloadProgress? downloadProgress;

  const DownloadTreeNode({
    required this.key,
    required this.title,
    required this.type,
    this.progress = 0.0,
    required this.status,
    this.children = const [],
    this.metadata,
    this.downloadProgress,
  });

  /// Check if this node has children
  bool get hasChildren => children.isNotEmpty;

  /// Get the number of completed children
  int get completedChildrenCount {
    return children.where((child) => child.status == DownloadStatus.completed).length;
  }
}

/// Type of node in the download tree
enum DownloadNodeType { show, season, episode, movie, album, track }

/// "1.2 GB · 720p 2 Mbps" for a completed leaf row, or whichever half is
/// known. Null when neither the size nor the quality is available.
@visibleForTesting
String? downloadLeafDetailLine(DownloadProgress? downloadProgress) {
  if (downloadProgress == null) return null;
  final parts = <String>[
    if (downloadProgress.totalBytes > 0) ByteFormatter.formatBytes(downloadProgress.totalBytes),
    if (downloadProgress.qualityPreset != null)
      qualityPresetLabel(TranscodeQualityPreset.fromName(downloadProgress.qualityPreset)),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Hierarchical tree view for downloads
/// Groups TV shows by show -> season -> episode and music by album -> track
/// Movies appear at top level
class DownloadTreeView extends StatefulWidget {
  final Map<String, DownloadProgress> downloads;
  final Map<String, MediaItem> metadata;
  final void Function(String globalKey)? onPause;
  final void Function(String globalKey)? onResume;
  final void Function(String globalKey)? onRetry;
  final void Function(String globalKey)? onCancel;
  final void Function(String globalKey)? onDelete;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;
  final bool suppressAutoFocus;

  const DownloadTreeView({
    super.key,
    required this.downloads,
    required this.metadata,
    this.onPause,
    this.onResume,
    this.onRetry,
    this.onCancel,
    this.onDelete,
    this.onNavigateLeft,
    this.onBack,
    this.suppressAutoFocus = false,
  });

  @override
  State<DownloadTreeView> createState() => _DownloadTreeViewState();
}

class _DownloadTreeViewState extends State<DownloadTreeView> with UnsuppressFocusFirstMixin<DownloadTreeView> {
  final Set<String> _expandedNodes = {};

  /// Multi-select mode: entered by long-pressing any row, left via the
  /// selection bar's close button or by completing an action. Holds leaf
  /// globalKeys only — container checkboxes are a view over their leaves.
  bool _selectionMode = false;
  final Set<String> _selectedKeys = {};

  @override
  String get firstItemFocusDebugLabel => 'DownloadTreeView_firstItem';

  @override
  bool suppressAutoFocusOf(DownloadTreeView widget) => widget.suppressAutoFocus;

  @override
  void didUpdateWidget(DownloadTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Downloads can disappear underneath the selection (deletion, sign-out).
    _selectedKeys.removeWhere((key) => !widget.downloads.containsKey(key));
  }

  @override
  Widget build(BuildContext context) {
    final tree = _buildTree();
    final flattenedNodes = _flattenTree(tree);

    if (flattenedNodes.isEmpty) {
      return Center(child: Text(t.downloads.noDownloadsTree));
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: .zero,
            itemCount: flattenedNodes.length,
            itemBuilder: (context, index) {
              final item = flattenedNodes[index];
              return _buildTreeItem(item.node, item.depth, isFirst: index == 0);
            },
          ),
        ),
        if (_selectionMode) _buildSelectionBar(context),
      ],
    );
  }

  List<DownloadTreeNode> _buildTree() {
    final Map<String, List<MapEntry<String, DownloadProgress>>> showGroups = {};
    final Map<String, List<MapEntry<String, DownloadProgress>>> albumGroups = {};
    final List<DownloadTreeNode> movies = [];

    for (final entry in widget.downloads.entries) {
      final globalKey = entry.key;
      final download = entry.value;
      final meta = widget.metadata[globalKey];

      if (meta == null) continue;

      if (meta.isEpisode) {
        final showKey = meta.grandparentId ?? 'unknown';
        showGroups.putIfAbsent(showKey, () => []);
        showGroups[showKey]!.add(entry);
      } else if (meta.kind == MediaKind.track) {
        final albumKey = meta.parentId ?? 'unknown';
        albumGroups.putIfAbsent(albumKey, () => []);
        albumGroups[albumKey]!.add(entry);
      } else if (meta.isMovie) {
        movies.add(
          DownloadTreeNode(
            key: globalKey,
            title: meta.displayTitle,
            type: DownloadNodeType.movie,
            progress: download.progressPercent,
            status: download.status,
            metadata: meta,
            downloadProgress: download,
          ),
        );
      }
    }

    final List<DownloadTreeNode> shows = [];
    for (final showEntry in showGroups.entries) {
      final showKey = showEntry.key;
      final episodes = showEntry.value;

      if (episodes.isEmpty) continue;

      final firstEpisode = widget.metadata[episodes.first.key];
      final showTitle = firstEpisode?.grandparentTitle ?? t.downloads.unknownShow;

      final Map<String, List<MapEntry<String, DownloadProgress>>> seasonGroups = {};
      for (final episode in episodes) {
        final meta = widget.metadata[episode.key];
        if (meta == null) continue;

        final seasonKey = meta.parentId ?? 'unknown';
        seasonGroups.putIfAbsent(seasonKey, () => []);
        seasonGroups[seasonKey]!.add(episode);
      }

      final List<DownloadTreeNode> seasons = [];
      for (final seasonEntry in seasonGroups.entries) {
        final seasonKey = seasonEntry.key;
        final seasonEpisodes = seasonEntry.value;

        if (seasonEpisodes.isEmpty) continue;

        final firstEpisode = widget.metadata[seasonEpisodes.first.key];
        final seasonNumber = firstEpisode?.parentIndex;
        final seasonTitle = firstEpisode?.parentTitle?.isNotEmpty == true
            ? firstEpisode!.parentTitle!
            : seasonNumber != null
            ? t.common.seasonNumber(number: seasonNumber)
            : t.downloads.unknownSeason;

        final List<DownloadTreeNode> episodeNodes = [];
        for (final episodeEntry in seasonEpisodes) {
          final globalKey = episodeEntry.key;
          final download = episodeEntry.value;
          final meta = widget.metadata[globalKey];

          if (meta == null) continue;

          final episodeNumber = meta.index;
          final episodeTitle = episodeNumber != null
              ? t.common.episodeNumberTitle(number: episodeNumber, title: meta.title!)
              : meta.title!;

          episodeNodes.add(
            DownloadTreeNode(
              key: globalKey,
              title: episodeTitle,
              type: DownloadNodeType.episode,
              progress: download.progressPercent,
              status: download.status,
              metadata: meta,
              downloadProgress: download,
            ),
          );
        }

        episodeNodes.sort((a, b) {
          final aIndex = a.metadata?.index ?? 0;
          final bIndex = b.metadata?.index ?? 0;
          return aIndex.compareTo(bIndex);
        });

        final seasonProgress = episodeNodes.isEmpty
            ? 0.0
            : episodeNodes.map((e) => e.progress).reduce((a, b) => a + b) / episodeNodes.length;
        final seasonStatus = _determineAggregateStatus(episodeNodes.map((e) => e.status).toList());

        seasons.add(
          DownloadTreeNode(
            key: '$showKey:$seasonKey',
            title: seasonTitle,
            type: DownloadNodeType.season,
            progress: seasonProgress,
            status: seasonStatus,
            children: episodeNodes,
          ),
        );
      }

      seasons.removeWhere((s) => s.children.isEmpty);

      seasons.sort((a, b) {
        final aSeasonNum = widget.metadata[a.children.first.key]?.parentIndex ?? 0;
        final bSeasonNum = widget.metadata[b.children.first.key]?.parentIndex ?? 0;
        return aSeasonNum.compareTo(bSeasonNum);
      });

      final showProgress = seasons.isEmpty
          ? 0.0
          : seasons.map((s) => s.progress).reduce((a, b) => a + b) / seasons.length;
      final showStatus = _determineAggregateStatus(seasons.map((s) => s.status).toList());

      shows.add(
        DownloadTreeNode(
          key: showKey,
          title: showTitle,
          type: DownloadNodeType.show,
          progress: showProgress,
          status: showStatus,
          children: seasons,
        ),
      );
    }

    final List<DownloadTreeNode> albums = [];
    for (final albumEntry in albumGroups.entries) {
      final albumKey = albumEntry.key;
      final tracks = albumEntry.value;
      if (tracks.isEmpty) continue;

      final firstTrack = widget.metadata[tracks.first.key];
      final albumTitle = firstTrack?.albumTitle ?? t.downloads.unknownAlbum;
      final artistTitle = firstTrack?.albumArtistTitle;
      final albumNodeTitle = artistTitle != null && artistTitle.isNotEmpty ? '$artistTitle - $albumTitle' : albumTitle;

      final List<DownloadTreeNode> trackNodes = [];
      for (final trackEntry in tracks) {
        final globalKey = trackEntry.key;
        final download = trackEntry.value;
        final meta = widget.metadata[globalKey];
        if (meta == null) continue;

        trackNodes.add(
          DownloadTreeNode(
            key: globalKey,
            title: meta.title ?? globalKey,
            type: DownloadNodeType.track,
            progress: download.progressPercent,
            status: download.status,
            metadata: meta,
            downloadProgress: download,
          ),
        );
      }
      if (trackNodes.isEmpty) continue;

      trackNodes.sort((a, b) {
        final byDisc = (a.metadata?.discNumber ?? 1).compareTo(b.metadata?.discNumber ?? 1);
        if (byDisc != 0) return byDisc;
        return (a.metadata?.trackNumber ?? 0).compareTo(b.metadata?.trackNumber ?? 0);
      });

      final albumProgress = trackNodes.map((e) => e.progress).reduce((a, b) => a + b) / trackNodes.length;
      final albumStatus = _determineAggregateStatus(trackNodes.map((e) => e.status).toList());

      albums.add(
        DownloadTreeNode(
          key: albumKey,
          title: albumNodeTitle,
          type: DownloadNodeType.album,
          progress: albumProgress,
          status: albumStatus,
          children: trackNodes,
        ),
      );
    }

    _sortNodesByStatusAndTitle(shows);
    _sortNodesByStatusAndTitle(albums);
    _sortNodesByStatusAndTitle(movies);

    return [...movies, ...shows, ...albums];
  }

  DownloadStatus _determineAggregateStatus(List<DownloadStatus> statuses) {
    if (statuses.isEmpty) return DownloadStatus.queued;

    if (statuses.any((s) => s == DownloadStatus.downloading)) {
      return DownloadStatus.downloading;
    }
    if (statuses.any((s) => s == DownloadStatus.queued)) {
      return DownloadStatus.queued;
    }
    if (statuses.any((s) => s == DownloadStatus.paused)) {
      return DownloadStatus.paused;
    }
    if (statuses.any((s) => s == DownloadStatus.failed)) {
      return DownloadStatus.failed;
    }
    return DownloadStatus.completed;
  }

  int _compareByStatus(DownloadStatus a, DownloadStatus b) {
    const statusOrder = {
      DownloadStatus.downloading: 0,
      DownloadStatus.queued: 1,
      DownloadStatus.paused: 2,
      DownloadStatus.completed: 3,
      DownloadStatus.failed: 4,
      DownloadStatus.cancelled: 5,
    };
    return (statusOrder[a] ?? 99).compareTo(statusOrder[b] ?? 99);
  }

  void _sortNodesByStatusAndTitle(List<DownloadTreeNode> nodes) {
    nodes.sort((a, b) {
      final statusCompare = _compareByStatus(a.status, b.status);
      if (statusCompare != 0) return statusCompare;
      return a.title.compareTo(b.title);
    });
  }

  /// Flatten the tree into a list of visible nodes with their depths
  List<_FlatNode> _flattenTree(List<DownloadTreeNode> nodes, [int depth = 0]) {
    final List<_FlatNode> result = [];

    for (final node in nodes) {
      result.add(_FlatNode(node: node, depth: depth));

      // Add children if node is expanded
      if (_expandedNodes.contains(node.key) && node.hasChildren) {
        result.addAll(_flattenTree(node.children, depth + 1));
      }
    }

    return result;
  }

  /// Toggle node expansion
  void _toggleExpansion(String key) {
    setState(() {
      if (_expandedNodes.contains(key)) {
        _expandedNodes.remove(key);
      } else {
        _expandedNodes.add(key);
      }
    });
  }

  Widget _buildTreeItem(DownloadTreeNode node, int depth, {bool isFirst = false}) {
    return _DownloadTreeItem(
      node: node,
      depth: depth,
      isExpanded: _expandedNodes.contains(node.key),
      onToggleExpansion: () => _toggleExpansion(node.key),
      onPause: widget.onPause,
      onResume: widget.onResume,
      onRetry: widget.onRetry,
      onCancel: widget.onCancel,
      onDelete: widget.onDelete,
      onNavigateLeft: widget.onNavigateLeft,
      onBack: widget.onBack,
      rowFocusNode: isFirst ? firstItemFocusNode : null,
      autofocus: isFirst && !widget.suppressAutoFocus,
      pauseAllChildren: _pauseAllChildren,
      resumeAllChildren: _resumeAllChildren,
      deleteAllChildren: _deleteAllChildren,
      selectionMode: _selectionMode,
      checkState: _checkStateFor(node),
      onToggleSelection: () => _toggleSelection(node),
      onEnterSelection: () => _enterSelectionMode(node),
    );
  }

  /// Checkbox state for a row: leaves are true/false, containers tri-state
  /// (null = some but not all descendant leaves selected).
  bool? _checkStateFor(DownloadTreeNode node) {
    if (!node.hasChildren) return _selectedKeys.contains(node.key);
    final leaves = _leafKeys(node);
    final selected = leaves.where(_selectedKeys.contains).length;
    if (selected == 0) return false;
    return selected == leaves.length ? true : null;
  }

  void _enterSelectionMode(DownloadTreeNode node) {
    setState(() {
      _selectionMode = true;
      _selectedKeys.addAll(node.hasChildren ? _leafKeys(node) : [node.key]);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
    });
  }

  void _toggleSelection(DownloadTreeNode node) {
    setState(() {
      if (!node.hasChildren) {
        if (!_selectedKeys.remove(node.key)) _selectedKeys.add(node.key);
        return;
      }
      // Container checkbox: everything selected → clear the subtree,
      // otherwise (none or partial) → select the whole subtree.
      final leaves = _leafKeys(node);
      if (leaves.every(_selectedKeys.contains)) {
        _selectedKeys.removeAll(leaves);
      } else {
        _selectedKeys.addAll(leaves);
      }
    });
  }

  void _selectAll() {
    setState(() {
      for (final entry in widget.downloads.entries) {
        final meta = widget.metadata[entry.key];
        if (meta == null) continue;
        // Same leaf predicate as [_buildTree] — only rows the tree shows.
        if (meta.isEpisode || meta.isMovie || meta.kind == MediaKind.track) {
          _selectedKeys.add(entry.key);
        }
      }
    });
  }

  bool _selectionHasStatus(bool Function(DownloadStatus status) test) {
    return _selectedKeys.any((key) {
      final status = widget.downloads[key]?.status;
      return status != null && test(status);
    });
  }

  bool get _selectionHasVideo =>
      _selectedKeys.any((key) => widget.metadata[key]?.isEpisode == true || widget.metadata[key]?.isMovie == true);

  /// Run [action] on every selected item whose status passes [where], then
  /// leave selection mode.
  void _applyToSelected(void Function(String globalKey)? action, bool Function(DownloadStatus status) where) {
    if (action == null) return;
    for (final key in _selectedKeys) {
      final status = widget.downloads[key]?.status;
      if (status != null && where(status)) action(key);
    }
    _exitSelectionMode();
  }

  Future<void> _deleteSelected() async {
    final keys = _selectedKeys.toList();
    final confirmed = await showDeleteConfirmation(
      context,
      title: t.downloads.deleteDownload,
      message: t.downloads.deleteSelectedConfirm(count: keys.length),
    );
    if (!confirmed || !mounted) return;
    for (final key in keys) {
      widget.onDelete?.call(key);
    }
    _exitSelectionMode();
  }

  /// Mark every selected movie/episode watched or unwatched through the
  /// offline-aware [WatchActions] path (online → server + trackers, offline →
  /// queued for later sync).
  Future<void> _markSelectedWatched({required bool watched}) async {
    final items = _selectedKeys
        .map((key) => widget.metadata[key])
        .whereType<MediaItem>()
        .where((meta) => meta.isEpisode || meta.isMovie)
        .toList();
    var queuedOffline = false;
    try {
      for (final item in items) {
        if (!mounted) return;
        final outcome = await WatchActions.setWatched(context, item, watched: watched);
        queuedOffline |= outcome == WatchMarkOutcome.queuedOffline;
      }
    } catch (e) {
      appLogger.e('Failed to mark selected downloads ${watched ? 'watched' : 'unwatched'}', error: e);
      if (mounted) showErrorSnackBar(context, t.messages.errorLoading(error: e.toString()));
      return;
    }
    if (!mounted) return;
    showAppSnackBar(
      context,
      watched
          ? (queuedOffline ? t.messages.markedAsWatchedOffline : t.messages.markedAsWatched)
          : (queuedOffline ? t.messages.markedAsUnwatchedOffline : t.messages.markedAsUnwatched),
    );
    _exitSelectionMode();
  }

  /// The bar shown while selecting: count, select-all, delete, and an
  /// overflow menu whose entries appear only when the selection contains
  /// items they apply to.
  Widget _buildSelectionBar(BuildContext context) {
    final theme = Theme.of(context);
    final count = _selectedKeys.length;
    final hasActive = _selectionHasStatus(
      (s) => s == DownloadStatus.downloading || s == DownloadStatus.queued,
    );
    final hasPaused = _selectionHasStatus((s) => s == DownloadStatus.paused);
    final hasFailed = _selectionHasStatus((s) => s == DownloadStatus.failed);
    final hasVideo = _selectionHasVideo;

    final overflowEntries = <PopupMenuEntry<VoidCallback>>[
      if (hasActive && widget.onPause != null)
        PopupMenuItem(
          value: () => _applyToSelected(
            widget.onPause,
            (s) => s == DownloadStatus.downloading || s == DownloadStatus.queued,
          ),
          child: Text(t.common.pause),
        ),
      if (hasPaused && widget.onResume != null)
        PopupMenuItem(
          value: () => _applyToSelected(widget.onResume, (s) => s == DownloadStatus.paused),
          child: Text(t.common.resume),
        ),
      if (hasActive && widget.onCancel != null)
        PopupMenuItem(
          value: () => _applyToSelected(
            widget.onCancel,
            (s) => s == DownloadStatus.downloading || s == DownloadStatus.queued,
          ),
          child: Text(t.common.cancel),
        ),
      if (hasFailed && widget.onRetry != null)
        PopupMenuItem(
          value: () => _applyToSelected(widget.onRetry, (s) => s == DownloadStatus.failed),
          child: Text(t.downloads.retryDownload),
        ),
      if (hasVideo)
        PopupMenuItem(value: () => _markSelectedWatched(watched: true), child: Text(t.mediaMenu.markAsWatched)),
      if (hasVideo)
        PopupMenuItem(value: () => _markSelectedWatched(watched: false), child: Text(t.mediaMenu.markAsUnwatched)),
    ];

    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: t.common.cancel,
                icon: const AppIcon(Symbols.close_rounded, fill: 1, size: 22),
                onPressed: _exitSelectionMode,
              ),
              Text(t.downloads.selectedCount(count: count), style: theme.textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: t.downloads.selectAll,
                icon: const AppIcon(Symbols.select_all_rounded, fill: 1, size: 22),
                onPressed: _selectAll,
              ),
              IconButton(
                tooltip: t.common.delete,
                icon: const AppIcon(Symbols.delete_rounded, fill: 1, size: 22),
                onPressed: count == 0 || widget.onDelete == null ? null : _deleteSelected,
              ),
              if (overflowEntries.isNotEmpty)
                PopupMenuButton<VoidCallback>(
                  icon: const AppIcon(Symbols.more_vert_rounded, fill: 1, size: 22),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => overflowEntries,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Pause all active (downloading and queued) children of a container node
  void _pauseAllChildren(DownloadTreeNode node) {
    final keys = _leafKeys(
      node,
      where: (leaf) => leaf.status == DownloadStatus.downloading || leaf.status == DownloadStatus.queued,
    );
    for (final key in keys) {
      widget.onPause?.call(key);
    }
  }

  /// Resume all paused children of a container node
  void _resumeAllChildren(DownloadTreeNode node) {
    final keys = _leafKeys(node, where: (leaf) => leaf.status == DownloadStatus.paused);
    for (final key in keys) {
      widget.onResume?.call(key);
    }
  }

  /// Delete all children of a container node via the container's globalKey
  /// so deleteDownload's transitive show/season path cleans up all maps.
  void _deleteAllChildren(DownloadTreeNode node) {
    final containerKey = resolveDownloadContainerGlobalKey(node, widget.metadata);
    if (containerKey != null) {
      widget.onDelete?.call(containerKey);
      return;
    }

    // Container globalKey unresolvable; fall back to per-leaf delete.
    for (final key in _leafKeys(node)) {
      widget.onDelete?.call(key);
    }
  }

  /// Get the keys of every leaf below a container node, in tree order.
  /// [where] filters which leaves are collected; unset collects all of them.
  List<String> _leafKeys(DownloadTreeNode node, {bool Function(DownloadTreeNode leaf)? where}) {
    final List<String> keys = [];
    for (final child in node.children) {
      if (child.hasChildren) {
        keys.addAll(_leafKeys(child, where: where));
      } else if (where == null || where(child)) {
        keys.add(child.key);
      }
    }
    return keys;
  }
}

/// Tree-node keys for shows/seasons aren't provider globalKeys; reconstruct
/// from any leaf episode's serverId + grandparentId/parentId.
@visibleForTesting
String? resolveDownloadContainerGlobalKey(DownloadTreeNode node, Map<String, MediaItem> metadata) {
  final firstLeafKey = _firstLeafKey(node);
  if (firstLeafKey == null) return null;
  final firstLeafMeta = metadata[firstLeafKey];
  final serverId = firstLeafMeta?.serverId;
  if (serverId == null) return null;
  switch (node.type) {
    case DownloadNodeType.show:
      final showRatingKey = firstLeafMeta!.grandparentId;
      if (showRatingKey == null) return null;
      return buildGlobalKey(ServerId(serverId), showRatingKey);
    case DownloadNodeType.season:
    case DownloadNodeType.album:
      final parentRatingKey = firstLeafMeta!.parentId;
      if (parentRatingKey == null) return null;
      return buildGlobalKey(ServerId(serverId), parentRatingKey);
    case DownloadNodeType.episode:
    case DownloadNodeType.movie:
    case DownloadNodeType.track:
      return null;
  }
}

String? _firstLeafKey(DownloadTreeNode node) {
  for (final child in node.children) {
    if (child.hasChildren) {
      final result = _firstLeafKey(child);
      if (result != null) return result;
    } else {
      return child.key;
    }
  }
  return null;
}

/// Helper class to store a node with its depth in the flattened tree
class _FlatNode {
  final DownloadTreeNode node;
  final int depth;

  const _FlatNode({required this.node, required this.depth});
}

/// A single action button of a tree row: the guards that decide which actions
/// exist live in one place ([_DownloadTreeItemState._actions]), so the focus
/// node count and the rendered buttons can never disagree.
typedef _RowAction = ({IconData icon, String tooltip, VoidCallback onPressed});

/// A single tree item with focusable row content and action buttons
class _DownloadTreeItem extends StatefulWidget {
  final DownloadTreeNode node;
  final int depth;
  final bool isExpanded;
  final VoidCallback onToggleExpansion;
  final void Function(String globalKey)? onPause;
  final void Function(String globalKey)? onResume;
  final void Function(String globalKey)? onRetry;
  final void Function(String globalKey)? onCancel;
  final void Function(String globalKey)? onDelete;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;
  final FocusNode? rowFocusNode;
  final bool autofocus;
  final void Function(DownloadTreeNode) pauseAllChildren;
  final void Function(DownloadTreeNode) resumeAllChildren;
  final void Function(DownloadTreeNode) deleteAllChildren;

  /// Multi-select: while [selectionMode] is on, the row's action buttons are
  /// replaced by a checkbox showing [checkState] (tri-state for containers).
  final bool selectionMode;
  final bool? checkState;
  final VoidCallback onToggleSelection;
  final VoidCallback onEnterSelection;

  const _DownloadTreeItem({
    required this.node,
    required this.depth,
    required this.isExpanded,
    required this.onToggleExpansion,
    this.onPause,
    this.onResume,
    this.onRetry,
    this.onCancel,
    this.onDelete,
    this.onNavigateLeft,
    this.onBack,
    this.rowFocusNode,
    this.autofocus = false,
    required this.pauseAllChildren,
    required this.resumeAllChildren,
    required this.deleteAllChildren,
    required this.selectionMode,
    required this.checkState,
    required this.onToggleSelection,
    required this.onEnterSelection,
  });

  @override
  State<_DownloadTreeItem> createState() => _DownloadTreeItemState();
}

class _DownloadTreeItemState extends State<_DownloadTreeItem> {
  /// Treat downloading items with no progress/speed as effectively queued
  /// (they're waiting in background_downloader's HoldingQueue).
  DownloadStatus get _effectiveStatus {
    if (widget.node.status == DownloadStatus.downloading &&
        widget.node.progress == 0 &&
        (widget.node.downloadProgress?.speed ?? 0) == 0) {
      return DownloadStatus.queued;
    }
    return widget.node.status;
  }

  FocusNode? _ownedRowFocusNode;
  final List<FocusNode> _buttonFocusNodes = [];

  FocusNode get _rowFocusNode => widget.rowFocusNode ?? _ownedRowFocusNode!;

  @override
  void initState() {
    super.initState();
    _initRowFocusNode();
    _initButtonFocusNodes();
  }

  @override
  void didUpdateWidget(_DownloadTreeItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reinitialize focus nodes if action count changed
    if (_actions().length != _buttonFocusNodes.length) {
      _disposeButtonFocusNodes();
      _initButtonFocusNodes();
    }
  }

  void _initRowFocusNode() {
    if (widget.rowFocusNode == null) {
      _ownedRowFocusNode = FocusNode(debugLabel: 'download_row_${widget.node.key}');
    }
  }

  void _initButtonFocusNodes() {
    final actionCount = _actions().length;
    for (int i = 0; i < actionCount; i++) {
      _buttonFocusNodes.add(FocusNode(debugLabel: 'download_action_$i'));
    }
  }

  void _disposeButtonFocusNodes() {
    for (final node in _buttonFocusNodes) {
      node.dispose();
    }
    _buttonFocusNodes.clear();
  }

  @override
  void dispose() {
    _ownedRowFocusNode?.dispose();
    _disposeButtonFocusNodes();
    super.dispose();
  }

  void _focusFirstButton() {
    if (_buttonFocusNodes.isNotEmpty) {
      _buttonFocusNodes.first.requestFocus();
    }
  }

  void _focusRow() {
    _rowFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canExpand = widget.node.hasChildren;
    // In selection mode every row trades its action buttons for a checkbox.
    final actions = widget.selectionMode ? const <_RowAction>[] : _actions();

    // Containers keep tap-to-expand even while selecting (their checkbox is
    // the select-subtree target); leaf taps toggle their checkbox.
    final VoidCallback? onRowActivated = canExpand
        ? widget.onToggleExpansion
        : widget.selectionMode
        ? widget.onToggleSelection
        : null;

    return Padding(
      padding: .only(left: widget.depth * 16.0),
      child: FocusableWrapper(
        focusNode: _rowFocusNode,
        autofocus: widget.autofocus,
        onSelect: onRowActivated,
        onNavigateLeft: widget.onNavigateLeft,
        onNavigateRight: actions.isNotEmpty ? _focusFirstButton : null,
        onBack: widget.onBack,
        borderRadius: 8.0,
        disableScale: true,
        useBackgroundFocus: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onRowActivated,
          onLongPress: widget.selectionMode ? null : widget.onEnterSelection,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(child: _buildRowContent(theme, canExpand)),

                if (widget.selectionMode)
                  Checkbox(
                    tristate: canExpand,
                    value: widget.checkState,
                    onChanged: (_) => widget.onToggleSelection(),
                  )
                else if (actions.isNotEmpty)
                  Row(
                    mainAxisSize: .min,
                    children: [for (int i = 0; i < actions.length; i++) _buildActionButton(actions[i], i)],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRowContent(ThemeData theme, bool canExpand) {
    return Row(
      children: [
        if (canExpand)
          AppIcon(widget.isExpanded ? Symbols.expand_more_rounded : Symbols.chevron_right_rounded, fill: 1, size: 20)
        else
          const SizedBox(width: 20),

        const SizedBox(width: 8),

        DownloadStatusIcon(status: _effectiveStatus, size: 20),

        const SizedBox(width: 12),

        Expanded(
          child: Column(
            crossAxisAlignment: .start,
            mainAxisSize: .min,
            children: [
              Text(
                widget.node.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: canExpand ? FontWeight.w600 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: .ellipsis,
              ),

              if (canExpand) ...[
                const SizedBox(height: 4),
                Text(
                  _getNodeSummary(),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
              ],

              // Completed leaves: on-disk size and the quality the download
              // was requested at (Original, or the transcode preset).
              if (!canExpand && _effectiveStatus == DownloadStatus.completed && _leafDetailLine() != null) ...[
                const SizedBox(height: 4),
                Text(
                  _leafDetailLine()!,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
              ],

              // Progress bar for active downloads
              if (_effectiveStatus == DownloadStatus.downloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: widget.node.progress,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                if (widget.node.downloadProgress != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${(widget.node.progress * 100).toStringAsFixed(1)}% - ${widget.node.downloadProgress!.speedFormatted}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ],

              // Queued label
              if (_effectiveStatus == DownloadStatus.queued) ...[
                const SizedBox(height: 4),
                Text(
                  t.downloads.downloadQueued,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                ),
              ],

              // Error message for failed downloads
              if (_effectiveStatus == DownloadStatus.failed && widget.node.downloadProgress?.errorMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.node.downloadProgress!.errorMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.red.withValues(alpha: 0.8)),
                  maxLines: 2,
                  overflow: .ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _getNodeSummary() {
    final total = widget.node.children.length;
    final completed = widget.node.completedChildrenCount;
    return t.downloads.completedOfTotal(completed: completed, total: total);
  }

  String? _leafDetailLine() => downloadLeafDetailLine(widget.node.downloadProgress);

  /// The actions this row offers, in render order. Single source of truth:
  /// both the button widgets and the focus nodes sizing come from this list,
  /// so they cannot drift apart. Uses the raw node status, not
  /// [_effectiveStatus] (which only remaps the row content).
  List<_RowAction> _actions() {
    final status = widget.node.status;
    final isContainer =
        widget.node.type == DownloadNodeType.show ||
        widget.node.type == DownloadNodeType.season ||
        widget.node.type == DownloadNodeType.album;
    final actions = <_RowAction>[];

    if (isContainer) {
      // Pause all button
      if ((status == DownloadStatus.downloading || status == DownloadStatus.queued) && widget.onPause != null) {
        actions.add((
          icon: Symbols.pause_rounded,
          tooltip: t.downloads.pauseAll,
          onPressed: () => widget.pauseAllChildren(widget.node),
        ));
      }

      // Resume all button
      if (status == DownloadStatus.paused && widget.onResume != null) {
        actions.add((
          icon: Symbols.play_arrow_rounded,
          tooltip: t.downloads.resumeAll,
          onPressed: () => widget.resumeAllChildren(widget.node),
        ));
      }

      // Delete all button
      if (widget.onDelete != null) {
        actions.add((
          icon: Symbols.delete_sweep_rounded,
          tooltip: t.downloads.deleteAll,
          onPressed: () async {
            if (await _confirmDelete()) widget.deleteAllChildren(widget.node);
          },
        ));
      }

      return actions;
    }

    final globalKey = widget.node.key;

    // Pause button for downloading items
    if (status == DownloadStatus.downloading && widget.onPause != null) {
      actions.add((icon: Symbols.pause_rounded, tooltip: t.common.pause, onPressed: () => widget.onPause!(globalKey)));
    }

    // Resume button for paused items
    if (status == DownloadStatus.paused && widget.onResume != null) {
      actions.add((
        icon: Symbols.play_arrow_rounded,
        tooltip: t.common.resume,
        onPressed: () => widget.onResume!(globalKey),
      ));
    }

    // Cancel button for downloading/queued items
    if ((status == DownloadStatus.downloading || status == DownloadStatus.queued) && widget.onCancel != null) {
      actions.add((
        icon: Symbols.close_rounded,
        tooltip: t.common.cancel,
        onPressed: () => widget.onCancel!(globalKey),
      ));
    }

    // Retry button for failed items
    if (status == DownloadStatus.failed && widget.onRetry != null) {
      actions.add((
        icon: Symbols.refresh_rounded,
        tooltip: t.downloads.retryDownload,
        onPressed: () => widget.onRetry!(globalKey),
      ));
    }

    // Delete button for completed/failed/cancelled items
    if ((status == DownloadStatus.completed || status == DownloadStatus.failed || status == DownloadStatus.cancelled) &&
        widget.onDelete != null) {
      actions.add((
        icon: Symbols.delete_rounded,
        tooltip: t.common.delete,
        onPressed: () async {
          if (await _confirmDelete()) widget.onDelete!(globalKey);
        },
      ));
    }

    return actions;
  }

  Future<bool> _confirmDelete() {
    return showDeleteConfirmation(
      context,
      title: t.downloads.deleteDownload,
      message: t.downloads.deleteConfirm(title: widget.node.title),
    );
  }

  Widget _buildActionButton(_RowAction action, int buttonIndex) {
    final isFirst = buttonIndex == 0;
    final isLast = buttonIndex == _buttonFocusNodes.length - 1;

    return FocusableWrapper(
      focusNode: _buttonFocusNodes[buttonIndex],
      onSelect: action.onPressed,
      onNavigateLeft: isFirst ? _focusRow : () => _buttonFocusNodes[buttonIndex - 1].requestFocus(),
      onNavigateRight: isLast ? null : () => _buttonFocusNodes[buttonIndex + 1].requestFocus(),
      onBack: widget.onBack,
      borderRadius: 20.0,
      disableScale: true,
      useBackgroundFocus: true,
      autoScroll: false,
      child: Tooltip(
        message: action.tooltip,
        child: GestureDetector(
          onTap: action.onPressed,
          child: Padding(padding: const EdgeInsets.all(8.0), child: AppIcon(action.icon, fill: 1, size: 20)),
        ),
      ),
    );
  }
}
