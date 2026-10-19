# macOS Platform Techniques for a System-Wide Inline Autocomplete App (Cotypist-like), Swift

Research date: 2026-10-18. Method: web search, Apple developer docs (JSON endpoints), the local macOS SDK headers (CommandLineTools `MacOSX27.0.sdk`), and a direct read of the source code of four MIT-licensed open-source Cotypist-style apps: **Tabber** (chriscorbell/tabber), **Typist** (BrodySalvucci/Typist), **Cotabby** (FuJacob/cotabby) and **KeyType** (johnbean393/KeyType). Most code-level findings below come from reading those files, cited by file URL. Paths use `blob/HEAD`, so a link may move if a repo changes. Note on OS versions: the local SDK is MacOSX27.0 and Tabber's compatibility table says it was "checked live on macOS 27", so macOS 27 appears to be current as of October 2026. I found no sources on macOS 27-specific API changes (see Gaps).

---

## 1. Reading the focused text and caret through Accessibility (AX): APIs, observers, latency, timeouts

### Takeaway
Every working OSS clone uses the same core: `AXUIElementCreateSystemWide()` → `AXFocusedUIElement` → read `AXValue`/`AXSelectedTextRange`/`AXNumberOfCharacters`, then `AXStringForRange`/`AXBoundsForRange`/`AXAttributedStringForRange` for windowed text, geometry and font. No single change signal is reliable, so the mature implementations combine three: AXObserver notifications, a short burst of re-reads after each keystroke, and a slow idle poll. They also clamp the AX messaging timeout to 50–250 ms so a hung app cannot stall the pipeline.

### Cited Findings
- **Attribute set used in practice (Tabber `AXName`)**: element attributes `AXRole`, `AXSubrole`, `AXRoleDescription`, `AXValue`, `AXPlaceholderValue`, `AXFocusedUIElement`, `AXSelectedTextRange`, `AXNumberOfCharacters`, `AXTextInputMarkedRange` (alt `AXMarkedTextRange`), `AXMultiLine`, `AXEditable`, `AXEditableAncestor`, `AXURL`, `AXDocument`, `AXWindow`, `AXPosition`, `AXSize`. Parameterized: `AXStringForRange`, `AXBoundsForRange`, `AXAttributedStringForRange`. For web content it uses the WebKit/Chromium **text-marker** family: `AXSelectedTextMarkerRange`, `AXTextMarkerRangeForUIElement`, `AXStringForTextMarkerRange`, `AXAttributedStringForTextMarkerRange`, `AXBoundsForTextMarkerRange`, `AXLengthForTextMarkerRange`, `AXPreviousTextMarkerForTextMarker`, `AXNextTextMarkerForTextMarker`, with the `AXTextMarkerGetTypeID`/`AXTextMarkerRangeCopyStartMarker` C APIs. Notifications: `AXFocusedUIElementChanged`, `AXFocusedWindowChanged`, `AXValueChanged`, `AXSelectedTextChanged`, `AXUIElementDestroyed` — [Tabber AXClient.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/AXClient.swift)
- Tabber uses plain string literals for attribute names "so nothing depends on which SDK macros Swift imports". Its `AXCast` helper checks `CFGetTypeID` before every cast, because "AX returns whatever the app put there" — [Tabber AXClient.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/AXClient.swift)
- **Batching**: `AXUIElementCopyMultipleAttributeValues` fetches several attributes in one IPC round trip. Some apps don't implement the batched form, so Tabber falls back to one call per attribute. In that fallback it **stops at the first `.cannotComplete`/`.invalidUIElement`**: "A dead or hung app fails every attribute the same way; don't spend the timeout N times." `AXUIElementGetPid` maps elements to a pid, and `CFEqual`/`CFHash` give remote element identity, so elements can serve as dictionary keys — [Tabber AXClient.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/AXClient.swift)
- **Change detection**: "Changes are picked up three ways, because no single one is reliable across apps: AXObserver notifications, a short burst of reads after each keystroke (`refreshSoon()`), and a slow idle poll." The idle poll's base interval is 0.5 s, backing off to 4x while nothing changes. The text window is 4000 UTF-16 units before the caret and 1000 after. Observers are created per pid with `AXObserverCreate` and `AXObserverAddNotification`: the app element registers for focus/window changes, the focused field for value/selection/destroyed — [Tabber FocusTracker.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/FocusTracker.swift); [Tabber architecture.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/architecture.md)
- After a key, "the focus tracker re-reads the field until the app has published the change" (apps publish AXValue asynchronously) — [Tabber architecture.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/architecture.md)
- **Threading, two conflicting approaches:**
  - **Tabber** runs all AX IPC on a dedicated thread with its own `CFRunLoop`. AXObserver run-loop sources and timers live there, "so a slow app can never stall the main thread". The thread has `.userInteractive` QoS and uses `CFRunLoopPerformBlock`. Timers are repeating `CFRunLoopTimer`s with huge intervals, because "a non-repeating CF timer invalidates itself after firing and can't be re-armed" — [Tabber AXThread.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/AXThread.swift)
  - **Cotabby** instead annotates its Chromium enabler `@MainActor` with the comment "all AX calls must run on the main thread, matching `FocusTracker`" — [Cotabby ChromiumAccessibilityEnabler.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Focus/Chromium/ChromiumAccessibilityEnabler.swift)
- **Messaging timeout values in the OSS apps**: Tabber sets `AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.08)`, i.e. "a hung app costs at most this per call" ([Tabber FocusTracker.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/FocusTracker.swift)). Cotabby uses 0.05 s per element (`pollMessagingTimeout`), set on each element including the app and menu elements ([Cotabby AXHelper.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Support/Accessibility/AXHelper.swift)). Typist uses 0.25 s on the system-wide, app and focused elements ([Typist AccessibilityReader.swift](https://github.com/BrodySalvucci/Typist/blob/HEAD/Sources/Typist/AccessibilityReader.swift))
- **Timeout semantics (Apple header)**: "Pass the system-wide accessibility object … if you want to set the timeout globally for this process. Setting the timeout on another accessibility object sets it only for that object, not for other accessibility objects that are equal to it. Setting timeoutInSeconds to 0 for the system-wide accessibility object resets the global timeout to its default value." `kAXErrorCannotComplete` means "messaging has failed in some way or the application has not yet responded" — [macOS 27.0 SDK HIServices/AXUIElement.h (local CommandLineTools SDK)](file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXUIElement.h)
- `AXUIElementCopyElementAtPosition` "Returns the accessibility object at the specified position in top-left relative screen coordinates", using window z-order hit-testing — [AXUIElement.h (SDK)](file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXUIElement.h). Cotabby uses it as "the only query that crosses Chrome's out-of-process-iframe boundary … the last resort for OOPIF editors like Gmail compose that surface through no focused-element attribute" — [Cotabby AXHelper.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Support/Accessibility/AXHelper.swift)
- **Debounce**: Typist debounces 120 ms after a key press before calling `AccessibilityReader.snapshot()` (text before/after caret, caret rect) — [Typist ARCHITECTURE.md](https://github.com/BrodySalvucci/Typist/blob/HEAD/docs/ARCHITECTURE.md)
- **Marked text**: IME compositions and macOS inline predictive text (Sonoma and later, on by default in every NSTextView: TextEdit, Notes, Mail, Messages) "are reported in `AXValue` like committed text, with the selection sitting at the caret". A naive reader therefore sees the text after the caret change and paints a second completion over the system's own. Cotabby treats the marked range as host-owned and suppresses its ghost while it is present. Gmail's Smart Compose writes its gray suggestion plus a "tab" hint line into the editable text, so AX reads it as user text — [Cotabby HostMarkedTextPolicy.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Support/Input/HostMarkedTextPolicy.swift); [Cotabby SuggestionCoordinator+HostMarkedText.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/App/Coordinators/Suggestion/SuggestionCoordinator+HostMarkedText.swift)
- **Stale TCC**: developers report `AXIsProcessTrusted` returning true while AX calls fail with `.cannotComplete` or return no data sporadically. One workaround was resetting with `tccutil` — [Apple Forums 794253](https://developer.apple.com/forums/thread/794253); [Apple Forums 703188](https://developer.apple.com/forums/thread/703188); [Apple Forums 750172](https://developer.apple.com/forums/thread/750172)

### Inferences
- Recommended skeleton: a dedicated AX thread with a run loop (Tabber pattern), a global messaging timeout of about 50–100 ms, `AXUIElementCopyMultipleAttributeValues` first with a per-attribute fallback, AXObservers re-registered on every app activation (`NSWorkspace.didActivateApplicationNotification`), plus a post-keystroke re-read burst. Keep the AX reader and the event-tap callback on separate threads. The tap must never wait on AX.
- Read a bounded window with `AXStringForRange` around the caret instead of the full `AXValue` for large documents, to cap IPC payloads (Tabber's 4000/1000 window).
- Always check for `AXTextInputMarkedRange` (non-empty means IME composition or system prediction) before generating.

### Gaps
- Apple's default global AX messaging timeout value is not stated in the header. It is commonly cited as about 6 s, but I found no primary source.
- No published benchmarks of per-call AX latency across apps. Tabber has a `tabber-probe` tool and `docs/benchmarks.md` (not read) that may contain numbers.

---

## 2. Problem apps (Chromium/Electron, web content, Google Docs, terminals, Office, Java, Catalyst, secure fields) and fallbacks

### Takeaway
Chromium and Electron build their AX tree lazily: you must set `AXManualAccessibility` (Electron) or `AXEnhancedUserInterface` (Chromium browsers, Firefox) on the app element. `AXEnhancedUserInterface` has side effects: it disturbs window managers and slows animations, and other tools switch it off again. Canvas-rendered editors (Google Docs without screen-reader mode, Figma), remote desktops and games expose nothing. Terminals and code editors are disabled by default in every clone. Secure input blocks the event tap entirely. The fallbacks in use are a "mirror card" (show the suggestion in a floating card when the caret is unknown), ScreenCaptureKit + Vision OCR (used for context and pixel caret location, not for reading the field), and a keystroke buffer.

### Cited Findings
- **Electron official**: third-party assistive technology can enable Electron's accessibility by setting `AXManualAccessibility` on the app element. Sample: `AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, true as CFTypeRef)`. Electron also enables accessibility automatically when assistive tech is present — [Electron accessibility docs](https://www.electronjs.org/docs/latest/tutorial/accessibility)
- `AXManualAccessibility` was added because `AXEnhancedUserInterface` "is already reserved by VoiceOver" — [Electron commit #7206 mirror](https://ayakael.net/mirrors/electron/commit/94dd068e15314ba990fb7b96a6c8e4ff100b19c1)
- **Side effect**: a developer reports that setting `AXEnhancedUserInterface` = true breaks window positioning in window managers such as Magnet. Electron avoids this with `AXManualAccessibility`, "Chromium apps still use AXEnhancedUserInterface" (no Apple reply) — [Apple Forums 659755](https://developer.apple.com/forums/thread/659755)
- **Rectangle** (window manager) reads `AXEnhancedUserInterface` on the app, logs "AXEnhancedUserInterface was enabled, will disable before resizing", writes it false, performs the frame adjustment and restores it. It skips this when VoiceOver or Switch Control is on — [Rectangle AccessibilityElement.swift](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift)
- **Tabber's web enabler**:
  - Detects Electron by the presence of `Contents/Frameworks/Electron Framework.framework`.
  - Detects Chromium browsers by bundle-ID prefix (Chrome, Brave, Edge, Arc `company.thebrowser.Browser`, Dia, Vivaldi, Opera, Chromium, Helium), plus other forks via `"<App> Framework.framework/Helpers"`.
  - Includes Firefox/Zen because they "also expose their content only when AXEnhancedUserInterface is set".
  - Tries `AXManualAccessibility` first, with `AXEnhancedUserInterface` as a fallback "because it can slow window animations".
  - "Chrome reports an error from this setter even when it applies the value, so read it back."
  - "On one test machine, every activation of Chrome cleared `AXEnhancedUserInterface` within 50 ms", so the flag is re-checked after activation and whenever a web caret can only be estimated.
  - [Tabber WebAccessibility.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/WebAccessibility.swift)
- **Cotabby's Chromium findings**:
  - Without priming, "a Chrome renderer reports itself AX-unaware and the system-wide focus query keeps returning the omnibox (or nil)".
  - Set the flag on the **browser process** element, never renderer subprocesses.
  - "`AXManualAccessibility` is an Electron addition; Chrome itself rejects it". Chrome's full mode, with inline text boxes and therefore character bounds and fonts, needs the VoiceOver signal `AXEnhancedUserInterface`. They measured (2026-09) that "all four test fields returned empty bounds and an empty font dictionary until this flag was set".
  - Electron editors such as VS Code must be **re-primed on every activation**: "the first `AXManualAccessibility` write returns success … yet the web-AX tree stays dormant for minutes".
  - They keep the `AXEnhancedUserInterface` fallback narrow because "changing it globally can affect window managers".
  - [Cotabby ChromiumAccessibilityEnabler.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Focus/Chromium/ChromiumAccessibilityEnabler.swift)
  - The two sources conflict on whether Chrome accepts `AXManualAccessibility`. Tabber tries it first on Chromium browsers and keeps whichever flag reads back true; Cotabby says Chrome rejects it.
- **Verified per-app results (Tabber, macOS 27)**:
  - Ghost text works in TextEdit, Safari textarea, Chrome textarea ("needs Chrome's accessibility tree, which Tabber turns on"; font "inferred from word positions (Chrome reports size only)"), an Electron contenteditable, Discord, Slack web, Word, Notes, Messages and Mail compose.
  - Microsoft Teams "answers every character-bounds query with an empty rect", so the caret comes from the frame of the last text run, and wrapped messages fall back to the mirror card.
  - Mail's compose body "doesn't report its text to Accessibility for read-back".
  - Known gaps: "Apps that draw text themselves without exposing it to Accessibility (Google Docs without screen-reader mode, Figma, games, remote desktops) can't get suggestions". Firefox is untested and expected to need the mirror card.
  - Off by default: terminals, code editors (Xcode, VS Code, Cursor, Zed, JetBrains) and password managers.
  - [Tabber compatibility.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/compatibility.md)
- Typist: no suggestions in "some terminals, Google Docs without its accessibility mode, a few custom editors". It sets `AXManualAccessibility` so Chromium and Electron expose text — [Typist README](https://github.com/BrodySalvucci/Typist); [Typist ARCHITECTURE.md](https://github.com/BrodySalvucci/Typist/blob/HEAD/docs/ARCHITECTURE.md)
- **Google Docs**: it moved from HTML to canvas rendering starting May 2021. Google said screen readers, braille and magnifiers "will not be impacted" — [Google Workspace Updates](https://workspaceupdates.googleblog.com/2021/05/Google-Docs-Canvas-Based-Rendering-Update.html). WebAIM worried about losing the DOM semantic underlay and noted that accessibility support works "with accessibility settings enabled" — [WebAIM](https://webaim.org/blog/seismic-change-to-docs/)
- **Per-app fallbacks in KeyType**: per-app caret-geometry fallbacks for Outlook, Mail single-line, Messages rich preview, Word search, Xcode find, MarkEdit and code editors, plus text-context fallbacks for WeChat, Mail compose and ChatWise. The AppCompatibility overrides cover Terminal, Xcode, VS Code, Android Studio, Cursor (`com.todesktop.230313mzl4w4u92`), Sublime, Safari, Chrome, Excel, Pages, Mail, Messages, iA Writer, WeChat and Obsidian — [KeyType repo tree](https://github.com/johnbean393/KeyType); [KeyType DefaultOverrides.swift](https://github.com/johnbean393/KeyType/blob/HEAD/Packages/AppCompatibility/Sources/AppCompatibility/DefaultOverrides.swift)
- **Grammarly's developer guidance**: on Mac, text must be exposed to accessibility (`setAccessibilityElement` on the NSView; NSTextView works out of the box). For web and Electron, use contenteditable or textarea wider than 150 px — [Superhuman/Grammarly help](https://help.superhuman.com/hc/en-us/articles/46242102540813-How-do-I-integrate-Grammarly-with-my-website-or-application)
- **Secure fields and Secure Event Input**:
  - Detection signals: `AXSecureTextField` role or subrole, or a role description containing "secure"/"password" ([Tabber FieldReader.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/FieldReader.swift)).
  - Cotabby found that a native `NSSecureTextField` announces itself via the *role description* ("secure text field"), and that CVV, security-code and OTP fields never contain "password", so it uses a broader marker set ([Cotabby SecureFieldDetector.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Support/Accessibility/SecureFieldDetector.swift)).
  - TN2150: `EnableSecureEventInput` protects keyboard input from intercept processes, event taps included ([Apple TN2150](https://developer.apple.com/library/mac/technotes/tn2150/_index.html)).
  - "When Secure Event Input is on (a password field anywhere, some terminals), the session tap receives no key events at all." Tabber checks `IsSecureEventInputEnabled()` and finds the holder with `CGSessionCopyCurrentDictionary()["kCGSSessionSecureInputPID"]` ([Tabber KeyboardMonitor.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/KeyboardMonitor.swift)).
  - Leaked secure input (reported for Cursor) breaks all system-wide taps until the app quits or the screen is locked ([Cursor forum](https://forum.cursor.com/t/cursor-leaks-secure-event-input-breaks-all-system-wide-input-taps-until-quit-or-screen-lock/167585)).
  - Hammerspoon docs: with secure input on, it "is not able to intercept keyboard events" ([hs.eventtap docs](https://commandpost.fcp.cafe/api-references/hammerspoon/hs.eventtap.md)).
  - Typist pauses automatically while Secure Input is active ([Typist README](https://github.com/BrodySalvucci/Typist)).
- **OCR via ScreenCaptureKit + Vision**: Tabber and Typist both use `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)`, then `SCContentFilter(desktopIndependentWindow:)`, then `SCScreenshotManager.captureImage(contentFilter:configuration:)`, then `VNRecognizeTextRequest` with `recognitionLevel = .accurate`. They use it for *context* text near the field, not as the primary text source. Typist caches for 20 s, in memory only — [Tabber WindowCapture.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberContext/WindowCapture.swift); [Typist ScreenContext.swift](https://github.com/BrodySalvucci/Typist/blob/HEAD/Sources/Typist/ScreenContext.swift); [Typist ARCHITECTURE.md](https://github.com/BrodySalvucci/Typist/blob/HEAD/docs/ARCHITECTURE.md)
- **Keystroke-buffer fallback**: GhostType uses `NSEvent.addGlobalMonitorForEvents` plus AX. Where AX doesn't expose text (Slack, Discord, some Electron apps, web inputs), a manual trigger (Option+\\) uses an internal keystroke buffer — [GhostType dev.to write-up](https://dev.to/mk668a/i-built-ghosttype-copilot-style-ghost-text-completion-for-every-app-on-macos-1o16)

### Inferences
- Priority order for a new app:
  1. Prime Chromium/Electron (`AXManualAccessibility`, then guarded `AXEnhancedUserInterface` with read-back and periodic re-assert).
  2. Classic `CFRange` AX attributes.
  3. Text-marker attributes for WebKit/Chromium contenteditable.
  4. Last text-run frame heuristics.
  5. Pixel or OCR caret location.
  6. Mirror card.
  7. Disable for the app.
- Default-off list: terminals (they often hold secure input or expose a grid, not a text field), code editors, password managers, canvas apps, remote desktop. Ship with per-app and per-domain overrides.
- Java (Swing/JavaFX) and Catalyst apps were not tested in any source I found. They expose AX through their own bridges, so expect partial support and verify with Accessibility Inspector.

### Gaps
- No source found on Microsoft Office for Mac beyond Tabber's Word and Teams results and KeyType's Outlook/Word fallbacks (Excel and PowerPoint untested).
- No source on Java Access Bridge behavior on macOS or Catalyst text fields.
- Whether Google Docs' "screen reader support" mode currently exposes a full AX text tree with bounds on macOS is unconfirmed (2021 sources only).

---

## 3. Getting the caret rectangle reliably (zero-length ranges, coordinate flips, Retina, multi-monitor)

### Takeaway
`AXBoundsForRange` with a zero-length range at the caret works in TextKit apps but is often wrong elsewhere. Failure modes include a rect at (0,0), the whole element frame, empty rects, bottom-left origin or backing-pixel coordinates, and rects one line too high after a newline. Robust code validates every candidate, tries the bounds of the previous or next character and uses their trailing or leading edge, repairs flipped or pixel-scaled rects, and falls back to text-run frames, pixel analysis or a mirror card.

### Cited Findings
- **Typist's simple strategy**: `bounds(location, length: 0)` first, else `bounds(location-1, length: 1)` (the previous character's trailing edge) — [Typist AccessibilityReader.swift](https://github.com/BrodySalvucci/Typist/blob/HEAD/Sources/Typist/AccessibilityReader.swift)
- **Tabber's validation and repair rules** ([Tabber CaretMath.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/CaretMath.swift)):
  - AX rects are global Quartz coordinates (top-left origin, y down).
  - Plausible means finite, height ≥ 1 and < 200 pt, within 60 pt "slack" of the field frame.
  - "'Don't know' often comes back as a rect at the origin. Real text can't be there: the menu bar is."
  - "Chromium answers some queries with the element's whole frame. A caret can't fill a multi-line field" (reject when the field height is > 48 and the rect height is > 80% of it).
  - "Some apps report text bounds with a bottom-left origin, or in backing pixels". The repair candidates are `y' = primaryScreenHeight - rect.maxY` and `rect / backingScale`, each accepted only if it lands squarely on the field (8 pt slack).
  - "Bounds for one character can be a whole line in some apps", so a character rect is only used if its width is ≤ max(3×height, 48).
  - The caret after a character is its trailing edge (its left edge for RTL); before a character it is the leading edge. An RTL detector covers Hebrew, Arabic and others.
  - "Zero-length bounds come back one line too high in TextKit". Fix: if the caret is above the previous newline's line, or entirely above the field, move it down one line. "Chromium reports a zero-width newline at the start of the next line instead."
  - Single-line run heuristic (< 26 pt tall): the caret goes at the run frame's trailing edge if the text before the caret ends with the run text. This is how Teams is handled.
  - Last resort is an estimate from the field frame (first line, 4 pt inset, default 17 pt line).
  - `DisplayInfo` uses `CGDisplayBounds(CGMainDisplayID())` and `CGGetDisplaysWithPoint` with `CGDisplayCopyDisplayMode` pixelWidth/points for scale, because CoreGraphics "unlike NSScreen is safe off the main thread".
- **Cotabby's pixel caret locator** uses ScreenCaptureKit captures of the host's own pixels. One case is hosts that expose a wrapped paragraph as one static-text run with no bounds answers (Obsidian's CodeMirror, measured 2026-09-09). Another is "Chrome's address bar … `AXBoundsForRange` returns a zero rect for every range, the font dictionary is empty". The caret is taken as the right edge of the last inked line. Captures exclude Cotabby's own windows ("an excluded window comes back black") — [Cotabby PixelCaretLocator.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Presentation/PixelCaretLocator.swift). Cotabby also has dedicated geometry modules (`DisplayCoordinateConverter`, `InkCaretAnalyzer`, `InkBaselineAnalyzer`, `TextLayoutCaretEstimator`, `CaretLagPolicy`) — [Cotabby repo tree](https://github.com/FuJacob/cotabby)
- **Coordinate systems**: `AXUIElementCopyElementAtPosition` takes "top-left relative screen coordinates" ([AXUIElement.h (SDK)](file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXUIElement.h)). Cotabby converts Cocoa (bottom-left) points to top-left before calling it ([Cotabby AXHelper.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Support/Accessibility/AXHelper.swift)).
- **Type-through lag**: when the user types faster than the app publishes AX updates, Tabber shifts the drawn ghost by the width of the characters already consumed ([Tabber architecture.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/architecture.md)).
- **Analogous issues on other platforms**: AT-SPI `get_character_extents` returns 0,0 for some offsets, e.g. a caret on a newline, and gives no usable caret on empty text ([Orca list](https://mail.gnome.org/archives/orca-list/2016-August/msg00017.html)). Windows UIA `IUIAutomationTextPattern2::GetCaretRange` returns a zero-length range at the caret ([Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationtextpattern2-getcaretrange)).

### Inferences
- Conversion to Cocoa for placing an NSPanel: `cocoaY = primaryScreenHeight - quartzRect.maxY`, where the primary screen is the one at index 0 / `CGMainDisplayID()` with origin (0,0). This works across multiple monitors because both systems are global and anchored to the primary display. Never use the height of the screen the caret is on.
- For an empty field, `AXBoundsForRange(0,0)` frequently fails. Fall back to the field frame plus placeholder metrics, or the mirror card.
- Cache "which strategy worked" per app and field to avoid repeated failing IPC.

### Gaps
- No Apple documentation found on the expected semantics of `AXBoundsForRange` for zero-length ranges. The behavior is empirical, from OSS code comments.

---

## 4. Drawing the overlay (window type, level, Spaces, font matching, no focus stealing)

### Takeaway
All four clones use a borderless, transparent, click-through `NSPanel` with `.nonactivatingPanel`, `canBecomeKey == false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, (.stationary), .ignoresCycle]`, at a level from `.statusBar` up to `.screenSaver`. Font matching uses `AXAttributedStringForRange` → `AXFont` dictionary (`AXFontName`/`AXFontFamily`/`AXFontSize`) and `AXForegroundColor`. When an app reports only a size (Chrome), fall back to matching by measured width, or use the system font sized from the caret height.

### Cited Findings
- **Tabber GhostPanel**:
  - `styleMask: [.borderless, .nonactivatingPanel]`, `isFloatingPanel = true`, `level = .popUpMenu`.
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.
  - `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `ignoresMouseEvents = true`, `hidesOnDeactivate = false`, `animationBehavior = .none`, `becomesKeyOnlyIfNeeded = true`.
  - `setAccessibilityElement(false)`, with overrides `canBecomeKey`/`canBecomeMain` → false.
  - `constrainFrameRect` is overridden to return the frame unchanged ("Never nudge the frame onto a screen").
  - [Tabber GhostPanel.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberOverlay/GhostPanel.swift)
- **Levels used by the others**: Cotabby uses `NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)` ([Cotabby OverlayController.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Presentation/OverlayController.swift)), KeyType `.screenSaver` ([KeyType GhostTextOverlayWindow.swift](https://github.com/johnbean393/KeyType/blob/HEAD/Packages/CompletionUI/Sources/CompletionUI/GhostTextOverlayWindow.swift)), and Typist `.statusBar` with the same click-through and collection-behavior flags ([Typist SuggestionOverlay.swift](https://github.com/BrodySalvucci/Typist/blob/HEAD/Sources/Typist/SuggestionOverlay.swift))
- **Font and color parsing**: remote apps send `AXFont` (a dictionary with `AXFontName`, `AXFontFamily`, `AXFontSize`, `AXVisibleName`) and `AXForegroundColor` (a CGColor). In-process strings carry `NSFont`/`NSColor` instead. "WebKit (and the AX bridge generally) tags colors as Generic RGB while the components are the page's sRGB values: converting would lighten them", so the components are taken raw — [Tabber TextStyleParser.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/TextStyleParser.swift). The SDK constants are `kAXFontTextAttribute` (a dictionary that must contain `kAXFontNameKey` and `kAXFontSizeKey`, and may contain `kAXFontFamilyKey`) and `kAXForegroundColorTextAttribute` (CGColorRef) — [HIServices/AXTextAttributedString.h (SDK)](file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXTextAttributedString.h)
- **Font resolution**:
  - Tabber picks the exact face, else the family, else the system font.
  - "When the name and family disagree (Word reports a fake 'Helvetica' name with the real family), the family wins."
  - When only a size is reported, it matches the rendered width of a text sample against candidate families: Helvetica, Arial, Georgia, Times New Roman, Verdana, Trebuchet MS, Menlo, Courier New, Inter, Roboto, Open Sans, Lato, Avenir Next, Palatino.
  - Size is sanity-checked against caret height and clamped to 6–96 pt.
  - The ghost color is the host text color at about 0.5 opacity.
  - [Tabber FontResolver.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberOverlay/FontResolver.swift); [Tabber architecture.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/architecture.md)
- Typist uses the system font sized from the caret height ("so it won't exactly match") and offers per-app "text size and offset" corrections — [Typist README](https://github.com/BrodySalvucci/Typist)
- **Mirror card**: "Where an app doesn't report the caret position, a small mirror card shows the suggestion instead" — [Tabber README](https://github.com/chriscorbell/tabber). Cotabby also shows a card when text follows the caret on the same line — [Cotabby PixelCaretLocator.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Presentation/PixelCaretLocator.swift)
- Apple Forums has an unanswered thread asking how to make Grammarly-like floating UI — [Apple Forums 720686](https://developer.apple.com/forums/thread/720686)

### Inferences
- Use `.nonactivatingPanel` plus `orderFrontRegardless()` (never `makeKeyAndOrderFront`) so the host keeps key focus. `setAccessibilityElement(false)` keeps the overlay from becoming the AX-focused element or confusing VoiceOver.
- Exclude the overlay from your own OCR captures (ScreenCaptureKit filter) so the ghost is never read back as host text (Cotabby does this).
- Draw with Core Text/`NSAttributedString` at the resolved font. Position the baseline from `ascent` relative to the caret rect's top, not the rect's bottom.

### Gaps
- No source found on Stage Manager or macOS 26/27 window-level interactions (e.g. whether `.statusBar` overlays appear over full-screen apps on all configurations). Each repo chose a different level without documenting why.

---

## 5. Intercepting accept/dismiss keys (CGEventTap): tap types, permissions, timeouts

### Takeaway
Use a session-level (`.cgSessionEventTap`) tap at `.headInsertEventTap`. To consume Tab it must be an active `.defaultTap`, which requires Accessibility. Never block or call AX inside the callback. Re-enable on `.tapDisabledByTimeout`. Mark your own synthetic events (`eventSourceUserData`) so the tap ignores them. A refined pattern (Cotabby) keeps a permanent listen-only tap for observation and installs the active consuming tap only while a suggestion is visible.

### Cited Findings
- **Tabber's tap**:
  - `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keyDown|keyUp|flagsChanged|left/right/otherMouseDown, …)` on its own thread with its own run loop. The source is added with `.commonModes`.
  - The callback "never blocks, never calls Accessibility, and never waits on the main thread". It decides from an in-memory `InterceptState` (is a ghost visible, which keys accept) behind an `OSAllocatedUnfairLock` and reports asynchronously via `DispatchQueue.main.async`.
  - It returns `nil` to swallow, and also swallows the matching keyUp.
  - It re-enables on `.tapDisabledByTimeout`/`.tapDisabledByUserInput`.
  - Synthetic events are skipped when `getIntegerValueField(.eventSourceUserData) == marker` (0x54414242, "TABB").
  - It reads the characters via `keyboardGetUnicodeString`.
  - `tapCreate` returning nil maps to "Usually Accessibility permission is missing".
  - [Tabber KeyboardMonitor.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/KeyboardMonitor.swift); [Tabber SyntheticText.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/SyntheticText.swift)
- Tabber "never owns Tab unless a suggestion is visible". Option-Tab sends a real Tab through, and a `passThroughTab()` re-posts Tab when needed — [Tabber README](https://github.com/chriscorbell/tabber); [Tabber TextInserter.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/TextInserter.swift)
- **Cotabby's two-tap design**:
  - "A steady-state `.listenOnly` observer at the head of the chain. Listen-only taps do not gate event delivery on the callback's return, so a slow main actor cannot stall input in unrelated apps (DaVinci Resolve's Spacebar play/pause is the canonical victim of an active tap here — see issue #328)", plus "a narrow `.defaultTap` accept tap at the tail, installed only while a suggestion is visible."
  - Pitfall: tearing down the accept tap in the same run-loop turn that posted the final synthetic keystroke "pulls the tap out of the session tap chain before the just-posted synthetic keystroke drains through it, so the last accepted word never reaches the host". They delay teardown by 0.05 s.
  - [Cotabby InputMonitor.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Input/InputMonitor.swift)
- **Apple doc**: event taps receive key events if the process runs as root or "access for assistive devices is enabled"; `tapCreate` returns NULL if the tap cannot be created — [CGEvent.tapCreate docs](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- **Permission APIs** (macOS 10.15+): `CGPreflightListenEventAccess`, `CGRequestListenEventAccess` ("Requests event listening access if absent, potentially prompting"), `CGPreflightPostEventAccess` and `CGRequestPostEventAccess` — [CoreGraphics/CGEvent.h (SDK)](file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreGraphics.framework/Headers/CGEvent.h). Apple DTS (Quinn): "If you're just using CGEventTap, there's CGPreflightListenEventAccess, CGRequestListenEventAccess, CGPreflightPostEventAccess, and CGRequestPostEventAccess. You only need the Accessibility privilege if you're doing other stuff with Accessibility APIs." — [Apple Forums 744440](https://developer.apple.com/forums/thread/744440). DTS also says listen-only taps use the separate ListenEvent TCC service — [Apple Forums 735204](https://developer.apple.com/forums/thread/735204)
- **Developer reports on prompts**: a `defaultTap` triggers the Accessibility prompt while `listenOnly` triggers Input Monitoring. An app that already has Accessibility gets no Input Monitoring prompt, and this behavior may vary by version — [Apple Forums 122492](https://developer.apple.com/forums/thread/122492). On macOS 15, `CGRequestListenEventAccess()` shows the prompt once per install but doesn't always add the app to the Input Monitoring list — [Apple Forums 828052](https://developer.apple.com/forums/thread/828052)
- **Revocation hazard**: revoking Accessibility while an active tap runs can make input unresponsive, with no timeout callback observed first ([Apple Forums 844416](https://developer.apple.com/forums/thread/844416)), or hang the app ([Apple Forums 735204](https://developer.apple.com/forums/thread/735204); FB13533901 per [744440](https://developer.apple.com/forums/thread/744440))
- **SDL's convention**: re-enable on `kCGEventTapDisabledByTimeout`, but leave a tap disabled by user input or another program disabled — [SDL commit mirror](https://git.axiodl.com/encounter/SDL/commit/51ccc9ed8cab7bf1e3ea293328f2e382eceaf273). Tabber and Cotabby re-enable on both.
- Typist and GhostType contrast: Typist uses a session event tap, "Sees keys first and swallows shortcuts. Events posted by Typist carry a marker and are ignored" ([Typist ARCHITECTURE.md](https://github.com/BrodySalvucci/Typist/blob/HEAD/docs/ARCHITECTURE.md)). GhostType uses `NSEvent.addGlobalMonitorForEvents` and needs Input Monitoring plus Accessibility ([GhostType write-up](https://dev.to/mk668a/i-built-ghosttype-copilot-style-ghost-text-completion-for-every-app-on-macos-1o16)). A global NSEvent monitor cannot consume events.

### Inferences
- A session tap is sufficient and preferable to a HID tap (`.cghidEventTap`): it sees the same keys after layout and modifier processing, and a HID tap is lower-level with higher stall risk.
- Poll `CGPreflightListenEventAccess()`/`AXIsProcessTrusted()` on a timer, and tear the active tap down proactively when trust disappears, to avoid the revocation freeze.
- Keep the callback O(1). With a bounded-time callback, `.tapDisabledByTimeout` (the system disables slow taps) should be rare.

### Gaps
- No official Apple table maps tap options to TCC services (Accessibility vs Input Monitoring). The evidence is DTS forum replies and developer reports.

---

## 6. Inserting accepted text: AX setters vs synthetic Unicode keystrokes vs pasteboard + Cmd-V

### Takeaway
The OSS clones default to **synthetic keyboard events carrying Unicode strings** (`CGEventKeyboardSetUnicodeString`), sent in chunks of at most 20 UTF-16 units. The app sees them as typing, so undo, autocorrect, rich-text styling and Electron/web input events behave naturally. **Pasteboard + Cmd-V with restore** is the fallback for apps that ignore the Unicode payload. macOS 15.4+/26 pasteboard privacy now complicates the clipboard save/restore step. Writing `kAXSelectedTextAttribute`/`kAXValueAttribute` is the least used path because web fields and undo behave unpredictably.

### Cited Findings
- **Apple doc**: `keyboardSetUnicodeString` overrides the string normally derived from the virtual key code. "Application frameworks may ignore the Unicode string in a keyboard event and do their own translation based on the virtual keycode" — [CGEvent.keyboardSetUnicodeString docs](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:))
- **20-unit limit**: "CGEventKeyboardSetUnicodeString delivers at most 20 UTF-16 units per event" ([Tabber SyntheticText.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/SyntheticText.swift)). Typist chunks at 20 and doesn't split surrogate pairs ([Typist TextInserter.swift](https://github.com/BrodySalvucci/Typist/blob/HEAD/Sources/Typist/TextInserter.swift)). espanso: "Because of a bug (or undocumented limit) of the CGEventKeyboardSetUnicodeString method the string gets truncated after 20 characters". It sends chunks of 20, or 1 when a custom delay is set, to `kCGHIDEventTap` with `usleep` delays ([espanso native.mm](https://github.com/espanso/espanso/blob/dev/espanso-inject/src/mac/native.mm)).
- **Tabber's insertion details** ([Tabber TextInserter.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/TextInserter.swift)):
  - Choice of virtual key code for Unicode events: "0 (A) is the safe default … Avoid 49 (pages see a Space press), 52 (the U.S. layout maps it to Enter, which could send a message), and unassigned codes like 102 or 127 (Chrome drops the event)." Web pages see the key as `code: "KeyA"`.
  - Newlines are sent as Return key presses ("many apps ignore a newline carried as Unicode text").
  - Posting location is `.cgAnnotatedSessionEventTap`: "skips every session-level tap (including ours) and goes straight to the focused app".
  - Uses `CGEventSource(stateID: .privateState)` with `userData = marker` and `localEventsSuppressionInterval = 0` ("Never hold back the user's own keystrokes").
  - Sets explicit `event.flags` so a held modifier never merges in.
  - Waits 1 ms between chunks (keystrokes mode) and 2 ms per grapheme (character mode).
  - Replacements are made with Backspace presses (key code for delete).
- **Pasteboard path (Tabber)**:
  - Snapshot all items, write the text marked as transient, post Cmd-V, then restore after 0.3 s, but only if `changeCount` is still ours. Consecutive pastes need at least 0.08 s between them.
  - The Cmd-V key code is resolved from the current keyboard layout (`KeyboardLayout.keyCodeForCommand("v")`) and refreshed on `kTISNotifySelectedKeyboardInputSourceChanged` (non-QWERTY layouts).
  - If the snapshot read was refused, it doesn't clobber the clipboard and falls back to keystrokes.
  - "On macOS 15.4+ reading the general pasteboard needs the user's permission (System Settings > Privacy > Paste from Other Apps)". It checks `NSPasteboard.general.accessBehavior` (`.alwaysAllow`/`.alwaysDeny`/ask).
  - [Tabber TextInserter.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/TextInserter.swift); [Tabber PasteboardSnapshot.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/PasteboardSnapshot.swift)
- **Pasteboard privacy**: Apple added an alert when an app programmatically reads the general pasteboard, unless the read follows a paste-related user action. The new `detect` methods inspect types without reading. `NSPasteboard.accessBehavior` gives always allow / never / ask. The developer preview is enabled with `defaults write <bundle id> EnablePasteboardPrivacyDeveloperPreview -bool yes` — [Michael Tsai summary of Apple notes](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4). The default for the general pasteboard is "ask" on programmatic access — [Apple: NSPasteboard.AccessBehavior.default](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/default.md). As of the macOS 26 beta 4 era, there was no MDM control for "Paste from Other Apps" — [Apple Forums 794560](https://developer.apple.com/forums/thread/794560)
- **KeyType's strategy menu**: `pasteboardPaste` (Cmd-V), `pasteAndMatchStyle` (Cmd-Opt-Shift-V, to avoid rich-text style bleed), `characterInjection`, `chunkedStringInjection(size:)` and `firstWordOnly`. Options include `restorePasteboard`, a non-breaking-space workaround, `backspaceAfterPaste`, `deleteBackwardCount`, and an AX selection-range replacement ("Select an exact AX text range in the currently focused field"). Synthetic events are tagged so KeyType's own taps ignore them — [KeyType TextInsertion.swift](https://github.com/johnbean393/KeyType/blob/HEAD/Packages/TextInsertion/Sources/TextInsertion/TextInsertion.swift)
- **Typist**: "Posts key events carrying text (`CGEventKeyboardSetUnicodeString`) and backspaces for replacements; clipboard untouched". It uses `.combinedSessionState` and posts to `.cgSessionEventTap`. Its "Ideas for contributors" list includes a paste fallback for apps that drop synthetic key events — [Typist ARCHITECTURE.md](https://github.com/BrodySalvucci/Typist/blob/HEAD/docs/ARCHITECTURE.md); [Typist TextInserter.swift](https://github.com/BrodySalvucci/Typist/blob/HEAD/Sources/Typist/TextInserter.swift)
- **Maccy's paste**: builds Cmd-V with `CGEventSource(stateID: .combinedSessionState)` and `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, then posts keyDown/keyUp to `.cgSessionEventTap` — [Maccy Clipboard.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift)
- **Where to post, from inside a tap**: Cotabby posts its synthetic insertion to `.cghidEventTap` from within the accept tap's callback — [Cotabby InputMonitor.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Input/InputMonitor.swift)
- **Emoji and keyboard events**: an emoji is 2 UniChars and must be posted as both units. Apple's engineer says macro tools typically offer "character at a time" or "simulating a paste", and the Unicode-string API "has always been problematic" — [Apple Forums 706245](https://developer.apple.com/forums/thread/706245)
- **AX setter pitfalls**: writing `AXSelectedTextRange` on a WebKit textarea once made the caret disappear and later reads return `kAXErrorNoValue` ([WebKit bug 20997](https://bugs.webkit.org/show_bug.cgi?id=20997)). An agent-tooling page describes setting `kAXValueAttribute` and falling back to clear-and-type when the AX set fails ([agent-desktop set-value](https://www.mintlify.com/lahfir/agent-desktop/api/set-value)). GhostType says accepted completions are written back through the Accessibility API, mechanism unspecified ([GhostType write-up](https://dev.to/mk668a/i-built-ghosttype-copilot-style-ghost-text-completion-for-every-app-on-macos-1o16)).
- In a web context, direct value assignment breaks undo while Chrome's `execCommand('insertText')` keeps it, which is indirect evidence that non-typing insertion bypasses the editor's undo path — [insert-text-textarea (npm)](https://npmjs.com/package/insert-text-textarea)

### Inferences
- **Tradeoffs:**

  | Method | Undo | Rich text | Electron/web | Risks |
  |---|---|---|---|---|
  | Unicode keystrokes | Natural (typing) | Inherits current style | Works if the app reads the event's string | Some frameworks ignore the string; slow for long text; autocorrect may fire |
  | Cmd-V + restore | One undo step | May paste foreign style (use match-style) | Works broadly | Clipboard races and history managers; pasteboard privacy prompts on 15.4+/26; layout-specific key code |
  | AX `kAXSelectedTextAttribute` | Often not registered with the undo manager | Plain | Unreliable in Chromium and WebKit | No input events, so React/JS state never sees the change |
  | AX `kAXValueAttribute` | Replaces the whole value and breaks undo | Destroys styling | Poor | Caret jumps; never use for inline completion |

- Recommended default: Unicode keystrokes posted to `.cgAnnotatedSessionEventTap` with a marker, then a per-app paste override, with AX setters only for specific native apps verified to work.

### Gaps
- No source quantified how often `kAXSelectedTextAttribute` writes register with NSUndoManager in AppKit apps.
- I didn't verify the exact transient pasteboard type Tabber writes (`PasteboardMarker.writeTransient`). The common convention is the nspasteboard.org `org.nspasteboard.TransientType`, but this is unconfirmed.

---

## 7. Alternative architecture: Input Method Kit (IMKInputController)

### Takeaway
An IMK input method gets text events natively inside every app's text system and can render marked text and candidate panels without AX or event taps. No OSS clone uses it, though, and I found no OSS LLM ghost-text input method. Marked text is styled by the client (typically underlined, not gray ghost text). The user must add and select your input source, which displaces their keyboard or CJK IME. And AX-based clones must already cope with marked text from real IMEs.

### Cited Findings
- **Apple doc**: an `IMKInputController` object is created per input session per client; it "manages events and text from the applications and converted text from the input method engine", implementing the `IMKServerInput`/`IMKStateSetting` protocols. Available since macOS 10.5 and not deprecated — [Apple: IMKInputController](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller)
- **Client protocol**: `IMKTextInput` includes `setMarkedText:selectionRange:replacementRange:` and `insertText:replacementRange:` — [IMKTextInput header dump](https://github.com/w0lfschild/macOS_headers/blob/master/macOS/Frameworks/InputMethodKit/365.16.13/IMKTextInput-Protocol.h). `mark(forStyle:at:)` returns the attribute dictionary an IM uses to style marked ranges — [Apple: mark(forStyle:at:)](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller/mark(forstyle:at:).md). Clients implement `NSTextInputClient` marked-text methods (`hasMarkedText`, `setMarkedText`, `unmarkText`) — [Apple: NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient.md)
- **IMK pitfall (Sumibi-mac PR)**: a no-op `insertText` used to wake the client counted as a document edit and broke undo grouping. An empty `setMarkedText` created the session without that side effect — [Sumibi-mac PR #7](https://github.com/kiyoka/Sumibi-mac/pull/7)
- **OSS IMK references**: [vChewing/IMKSwift](https://github.com/vChewing/IMKSwift) (an IMK replacement for Swift 6); [lexoliu/ml-ime issue #84](https://github.com/lexoliu/ml-ime/issues/84) (marked text plus a reused NSPanel candidate window); [ensan-hcl/macOS_IMKitSample_2021](https://github.com/ensan-hcl/macOS_IMKitSample_2021) (minimal IMK sample)
- **Interplay with real IMEs**: KeyType tracks enabled and selected keyboard input sources through Text Input Source Services (`kTISPropertyInputSourceCategory`/`kTISCategoryKeyboardInputSource`), keeping a deny-list of TIS identifiers and noting TIS is main-thread-only ([KeyType InputMethodController.swift](https://github.com/johnbean393/KeyType/blob/HEAD/KeyType/Logic/Settings/InputMethodController.swift)). Cotabby holds its ghost while an IME composition is present ([Cotabby HostMarkedTextPolicy.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Support/Input/HostMarkedTextPolicy.swift)).
- No combined IMK + LLM ghost-text project was found in search; GhostType is AX-based — [search result summary / GhostType write-up](https://dev.to/mk668a/i-built-ghosttype-copilot-style-ghost-text-completion-for-every-app-on-macos-1o16)

### Inferences
These are unverified, from platform knowledge; validate before relying on them.
- **Pros of IMK**: no Accessibility or Input Monitoring TCC permissions for basic operation. Text is committed through the app's own text-input path, so undo and input events are correct. The caret rect is available via the client's `attributes(forCharacterIndex:lineHeightRectangle:)`. It works in Chromium and Electron text inputs because they implement NSTextInputClient for IMEs. Event taps and secure-input conflicts don't apply.
- **Cons of IMK**:
  - Only one input source is active at a time, so it conflicts with CJK and other IMEs.
  - The user must install it into `~/Library/Input Methods` and enable it in System Settings → Keyboard → Input Sources (high friction).
  - Marked-text appearance is controlled by the client, usually underlined black text, not gray. True ghost text would still need an overlay window.
  - Marked text becomes part of the app's buffer, which can trigger autosave, JS input events and collaboration sync.
  - Secure text fields generally switch to a Roman/ASCII source.
  - The IM sees only what the client exposes (`string(from:actualRange:)` support varies).
- **Hybrid option**: an IMK process for reliable caret geometry and commit, plus an overlay for gray rendering. This still needs the user to select the input source.

### Gaps
- I found no measured comparison of IMK marked-text rendering across apps (Chrome, Electron, Word), and no documented approach for gray (non-underlined) marked text.
- I did not verify whether `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` returns correct rects in Chromium.

---

## 8. Distribution constraints (sandbox, hardened runtime, notarization, TCC, macOS 15/26 changes)

### Takeaway
All clones ship **outside the Mac App Store, unsandboxed**, as Developer ID-signed, hardened-runtime, notarized DMGs with Sparkle updates. The main TCC grants are Accessibility (required), Screen Recording (optional, for OCR context) and "Paste from Other Apps" (on 15.4+/26 if using clipboard restore). Re-signing during development resets the Accessibility grant.

### Cited Findings
- Tabber entitlements: `com.apple.security.app-sandbox = false` with the comment "Not sandboxed: Tabber needs Accessibility, an event tap and synthetic input in other apps." Info.plist has `LSUIElement = true` (menu-bar agent) and `NSAccessibilityUsageDescription` — [Tabber Tabber.entitlements](https://github.com/chriscorbell/tabber/blob/HEAD/App/Tabber.entitlements); [Tabber Info.plist](https://github.com/chriscorbell/tabber/blob/HEAD/App/Info.plist)
- KeyType: "With the hardened runtime on (ADR-005) the framework's signature won't match a Team-ID-only validation, so library validation must be relaxed" to load the dynamic llama.cpp framework (`com.apple.security.cs.disable-library-validation = true`). "App Sandbox stays disabled." — [KeyType KeyType.entitlements](https://github.com/johnbean393/KeyType/blob/HEAD/KeyType/KeyType.entitlements)
- **Release pipelines**:
  - Tabber: signed DMG (`scripts/package-dmg.sh`), "Notarized and stapled with `notarytool`" (`scripts/notarize.sh`), and a Sparkle updater that checks the GitHub-release appcast ([Tabber README](https://github.com/chriscorbell/tabber); [Tabber architecture.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/architecture.md)).
  - Cotabby documents Sparkle keys and release flow in RELEASING.md ([Cotabby wiki](https://github.com/FuJacob/cotabby/wiki)).
  - TabType forks are listed as unnotarized alpha ([TabType repo](https://github.com/nilava/TabType)).
- **Dev pitfall**: "Ad hoc signing (the default in `Scripts/bundle.sh`) makes macOS re-ask for Accessibility after each rebuild. Setting `SIGN_IDENTITY` avoids this." — [Typist README](https://github.com/BrodySalvucci/Typist)
- **Screen Recording (Sequoia)**: macOS 15 re-prompts apps using screen capture monthly (originally planned weekly), and no longer re-prompts after reboot — [TidBITS](https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly); [9to5Mac](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/). Reports conflict on what 15.1 changed — [9to5Mac Oct 2024](https://9to5mac.com/2024/10/07/macos-sequoia-screen-recording-popups/); [heise](https://heise.de/-9973354)
- **Pasteboard privacy (15.4 preview, then macOS 26)**: `NSPasteboard.accessBehavior`, the `detect` APIs and a user-facing alert, covered in section 6 — [mjtsai](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4); [Apple doc](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/default.md)
- **Input Monitoring list registration bug on macOS 15** — [Apple Forums 828052](https://developer.apple.com/forums/thread/828052)
- **Stale TCC state**: `AXIsProcessTrusted` returns true but calls fail; reset with `tccutil` — [Apple Forums 750172](https://developer.apple.com/forums/thread/750172); [703188](https://developer.apple.com/forums/thread/703188)
- **Minimum OS**: Tabber, Typist, KeyType and GhostType all target macOS 14+ — [Tabber README](https://github.com/chriscorbell/tabber); [Typist README](https://github.com/BrodySalvucci/Typist); [KeyType repo](https://github.com/johnbean393/KeyType); [GhostType write-up](https://dev.to/mk668a/i-built-ghosttype-copilot-style-ghost-text-completion-for-every-app-on-macos-1o16)
- **Permission onboarding UX**: KeyType and Cotabby both ship a `PermissionGuidance` module with a drag-source view and a `SystemSettingsWindowLocator`. The likely pattern is guiding users to drag the app into the System Settings privacy list — [KeyType repo tree](https://github.com/johnbean393/KeyType); [Cotabby repo tree](https://github.com/FuJacob/cotabby)

### Inferences
- The Mac App Store requires App Sandbox, and cross-app AX control, global event taps and posting events to other apps are incompatible with it. Every clone disables the sandbox, so MAS distribution is effectively off the table. Plan on Developer ID + notarization + Sparkle (or Homebrew cask).
- Use a stable Developer ID signature even for local development builds, so TCC grants survive rebuilds.
- Prefer keystroke insertion over clipboard restore on macOS 26+ to avoid pasteboard-privacy alerts. If you paste, check `accessBehavior` first and use `detect` methods to avoid unnecessary reads.

### Gaps
- No primary Apple release notes were found for macOS 26 Tahoe or macOS 27 changes to AX, event taps or TCC. Search returned only older forum threads. The macOS 27 SDK is present locally, but I didn't diff its headers against 26.
- I didn't confirm whether macOS 26 still re-prompts Screen Recording monthly.

---

## 9. Open-source projects demonstrating each technique

### Takeaway
Four substantial MIT-licensed Swift clones (Tabber, Cotabby, KeyType, Typist) already implement the full AX + event tap + overlay + insertion stack, each with documented per-app workarounds. Mature utilities (Rectangle, Maccy, espanso, Hammerspoon) show individual techniques. Tabber has the cleanest module boundaries; Cotabby has the most exhaustive geometry and compatibility heuristics.

### Cited Findings

**Complete Cotypist-style apps:**
- **Tabber** ([chriscorbell/tabber](https://github.com/chriscorbell/tabber)): llama.cpp base model.
  - `TabberAX`: FocusTracker, FieldReader, CaretMath, WebAccessibility, TextStyleParser.
  - `TabberInput`: KeyboardMonitor tap, TextInserter, PasteboardSnapshot.
  - `TabberOverlay`: GhostPanel, FontResolver, MirrorCard.
  - `TabberContext`: SCK + Vision OCR, clipboard, SecretRedactor.
  - A `tabber-probe` CLI for live AX, keyboard and overlay checks.
  - Notarized DMG and Sparkle — [architecture.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/architecture.md); [compatibility.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/compatibility.md)
- **Cotabby** ([FuJacob/cotabby](https://github.com/FuJacob/cotabby)): Apple Intelligence (Foundation Models), llama.cpp or an OpenAI-compatible endpoint. It includes:
  - The Chromium AX enabler and the two-tap InputMonitor.
  - The pixel caret locator (ScreenCaptureKit).
  - The marked-text, Gmail Smart Compose and secure-field policies.
  - A large geometry suite and a Cotypist export importer (`CotypistExportImporter.swift`).
- **KeyType** ([johnbean393/KeyType](https://github.com/johnbean393/KeyType)): SwiftPM packages `MacContextCapture` (AX focus, caret, per-app geometry fallbacks, Vision OCR), `CompletionUI` (ghost overlay, mirror view, caret debug overlay), `TextInsertion` (paste and inject strategies), `AppCompatibility` (per-app/per-domain policy) and `ConstrainedGeneration`.
- **Typist** ([BrodySalvucci/Typist](https://github.com/BrodySalvucci/Typist)): compact single-target reference covering `AccessibilityReader`, `KeyInterceptor` and Unicode-keystroke `TextInserter`, with SCK OCR.

**Smaller or derivative clones:**
- **TabType**: MLX + Qwen3, alpha, unnotarized, several near-duplicate forks ([nilava/TabType](https://github.com/nilava/TabType), [m-ghalib/TabType](https://github.com/m-ghalib/TabType)). **S1S** is a fork ([m-ghalib/S1S](https://github.com/m-ghalib/S1S)).
- **GhostType** ([mk668a/GhostType](https://github.com/mk668a/GhostType)): PolyForm Noncommercial, not OSI open source. Uses a global NSEvent monitor, AX and a keystroke-buffer fallback, with a local OpenAI-compatible server — [write-up](https://dev.to/mk668a/i-built-ghosttype-copilot-style-ghost-text-completion-for-every-app-on-macos-1o16)

**Single-technique references:**
- **Rectangle**: AX window control, toggling `AXEnhancedUserInterface` around resizes — [AccessibilityElement.swift](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift)
- **Maccy**: synthesizing Cmd-V via CGEvent to `.cgSessionEventTap` — [Clipboard.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift)
- **espanso**: Unicode-string injection in 20-unit chunks to `kCGHIDEventTap`, plus vkey combos — [espanso-inject/src/mac/native.mm](https://github.com/espanso/espanso/blob/dev/espanso-inject/src/mac/native.mm)
- **Hammerspoon**: `hs.eventtap` (and its secure-input caveat) — [hs.eventtap docs mirror](https://commandpost.fcp.cafe/api-references/hammerspoon/hs.eventtap.md)
- **Electron docs**: a canonical `AXManualAccessibility` snippet — [Electron accessibility](https://www.electronjs.org/docs/latest/tutorial/accessibility)
- **Apple's UIElementInspector sample**: AX attribute utilities in `UIElementUtilities.m` — [Apple sample code listing](https://developer.apple.com/library/mac/samplecode/UIElementInspector/Listings/UIElementUtilities_m.html)
- **IMK samples**: [vChewing/IMKSwift](https://github.com/vChewing/IMKSwift), [ensan-hcl/macOS_IMKitSample_2021](https://github.com/ensan-hcl/macOS_IMKitSample_2021), [kiyoka/Sumibi-mac](https://github.com/kiyoka/Sumibi-mac/pull/7)
- **SDL**: event-tap timeout re-enable policy — [commit mirror](https://git.axiodl.com/encounter/SDL/commit/51ccc9ed8cab7bf1e3ea293328f2e382eceaf273)

### Inferences
- A builder could start by studying Tabber's module contracts (`FocusTracker`, `KeyboardMonitor`, `TextInserter`, `OverlayController`) and porting Cotabby's Chromium and geometry heuristics. Both are MIT-licensed, so reuse with attribution is permitted. Check each repo's LICENSE file.

### Gaps
- I didn't verify the AX or overlay internals of AltTab, PopClip-like OSS tools, or Raycast-like launchers. Their relevance is mostly to window or selection handling, not caret-level text.
- Repo maturity is unassessed (star counts, activity, open issues). Tabber self-describes as v0.1.

---

## 10. (Secondary) Windows and Linux equivalents

### Takeaway
Windows offers UI Automation TextPattern/TextPattern2 (`GetCaretRange` returns a zero-length caret range whose bounding rects give the caret) plus TSF for an IME-style approach. Linux offers AT-SPI Text (caret offset, `GetCharacterExtents`) and IBus/Fcitx input-method engines with surrounding text. Both have the same class of caret-geometry and offset bugs as macOS AX.

### Cited Findings
- **Windows UIA**: `IUIAutomationTextPattern2::GetCaretRange` "Retrieves a zero-length text range at the location of the caret". If `isActive` is FALSE, the control's caret may not match the system caret — [Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationtextpattern2-getcaretrange)
- **Linux AT-SPI**: the Text interface exposes the caret offset, set-caret and character extents — [Ubuntu D-Bus reference org.a11y.atspi.Text](https://documentation.ubuntu.com/desktop/en/latest/reference/accessibility/dbus/org.a11y.atspi.Text); [atspi-text.h](https://codebrowser.dev/qt6/include/at-spi-2.0/atspi/atspi-text.h.html). `get_character_extents` returns 0,0 for some offsets, e.g. a newline caret — [Orca list](https://mail.gnome.org/archives/orca-list/2016-August/msg00017.html). GTK recently fixed GetCharacterExtents, GetRangeExtents and GetOffsetAtPoint (size and parent-relative coordinates) — [GTK MR 7104](https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/7104)
- **Wayland/IBus**: the text-input protocol uses byte offsets while IBus expects character offsets for surrounding text and preedit cursor, which causes conversion bugs — [mutter issue 3102](https://gitlab.gnome.org/GNOME/mutter/-/issues/3102); [mutter preedit offsets commit](https://lists.gnome.org/archives/commits-list/2020-March/msg07776.html)

### Inferences
- On Linux/Wayland, global key interception and overlay positioning at arbitrary screen coordinates are restricted by design. An IBus/Fcitx engine (preedit or inline candidates) is likely the more viable path there than the AX-plus-overlay model. On Windows, the macOS-style UIA + low-level keyboard hook (`SetWindowsHookEx(WH_KEYBOARD_LL)`) + layered topmost window approach is feasible. These are inferences from platform knowledge, not sourced.

### Gaps
- No sources were gathered on TSF text services for inline suggestions, Windows low-level hook constraints, or Wayland overlay restrictions (layer-shell).
