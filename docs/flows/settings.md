# Settings window

## Requirement and owner

Owner: LocalFlow maintainers. Requested in the September 8, 2026 local testing
session: use native macOS settings navigation and explain why login and update
controls are unavailable in LocalFlow Local. Keep dictation and waveform behavior.

## Intended behavior

- Open Settings from the app menu. A resizable window has six sidebar categories
  in production, plus Diagnostics locally, and native grouped forms. Keyboard
  navigation selects categories.
- General starts with the shortcut, login, and update controls. Instructions
  remain available in a collapsed disclosure group.
- Local builds show disabled login and update switches with visible explanations.
  Production login uses SMAppService; signed distribution builds with an update
  feed retain Sparkle controls. This redesign does not change those policies.
- Closing and reopening preserves the current pane and window position.
- Listening themes and their animated previews remain in Dictation.
- The sidebar shows the installed bundle's version in every build. Local builds
  also identify their source revision and whether it includes uncommitted work.
- Local builds have a Diagnostics pane with retained dictation, replay, and model
  preparation traces. It reads only structured timing metadata from the local
  diagnostic file on opening or Refresh. No transcript, raw log, or clipboard
  data is displayed. Production does not expose this pane.
- Release-to-dispatch ends at a successful paste/typing dispatch event. It does
  not imply visible insertion and excludes clipboard restoration. Missing events
  remain missing. Retention and truncated reads are explained in the pane.

## Observed implementation

`AppDelegate.openSettings` calls `SettingsPanelController.show` in
`Sources/LocalFlow/SettingsWindow.swift`. The controller reuses its NSWindow and
refreshes `SettingsModel`. `SettingsView` uses NavigationSplitView and Form.
Bindings go through SettingsModel to SettingsApplication for validation,
persistence, and typed effects on the running app. AppDelegate constructs the
SettingsApplication and its production effects, then injects it into SettingsModel.
The model keeps published view state and no longer translates effects into a
second set of callbacks. Pane selection is view-local.

Login registration failures revert the displayed value and report an issue.
Updates are enabled only when `UpdateController.isSupported` verifies a
distribution signature and update feed. Local startup registration remains
disabled by AppIdentity. History deletion still requires confirmation.

## Acceptance checks

- `swift test -c release --disable-automatic-resolution`: settings persistence,
  live effects, login failure recovery, updater policy, and other existing tests.
- `./scripts/local-app.sh install`: build, sign, install local, wait for model ready.
- Installed UI: inspect General, select all six panes, resize, close/reopen,
  verify local controls are disabled with explanations, and verify waveform
  previews still exist. Do not change production login/update settings.
- Capture General or Command mode for layout evidence; don't export history or vocabulary.

## Verification

Verified on September 8, 2026, macOS 26.6.2, M5 Pro, Swift 6.3.3. Base commit:
`08614b5d1166bcbd56a2c6eb7ada550ffff2aabf`, with uncommitted local-build and
preparation changes from the same session. This redesign changes
`Sources/LocalFlow/SettingsWindow.swift` and this record. The source diff is
captured in `/tmp/localflow-settings-redesign.diff`; it also includes the earlier
local login guard. Evidence files below are local, temporary artifacts.

- PASS: `swift test -c release --disable-automatic-resolution`, 193 tests,
  zero failures. Evidence: `/tmp/localflow-settings-tests.log`. An earlier build
  attempt failed because the source was edited during compilation; the final
  run used stable source.
- PASS: `./scripts/local-app.sh install`, release build, local install and model
  readiness. Warm model load was 0.86 seconds; this is not a redesign speedup.
  Evidence: `/tmp/localflow-settings-install.log`.
- PASS: `codesign --verify --deep --strict '/Applications/LocalFlow Local.app'`;
  production executable still matches `/tmp/localflow-production-before.sha256`.
- PASS: installed Command mode layout visually inspected at 820 pixels wide.
  Evidence: `/tmp/localflow-settings-command-mode.png`. General accessibility
  inspection exposed all six sidebar entries, the shortcut, both toggle controls,
  and both explanatory footers. A resize to a 740-by-552 window succeeded.
- PASS: independent source review found no blocking regression in pane bindings,
  history confirmation, or theme rendering. `git diff --check` passed.
- NOT RUN: complete keyboard navigation, light appearance, all panes at minimum
  size, and pane/position preservation after reopening. Automated interaction
  stopped when the window was being used. Maintainers should finish these checks
  when the app is idle. No personal vocabulary or history was inspected.
- NOT RUN: actual production login registration, update installation, and live
  dictation/waveform testing. Those behaviors were not changed by this redesign;
  existing tests cover settings logic, but do not establish these runtime checks.

## Version and diagnostics follow-up

Requested in the same September 8 testing session. Owner: LocalFlow maintainers.
`SettingsPane.available` gates the new pane by AppIdentity. `DiagnosticsPane`
loads `DiagLog.fileURL` on opening or Refresh, using a utility-priority task.
`DiagnosticsSnapshot.read` bounds reads to 8 MB and rejects non-regular files;
its parser accepts typed events and allowlisted metadata. Each trace retains its
recorded launch environment. A missing file is an empty state, other read errors
are failures, and malformed/unsupported events are counted. Expand a trace for
its full metadata-only report. No timer, transcript store, new log events, or
clipboard operation was added.

`AppBuildInfo` is shared by the sidebar and Diagnostics header. Version, build
number, revision, and dirty state come from the installed bundle. Packaging now
adds `LFBuildDate` before signing so successive local rebuilds can be identified.

Follow-up verification used the same machine and base commit as above. The dirty
source artifact is `/tmp/localflow-diagnostics-working-tree.diff`; it includes
earlier session changes in the touched files and the new reader/view/tests.

- PASS: independently authored `DiagnosticsSnapshotTests`, 9 frozen acceptance
  tests. Initial missing-implementation red: `/tmp/localflow-diagnostics-tests-red.log`.
  Behavioral red: `/tmp/localflow-diagnostics-behavior-red.log` caught embedded
  timing payloads and missing-file handling before they were fixed.
- PASS: `DiagnosticsReaderTests`, 5 checks for bounded reads, missing files,
  read failures, local-only navigation, and bundle-version formatting. The
  directory test also caught an error initially presented as an empty log.
- PASS: `swift test -c release --disable-automatic-resolution`, 207 tests, zero
  failures. Evidence: `/tmp/localflow-diagnostics-tests.log`.
- PASS: `bash Tests/ReleaseContractTests.sh`, 63 checks;
  `/tmp/localflow-diagnostics-release-contract.log`. Shell syntax and diff
  whitespace checks passed. Independent review found no blocking issues.
- PASS: `./scripts/local-app.sh install` and installed signature verification.
  Version 1.2.0, revision 08614b5d, modified tree, built 2026-09-09T01:54:06Z.
  The production executable checksum is unchanged. Evidence:
  `/tmp/localflow-diagnostics-install.log`.
- PASS: installed sidebar version/revision and Diagnostics navigation checked
  through Accessibility. The pane loaded 39 retained traces; its list, timing
  summaries, build header, and retention explanation were visually inspected.
  Evidence: `/tmp/localflow-diagnostics.png`. Only timing metadata was inspected.
- NOT RUN: expanded report scrolling at minimum size and rendered refresh/error/
  empty states. The window was closed during verification; automated interaction
  stopped. Parser behavior and reader failure states are covered by synthetic
  tests, but those tests do not verify layout. Maintainers can finish these UI
  checks when the app is idle. No audio accuracy or visible-insertion timing
  claims are made by this change.

## Architecture routing follow-up

The September 10, 2026 architecture implementation keeps the existing
SettingsApplication validation and persistence rules. Typed values now reach
model loading, microphone selection, warm-capture preference, theme selection,
and updater preference directly. Command-hotkey reconciliation still checks
the companion command-mode preference and backend availability.

SettingsApplicationRoutingTests covers normalized window/menu changes, duplicate
effect suppression, rejected-model rollback, and login failure/retry through an
injected application. SettingsModelCorrectionTests checks stable correction
identity across unrelated changes and removal. Production login registration,
update installation, and installed UI interactions remain unverified in this
refactor. See the [combined verification](dictation-recovery.md#architecture-implementation-verification).
