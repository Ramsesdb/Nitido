# Design: screenshot-import-improvements

## Enfoque técnico

Tres fases independientes sobre el flujo screenshot-import (`lib/app/accounts/statement_import/`) que comparten un mismo state object (`statement_import_flow.dart`) y commit final (`confirm.page._commit`). El cambio bootstrappea dominio `statement-import` con multi-imagen serial + dedupe in-session, centraliza fallback de categorización en una constante compartida con C19/C03, y eleva los diálogos retroactivos de `account_form.dart` para reutilizarlos en confirm. Cero migración: monta sobre `accounts.trackedSince` v24 ya entregado por `account-pre-tracking-period`.

---

## 1. Arquitectura general

```
┌──────────────┐  N imágenes   ┌────────────────┐  serial loop   ┌──────────────┐
│  capture     │──────────────▶│  flow state    │───────────────▶│  processing  │
│  (camera +   │  pivot dates  │  imageBase64s  │  i = 0..N-1    │  extractFrom │
│   picker +   │               │  pivotDates    │                │   Image()    │
│   PDF pages) │               │  failedIdx     │                │              │
└──────────────┘               └────────────────┘                └──────┬───────┘
                                       ▲                                │
                                       │ failedImageIndices             │ List<ExtractedRow>
                                       │                                ▼
                                ┌──────┴──────┐                  ┌──────────────┐
                                │   review    │◀── dedupe ───────│  in-session  │
                                │ failed-chip │  by key tuple    │   dedupe     │
                                └──────┬──────┘                  └──────────────┘
                                       │ approved                        │
                                       ▼                                 ▼
                                ┌─────────────┐                 ┌──────────────┐
                                │  confirm    │── pre-fresh? ──▶│ Retroactive  │
                                │ _commit()   │                 │ PreviewDialog│
                                └──────┬──────┘                 └──────────────┘
                                       │ accept/cancel
                                       ▼
                              statement_batches_service.commit()
```

---

## 2. Decisión: multi-imagen serial vs batched LLM

| Opción | Tradeoff | Decisión |
|--------|----------|----------|
| A — Serial loop por imagen | N round-trips (+latency); aislamiento por imagen; pivot-date per-image trivial; progreso 1-of-N visible | **Elegida** |
| B — Batched (N images in one `messages[].content`) | 1 round-trip más barato; harder to attribute failure; vendor caps (~5-10 imgs); pivot único | Diferida v1.1 si telemetría real demuestra latencia inaceptable |
| C — Hybrid (3-batches) | Balance latencia/costo | Sobre-ingeniería para v1 |

**Wiring**: `processing.page.dart` itera `for (int i = 0; i < imageBase64s.length; i++)` invocando `StatementExtractorService().extractFromImage(imageBase64s[i], pivotDates[i])` con try/catch por imagen. Resultados se acumulan en un `List<ExtractedRow> all`. Una vez completas todas las iteraciones, se aplica dedupe in-session (sección 4) y se invoca `MatchingEngine` UNA sola vez sobre la unión deduplicada.

**Progreso**: `processing.page.dart` expone `ValueNotifier<int> _currentImageIndex` que el widget consume vía `ValueListenableBuilder` para renderizar i18n `STATEMENT_IMPORT.PROCESSING.progress` ("Procesando 2 de 5"). El detalle de UI queda en spec; design solo confirma la pieza de plumbing.

---

## 3. Decisión: pivot date por imagen (EXIF + prompt fallback)

EXIF está disponible: `pubspec.yaml:97 exif: ^3.3.0` ya importado. NO se añade `native_exif`.

**Tipo nuevo** — value class inmutable en `lib/core/services/statement_import/image_pivot.dart`:

```dart
class ImagePivot {
  final String base64;
  final DateTime? exifDate;        // null si EXIF ausente o fallido
  final DateTime resolvedPivot;    // exifDate ?? userPicked ?? today
  const ImagePivot({required this.base64, this.exifDate, required this.resolvedPivot});
}
```

**Resolución** (en `capture.page.dart` antes de pasar control al flow):
1. Por cada imagen capturada/seleccionada, leer EXIF (`readExifFromBytes(imageBytes)['DateTime' or 'DateTimeOriginal']`).
2. Si la fecha existe Y es `<= now`, usarla como `resolvedPivot`. Fechas EXIF futuras se descartan (cámara con clock mal seteada).
3. Acumular indices sin EXIF; al pulsar "Continuar", si la lista no es vacía, presentar **un solo bottom sheet** listando esas imágenes por thumbnail con un date picker por fila. El usuario puede usar "hoy" para todos en bulk (botón "Todas hoy").
4. Cualquier imagen aún sin pivot tras el bottom sheet usa `today` (default conservador, comportamiento actual).
5. Cualquier pivot puede sobrescribirse desde un long-press en su thumbnail en la captura (UX detail; spec'd).

`flow state` pasa de `String? imageBase64 + DateTime? pivotDate` a `List<ImagePivot> images`. Compatibilidad con single-image queda garantizada por `images.length == 1`.

---

## 4. Decisión: dedupe in-session

**Key tuple**: `(amount, currency, dateBucket, counterpartyName)` donde:
- `amount = row.amount.abs()` (signo se ignora; ya está separado por `kind`).
- `currency = row.currency.toUpperCase()`.
- `dateBucket = row.date.millisecondsSinceEpoch ~/ (4 * 3600 * 1000)` (4-hour bucket).
- `counterpartyName = (row.counterpartyName ?? '').toLowerCase().trim()`.

**Cuándo**: DESPUÉS de completar todas las extracciones (tener el set total) y ANTES de invocar `MatchingEngine.match(...)`. Esto preserva el dedupe contra DB del MatchingEngine (separados por capa).

**Implementación** (extension method o función pura en `lib/core/services/statement_import/dedupe.dart`):
```dart
DedupeResult dedupeInSession(List<ExtractedRow> rows) {
  final map = <String, ExtractedRow>{};
  int collisions = 0;
  for (final r in rows) {
    final key = _buildKey(r);
    final existing = map[key];
    if (existing == null) {
      map[key] = r;
    } else {
      collisions++;
      if ((r.confidence ?? 0) > (existing.confidence ?? 0)) map[key] = r;
    }
  }
  return DedupeResult(rows: map.values.toList(), collisions: collisions);
}
```

`collisions` se propaga a review.page para contador opcional (i18n "N duplicados colapsados"); UX queda en spec.

---

## 5. Decisión: categorización fallback — constantes y lookup

**Archivo nuevo** `lib/core/constants/fallback_categories.dart` (la carpeta `lib/core/constants/` no existe — se crea):

```dart
const kFallbackExpenseCategoryId = 'C19'; // Otros Gastos (type "B" en seed)
const kFallbackIncomeCategoryId  = 'C03'; // Otros Ingresos (type "I" en seed)

Future<Category?> resolveFallbackCategory(
  TransactionType type,
  List<Category> userCategories,
) async {
  final wantedId = type == TransactionType.income
      ? kFallbackIncomeCategoryId
      : kFallbackExpenseCategoryId;

  // Filtro por tipo: para expense aceptamos "E" y "B"; para income "I" y "B".
  final filtered = userCategories.where((c) =>
      type == TransactionType.income
          ? (c.type == 'I' || c.type == 'B')
          : (c.type == 'E' || c.type == 'B')
  ).toList();

  // 1) lookup por ID dentro del filtrado.
  final byId = filtered.where((c) => c.id == wantedId).toList();
  if (byId.isNotEmpty) return byId.first;

  // 2) last-resort: primera categoría del filtrado, o null si no hay ninguna.
  return filtered.isNotEmpty ? filtered.first : null;
}
```

**Riesgo confirmado** (verificado contra `assets/sql/initial_categories.json:545-548`): C19 tiene `type: "B"`. Por eso el filtro acepta `"B"` para queries de expense. Si esto no se respetara, `C19` quedaría invisible al fallback de gasto y caería en `.first` (volviendo a "Alimentación").

**Prompt** — append literal al final del prompt actual en `auto_categorization_service.dart:47-70`:

```
Si no estás 100% seguro de la categoría, devuelve "C19" para gastos o "C03" para ingresos. Es preferible una clasificación neutral a una incorrecta.
```

**Threshold** — el servicio NO tiene threshold hoy (descubierto en exploration). Se introduce `const _kMinConfidence = 0.55` top-level en `auto_categorization_service.dart`. Lectura: por debajo del threshold se descarta `proposedCategoryId` y los call sites caen en `resolveFallbackCategory`. Justificación de 0.55: balance entre precision/recall observado al mirar logs informales; seguro por encima del piso aleatorio (~0.3 con ~20 categorías) y bajo el "alta confidence" típico (~0.7+). Tunable en v1.1.

---

## 6. Decisión: lift de diálogos retroactivos

**Mover** `RetroactivePreviewDialog` y `RetroactiveStrongConfirmDialog` desde `lib/app/accounts/account_form.dart` a `lib/core/presentation/widgets/retroactive_preview_dialog.dart` (carpeta destino existe; archivo nuevo).

**Call sites tras el lift**:
- `account_form.dart` (existente, usado por edición manual de `trackedSince`).
- `confirm.page.dart` (NUEVO uso para pre-fresh auto-adjust).

**Riesgo y mitigación**: el lift toca código ya enviado (account-pre-tracking-period). Es **puro move + import-update**, sin cambios de comportamiento ni firma. El PR de este change DEBE mergear DESPUÉS de que `account-pre-tracking-period` quede archivada (state.yaml: smoke-test cerrado).

**Hook en `confirm.page.dart`**:

```dart
/// Returns true si el commit debe proceder (no pre-fresh, o usuario aceptó,
/// o usuario canceló — las filas pre-fresh quedan ocultas pero se persisten).
/// Returns false solo si el flujo del diálogo errorea (e.g. preview stream falla).
Future<bool> _handlePreFresh(Account account, List<MatchedRow> approved) async {
  if (account.trackedSince == null) return true;
  final preFresh = approved.where((r) => r.row.date.isBefore(account.trackedSince!));
  if (preFresh.isEmpty) return true;

  final proposed = preFresh.map((r) => r.row.date).reduce((a, b) => a.isBefore(b) ? a : b);
  final proposedTruncated = DateTime(proposed.year, proposed.month, proposed.day);

  final currentBalance = await accountService.getAccountsMoney(...).first;
  final simulated = await accountService
      .getAccountsMoneyPreview(accountId: account.id, simulatedTrackedSince: proposedTruncated)
      .first;

  final accepted = await showRetroactiveDialog(
    context: context, current: currentBalance, simulated: simulated,
    proposedTrackedSince: proposedTruncated,
  );
  if (accepted == true) {
    await accountService.updateAccount(account.copyWith(trackedSince: proposedTruncated));
    flow.refreshAccount();
  }
  return true; // commit procede en ambos casos (accept = visible, cancel = histórico)
}
```

`showRetroactiveDialog` internamente decide preview vs strong-confirm con la regla establecida en `account-pre-tracking-period` (shift > 50% OR simulated < 0).

---

## 7. Decisión: contrato de aislamiento de fallos

`processing.page.dart` mantiene:
```dart
final List<int> failedImageIndices = [];
for (int i = 0; i < imageBase64s.length; i++) {
  try {
    final rows = await extractor.extractFromImage(imageBase64s[i], pivotDates[i]);
    accumulated.addAll(rows);
  } catch (e, st) {
    failedImageIndices.add(i);
    log.warn('image $i failed: $e');
  }
}
```

**Reglas**:
- `failedImageIndices.length == imageBase64s.length` → processing.page muestra error global ("ninguna imagen extrajo movimientos") con botones Reintentar/Cancelar; **no avanza** a review.
- En cualquier otro caso, navega a review pasando `failedImageIndices` en el payload.
- review.page renderiza un `Wrap` de chips i18n `STATEMENT_IMPORT.REVIEW.image-failed` ("Imagen N: no extrajo movs"). Cada chip es dismissible (solo oculta el chip; no afecta filas).

---

## 8. Feature flags

**Archivo** `lib/core/constants/feature_flags.dart` (NO existe; se crea junto con `fallback_categories.dart`):

```dart
const kEnableMultiImageImport = false;     // flip a true tras smoke test multi-imagen
const kEnablePreFreshAutoAdjust = true;    // bajo riesgo: reusa diálogo ya probado
// Categorización fallback: SIN flag (fix derecho).
```

`capture.page.dart` lee `kEnableMultiImageImport`: si es `false`, mantiene comportamiento single-image (un sólo `pickImage`/`pickFiles` sin `allowMultiple`). `confirm.page.dart` lee `kEnablePreFreshAutoAdjust` para decidir si invocar `_handlePreFresh`.

---

## 9. Migraciones / data

| Item | Estado |
|------|--------|
| Drift schema | Sigue en v24 (sin cambios) |
| `accounts.trackedSince` | Ya existe (v24, account-pre-tracking-period) |
| Categorías C19, C03 | Ya seeded en `initial_categories.json` (verificado: líneas 51, 545) |
| Tablas nuevas | Ninguna |

---

## 10. Performance / token budget

| Métrica | Estimación | Nota |
|---------|-----------|------|
| LLM calls por sesión worst-case | 10 | cap fijo de imágenes |
| Tokens por imagen multimodal | ~2-4k | image_url base64 1600px ≈ 800-1500 tok + prompt fijo |
| Costo por sesión (10 imgs, Haiku 4.5) | $0.05-0.20 | aceptable; sin telemetría aún |
| Latencia serial (10 imgs) | 30-80s | mitigado por progress UI; paralelismo cap=2 reservado para v1.1 |

Sin cambios al budget si flag multi-image está apagada (comportamiento single-image idéntico al actual).

---

## 11. Plan de testing

| Capa | Qué probar | Enfoque |
|------|-----------|---------|
| Unit | Dedupe key tuple (4h bucket, casos límite a 3:59h vs 4:01h) | función pura `dedupeInSession` |
| Unit | `resolveFallbackCategory` (C19 presente, C19 borrado, lista vacía, type="B" filter) | mocks de `Category` |
| Unit | Pre-fresh threshold (>50% shift, balance negativo) | helpers puros de cálculo |
| Widget | Capture multi-select (3 fotos) cuenta correctamente | `WidgetTester` |
| Widget | Processing renderiza "Procesando N de M" | `ValueNotifier` mock |
| Widget | Review chip "Imagen N falló" presente cuando `failedImageIndices` no vacío | render snapshot |
| Widget | Confirm muestra `RetroactivePreviewDialog` cuando hay pre-fresh | mock `accountService` |
| Integration | Flow completo 3 imágenes (1 falla) → review → confirm con pre-fresh aceptado | in-memory DB |
| Integration | Flow completo 3 imágenes → cancel pre-fresh → filas insertadas como histórico | in-memory DB |

Patrones existentes en `test/auto_import/` (~149 tests). Estimado: +15-20 tests nuevos.

---

## 12. Rollback

| Escenario | Acción |
|-----------|--------|
| Bug en multi-imagen post-deploy | `kEnableMultiImageImport = false` → captura vuelve a single |
| Bug en pre-fresh auto-adjust | `kEnablePreFreshAutoAdjust = false` → confirm salta el diálogo |
| Bug en categorización fallback | revertir commit del archivo `fallback_categories.dart` y los 2 call sites; sin flag |
| Rollback total | revertir commits en orden inverso (fase 3 → 2 → 1); sin migración Drift que revertir; `accounts.trackedSince` queda intacto (válido bajo el modelo previo) |

---

## Preguntas abiertas

- [ ] Threshold `0.55` se confirma con sample manual de 30 transacciones reales antes de mergear; tunable a `0.50` o `0.60` sin cambios estructurales.
- [ ] Cap fijo de 10 imágenes — revisar tras smoke test si usuarios reales suben PDFs de >10 páginas con frecuencia (mover a constante `kMaxImagesPerSession` para futuro hot-fix).
- [ ] `package:exif` — verificar en smoke test que la lectura funciona sin errores en imágenes que pasan por `image_picker` (algunas plataformas strippean EXIF en el thumbnail). Si falla, fallback a "preguntar usuario" sin auto-detect.
