import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/play_queue.dart';
import '../providers/download_provider.dart';
import '../providers/playback_state_provider.dart';
import 'media_list_playback_launcher.dart';

/// Offline launcher for shuffled show/season playback.
///
/// No server is reachable offline, so the queue is built from
/// [DownloadProvider]'s completed episode downloads and shuffled locally —
/// the same client-side [LocalPlayQueue] path [JellyfinSequentialLauncher]
/// uses online. [LocalPlayQueue]s are fully resident, so the player resolves
/// prev/next from [PlaybackStateProvider] without any server round trip. The
/// player is entered with `isOffline: true` so playback resolves downloaded
/// files.
class OfflineShuffleLauncher extends MediaListPlaybackLauncher {
  final BuildContext context;

  /// Hook for tests — bypasses [Provider.of] so callers can inject a fake
  /// [DownloadProvider]. Production callers leave this null.
  final DownloadProvider? downloadProviderForTesting;

  /// Hook for tests — bypasses [Provider.of] so callers can inject a
  /// fake [PlaybackStateProvider]. Production callers leave this null.
  final PlaybackStateProvider? playbackStateForTesting;

  /// Hook for tests — replaces the real player navigation so the unit
  /// test doesn't need a Navigator/route stack.
  final Future<void> Function(MediaItem item)? navigateForTesting;

  OfflineShuffleLauncher({
    required this.context,
    this.downloadProviderForTesting,
    this.playbackStateForTesting,
    this.navigateForTesting,
  });

  /// Collections and playlists have no offline browsing surface; only the
  /// downloads library's show/season detail can launch playback offline.
  @override
  Future<PlayQueueResult> launchFromCollectionOrPlaylist({
    required Object item,
    required bool shuffle,
    MediaItem? startItem,
    bool showLoadingIndicator = true,
  }) async {
    return PlayQueueError(Exception('Collections and playlists cannot be played offline'));
  }

  /// Folder rows are a library-tree feature; there is no offline surface.
  @override
  Future<PlayQueueResult> launchFromFolder({
    required MediaItem folder,
    required bool shuffle,
    bool showLoadingIndicator = true,
  }) async {
    return PlayQueueError(Exception('Folders cannot be played offline'));
  }

  @override
  Future<PlayQueueResult> launchShuffledShow({required MediaItem metadata, bool showLoadingIndicator = true}) async {
    final kind = metadata.kind;
    if (kind != MediaKind.show && kind != MediaKind.season) {
      return PlayQueueError(Exception('Shuffle play only works for shows and seasons'));
    }
    final String showId;
    if (kind == MediaKind.show) {
      showId = metadata.id;
    } else {
      final parent = metadata.parentId;
      if (parent == null) {
        return PlayQueueError(Exception('Season is missing parentId'));
      }
      showId = parent;
    }

    // Everything below reads local state only, so no loading dialog is
    // needed; executeWithLoading still centralizes the empty-queue snackbar
    // and error-to-result translation.
    return executeWithLoading(
      context: context,
      showLoading: false,
      actionLabel: t.common.shuffle,
      execute: (dismissLoading) async {
        final downloadProvider = downloadProviderForTesting ?? context.read<DownloadProvider>();
        var episodes = downloadProvider.getDownloadedEpisodesForShow(showId);
        if (kind == MediaKind.season) {
          episodes = episodes.where((ep) => ep.parentIndex == metadata.index).toList();
        }
        if (episodes.isEmpty) return const PlayQueueEmpty();

        // Preserve the show/season's server identity on the episodes, the
        // same way the offline Play button does.
        final items =
            episodes
                .map(
                  (e) => e.copyWith(
                    serverId: metadata.serverId ?? e.serverId,
                    serverName: metadata.serverName ?? e.serverName,
                  ),
                )
                .toList()
              ..shuffle(Random());

        if (!context.mounted && navigateForTesting == null) {
          return const PlayQueueError('Context not mounted');
        }

        final playbackState = playbackStateForTesting ?? context.read<PlaybackStateProvider>();
        return launchLocalQueuePlayback(
          context: context,
          playbackState: playbackState,
          queue: LocalPlayQueue(id: 'offline:$showId', items: items, currentIndex: 0, shuffled: true),
          contextKey: showId,
          isOffline: true,
          navigateForTesting: navigateForTesting,
        );
      },
    );
  }
}
