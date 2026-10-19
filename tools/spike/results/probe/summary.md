### Field as first seen (`--once`)

| Scenario | App | Role (description) | Value len | Selection | Marked range | Zero-length caret | Prev-char edge | Disagree px | AXFont |
|---|---|---|---:|---|---|---|---|---:|---|
| textedit | com.apple.TextEdit | AXTextArea (text entry area) | 166 | 0+0 | 166+0 | y=121 h=13 w=0 ⚠ outsideElementFrame | –  | – | Family=Menlo, Name=Menlo-Regular, Size=11, VisibleName=Menlo Regular |
| safari | com.apple.Safari | AXTextField (text field) | 210 | 0+210 | none | y=35 h=16 w=0 ⚠ outsideElementFrame | –  | – | Family=.AppleSystemUIFont, Name=.AppleSystemUIFont, Size=13, VisibleName=System Font Regular |
| safari-ce | com.apple.Safari | AXTextArea (text entry area) | 112 | 112+0 | none | y=190 h=20 w=2  | y=190  | 2 | Family=Georgia, Name=Georgia, Size=17 |
| chrome | com.google.Chrome | AXTextArea (text entry area) | 112 | 112+0 | none | y=96 h=20 w=0  | y=96  | 0 | Size=17 |
| chrome-ax | com.google.Chrome | AXTextArea (text entry area) | 112 | 112+0 | none | y=96 h=20 w=0  | y=96  | 0 | Size=17 |
| chrome-ce-ax | com.google.Chrome | AXTextArea (text entry area) | 112 | 112+0 | none | y=96 h=20 w=0  | y=96  | 0 | Size=17 |
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
| textedit (AXTextArea) | 33 | 0.31 ms | 32 / 2 | SelectedText 1.1, Value 1.0 | 5.2 / 8.8 / 14.3 ms | 2.9 / 7.8 ms | differ by 13 px; zero-length rejected 1/34 |
| safari (AXTextField/?/AXTextArea) | 33 | 0.35 ms | 34 / 2 | SelectedText 1.4, Value 3.0 | 4.8 / 28.7 / 92.2 ms | 6.0 / 9.8 ms | differ by 2 px; zero-length rejected 27/36 |
| safari-ce (AXTextArea) | 33 | 0.30 ms | 33 / 0 | SelectedText 3.1, Value 3.0 | 5.6 / 8.8 / 15.4 ms | 2.8 / 4.4 ms | differ by 2 px |
| chrome (AXTextArea) | 33 | 0.31 ms | 33 / 0 | SelectedText 2.0, Value 2.0 | 8.7 / 11.5 / 13.5 ms | 2.4 / 4.2 ms | differ by 0 px |
| chrome-ax (AXTextArea) | 33 | 0.37 ms | 34 / 1 | SelectedText 2.0, Value 2.0 | 7.8 / 10.1 / 13.5 ms | 2.9 / 4.2 ms | differ by 0 px; zero-length rejected 2/35 |
| chrome-ce-ax (AXTextArea) | 33 | 0.36 ms | 32 / 1 | SelectedText 2.0, Value 2.0 | 8.7 / 11.3 / 12.6 ms | 2.8 / 4.1 ms | differ by 0 px |
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
| textedit | com.apple.TextEdit | 4.4 / 5.8 (max 8.5) | 0.26 / 0.35 | 0.08 / 0.12 | 0.10 / 0.13 | 0.28 / 0.40 | 0.23 / 0.33 | 0.23 / 0.34 |
| safari | com.apple.Safari | 7.0 / 9.5 (max 19.4) | 0.52 / 0.63 | 0.08 / 0.12 | 0.08 / 0.12 | 0.32 / 0.37 | 0.36 / 0.44 | 3.25 / 3.88 |
| safari-ce | com.apple.Safari | 7.4 / 10.6 (max 20.9) | 0.51 / 0.67 | 0.08 / 0.10 | 0.08 / 0.10 | 0.38 / 0.51 | 0.48 / 0.72 | 3.78 / 4.11 |
| chrome | com.google.Chrome | 4.4 / 7.0 (max 15.7) | 0.30 / 0.48 | 0.09 / 0.13 | 0.17 / 0.27 | 0.12 / 0.19 | 0.16 / 0.20 | 0.77 / 0.97 |
| chrome-ax | com.anthropic.claudefordesktop | 2.4 / 5.1 (max 7.0) | 0.23 / 0.33 | 0.03 / 0.04 | 0.05 / 0.07 | 0.03 / 0.05 | – | 0.16 / 0.21 |
| chrome-ce-ax | com.google.Chrome | 3.3 / 6.0 (max 11.2) | 0.23 / 0.39 | 0.07 / 0.11 | 0.16 / 0.27 | 0.10 / 0.16 | 0.11 / 0.24 | 0.59 / 0.96 |
| edge | com.microsoft.edgemac | 0.6 / 0.8 (max 8.0) | 0.17 / 0.22 | – | – | – | – | – |
| edge-ax | com.microsoft.edgemac | 0.5 / 0.7 (max 0.8) | 0.17 / 0.20 | – | – | – | – | – |
| notes | com.apple.Notes | 5.4 / 6.3 (max 18.4) | 0.20 / 0.32 | 0.71 / 0.87 | 0.09 / 0.12 | 0.25 / 0.37 | 0.28 / 0.37 | 0.54 / 0.63 |
| stickies | com.apple.Stickies | 4.4 / 5.1 (max 10.5) | 0.17 / 0.22 | 0.05 / 0.09 | 0.06 / 0.10 | 0.17 / 0.33 | 0.25 / 0.37 | 0.25 / 0.36 |
| libreoffice-writer | org.libreoffice.script | 3.9 / 5.3 (max 11.4) | 0.22 / 0.30 | 0.06 / 0.10 | 0.07 / 0.13 | 0.11 / 0.16 | 0.27 / 0.39 | 0.75 / 1.01 |
| wordcraft | ai.storyteller.wordcraft | 4.0 / 5.6 (max 84.3) | 0.18 / 0.25 | 0.06 / 0.11 | 0.06 / 0.10 | 0.06 / 0.10 | 0.13 / 0.16 | 0.09 / 0.18 |
| teams | com.microsoft.teams2 | 3.7 / 4.8 (max 21.3) | 0.56 / 0.66 | 0.09 / 0.11 | 0.96 / 1.22 | 0.08 / 0.11 | 0.11 / 0.18 | 0.49 / 0.68 |
| vscode | com.microsoft.VSCode | 1.7 / 4.4 (max 10.3) | 0.24 / 0.34 | 0.06 / 0.07 | 0.08 / 0.11 | 0.07 / 0.10 | – | – |
| bundle-open | com.anthropic.claudefordesktop | 6.3 / 9.1 (max 54.4) | 0.47 / 4.86 | 0.04 / 0.08 | 0.05 / 0.08 | 0.06 / 0.11 | – | – |
| bundle-exec | com.anthropic.claudefordesktop | 10.3 / 32.0 (max 46.1) | 0.22 / 6.19 | 0.03 / 0.04 | 0.03 / 0.05 | 0.04 / 0.05 | – | – |

