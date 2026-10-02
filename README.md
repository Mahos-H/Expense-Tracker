# Expense Tracker

An Android application that reads HDFC Bank debit SMS and turns them into a
running ledger, without a network connection of any kind. This document
explains what the app does, why it's built the way it is, how its data
safety mechanisms work, and how to build and run it. If you're looking for
a history of changes rather than current behavior, see `CHANGELOG.md`.

## Why it works this way

Your bank already texts you every time money leaves your account. This app
reads that text instead of asking you to photograph receipts, manually log
spending, or connect your account through a third-party aggregator that
has no reason to see your financial data. That one decision drives almost
everything else about the design: if the app only ever needs to react to a
single SMS as it arrives, it doesn't need a background service, it doesn't
need your inbox history, and it has no reason to touch a network at all.
It's a SQLite file and a broadcast receiver that wakes up for a fraction of
a second when a message comes in, and nothing else.

## Confirming there's no internet involved

Rather than asking you to take this on faith: `AndroidManifest.xml`
declares `RECEIVE_SMS` as its only permission in normal builds (see
"Build variants" below for the one exception). There is no `INTERNET`
permission anywhere, and Android does not allow an app to open a network
socket without it — this isn't a setting that could be quietly changed
later; the manifest would have to be edited and the app rebuilt.
`pubspec.yaml` lists three dependencies — `sqflite`, `path`, `intl` — none
of which talk to a server. A search of every `.dart` and `.kt` file in the
project for anything network-shaped turns up nothing except the XML
namespace URL every Android manifest includes by convention, which is an
identifier string, not a request. The one caveat: `flutter run` itself
talks to your computer over USB for hot reload during development. That's
Flutter's tooling, not the app, and it stops applying the moment you
install a built APK instead.

## How the SMS pipeline works

When a text arrives, Android broadcasts `SMS_RECEIVED` system-wide. This
app has a manifest-registered receiver for that broadcast, which Android
will deliver even if the app hasn't been opened in weeks — there's no
polling and nothing resident in memory between messages.

The receiver checks whether the sender ID contains a configurable marker
string (`HDFC` by default). If it matches, the message body is tested
against a regular expression expecting something like:

```
Sent 145.00 From HDFC Bank A/C x0889 To BOTTLE LAB TECHNOLOGIES P On 16/08/26
```

The amount and the receiver name are pulled out as capture groups; anything
else in the message is ignored. A message from a matching sender that
doesn't fit the pattern is logged rather than dropped, so you can see what
didn't get tracked and why.

Long messages split by the carrier into multiple SMS parts are reassembled
before parsing. Every transaction derived from an SMS carries a fingerprint
built from the sender, the SMS's own timestamp, the amount, and the
receiver, enforced as unique in the database — if Android ever redelivers
the same broadcast, which does happen occasionally, the duplicate is
dropped rather than recorded twice.

The date and time on an SMS-derived entry come from the SMS itself, not
from whenever the app got around to processing it, and that field is
locked from editing for exactly that reason — it's meant to be a fact
about when the bank moved the money. The amount and receiver name on the
same entry remain fully editable.

## Previous Expense — the anchor entry

Every install starts with one entry, "Previous Expense," set to ₹0.00. It
represents whatever your account held before this app started tracking.
If you're starting from zero, leave it alone; if you've been spending for a
while, set it to whatever your account actually holds.

It also absorbs history as the entry cap (below) prunes old transactions —
when an entry is pruned, its amount is added into this one, so the
all-time total is never affected by pruning, even though the individual
transaction's detail is gone. This is also why the entry can't be deleted:
the pruning mechanism depends on it always existing.

## The 300-entry cap

The app keeps the most recent 300 transactions in full detail and folds
anything older into Previous Expense as described above. 300 is a size
chosen to keep the database small and the app fast without real upkeep;
it has no particular significance beyond that.

## The forms in the app

**Entries.** Every entry, however it was created, has an amount, a
debit/credit toggle, a receiver name, and a date (locked for SMS-derived
entries, as above; free for manual and anchor entries, including dates up
to five years in the future, which is deliberately permissive — forward
budgeting isn't something the app tries to prevent). Editing or deleting an
existing entry asks for confirmation first.

**Rename rules.** Map a receiver name exactly as it appears in the SMS to
whatever you'd rather see — the default turns `BOTTLE LAB TECHNOLOGIES P`
into `Lunch`. Rules can be applied retroactively to existing entries.

**Parser settings.** The sender filter and the parsing regex are both
editable here, with a test box that shows what the current pattern
extracts from a pasted sample before you commit to it. The regex needs its
first capture group to be the amount and its second to be the receiver; a
pattern that fails to compile on-device falls back to the built-in default
rather than silently halting tracking, and a note is logged when that
happens. This screen also shows the last time the receiver observed any
SMS at all, independent of whether that message was tracked — useful for
telling apart "nothing is arriving" from "things are arriving but not
parsing."

## The trend graph

A cumulative running-total line, for Today / Week / Month / Year / All /
Custom. The line starts wherever the account's balance already stood going
into that window and only plots real entries — it never draws a flat line
out to the edges of the selected range or invents data between the last
real entry and the present moment. The Y-axis is scaled to the actual
values in the selected window rather than a fixed ₹0 baseline, since a
fixed baseline would flatten realistic daily movement against a much
larger running total.

## Database naming and versioning

The SQLite filename is not fixed. It's generated as
`expense_tracker_<versionName>.db`, where `<versionName>` is read directly
from the app's own installed package metadata (the `versionName` field in
`android/app/build.gradle.kts`) at the moment the database is opened. The
Dart side asks the native side for this filename over a platform channel
rather than keeping its own separately-maintained copy of the version
string, specifically so the two sides cannot disagree about which file to
open.

The practical effect: if a version bump results in Android updating the
app in place, the previous version's database file is left exactly where
it was, untouched, because the new version is looking for a differently
named file. You keep both on disk, and nothing auto-migrates between them
without you doing it deliberately (see "Recovering data" below).

Be clear-eyed about what this does and doesn't protect against. It only
helps when the OS performs an in-place update. A full uninstall — whether
triggered by you, by a signing-certificate mismatch between builds (see
"Build signing" below), by "Clear storage" in Android's app settings, or
by a factory reset — wipes the entire private storage directory regardless
of what any file inside it is named. Filename versioning is a convenience
for the common case, not a backup strategy. The next section is the actual
backup strategy.

## Backups and recovering data

**Automatic daily backup.** At most once per calendar day, the app makes a
clean snapshot of its live database using SQLite's own `VACUUM INTO`
command — this guarantees the snapshot can never be a half-written or
corrupt copy, regardless of what the app was doing at the moment the
backup ran — and copies that snapshot to your phone's public Downloads
folder as `expense_tracker_daily_backup.db`. Downloads is genuinely outside
the app's private storage, so this file survives even a full uninstall.
The check runs both when the app is opened and whenever the SMS receiver
fires, so a backup can still happen on a day the app itself is never
opened.

**Manual export.** Parser Settings has an "Export now" button that performs
the same `VACUUM INTO` snapshot on demand, saved to Downloads under a
timestamped filename so repeated exports never overwrite one another. Use
this immediately before anything that might risk the app's storage — a
version bump, a rebuild after dependency or Gradle changes, switching
build flavors — rather than relying solely on the daily schedule.

**Pulling a backup off the phone.** If you need the file on your computer,
use `adb exec-out`, not `adb shell`:
```
adb exec-out run-as com.expensetracker.hdfc cat databases/<filename>.db > local_copy.db
```
`adb shell` (without `exec-out`) pipes its output through a pseudo-terminal
that rewrites certain byte sequences — harmless for text, but it corrupts
binary files like a SQLite database. This cost real data during
development before the cause was identified. Files already in Downloads
(daily backups, manual exports) don't need `run-as` at all — they're public
storage, so a plain `adb pull` works.

**Restoring a backup into a running install.** The database filename
depends on the installed `versionName`, so a restored file has to be
renamed to match whatever the current build expects:
```
adb shell am force-stop com.expensetracker.hdfc
adb push your_backup.db /data/local/tmp/expense_tracker_<versionName>.db
adb shell run-as com.expensetracker.hdfc mkdir -p databases
adb shell run-as com.expensetracker.hdfc cp /data/local/tmp/expense_tracker_<versionName>.db databases/expense_tracker_<versionName>.db
adb shell rm /data/local/tmp/expense_tracker_<versionName>.db
adb shell am start -n com.expensetracker.hdfc/.MainActivity
```
Force-stopping first matters — it ensures nothing holds the database file
open while you overwrite it underneath the running process.

## Recovery tooling (Import from SMS)

A separate, deliberately isolated screen exists for the case where
transactions were missed or data needs reconstructing from scratch: it
scans the device's SMS inbox directly — not just new arrivals — for any
message containing "HDFC," regardless of sender, across a chosen date
range, and runs each one through the same parsing logic the live receiver
uses. Anything already present is skipped automatically by the existing
uniqueness constraint, so running the scan again over an overlapping range
never creates duplicates.

This requires `READ_SMS`, a materially broader grant than the app's normal
`RECEIVE_SMS` — it can read the entire inbox, not just react to new
messages. Because that's a real increase in what the app can see, it's
walled off at the build level rather than simply hidden behind a UI toggle:

## Build variants

The project defines two Gradle product flavors, sharing one application
ID:

- **`standard`** — the day-to-day build. Declares only `RECEIVE_SMS`.
  `READ_SMS` does not exist anywhere in this build's compiled manifest.
- **`recovery`** — adds `READ_SMS` via a flavor-specific manifest fragment,
  and exposes the Import from SMS screen when also built with
  `--dart-define=ENABLE_SMS_IMPORTER=true`.

Once any flavor is defined, Gradle requires one to be specified on every
build — there is no longer a flavor-less `flutter run`:
```
flutter run --flavor standard
flutter run --flavor recovery --dart-define=ENABLE_SMS_IMPORTER=true
```
Use `standard` unless you specifically need the import tool.

## Build signing

By default, `flutter run` signs the app with a debug key that Android's
tooling generates automatically on your machine. That key is not
guaranteed to stay fixed — it can change across a toolchain reinstall, a
different machine, or other environment changes — and if it does, the next
build's signature no longer matches what's installed, which forces Android
to uninstall before reinstalling, wiping all app data as a side effect.
This is believed to be the root cause of a real data-loss incident during
development (see `CHANGELOG.md`, Section 10).

The project optionally supports a stable, self-managed keystore
(`android/key.properties`, excluded from version control) that both the
debug and release build types sign with when present, so the signature
stays identical across machines and over time regardless of what happens
to any individual machine's auto-generated debug key. If `key.properties`
is absent, the build falls back to normal Android Gradle Plugin defaults
without issue — this is an optional hardening step, not a requirement to
build the project.

If you set this up: back up the `.jks` file itself in more than one place.
Losing it doesn't put your data at risk — the backup mechanisms above are
independent of signing entirely — but it does mean the next build after
that point will itself be a one-time forced reinstall, since a replacement
keystore is, by definition, a different signature.

## Known limitations

**Receiver names cut short at a fixed length are not a bug in this app.**
Investigation (comparing the stored receiver name against the original SMS
text, which is viewable on an SMS-derived entry's edit screen) confirmed
that some payee names arrive already truncated inside the bank's own SMS.
The full name was never present in the source message, and no parsing
change can recover text that wasn't sent.

**OEM background restrictions can silently stop SMS from being tracked.**
Some Android manufacturers — Samsung, Xiaomi, and others are commonly
reported — apply their own background-process limits on top of stock
Android, independent of whether `RECEIVE_SMS` is granted. If tracking
stops after the app hasn't been opened for a while, check your device's
battery optimization and autostart settings for this app specifically; this
is outside anything the app itself can control.

**Timestamps carry no timezone metadata**, stored as local time at the
moment of arrival. Entries logged before a timezone change will not
retroactively adjust.

**The Parser Settings test box and the live receiver use different regex
engines** (Dart's for the in-app preview, Kotlin's on-device). They agree
on virtually any pattern an ordinary person would write; if you're doing
something unusual with the syntax, confirm against a real message
afterward via the activity log rather than trusting the preview alone.

## Security posture, summarized

One permission in normal builds (`RECEIVE_SMS`), requested through a
purpose-built platform channel rather than a bundled plugin that would ask
for more than this app needs. The manifest receiver requires the sender to
hold `BROADCAST_SMS`, which only the operating system holds, so no other
app can forge a fake SMS broadcast into this one. `allowBackup` is
disabled, keeping data out of `adb backup` and automatic cloud backup. No
networking capability exists anywhere in the app for anything to leak
through even if something else went wrong.

## Setup

You need the Flutter SDK, Android Studio (for the Android SDK and an
emulator), and a way to test on a device. Full platform-by-platform
installation steps are in `CHANGELOG.md`'s companion setup notes if you're
starting from nothing; the short version, once Flutter and Android Studio
are installed and `flutter doctor` is clean:

```
flutter pub get
flutter run --flavor standard
```

Grant SMS permission when prompted on first launch — that, plus `READ_SMS`
only if you build the `recovery` flavor, is everything the app will ever
ask for.

To produce an installable APK:
```
flutter build apk --flavor standard --release
```
found afterward at
`build/app/outputs/flutter-apk/app-standard-release.apk`.