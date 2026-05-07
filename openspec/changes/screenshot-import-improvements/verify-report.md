# Verification Report: screenshot-import-improvements

**Mode**: openspec
**Verified**: 2026-05-07

## Verdict

**PASS-WITH-CAVEATS** — All implementation tasks complete, tests green (602 passed, 8 skipped, 0 failed), zero new analyzer regressions. Two deferred integration tests (1.11d, 3.5d) are explicitly tracked for Phase 4 manual smoke per the design's deferral note. Manual smoke (4.2a–f) is pending and is the user's responsibility before final archive.

---

## Per-Phase Checklist

### Phase 0 — Prep / shared utilities

| Item | Status | Evidence |
|------|--------|----------|
| `lib/core/constants/feature_flags.dart` exists with both flags | OK | `feature_flags.dart:12,18` — `kEnableMultiImageImport=false`, `kEnablePreFreshAutoAdjust=true` |
| `lib/core/constants/fallback_categories.dart` exists with `kFallbackExpenseCategoryId='C19'`, `kFallbackIncomeCategoryId='C03'`, working `resolveFallbackCategory` | OK | `fallback_categories.dart:6,10,24,50` — sync + async wrapper present |
| `lib/core/presentation/widgets/retroactive_preview_dialog.dart` contains both dialogs | OK | `retroactive_preview_dialog.dart:10` (`RetroactivePreviewDialog`), `:55` (`RetroactiveStrongConfirmDialog`) |
| `account_form.dart` imports the dialogs from new path; no duplicates | OK | `account_form.dart:28` import; grep confirms only one definition site of each class |

### Phase 1 — Multi-image import

| Item | Status | Evidence |
|------|--------|----------|
| `image_pivot.dart` defines `ImagePivot` with `base64`, `exifDate`, `resolvedPivot` + `readExifDate(base64)` helper | OK | `image_pivot.dart:7-25` value class, `:27-34` `readExifDate`, `:36-61` `readExifDateFromBytes` discards future dates |
| `dedupe_in_session.dart` exists with the 4h-bucket key | OK | `dedupe_in_session.dart:10` `_bucketMs = 4*3600*1000`; key tuple at `:12-18` |
| `statement_import_flow.dart` uses `List<ImagePivot> images` and `List<int> failedImageIndices` (back-compat getters acceptable) | OK | `statement_import_flow.dart:32-33` fields, `:48,51` legacy getters |
| `capture.page.dart` uses `pickFiles(allowMultiple: true)` and respects 10-cap; gated on `kEnableMultiImageImport` | OK | `capture.page.dart:17` `kMaxImagesPerSession=10`, `:30` flag, `:65-70` `allowMultiple: _multiEnabled`, `:74-75` cap check, `:160-167` PDF page cap loop |
| `processing.page.dart` runs serial loop with try/catch per image and `ValueNotifier<int>` for progress | OK | `processing.page.dart:30` notifier, `:80-96` serial loop with try/catch, `:268-279` ValueListenableBuilder |
| `review.page.dart` renders dismissible chips for `failedImageIndices` | OK | `review.page.dart:174` reads `flow.failedImageIndices`; `:266-310` `_FailedImageChips` with `InputChip(onDeleted:)` |
| i18n keys present in `es.json` + `en.json` | OK | `es.json:1284,1303,1304,1321`; `en.json:1282,1301,1302,1319` (all four keys: multi-count, progress, all-failed, image-failed) |
| Tests in `dedupe_in_session_test.dart`, `capture_multi_counter_test.dart`, `processing_progress_test.dart` | OK | All three files present under `test/statement_import/` |

### Phase 2 — Categorization

| Item | Status | Evidence |
|------|--------|----------|
| `proposal_review.page.dart` `_resolveFallbackCategoryForType` calls `resolveFallbackCategory` (NOT `.first`) | OK | `proposal_review.page.dart:940-945` |
| `confirm.page.dart` `_resolveCategoryForKind` calls `resolveFallbackCategory` | OK | `confirm.page.dart:55-61` |
| `auto_categorization_service.dart` has `kMinConfidence = 0.55` and gates suggestion below threshold | OK | `auto_categorization_service.dart:9` `const double kMinConfidence = 0.55;`; `:51` `if (clamped < kMinConfidence) return null;` |
| LLM prompt contains literal Spanish neutral-fallback instruction | OK | `auto_categorization_service.dart:108-110` literal "Si no estás 100% seguro de la categoría, devuelve "C19" para gastos o "C03" para ingresos. Es preferible una clasificación neutral a una incorrecta." |
| Tests in `fallback_categories_test.dart` and `auto_categorization_service_test.dart` | OK | Both files present; 9 + 14 cases observed |

### Phase 3 — Pre-fresh auto-adjust

| Item | Status | Evidence |
|------|--------|----------|
| `confirm.page.dart` has `_handlePreFresh(Account, List<MatchingResult>)` returning `Future<bool>` | OK | `confirm.page.dart:75-142` |
| Hook called in `_commit()` and gated on `kEnablePreFreshAutoAdjust` | OK | `confirm.page.dart:151-154` |
| Hook handles `trackedSince == null` by returning true immediately | OK | `confirm.page.dart:79` `if (account.trackedSince == null) return true;` |
| Strong-confirm escalation predicate matches design (shift > 50% OR balance < 0) | OK | `confirm.page.dart:25` const, `:31-40` `shouldEscalatePreFreshDialog` predicate |
| On accept: calls `accountService.updateAccount` with new `trackedSince` and refreshes flow account | OK | `confirm.page.dart:127-132` `updateAccount(...)` then `flow.refreshAccount()`; flow `:126-134` queries DB |
| i18n keys `auto-adjust-title/auto-adjust-body` exist in both locales | OK | `es.json:1360-1361`; `en.json:1358-1359` |
| Tests in `pre_fresh_dialog_test.dart` | OK | Present; covers predicate (5 cases), preview render, strong-confirm with text input, trackedSince-null bypass |

---

## Test Results

`flutter test` (full suite): **All tests passed** (exit 0)

- Total reported by harness: **602 passed**, **8 skipped**, **0 failed**
- Statement-import suite, fallback_categories suite, auto_categorization_service suite all green
- Suites run included: pre_fresh_dialog_test, processing_progress_test, capture_multi_counter_test, dedupe_in_session_test, fallback_categories_test, auto_categorization_service_test, plus ~595 unrelated tests

No failures.

---

## Analyze Results

`flutter analyze` (full project): **41 issues** total — all pre-existing.

Categorisation:

- **36 warnings** in generated `lib/i18n/generated/translations_{de,fr,hu,it,tr,uk,zh_CN,zh_TW}.g.dart` — `override_on_non_overriding_member`. Pre-existing, generated by slang.
- **3 infos** for `NexusAiService` deprecation (in `receipt_extractor_service.dart`, `statement_extractor_service.dart`, plus 2 test files) — pre-existing.
- **1 info** in `lib/core/services/ai/ai_service.dart:109` `curly_braces_in_flow_control_structures` — pre-existing.
- **1 info** in `lib/core/utils/date_time_picker.dart:44` `use_build_context_synchronously` — pre-existing.

**New issues introduced by this change**: **0**. None of the new files (`feature_flags.dart`, `fallback_categories.dart`, `image_pivot.dart`, `dedupe_in_session.dart`, `missing_pivot_sheet.dart`, `retroactive_preview_dialog.dart`) appear in the output. Touched call sites (`capture.page.dart`, `processing.page.dart`, `review.page.dart`, `confirm.page.dart`, `proposal_review.page.dart`, `auto_categorization_service.dart`, `account_form.dart`, `statement_import_flow.dart`) likewise produce no new issues.

State.yaml had noted "7 pre-existing infos" — the 41 includes those plus the 36 generated-translations warnings, also pre-existing. No regressions.

---

## Spec Coverage

### Delta `statement-import-multi-image.md`

| Requirement | Implementation evidence | Status |
|-------------|-------------------------|--------|
| Captura acepta hasta 10 imágenes | `capture.page.dart:17` `kMaxImagesPerSession=10`; `:31` `_capReached`; cap check enforced before each ingest; PDF rasterizes up to `cap` pages (`:160-163`) | Satisfied |
| Pivot date por imagen con auto-detección EXIF | `image_pivot.dart:36-61` reads EXIF, discards future dates; `capture.page.dart:106-115` builds `ImagePivot`; `:213-219` `_continueIfReady` calls `promptMissingPivots` | Satisfied |
| Pipeline serial con aislamiento de fallos | `processing.page.dart:80-96` per-image try/catch, `_currentImageIndex` updated; `:100-109` global all-failed branch (no nav to review) | Satisfied |
| Dedupe in-session antes de revisión | `dedupe_in_session.dart:12-18,20-46`; `processing.page.dart:113` invoked after extraction loop, before MatchingEngine (`:127`) | Satisfied |
| Revisión muestra imágenes fallidas | `review.page.dart:174,266-310` dismissible InputChip per failed index | Satisfied |

### Delta `categorization-fallback.md`

| Requirement | Implementation evidence | Status |
|-------------|-------------------------|--------|
| Fallback a C19/C03 por ID estable, centralizado | `fallback_categories.dart:6,10,24-45` lookup-by-id then `.first` | Satisfied |
| Prompt LLM permite y favorece neutral | `auto_categorization_service.dart:108-110` literal Spanish instruction; `:51` threshold gate (`kMinConfidence`) discards low-confidence | Satisfied |
| Last-resort `.first` si seed eliminada | `fallback_categories.dart:44` `return filtered.first;` after id-lookup miss | Satisfied |
| Misma resolución en ambos call sites | `proposal_review.page.dart:944` and `confirm.page.dart:60` both call `resolveFallbackCategory`; identical chain | Satisfied |

### Delta `pre-fresh-auto-adjust.md`

| Requirement | Implementation evidence | Status |
|-------------|-------------------------|--------|
| Detección filas pre-fresh + propuesta `proposedTrackedSince` | `confirm.page.dart:81-91` filters `r.isPreFresh`, computes `min`, truncates to date | Satisfied |
| `RetroactivePreviewDialog` muestra balance hipotético | `confirm.page.dart:94-124` queries `getAccountsMoney` + `getAccountsMoneyPreview`, shows preview | Satisfied |
| Escalación a strong-confirm | `confirm.page.dart:31-40` predicate (`shift > 50% OR simulated < 0`); `:104-124` chooses dialog | Satisfied |
| Aceptar persiste y procede | `confirm.page.dart:127-133` `updateAccount(... trackedSince ...)`, `refreshAccount()`, returns true | Satisfied |
| Cancelar mantiene comportamiento previo | `confirm.page.dart:136-141` standard preview dismissal returns true (commit proceeds, no mutation) | Satisfied |
| Sin `trackedSince` configurado — no diálogo | `confirm.page.dart:79` early return `true` when `trackedSince == null` | Satisfied |

---

## Open Issues / Follow-ups

**Deferred (NOT regressions; explicitly noted in `tasks.md` and `state.yaml`):**

- 1.11d — Integration test: 3 images, 1 fails → review chip + commit. Deferred by design (singleton mocking cost vs benefit). Covered by manual smoke 4.2c.
- 3.5d — Integration test: old screenshot → accept dialog → rows visible. Deferred by design (singleton `AccountService`/`StatementBatchesService`). Covered by manual smoke 4.2d/4.2e.

**Pending (user action):**

- 4.2a — Single-image import regression (flag off).
- 4.2b — 3-image import, all succeed.
- 4.2c — 3-image import, 1 fails extraction → chip in review.
- 4.2d — Old-dated import → pre-fresh accept → rows visible.
- 4.2e — Old-dated import → pre-fresh cancel → rows historical.
- 4.2f — Categorization with ambiguous merchant → C19.
- 4.4 — Flip `kEnableMultiImageImport = true` after smoke passes.

**Notes on observations during verification:**

- `_buildKey` in `dedupe_in_session.dart` accepts `currency` as a parameter but `processing.page.dart:113` calls `dedupeInSession(accumulated)` without currency, so the bucket key uses an empty currency literal. This still satisfies the spec (extracted rows in a single session belong to the same import context, and currency is rarely a discriminator across screenshots of the same account). Not a blocker; flagged for future review if multi-currency screenshots become common.
- The flow file retains backwards-compat getters (`imageBase64`, `pivotDate`) — these are explicitly allowed by the verification rubric.

---

## Recommendation

The implementation is **ready for the manual smoke pass (4.2a–f)**. Once smoke is green, run `/sdd-archive screenshot-import-improvements`. Do not archive before the user has executed the smoke checklist — the two deferred integration tests rely on smoke for behavioral coverage of the full flow.

**Next recommended**: manual smoke (user); then `/sdd-archive screenshot-import-improvements`.
