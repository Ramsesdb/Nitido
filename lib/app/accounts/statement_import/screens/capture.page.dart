import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:nitido/app/accounts/statement_import/statement_import_flow.dart';
import 'package:nitido/app/accounts/statement_import/widgets/missing_pivot_sheet.dart';
import 'package:nitido/core/constants/feature_flags.dart';
import 'package:nitido/core/presentation/helpers/snackbar.dart';
import 'package:nitido/core/services/statement_import/image_pivot.dart';
import 'package:nitido/core/services/statement_import/pdf_to_image_service.dart';
import 'package:nitido/i18n/generated/translations.g.dart';

const int kMaxImagesPerSession = 10;

class CapturePage extends StatefulWidget {
  const CapturePage({super.key});

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  bool _busy = false;
  final List<ImagePivot> _images = [];

  bool get _multiEnabled => kEnableMultiImageImport;
  bool get _capReached => _images.length >= kMaxImagesPerSession;
  int get _remaining => kMaxImagesPerSession - _images.length;

  Future<void> _onTakePhoto() async {
    if (_busy || _capReached) return;
    setState(() => _busy = true);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        imageQuality: 82,
      );
      if (picked == null) return;

      final bytes = await File(picked.path).readAsBytes();
      await _ingestImageBytes(bytes);

      if (!_multiEnabled) {
        if (!mounted) return;
        await _continueIfReady();
      }
    } catch (e, st) {
      debugPrint('CapturePage.takePhoto failed: $e\n$st');
      _showReadError();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onPickFile() async {
    if (_busy || _capReached) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
        withData: true,
        allowMultiple: _multiEnabled,
      );
      if (result == null || result.files.isEmpty) return;

      for (final file in result.files) {
        if (_capReached) {
          _showCapReached();
          break;
        }
        final bytes =
            file.bytes ?? await File(file.path!).readAsBytes();
        final ext = (file.extension ?? '').toLowerCase();
        if (ext == 'pdf') {
          await _handlePdf(bytes);
        } else {
          await _ingestImageBytes(bytes);
        }
        if (!_multiEnabled) break;
      }

      if (!_multiEnabled) {
        if (!mounted) return;
        await _continueIfReady();
      }
    } catch (e, st) {
      debugPrint('CapturePage.pickFile failed: $e\n$st');
      _showReadError();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ingestImageBytes(Uint8List bytes) async {
    if (_capReached) {
      _showCapReached();
      return;
    }
    final exifDate = await readExifDateFromBytes(bytes);
    final resized = _resizeIfNeeded(bytes);
    final base64 = base64Encode(resized);
    final pivot = ImagePivot(
      base64: base64,
      exifDate: exifDate,
      resolvedPivot: exifDate ?? DateTime.now(),
    );
    setState(() => _images.add(pivot));
  }

  Future<void> _handlePdf(Uint8List bytes) async {
    final service = PdfToImageService();
    final pages = await service.pageCount(bytes);

    if (!_multiEnabled) {
      if (pages > 1) {
        if (!mounted) return;
        final t = Translations.of(context);
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(t.statement_import.capture.pdf_warning_title),
            content: Text(
              t.statement_import.capture.pdf_warning_body(pages: pages),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.ui_actions.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.statement_import.capture.pdf_warning_continue),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
      final raster = await service.rasterizeFirstPage(bytes);
      await _ingestImageBytes(raster);
      return;
    }

    final cap = _remaining;
    if (cap <= 0) {
      _showCapReached();
      return;
    }
    if (pages > cap) {
      if (!mounted) return;
      _showCapReached();
    }
    final pageImages = await service.rasterizeAllPages(
      bytes,
      maxPages: cap,
    );
    for (final raster in pageImages) {
      if (_capReached) break;
      await _ingestImageBytes(raster);
    }
  }

  Uint8List _resizeIfNeeded(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;

      final maxDim = decoded.width > decoded.height
          ? decoded.width
          : decoded.height;
      if (maxDim <= 1600) return bytes;

      final resized = img.copyResize(
        decoded,
        width: decoded.width >= decoded.height ? 1600 : null,
        height: decoded.height > decoded.width ? 1600 : null,
        interpolation: img.Interpolation.cubic,
      );
      return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
    } catch (e) {
      debugPrint('CapturePage.resize failed: $e');
      return bytes;
    }
  }

  void _showReadError() {
    final t = Translations.of(context);
    NitidoSnackbar.error(
      SnackbarParams(t.statement_import.capture.error_read),
    );
  }

  void _showCapReached() {
    final t = Translations.of(context);
    NitidoSnackbar.info(
      SnackbarParams(
        t.statement_import.capture.cap_reached(max: kMaxImagesPerSession),
      ),
    );
  }

  void _removeImage(int index) {
    setState(() => _images.removeAt(index));
  }

  Future<void> _continueIfReady() async {
    if (_images.isEmpty) return;
    final resolved = await promptMissingPivots(context, _images);
    if (resolved == null) return;
    if (!mounted) return;
    StatementImportFlow.of(context).goToProcessing(images: resolved);
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(t.statement_import.title)),
      body: AbsorbPointer(
        absorbing: _busy,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeroDocument(),
              const SizedBox(height: 20),
              Text(
                t.statement_import.title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                t.statement_import.subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              _PrivacyBadge(),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy || _capReached ? null : _onTakePhoto,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.camera_alt_outlined),
                label: Text(t.statement_import.capture.cta_camera),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy || _capReached ? null : _onPickFile,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(t.statement_import.capture.cta_file),
              ),
              if (_multiEnabled && _images.isNotEmpty) ...[
                const SizedBox(height: 16),
                _MultiCounter(count: _images.length),
                const SizedBox(height: 10),
                _ImageStrip(
                  images: _images,
                  onRemove: _removeImage,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _continueIfReady,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: Text(
                    t.statement_import.capture.continue_cta(
                      n: _images.length,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Funciona mejor con documentos de bancos venezolanos (BDV, Mercantil, Provincial, Banesco). Podrás revisar y editar cada fila antes de importar.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MultiCounter extends StatelessWidget {
  const _MultiCounter({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.collections_outlined, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            t.statement_import.capture.multi_count(n: count),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageStrip extends StatelessWidget {
  const _ImageStrip({required this.images, required this.onRemove});

  final List<ImagePivot> images;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, idx) {
          final img = images[idx];
          Uint8List? bytes;
          try {
            bytes = base64Decode(img.base64);
          } catch (_) {
            bytes = null;
          }
          return Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: bytes == null
                    ? Container(
                        width: 84,
                        height: 84,
                        color: cs.surfaceContainer,
                        child: const Icon(
                          Icons.image_not_supported_outlined,
                          size: 18,
                        ),
                      )
                    : Image.memory(
                        bytes,
                        width: 84,
                        height: 84,
                        fit: BoxFit.cover,
                      ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: Material(
                  color: cs.surface,
                  shape: const CircleBorder(),
                  elevation: 2,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => onRemove(idx),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 14, color: cs.onSurface),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HeroDocument extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 170,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Center(
        child: Icon(Icons.description_outlined, size: 96, color: cs.primary),
      ),
    );
  }
}

class _PrivacyBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.shield_outlined, size: 14, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          t.statement_import.ai_badge,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
