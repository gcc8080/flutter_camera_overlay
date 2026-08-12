import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_camera_overlay/model.dart';
import 'package:flutter_camera_overlay/overlay_shape.dart';

typedef XFileCallback = void Function(XFile file);

class CameraOverlay extends StatefulWidget {
  const CameraOverlay(
    this.camera,
    this.model,
    this.onCapture, {
    super.key,
    this.flash = false,
    this.enableCaptureButton = true,
    this.label,
    this.info,
    this.loadingWidget,
    this.infoMargin,
  });

  final CameraDescription camera;
  final OverlayModel model;
  final bool flash;
  final bool enableCaptureButton;
  final XFileCallback onCapture;
  final String? label;
  final String? info;
  final Widget? loadingWidget;
  final EdgeInsets? infoMargin;

  @override
  State<CameraOverlay> createState() => _FlutterCameraOverlayState();
}

class _FlutterCameraOverlayState extends State<CameraOverlay>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void> _cameraOperation = Future<void>.value();
  bool _cameraShouldBeActive = true;
  bool _isDisposed = false;
  bool _isTakingPicture = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final AppLifecycleState? lifecycleState =
        WidgetsBinding.instance.lifecycleState;
    _cameraShouldBeActive =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    if (_cameraShouldBeActive) {
      _enqueueCameraOperation('initialize the camera', _initializeCamera);
    }
  }

  @override
  void didUpdateWidget(CameraOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.camera.name != widget.camera.name) {
      _enqueueCameraOperation('switch cameras', () async {
        await _disposeCamera();
        await _initializeCamera();
      });
    } else if (oldWidget.flash != widget.flash) {
      _enqueueCameraOperation('update the flash mode', _updateFlashMode);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cameraShouldBeActive = true;
      _enqueueCameraOperation('resume the camera', _initializeCamera);
      return;
    }

    _cameraShouldBeActive = false;
    _enqueueCameraOperation('pause the camera', _disposeCamera);
  }

  void _enqueueCameraOperation(
    String description,
    Future<void> Function() operation,
  ) {
    _cameraOperation = _cameraOperation.then<void>((_) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'flutter_camera_overlay',
            context: ErrorDescription('while attempting to $description'),
          ),
        );
      }
    });
  }

  Future<void> _initializeCamera() async {
    if (_isDisposed || !_cameraShouldBeActive) {
      return;
    }

    final CameraController? existingController = _controller;
    if (existingController != null &&
        existingController.value.isInitialized) {
      await _setFlashMode(existingController);
      return;
    }

    await _disposeCamera();
    if (_isDisposed || !_cameraShouldBeActive) {
      return;
    }

    final CameraController controller = CameraController(
      widget.camera,
      ResolutionPreset.max,
      enableAudio: false,
    );
    _controller = controller;

    try {
      await controller.initialize();
      if (_isDisposed ||
          !_cameraShouldBeActive ||
          !identical(_controller, controller)) {
        return;
      }

      await _setFlashMode(controller);
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      if (identical(_controller, controller)) {
        _controller = null;
      }
      await controller.dispose();
      rethrow;
    }
  }

  Future<void> _updateFlashMode() async {
    final CameraController? controller = _controller;
    if (_isDisposed ||
        !_cameraShouldBeActive ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    await _setFlashMode(controller);
  }

  Future<void> _setFlashMode(CameraController controller) {
    return controller.setFlashMode(
      widget.flash ? FlashMode.auto : FlashMode.off,
    );
  }

  Future<void> _disposeCamera() async {
    final CameraController? controller = _controller;
    if (controller == null) {
      return;
    }

    _controller = null;
    _isTakingPicture = false;
    if (mounted) {
      setState(() {});
    }
    await controller.dispose();
  }

  void _takePicture() {
    if (_isDisposed ||
        !_cameraShouldBeActive ||
        _isTakingPicture ||
        !mounted) {
      return;
    }

    setState(() {
      _isTakingPicture = true;
    });

    _enqueueCameraOperation('take a picture', () async {
      try {
        for (int i = 10; i > 0; i--) {
          if (_isDisposed || !_cameraShouldBeActive) {
            return;
          }
          await HapticFeedback.vibrate();
        }

        final CameraController? controller = _controller;
        if (_isDisposed ||
            !_cameraShouldBeActive ||
            controller == null ||
            !controller.value.isInitialized ||
            controller.value.isTakingPicture) {
          return;
        }

        final XFile file = await controller.takePicture();
        if (!_isDisposed &&
            _cameraShouldBeActive &&
            identical(controller, _controller)) {
          widget.onCapture(file);
        }
      } finally {
        _isTakingPicture = false;
        if (mounted) {
          setState(() {});
        }
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _cameraShouldBeActive = false;
    WidgetsBinding.instance.removeObserver(this);
    _enqueueCameraOperation('dispose the camera', _disposeCamera);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget loadingWidget = widget.loadingWidget ??
        Container(
          color: Colors.white,
          height: double.infinity,
          width: double.infinity,
          child: const Align(
            alignment: Alignment.center,
            child: Text('loading camera'),
          ),
        );
    final CameraController? controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return loadingWidget;
    }

    return Stack(
      alignment: Alignment.bottomCenter,
      fit: StackFit.expand,
      children: <Widget>[
        CameraPreview(controller),
        OverlayShape(widget.model),
        if (widget.label != null || widget.info != null)
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: widget.infoMargin ??
                  const EdgeInsets.only(top: 100, left: 20, right: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (widget.label != null)
                    Text(
                      widget.label!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (widget.info != null)
                    Flexible(
                      child: Text(
                        widget.info!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (widget.enableCaptureButton)
          Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black12,
                  shape: BoxShape.circle,
                ),
                margin: const EdgeInsets.all(25),
                child: IconButton(
                  enableFeedback: true,
                  color: Colors.white,
                  onPressed: _isTakingPicture || !_cameraShouldBeActive
                      ? null
                      : _takePicture,
                  icon: const Icon(Icons.camera),
                  iconSize: 72,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
