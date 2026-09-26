# Preparation evidence

This repository is generated from working-tree source bytes. The ecosystem
orchestrator records global source provenance and hashes separately.

## Validation status

The validation commands in the ecosystem record describe historical extraction
validation and the checks required for this snapshot. `prepare()` does not execute
or claim a current verification run. The main setup orchestrator must run and record
those commands against the generated `plugin.respack` repository.

- Required command: `nix develop --command make test`
- Required artifact check: `nix develop --command wasm-tools validate dist/plugin.respack.wasm`
- `make test` runs the component through its independently transpiled JavaScript.

No timestamp or platform is asserted here because this generated repository does not
carry an independently established validation record for its current bytes.

## Release blockers

- Repository-owner license approval remains unresolved; see `LICENSING.md`.
- Third-party provenance, notices, source obligations, and artifact inventory need approval.
- Independent Linux CI evidence has not yet been recorded.
- No Git repository was initialized and no network publication was performed.
