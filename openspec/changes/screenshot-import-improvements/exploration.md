# Exploration: screenshot-import-improvements

## Goal in Plain Language

Three independent quality-of-life fixes for the screenshot-based statement import flow (the "subir foto del estado de cuenta" feature):

1. **Multi-image import** — let the user pick / shoot **multiple screenshots** in one import session and have them all extracted, deduped, and reviewed together. Today the picker only accepts a single file/photo.
2. **Smarter categorization fallback** — when the LLM is uncertain (or AI categorization is disabled), do not silently dump every uncategorized expense into "Alimentación". Route to the existing neutral "Otros Gastos" / "Otros Ingresos" categories, and instruct the LLM to admit ignorance instead of guessing.
3. **Pre-fresh transactions become visible automatically** — when the user imports a statement that contains rows older than the account's `trackedSince`, offer to auto-roll `trackedSince` back to the earliest imported date (with a preview dialog showing the new balance), so the imported rows actually appear in account-scoped views instead of being silently filtered out.

These three fixes target three distinct files/services, so they can be one change with three sub-deltas, but **fix #3 has a hard prerequisite** on `account-pre-tracking-period` already being in place (it is — see below).

---

## Codebase Orientation

### Problem 1 — single image only

| File | Line(s) | Issue |
|------|---------|-------|
| `lib/app/accounts/statement_import/screens/capture.page.dart` | 25-57 | `_onTakePhoto` calls `picker.pickImage()` — singular. `image_picker` does have `pickMultiImage()` but camera source is hard-coded so this is camera = 1 photo. |
| `lib/app/accounts/statement_import/screens/capture.page.dart` | 59-85 | `_onPickFile` calls `FilePicker.platform.pickFiles()` (no `allowMultiple: true`) and then `result.files.single`. |
| `lib/app/accounts/statement_import/screens/capture.page.dart` | 103-145 | `_handlePdf` already has special-case multi-page logic, but only ever rasterizes `rasterizeFirstPage(bytes)` (line 132) so 2-page PDFs are silently truncated to page 1 today. |
| `lib/app/accounts/statement_import/statement_import_flow.dart` | 31-32 | Flow state holds `String? imageBase64` + `DateTime? pivotDate` — single image only. |
| `lib/app/accounts/statement_import/statement_import_flow.dart` | 51-66 | `goToProcessing({required String imageBase64, required DateTime pivotDate})` accepts one image. |
| `lib/app/accounts/statement_import/screens/processing.page.dart` | 64-85, 87-108 | `_runExtract` calls `StatementExtractorService().extractFromImage(...)` once per render, then triggers MatchingEngine once. To support N images: loop or batch. |
| `lib/core/services/statement_import/statement_extractor_service.dart` | 60-97 | `extractFromImage({imageBase64, pivotDate})` accepts a single base64 string. The signature would need to change OR a new `extractFromImages(List<String>)` to be added. |
| `lib/core/services/ai/nexus_ai_service.dart` | 137-188 | `completeMultimodal` is OpenAI chat-completions compatible — its `messages[].content` array can carry **N image parts** in a single request. So a batched call IS technically supported by the upstream API; `_defaultMultimodalModel` capacity is the practical limit. |
| `lib/core/services/statement_import/matching_engine.dart` | 14-95 | Stateless; takes `List<ExtractedRow>` regardless of source. Easy to feed concatenated rows from N images. |
| `lib/core/services/statement_import/statement_batches_service.dart` | (not re-read) | Commits a batch — already aggregates a `List<TransactionInDB>`, so multi-image only feeds it more rows. No change. |

### Problem 2 — auto-categorization always falls back to "Alimentación"

| File | Line(s) | Issue |
|------|---------|-------|
| `lib/app/transactions/auto_import/proposal_review.page.dart` | 939-963 | `_resolveFallbackCategoryForType` filters categories by `type` then returns `normalized.first`. Categories are seeded in the order they appear in `assets/sql/initial_categories.json`; first expense category is **C10 Alimentación**. This is the bug. |
| `lib/app/accounts/statement_import/screens/confirm.page.dart` | 29-37 | `_resolveCategoryForKind` does the same `firstOrNull` trick on category lists — same bug, second site. Used in the bulk commit path of the screenshot import. |
| `lib/core/services/ai/auto_categorization_service.dart` | 47-70 | The system + user prompt instructs the LLM to "Clasifica este movimiento usando SOLO una categoria valida" — there is no "if uncertain, return categoryId=null / OTROS" escape hatch. The LLM will always pick something, often wrong. |
| `assets/sql/initial_categories.json` | line 38-54 | **C03 "Otros Ingresos"** exists, type `"I"`. ID is stable. |
| `assets/sql/initial_categories.json` | line 532-548 | **C19 "Otros Gastos"** exists, type `"B"` (Both — counts as expense AND income). ID is stable. |

So **no schema or seed change is needed** — both neutral categories already exist in `initial_categories.json` with stable IDs `C03` / `C19`. The fix is two-fold:

- (a) Update both `_resolveFallbackCategoryForType` (proposal_review) and `_resolveCategoryForKind` (confirm.page) to look up by ID `C19` (expense) / `C03` (income) and only fall back to `.first` if those rows don't exist (e.g. user deleted them).
- (b) Update `auto_categorization_service.dart` prompt to allow the LLM to return `categoryId: "C19"` / `"C03"` (or null with a sentinel) when confidence is low, plus add a confidence threshold below which the suggestion is rejected and the local fallback (a) kicks in. Today the threshold check happens on the call site (`proposal_review.page.dart:194-208` reads `pi.proposedCategoryId`) but acceptance is unconditional.

### Problem 3 — pre-fresh transactions silently invisible

| File | Line(s) | Issue |
|------|---------|-------|
| `lib/core/services/statement_import/matching_engine.dart` | 73-75 | `final isPreFresh = trackedSince != null && row.date.isBefore(trackedSince);` — confirmed marker. |
| `lib/app/accounts/statement_import/screens/review.page.dart` | 28-38, 132-137 | The "informative" mode chip is the existing surface for pre-fresh — when active, only pre-fresh rows show. Today the user can already SEE the rows are pre-fresh; what's missing is making them VISIBLE in the rest of the app post-import. |
| `lib/app/accounts/statement_import/screens/review.page.dart` | 75-105 | `_promptInformativeBlocked` already routes the user to `AccountFormPage` (line 100) so they can manually edit `trackedSince`. After return, `flow.refreshAccount()` re-reads the account. So a manual workaround exists today; it's just clunky. |
| `lib/app/accounts/statement_import/screens/confirm.page.dart` | 39-112 | `_commit` does NOT touch `trackedSince` — it just inserts transactions with their real dates. Pre-fresh inserts succeed but are filtered by `getAccountsMoney`'s `respectTrackedSince=true` (per `account-pre-tracking-period`). |
| `lib/core/database/services/account/account_service.dart` | 29-33 | `updateAccount(AccountInDB)` is the existing mutator. To shift `trackedSince` we use `AccountInDB(...).copyWith(trackedSince: newDate)` then `updateAccount(updated)`. |
| `lib/core/database/services/account/account_service.dart` | 314-389 | `getAccountsMoneyPreview({required accountId, required simulatedTrackedSince})` is **already implemented** — built explicitly for this use case (per `account-pre-tracking-period` task 2.4). Returns a `Stream<double>` of the simulated balance. Perfect for our preview dialog. |
| `lib/core/models/account/account.dart` | 81-82 | `account.isTrackingHistorical(DateTime txDate)` helper exists. |
| `lib/app/accounts/account_form.dart` | (per task list) | `RetroactivePreviewDialog` and `RetroactiveStrongConfirmDialog` widgets already exist (tasks 3.6, 3.7 marked `[x]`). We can either reuse those exact widgets, lift them to a shared location, or copy the pattern. Reusing avoids drift in confirmation UX. |

---

## Existing Related Work

### `account-pre-tracking-period` — applied

Per `openspec/changes/account-pre-tracking-period/tasks.md`, **Fases 1–5 are all `[x]` (done)**. Only the smoke-test phase 6 is still open. The infrastructure this new change depends on is shipped:

- `accounts.trackedSince DATETIME` column + Drift migration v24.
- `Account.trackedSince`, `Account.isTrackingHistorical(date)`.
- `AccountService.updateAccount(AccountInDB)` mutator.
- `AccountService.getAccountsMoneyPreview({accountId, simulatedTrackedSince})` — **already designed for the exact use case**: simulate balance under a hypothetical `trackedSince` without persisting. Returns a `Stream<double>`.
- `TransactionFilterSet.respectTrackedSince` flag.
- The pre-fresh badge in `transaction_list_tile.dart`.
- `RetroactivePreviewDialog` / `RetroactiveStrongConfirmDialog` widgets (in `account_form.dart`).

The previous change explicitly listed "Integración con `bulk-statement-ocr` (change siguiente)" as out of scope (proposal.md line 40). That "change siguiente" is this one.

### `templates-trainable` — orthogonal, no overlap

That change targets the **notification listener pipeline** (SMS / push parsing → `pendingImports` table → `proposal_review.page.dart`). It does NOT touch `lib/app/accounts/statement_import/` (the screenshot OCR flow) or `lib/core/services/statement_import/`. The only point of contact is `proposal_review.page.dart:939-963` (Problem 2 above), which IS used by both flows downstream of `pendingImports`. The categorization fallback fix touches a function that templates-trainable does not modify per its proposal.md, so no merge conflict expected. Recommend coordinating PR order if both land in the same week.

---

## Approaches

### Problem 1 — multi-image: serial vs batched

| Approach | Pros | Cons | Effort |
|----------|------|------|--------|
| **A. Serial pipeline** — loop `extractFromImage` per image, concatenate `List<ExtractedRow>`, dedupe, run MatchingEngine once on the union. | Minimal API change; existing `extractFromImage` reused; one image failing doesn't kill others (catch + skip with warning). Easy to show progress (3/5). LLM cost = N × current. Each image gets its own retry budget. | N round-trips = N × latency. User waits longer. Each call pays the system-prompt token cost separately (cache could help in future). | **Low** |
| **B. Batched call** — new `extractFromImages(List<String>)` that sends N image-parts in one `messages[].content` array. | One round-trip; cheaper (system prompt charged once); model sees full statement context (continuation across screenshots). | Vendor model token limits (most multimodal endpoints cap 5-10 images per request, and per-image token cost is ~1k+); harder to attribute failure to a specific image; harder to retry just one; date-hint logic in `_resolveDate` assumes a single `pivotDate` — N images may have N different EXIF/user dates. | **Medium** |
| **C. Hybrid** — batch up to 3 images per call, serial across batches. | Best of both — balances latency, cost, and reliability. | More code. | Medium-High |

**Recommendation: A (serial) for v1.** Reasoning: the user explicitly mentioned "May 4 + May 5" — typically 2-5 screenshots, not 50. Latency is acceptable (3 × 5s = 15s); it composes cleanly with progress UI; each image keeps its own pivot date (EXIF or per-image prompt); failures are isolated. B is an optimization that should wait for real telemetry showing latency complaints. The serial approach also reuses `_resolveDate`'s pivot-per-image semantics without changes.

### Problem 2 — categorization fallback

| Approach | Pros | Cons | Effort |
|----------|------|------|--------|
| **A. Hard-coded constant lookup** — `_kFallbackExpenseCategoryId = 'C19'`, `_kFallbackIncomeCategoryId = 'C03'`. Apply in both `_resolveFallbackCategoryForType` and `_resolveCategoryForKind`. + LLM prompt update with confidence threshold (e.g. `< 0.6` → reject). | Zero schema change; both fallback categories already seeded; one constant to update if seed JSON ever moves. Deterministic. | If user deletes "Otros Gastos" / "Otros Ingresos", we still need a `.first` fallback as last resort. Hardcoded ID couples to seed file. | **Low** |
| **B. Heuristic name-match** — find category whose name contains "otros" / "other" / "misc" (i18n-aware). | More robust to seed reorganization. | Brittle across locales; could match "Otros Servicios" by accident. | Medium |
| **C. New `isDefault` / `isFallback` flag** in `categories` table (Drift migration). | Explicit semantics; user-visible in category editor. | Schema change; migration; UI; out of proportion to bug. | High |

**Recommendation: A (constant lookup)** with a `.first` last-resort fallback for the case where the user deleted the seeded category. Add a constants file `lib/core/constants/fallback_categories.dart` (or similar) so both call sites import the same IDs.

### Problem 3 — auto-adjust trackedSince

| Approach | Pros | Cons | Effort |
|----------|------|------|--------|
| **A. Silent auto-adjust** at commit time — if any `r.isPreFresh`, find min(date), `account.copyWith(trackedSince: min)`, persist, then proceed. | Zero friction; user said "auto-ajustar". | Mutates balance-affecting state without confirmation; surprises users; violates the "dialog before retroactive trackedSince change" pattern already established in `account_form.dart` (tasks 3.6/3.7). |  Low |
| **B. Preview dialog with cancel** — reuse `RetroactivePreviewDialog` (and `RetroactiveStrongConfirmDialog` if the diff is large) on `confirm.page._commit()` before inserting transactions. Show "balance actual: X → balance nuevo: Y". | Consistent with existing UX precedent for retroactive `trackedSince` changes. User stays in control. Reuses tested widgets. | One extra tap. Need to lift the dialogs from `account_form.dart` to a shared location (or expose them). | Medium |
| **C. Post-commit toast with undo** — commit transactions first, auto-shift `trackedSince`, show "Movimientos previos visibles ahora — deshacer" snackbar. | Minimal blocking UX. | Asymmetric (silent shift, manual revert). Confusing if user dismisses snackbar. | Medium |

**Recommendation: B (preview dialog with cancel).** The existing change already established the convention (`RetroactivePreviewDialog` + strong-confirm for big diffs); breaking that convention in a sibling flow would be jarring. The user said "auto-ajustar" but a preview-confirm is still "auto" — the system surfaces the suggestion automatically, the user only has to tap Aceptar. Concretely:

1. In `confirm.page._commit()`, before inserting, compute `preFreshRows = approved.where((r) => r.isPreFresh)`.
2. If non-empty AND `account.trackedSince != null`, compute `proposedTrackedSince = preFreshRows.map((r) => r.row.date).reduce(min)` (truncated to date).
3. Stream `getAccountsMoneyPreview(accountId: account.id, simulatedTrackedSince: proposedTrackedSince).first` to get hypothetical balance.
4. Show `RetroactivePreviewDialog(currentBalance: X, simulatedBalance: Y)`. If diff > 50% or Y < 0, escalate to `RetroactiveStrongConfirmDialog`.
5. On Aceptar: persist `account.copyWith(trackedSince: proposedTrackedSince)` via `AccountService.updateAccount`, then `flow.refreshAccount()`, then proceed with `commit()`.
6. On Cancel: leave `trackedSince` alone, proceed with commit (rows still get inserted, will remain pre-fresh; user explicitly chose this).

---

## Open Questions for `/sdd-propose`

1. **Multi-image extraction strategy** — confirm Approach A (serial). Token budget per image: image_url with base64 1600px wide ≈ 800-1500 tokens; 5 images ≈ 7.5k tokens just for images, comfortable under any reasonable model context window. **Decision needed**: max images allowed per session (suggest 10 with hard cap, 5 with warning soft cap)?
2. **Multi-image dedupe within session** — if user uploads two screenshots of the same screen, MatchingEngine today only dedupes against existing DB transactions, not within the new batch. **Decision needed**: dedupe rule? Suggest: same `(date, amount, kind)` triple within a single session is collapsed before MatchingEngine runs. Confidence: keep highest.
3. **Per-image pivot date** — current single-image flow uses EXIF date OR a single user-picked date as pivot for "HOY"/"AYER" resolution. With N images, do we (a) ask user once for one shared pivot, (b) read EXIF per-image and prompt only when missing, (c) require all images have EXIF or fail? Suggest (b) — keeps EXIF auto-detect, only prompts for the missing ones, one date-picker per "missing" image, batched at the start.
4. **Categorization confidence threshold** — what's the cutoff below which we discard the LLM suggestion and use `C19`/`C03`? Suggest 0.6, surfaced as a constant. Also: should the prompt explicitly list `"Otros Gastos (C19)"` as an option and tell the LLM "use this when unsure"? Yes — this is the cheapest win.
5. **Trackedsince preview reuse** — lift `RetroactivePreviewDialog` from `account_form.dart` to `lib/core/presentation/widgets/` so both surfaces use the same widget? Yes; a 5-line refactor that prevents drift.
6. **Failure handling N-of-M images** — if 3 of 5 images extract successfully, do we (a) abort the whole session, (b) proceed with the 3 and warn, (c) ask the user? Suggest (b) with a per-image error chip in the review screen.
7. **One change or split into 2-3?** — see Recommendation below.

---

## Risks / Unknowns

1. **Multi-image LLM rate limits & timeouts** — current `processing.page.dart:71` has a hard 30s timeout. Five serial calls = potential 5×30s = 150s with no progress feedback. Need progress UI ("procesando 2 de 5") and per-image timeout, plus backoff if rate-limited.
2. **Pre-fresh auto-adjust + transfer cross-account symmetry** — `account-pre-tracking-period` design (from its proposal line 13) requires symmetric pre-fresh logic on transfer counterpart accounts. Statement import only ingests one account's rows, but if a row is a transfer (not currently extracted, but a future enhancement), shifting `trackedSince` on the source account creates asymmetry with the destination. Mitigation: explicitly out-of-scope — statement import currently treats every row as income/expense/fee, no transfer detection.
3. **Strong-confirm trigger on auto-adjust** — when shifting `trackedSince` back several months, balance can flip sign or change by >50%, triggering `RetroactiveStrongConfirmDialog`'s "type CONFIRMAR" gate. This is correct behavior but may surprise users who expected one-tap "auto-ajustar". Document in copy.
4. **Token cost regression** — even with serial Approach A, 10 images = 10× current cost per import. If a user dumps a 20-page PDF rasterized as 20 images this could be expensive. Mitigation: cap image count in capture.page.dart at 10, surface count + estimated cost (rough) before processing.
5. **Confidence threshold mis-tuning** — if 0.6 is too aggressive, every transaction defaults to "Otros Gastos" and the categorization feature degrades. If too lax, the bug survives. Mitigation: log telemetry of `(confidence, kept_or_replaced)` and tune in v1.1. No live telemetry exists today; consider a debug log line.
6. **Image picker platform variance** — `image_picker.pickMultiImage()` is Android/iOS only; on desktop the `file_picker` path is the only option. `FilePicker.pickFiles(allowMultiple: true)` works on all platforms and supports both PDFs and images. Recommend converging on `file_picker` for the multi-select path even when `pickMultiImage` is technically available, for consistency.
7. **Single-image regression risk** — touching `statement_import_flow.dart` state shape (`List<String> imageBase64s` instead of `String? imageBase64`) ripples through processing/review/confirm. Mitigation: keep a single-element list as the common case; do not change the public API of stateless services. Add a smoke test for "single image still works".

---

## Recommendation

### Change name

Keep `screenshot-import-improvements`. Generic enough to cover the three sub-fixes; specific enough to disambiguate from `templates-trainable` (notification flow) and `account-pre-tracking-period` (already shipped).

### One change or split?

**Recommend ONE change with three explicit phases in `tasks.md`** — the surface area is bounded (~6 files modified, ~2 new helpers), the user reported them together, and they share testing surface (the same import session exercises all three). Three separate `/sdd-new` cycles would generate redundant proposals.

**Alternative split (only if scope balloons in `/sdd-design`)**:

- `screenshot-import-multi-image` — Problem 1 alone (largest blast radius: capture.page, flow state, processing.page, possibly extractor service).
- `auto-import-categorization-fallback` — Problem 2 alone (cross-cutting fix touching both `proposal_review.page.dart` and `confirm.page.dart` plus the AI service prompt; affects both notification AND screenshot flows).
- `screenshot-import-pre-fresh-auto-adjust` — Problem 3 alone (small; one-method change in `confirm.page._commit` plus dialog-widget extraction).

Split if estimated effort exceeds 5 engineer-days. First-pass estimate for the unified change: **3-4 engineer-days** including manual smoke test. Below the split threshold.

### Phase ordering inside the unified change

1. **Phase 1 — categorization fallback** (smallest, lowest risk, unblocks Problem 2 in proposal_review which also fires for SMS/notification imports — biggest UX win-per-LOC).
2. **Phase 2 — pre-fresh auto-adjust** (depends on widget lift from `account_form.dart`; isolated to confirm.page).
3. **Phase 3 — multi-image** (largest; touches flow state, capture/processing screens; benefits from the previous two already being in place so the multi-image session pays off correctly on first use).

### Ready for `/sdd-propose`

**Yes.** The exploration confirms:
- All three problems are reproducible from code reading alone.
- The infrastructure (`trackedSince`, `getAccountsMoneyPreview`, neutral categories C03/C19) is already in place.
- No schema migration is required.
- Effort estimate is below split threshold.

Open questions (1-7 above) are well-formed and can be resolved during proposal/design phases.
