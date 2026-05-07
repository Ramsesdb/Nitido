# Delta for statement-import — multi-image session

Bootstraps el dominio `statement-import` (no existe spec previo). Cubre la captura, extracción y revisión multi-imagen del flujo "subir foto del estado de cuenta".

---

## ADDED Requirements

### Requirement: Captura acepta hasta 10 imágenes por sesión

La pantalla de captura MUST permitir agregar hasta 10 imágenes por sesión de import, desde cámara, picker de archivos, o una mezcla de ambos. El cap MUST ser fijo en 10 (no configurable por usuario en v1). Al alcanzar el cap, los controles para añadir más imágenes MUST quedar deshabilitados con mensaje i18n indicando el límite. Rasterización de PDF MUST extender a TODAS las páginas, contando cada página rasterizada contra el cap de 10.

#### Scenario: Usuario sube 3 fotos de cámara

- GIVEN el usuario abre la pantalla de captura
- WHEN toma 3 fotos consecutivas con la cámara
- THEN la UI muestra contador "3 imágenes" y permite continuar a procesamiento

#### Scenario: PDF de 12 páginas excede el cap

- GIVEN el usuario selecciona un PDF de 12 páginas vía file picker
- WHEN se rasteriza el PDF
- THEN se generan 10 page-images (las primeras 10) y se descarta el resto
- AND la UI muestra advertencia i18n "Solo se procesarán las primeras 10 páginas"

#### Scenario: Mezcla de cámara y file picker

- GIVEN el usuario ya capturó 4 fotos con cámara
- WHEN selecciona 2 imágenes adicionales vía file picker (con `allowMultiple: true`)
- THEN la sesión acumula 6 imágenes en total
- AND el contador refleja "6 imágenes"

---

### Requirement: Pivot date por imagen con auto-detección EXIF

Cada imagen MUST conservar su propio `pivotDate` (usado por el extractor para resolver "HOY"/"AYER"). El sistema MUST intentar leer la fecha EXIF de cada imagen. Si la imagen tiene EXIF date válida, MUST usarla automáticamente. Si la imagen NO tiene EXIF date (o falla la lectura), el sistema MUST preguntar al usuario por la fecha de esa imagen ANTES de proceder a la extracción. La UI MUST permitir al usuario sobrescribir el `pivotDate` de cualquier imagen (incluyendo las auto-detectadas) desde la pantalla de captura.

#### Scenario: Imagen con EXIF date se auto-resuelve

- GIVEN el usuario selecciona una foto con EXIF date `2026-05-04`
- WHEN avanza a procesamiento
- THEN la imagen se procesa con `pivotDate = 2026-05-04` sin interacción adicional

#### Scenario: Imagen sin EXIF requiere prompt

- GIVEN el usuario selecciona 3 imágenes, una de ellas sin EXIF date
- WHEN intenta avanzar a procesamiento
- THEN el sistema muestra un date picker para la imagen sin EXIF antes de continuar
- AND la extracción NO inicia hasta que la fecha esté provista

#### Scenario: Usuario sobrescribe pivot auto-detectado

- GIVEN una imagen con EXIF date `2026-05-04`
- WHEN el usuario edita el pivot en la captura y elige `2026-05-05`
- THEN la imagen se procesa con `pivotDate = 2026-05-05`

---

### Requirement: Pipeline serial con aislamiento de fallos

El procesamiento MUST iterar sobre las imágenes en serie, llamando a `extractFromImage(imageBase64, pivotDate)` una vez por imagen. La UI MUST mostrar progreso "procesando N de M". Si una imagen falla la extracción (timeout, error LLM, parse error), el pipeline MUST continuar con las siguientes; el índice fallido MUST registrarse en una lista `failedImageIndices` propagada hasta la pantalla de revisión. La sesión NO MUST abortar a menos que TODAS las imágenes fallen.

#### Scenario: Las 5 imágenes extraen exitosamente

- GIVEN el usuario procesa 5 imágenes válidas
- WHEN finaliza la extracción
- THEN se muestran las filas de las 5 imágenes concatenadas en revisión
- AND `failedImageIndices` está vacío

#### Scenario: 1 de 4 imágenes falla, las otras continúan

- GIVEN el usuario procesa 4 imágenes y la imagen #2 retorna error de extracción
- WHEN finaliza la sesión
- THEN se muestran las filas de las imágenes 1, 3 y 4 en revisión
- AND `failedImageIndices = [1]` (índice 0-based de la imagen #2)

#### Scenario: Todas las imágenes fallan

- GIVEN el usuario procesa 3 imágenes y las 3 fallan extracción
- WHEN finaliza la sesión
- THEN el sistema muestra error global y permite reintentar o cancelar
- AND no avanza a la pantalla de revisión

---

### Requirement: Dedupe in-session antes de revisión

Antes de pasar las filas extraídas al `MatchingEngine`, el sistema MUST deduplicar filas dentro de la sesión por la tupla `(amount, currency, date±4h, counterpartyName)`. Si dos filas comparten amount, currency, counterparty y sus fechas difieren por menos de 4 horas, MUST conservar UNA sola (la de mayor confidence; en empate, la primera por orden de aparición). El dedupe in-session MUST ocurrir ANTES del dedupe contra DB del MatchingEngine, no después.

#### Scenario: Dos screenshots del mismo movimiento se colapsan

- GIVEN imagen A contiene una fila `(50 USD, "Pago Uber", 2026-05-04 14:32)`
- AND imagen B contiene una fila `(50 USD, "Pago Uber", 2026-05-04 14:35)`
- WHEN el pipeline dedupe in-session
- THEN solo UNA fila llega al MatchingEngine
- AND la fila conservada es la de mayor confidence

#### Scenario: Mismo monto con counterparty distinto NO se colapsa

- GIVEN imagen A contiene `(50 USD, "Pago Uber", 2026-05-04 14:32)`
- AND imagen B contiene `(50 USD, "Compra Amazon", 2026-05-04 14:32)`
- WHEN el pipeline dedupe in-session
- THEN ambas filas se preservan

#### Scenario: Misma fila con fechas a >4h de distancia NO se colapsa

- GIVEN imagen A contiene `(50 USD, "Uber", 2026-05-04 08:00)`
- AND imagen B contiene `(50 USD, "Uber", 2026-05-04 14:00)` (6h después)
- WHEN el pipeline dedupe in-session
- THEN ambas filas se preservan

---

### Requirement: Revisión muestra imágenes fallidas

La pantalla de revisión MUST mostrar visualmente cuáles imágenes (si hay) no extrajeron filas. Para cada índice en `failedImageIndices`, MUST renderizar un chip o banner i18n indicando "Imagen N falló al extraer" sin bloquear la confirmación de las filas exitosas. El usuario MUST poder confirmar las filas extraídas aun habiendo fallos parciales.

#### Scenario: Revisión con 1 imagen fallida

- GIVEN una sesión donde la imagen #3 falló extracción
- WHEN el usuario llega a revisión
- THEN ve un chip "Imagen 3 no se pudo procesar"
- AND puede aprobar y confirmar las filas de las imágenes 1, 2, 4, 5 normalmente
