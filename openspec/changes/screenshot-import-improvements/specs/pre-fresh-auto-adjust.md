# Delta for statement-import — pre-fresh auto-adjust de `trackedSince`

Extiende el flujo de import del estado de cuenta para ofrecer ajuste retroactivo de `trackedSince` cuando filas pre-fresh vendrían a quedar invisibles tras el commit. Reutiliza `RetroactivePreviewDialog` y `RetroactiveStrongConfirmDialog` ya entregados por `account-pre-tracking-period`.

---

## ADDED Requirements

### Requirement: Detección de filas pre-fresh y propuesta de nuevo `trackedSince`

Tras revisión y antes del commit final, si el conjunto de filas aprobadas contiene al menos una con `isPreFresh == true` (i.e., `row.date < account.trackedSince`) Y `account.trackedSince != null`, el sistema MUST computar:

- `proposedTrackedSince = min(approved.where(isPreFresh).map(date)).truncatedToDate()`.

Y MUST proponer este valor al usuario vía diálogo ANTES de proceder al commit. La detección MUST ocurrir en `confirm.page._commit()` antes de invocar `statement_batches_service.commit()`.

#### Scenario: Hay filas pre-fresh — propuesta visible

- GIVEN una cuenta con `trackedSince = 2026-04-01`
- AND el usuario aprobó filas con fechas `2026-03-15`, `2026-03-20`, `2026-04-05`
- WHEN se invoca `_commit()`
- THEN el sistema propone `trackedSince = 2026-03-15`
- AND muestra el diálogo de preview antes del commit

#### Scenario: Sin filas pre-fresh — commit directo

- GIVEN una cuenta con `trackedSince = 2026-04-01`
- AND el usuario aprobó filas con fechas todas `>= 2026-04-01`
- WHEN se invoca `_commit()`
- THEN no se muestra ningún diálogo
- AND el commit procede directamente

---

### Requirement: `RetroactivePreviewDialog` muestra balance hipotético

Cuando hay propuesta de ajuste, el sistema MUST mostrar `RetroactivePreviewDialog` con:

- Balance actual (calculado con `trackedSince` actual).
- Balance simulado (calculado vía `accountService.getAccountsMoneyPreview(accountId, simulatedTrackedSince: proposedTrackedSince).first`).
- Cantidad de filas que se volverán visibles.

El widget `RetroactivePreviewDialog` MUST ser elevado desde `account_form.dart` a `lib/core/presentation/widgets/retroactive_preview_dialog.dart` para reutilización compartida y prevenir drift. La copia del diálogo MUST ser i18n usando claves bajo `STATEMENT_IMPORT.PRE_FRESH.*`.

#### Scenario: Preview muestra ambos balances

- GIVEN propuesta de `trackedSince` shift de `2026-04-01` a `2026-03-15`
- AND balance actual `1000 Bs`, balance simulado `850 Bs`
- WHEN se muestra el diálogo
- THEN el usuario ve "Balance actual: 1000 Bs → Balance nuevo: 850 Bs"
- AND ve cuántas filas se volverían visibles

---

### Requirement: Escalación a `RetroactiveStrongConfirmDialog` ante shift grande

Si el shift proyectado cumple cualquiera de las siguientes condiciones, el sistema MUST escalar de `RetroactivePreviewDialog` a `RetroactiveStrongConfirmDialog` (mismo trigger usado por `account-pre-tracking-period`):

- `|balanceActual - balanceSimulado| > 0.5 * |balanceActual|` (shift > 50%).
- `balanceSimulado < 0` (balance proyectado negativo).

El strong-confirm MUST exigir que el usuario tipee literalmente "CONFIRMAR" para proceder.

#### Scenario: Shift menor al 50% — preview simple

- GIVEN balance actual `1000 Bs` y simulado `850 Bs` (shift 15%)
- WHEN se muestra el diálogo
- THEN basta con pulsar "Aceptar" (no se exige tipear)

#### Scenario: Shift > 50% — strong confirm

- GIVEN balance actual `1000 Bs` y simulado `300 Bs` (shift 70%)
- WHEN se muestra el diálogo
- THEN el sistema escala a `RetroactiveStrongConfirmDialog`
- AND exige tipear "CONFIRMAR"

#### Scenario: Balance proyectado negativo — strong confirm

- GIVEN balance actual `100 Bs` y simulado `-200 Bs`
- WHEN se muestra el diálogo
- THEN el sistema escala a `RetroactiveStrongConfirmDialog`
- AND exige tipear "CONFIRMAR"

---

### Requirement: Aceptar persiste `trackedSince` y procede al commit

Cuando el usuario acepta el diálogo (incluyendo el strong-confirm si aplicó), el sistema MUST:

1. Invocar `accountService.updateAccount(account.copyWith(trackedSince: proposedTrackedSince))`.
2. Refrescar el estado de la cuenta en `statement_import_flow` (`flow.refreshAccount()`).
3. Proceder con el commit normal de las filas aprobadas.

Las filas previamente pre-fresh MUST quedar visibles tras el commit (sin badge "Histórico" si `row.date >= newTrackedSince`).

#### Scenario: Usuario acepta, filas se vuelven visibles

- GIVEN propuesta `trackedSince` shift y usuario pulsa "Aceptar"
- WHEN finaliza el commit
- THEN `account.trackedSince` quedó actualizado en DB
- AND las filas pre-fresh aprobadas son visibles en el detalle de cuenta sin badge "Histórico"

---

### Requirement: Cancelar mantiene comportamiento previo

Cuando el usuario cancela el diálogo (rechaza el ajuste), el sistema MUST:

1. NO modificar `account.trackedSince`.
2. Proceder con el commit normal.
3. Insertar las filas con sus fechas reales; las filas pre-fresh quedarán flagueadas como tal y filtradas por `respectTrackedSince=true` en views de balance (comportamiento actual del módulo `accounts`).

El cancel MUST NO bloquear el import; solo significa "el usuario eligió mantener el `trackedSince` actual aunque algunas filas queden histórico-only".

#### Scenario: Usuario cancela el diálogo

- GIVEN propuesta de shift y usuario pulsa "Cancelar"
- WHEN finaliza el commit
- THEN `account.trackedSince` NO cambia
- AND las filas pre-fresh se insertan con su fecha real
- AND aparecen con badge "Histórico" en feeds (comportamiento heredado de `account-pre-tracking-period`)

---

### Requirement: Sin `trackedSince` configurado — no hay diálogo

Si `account.trackedSince == null` (cuenta nunca activó tracking), el sistema NO MUST mostrar el diálogo aunque haya filas con fechas antiguas. El commit MUST proceder directo con todas las filas insertándose normalmente, preservando el comportamiento actual del módulo `accounts` (sin `trackedSince`, todas las filas afectan balance).

#### Scenario: Cuenta sin tracking configurado

- GIVEN una cuenta con `trackedSince = NULL`
- AND el usuario aprobó filas con fechas variadas (incluso antiguas)
- WHEN se invoca `_commit()`
- THEN no se muestra el diálogo de auto-ajuste
- AND todas las filas se insertan con fechas reales
- AND todas afectan balance normalmente
