# Inventar+

**Stock management with barcode scanning, low-stock alerts and SMS notifications.**
No server. No internet. No accounts.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Flutter](https://img.shields.io/badge/Flutter-3.10%2B-02569B?logo=flutter)](https://flutter.dev)
[![Android](https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android)](https://www.android.com)

---

## What is Inventar+?

Inventar+ is an open-source Flutter app for Android that keeps the stock of a small shop,
warehouse or workshop on the phone. You add products by scanning their barcode, and the app
warns you when a product drops below its alert threshold or minimum stock. It can text clients
or suppliers, and keep a second phone in sync. Everything runs on the phone, with no server and
no internet connection.

---

## Features

- **Barcode scanning** with the phone camera to add and find products
- **Stock alerts** when a product drops below its alert threshold or its minimum stock
- **SMS notifications** to clients or suppliers, with an editable message template
- **Two-phone sync over SMS** with a partner phone
- **Reports** for any period, including what was moved or deleted from stock
- **Backup and restore**, daily and manual, to phone storage or a USB stick
- 30-day free trial, then an activation license (see [Free Trial & Activation License](#free-trial--activation-license))

---

## How It Works

```
Scan a barcode        →  product added or found in stock
Stock drops below min →  local alert (and SMS, if set up)
Change on one phone   →  sent over SMS to the partner phone
```

SMS sending, sync, backup and license import run natively on Android (Kotlin, in
`android/app/src/main/kotlin`).

---

## Free Trial & Activation License

The complete source code, including the 30-day trial check, is published here under the AGPL-3.0.
**The code is not sold**, and the rights the AGPL gives you (to use, study, modify and redistribute it)
don't depend on buying anything.

What is sold is an **activation license**: a signed file, tied to one install code (Business ID),
that unlocks the app after the 30-day free trial in the Inventar+ app distributed by Volt Academy
(the Android APK available at [voltacademy.app/inventarplus.html](https://voltacademy.app/inventarplus.html)).

| Period | Requirement |
|---|---|
| First 30 days after install | Free, all features |
| After the trial | Activation license — 30, 60 or 180 days, or permanent |

Licenses are bought at [voltacademy.app/inventarplus.html](https://voltacademy.app/inventarplus.html#licentiere),
where current prices are listed. Expirable licenses bought for the same install code add up, and the
license becomes permanent automatically once their total reaches the price of a permanent license.

To activate a license:

1. Open the **Licență** screen in the app and copy the **Cod de instalare** (install code).
2. Buy a license on the site with that code and download `inventarplus_license.json`.
3. Back on the **Licență** screen, tap **Selectează fișierul de licență** and pick the downloaded file.

One license covers two synced phones. Once sync is set up, tap **Trimite licența la telefonul partener**
and the license is sent over SMS to the second phone.

Questions about licenses: [voltacademy.app/contact.html](https://voltacademy.app/contact.html)

---

## Platform Support

Inventar+ is built for **Android** only. SMS, sync, backup and license import use Android
platform channels.

---

## Getting Started

### Requirements
- Flutter SDK 3.10+
- Android SDK (minSdk 24 — Android 7.0)

### Run

```bash
git clone https://github.com/adyptc-prog/inventarplus.git
cd inventarplus
flutter pub get
flutter run
```

### Test

```bash
flutter test
dart analyze
cd android && ./gradlew :app:testDebugUnitTest
```

### Build release APK

```bash
flutter build apk --release
```

Release builds are signed with the keystore described in `android/key.properties`, which is not
part of this repository. To build your own release, create that file for your own keystore.

---

## Author

**Adrian Petcu** — [Volt Academy](mailto:adyptc@gmail.com)

---

## Contributing

Pull requests are welcome. For major changes, open an issue first.

All contributions must be compatible with the AGPL-3.0 license.

---

## License

**Inventar+ — Stock Management App**<br>
Copyright (C) 2026 Adrian Petcu — Volt Academy

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published
by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

The full text of the **GNU Affero General Public License v3.0** is in [LICENSE](LICENSE).

SPDX-License-Identifier: AGPL-3.0-or-later
