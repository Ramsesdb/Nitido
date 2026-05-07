# Proposal: screenshot-import-improvements

## Why

Hoy el flujo "subir foto del estado de cuenta" tiene tres dolores reales del usuario: solo acepta una imagen por sesión (no puedo subir varias capturas del mismo PDF), todo lo que el LLM no sabe categorizar cae en "Alimentación" (todo cae en alimentación), y los movimientos previos a `trackedSince` se insertan pero quedan invisibles en la cuenta (movs viejos no aparecen). Este change agrupa los tres fixes porque comparten la misma sesión de import y se construyen sobre la infraestructura ya entregada por `account-pre-tracking-period`.

## What Changes

### 1. Multi-image import

- [ ] `capture.page.dart:25-57` — `_onTakePhoto`: loop hasta 10 imágenes (cámara) acumulando en `List<String> imageBase64s`; mostrar contador "N imágenes".
- [ ] `capture.page.dart:59-85` — `_onPickFile`: `FilePicker.pickFiles(allowMultiple: true)` y consumir `result.files` (no `.single`); cap a 10.
- [ ] `capture.page.dart:103-145` — `_handlePdf`: rasterizar todas las páginas (no solo `rasterizeFirstPage`) hasta el cap.
- [ ] `statement_import_flow.dart:31-32, 51-66` — cambiar estado `String? imageBase64` → `List<String> imageBase64s`; `goToProcessing` recibe lista + `List<DateTime?> pivotDates` (uno por imagen).
- [ ] `processing.page.dart:64-108` — loop serial sobre `extractFromImage` (Approach A de exploration.md), concatenar `List<ExtractedRow>`, dedupe in-session por `(amount, currency, date±4h, counterpartyName)` antes de MatchingEngine. Progreso "procesando 2 de 5". Si una imagen falla, continuar con el resto y reportar el fallo en review.
- [ ] `review.page.dart` — chip de error por imagen N que no extrajo (lista de `failedImageIndices` propagada desde processing).
- [ ] i18n: `STATEMENT_IMPORT.CAPTURE.multi-count`, `STATEMENT_IMPORT.PROCESSING.progress`, `STATEMENT_IMPORT.REVIEW.image-failed`.

### 2. Categorization fallback

- [ ] Nuevo `lib/core/constants/fallback_categories.dart` con `kFallbackExpenseCategoryId = 'C19'` y `kFallbackIncomeCategoryId = 'C03'` (existen en `assets/sql/initial_categories.json:38-54, 532-548`).
- [ ] `proposal_review.page.dart:939-963` — `_resolveFallbackCategoryForType` busca por ID `C19`/`C03` primero; `.first` solo como último recurso (si usuario borró la categoría seed).
- [ ] `confirm.page.dart:29-37` — `_resolveCategoryForKind` mismo cambio (mismo bug, segundo sitio).
- [ ] `auto_categorization_service.dart:47-70` — actualizar prompt: incluir literal "si no estás seguro, devuelve `categoryId: C19` (gasto) o `C03` (ingreso)"; mantener el threshold de confianza existente (no nuevo campo). Defense in depth: prompt + fallback constante.
- [ ] i18n: ninguna nueva (las categorías ya tienen nombre i18n via seed).

### 3. Pre-fresh auto-adjust

- [ ] `confirm.page.dart:39-112` — antes de `_commit()`, si hay `approved.where((r) => r.isPreFresh).isNotEmpty` y `account.trackedSince != null`:
  1. computar `proposedTrackedSince = min(preFreshRows.map(date))` truncado a fecha.
  2. `getAccountsMoneyPreview(accountId, simulatedTrackedSince).first` para balance hipotético.
  3. mostrar `RetroactivePreviewDialog` (reutilizar el ya existente de `account_form.dart`); si diff > 50% o balance < 0, escalar a `RetroactiveStrongConfirmDialog` (mismo trigger ya usado por `account-pre-tracking-period`).
  4. en Aceptar: `accountService.updateAccount(account.copyWith(trackedSince: proposedTrackedSince))`, luego `flow.refreshAccount()`, luego seguir con commit.
  5. en Cancelar: commit normal, filas quedan pre-fresh (usuario eligió).
- [ ] Lift `RetroactivePreviewDialog` y `RetroactiveStrongConfirmDialog` desde `account_form.dart` a `lib/core/presentation/widgets/retroactive_preview_dialog.dart` para evitar drift entre las dos superficies.
- [ ] i18n: `STATEMENT_IMPORT.PRE_FRESH.auto-adjust-title`, `STATEMENT_IMPORT.PRE_FRESH.auto-adjust-body`.

## Impact

| Área | Tipo | Archivos clave |
|------|------|----------------|
| UI capture | Modificado | `app/accounts/statement_import/screens/capture.page.dart:25-145` |
| Flow state | Modificado | `app/accounts/statement_import/statement_import_flow.dart:31-66` |
| Extractor pipeline (loop+dedupe) | Modificado | `app/accounts/statement_import/screens/processing.page.dart:64-108` |
| Review screen | Modificado | `app/accounts/statement_import/screens/review.page.dart` (badge errores por imagen) |
| Confirm/commit | Modificado | `app/accounts/statement_import/screens/confirm.page.dart:29-112` |
| AI categorization | Modificado | `core/services/ai/auto_categorization_service.dart:47-70` (prompt) |
| Auto-import review fallback | Modificado | `app/transactions/auto_import/proposal_review.page.dart:939-963` |
| Constantes fallback | Nuevo | `core/constants/fallback_categories.dart` |
| Diálogos retroactivos | Movido | `account_form.dart` → `core/presentation/widgets/retroactive_preview_dialog.dart` |
| Account service hook | Reutilizado | `core/database/services/account/account_service.dart:29-33, 314-389` (sin cambios) |
| i18n | Modificado | `lib/i18n/json/es.json`, `en.json` (claves listadas arriba) |

**Drift migration**: ninguna. Reutiliza `accounts.trackedSince` (v24, ya entregada por `account-pre-tracking-period`).

**Breaking changes**: ninguno. `imageBase64s` con un solo elemento es comportamiento idéntico al `imageBase64` actual; las constantes `C19`/`C03` con `.first` como último recurso preservan el comportamiento si se borra el seed.

## Out of Scope

- Telemetría de confidence/categorización (se pospone a v1.1).
- Llamada batched-LLM (una sola petición con N imágenes) — se queda en serial Approach A; batching es optimización futura tras medir latencia real.
- Cambios a parsers dedicados por banco (Zinli, Mercantil, etc.) — solo tocamos el flujo screenshot/statement.
- Detección de transferencias en filas extraídas (sigue siendo income/expense/fee).
- Sync Firebase del nuevo `trackedSince` ajustado (igual que en `account-pre-tracking-period`).
- Toggle stats para incluir/excluir filas pre-fresh.

## Open Questions

1. **Cap de imágenes por sesión**: 10 (recomendado) vs configurable por usuario. Diferir a `/sdd-design`.
2. **Pivot date por imagen**: confirmar Approach (b) — EXIF auto-detect + prompt solo para faltantes — en `/sdd-design`.
3. **Threshold de confianza** para descartar la sugerencia LLM y caer en C19/C03: ¿0.6 hardcoded o ya existe constante en `auto_categorization_service`? Resolver en `/sdd-spec`.

## Rollback Plan

1. Feature flag por fase: `kEnableMultiImageImport`, `kEnablePreFreshAutoAdjust` en `core/constants/feature_flags.dart` permiten apagar fases 1 y 3 sin revertir código.
2. Si rollback total: revertir commits en orden inverso (fase 3 → 2 → 1). Datos quedan intactos — `imageBase64s.first` sigue funcionando, las categorías C19/C03 ya están seedeadas, y `trackedSince` ya ajustado en cuentas no se revierte (es válido bajo el modelo previo).
3. Sin migración Drift que revertir (riding sobre v24 existente).
