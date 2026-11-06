## Current tag-based release authorization

Pushing the matching version tag authorizes release in this repository. No manual
checksum variables, approval boolean, hosted-review approval, or `release`-branch
HEAD match is required. Branch candidates still validate their payloads; they do
not publish a GitHub Release or OCI version. Manual branch runs verify only.

Repository/tag/version and WIT identity checks, build/runtime tests, source and
build-evidence checks, nonempty LICENSE/NOTICE, exact embedded licensing bytes,
generated SHA256SUMS, independent candidates, and GitHub Release/OCI no-overwrite
checks remain required. The workflow uses the automatic GitHub token. Never move
or overwrite an existing version tag. Pages publication remains independent.

This policy supersedes historical approval-variable and pre-tag review/branch
requirements below, not source provenance or legal terms. It does not claim hosted
validation or authorize this editing session to commit, push, tag, or publish.
No source snapshots, legal texts, or historical evidence are refreshed.

> Prepared target: `plugin.respack` v0.2.1; not yet published.
> The documentation below is a frozen historical record, not current
> pending approval requirements. Its manual approval/checksum and pre-tag
> review/branch requirements are superseded above; content checks remain.

# plugin.respack

Standalone extraction of the GAMS resource-pack WebAssembly component. The Odin
core, C component adapter, local Odin jsmn port, WIT dependencies, schema, and
test fixture are included. It exports `gams:respack/respack@1.0.0`.

## Build and verify

```sh
nix develop --command make test
```

The test checks Odin generation, invalid-schema diagnostics, and the binary RSPK
header/content using the checked-in fixture. Output is `dist/plugin.respack.wasm`.
The flake pins the same Odin revision as the standalone `plugin.director-compiler`.

The owner approved Apache-2.0 for GAMS-authored code and reviewed the third-party
`NOTICE`. The extracted Odin jsmn port now identifies its upstream MIT origin;
hosted Linux adapter/candidate evidence is still required before tagging. See `LICENSING.md`, `THIRD-PARTY-REVIEW.md`, and
`PUBLISHING.md` for the fail-closed candidate/release process.

## Local Project and documentation

Run `nix develop --command make open` on macOS Apple Silicon to build local
artifacts and open this repository's `gams.json` with the downloaded released
Host. No sibling checkout is required; `tools/` and `gams_modules/` are ignored.
The existing Host is retained, with release notices kept alongside it.

Use `make serve-docs` (`DOCS_PORT` overrides 8080), `make validate-docs` and
`make docs` for the pinned wiki. The site is built into `build/site/`; pushes to
`release` publish it through GitHub Pages, independently of version tags.
See [development documentation](docs/index.md) for Project behavior and checks.
