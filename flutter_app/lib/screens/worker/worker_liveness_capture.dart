import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../models/worker_models.dart';

class WorkerLivenessResult {
  const WorkerLivenessResult({required this.photo, required this.checks});

  final XFile photo;
  final List<DocumentValidationCheck> checks;
}

class WorkerLivenessCapture extends StatefulWidget {
  const WorkerLivenessCapture({super.key});

  @override
  State<WorkerLivenessCapture> createState() => _WorkerLivenessCaptureState();
}

class _WorkerLivenessCaptureState extends State<WorkerLivenessCapture> {
  CameraController? _controller;
  late final FaceDetector _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
      enableTracking: true,
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.15,
    ),
  );
  final _yawSamples = <double>[];
  int _step = 0;
  bool _loading = true;
  bool _capturing = false;
  String? _error;

  static const _instructions = [
    'Look straight at the camera',
    'Slowly turn your head to the left',
    'Slowly turn your head to the right',
  ];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Camera could not be started. Allow camera permission and try again.';
        });
      }
    }
  }

  Future<void> _captureStep() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }
    setState(() {
      _capturing = true;
      _error = null;
    });
    try {
      final photo = await controller.takePicture();
      final faces = await _faceDetector.processImage(
        InputImage.fromFilePath(photo.path),
      );
      if (faces.length != 1) {
        throw const FormatException('Show one face clearly in the camera.');
      }
      final yaw = faces.single.headEulerAngleY;
      if (yaw == null) {
        throw const FormatException('Keep your face level and try again.');
      }
      _yawSamples.add(yaw);
      if (_step < _instructions.length - 1) {
        setState(() {
          _step += 1;
          _capturing = false;
        });
        return;
      }

      final center = _yawSamples[0].abs() <= 15;
      final movement = _yawSamples.skip(1).any((value) => value <= -12) &&
          _yawSamples.skip(1).any((value) => value >= 12);
      if (!center || !movement) {
        _yawSamples.clear();
        setState(() {
          _step = 0;
          _capturing = false;
          _error = 'Head movement was not detected. Follow all three instructions slowly.';
        });
        return;
      }

      if (mounted) {
        Navigator.of(context).pop(
          WorkerLivenessResult(
            photo: photo,
            checks: const [
              DocumentValidationCheck(
                label: 'Camera-only selfie',
                passed: true,
                message: 'Selfie was captured using the device camera.',
              ),
              DocumentValidationCheck(
                label: 'Face detected',
                passed: true,
                message: 'One clear face was detected.',
              ),
              DocumentValidationCheck(
                label: 'Movement liveness',
                passed: true,
                message: 'Required head movement was detected.',
              ),
            ],
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _capturing = false;
          _error = error is FormatException
              ? error.message
              : 'Selfie capture failed. Keep your face visible and try again.';
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Selfie liveness check')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Expanded(
                    child: controller == null
                        ? Center(child: Text(_error ?? 'Camera unavailable.'))
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: CameraPreview(controller),
                          ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    _instructions[_step],
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('Step ${_step + 1} of ${_instructions.length}'),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _capturing ? null : _captureStep,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: Text(_capturing ? 'Checking…' : 'Capture step'),
                  ),
                ],
              ),
            ),
    );
  }
}
