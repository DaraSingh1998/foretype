### Field as first seen (`--once`)

| Scenario | App | Role (description) | Value len | Selection | Marked range | Zero-length caret | Prev-char edge | Disagree px | AXFont |
|---|---|---|---:|---|---|---|---|---:|---|
| edge | com.microsoft.edgemac | None (None) | None | None+None | none | –  | –  | – | none |
| edge-ax | com.microsoft.edgemac | None (None) | None | None+None | none | –  | –  | – | none |
| notes | com.apple.Notes | AXTextArea (text entry area) | None | 0+0 | 0+0 | y=94 h=23 w=0  | –  | – | none |
| stickies | com.apple.Stickies | AXTextArea (text entry area) | 0 | 0+0 | 0+0 | y=319 h=14 w=0  | –  | – | none |
| libreoffice-writer | org.libreoffice.script | AXTextArea (text entry area) | 0 | 0+0 | none | y=-2147483178 h=-2147483647 w=-2147483647 ⚠ tooTall,outsideElementFrame,offScreen | –  | – | none |
| wordcraft | ai.storyteller.wordcraft | AXGroup (group) | 1 | 0+0 | none | y=321.035 h=21.959 w=0  | –  | – | none |
| teams | com.microsoft.teams2 | AXTextArea (text entry area) | 23 | 21+0 | none | y=982 h=0 w=0 ⚠ zeroHeight,outsideElementFrame | y=982 ⚠ zeroHeight,outsideElementFrame | – | Size=14 |
| vscode | com.microsoft.VSCode | AXTextArea (editor) | 0 | 0+0 | none | y=982 h=0 w=0 ⚠ zeroHeight | –  | – | none |

### Typing run (`--type`, 32 synthetic keystrokes at 120 ms)

| Scenario | Keys seen by tap | Tap lag p50 | Snapshots (notif / poll-only) | AX notifications per keystroke | Keystroke → AX notification p50 / p90 / max | Snapshot AX cost p50 / p90 | Zero-length rect vs prev-char edge |
|---|---:|---:|---|---|---|---|---|
| edge (?) | 33 | 0.25 ms | 1 / 0 |  | – / – / – ms | 0.1 / 0.1 ms | agree |
| edge-ax (?/AXTextArea) | 33 | 0.28 ms | 33 / 0 | SelectedText 2.0, Value 2.0 | 4.5 / 10.8 / 17.1 ms | 1.0 / 2.5 ms | differ by 0 px |
| notes (AXTextArea) | 33 | 0.34 ms | 32 / 0 | SelectedText 2.1, Value 1.9 | 7.3 / 10.6 / 138.4 ms | 10.2 / 37.7 ms | differ by 23 px |
| stickies (AXTextArea) | 33 | 0.30 ms | 33 / 0 | SelectedText 1.1, Value 1.1 | 3.4 / 6.7 / 18.9 ms | 2.0 / 3.0 ms | differ by 14 px |
| libreoffice-writer (AXTextArea) | 33 | 0.33 ms | 34 / 0 | SelectedText 1.0, Value 1.0 | 32.4 / 39.7 / 42.0 ms | 4.7 / 13.3 ms | agree; zero-length rejected 34/34 |
| wordcraft (AXGroup) | 33 | 0.28 ms | 21 / 8 | SelectedText 1.0, Value 1.0 | 56.8 / 106.7 / 113.2 ms | 122.6 / 136.5 ms | differ by 0 px |
| teams (AXTextArea) | 33 | 0.31 ms | 33 / 0 | SelectedText 2.0, Value 2.0 | 12.3 / 43.0 / 70.5 ms | 2.1 / 3.7 ms | agree; zero-length rejected 33/33 |

### Back-to-back snapshot cost (`--bench 30`, ms p50 / p90)

| Scenario | App measured | Whole snapshot | AXFocusedUIElement | AXValue | AXSelectedTextRange | AXBoundsForRange(caret,0) | AXBoundsForRange(prev,1) | AXAttributedStringForRange(1) |
|---|---|---|---|---|---|---|---|---|
| edge | com.microsoft.edgemac | 0.6 / 0.8 (max 8.0) | 0.17 / 0.22 | – | – | – | – | – |
| edge-ax | com.microsoft.edgemac | 0.5 / 0.7 (max 0.8) | 0.17 / 0.20 | – | – | – | – | – |
| notes | com.apple.Notes | 5.4 / 6.3 (max 18.4) | 0.20 / 0.32 | 0.71 / 0.87 | 0.09 / 0.12 | 0.25 / 0.37 | 0.28 / 0.37 | 0.54 / 0.63 |
| stickies | com.apple.Stickies | 4.4 / 5.1 (max 10.5) | 0.17 / 0.22 | 0.05 / 0.09 | 0.06 / 0.10 | 0.17 / 0.33 | 0.25 / 0.37 | 0.25 / 0.36 |
| libreoffice-writer | org.libreoffice.script | 3.9 / 5.3 (max 11.4) | 0.22 / 0.30 | 0.06 / 0.10 | 0.07 / 0.13 | 0.11 / 0.16 | 0.27 / 0.39 | 0.75 / 1.01 |
| wordcraft | ai.storyteller.wordcraft | 4.0 / 5.6 (max 84.3) | 0.18 / 0.25 | 0.06 / 0.11 | 0.06 / 0.10 | 0.06 / 0.10 | 0.13 / 0.16 | 0.09 / 0.18 |
| teams | com.microsoft.teams2 | 3.7 / 4.8 (max 21.3) | 0.56 / 0.66 | 0.09 / 0.11 | 0.96 / 1.22 | 0.08 / 0.11 | 0.11 / 0.18 | 0.49 / 0.68 |
| vscode | com.microsoft.VSCode | 1.7 / 4.4 (max 10.3) | 0.24 / 0.34 | 0.06 / 0.07 | 0.08 / 0.11 | 0.07 / 0.10 | – | – |

