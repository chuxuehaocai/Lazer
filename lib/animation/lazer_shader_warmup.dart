import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Compile the mesh, artwork clipping and lyric blur paths before the first
/// interactive frame, rather than on the first opening of the player.
class LazerShaderWarmUp extends ShaderWarmUp {
  const LazerShaderWarmUp();

  @override
  ui.Size get size => const ui.Size(256, 256);

  @override
  Future<void> warmUpOnCanvas(ui.Canvas canvas) async {
    const bounds = ui.Rect.fromLTWH(0, 0, 256, 256);
    final gradient = ui.Gradient.linear(
      const ui.Offset(0, 0),
      const ui.Offset(256, 256),
      const [ui.Color(0xFF254C65), ui.Color(0xFF942F54)],
    );
    canvas.drawRect(bounds, ui.Paint()..shader = gradient);
    final mesh = ui.Vertices(
      ui.VertexMode.triangles,
      const [ui.Offset(0, 0), ui.Offset(256, 0), ui.Offset(0, 256)],
      colors: const [
        ui.Color(0xFF385F72),
        ui.Color(0xFF64385F),
        ui.Color(0xFF85845A),
      ],
    );
    canvas.drawVertices(mesh, ui.BlendMode.srcOver, ui.Paint());
    mesh.dispose();
    canvas.save();
    canvas.clipRRect(
      ui.RRect.fromRectAndRadius(
        bounds.deflate(24),
        const ui.Radius.circular(12),
      ),
    );
    canvas.drawRect(bounds, ui.Paint()..shader = gradient);
    canvas.restore();
    final paragraph =
        (ui.ParagraphBuilder(
                ui.ParagraphStyle(fontFamily: 'MiSans', fontSize: 24),
              )
              ..pushStyle(
                ui.TextStyle(
                  color: const ui.Color(0xFFFFFFFF),
                  fontWeight: ui.FontWeight.w600,
                ),
              )
              ..addText('Lazer 音乐 歌词'))
            .build()
          ..layout(const ui.ParagraphConstraints(width: 240));
    for (final sigma in [1.0, 3.0, 5.0]) {
      canvas.saveLayer(
        bounds,
        ui.Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
      canvas.drawParagraph(paragraph, const ui.Offset(8, 64));
      canvas.restore();
    }
    canvas.drawParagraph(paragraph, const ui.Offset(8, 128));
    paragraph.dispose();
    gradient.dispose();
  }
}
