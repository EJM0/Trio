# Trio design language (iOS and watchOS)

Agent F, Phase 1 (read-only research). Baseline `nightscout/Trio` `dev` @ `ad6c66876e5ccca8b0a6e1c5b7626ed4caa65926`.
All file:line references are at that SHA unless marked `exp:` (experimental branch `kristinkand/feature/untethered-watch-mode` @ `a56170dc0`).
Claims are marked **V** (Verified: read in source), **I** (Inferred), **U** (Unverified).

## Executive summary

- Trio iOS has a coherent, recently reworked Home language: a dark navy gradient, rounded bold numerals, outlined capsules for status "pills", glass panels for the bottom zone, and one glucose "bobble" with a rotating trend pointer. Status is carried by a small set of named colors (`LoopGreen`, `LoopYellow`, `LoopRed`, `Insulin`, orange) plus text. (V)
- iOS states are carefully worded and spoken: loop ring meaning depends on dosing mode, readings older than 12 min are masked to dashes, VoiceOver gets one combined sentence per status element, and Dynamic Type is capped, not disabled. (V)
- The watch app is a thin remote: three vertical pages (glucose bobble, chart, snooze), IOB/COB in the toolbar, override / treatment / temp target buttons at the bottom. It shows no pump state, no CGM state, no dosing mode, no reading age and no bolus delivery progress (the overlay is commented out). (V)
- Watch freshness is phone-centric: everything greys to "--" and "STALE DATA" when the last phone snapshot is older than 5 min; the loop color is parsed from a phone-made English string ("N min"). Reading age and loop age are not separated. (V)
- Watch accessibility is thin: only the snooze page has VoiceOver labels; fonts are fixed per case size, not Dynamic Type. (V)
- Watch bolus flow: Digital Crown dial with haptics, then a crown-turn confirmation, a 2-minute entry expiry, a 15 s acknowledgement timeout. "Bolus enacted successfully." means the pump accepted the command, not that it delivered. The iOS low-glucose bolus warning has no watch equivalent. (V)
- Color tokens are duplicated per target: the watch catalog is a subset of iOS (no `ManualTempBasal`, `warning`, `darkOrange`, `DarkerBlue`, `minus`). (V)
- An untethered mode must add, as constraints: who is in control, CGM and pump link state, and loop / reading freshness computed on the watch from timestamps. It should reuse iOS semantics (ring rules, 12-minute mask, status highlight text) and add few screens. Draft guidelines are in the final section.
- Screenshots were not captured (reason under Method). This document is source-first.

## Scope and method

Read: `Trio/Sources/Modules/Home/**`, `Trio/Sources/Views`, `Trio/Sources/Helpers/{Color+Extensions,DynamicGlucoseColor,Formatters}.swift`, `Trio/Sources/Models/DosingMode.swift`, `Trio/Sources/Modules/Treatments/View/TreatmentsRootView.swift`, `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`, `Trio/Sources/APS/APSManager.swift` (bolus path only), all of `Trio Watch App Extension/`, `Trio Watch Complication/`, `LiveActivity/`, and the color sets in all five asset catalogs.

Not read in depth: History, Adjustments editors, Settings sub-screens, Onboarding, Stat. They follow standard `List`/`Section` forms (`Settings/View/SettingsRootView.swift:141-420`, V) and are not relevant to a watch mode.

Screenshots: **not captured.** iOS Home needs a finished onboarding, which means either driving the UI (synthetic input is not allowed) or cloning another simulator's data container (that touches the user's simulators). The watch app alone would only show the "STALE DATA" state, which the source already pins down. A build plus a fresh paired simulator set would have taken most of the 30-minute budget for little gain. No `Trio-on-watch-ui` worktree was created.

## Platform and targets

| Item | Value | Ref |
|---|---|---|
| iOS deployment target | 17.6 | `Trio.xcodeproj/project.pbxproj` `IPHONEOS_DEPLOYMENT_TARGET` (V) |
| watchOS deployment target | 10 | same, `WATCHOS_DEPLOYMENT_TARGET` (V) |
| Watch targets | `Trio Watch App` (stub container), `Trio Watch App Extension` (all UI), `Trio Watch Complication` | directory layout (V) |
| Live Activity | `LiveActivity/`, also offered to watchOS Smart Stack via `.supplementalActivityFamilies([.small])` on iOS 18+ | `LiveActivity/LiveActivity.swift:55-58` (V) |
| iOS 26 chrome | Liquid Glass panels and tab bar when available; material fallback below; `UIDesignRequiresCompatibility` respected on iOS 26 | `Home/View/GlassChrome.swift:24-81`, `HomeRootView.swift:365-378` (V) |
| Asset color symbols | `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES`; the watch gets `Color.loopGreen`, `.insulin`, `.tabBar` from generated symbols, plus manual `bgDarkBlue` aliases | pbxproj; `Trio Watch App Extension/Helper/Helper+Extensions.swift:13-16` (V for setting; I for how the watch resolves the symbols) |

## Visual language

- **Background.** Dark mode: vertical gradient `Background_DarkBlue` #0A2237 to `Background_DarkerDarkBlue` #030F1C. Light mode: flat `gray.opacity(0.1)`. `Trio/Sources/Application/AppState.swift:7-19` (V). The watch always uses the dark gradient, copied per view (`TrioMainWatchView.swift:57-61`, `BolusInputView.swift:19-23`, `CarbsInputView.swift:18-22`, `BolusConfirmationView.swift:13-17`, `AcknowledgementPendingView.swift:8-12`, V).
- **Bobble.** The central glucose element on both platforms: a circle with a purple-to-cyan angular gradient stroke (#B857FF, #9F6CFA, #7C8BF3, #57AAEC, #43BBE9), a cyan (#43BBE9) triangle pointer rotated by trend, and the value inside. iOS: 130 pt, `Chart` fill, soft cyan glow behind it (`CurrentGlucoseView.swift:26-33, 86-107, 397-441`). Watch: sized per case (82-105 pt), with an extra outer ring colored by loop freshness and a matching glow (`GlucoseTrendView.swift:38-53, 117-131`, `TrendShape.swift:62-88`). (V)
- **Pills.** Status values sit in outlined capsules: `Capsule().stroke(color.opacity(0.4), lineWidth: 2)`, padding 5 pt vertical and 10 pt horizontal, text in the same color. Used for loop status, reservoir and snoozed alarms (`LoopView.swift:91-98`, `PumpView.swift:80-86`, `HomeRootView+MealPanel.swift:170-176`, V). Icon-only round buttons use the same stroke on a 32 pt circle (`HomeRootView.swift:167-176`, `HomeRootView+MealPanel.swift:178-185`, V).
- **Glass panels.** The bottom zone (adjustment / bolus progress panel, multi-use banner) uses `glassPanel(tint:)`: corner radius 26, continuous, tint opacity 0.12 (0.30 when critical), stroke 0.35 (0.8 when critical). Reduce Transparency and Increase Contrast switch to an opaque fill (`GlassChrome.swift:5-81`, V).
- **Fixed zones.** Home does not scroll. It has fixed slots: header 172 pt, meal row 44 pt, bottom panel 60 pt, banner 60 pt; the chart takes the rest (`HomeLayout.swift`, `HomeRootView.swift:224-259`, V). A status change never reflows the layout.
- **Watch chrome** is stock watchOS: `TabView(.verticalPage)`, toolbar items, `List` sheets, `.bordered` buttons tinted by meaning (V, files below).

## Color system

### Named color assets

Values read from `Contents.json` (any / dark appearance). "W" means the color set also exists in the watch catalog with the same values.

| Asset | Value | W | Meaning in use |
|---|---|---|---|
| `LoopGreen` | #6FCF97 | yes; also in LiveActivity | Loop fresh, device OK, battery/pod OK, temp target, success |
| `LoopYellow` | #FFC145 (dark alpha 0.95) | yes | Loop delayed (5-10 min); COB icon on iOS Home; COB forecast line |
| `LoopRed` | #EB5757 | yes | Loop overdue, failure text, reservoir/battery critical, destructive list rows on watch |
| `LoopGray` | #BDBDBD | yes | Pump suspension band in chart |
| `Insulin` | #1E96FC | yes | IOB icon, bolus, basal capsule, reservoir normal, insulin buttons |
| `ManualTempBasal` | #1E96FC | **no** | Loop ring / basal pill while a manual temp basal runs (same hue as Insulin) |
| `Basal` | #1E96FC alpha 0.5 | yes | Scheduled basal |
| `TempBasal` | #A2D6F9 a0.5 / dark #1E96FC | yes | Temp basal fill |
| `TabBar` | #7D8CF2 | yes | Tab tint, centre "+" button (iOS and watch), sync glyph on watch |
| `UAM` | #D12BF7 | yes | UAM forecast |
| `ZT` | #7161EF | yes | Zero-temp forecast |
| `Chart` | #FFFFFF / dark #21212E | yes | Bobble fill (iOS), chart background |
| `Background_DarkBlue` / `Background_DarkerDarkBlue` | #0A2237 / #030F1C | yes | App background gradient |
| `warning` | #EAC345 / dark systemYellow | **no** | `Color.warning`, `agingColor` |
| `darkGreen`, `darkOrange`, `DarkerBlue`, `minus`, `darkGray`, `ApnBackground*` | various, with high-contrast variants for darkGreen/darkOrange | **no** | Chart and misc. |
| `AccentColor` | empty (no components) | empty | System default accent (I) |

Sources: `Trio/Resources/Assets.xcassets/Colors/*.colorset`, `Trio Watch App Extension/Assets.xcassets/Colors/*.colorset`, `LiveActivity/Assets.xcassets/LoopGreen.colorset`; Swift accessors in `Trio/Sources/Helpers/Color+Extensions.swift:55-75` (V).

`Color.carbs`, `.fresh`, `.glucose`, `.loopAccent` reference sets (`carbs`, `fresh`, `glucose`, `accent`) that do not exist in the Trio catalog (`Color+Extensions.swift:5-21`; only `fresh` exists, in LoopKitUI). Whether they resolve at runtime: U. They are not used by the Home or watch views read here (V for those views).

### Semantic and system colors in use

| Meaning | iOS | Watch |
|---|---|---|
| Carbs / COB | `fork.knife` in `LoopYellow` on Home meal row (`HomeRootView+MealPanel.swift:106-108`); `.orange` in chart legend and Treatments | `.orange` everywhere (toolbar, carbs input, treatment menu) |
| Override | `.purple` (`HomeRootView+BottomControls.swift:54`) | `.purple` (`TrioMainWatchView.swift:146-148`) |
| Temp target | `LoopGreen` (`HomeRootView+BottomControls.swift:55`) | `LoopGreen` at 0.75 opacity (`TrioMainWatchView.swift:165-167`) |
| Warning tier | `.orange` (sensor tags, banners, battery 11-20 %, pod < 24 h) | none |
| Critical tier | `LoopRed`, `.red` for "Notifications Disabled" | `LoopRed` for limit reached and failures |
| Unknown / stale | `.secondary` | `.secondary` |

COB has two hues across the product: `LoopYellow` on iOS Home, orange elsewhere (V). This is drift worth not copying.

### Glucose coloring

- Setting `GlucoseColorScheme`: `dynamicColor` or `staticColor` (`Trio/Sources/Models/GlucoseColorScheme.swift:5-13`, V).
- Static: low `hue 0`, in range `hue 120`, high `hue 270` (red / green / purple), all at saturation 0.6 and brightness 0.9 (`DynamicGlucoseColor.swift:70-81`, V). The chart legend text says "static (red, green, orange)" (`ChartLegendView.swift:122,126`), which does not match the purple high (V, copy bug).
- Dynamic: hue moves continuously from red at low, to green at target, to purple at high; Home and the watch use hard-coded 55 and 220 mg/dL as the ends (`CurrentGlucoseView.swift:364-379`, `AppleWatchManager.swift:247-264`, V).
- **Current value is uncolored while in range.** iOS uses `Color.primary` between the low and high thresholds (`CurrentGlucoseView.swift:369-371`). The phone sends `#ffffff` to the watch in that case (`AppleWatchManager.swift:266-270`). Chart points are always colored. (V)
- The watch gets colors as hex strings made on the phone and parses them with `String.toColor()` (`Helper+Extensions.swift:18-31`, V). An untethered watch has to compute them locally.

## Typography

| Element | iOS | Watch |
|---|---|---|
| Current glucose | `.system(size: 40, weight: .bold, design: .rounded)` (`CurrentGlucoseView.swift:223`) | `.title2` (40-44 mm) / `.title` (45/49 mm), `.semibold` (`GlucoseTrendView.swift:86-99,135-138`) |
| Status values (loop age, reservoir, IOB, COB, eventual BG, basal) | `.callout` `.bold` `.rounded` | IOB/COB: `.caption2` (`TrioMainWatchView.swift:126,138`) |
| Delta, reading age | `.callout` bold, white 0.9 (dark) / secondary | delta `.caption` semibold secondary; no reading age |
| Loop time / stale label | n/a | fixed `.system(size: 9-11)`; `.expanded` width for "STALE DATA" (`GlucoseTrendView.swift:101-115,151-158`) |
| Entry amounts | form fields | `.system(.title2, design: .rounded)` bold (`BolusInputView.swift:77-79`, `CarbsInputView.swift:49-51`) |
| Panel title / subtitle | `.subheadline` semibold / `.caption` secondary (`HomeRootView+BottomControls.swift:674-678`) | n/a |

Pattern: numbers are rounded and bold. Labels are system default. (V)

## SF Symbols

| Meaning | Symbol | Where |
|---|---|---|
| IOB / bolus | `syringe.fill` | iOS meal row, watch toolbar, treatment menu (V) |
| COB / meal | `fork.knife` | same (V) |
| Reservoir, bolus in progress | `cross.vial.fill` | `PumpView.swift:62`, `HomeRootView+BottomControls.swift:473` (V) |
| Pump battery | `battery.100` (tinted) | `PumpView.swift:94` (V) |
| Pod / patch life | `hourglass`, `hourglass.bottomhalf.filled`, `hourglass.tophalf.filled`, `hourglass.badge.plus` (palette) | `PumpView.swift:16-32` (V) |
| Sensor warmup / stabilizing | `hourglass` | `CurrentGlucoseView.swift:311-325` (V) |
| No CGM / add CGM | `sensor.tag.radiowaves.forward.fill` | `CurrentGlucoseView.swift:71` (V) |
| No pump / add pump | `keyboard.onehanded.left` | `PumpView.swift:45` (V) |
| Loop closed | `circle` (custom open ring for other modes) | `LoopView.swift:165-174`, `DosingMode.swift:68-79` (V) |
| Open Loop | `circle.dashed` | `DosingMode.swift:73` (V) |
| Low Glucose Suspend / manual basal | `hand.raised.fill` | `DosingMode.swift:75`, `HomeRootView.swift:108-110` (V) |
| Basal Testing | `waveform` | `DosingMode.swift:77` (V) |
| Eventual glucose | `arrow.right.circle` | `HomeRootView+Header.swift:172` (V) |
| Alarms / snoozed | `bell.fill` / `bell.slash.fill`; end snooze `alarm.waves.left.and.right.fill` | meal row, watch snooze page (V) |
| Override | `clock.arrow.2.circlepath` | iOS adjustment panel, watch bottom bar (V) |
| Temp target | `target` | same (V) |
| No adjustment / Adjustments tab | `slider.horizontal.2.gobackward` | (V) |
| Stop / cancel (adjustment, bolus) | `xmark.app` | `HomeRootView+BottomControls.swift:220-310,498` (V) |
| Add treatment | `plus.circle.fill` (iOS), `plus` in a `TabBar` circle (watch) | (V) |
| Phone sync in progress (watch) | `iphone.radiowaves.left.and.right` with `.variableColor.iterative` | `TrioMainWatchView.swift:74-88` (V) |
| Crown confirm hint | `digitalcrown.arrow.clockwise.fill` / `.counterclockwise.fill` by wrist side, `.variableColor.reversing` | `BolusConfirmationView.swift:89-101` (V) |
| Ack pending / success / failure (watch) | `progress.indicator` / `checkmark.circle` / `xmark` | `AcknowledgementPendingView.swift:14-23` (V) |
| Banners | `bell.slash.fill`, `clock.badge.exclamationmark.fill`, `drop.fill`, `exclamationmark.triangle.fill`, `icloud.slash.fill`, `sparkles` | `HomeRootView+BottomControls.swift:704-781` (V) |
| Help | `questionmark.circle`, `info` | (V) |
| Tabs | `chart.xyaxis.line`, `book.pages`, `slider.horizontal.2.gobackward`, `gear` | `HomeRootView.swift:389-418` (V) |

Trend on iOS Home and the watch is a rotated triangle, not an arrow glyph. Live Activity and Calendar use Unicode arrows (`↑↑`, `↗︎`, `→`, `↔︎` …; `CalendarManager.swift:312-340`, V).

## Navigation and layout

### iOS

- Root `TabView`: Main, History, centre treatment button, Adjustments, Settings. On iOS 26 glass, the centre slot is an invisible tab with the button laid over it, and its selection is ignored. Long-pressing the button opens Quick-Pick treatments. (`HomeRootView.swift:372-470`, V)
- Home zones, top to bottom (`HomeRootView.swift:224-259`, V):
  1. Header: pump panel (left), glucose bobble (centre), loop status plus eventual glucose (right).
  2. Meal row: IOB (left), COB (centre), alarm pill (right). While the chart is being scrubbed, a readout for the selected point replaces this row.
  3. Chart, with the current basal rate capsule (top right) and a legend button.
  4. Bottom zone: adjustment panel or bolus progress panel, then the multi-use banner.
- Details open as sheets: loop status, chart legend, snooze, CGM / pump settings, release notes (`HomeRootView.swift:278-362`). Pulling down forces a loop, except in Open Loop (`HomeRootView+Refresh.swift:31-95`). (V)
- Multi-use banner priority, highest first: Notifications Disabled, pump Time Change, No Recent Glucose (> 12 min), dosing mode limited (LGS / Basal Testing), Max IOB is 0 U, Tidepool login, What's New, stats (`MultiUsePanelState.swift:17-40`, V). One slot, one message, ranked by safety.

### Watch

- `NavigationStack` around a `TabView(.verticalPage)` with three pages: 0 glucose bobble, 1 chart, 2 alarm snooze. The Digital Crown pages between them (`.digitalCrownRotation($currentPage, 0...2)`). (`TrioMainWatchView.swift:64-110`, V)
- Toolbar: IOB (top leading), COB (top trailing); bottom bar: override, "+" treatment, temp target. All three buttons are disabled when the state is stale or the session is not activated (`TrioMainWatchView.swift:116-169`, V).
- Treatment menu: full-screen cover with Meal, Bolus, Meal & Bolus. Inputs and confirmation are pushed on the navigation path (`TreatmentMenuView.swift`, `TrioMainWatchView.swift:171-225`, V).
- Override and temp target presets: sheets with a red "Stop <name>" row at the top, then the presets; the running one has a gradient row and the caption "is running" (`OverridePresetsView.swift:24-75`, V).
- After any request: `AcknowledgementPendingView` (toolbar hidden, back button hidden), which returns to root when the banner clears (`AcknowledgementPendingView.swift:25-57`, V).
- Chart page: tap cycles the time window; optional forecast as lines or cone; no axis on X (`GlucoseChartView.swift:153-232`, V).
- Complication: static Trio icon only, `accessoryCircular` and `accessoryCorner`, timeline `.never` (`Trio Watch Complication/TrioWatchComplication.swift:12-101`, V). No data.

## Information hierarchy

iOS Home, by visual weight: (1) glucose value with trend, (2) loop ring and pump pills either side, (3) IOB / COB, (4) chart, (5) adjustment, bolus and warning banner. Warnings take the banner slot by priority instead of stacking. (V, from layout)

Watch page 0: (1) glucose value with trend and loop-colored ring, (2) delta, (3) loop age ("N min") or "STALE DATA", (4) IOB / COB in the corners, (5) actions at the bottom. Device health and reading age are missing from the hierarchy. (V)

## Reusable components

| Component | File | Notes |
|---|---|---|
| `LoopView` | `Home/View/Header/LoopView.swift` | Ring, gap, center symbol, caption, color and spoken label; static helpers (`ringColor`, `ringGap`, `centerSymbol`, `showsCaption`) are pure and reusable (V) |
| `CurrentGlucoseView` + `TrendShape`, `SensorLifecycleArcView`, `SensorStatusTagView` | `Home/View/Header/…` | Bobble, freshness mask, CGM status collapse, lifecycle arc (V) |
| `PumpView` | `Home/View/Header/PumpView.swift` | Reservoir / battery / pod pills, or the pump status highlight text instead (V) |
| `glassPanel`, `glassMaterialFill` | `Home/View/GlassChrome.swift` | Accessibility-aware chrome (V) |
| `panelBanner` | `HomeRootView+BottomControls.swift:657-701` | Icon, title, subtitle, chevron (V) |
| `BolusProgressBar` | `Trio/Sources/Views/BolusProgressBar.swift` | Gradient bar under the bolus panel (V) |
| `GlassActionSheet` | `Trio/Sources/Views/GlassActionSheet.swift` | Bolus warning confirmation (V) |
| `TagCloudView`, `DefinitionRow`, `SettingInputSection` | `Trio/Sources/Views/` | Algorithm tags, glossary rows, settings rows with mini and verbose hints (V) |
| Watch: `WatchOSButtonStyle`, `PressableIconButtonStyle` | `Trio Watch App Extension/Helper/Helper+ButtonStyles.swift` | Round `TabBar` button sized per case (V) |
| Watch: `WatchSize` | `Helper+Enums.swift:35-68` | Exact screen-bounds matching; unknown sizes fall back to 45 mm values (V) |

The watch has its own `TrendShape` and `GlucoseTrendView`. It shares no view code with iOS (V). Only `WatchMessageKeys.swift` and the model structs are shared (pbxproj, V).

## How each quantity is shown

| Quantity | iOS (Home) | Watch app | Live Activity / Smart Stack |
|---|---|---|---|
| Glucose | 40 pt rounded bold in bobble; "HIGH" at 400; uncolored in range; "– –" secondary if the reading is ≥ 12 min old (`CurrentGlucoseView.swift:218-251`) | Phone-formatted string; "--" if state > 5 min old; color from phone hex (`GlucoseTrendView.swift:135-138`) | Value plus arrow plus change; strikethrough red when `isStale` (`LiveActivityBGLabelWatchView.swift:16-41`) |
| Unit | Not printed next to the value; spoken in VoiceOver | Not printed | Not printed |
| Trend | Rotating triangle (−90°…+90°; double and triple map to ±90°) (`CurrentGlucoseView.swift:117-142`) | Same scheme with spring animation (`TrioMainWatchView.swift:245-262`) | Unicode arrows |
| Delta | Signed, units-aware (`formattedDelta`), beside the reading age | Signed string from phone, `.caption` | Text |
| Reading age | `formattedTimeAgo` (e.g. "3m") under the value (`CurrentGlucoseView.swift:231-241`) | **Not shown** | Clock time "Updated: 14:05" (`LiveActivityUpdatedLabelView.swift`) |
| Eventual glucose | `arrow.right.circle` + value under the loop ring (`HomeRootView+Header.swift:169-197`) | Not shown | Detailed view only (I) |
| IOB | `syringe.fill` + "1.25 U" (`HomeRootView+MealPanel.swift:120-142`) | `syringe.fill` + "1.25", **no unit** (`TrioMainWatchView.swift:117-127`) | IOB label view |
| COB | `fork.knife` (LoopYellow) + "12 g" | `fork.knife` (orange) + "12", **no unit** | COB label view |
| Basal | Capsule on chart: "0.85 U/hr", "Suspended", or manual with `hand.raised.fill` in ManualTempBasal (`HomeRootView.swift:103-160`) | Not shown | Not shown |
| Bolus in progress | Glass panel: "Initiating…" / "Bolusing", "0.40 of 1.00 U", cancel `xmark.app`, gradient bar (`HomeRootView+BottomControls.swift:458-512`) | **Not shown** (`BolusProgressOverlay.swift` entirely commented out) | Not shown |
| Loop status | Ring color plus caption; open ring and center symbol for constrained modes; "looping" while running; tap opens a status sheet with "Enacted at …" and the oref reason (`LoopView.swift`, `LoopStatusView.swift`) | Outer ring color plus glow, "N min" under the bobble; no mode | Not shown |
| Dosing mode | Ring shape, center symbol, banner, label in status sheet (`DosingMode.swift`) | Not shown | Not shown |
| Pump | Reservoir pill (Insulin; orange ≤ 30 U; red ≤ 10 U; "50+ U" when unknown), battery %, pod countdown; a pump status highlight message (e.g. suspended) replaces all of it (`PumpView.swift:34-109,185-242`) | Not shown | Not shown |
| CGM | Lifecycle arc (last 48 h, warmup, non-normal), status tag (orange / red / secondary), and, when no fresh reading, the bobble collapses into the kit's symbol plus message (`CurrentGlucoseView.swift:41-58,255-362`) | Not shown; chart says "No glucose readings. Check phone and CGM connectivity." (`GlucoseChartView.swift:154-157`) | Not shown |
| Override / temp target | Glass panel with name, remaining time bar, stop button; purple / green tint (`HomeRootView+BottomControls.swift:190-456`) | Bottom-bar icon tinted when active; sheet shows "is running" | Detailed view shows names (`LiveActivityView.swift:54-65`) |
| Alarms | Bell pill; snoozed: `bell.slash.fill` + "N m" (`HomeRootView+MealPanel.swift:152-202`) | Page 3, same pill plus "Snoozed until …" / "Alarms active" (`AlarmSnoozeView.swift`) | n/a |

## Loading, error, connectivity and stale states

### iOS

| State | Presentation | Ref |
|---|---|---|
| Loop running | `ProgressView` in the ring, caption "looping"; pull-down shows "Forcing loop…" | `LoopView.swift:175-187`, `HomeRootView+Refresh.swift:39-48` (V) |
| No enacted determination | Ring `.secondary`; spoken "not looping" | `LoopView.swift:59,118-119` (V) |
| Loop late | Yellow above 5 min, red above 10 min (after a 30 s grace) | `LoopView.swift:61-68` (V) |
| Loop error | Status sheet: "Loop at <date> failed." plus the message, in LoopRed | `LoopStatusView.swift:58-65` (V) |
| Reading ≥ 12 min old | Value masked "– –"; banner "No Recent Glucose / Tap to add a fingerstick reading."; with a CGM status, the bobble becomes symbol plus message | `CurrentGlucoseView.swift:244-251`, `MultiUsePanelState.swift:14-29` (V) |
| Open Loop device health | Ring green if devices talk, red if not (`hasDeviceIssue` = pump highlight, or glucose > 12 min old) | `LoopView.swift:47-57`, `HomeStateModel.swift:147-150` (V) |
| Bluetooth off | Header replaced by "Bluetooth Required / Tap to Enable Bluetooth in iOS Settings" | `BluetoothRequiredView.swift:15-25`, `HomeRootView.swift:227-231` (V) |
| Waiting for a suggestion | Whole tab view blurred, `CustomProgressView` "Updating IOB..." | `HomeRootView.swift:432,583-587` (V) |
| No devices | "Add CGM" / "Add pump" placeholders that open pickers | `CurrentGlucoseView.swift:66-83`, `PumpView.swift:42-59` (V) |

### Watch

| State | Presentation | Ref |
|---|---|---|
| Snapshot older than 5 min (`isWatchStateDated`) | Glucose, delta, IOB, COB "--" in secondary; trend ring grey gradient; "STALE DATA" in expanded width; action buttons disabled | `TrioMainWatchView.swift:24-33,116-169`, `GlucoseTrendView.swift:135-158`, `TrendShape.swift:77-86` (V) |
| Session not activated | Same as stale (OR'd in). The comment says "not activated OR not reachable" but the code checks activation only | `TrioMainWatchView.swift:35-41` (V) |
| Phone unreachable but snapshot fresh | UI looks normal; a request fails at send time: "iPhone not reachable. Nothing was sent." | `WatchState+Requests.swift:127-135`, `WatchState.swift:80-83` (V) |
| Syncing | `iphone.radiowaves.left.and.right` animated at the top left of page 0 | `TrioMainWatchView.swift:74-88` (V) |
| Request in flight | "Processing…" with spinner; 15 s timeout, then "No answer from iPhone. Check Trio on your iPhone before trying again." | `AcknowledgementPendingView.swift:35-38`, `WatchState.swift:73-79,170-190` (V) |
| Result | Icon plus phone-supplied message for 2 s, then back to root | `WatchState.swift:196-228` (V) |
| Bolus limit unknown | "Bolus limit cannot be fetched from phone!" / "Check device settings, connect to phone, and try again." | `BolusInputView.swift:45-50` (V) |
| Entry left > 2 min | Inputs closed; on send: "Entry expired after 2 minutes. Nothing was sent. Please enter it again." | `WatchState.swift:40-46,160-166`, `TrioMainWatchView.swift:234-240` (V) |
| Calculating | `ProgressView` "Calculating Bolus..." | `BolusInputView.swift:38-43` (V) |

### Live Activity

`isStale` (stale date about 6 min after the last reading, `LiveActivityManager.swift:273`) shows the time and value in secondary or red 0.6 with a strikethrough. Expiry shows "Live Activity Expired. Open Trio to Refresh" (`LiveActivityView.swift:192,243`). (V) This strikethrough is the only stale treatment that exists in a watch-face context today.

## Terminology (exact strings)

| Context | String | Ref |
|---|---|---|
| Dosing modes | "Closed Loop", "Open Loop", "Low Glucose Suspend", "Basal Testing" | `DosingMode.swift:41-52` |
| Mode hints | "Trio adjusts your insulin automatically." / "Trio only shows what it would do. It never changes your insulin." / "Trio may only lower basal insulin. It will not correct highs." / "Trio steps in only if your glucose goes low." | `DosingMode.swift:54-65` |
| Loop caption (iOS) | "looping" (running), "Manual" (manual temp basal), time ago e.g. "3m", "--" | `LoopView.swift:185-194,201-203` |
| Loop status sheet | "Current Loop Status", "Enacted at <time>", "Determined at <time>" (open loop), "Trio has not looped in N minutes.", "Trio has not run in N minutes.", "Not looping.", "No recent determination.", "Loop at <date> failed.", "Latest Raw Algorithm Output", "Current Algorithm Reasoning", "No recent oref algorithm determination.", "Got it!" | `LoopStatusView.swift:22-107,198-225` |
| Mode caveats | "Trio worked this out but did not send anything to your pump." / "Trio may only lower your basal. It will not correct a high." / "Trio leaves your basal alone unless your glucose goes low." | `LoopStatusView.swift:150-161` |
| Loop spoken | "<mode>, looping normally / last loop delayed / loop overdue / not looping / not dosing / manual temporary basal running, last loop <ago> / in progress / last device communication <ago>" | `LoopView.swift:111-154` |
| Force loop | "Pull down to force loop", "Forcing loop…" | `HomeRootView+Refresh.swift:42,54` |
| Watch loop | "N min" (made on the phone, not localized), "--", "STALE DATA" | `AppleWatchManager.swift:214-220`, `GlucoseTrendView.swift:151-156` |
| Bolus | "Enact Bolus", "Ignore Warning and Enact Bolus", "Glucose is very low.", "Glucose forecast is very low.", "Bolusing", "Initiating…", "x of y U", "Cancel bolus" (a11y), "Max Bolus of N U Exceeded" | `TreatmentsRootView.swift:538-591,687`, `HomeRootView+BottomControls.swift:466-501` |
| Watch bolus | "Insulin", "Enact Bolus", "No Bolus, Log Carbs", "Recommended: x.x U", "Bolus Limit Reached!", "Confirm", "To confirm, dial crown.", "Cancel" | `BolusInputView.swift`, `BolusConfirmationView.swift` |
| Watch carbs | "Carbohydrates", "Log Carbs", "Proceed", "Carbs Limit Reached!" | `CarbsInputView.swift` |
| Watch treatments | "Pick Treatment", "Meal", "Bolus", "Meal & Bolus" | `TreatmentMenuView.swift:72,104-110` |
| Phone acks | "Bolus enacted successfully." (pump accepted the command), "Error! Failed to enact bolus.", "Carbs logged successfully.", "Saving Carbs...", "Enacting bolus...", "Carbs and Bolus logged successfully.", "Started Override \"x\" successfully.", "Stopped Temp Target successfully."; some failures unlocalized ("Error logging carbs", "Failed to log carbs and bolus") | `APSManager.swift:653-676`, `AppleWatchManager.swift:855-1065` |
| Watch combo steps | "Saving Carbs...", "Enacting Bolus..." as enum raw values (rendered verbatim, not localized) | `Helper+Enums.swift:11-14`, `AcknowledgementPendingView.swift:30` |
| Snooze | "Snooze Alerts", "End Snooze", "Snoozed until %@", "Alarms active", "N m" | `AlarmSnoozeView.swift` |
| Banners | "Notifications Disabled / Alarms cannot alert you. Tap to fix.", "No Recent Glucose / Tap to add a fingerstick reading.", "Max IOB is 0 U / Automated dosing is limited. Tap to review.", "Time Change Detected / Pump clock differs from phone. Tap to review." | `HomeRootView+BottomControls.swift:704-781` |
| Pump | "Add pump", "Replace pod", "Reservoir", "Pump battery", "Pod expiration" | `PumpView.swift` |
| CGM | "Add CGM", "Warming up", "Stabilizing", kit status text verbatim | `CurrentGlucoseView.swift` |

Note the casing: iOS uses "looping" (lowercase caption) and "Looping" does not appear as a label. "Last loop" exists only in the spoken label ("last loop %@"). (V by grep of the files listed.)

## Accessibility

- **iOS Home** groups each status element into one VoiceOver element with a full sentence: glucose "Glucose 79 mg/dL, in range, falling, delta -2, 1 minute ago" plus the sensor tag; loop mode, status and age; reservoir and battery with spoken severity ("low", "getting low"); the basal rate spoken with units (`CurrentGlucoseView.swift:143-216`, `LoopView.swift:99-154`, `PumpView.swift:87-183`, `HomeRootView.swift:122-160`). Tap and long-press gestures are mirrored as accessibility actions ("Snooze alerts", "Quick Pick Treatments") (`HomeRootView+Header.swift:99-108`, `HomeRootView.swift:493-509`). (V)
- **Color is never the only signal on iOS:** range, loop health and severity are put into words (V, same refs).
- **Dynamic Type:** global cap at `.accessibility1`; Home, Statistics and Calibrations cap at `.xxLarge` because of fixed zones (`TrioApp.swift:376-378`, `HomeRootView.swift:264-265`). Ring size uses `@ScaledMetric` (`LoopView.swift:156-157`). Many Home sizes are fixed points (bobble 130 pt, value 40 pt). (V)
- **Reduce Transparency / Increase Contrast:** glass falls back to opaque (`GlassChrome.swift:34-48`). (V)
- **Watch:** only `AlarmSnoozeView` has accessibility modifiers. The glucose bobble, loop ring, IOB/COB and the icon-only bottom buttons have no labels; the buttons would read as symbol names (I). Fonts are picked per `WatchSize`, and fixed 9-11 pt text does not follow Dynamic Type (`GlucoseTrendView.swift:101-115`). (V by grep: `accessibility` occurs only in `AlarmSnoozeView.swift`.)

## Interaction conventions

### Bolus

| Step | iOS | Watch |
|---|---|---|
| Entry | Treatments sheet: carbs, fat, protein, recommendation row (tap copies it), bolus field, limits shown as red "Max … Exceeded" (`TreatmentsRootView.swift`) | Crown dial from 0 to `maxBolus` in pump increments, with ± buttons, prefilled with the recommendation; red value plus "Bolus Limit Reached!" at the limit (`BolusInputView.swift:63-121`) |
| Safety prompt | If "confirm bolus" is on and glucose < 54 or forecast min < 54, a glass action sheet asks "<warning> Bolus N U?" with a destructive "Ignore Warning and Enact Bolus" (`TreatmentsRootView.swift:529-596`) | **None** (open upstream PR #1648) |
| Confirm | One button tap | Second screen: turn the crown until the progress bar fills (step 0.05, or 0.5 with "Confirm Bolus Faster"); `.click` haptic per step, `.success` when full, then send (`BolusConfirmationView.swift:46-86`) |
| Expiry | n/a | Entry cleared after 2 min idle or on return to root (`WatchState.swift:40-46,137-166`) |
| Feedback | Bolus panel on Home and in Treatments with progress and cancel | Ack screen: success means the pump accepted; no delivery progress, no cancel (the cancel UI is commented out) |

### Crown, haptics, gestures

- Crown: page navigation on the main view; value entry; confirmation. All with `isHapticFeedbackEnabled: true` (V).
- Watch haptics: `.click` and `.success` only; no `.failure` on errors (V).
- iOS haptics: heavy impact on long-press (snooze, quick-pick), medium on force loop and chart scrub, success notification in Settings (12 call sites; V by grep).
- iOS gestures: tap the bobble for CGM settings, long-press for snooze; tap the pump panel for pump settings; tap the loop ring for the status sheet; pull down to force a loop (V, refs above).

## iOS vs watchOS: differences that matter for untethered

| Topic | iOS | Watch (baseline) |
|---|---|---|
| Data source | Local stores | Phone snapshot via WatchConnectivity; phone pushes only when reachable (`AppleWatchManager.swift:174-185`) |
| Freshness basis | Per signal: reading date, `lastLoopDate`, pump comms | One: snapshot age (5 min) plus loop string |
| Loop color | Mode-aware, from `Date`s | Parsed from "N min" text; mode-blind (`GlucoseTrendView.swift:14-36`) |
| Glucose mask | 12 min on the reading | None on the reading; 5 min on the snapshot |
| Device status | Pump and CGM fully surfaced | Absent |
| Bolus progress / cancel | Yes | No |
| Low-glucose bolus warning | Yes (setting) | No |
| VoiceOver | Thorough | Snooze page only |
| Units in display | "U", "g", "U/hr" | Only on input screens |
| Localization | `String(localized:)` throughout Home | Mostly; exceptions: "N min", combo step raw values, some phone ack messages; `String(format: "%.2f U")` ignores locale decimal separators (I) |

## Experimental branch: screens added (inventory only, not a design reference)

From `git diff --stat 3f6b238b4..a56170dc0` and struct names (unverified, kristinkand code):

- `exp: Trio Watch App Extension/Untethered/UntetheredViews.swift`: `UntetheredStatusView` (control / handover status, "Hand Back", "Emergency Stop", pod phases, line 12-115, 175-433), `UntetheredHistoryView` (493), `BolusProgressRing` (616), `UntetheredLoopModeSelectionView` "Loop Mode" (638), `UntetheredLoopStatusView` (687, ports iOS "Current Loop Status" strings), `UntetheredGlanceView` (863, "Extended Untethered Mode" minimal screen tied to a workout), `ManualGlucoseEntryView` "Add BG" (1083), `CrownConfirmView` (1179).
- `exp: Trio Watch App Extension/Views/PeripheralsView.swift` (devices page), `G7Direct/WatchG7View.swift` (watch sensor toggle, pairing, log).
- `exp: TrioMainWatchView.swift` adds pages: devices, status, watch sensor, loop status (lines 173-205).
- `exp: Trio Watch Complication/TrioWatchComplication.swift` adds `accessoryRectangular` and an `UntetheredBadge` (65, 178, 323).

That is about eight new screens plus three complication changes. The guidelines below need far fewer.

## Draft UX guidelines for Trio on Watch (constraints, not a redesign)

These are contributor-facing constraints for any untethered mode. MUST = needed for safe use; SHOULD = strong default; MAY = optional. All user-facing copy that comes out of this must be plain language for people managing their own or a family member's diabetes, keep every safety caveat, and not give dosing advice. It is not medical advice. Users should involve their care team when changing how they manage therapy.

### G1. Control authority (MUST)

1. The main watch page MUST always say which device is running the loop: this watch, the iPhone, or none. Use a symbol plus a short word ("Watch" / "iPhone" / "Not looping"), never color alone. Reuse existing glyphs (`applewatch`, `iphone`) instead of new art.
2. A handover in progress is its own state, worded as such (e.g. "Switching to watch…"). While it lasts, dosing actions on that device MUST be disabled with a visible reason. No silent "both" or "unknown" state.
3. The same indicator MUST appear on iPhone Home when the watch is in control (a banner in the multi-use slot fits the existing priority model, ranked above "No Recent Glucose"). Otherwise the phone Home looks like it is looping when it is not.
4. Failure and timeout messages MUST name the device actually involved. Today's "No answer from iPhone…" and "iPhone not reachable. Nothing was sent." are wrong when the watch is in control.

### G2. Loop freshness (MUST)

1. Reuse the iOS rules exactly: green ≤ 5 min, yellow ≤ 10 min, red beyond, measured from the last *enacted* loop with the 30 s grace; secondary grey when nothing is enacted; open ring plus center symbol for LGS and Basal Testing; Open Loop shows device health instead. The logic lives in `LoopView`'s static helpers and should be shared, not re-implemented.
2. Freshness MUST be computed on the watch from `Date`s at render time (`TimelineView`), not parsed from a phone-made string like "N min".
3. The dosing mode MUST be visible on the watch whenever it is not Closed Loop (ring shape and symbol, plus the mode name on the status surface).
4. When the loop last failed, the reason SHOULD be reachable in one tap, with the iOS wording "Loop at <time> failed." and the message.

### G3. Separate the clocks (MUST)

Show these as different things; do not merge them into one "stale" flag:
- Reading age: the value is masked to "--" at 12 min, matching iOS and the loop input gate (`CurrentGlucoseView.swift:244-251`). Show "Nm" next to the value as iOS does.
- Loop age (G2).
- Pump last communication.
- In tethered mode only: snapshot age from the phone. Today's "STALE DATA" means this and only this. It SHOULD not be shown when the watch is in control and its own data is fresh.

### G4. CGM and pump link (MUST)

1. CGM: last reading age plus the kit's status message verbatim (the same source as iOS `cgmDisplayState`), colored by tier (secondary / orange / red). With no fresh reading, collapse to symbol plus message as iOS does, not an empty bobble.
2. Pump: last communication age, and the pump status highlight (e.g. suspended) verbatim when present. Reservoir and battery MAY follow, using the iOS thresholds and colors (≤ 30 U orange, ≤ 10 U red; battery ≤ 20 % orange, ≤ 10 % red).
3. "Bluetooth off / not authorized" on the watch MUST be stated explicitly. It is a likely watch failure and iOS already has a pattern ("Bluetooth Required").

### G5. Bolus (MUST)

1. Keep the crown-to-confirm screen, the per-step `.click` and the `.success` haptics, the 2-minute entry expiry and the pump-increment rounding. They are good and already tested.
2. The watch MUST distinguish requested, accepted by the pump, delivering (x of y U) and finished (or failed / cancelled). "Bolus enacted successfully." means accepted only; it MUST NOT be the last thing the user sees for a watch-run bolus. Delivery progress with a cancel control (iOS: "Bolusing", "x of y U", `xmark.app`, accessibility "Cancel bolus") is required when the watch drives the pump.
3. The low-glucose bolus confirmation that iOS has (glucose < 54 or forecast < 54 with "confirm bolus" on) MUST exist on the watch when the watch computes the recommendation. Copy: "Glucose is very low." / "Glucose forecast is very low." / "Ignore Warning and Enact Bolus".
4. Failures SHOULD play `.failure`. A pump error SHOULD tell the user to check pump history before repeating (the existing iOS alert body "Check pump history before repeating.").

### G6. Stale and unknown values (MUST)

- Use "--" and `.secondary` for any value that is unknown or older than its limit. Never show the last known glucose in range colors once it is stale.
- In complications or Smart Stack, use the Live Activity convention: secondary or red 0.6 with strikethrough, plus the time of the last value.
- IOB and COB on the watch SHOULD carry units ("U", "g") as iOS does.

### G7. Alerts (MUST, details are an open question)

If the watch is in control, alarms for low / high glucose, signal loss, loop failure and pump faults MUST be raised on the watch itself. The snooze page and "End Snooze" pattern can be reused. If watch notifications are off, the watch MUST say so (iOS ranks "Notifications Disabled" top of the banner list).

### G8. Accessibility (MUST)

- Port the iOS VoiceOver sentences (glucose with range, trend, delta and age; loop status with mode and age; pump and CGM status) to the watch elements. Add labels to every icon-only button.
- Don't use color alone for state (G1, G2).
- New watch text SHOULD use text styles instead of fixed point sizes. It MAY keep the `WatchSize` table for geometry only.

### G9. Localization and units (MUST)

- No pre-formatted English strings across devices; send numbers and dates. All copy via `String(localized:)`. Format decimals with the locale (no `String(format: "%.2f")` for user-facing amounts).
- Glucose is stored in mg/dL and converted at display.

### G10. Visual tokens (SHOULD)

- Reuse existing color names and values. Add the missing iOS sets to the watch catalog (`ManualTempBasal`, `warning`) instead of creating new hues. Carbs: pick one hue (orange is the majority use) for any new watch surface.
- Keep the bobble, the outlined capsule pill, the dark gradient and rounded bold numerals. There is no need for a watch-specific style.

### G11. Scope: screens (YAGNI)

Needed, at most:
1. The main page gains the control indicator (G1), reading age (G3) and a loop ring that follows G2.
2. One status page, reached from the main page: control and handover action, CGM link, pump link, dosing mode, last loop result. This replaces the separate devices, status and loop pages of the experimental branch.
3. Bolus delivery progress and cancel (G5) as an overlay or pushed view in the existing navigation path.
4. A handover confirmation (system `confirmationDialog`).

Speculative, defer until a need is shown: watch-side history, dosing mode selection on the watch, a workout-driven glance screen, a manual BG entry screen (iOS covers this unless the phone is gone for long), and new complication families.

## Open questions

1. Where should "who is in control" live on the phone: the multi-use banner (one slot, ranked) or the loop ring area? The banner fits the existing model but can be displaced by "Notifications Disabled".
2. Does the watch keep the phone-made glucose color, or compute it locally? Locally requires the glucose color settings and targets on the watch (I: yes).
3. Alarm ownership during untethered running: the watch only, or both devices with deduplication? This needs Agent E / D input on watchOS background and notification limits.
4. Is a complication with live data in scope for Phase 2? Today it is a static icon. With the watch in control, a glanceable freshness signal on the watch face could matter for safety (I).
5. Should "STALE DATA" be reworded (plain language, e.g. "No update from iPhone") when touched? It is user-visible and vague. This is a Crowdin change.
6. Bolus cancel on the watch: are the pump-driver semantics the same as on iOS (cancel accepted vs. actually stopped)? This needs Agent C / E.
7. Whether the missing `carbs` / `glucose` / `accent` color sets cause any runtime fallback (U).

## Evidence index

All paths are relative to `/Users/dnzxy/workspaces/Trio-on-watch` at `ad6c66876`.

| Topic | Evidence |
|---|---|
| Loop ring semantics | `Trio/Sources/Modules/Home/View/Header/LoopView.swift:24-213` |
| Loop status sheet strings | `Trio/Sources/Modules/Home/View/Header/LoopStatusView.swift:17-225` |
| Dosing modes | `Trio/Sources/Models/DosingMode.swift:1-101` |
| Glucose bobble, 12-min mask, CGM states, a11y | `Trio/Sources/Modules/Home/View/Header/CurrentGlucoseView.swift:37-379` |
| Sensor arc / tag | `Trio/Sources/Modules/Home/View/Header/SensorLifecycle/SensorLifecycleArcView.swift:9-47`, `SensorStatusTagView.swift:4-42` |
| Pump panel | `Trio/Sources/Modules/Home/View/Header/PumpView.swift:16-242` |
| Header composition, gestures | `Trio/Sources/Modules/Home/View/HomeRootView+Header.swift:70-199` |
| Home layout, tabs, basal pill | `Trio/Sources/Modules/Home/View/HomeRootView.swift:75-612`, `HomeLayout.swift` |
| Meal row, alarm pill | `Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift:93-202` |
| Bolus panel, banners | `Trio/Sources/Modules/Home/View/HomeRootView+BottomControls.swift:54-55,458-512,657-818` |
| Banner priority | `Trio/Sources/Modules/Home/View/MultiUsePanelState.swift:4-40` |
| Force loop | `Trio/Sources/Modules/Home/View/HomeRootView+Refresh.swift:31-95` |
| Glass chrome and a11y fallback | `Trio/Sources/Modules/Home/View/GlassChrome.swift:5-119` |
| Device issue | `Trio/Sources/Modules/Home/HomeStateModel.swift:147-150` |
| Colors | `Trio/Sources/Helpers/Color+Extensions.swift:1-75`; `Trio/Resources/Assets.xcassets/Colors/*`; `Trio Watch App Extension/Assets.xcassets/Colors/*`; `LiveActivity/Assets.xcassets/LoopGreen.colorset` |
| Glucose color | `Trio/Sources/Helpers/DynamicGlucoseColor.swift:5-81`; legend copy `Trio/Sources/Modules/Home/View/Chart/ChartLegendView.swift:122,126` |
| Background | `Trio/Sources/Application/AppState.swift:7-19` |
| Dynamic Type caps | `Trio/Sources/Application/TrioApp.swift:376-378`; `HomeRootView.swift:264-265` |
| Time / delta formatting | `Trio/Sources/Helpers/Formatters.swift:113-130`; `Trio/Sources/Models/BloodGlucose.swift:228-230` |
| iOS bolus warning and confirm | `Trio/Sources/Modules/Treatments/View/TreatmentsRootView.swift:527-596` |
| Bolus enact semantics | `Trio/Sources/APS/APSManager.swift:635-676` |
| Watch snapshot build, "N min", color hex | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift:174-330` |
| Watch acks | `Trio/Sources/Services/WatchManager/AppleWatchManager.swift:812-822,855-1065` |
| Watch main view | `Trio Watch App Extension/Views/TrioMainWatchView.swift:24-262` |
| Watch bobble and loop ring | `Trio Watch App Extension/Views/GlucoseTrendView.swift:14-163`, `Views/TrendShape.swift:62-88` |
| Watch bolus flow | `Trio Watch App Extension/Views/BolusInputView.swift:15-176`, `Views/BolusConfirmationView.swift:19-103` |
| Watch bolus progress (disabled) | `Trio Watch App Extension/Views/BolusProgressOverlay.swift:1-86` (all commented) |
| Watch carbs, menu, presets, snooze, chart | `Views/CarbsInputView.swift`, `Views/TreatmentMenuView.swift`, `Views/OverridePresetsView.swift`, `Views/TempTargetPresetsView.swift`, `Views/AlarmSnoozeView.swift`, `Views/GlucoseChartView.swift:153-232` |
| Watch state, timeouts, messages | `Trio Watch App Extension/WatchState.swift:7-228`, `WatchState+Requests.swift:9-222` |
| Watch enums, sizes, button styles | `Trio Watch App Extension/Helper/Helper+Enums.swift`, `Helper+ButtonStyles.swift`, `Helper+Extensions.swift` |
| Watch complication | `Trio Watch Complication/TrioWatchComplication.swift:1-114` |
| Live Activity on watch, stale | `LiveActivity/LiveActivity.swift:55-58`; `LiveActivity/Views/WidgetItems/LiveActivityUpdatedLabelView.swift:18-53`; `LiveActivityBGLabelWatchView.swift:15-43`; `Trio/Sources/Services/LiveActivity/LiveActivityManager.swift:273` |
| Trend arrows (text) | `Trio/Sources/Services/Calendar/CalendarManager.swift:312-340` |
| Deployment targets, asset symbols | `Trio.xcodeproj/project.pbxproj` (`IPHONEOS_DEPLOYMENT_TARGET = 17.6`, `WATCHOS_DEPLOYMENT_TARGET = 10`, `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES`) |
| Experimental screens | `git -C ~/workspaces/Trio show a56170dc0:"Trio Watch App Extension/Untethered/UntetheredViews.swift"`, `…/Views/PeripheralsView.swift`, `…/G7Direct/WatchG7View.swift`, `…/Views/TrioMainWatchView.swift`, `Trio Watch Complication/TrioWatchComplication.swift`; diff stat `3f6b238b4..a56170dc0` |
| Related upstream PRs (not in baseline) | nightscout/Trio #1648 (watch bolus safety check), #1694, #1723, #1749 (listed in `docs/trio-on-watch/README.md`) |
