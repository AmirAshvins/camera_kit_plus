import 'package:flutter/material.dart';
import 'package:camera_kit_plus/camera_kit_plus.dart';

void main() {
  runApp(const MyApp());
}

/// Example host for barcode + OCR platform views.
class MyApp extends StatelessWidget {
  /// Creates the example app.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'camera_kit_plus example',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// Demo page that toggles barcode vs OCR and exposes camera controls.
class HomePage extends StatefulWidget {
  /// Creates the home page.
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final CameraKitPlusController _controller = CameraKitPlusController();
  final CameraKitPlus _plugin = CameraKitPlus();

  bool _useOcr = true;
  bool _flashOn = false;
  bool _paused = false;
  bool _macro = false;
  bool _showTextRects = false;
  String _lastEvent = 'Ready';
  String _platformVersion = '…';

  @override
  void initState() {
    super.initState();
    _loadPlatformVersion();
  }

  Future<void> _loadPlatformVersion() async {
    final version = await _plugin.getPlatformVersion() ?? 'unknown';
    if (!mounted) return;
    setState(() => _platformVersion = version);
  }

  Future<void> _toggleFlash() async {
    _flashOn = !_flashOn;
    await _controller.changeFlashMode(
      _flashOn ? CameraKitPlusFlashMode.on : CameraKitPlusFlashMode.off,
    );
    setState(() {});
  }

  Future<void> _togglePause() async {
    if (_paused) {
      await _controller.resumeCamera();
    } else {
      await _controller.pauseCamera();
    }
    setState(() => _paused = !_paused);
  }

  Future<void> _toggleMacro() async {
    _macro = !_macro;
    await _controller.setMacro(_macro);
    setState(() {});
  }

  Future<void> _takePicture() async {
    final path = await _controller.takePicture();
    setState(() => _lastEvent = 'Photo: $path');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_useOcr ? 'OCR' : 'Barcode'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _useOcr = !_useOcr),
            child: Text(_useOcr ? 'Barcode' : 'OCR'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _useOcr
                ? CameraKitOcrPlusView(
                    key: const ValueKey('ocr'),
                    controller: _controller,
                    showFrame: true,
                    showZoomSlider: true,
                    showTextRectangles: _showTextRects,
                    onTextRead: (data) {
                      if (data.text.isEmpty) return;
                      setState(() => _lastEvent = data.text);
                    },
                  )
                : CameraKitPlusView(
                    key: const ValueKey('barcode'),
                    controller: _controller,
                    showFrame: true,
                    showZoomSlider: true,
                    onBarcodeRead: (code) {
                      setState(() => _lastEvent = code);
                    },
                    onBarcodeDataRead: (data) {
                      setState(
                        () => _lastEvent = '${data.getType}: ${data.value}',
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _lastEvent,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              FilledButton(
                onPressed: _toggleFlash,
                child: Text(_flashOn ? 'Flash off' : 'Flash on'),
              ),
              FilledButton(
                onPressed: _togglePause,
                child: Text(_paused ? 'Resume' : 'Pause'),
              ),
              FilledButton(
                onPressed: _toggleMacro,
                child: Text(_macro ? 'Macro off' : 'Macro on'),
              ),
              FilledButton(
                onPressed: _takePicture,
                child: const Text('Take picture'),
              ),
              if (_useOcr)
                FilledButton(
                  onPressed: () async {
                    _showTextRects = !_showTextRects;
                    await _controller.setShowTextRectangles(_showTextRects);
                    setState(() {});
                  },
                  child: Text(_showTextRects ? 'Hide rects' : 'Show rects'),
                ),
              FilledButton(
                onPressed: () => _controller.setZoom(2),
                child: const Text('Zoom 2x'),
              ),
              FilledButton(
                onPressed: () => _controller.setZoom(1),
                child: const Text('Zoom 1x'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('Platform: $_platformVersion'),
          ),
        ],
      ),
    );
  }
}
