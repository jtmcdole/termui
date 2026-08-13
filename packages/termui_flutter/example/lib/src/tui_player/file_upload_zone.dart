import 'dart:async';
import 'dart:developer' as developer;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cross_file/cross_file.dart';

import 'file_upload_zone_stub.dart'
    if (dart.library.js_interop) 'file_upload_zone_web.dart'
    as web_impl;

/// A widget that handles file drag-and-drop and manual selection.
final class FileUploadZone extends StatefulWidget {
  /// Creates a [FileUploadZone].
  const FileUploadZone({
    super.key,
    required this.child,
    required this.onFilesSelected,
    this.targetPath = 'ROOT',
  });

  /// The child widget to wrap with the drop zone.
  final Widget child;

  /// The human-readable target path name (e.g. "/data/logs").
  final String targetPath;

  /// Callback when files are selected (dropped or picked).
  final ValueChanged<Map<String, XFile>> onFilesSelected;

  @override
  State<FileUploadZone> createState() => _FileUploadZoneState();
}

class _FileUploadZoneState extends State<FileUploadZone> {
  bool _isDragging = false;
  Timer? _dragTimeout;
  void Function()? _webDispose;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _webDispose = web_impl.setupWebDropZone(
        onDragStateChanged: (isDragging) {
          if (mounted) {
            setState(() {
              _isDragging = isDragging;
            });
          }
        },
        onFilesSelected: (files) {
          if (mounted) {
            widget.onFilesSelected(files);
          }
        },
      );
    }
  }

  void _resetDragTimer() {
    _dragTimeout?.cancel();
    _dragTimeout = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _isDragging = false);
      }
    });
  }

  @override
  void dispose() {
    _dragTimeout?.cancel();
    _webDispose?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stack = SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(child: RepaintBoundary(child: widget.child)),
          if (_isDragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.blue.withValues(alpha: 0.4),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.green, width: 8),
                        borderRadius: BorderRadius.circular(16),
                        color: Colors.black.withValues(alpha: 0.85),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.upload_file,
                            size: 64,
                            color: Colors.green,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'DROP FILES TO UPLOAD',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 2,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'TARGET: ${widget.targetPath}',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Colors.green.withValues(alpha: 0.7),
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (kIsWeb) {
      return stack;
    }

    return DropTarget(
      onDragEntered: (DropEventDetails e) {
        // ignore: avoid_print
        print('[FileUploadZone] onDragEntered: ${e.localPosition}');
        _resetDragTimer();
        setState(() => _isDragging = true);
      },
      onDragExited: (e) {
        // ignore: avoid_print
        print('[FileUploadZone] onDragExited');
        _dragTimeout?.cancel();
        setState(() => _isDragging = false);
      },
      onDragUpdated: (e) {
        // ignore: avoid_print
        print('[FileUploadZone] onDragUpdated: ${e.localPosition}');
        _resetDragTimer();
      },
      onDragDone: (details) {
        // ignore: avoid_print
        print('[FileUploadZone] onDragDone: ${details.files.length} files');
        _dragTimeout?.cancel();
        setState(() => _isDragging = false);
        try {
          if (details.files.isNotEmpty) {
            final files = <String, XFile>{
              for (final file in details.files)
                if (file is! DropItemDirectory) file.name: file,
            };
            // ignore: avoid_print
            print(
              '[FileUploadZone] Drop completed. Found files: ${files.keys.join(', ')}',
            );
            developer.log(
              'Dropped files: ${details.files.map((f) => "${f.name}-${f.runtimeType}").join(', ')}',
            );
            widget.onFilesSelected(files);
          }
        } catch (e, s) {
          developer.log('Error processing dropped files: $e', stackTrace: s);
          setState(() => _isDragging = false);
        }
      },
      child: stack,
    );
  }
}
