# Tasks: screenshot-import-improvements

> **Phase ordering**: Phase 0 must complete before Phase 1. Phases 1, 2, and 3 are independent and may interleave once Phase 0 lands. Phase 4 (verification) runs last.

## Phase 0 — Prep / shared utilities

- [x] 0.1 Create `lib/core/constants/feature_flags.dart` (new file per design §8) with `const kEnableMultiImageImport = false;` and `const kEnablePreFreshAutoAdjust = true;`.
- [x] 0.2 Create `lib/core/constants/fallback_categories.dart` with `kFallbackExpenseCategoryId = 'C19'`, `kFallbackIncomeCategoryId = 'C03'`, and `resolveFallbackCategory(TransactionType, List<Category>)` helper (per design §5; type filter must accept `"B"` for expense queries).
- [x] 0.3 Lift `RetroactivePreviewDialog` and `RetroactiveStrongConfirmDialog` from `lib/app/accounts/account_form.dart` to new `lib/core/presentation/widgets/retroactive_preview_dialog.dart` (pure move; no behavior change). Update import in `account_form.dart`.
- [x] 0.4 Add unit tests for `resolveFallbackCategory` in `test/core/constants/fallback_categories_test.dart` covering: C19 found, C19 deleted → `.first`, type `"B"` accepted for expense, empty list → null.

## Phase 1 — Multi-image import

- [x] 1.1 Add `ImagePivot` value class in new file `lib/core/services/statement_import/image_pivot.dart` (per design §3): fields `base64`, `exifDate?`, `resolvedPivot`.
- [x] 1.2 Update `lib/app/accounts/statement_import/statement_import_flow.dart:31-66`: replace `String? imageBase64` with `List<ImagePivot> images`; update `goToProcessing` signature; add `List<int> failedImageIndices`.
- [x] 1.3 Update `lib/app/accounts/statement_import/screens/capture.page.dart:25-145`:
   - [x] 1.3a `_onTakePhoto` (lines 25-57): loop accumulating into `List<ImagePivot>` capped at 10; render counter UI (`STATEMENT_IMPORT.CAPTURE.multi-count`).
   - [x] 1.3b `_onPickFile` (lines 59-85): use `FilePicker.pickFiles(allowMultiple: true)` and consume `result.files`; cap at 10.
   - [x] 1.3c `_handlePdf` (lines 103-145): rasterize all PDF pages (replace `rasterizeFirstPage`); each page counts against the 10 cap.
- [x] 1.4 Add EXIF detection helper `Future<DateTime?> readExifDate(String base64)` in `image_pivot.dart` using `package:exif` (already in `pubspec.yaml:97`); discard EXIF dates `> now`.
- [x] 1.5 Add bottom-sheet UI `lib/app/accounts/statement_import/widgets/missing_pivot_sheet.dart` to prompt for pivot dates of images missing EXIF: thumbnail + per-image date picker + "Todas hoy" bulk action (per design §3 step 3).
- [x] 1.6 Update `lib/app/accounts/statement_import/screens/processing.page.dart:64-108`: serial `for` loop over `images`, try/catch per image, accumulate `List<ExtractedRow>`, expose `ValueNotifier<int> _currentImageIndex` for progress UI (`STATEMENT_IMPORT.PROCESSING.progress`); apply dedupe before invoking `MatchingEngine` once.
- [x] 1.7 Add dedupe helper `dedupeInSession(List<ExtractedRow>)` in new file `lib/core/services/statement_import/dedupe_in_session.dart` using key `(amount.abs, currency.upper, floor(ms/4h), counterpartyName.lowerTrim)`; return `DedupeResult(rows, collisions)` per design §4.
- [x] 1.8 Update `lib/app/accounts/statement_import/screens/review.page.dart` to render dismissible chips for `failedImageIndices` (i18n `STATEMENT_IMPORT.REVIEW.image-failed`).
- [x] 1.9 In `processing.page.dart`, add global error screen branch when `failedImageIndices.length == images.length` (no rows extracted): show retry/cancel buttons, do NOT navigate to review (per design §7).
- [x] 1.10 Add i18n keys to `lib/i18n/json/es.json` and `lib/i18n/json/en.json`: `STATEMENT_IMPORT.CAPTURE.multi-count`, `STATEMENT_IMPORT.PROCESSING.progress`, `STATEMENT_IMPORT.REVIEW.image-failed`, `STATEMENT_IMPORT.PROCESSING.all-failed`. Run `dart run slang` to regenerate `translations.g.dart`.
- [x] 1.11 Tests:
   - [x] 1.11a Unit: dedupe key tuple boundary cases (3:59h vs 4:01h, signo, currency case) in `test/statement_import/dedupe_in_session_test.dart`.
   - [x] 1.11b Widget: capture multi-select counter renders "3 imágenes" after 3 picks.
   - [x] 1.11c Widget: processing renders "Procesando 2 de 5" via `ValueListenableBuilder` mock.
   - [ ] 1.11d Integration: 3 images, 1 fails → review shows 1 chip, other 2 batches commit. **DEFERRED** — full-flow integration requires mocking extractor + MatchingEngine + Drift DB; cost outweighs benefit relative to 1.11a-c which already cover the chip render path and the dedupe semantics. To revisit in Phase 4 smoke testing.

## Phase 2 — Categorization fallback

- [x] 2.1 Wire `resolveFallbackCategory` in `lib/app/transactions/auto_import/proposal_review.page.dart:939-963` (replace existing `.first` logic in `_resolveFallbackCategoryForType`).
- [x] 2.2 Wire `resolveFallbackCategory` in `lib/app/accounts/statement_import/screens/confirm.page.dart:29-37` (`_resolveCategoryForKind`; same fix, second call site).
- [x] 2.3 Add top-level `const _kMinConfidence = 0.55;` to `lib/core/services/ai/auto_categorization_service.dart`; gate suggestion return so confidence below threshold yields null (call sites then fall to `resolveFallbackCategory`).
- [x] 2.4 Update LLM prompt in `auto_categorization_service.dart:47-70` to append literal: "Si no estás 100% seguro de la categoría, devuelve `C19` para gastos o `C03` para ingresos. Es preferible una clasificación neutral a una incorrecta."
- [x] 2.5 Tests:
   - [x] 2.5a Update existing categorization tests under `test/auto_import/` to assert C19/C03 path when fallback fires.
   - [x] 2.5b Add test: confidence `0.40` returns `null` from service → call site lands on C19.

## Phase 3 — Pre-fresh auto-adjust

- [x] 3.1 In `lib/app/accounts/statement_import/screens/confirm.page.dart`, add `Future<bool> _handlePreFresh(Account account, List<MatchedRow> approved)` per design §6:
   - [x] 3.1a Compute `proposedTrackedSince = preFresh.map((r) => r.row.date).reduce(min)` truncated to date (year/month/day).
   - [x] 3.1b Call `accountService.getAccountsMoneyPreview(accountId: account.id, simulatedTrackedSince: proposedTrackedSince).first`.
   - [x] 3.1c Show `RetroactivePreviewDialog`; escalate to `RetroactiveStrongConfirmDialog` when `shift > 50% || simulated < 0` (reuse trigger from `account-pre-tracking-period`).
   - [x] 3.1d On accept: `accountService.updateAccount(account.copyWith(trackedSince: proposedTrackedSince))` then `flow.refreshAccount()`.
   - [x] 3.1e On cancel: proceed with commit; rows stay flagged pre-fresh (hidden in account view as historical).
- [x] 3.2 Hook `_handlePreFresh` early in `confirm.page.dart:39-112` `_commit()` flow, gated on `kEnablePreFreshAutoAdjust`.
- [x] 3.3 Skip dialog when `account.trackedSince == null` (no-op path → `_handlePreFresh` returns true immediately).
- [x] 3.4 Add i18n keys `STATEMENT_IMPORT.PRE_FRESH.auto-adjust-title` and `auto-adjust-body` to `es.json` + `en.json`; regenerate slang.
- [x] 3.5 Tests:
   - [x] 3.5a Widget: `RetroactivePreviewDialog` shown when pre-fresh rows present and shift small.
   - [x] 3.5b Widget: strong-confirm escalation when shift > 50%.
   - [x] 3.5c Widget: `account.trackedSince == null` bypasses dialog entirely.
   - [ ] 3.5d Integration: import old screenshot → accept dialog → rows visible in account view (in-memory DB). **DEFERRED** — same rationale as 1.11d: full-flow integration needs the in-memory Drift DB plus singleton mocks for `AccountService`/`StatementBatchesService`. Covered by Phase 4 smoke (4.2d / 4.2e).

## Phase 4 — Verification

- [ ] 4.1 Run full test suite: `flutter test`. All green.
- [ ] 4.2 Manual smoke (per design §11):
   - [ ] 4.2a Single-image import (regression — must still work with flag off).
   - [ ] 4.2b 3-image import, all succeed.
   - [ ] 4.2c 3-image import, 1 fails extraction → review shows chip.
   - [ ] 4.2d Old-dated import → pre-fresh dialog → accept → rows visible in account.
   - [ ] 4.2e Old-dated import → pre-fresh dialog → cancel → rows hidden as historical.
   - [ ] 4.2f Categorization with ambiguous merchant → ends as C19.
- [ ] 4.3 Run `/sdd-verify screenshot-import-improvements`.
- [ ] 4.4 Flip `kEnableMultiImageImport = true` in `lib/core/constants/feature_flags.dart` after smoke passes.

---

## Notes

### Out of scope (do NOT implement here)

- Telemetry of confidence/categorization (deferred to v1.1).
- Batched-LLM call (single request with N images).
- Per-bank dedicated parsers.
- Transfer detection in extracted rows.
- Firebase sync of adjusted `trackedSince`.
- Stats toggle for including/excluding pre-fresh rows.

### Critical dependencies

- Phase 1, 2, 3 all depend on Phase 0 (constants + lifted dialogs).
- Phase 3 depends on `account-pre-tracking-period` being archived (PR ordering rule from `state.yaml`).
- `dart run slang` must run after every i18n change (1.10, 3.4).
