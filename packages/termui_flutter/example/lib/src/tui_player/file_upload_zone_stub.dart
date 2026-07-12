import 'package:cross_file/cross_file.dart';

void Function()? setupWebDropZone({
  required void Function(bool isDragging) onDragStateChanged,
  required void Function(Map<String, XFile> files) onFilesSelected,
}) {
  // No-op on VM/desktop.
  return null;
}
