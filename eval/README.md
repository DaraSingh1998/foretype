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

`details.json`: the user's own details (Settings ▸ About You) for `ft-replay --details`, by
document id: the three self-written documents that end with a signature get their signer
(fictional), `*` gives every other document one more fictional person. Example values only
(`example.com`, 555 numbers).

Run it through the engine with:

    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus.jsonl
    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus.jsonl --only sw- --personal-loo
    core/target/release/ft-replay MODEL.gguf --corpus eval/corpus.jsonl --details eval/details.json
