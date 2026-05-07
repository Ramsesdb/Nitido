import 'dart:typed_data';

import 'package:pdfx/pdfx.dart';

class PdfToImageService {
  Future<int> pageCount(Uint8List pdfBytes) async {
    final doc = await PdfDocument.openData(pdfBytes);
    try {
      return doc.pagesCount;
    } finally {
      await doc.close();
    }
  }

  Future<Uint8List> rasterizeFirstPage(
    Uint8List pdfBytes, {
    double scale = 2.0,
  }) async {
    return rasterizePage(pdfBytes, 1, scale: scale);
  }

  Future<Uint8List> rasterizePage(
    Uint8List pdfBytes,
    int pageNumber, {
    double scale = 2.0,
  }) async {
    final doc = await PdfDocument.openData(pdfBytes);
    PdfPage? page;
    try {
      page = await doc.getPage(pageNumber);
      final image = await page.render(
        width: page.width * scale,
        height: page.height * scale,
        format: PdfPageImageFormat.png,
      );
      if (image == null) {
        throw StateError('pdfx render returned null for page $pageNumber');
      }
      return image.bytes;
    } finally {
      if (page != null && !page.isClosed) {
        await page.close();
      }
      await doc.close();
    }
  }

  Future<List<Uint8List>> rasterizeAllPages(
    Uint8List pdfBytes, {
    double scale = 2.0,
    int? maxPages,
  }) async {
    final doc = await PdfDocument.openData(pdfBytes);
    try {
      final total = doc.pagesCount;
      final cap = maxPages == null || maxPages > total ? total : maxPages;
      final results = <Uint8List>[];
      for (var i = 1; i <= cap; i++) {
        PdfPage? page;
        try {
          page = await doc.getPage(i);
          final image = await page.render(
            width: page.width * scale,
            height: page.height * scale,
            format: PdfPageImageFormat.png,
          );
          if (image == null) {
            throw StateError('pdfx render returned null for page $i');
          }
          results.add(image.bytes);
        } finally {
          if (page != null && !page.isClosed) {
            await page.close();
          }
        }
      }
      return results;
    } finally {
      await doc.close();
    }
  }
}
