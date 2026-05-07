/// Compile-time feature flags for incremental rollout of the
/// `screenshot-import-improvements` change.
///
/// Flags are intentionally `const` so unused branches are tree-shaken by the
/// Dart compiler. Flip values directly in this file (no env / runtime flag
/// system in the project as of this change).
library;

/// Enables multi-image capture/processing in the statement-import flow.
/// Default `false` until the feature lands smoke-tested. When `false`,
/// capture and processing keep their pre-existing single-image behaviour.
const bool kEnableMultiImageImport = false;

/// Enables the auto-adjust of `account.trackedSince` at import time when
/// approved rows include pre-fresh transactions. Default `true`: low risk,
/// reuses the retroactive confirmation dialogs already shipped by
/// `account-pre-tracking-period`.
const bool kEnablePreFreshAutoAdjust = true;
