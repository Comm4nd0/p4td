import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

/// Full-screen camera that lets the user capture multiple photos in one
/// session. Returns a `List<(Uint8List, String)>` of (jpegBytes, fileName)
/// via Navigator.pop when the user taps Done.
class MultiPhotoCaptureScreen extends StatefulWidget {
  const MultiPhotoCaptureScreen({super.key});

  @override
  State<MultiPhotoCaptureScreen> createState() => _MultiPhotoCaptureScreenState();
}

class _MultiPhotoCaptureScreenState extends State<MultiPhotoCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  FlashMode _flashMode = FlashMode.off;
  bool _initializing = true;
  bool _capturing = false;
  bool _saveToGallery = false;
  String? _initError;

  final List<(Uint8List, String)> _captured = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      c.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    setState(() {
      _initializing = true;
      _initError = null;
    });
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _initializing = false;
          _initError = 'No camera available on this device.';
        });
        return;
      }
      if (_cameraIndex >= _cameras.length) _cameraIndex = 0;
      await _attachController(_cameras[_cameraIndex]);
    } on CameraException catch (e) {
      setState(() {
        _initializing = false;
        _initError = _friendlyCameraError(e);
      });
    } catch (e) {
      setState(() {
        _initializing = false;
        _initError = 'Failed to start camera: $e';
      });
    }
  }

  Future<void> _attachController(CameraDescription camera) async {
    await _controller?.dispose();
    final c = CameraController(
      camera,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = c;
    try {
      await c.initialize();
      try {
        await c.setFlashMode(_flashMode);
      } catch (_) {
        // Front cameras often lack flash — silently ignore.
      }
      if (mounted) setState(() => _initializing = false);
    } on CameraException catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _initError = _friendlyCameraError(e);
        });
      }
    }
  }

  String _friendlyCameraError(CameraException e) {
    switch (e.code) {
      case 'CameraAccessDenied':
      case 'CameraAccessDeniedWithoutPrompt':
      case 'CameraAccessRestricted':
        return 'Camera permission denied. Enable it in your device settings to take photos.';
      default:
        return e.description ?? e.code;
    }
  }

  Future<void> _switchLens() async {
    if (_cameras.length < 2) return;
    setState(() => _initializing = true);
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _attachController(_cameras[_cameraIndex]);
  }

  Future<void> _cycleFlash() async {
    final next = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    setState(() => _flashMode = next);
    try {
      await _controller?.setFlashMode(next);
    } catch (_) {}
  }

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      final shot = await c.takePicture();
      final bytes = await shot.readAsBytes();
      final name = 'photo_${DateTime.now().millisecondsSinceEpoch}_'
          '${_captured.length + 1}.jpg';
      if (mounted) {
        setState(() => _captured.add((bytes, name)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _removePhoto(int index) {
    setState(() => _captured.removeAt(index));
  }

  Future<void> _toggleSaveToGallery() async {
    if (_saveToGallery) {
      setState(() => _saveToGallery = false);
      return;
    }
    try {
      final hasAccess = await Gal.hasAccess();
      final granted = hasAccess ? true : await Gal.requestAccess();
      if (!mounted) return;
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Photo library permission denied. Enable it in your device settings to save photos.',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      setState(() => _saveToGallery = true);
    } on GalException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not enable saving: ${e.type.message}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _done() async {
    final photos = List<(Uint8List, String)>.from(_captured);
    if (_saveToGallery && photos.isNotEmpty) {
      final ok = await _saveAllToGallery(photos);
      if (!mounted) return;
      if (!ok) return; // Let the user decide what to do next.
    }
    if (mounted) Navigator.pop(context, photos);
  }

  Future<bool> _saveAllToGallery(List<(Uint8List, String)> photos) async {
    final total = photos.length;
    final progress = ValueNotifier<int>(0);
    BuildContext? dialogCtx;

    // Re-verify permission immediately before saving — the toggle state
    // may be stale if the user revoked access in settings since enabling it.
    try {
      final granted = await Gal.hasAccess() || await Gal.requestAccess();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Photo library permission denied. Enable it in your device settings to save photos.',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        return false;
      }
    } catch (_) {
      // Fall through — putImageBytes will surface a clearer error.
    }

    if (!mounted) return false;

    // Show progress dialog. We deliberately don't await the future from
    // showDialog (we close it ourselves) and capture the dialog's context so
    // we can definitively pop the correct route later.
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return PopScope(
          canPop: false,
          child: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, __) => AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text('Saving $done/$total to your photos...'),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: total > 0 ? done / total : 0),
                ],
              ),
            ),
          ),
        );
      },
    ));

    // Yield a frame so the dialog actually renders before native work begins.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    String? errorMessage;
    int saved = 0;
    try {
      for (final (bytes, fileName) in photos) {
        // Some gal versions choke on names that already include an extension
        // and either fail silently or hang on Android — strip it defensively.
        final bareName = fileName.replaceAll(RegExp(r'\.[^./\\]+$'), '');
        try {
          await Gal.putImageBytes(bytes, name: bareName)
              .timeout(const Duration(seconds: 30));
          saved++;
          progress.value = saved;
        } on TimeoutException {
          errorMessage = 'Saving stopped after $saved/$total photos (timed out).';
          break;
        } on GalException catch (e) {
          errorMessage = 'Could not save photo ${saved + 1} of $total: ${e.type.message}';
          break;
        } on PlatformException catch (e) {
          errorMessage = 'Could not save photo ${saved + 1} of $total: ${e.message ?? e.code}';
          break;
        } catch (e) {
          errorMessage = 'Could not save photo ${saved + 1} of $total: $e';
          break;
        }
      }
    } finally {
      // Always close the progress dialog so we can never end up with a stuck
      // spinner regardless of what happened. Prefer the dialog's own context;
      // fall back to the screen context if the builder hadn't run yet.
      final closeCtx = (dialogCtx != null && dialogCtx!.mounted) ? dialogCtx! : context;
      if (mounted && Navigator.canPop(closeCtx)) {
        Navigator.of(closeCtx).pop();
      }
      progress.dispose();
    }

    if (!mounted) return saved == total;

    if (errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage), backgroundColor: Colors.red),
      );
      // If at least one saved, let the upload proceed; otherwise stay put.
      return saved > 0;
    }

    return true;
  }

  Future<bool> _confirmDiscard() async {
    if (_captured.isEmpty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard photos?'),
        content: Text(
          'You have ${_captured.length} unsaved photo${_captured.length == 1 ? '' : 's'}. '
          'Going back will lose them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep shooting'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  IconData _flashIcon() {
    return switch (_flashMode) {
      FlashMode.off => Icons.flash_off,
      FlashMode.auto => Icons.flash_auto,
      _ => Icons.flash_on,
    };
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _captured.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_initError != null) return _buildError();
    if (_initializing || _controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    return Column(
      children: [
        _buildTopBar(),
        Expanded(child: _buildPreview()),
        _buildBottomControls(),
      ],
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.no_photography, color: Colors.white70, size: 64),
            const SizedBox(height: 16),
            Text(
              _initError ?? 'Camera unavailable',
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () async {
              if (await _confirmDiscard() && mounted) {
                Navigator.pop(context);
              }
            },
          ),
          const Spacer(),
          IconButton(
            tooltip: _saveToGallery
                ? 'Saving copies to your photos'
                : 'Also save copies to your photos',
            icon: Icon(
              _saveToGallery ? Icons.save_alt : Icons.save_alt_outlined,
              color: _saveToGallery ? Colors.amberAccent : Colors.white,
            ),
            onPressed: () => _toggleSaveToGallery(),
          ),
          IconButton(
            tooltip: 'Flash',
            icon: Icon(_flashIcon(), color: Colors.white),
            onPressed: _cycleFlash,
          ),
          if (_cameras.length > 1)
            IconButton(
              tooltip: 'Switch camera',
              icon: const Icon(Icons.cameraswitch, color: Colors.white),
              onPressed: _switchLens,
            ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final c = _controller!;
    // previewSize is reported in the camera sensor's native (landscape)
    // orientation, so flip it for a portrait preview frame.
    final previewSize = c.value.previewSize;
    final aspect = previewSize == null
        ? 3 / 4
        : previewSize.height / previewSize.width;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: CameraPreview(c),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_captured.isNotEmpty) _buildThumbnailStrip(),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 24),
              SizedBox(
                width: 60,
                child: Text(
                  _captured.isEmpty ? '' : '${_captured.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
              ),
              const Spacer(),
              _buildShutter(),
              const Spacer(),
              SizedBox(
                width: 60,
                child: _captured.isEmpty
                    ? null
                    : FilledButton(
                        onPressed: () => _done(),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        child: const Text('Done'),
                      ),
              ),
              const SizedBox(width: 16),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildShutter() {
    return GestureDetector(
      onTap: _capture,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _capturing ? Colors.white54 : Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnailStrip() {
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: _captured.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (bytes, _) = _captured[index];
          return SizedBox(
            width: 76,
            height: 76,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    bytes,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => _removePhoto(index),
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.black87,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: const Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
