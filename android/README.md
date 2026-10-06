# Chef Pocket for Android

Chef Pocket is a native Android app for capturing and browsing to-dos, thoughts, and explicit calendar requests with Chef on Mac. Captures stay in the app's private device database while offline; paired sync uses the existing encrypted Pocket events relay.

## Build

Use JDK 17, Gradle 8.11.1, Android Gradle Plugin 8.9.2, and Android SDK Platform 35. In Android Studio, open this directory and build the `app` debug variant, or run:

```sh
python3 scripts/prepare-model.py
./gradlew testDebugUnitTest assembleDebug lintDebug
```

The installable debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`. The official Vosk `vosk-model-small-en-us-0.15` model must be extracted into `app/src/main/assets/model-en-us` before building. It is about 40 MB compressed, designed for mobile, and licensed Apache-2.0. The APK includes the offline model. The model directory is excluded from Git to keep the source checkout small.

For logic checks, run `./gradlew testDebugUnitTest`. Speech recognition stays offline. Fixed public confirmations were generated with the user’s selected Fish Audio Chef voice using the free model and are bundled for offline playback. No Fish credential is shipped to the phone.

## Voice capture

Handsfree mode is off until the user enables it in the visible app, accepts the microphone explanation, and grants Android's microphone permission. Android starts the microphone foreground service while Chef Pocket is visible; its persistent notification provides a Stop control. The service is designed to continue across screen lock, exits when stopped or when the process is terminated, and does not restart at boot. It auto-stops after 12 hours; re-enable it from the visible app. Some phone manufacturers require setting app battery use to Unrestricted. A fully powered-off phone cannot listen. Speech recognition runs offline on the phone. Chef saves a capture only after it hears “hey chef”; a standalone wake phrase opens a 15 second command window, and recognized command text must be followed by three seconds of silence before it is saved. Audio is not written to storage or sent to the relay.

## Pair and sync

In Chef on Mac, open **Controls → Phone → Show pairing**, then paste the 64 character code in Chef Pocket. The code is encrypted with an Android Keystore AES-GCM key in app-private preferences. To-dos and thoughts use the same SHA-256 derived channel, bearer credential, AES-GCM envelope, and event route as the existing Pocket web app. The app retains pending ciphertext and reuses event IDs during retries. Imported item text is data and never executes desktop actions.

Calendar requests are saved durably and synced as requests. The user may grant Calendar permission and select a writable calendar in the visible app. Explicit calendar captures can then add an event on that phone; a stable capture UUID and provider event ID prevent duplicate inserts. If permission or a writable calendar is unavailable, the app keeps the request and reports that it has not been added. This does not control the Mac.

## Limitations

The relay URL is the existing Chef Pocket service. A successful Android build does not prove that the current Site accepts native app requests, or that a real Android device can reach the user's Mac. The existing Site is published; real-device sync and screen-off recognition still require testing on the user's Android and Mac. No device control or unattended actions are provided.

## Wake repair in 1.2

One AudioRecord microphone stream feeds a dedicated constrained “hey chef” recognizer and a separate unrestricted command recognizer. The wake decoder includes an unknown-speech path to reject other speech. A valid wake event opens a bounded command window; command captures remain explicitly gated. The phone stays offline for recognition and keeps the same bundled Fish Chef confirmations. Real S25 Ultra/Android16 testing is still required.

## Voice repair in 1.1

Wake recognition now examines partial hypotheses as well as finalized speech and accepts a bounded set of common on-device transcription variants. “Talk now” explicitly captures the next sentence. Only an active wake window or that button can save a spoken capture. Generic diagnostic status distinguishes recognized speech from a recognized wake without storing ambient transcripts.

All capture confirmations and the “Test Chef voice” button use bundled Fish recordings for voice ID `14129c3e320149449d6bada6862f7338`. This is spoken capture feedback, not a full phone conversation engine. Playback uses Android Media volume and audio focus; playback failures are displayed rather than silently switching voices. The API key remains in the Mac Keychain. Install 1.1 over 1.0 to preserve pairing and captures; do not uninstall first.

## Verified build

Version 1.0 built on October 6, 2026: six JUnit tests passed; APK assembled; lint passed with no errors; v2 signing and native-library 16KB alignment verified. Native Mac compatibility build82 passed its self-tests and signature checks. No physical Android or live paired sync test has been performed.

Keep the existing signing key private and stable for future updates. The test APK is signed with the local Android debug key, not a Play Store release identity. Never commit keystores or pairing secrets.
