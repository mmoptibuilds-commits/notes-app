# Manual mobile-data smoke test

Proves that a phone on mobile data and Linux exchange notes in both directions
through the deployed **test** Worker, with LAN sync off. It uses synthetic
notes and the isolated `Notes (cloud test)` app (`com.mmoptibuilds.notes.cloudtest`).
It never touches the live Notes app, real notes or the production Worker.

The phone steps need no ADB. Only `setup` and the start of `run` use it.

## Setup (ADB, phone on Wi-Fi)

```sh
tool/cloud_manual_smoke.sh setup "<adb-serial>" https://notes-sync-test.mmoptibuilds.workers.dev
```

This builds a debug APK, checks that its package id is exactly
`com.mmoptibuilds.notes.cloudtest`, removes any older copy of **that package
only**, and installs it empty. The test Worker deployment is the only server it
knows about. Tailscale and any VPN on the phone must be off.

## Run

Start the Linux half. It resets the test library, uploads two synthetic notes,
one folder and one image, then waits up to 40 minutes for the phone:

```sh
tool/cloud_manual_smoke.sh run "<adb-serial>" https://notes-sync-test.mmoptibuilds.workers.dev
```

Linux prints `SMOKE` lines. Follow them on the phone:

1. Open **Notes (cloud test)**. Settings, **Cloud sync**, **Sign in with
   Google**. The browser shows the test sign-in page: tap **Sign in as owner**
   (the other link must be refused; do not use it). You return to the app. If
   the browser stays on a page that says "Return to Notes", tap **Continue**.
2. Still on Wi-Fi: **Check this device**, then **Join**. Two notes, a folder
   and an image arrive (`Smoke note one`, `Smoke note two`).
3. Turn Wi-Fi off and confirm the status bar shows mobile data only. ADB
   disconnects here; that is expected and does not stop the test.
4. Create a new note whose title contains `PHONE-MOBILE`.
5. Linux prints `RECEIVED PHONE-MOBILE ...` and whether the phone still answers
   on the LAN (it must not). Linux then creates `LINUX-REPLY`.
6. Wait up to a minute for `LINUX-REPLY` to appear on the phone (use **Sync
   now** in Cloud sync if it is slow). Then create a note whose title contains
   `PHONE-SAW-REPLY`.
7. Linux prints `PASS both directions through the deployed test Worker` and
   signs out. If it prints a `WARNING` or times out, the test did not pass.

Afterwards: in **Cloud sync** on the phone use **Sign out of this device**,
turn Wi-Fi back on, and uninstall `Notes (cloud test)` if you no longer need it.
The test Worker keeps the synthetic records until the next reset.

## What it covers and does not

Covers: sign-in through the deployed test Worker, join, both directions, image
transfer, no LAN path (LAN sync is asserted off on Linux and the phone is
checked to be unreachable on the LAN), and that the phone's notes are present
on the server.

Does not cover: the real Google consent screen, the production Worker, a
second Google account, or a Linux machine on an internet connection other than
the home router. For this test the phone is on its mobile network and Linux is
on the home Wi-Fi, which are different networks only while the phone's Wi-Fi is
off.
