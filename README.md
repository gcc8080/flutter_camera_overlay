# flutter_camera_overlay

This package provides a simple camera overlay to aid capture of documents such 
as national ID cards, passports and driving licenses.

## Default ISO Card formats
https://www.iso.org/standard/70483.html

cardID1 - Most banking cards and ID cards

cardID2 - French and other ID cards. Visas.

cardID3 - United States government ID cards

simID000 - SIM cards

<img src="https://raw.githubusercontent.com/gcc8080/flutter_camera_overlay/main/example/flutter_camera_overlay.webp" width="300">

## Compatibility

Version 0.2.0 requires Flutter 3.27 or newer and Dart 3.6 or newer. Android
uses the CameraX implementation of Flutter's camera plugin to avoid the legacy
Camera2 capture-session shutdown race. The supported platform baselines are
Android API 23+ and iOS 13+.

Do not add the legacy `camera_android` package to the consuming application;
doing so explicitly opts Android back into the Camera2 implementation.

The overlay releases camera resources while the app is inactive and restores
them when the app resumes. Applications should avoid wrapping the overlay in a
second owner that initializes or disposes the same camera concurrently.

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
