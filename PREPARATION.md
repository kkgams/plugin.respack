# Preparation evidence

Historical source provenance and extraction hashes are recorded in `SOURCE.json`.

## Validation status

Run the commands below against the current checkout and record their results.
Historical extraction validation is not proof that the current checkout passes.

- Required command: `nix develop --command make test`
- Required artifact check: `nix develop --command wasm-tools validate dist/plugin.respack.wasm`
- `make test` runs the component through its independently transpiled JavaScript.

No timestamp or platform is asserted here because this generated repository does not
carry an independently established validation record for its current bytes.

## Release blockers

- The owner approved Apache-2.0 for GAMS-authored code and reviewed this
  repository's third-party NOTICE. Hosted Linux candidate/link evidence is still
  required before a version tag may authorize release.
- The release scaffold is ready for an owner-operated `release` branch push after
  repository variables are set. Do not push a version tag until the exact hosted
  candidate and branch release-shell run pass and are reviewed.
