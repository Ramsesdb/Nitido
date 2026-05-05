import 'package:flutter_test/flutter_test.dart';
import 'package:nitido/core/services/auto_import/profiles/bank_profiles_registry.dart';
import 'package:nitido/core/services/auto_import/supported_banks.dart';

/// Guards the contract that every [SupportedBank] entry declared with
/// `hasDedicatedParser: true` is actually backed by a registered profile in
/// [bankProfilesRegistry].
///
/// The flag is a promise to the rest of the system that a fast regex parser
/// exists for that bank. A stale `true` results in silent degradation: the
/// runtime falls back to the GenericLlmProfile while the UI claims a dedicated
/// parser is in use. The match is keyed on `profileId`, which is the stable
/// identifier shared between [SupportedBank.profileId] and
/// [BankProfile.profileId] in the registry.
void main() {
  test('every SupportedBank with hasDedicatedParser=true is registered in '
      'bankProfilesRegistry by profileId', () {
    final registeredProfileIds = bankProfilesRegistry
        .map((p) => p.profileId)
        .toSet();

    final missing = <String>[];
    for (final bank in kSupportedBanks) {
      if (!bank.hasDedicatedParser) continue;
      if (!registeredProfileIds.contains(bank.profileId)) {
        missing.add('${bank.displayName} (profileId=${bank.profileId})');
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'The following banks are declared with hasDedicatedParser=true in '
          'kSupportedBanks but have no matching profile registered in '
          'bankProfilesRegistry:\n'
          '  - ${missing.join("\n  - ")}\n'
          'Either register a BankProfile with the same profileId, or set '
          'hasDedicatedParser=false so the GenericLlmProfile fallback is '
          'used honestly.',
    );
  });
}
