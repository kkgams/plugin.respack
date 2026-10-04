> **Prospective v0.2.0 maintenance preparation — NOT release-ready.**
> Target: `plugin.respack` v0.2.0, `plugin.respack.wasm`, `ghcr.io/kkgams/gams/respack:0.2.0`.
> Below is frozen historical documentation: existing GitHub Release URLs,
> versioned examples and repair instructions refer to their original releases.
> For a future v0.2.0 candidate, use the prepared distribution metadata;
> rebuild and run repository-owned locked toolchain/runtime tests, review
> source drift, linked evidence and exact LICENSE/NOTICE/candidate digests.
> Migrate the direct-release publisher to draft-first immutable-policy and
> exact public-byte verification before any tag/OCI push/Pages publication.
> Do not run the historical publishing commands as v0.2.0 instructions.

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
