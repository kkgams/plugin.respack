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

No release/publish automation is included. The Odin jsmn port's provenance and
license are an explicit inventory blocker; see `LICENSING.md` and `PREPARATION.md`.
