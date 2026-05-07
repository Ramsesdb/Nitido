# Delta for auto-categorization — neutral fallback

Bootstraps el dominio `auto-categorization` (no existe spec previo). Cubre el comportamiento de fallback cuando el LLM no produce sugerencia confiable, evitando que toda categoría incierta caiga en la primera de la lista (hoy "Alimentación").

---

## ADDED Requirements

### Requirement: Fallback a `C19` (gasto) y `C03` (ingreso) por ID estable

Cuando la categorización automática NO produce sugerencia (LLM deshabilitado, sin respuesta, o con confidence por debajo del umbral configurado), el sistema MUST resolver la categoría usando los IDs constantes:

- `kFallbackExpenseCategoryId = 'C19'` (Otros Gastos) para filas tipo `expense`/`fee`.
- `kFallbackIncomeCategoryId = 'C03'` (Otros Ingresos) para filas tipo `income`.

Estos IDs MUST estar centralizados en una constante única (`lib/core/constants/fallback_categories.dart`) referenciada por todos los call sites. El sistema NO MUST seleccionar la primera categoría de la lista cuando exista la categoría neutral.

#### Scenario: Movimiento sin sugerencia LLM cae en C19

- GIVEN una fila `expense` cuyo merchant no pudo categorizar el LLM
- WHEN se resuelve la categoría de fallback
- THEN la fila queda asignada a `C19 (Otros Gastos)`
- AND NO queda en `C10 (Alimentación)` (que era el bug previo por ser `.first`)

#### Scenario: Ingreso sin sugerencia LLM cae en C03

- GIVEN una fila `income` cuyo origen no pudo categorizar el LLM
- WHEN se resuelve la categoría de fallback
- THEN la fila queda asignada a `C03 (Otros Ingresos)`

---

### Requirement: Prompt LLM permite y favorece la respuesta neutral

El prompt de `AutoCategorizationService` MUST instruir explícitamente al modelo para devolver `categoryId: 'C19'` (gasto) o `'C03'` (ingreso) cuando NO esté seguro de la categoría correcta. El prompt MUST listar estos IDs como opciones válidas dentro del set de categorías candidatas. El sistema MUST preservar el threshold de confianza existente sin introducir un campo nuevo: si la respuesta del modelo viene por debajo del threshold, el call site MUST descartar la sugerencia y aplicar el fallback constante.

#### Scenario: Merchant claro → LLM sugiere específica

- GIVEN una fila con merchant `"Uber"` y descripción clara
- WHEN se ejecuta categorización
- THEN el LLM devuelve `categoryId = 'C12' (Transporte)` con confidence alta
- AND la fila queda asignada a `C12`, NO al fallback

#### Scenario: Merchant ambiguo → LLM elige neutral

- GIVEN una fila con merchant `"Pago varios"` sin contexto
- WHEN se ejecuta categorización
- THEN el LLM devuelve `categoryId = 'C19'` por instrucción del prompt
- AND la fila queda asignada a `C19`

#### Scenario: Confidence bajo → call site descarta y aplica fallback

- GIVEN una fila donde el LLM devuelve `categoryId = 'C10'` con confidence bajo el threshold
- WHEN el call site procesa la sugerencia
- THEN la sugerencia se descarta
- AND la fila queda asignada a `C19` (fallback constante por tipo)

---

### Requirement: Last-resort `.first` si la categoría seed fue eliminada

Si el ID de fallback (`C19` o `C03`) NO existe en la lista de categorías del usuario (porque el usuario lo borró o renombró el ID), el sistema MUST caer en `.first` de la lista filtrada por tipo. Esto preserva el comportamiento previo y evita crashes. La caída a `.first` MUST ser SILENCIOSA (sin error visible al usuario) y registrar warning en logs si la infraestructura de logging existe.

#### Scenario: Usuario borró Otros Gastos

- GIVEN el usuario eliminó la categoría `C19` de su lista
- AND una fila `expense` necesita fallback
- WHEN se resuelve la categoría
- THEN el sistema cae en la primera categoría tipo expense disponible (`.first`)
- AND la fila se asigna sin crashear el flujo

#### Scenario: Categoría neutral existe → no usa .first

- GIVEN el usuario tiene `C19` y `C03` en su lista (caso por defecto)
- WHEN se resuelve fallback para una fila expense
- THEN se usa `C19`, no `.first`

---

### Requirement: Misma resolución en ambos call sites

La lógica de resolución de fallback MUST ser idéntica en:

- `lib/app/transactions/auto_import/proposal_review.page.dart` (función `_resolveFallbackCategoryForType`).
- `lib/app/accounts/statement_import/screens/confirm.page.dart` (función `_resolveCategoryForKind`).

Ambas funciones MUST importar la misma constante de `core/constants/fallback_categories.dart` y aplicar la misma cadena de resolución (constante → `.first` last resort). NO MUST haber drift entre los dos sitios.

#### Scenario: Pendiente de notificación y screenshot import resuelven igual

- GIVEN una fila `expense` ambigua proveniente del flujo de notificación SMS
- AND una fila `expense` ambigua proveniente del flujo screenshot
- WHEN ambas resuelven fallback
- THEN ambas terminan asignadas a `C19`
