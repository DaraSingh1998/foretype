# Third-party notices

Foretype is licensed under MIT OR Apache-2.0 (`LICENSE-MIT`, `LICENSE-APACHE`). It includes or
uses the following third-party work. The release app carries this file, the project licences
and the licence texts named below in `Foretype.app/Contents/Resources/`.

## Shipped in the app

| Component | Licence | Notes |
|---|---|---|
| [llama.cpp / ggml](https://github.com/ggml-org/llama.cpp), via the [`llama-cpp-2`](https://github.com/utilityai/llama-cpp-rs) crate 0.1.160 | MIT (llama.cpp), MIT OR Apache-2.0 (crate) | Copyright (c) 2023-2026 The ggml authors. Compiled into the core with Metal. The MIT text is below. |
| [Sparkle](https://sparkle-project.org) 2.10.0 | MIT, with notices for its bundled code | Copyright (c) 2006-2013 Andy Matuschak and the other Sparkle contributors. The update framework in release builds. Its full licence ships as `Sparkle-LICENSE.txt`. |
| [gemoji](https://github.com/github/gemoji) emoji names | MIT | Copyright (c) 2019 GitHub, Inc. Table in `core/data/emoji.tsv`; licence in `core/data/emoji-LICENSE.txt`, shipped as `gemoji-LICENSE.txt`. |
| Rust crates linked into the core (`core/Cargo.lock`) | MIT OR Apache-2.0 for most; also MIT, ISC, BSD-3-Clause, Zlib, Unlicense OR MIT, Unicode-3.0 (`icu_*`, `zerovec`, `unicode-ident` and others), CDLA-Permissive-2.0 (`webpki-roots`), Apache-2.0 AND ISC (`ring`) | All permissive. List them with `cargo metadata --format-version 1 --manifest-path core/Cargo.toml`. Build-only crates (`bindgen`, `cc`, `cmake`, `clang-sys`) aren't shipped. |

## Not shipped, used by the project

| Component | Licence | Notes |
|---|---|---|
| Language models (`models/catalog.json`): Qwen3 0.6B/1.7B/4B Base, Gemma 4 E2B | Apache-2.0 | Downloaded on request from Hugging Face ([mradermacher](https://huggingface.co/mradermacher) quantisations) and checked against a pinned SHA-256; never bundled. Gemma 4 is Apache-2.0 ([Google, 2026](https://opensource.googleblog.com/2026/03/gemma-4-expanding-the-gemmaverse-with-apache-20.html)). |
| [OpenAssistant oasst1](https://huggingface.co/datasets/OpenAssistant/oasst1) | Apache-2.0 | 41 of the 53 documents in `eval/corpus.jsonl` (and `tools/spike/eval/corpus/`) are messages from its validation split, selected and filtered as described in `eval/README.md`; they are excerpts, not the full dataset. |

## llama.cpp licence

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
