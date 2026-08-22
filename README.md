# Expense_tracker

This is a small Android app that watches for Bank debit SMS and turns
them into a running ledger, without ever touching the internet. Everything
below explains why it's built the way it is, exactly how it behaves, and
where the rough edges are.

## The idea behind it

Most expense trackers ask you to either photograph receipts, connect your
bank account through a third-party aggregator, or manually log every rupee
you spend. All three are friction, and the middle one hands your financial
data to a company you've never heard of. But your bank is already texting
you every time money leaves your account. This app just reads that text.

That constraint shapes everything else about it. If the app only ever needs
to react to an SMS as it arrives, it doesn't need a background service
burning battery, it doesn't need your inbox history, and it definitely
doesn't need a network connection. So it has none of those. The whole thing
is a SQLite file on your phone and a broadcast receiver that wakes up for a
fraction of a second whenever a new message comes in.

## Confirming there's no internet involved

Rather than just asserting this, here's how to check it yourself:

- `android/app/src/main/AndroidManifest.xml` declares exactly one
  permission — `RECEIVE_SMS`. There is no `INTERNET` permission anywhere in
  the manifest, and Android will not let an app open a socket without it,
  full stop. This isn't a setting that could quietly get flipped later —
  the permission would have to be added back to the manifest and the app
  rebuilt for that to even become possible.
- `pubspec.yaml` lists three dependencies: `sqflite` (a local database),
  `path` (string manipulation for file paths), and `intl` (date and
  currency formatting). None of them talk to a server.
- A search through every `.dart` and `.kt` file in this project for
  anything network-shaped — `http`, `Socket`, `WebView`, Firebase,
  analytics SDKs — turns up nothing except the XML namespace URL that
  every single Android manifest file includes by convention (it's an
  identifier string, not a request).

The one caveat: while you're actively developing with `flutter run`, your
computer and phone talk to each other over USB or Wi-Fi so you can hot
reload — that's Flutter's tooling, not the app, and it stops mattering the
moment you build a release APK and install that instead.

## How the SMS pipeline actually works

When a text message arrives, Android broadcasts `SMS_RECEIVED` system-wide.
This app has a receiver registered for that broadcast in the manifest,
which means Android will wake the app's process for just long enough to
handle it, even if you haven't opened the app in weeks — there's no polling
loop and no persistent service sitting in memory the rest of the time.

The receiver checks whether the sender ID contains a marker string (by
default `HDFCBK`, matching the pattern Indian carriers use for bank sender
IDs like `TX-HDFCBK-S` or `VM-HDFCBK`). If it matches, the message body gets
tested against a regular expression that expects something like:

```
Sent 145.00 From HDFC Bank A/C x0889 To ABC On 16/08/25
```

The pattern pulls out the amount and the receiver name as capture groups
and ignores everything else in the message. If a message from a matching
sender doesn't fit the pattern — an OTP, a balance alert, a promotional
text — it gets logged to the Unparsed Messages screen instead of silently
vanishing, so you can see what's being missed.

Long messages that Android splits into multiple SMS parts get reassembled
into one message before parsing (grouped by sender and timestamp), so a
single transaction never gets parsed twice from its own fragments. And
every successfully parsed entry gets a fingerprint built from the sender,
the SMS's own timestamp, the amount, and the receiver name; that
fingerprint has a uniqueness constraint in the database, so if Android ever
redelivers the same broadcast — which does happen occasionally on some
phones — the duplicate gets silently dropped rather than logged twice.

The date and time recorded for an SMS-derived entry comes from the SMS
itself, not from whenever the app happened to process it. That's also why,
if you edit one of these entries later, the date field is locked — it's
meant to be a fact about when the bank moved the money, and letting it
drift would undermine the one piece of ground truth the whole system is
built on. The amount and the receiver name on that same entry, though, are
completely editable, since those are things you might reasonably want to
correct or clean up.

## Previous Expense — the anchor entry

Every fresh install seeds one entry called "Previous Expense," set to
₹0.00. It's not a real transaction; it's a placeholder for however much you
already owe or have saved that predates this app's tracking. If you start
using this the day you get your salary and your account is otherwise at
zero, you can leave it alone. If you've been spending for a while and want
the running total to reflect reality, open it from the entry list and set
its amount to whatever your account actually holds (or owes) right now.

This entry also does something less obvious: it's the container that
absorbs history once the app's 200-entry cap kicks in. The app keeps the
most recent 200 transactions in full detail — receiver name, exact SMS
text, timestamp, all of it — and once a 201st comes in, the oldest one gets
folded away. But "folded away" doesn't mean deleted from your total; its
amount gets added into Previous Expense, so the running sum across all your
entries stays exactly the same. You lose the ability to see that one old
transaction's details, but you never lose track of the money. This is why
the entry can't be deleted from the app, even though everything about it —
the amount, its date, even its label — can be edited freely.

## The 200-entry cap

If you want to see further back than that, the Previous Expense entry's date tells you when
the oldest visible entry starts mattering, and everything before it is
already accounted for in that one number.

## The forms in the app

**Adding or editing an entry.** Every entry — however it was created — has
an amount, a debit/credit toggle, a receiver name, and a date. Debit means
money left your account and counts as positive; credit means money came in
and counts as negative. For a manual entry you're free to set the date to
anything in the past, since you're usually logging something that already
happened. Editing an existing entry asks you to confirm before saving,
since it's easy to fat-finger a digit on a phone screen. Deleting works the
same way, with its own confirmation, and is available from the edit screen
itself as well as by swiping an entry left on the home list.

**Rename rules.** These let you map a receiver name exactly as it appears
in the SMS to something you'd rather see — the default rule turns "BOTTLE
LAB TECHNOLOGIES P" into "Lunch," which was presumably a specific café at
some point. Add a rule with the exact original name and whatever you want
it replaced with, and optionally have it applied retroactively to entries
that already exist. New SMS get renamed automatically going forward.

**Parser settings.** This is the one that lets you adapt the whole system
to a different bank or a different message format, if HDFC ever changes
theirs or you want to track a second account. There are two fields: which
string the sender ID has to contain, and the regular expression the
message body has to match. The regex needs its first capture group to be
the amount and its second to be the receiver — anything else in the
message is ignored. There's a test box on the same screen where you can
paste a real (or made-up) SMS and see exactly what the current pattern
would extract, before you commit to it. Worth knowing: this test box runs
on Dart's regex engine for the live preview, while the phone itself parses
incoming SMS using Kotlin's regex engine. They agree on essentially
everything a normal pattern would use, but if you're doing something
unusual with the syntax, it's worth double-checking against a real message
afterward via the Unparsed Messages screen. Also worth knowing: if you set
the sender filter too broadly — a single common letter, for instance —
you'll start catching messages from unrelated senders, so keep it as
specific as the actual sender IDs you're trying to match. If a saved
pattern ever fails to compile on the phone for some reason, the app quietly
falls back to the built-in HDFC default rather than going dark, and leaves
a note about it in Unparsed Messages so you know to go fix it.

## The trend graph

This shows a line — your cumulative running total over time — for
whichever window you pick: today, this week, this month, this year,
everything, or a custom range. The line always starts at whatever your
account had already accumulated going into that window, which is really
just the same "start at previous expenses" idea from the anchor entry
applied to a shorter timeframe. A week view doesn't start at zero; it
starts wherever last week left off.

The Y-axis is deliberately not anchored to ₹0. If your balance genuinely
sits around ₹25,000 and moves by a few hundred rupees a day, forcing the
axis to span from zero would flatten every real fluctuation into a
barely-visible wobble near the top of the chart — not something a phone
screen has the vertical pixels to show meaningfully anyway. Instead the
axis zooms to whatever range your actual values cover in that window, with
a bit of padding on top and bottom. This means the same ₹500 swing will
look dramatic in a "Today" view and barely noticeable in an "All time"
view, which is exactly the point — read the axis labels, not just the
shape of the line, when you're comparing across different windows.

One thing that trips people up: the total shown on the home screen and the
ending value of the trend graph for the same period aren't always the same
number, and that's intentional. The home screen's total is "how much
happened in this specific window" — it only counts entries whose date
falls inside the selected range. The trend graph's ending value is "what
was my running balance by the end of this window" — it includes everything
that came before, via the baseline. They're answering two different
questions.

## Known limitations

A few things worth knowing about rather than being surprised by:

If two genuinely different SMS from the same sender arrive in the exact
same millisecond, they'd get treated as fragments of one multi-part
message and concatenated before parsing, which would break the parse for
both. This is an extremely narrow window and hasn't come up in testing,
but it's a real corner case given how the multi-part reconstruction works.

All timestamps are stored in the phone's local time at the moment the SMS
arrived, with no timezone metadata attached. If you travel across time
zones, older entries will still display in whatever local time they were
recorded in, not adjusted for wherever you are now.

Some phone manufacturers — MIUI and ColorOS are the usual suspects — are
aggressive about killing background processes they consider inactive, and
that can interfere with broadcast delivery to apps you haven't opened
recently. If SMS stop being picked up after the app's been idle a while,
check your phone's battery optimization settings and exclude this app from
them. This is a manufacturer-level restriction; there's no way to code
around it from inside the app.

The parser settings put real power in your hands, which also means real
ways to misconfigure it — an overly broad sender match or a regex with the
wrong capture groups will produce garbage entries or silently miss real
ones. The test box exists specifically to let you check before you commit.

## Security choices, summarized

Only one permission is ever requested (`RECEIVE_SMS`), and it's requested
through a purpose-built platform channel rather than a bundled "SMS
permissions" plugin that would ask for read and send access too. The
manifest receiver requires the sender to hold `BROADCAST_SMS`, which only
the operating system itself holds, so no other app can forge a fake SMS
broadcast to inject fabricated entries. `allowBackup` is turned off, so
your financial data doesn't end up in `adb backup` or automatic cloud
backups. And as covered above, there's no networking capability anywhere
in the app for any of this to leak through even if something else went
wrong.

---

## Setup

You need three things on your **computer** (not your phone): the Flutter
SDK, Android Studio, and a way to test on an actual device.

### Windows

1. Download the Flutter SDK from
   `https://docs.flutter.dev/get-started/install/windows` and extract it
   somewhere with no spaces in the path — `C:\src\flutter`, not
   `C:\Program Files\`.
2. Add `C:\src\flutter\bin` to your PATH (Windows key → "env" → "Edit the
   system environment variables" → Environment Variables → Path → Edit →
   New).
3. Close and reopen any terminal windows.
4. Install Android Studio from `https://developer.android.com/studio`,
   accepting the defaults (this installs the Android SDK and emulator
   support too).
5. In a new PowerShell window, run `flutter doctor`. If it complains about
   licenses, run `flutter doctor --android-licenses` and accept them.

### macOS

1. `brew install --cask flutter` (install Homebrew from `https://brew.sh`
   first if you don't have it), or download manually from
   `https://docs.flutter.dev/get-started/install/macos`.
2. Install Android Studio from `https://developer.android.com/studio`.
3. Run `flutter doctor` in Terminal and fix anything it flags, including
   `flutter doctor --android-licenses` if needed.

### Linux

1. Download the SDK tarball from
   `https://docs.flutter.dev/get-started/install/linux`, extract it (e.g.
   to `~/development/flutter`), and add
   `export PATH="$PATH:$HOME/development/flutter/bin"` to `~/.bashrc`.
2. Install Android Studio and run through its setup wizard.
3. Run `flutter doctor` and resolve anything flagged.

Don't move on until `flutter doctor` shows the Flutter and Android
toolchain checks passing.

### Getting a device to test on

The whole point of this app is reading real bank SMS, so you'll eventually
want a real phone — emulators can't receive genuine carrier messages, only
ones you inject yourself for testing.

For a real phone: enable Developer Options (Settings → About phone → tap
Build number seven times), turn on USB debugging under Developer Options,
plug it in, and approve the debugging prompt that appears on the phone.
`flutter devices` should then list it.

For an emulator: Android Studio → Virtual Device Manager → Create device,
pick any profile and system image. Once it's running, you can simulate a
test SMS with:
```
adb emu sms send HDFCBK "Sent 145.00 From HDFC Bank A/C x0889 To BOTTLE LAB TECHNOLOGIES P On 16/08/26 Not you? Call 1800..."
```

### Building the project

The zip you have contains the customized files (`lib/`, the manifest, the
Kotlin sources) but not the generic Flutter boilerplate, which only
`flutter create` can generate correctly for your machine. From a terminal,
in whatever folder you want the project to live next to your unzipped
`Expense_tracker` folder:

```
flutter create --org com.expensetracker --project-name expense_tracker expense_tracker_app
```

Then copy the customized files on top of the placeholders it generated:

**macOS / Linux:**
```
cp -R Expense_tracker/lib/. expense_tracker_app/lib/
cp Expense_tracker/pubspec.yaml expense_tracker_app/pubspec.yaml
cp Expense_tracker/android/app/src/main/AndroidManifest.xml expense_tracker_app/android/app/src/main/AndroidManifest.xml
rm -rf expense_tracker_app/android/app/src/main/kotlin/com/expensetracker
cp -R Expense_tracker/android/app/src/main/kotlin/com/expensetracker expense_tracker_app/android/app/src/main/kotlin/com/
```

**Windows (PowerShell):**
```
Copy-Item -Recurse -Force Expense_tracker\lib\* expense_tracker_app\lib\
Copy-Item -Force Expense_tracker\pubspec.yaml expense_tracker_app\pubspec.yaml
Copy-Item -Force Expense_tracker\android\app\src\main\AndroidManifest.xml expense_tracker_app\android\app\src\main\AndroidManifest.xml
Remove-Item -Recurse -Force expense_tracker_app\android\app\src\main\kotlin\com\expensetracker
Copy-Item -Recurse -Force Expense_tracker\android\app\src\main\kotlin\com\expensetracker expense_tracker_app\android\app\src\main\kotlin\com\
```

Open `expense_tracker_app/android/app/build.gradle` and set
`namespace "com.expensetracker.hdfc"` inside the `android { }` block, and
`applicationId "com.expensetracker.hdfc"` inside `defaultConfig { }`
(alongside `minSdk 23`, `compileSdk 34`, `targetSdk 34`).

Then:
```
cd expense_tracker_app
flutter pub get
flutter run
```

Tap Grant on the orange permission banner the first time the app opens —
that's the only thing it will ever ask you for.

### Building an installable APK

Once `flutter run` works, `flutter build apk --release` produces a
standalone APK at
`expense_tracker_app/build/app/outputs/flutter-apk/app-release.apk`. Move
that file to your phone however's convenient and open it there to install
— you'll need to allow installs from unknown sources once, since it isn't
coming from the Play Store.

### If something breaks

A build error mentioning the manifest's `package` attribute means your
Flutter version's Android Gradle Plugin wants the namespace declared in
`build.gradle` instead — remove `package="com.expensetracker.hdfc"` from
the manifest's `<manifest>` tag if it's still there, and confirm `namespace`
is set in `build.gradle` as described above.

A `no such table` error on a phone that already had the app installed
before means the database needs a migration, not a fresh install — check
that `dbVersion` in `db_helper.dart` and `DB_VERSION` in `ExpenseDbHelper.kt`
have been bumped together, with a matching `onUpgrade` block that adds
whatever table went missing, rather than deleting and reinstalling (which
would work but throws away your existing entries for no reason).

If SMS stop being tracked after the app hasn't been opened in a while,
check your phone's battery optimization settings for this app, as
mentioned above.

If entries never appear at all, confirm you tapped Grant on the permission
banner, and check the Unparsed Messages screen — if messages are showing
up there, the sender filter is working but the pattern isn't matching, and
Parser Settings is where to fix that.
