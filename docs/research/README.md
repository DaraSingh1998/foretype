# Research

- [cotypist-report.md](cotypist-report.md): the research report that started the project
  (2026-10-18): how Cotypist works (product, privacy, confirmed vs inferred internals), what
  the open-source clones reveal about each layer, inference and latency, the open-source
  landscape and licensing, and the blueprint this repository implements. Claims carry
  inline source links.
- [notes/](notes/): the five research notes behind the report, with sources:
  `cotypist_product.md`, `cotypist_internals.md`, `macos_platform_techniques.md`,
  `local_inference.md`, `oss_landscape.md`.
- `data-phase3-*.txt`: raw `ft-replay` output for the Phase 3 prefetch and personalization
  measurements (summarized in `../MEASUREMENTS.md`).
- Phase 0 spike results: [../../tools/spike/RESULTS.md](../../tools/spike/RESULTS.md).

The report and notes reflect what was publicly known on 2026-10-18; Cotypist may have
changed since. Third-party code was read for reference only (see `../DECISIONS.md`, D2).
