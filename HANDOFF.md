Android1.2: same microphone stream now feeds a dedicated constrained hey-chef wake decoder plus unrestricted command recognizer; exact validated wake gates commands. Unknown background speech, expired command windows, negations and one-breath name misrecognition have regression coverage. Shared audio resources close only after reader exit. Fish confirmations unchanged. Device wake retest on S25Ultra Android16 pending.

Android 1.1 repair: partial wake recognition, bounded transcription variants, explicit Talk now, and offline Fish Chef voice confirmations. Nine JUnit tests plus assembly/lint and same-key APK signing passed. Human reports Android16/Samsung Galaxy S25 Ultra. Real-device retest pending. Selected Fish voice 14129c3e320149449d6bada6862f7338; fixed public recordings bundled, no API key on phone.

# Current handoff

Native Android Chef Pocket 1.0 is implemented in android/. Six JUnit tests, APK assembly, Android lint, signature verification and native-library 16KB alignment passed on October 6, 2026. The APK includes the offline Vosk model, while source uses scripts/prepare-model.py to fetch the checksum-verified model.

Install page: https://chef-pocket-daniel.sy-alejandri-0136.chatgpt.site/android.html
The existing Sites project is public with explicit human approval. Its configured source is managed separately by Sites. Version3 (commit d382cb14b7dde4a752421a17cdca6a60a80ebfe9) deployed successfully and includes the APK downloader. Do not register a replacement Site.

The canonical native Mac app is build82; its self-tests and signature checks passed. The running process was left for its existing idle/apply-update restart path. Mac Pocket schema now accepts and displays native phone calendar requests. Remote request text does not execute Mac actions. CalendarContract-created Google events reach Mac Calendar through the already connected Google account, when actual account sync succeeds.

Required device proof remains: install APK on the human’s Android; grant microphone/notifications; pair with Mac; select the writable Google calendar; enable Handsfree; lock screen and test Hey Chef capture; verify to-do/thought on Mac and phone; verify calendar insertion and Google account sync; check offline retry without duplicate events. Handsfree stops after 12 hours, reboot, or process termination and may need Unrestricted battery setting. No physical Android or live paired sync test has been performed.
