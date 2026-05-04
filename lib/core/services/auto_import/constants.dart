/// Shared constants for the auto-import subsystem.
library;

/// Maximum allowed length for a raw notification text (title + content).
///
/// Empirical observation: real banking notifications from
/// BDV / Banesco / Mercantil are consistently < 500 characters.
/// 4 096 is ~8× the worst-case real notification — generous enough for
/// legitimate spam while rejecting pathological payloads that could
/// exhaust memory or burn LLM tokens.
const int kMaxNotificationLength = 4096;

/// Maximum time to wait for an LLM completion call before giving up.
///
/// Nexus (via Groq) typically responds in < 2 s.  BYOK providers
/// (OpenAI / Anthropic direct) may take 5–10 s.  15 s is conservative
/// enough to avoid false positives while still catching genuine hangs.
const Duration kLlmCallTimeout = Duration(seconds: 15);
