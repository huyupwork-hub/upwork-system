import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import 'theme.dart';

/// Thumbnails for one punch item, with add and delete.
///
/// Read-only when the parent inspection is submitted (D17). The database refuses
/// the write either way — this only stops the app offering it.
class PhotoStrip extends StatefulWidget {
  const PhotoStrip({
    super.key,
    required this.photos,
    required this.source,
    required this.inspectionId,
    required this.itemId,
    required this.editable,
  });

  final PhotosRepository photos;
  final PhotoSource source;
  final String inspectionId;
  final String itemId;
  final bool editable;

  @override
  State<PhotoStrip> createState() => _PhotoStripState();
}

class _PhotoStripState extends State<PhotoStrip> {
  List<ItemPhoto>? _rows;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await widget.photos.listFor(widget.itemId);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _add() async {
    final choice = await showCupertinoModalPopup<_Pick>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: const Text('Add a photo'),
        actions: [
          CupertinoActionSheetAction(
            key: const Key('photo-camera'),
            onPressed: () => Navigator.of(sheet).pop(_Pick.camera),
            child: const Text('Take Photo'),
          ),
          CupertinoActionSheetAction(
            key: const Key('photo-gallery'),
            onPressed: () => Navigator.of(sheet).pop(_Pick.gallery),
            child: const Text('Choose from Library'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (choice == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final captured = choice == _Pick.camera
          ? await widget.source.capture()
          : await widget.source.pickFromGallery();
      // Null means the user cancelled the picker; not an error.
      if (captured == null) return;

      await widget.photos.upload(
        inspectionId: widget.inspectionId,
        itemId: widget.itemId,
        photo: captured,
      );
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(ItemPhoto photo) async {
    final deleted = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        fullscreenDialog: true,
        builder: (_) => PhotoViewer(
          photo: photo,
          photos: widget.photos,
          editable: widget.editable,
        ),
      ),
    );
    if (deleted == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 84,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppMetrics.gutter),
            children: [
              if (rows == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: CupertinoActivityIndicator(),
                )
              else ...[
                for (final p in rows)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _Thumb(
                      key: Key('photo-thumb-${p.id}'),
                      photo: p,
                      photos: widget.photos,
                      onTap: () => _open(p),
                    ),
                  ),
                if (widget.editable)
                  _AddTile(
                    key: const Key('add-photo-button'),
                    busy: _busy,
                    onTap: _busy ? null : _add,
                  ),
                if (!widget.editable && rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Text(
                      'No photos.',
                      key: Key('photos-empty'),
                      style: TextStyle(fontSize: 15, color: AppColors.label2),
                    ),
                  ),
              ],
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(
              _error!,
              key: const Key('photo-error'),
              style: const TextStyle(fontSize: 13, color: AppColors.red),
            ),
          ),
      ],
    );
  }
}

enum _Pick { camera, gallery }

/// Resolves a short-lived signed URL, then renders it.
///
/// The bucket is private, so there is no stable URL to cache; a failure to
/// resolve or load shows a placeholder rather than an exception box.
class _Thumb extends StatelessWidget {
  const _Thumb({
    super.key,
    required this.photo,
    required this.photos,
    required this.onTap,
  });

  final ItemPhoto photo;
  final PhotosRepository photos;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 72,
          height: 72,
          child: FutureBuilder<String>(
            future: photos.signedUrl(photo),
            builder: (context, snap) {
              if (!snap.hasData) return const _ThumbPlaceholder();
              return Image.network(
                snap.data!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) =>
                    const _ThumbPlaceholder(),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.fill,
        alignment: Alignment.center,
        child: const Icon(
          CupertinoIcons.photo,
          size: 22,
          color: AppColors.label3,
        ),
      );
}

class _AddTile extends StatelessWidget {
  const _AddTile({super.key, required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: AppColors.fill,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: busy
            ? const CupertinoActivityIndicator()
            : const Icon(CupertinoIcons.camera,
                size: 24, color: AppColors.blue),
      ),
    );
  }
}

/// Full-screen viewer. Delete lives here, not on the thumbnail, so removing a
/// photo is always deliberate.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({
    super.key,
    required this.photo,
    required this.photos,
    required this.editable,
  });

  final ItemPhoto photo;
  final PhotosRepository photos;
  final bool editable;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: const Text('Delete this photo?'),
        message: const Text('This cannot be undone.'),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheet).pop(true),
            child: const Text('Delete'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(false),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.photos.delete(widget.photo);
      if (mounted) Navigator.of(context).pop(true);
    } on PhotoCleanupException catch (e) {
      // The metadata row IS gone, so the photo is removed from the user's point
      // of view. Say what happened rather than pretending it failed outright.
      if (mounted) {
        setState(() => _error = e.toString());
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.label,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.card,
        middle: const Text('Photo'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Done'),
        ),
        trailing: widget.editable
            ? CupertinoButton(
                key: const Key('delete-photo-button'),
                padding: EdgeInsets.zero,
                onPressed: _busy ? null : _delete,
                child: const Icon(
                  CupertinoIcons.delete,
                  color: AppColors.red,
                ),
              )
            : null,
      ),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: FutureBuilder<String>(
                future: widget.photos.signedUrl(widget.photo),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(
                      child: CupertinoActivityIndicator(
                        color: AppColors.card,
                      ),
                    );
                  }
                  return InteractiveViewer(
                    child: Image.network(
                      snap.data!,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stack) => const Center(
                        child: Icon(
                          CupertinoIcons.photo,
                          size: 48,
                          color: AppColors.label3,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  key: const Key('photo-viewer-error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: AppColors.red),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
