/// The one place `image_picker` is used.
///
/// Everything above this file talks to [PhotoSource], so the widget tests never
/// load a platform channel. Capture on a real device is verified on Android
/// (D20); it is not something a host-side test can prove.
library;

import 'package:image_picker/image_picker.dart';

import 'models.dart';
import 'repositories.dart';

class ImagePickerPhotoSource implements PhotoSource {
  ImagePickerPhotoSource({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// A sensible ceiling applied at capture time so a 12 MP phone photo does not
  /// arrive as 8 MB and get rejected after the user has waited for it. This is
  /// the whole of the "compression pipeline" — a size cap, nothing more.
  static const double _maxDimension = 2048;
  static const int _quality = 85;

  @override
  Future<CapturedPhoto?> capture() => _pick(ImageSource.camera);

  @override
  Future<CapturedPhoto?> pickFromGallery() => _pick(ImageSource.gallery);

  Future<CapturedPhoto?> _pick(ImageSource source) async {
    final file = await _picker.pickImage(
      source: source,
      maxWidth: _maxDimension,
      maxHeight: _maxDimension,
      imageQuality: _quality,
    );
    // Null means the user backed out. Cancelling is not a failure.
    if (file == null) return null;

    final bytes = await file.readAsBytes();

    // `image_picker` re-encodes to JPEG when imageQuality is set, so the
    // reported mime type is advisory at best. The content type is decided from
    // the bytes' own magic number rather than from anything the platform or a
    // filename claims — the same reason the storage path never trusts a caller.
    final contentType = _sniff(bytes) ?? 'image/jpeg';

    return CapturedPhoto(bytes: bytes, contentType: contentType);
  }

  /// Minimal magic-number sniff for the three types the schema accepts.
  static String? _sniff(List<int> b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (b.length >= 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'image/png';
    }
    // RIFF....WEBP
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }
}
