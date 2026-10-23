# Evaluation corpus

`corpus.jsonl`: 53 documents, 2,367 words, 12,704 characters, built in the Phase 0 spike.

- `sw-*` (12 documents, 1,056 words) were written for this evaluation in email, chat,
  notes, essay, support-reply and review registers. They may be used without restriction.
- The other 41 are English, human-written messages from
  [OpenAssistant/oasst1](https://huggingface.co/datasets/OpenAssistant/oasst1) (validation
  split, first 600 rows, filtered to 80–900 characters with no code, markup or URLs).
  oasst1 is licensed under Apache-2.0.

Each line has `id`, `register`, `header` (for example "An email written in Mail:", used to
name the app) and `text`.

## Hindi and Hinglish

Written for this evaluation on 2026-10-22 (self-written, may be used without restriction),
in the same registers and JSONL shape as the English `sw-*` documents, with headers in
English (only the app name reaches the prompt):

- `corpus-hi.jsonl`: 13 documents in Devanagari, 949 words, 4,616 characters: formal and
  family emails, a leave application, a support reply, WhatsApp, Slack, Teams and Messages
  chats, notes, a product review and an essay paragraph. Standard grammar and spelling,
  danda (`।`) at sentence ends, nukta forms (ज़, फ़) and common English loanwords in
  Devanagari (डिप्लॉय, डैशबोर्ड). NFC, so a nukta is a separate combining mark.
- `corpus-hinglish.jsonl`: 12 documents of Hindi in Roman script mixed with English, 678
  words, 3,632 characters: WhatsApp, Slack, Teams and Messages chats, two informal emails,
  a to-do note and a review, with the common spellings (`hai`, `nahi`, `kya`, `toh`,
  `achha`) and ASCII punctuation.

    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus-hi.jsonl
    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus-hinglish.jsonl
    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus-hi.jsonl --token-cost

Characters are Unicode scalars, so a Devanagari consonant, a vowel sign and a virama each
count as one keystroke, as they do on the InScript keyboard.

## Context from other apps

`corpus-multiwindow.jsonl` (written for this evaluation on 2026-10-23, self-written, may be
used without restriction; fictional people, companies, figures and booking codes): 21
replies, chat messages, notes, a cover letter and a review, 1,799 words, 9,783 characters,
each written while another app shows what it quotes. Besides `id`, `register`, `header` and
`text`, each line has:

- `context`: the other app's text (272–687 characters): a budget review and meeting notes in
  Word, a launch plan and an agenda as slides, regional sales and an estimate as
  spreadsheets, a pricing page, a help-centre article, a recipe, a booking confirmation, a
  news story, a GitHub issue, a job posting, release notes and an HR policy in a browser, a
  lease, a supplier quote and a school letter in Preview. `context_app` and
  `context_title` name the app and window.
- `screen`: the focused window's own text around the field (24–252 characters): the email
  being answered, the chat so far, a note list, a review form.

The `text` repeats figures, dates, names and steps from `context` (and answers `screen`), so
the gap between `--context-mode focused` and `both` is what reading the other app is worth
at best. `both` sends `context` as the pool of other apps' text (one window on screen; the
core's other-apps section) and `screen` as screen context; `both-screen` is Phase A's
stand-in, both through the screen context (every item fits its 1,500-character budget).
`--distractors N` adds other items' `context` as recently viewed windows.

    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus-multiwindow.jsonl --context-mode both
    scripts/bench-context.sh

`details.json`: the user's own details (Settings ▸ About You) for `ft-replay --details`, by
document id: the three self-written documents that end with a signature get their signer
(fictional), `*` gives every other document one more fictional person. Example values only
(`example.com`, 555 numbers).

Run it through the engine with:

    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus.jsonl
    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus.jsonl --only sw- --personal-loo
    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus.jsonl --details eval/details.json
