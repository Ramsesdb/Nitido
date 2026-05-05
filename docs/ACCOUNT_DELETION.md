**Account Deletion**

Nitido is an open-source personal finance Android app (AGPL-3.0) developed by Ramses Briceño. This page explains how to delete your account and what happens to your data, in compliance with Google Play Data Safety requirements.

**How to Delete Your Account**

*From within the app (recommended)*

1. Open Nitido on your Android device.
2. Go to **Settings** (Configuración).
3. Tap **Account** (Cuenta).
4. Tap **Delete account** (Eliminar cuenta).
5. Confirm the action.

The deletion is processed immediately and removes your data from Firebase services.

*If you cannot access the app*

If you have uninstalled Nitido, lost access to your device, or cannot complete the in-app flow for any reason, you can request manual deletion by email:

- **Email**: ramsesdb.dev@gmail.com
- **Subject**: `Account Deletion Request - Nitido`
- **Include**: the email address you used to sign in to Nitido.

We will verify the request and process the deletion within **30 days**, then reply to confirm.

**What Data Is Deleted**

When your account is deleted, the following are permanently removed:

- All financial transactions, categories, accounts, and budgets stored in **Firebase Firestore**.
- Your authentication record (email, display name) in **Firebase Authentication**.
- Any synced attachments (e.g. receipt images) in **Firebase Storage**.
- Device-specific identifiers used to correlate your data across Firebase services.

**What Data Is Retained**

The following datasets may be retained after account deletion, but cannot be linked back to your identity:

- **Firebase Analytics**: aggregate, anonymized usage metrics retained for up to **14 months** for app improvement (Firebase Analytics default retention).
- **Firebase Crashlytics**: crash reports retained for up to **90 days** for debugging purposes.
- **Server logs / rate-limit metadata** for the Nexus AI Gateway (`api.ramsesdb.tech`): retained up to **30 days** for abuse prevention. No transaction text is logged.

These retained datasets are anonymized and contain no personal identifiers tying them back to you.

**Local Data on Your Device**

If you delete your account but keep the app installed, the local SQLite database on your device (containing your transactions, categories, etc.) **remains on your device** until you:

- Uninstall the app, or
- Clear app data manually via **Android Settings → Apps → Nitido → Storage → Clear data**.

Local data never leaves your device unless you explicitly enable cloud sync.

**Contact**

For questions about account deletion or data privacy:

- **Developer**: Ramses Briceño
- **Email**: ramsesdb.dev@gmail.com
- **Repository**: https://github.com/Ramsesdb/Nitido
- **Privacy Policy**: [PRIVACY_POLICY.md](./PRIVACY_POLICY.md)

This document is effective as of 2026-05-05.
