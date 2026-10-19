# Eval corpus

`corpus.jsonl` is built by `build_corpus.py` from two sources:

- `self_written.jsonl`: 12 documents (1,056 words) written for this evaluation in email, chat, notes, essay, support-reply and review registers. They may be used without restriction.
- `oasst1-raw/`: the first 600 rows of the validation split of [OpenAssistant/oasst1](https://huggingface.co/datasets/OpenAssistant/oasst1), fetched on 2026-10-19 through the Hugging Face datasets-server rows API (about 1 MB). oasst1 is licensed under Apache-2.0. From those rows the builder keeps English, non-deleted, non-synthetic messages of 80–900 characters with no code, markup or URLs. It takes every user ("prompter") message, then human-written assistant replies, up to 1,311 words (41 messages).

Each document has a byte-stable `header`, for example "An email written in Mail:", which is prepended to the prompt. The header is never typed.
