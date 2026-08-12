# flutter_camera_overlay

This package provides a simple camera overlay to aid capture of documents such 
as national ID cards, passports and driving licenses.

## Flutter 3.27 / Camera2 branch

The `fix/use-patched-camera-android` branch uses `camera 0.11.2` and pins a patched Camera2
implementation from `gcc8080/camera_android`. The immutable commit backports capture-session
teardown race guards while retaining Flutter 3.27 and Android API 23 compatibility.

Flutter 3.27 chooses a non-default federated plugin only when it is a direct dependency of the host
application. Therefore the application's own `pubspec.yaml` must repeat the same Camera2
dependency:

```yaml
dependencies:
  flutter_camera_overlay:
    git:
      url: https://github.com/gcc8080/flutter_camera_overlay.git
      ref: fix/use-patched-camera-android
  camera_android:
    git:
      url: https://github.com/gcc8080/camera_android.git
      ref: e61427e9ad09754aee6767bf996a4d436cb3ab31
```

Do not add a different hosted or Git source for `camera_android`. After `flutter pub get`, verify
that the resolved Git revision is `e61427e9ad09754aee6767bf996a4d436cb3ab31` and that the generated
Android plugin registrant uses `io.flutter.plugins.camera.CameraPlugin`, not the CameraX
implementation.

## Default ISO Card formats
https://www.iso.org/standard/70483.html

cardID1 - Most banking cards and ID cards

cardID2 - French and other ID cards. Visas.

cardID3 - United States government ID cards

simID000 - SIM cards

<img src="https://raw.githubusercontent.com/matwright/flutter_camera_overlay/main/example/flutter_camera_overlay.webp" width="300">

## Getting Started

Import the file.

```dart
import 'package:flutter_camera_overlay/flutter_camera_overlay.dart';
```

### Use with default style:

```dart
CameraOverlay(
    snapshot.data!.first,
    CardOverlay.byFormat(format),
    (XFile file) => print(file.path),
    info: 'Position your ID card within the rectangle and ensure the image is perfectly readable.',
    label: 'Scanning ID Card');
```

### TODO

* add data capture (card numbers, etc)
* automatic edge detection & capture
