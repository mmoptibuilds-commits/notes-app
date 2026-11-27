---
name: notes-release
description: Prepare or verify a Notes release candidate and preserve Android and Linux update trust.
---

Follow [the stable release procedure](../../../docs/RELEASE.md). Record the exact commit, verify CI, and use the lockfiles. Before selecting a build number, check the last distributed version and installed versionCodes read-only. Run `dart tool/check_stable_version.dart --stable` for the next candidate.

- Use the existing Android certificate and pinned public fingerprint. Verify the arm64 APK with `tool/verify_release_apk.dart`. Verify the Linux archive and checksum.
- Verify the signed manifest against the finished bytes and pinned public key. Keep exactly one release asset whose name contains `apk`. Record artifact hashes and verification results.
- The owner handles private signing material. Use a disposable emulator for install checks and the isolated test Worker for cloud checks. Follow owner approval rules for publishing, tagging, pushing or merging to main, and installing on the owner's devices.
