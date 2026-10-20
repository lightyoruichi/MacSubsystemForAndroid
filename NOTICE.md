# Notices

Mac Android Subsystem is free software under the GNU General Public License v3 or later (see LICENSE).

It includes or downloads the following software, each under its own licence:

| Component | Licence | How it is used | Source |
|---|---|---|---|
| QEMU | GPL-2.0 (some parts GPL-2.0-or-later, LGPL, BSD) | Bundled in `Contents/Helpers` and run as a separate program, built from source with SDL audio, with its libraries from Homebrew (glib, pixman, libslirp, SDL and others, under their own licences) | https://www.qemu.org/download/ (the version is in `Contents/Resources/qemu/QEMU-VERSION`) |
| EDK II (edk2-aarch64-code.fd) | BSD-2-Clause-Patent | UEFI firmware for the virtual machine | https://github.com/tianocore/edk2 |
| scrcpy server 5.0.1 | Apache-2.0 | Bundled as `scrcpy-server.jar` and run inside Android for app windows | https://github.com/Genymobile/scrcpy |
| LineageOS | Apache-2.0, GPL-2.0 (Linux kernel) and others | Downloaded on first launch as the Android image | https://github.com/LineageOS |

The client side of the scrcpy protocol (`apple/Shared/Scrcpy`) is an independent implementation written for this project from scrcpy's protocol documentation.

The idea of running LineageOS's `virtio_arm64only` target under QEMU on Apple silicon, and the QEMU options used, come from LineageOS's UTM and libvirt guides and from [jqssun/android-lineage-qemu](https://github.com/jqssun/android-lineage-qemu).

The Android robot (in the app icon, the menu bar icon and the website) is reproduced or modified from work created and shared by Google and used according to terms described in the Creative Commons 3.0 Attribution License (https://creativecommons.org/licenses/by/3.0/).

Android is a trademark of Google LLC. Mac and macOS are trademarks of Apple Inc. This project is not affiliated with or endorsed by any of them, or by the LineageOS project.
