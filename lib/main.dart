import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart' hide Image;
import 'package:flutter/scheduler.dart';
import 'package:image/image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite/tflite.dart';
import 'package:uuid/uuid.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gesture Recognizer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Gesture Recognizer'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

extension MappedList<T> on List<T> {
  double minMapped(Function mapper) {
    return map((e) => mapper(e))
        .reduce((prev, element) => element < prev ? element : prev);
  }

  double maxMapped(Function mapper) {
    return map((e) => mapper(e))
        .reduce((prev, element) => element > prev ? element : prev);
  }
}

class _MyHomePageState extends State<MyHomePage> {
  Map<int, List<Offset>> positions = {};
  Rect? boundaries;
  Set<int> fingers = {};
  String? gesture;

  @override
  void initState() {
    super.initState();
    Tflite.loadModel(
        model: "assets/model_unquant.tflite", labels: "assets/labels.txt");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, constraints) => Listener(
              onPointerDown: (p) {
                positions[p.pointer] = [];
                fingers.add(p.pointer);
              },
              onPointerUp: (p) {
                fingers.remove(p.pointer);
                if (fingers.isEmpty) {
                  //gesture finished
                  double? minX, minY, maxX, maxY;
                  positions.forEach((finger, points) {
                    final fMinX = points.minMapped((point) => point.dx);
                    final fMinY = points.minMapped((point) => point.dy);
                    final fMaxX = points.maxMapped((point) => point.dx);
                    final fMaxY = points.maxMapped((point) => point.dy);
                    minX = min(fMinX, minX ?? fMinX);
                    minY = min(fMinY, minY ?? fMinY);
                    maxX = max(fMaxX, maxX ?? fMaxX);
                    maxY = max(fMaxY, maxY ?? fMaxY);
                  });

                  var maxSize = max(maxX! - minX!, maxY! - minY!);
                  if (maxSize % 2 == 1) maxSize++;

                  final centerX = (minX! + maxX!) ~/ 2;
                  final centerY = (minY! + maxY!) ~/ 2;
                  boundaries =
                      Offset(centerX - maxSize / 2, centerY - maxSize / 2) &
                          Size(maxSize, maxSize);
                  setState(() {});

                  final pictureRecorder = PictureRecorder();
                  final canvas = Canvas(pictureRecorder);
                  final size = constraints.biggest;
                  TrackPainter(positions, boundaries, visual: false)
                      .paint(canvas, size);
                  final img = pictureRecorder.endRecording();
                  SchedulerBinding.instance!
                      .addPostFrameCallback((timeStamp) async {
                    final image = await img.toImage(
                        size.width.toInt(), size.height.toInt());
                    final bytes = await image.toByteData();

                    List<int> cropped = [];
                    for (int y = centerY - maxSize ~/ 2;
                        y < centerY + maxSize ~/ 2;
                        y++) {
                      for (int x = centerX - maxSize ~/ 2;
                          x < centerX + maxSize ~/ 2;
                          x++) {
                        cropped.add(
                            bytes!.getUint8((y * size.width.toInt() + x) * 4));
                      }
                    }

                    Image cropImage = Image.fromBytes(
                        maxSize.toInt(), maxSize.toInt(), cropped,
                        format: Format.luminance);
                    Image prepared =
                        copyResize(cropImage, width: 224, height: 224);
                    final uuid = const Uuid().v4();
                    final path =
                        (await getApplicationDocumentsDirectory()).path +
                            "/$uuid.png";
                    final file = File(path);
                    await file.writeAsBytes(encodePng(prepared));

                    final result = await Tflite.runModelOnImage(path: path);
                    final label = result?.first["label"];
                    gesture = label.substring(label.indexOf(" ") + 1);
                    setState(() {});
                    Future.delayed(const Duration(seconds: 3), () {
                      positions = {};
                      boundaries = null;
                      gesture = null;
                      setState(() {});
                    });
                  });
                }
              },
              onPointerMove: (p) {
                bool skip = false;
                if (positions[p.pointer]!.isNotEmpty) {
                  var last = positions[p.pointer]!.last;
                  if ((last - p.localPosition).distance < 10) skip = true;
                }
                if (!skip) {
                  positions[p.pointer]!.add(p.localPosition);
                  setState(() {});
                }
              },
              child: Stack(children: [
                Container(color: Colors.blueGrey),
                CustomPaint(
                  painter: TrackPainter(positions, boundaries, visual: true),
                ),
              ]),
            ),
          ),
          if (gesture != null)
            Center(
              child: Text("Detected Gesture: ${gesture!}",
                  style: const TextStyle(fontSize: 32, color: Colors.white)),
            ),
        ],
      ),
    );
  }
}

class TrackPainter extends CustomPainter {
  Map<int, List<Offset>> positions;

  Rect? boundaries;

  bool visual;

  TrackPainter(this.positions, this.boundaries, {required this.visual});

  @override
  void paint(Canvas canvas, Size size) {
    Paint track;
    if (visual) {
      track = Paint()
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3)
        ..isAntiAlias = true
        ..color = Colors.white
        ..strokeWidth = 4;
    } else {
      track = Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white
        ..isAntiAlias = false
        ..strokeWidth = 1;
    }
    positions.forEach((fingers, points) {
      Offset? position;
      for (var pos in points) {
        if (position != null) {
          canvas.drawLine(position, pos, track);
        }
        position = pos;
      }
    });

    final boundaryPaint = Paint()
      ..color = Colors.grey
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    if (boundaries != null) {
      canvas.drawRect(boundaries!, boundaryPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
