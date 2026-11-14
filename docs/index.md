---
title: Resource Pack
description: Generate Odin decoders and packed binary resources.
status: reference
---
# Resource Pack

The resource pack component is a [GAMS](https://github.com/kkgams/gams) WASM Project Unit exporting `gams:respack/respack@1.0.0`. Caller-owned JSON schemas and slot payloads produce Odin decoder source or binary RSPK data. Only `build-to-file` accesses Host-preopened files; ordinary generation/build calls return data. Resource packing is independent of Director compilation.

| Unit | Source / output | Original work |
| --- | --- | --- |
| Resource pack compiler | `src/*.odin`, `src/component.c`, `src/wit/`; `build.nosync/plugin.respack.wasm` | GAMS contributors; [jsmn](https://github.com/zserge/jsmn) by Serge Zaitsev (Odin port in `src/jsmn/`); Odin/WASI runtime contributors |

## Development

Install Nix; run native commands with `nix develop --command make <target>`. The flake pins the actual Odin compiler, WASI SDK, binding tools and Rust. Cargo locks native Wasmtime tests; dependency-free Node runs only the pinned wiki engine.

| Command | Purpose |
| --- | --- |
| `make build` | Compile Odin core and C component into `build.nosync/`. |
| `make package` | Build raw WASM, LICENSE, NOTICE and SHA256SUMS; unchanged output does no work. |
| `make test` | Run native Cargo/Wasmtime decoder-generation, RSPK header/slot-count and invalid-schema assertions against the checked-in fixture and a separate test component. |
| `make open` | Build and open local `gams.json` in the released macOS Apple Silicon Host. |
| `make serve-docs` | Serve pinned wiki; independent `DOCS_PORT` defaults to 8080. |
| `make docs` | Build documentation into `build.nosync/site/`. |
| `make validate-docs` | Validate documentation. |
| `make clean` | Remove known generated output/docs and marked downloads; preserve supplied tools/Units and unidentified legacy output. |

Use `src/example.respack.json` with `src/testdata/example.slots.json` as schema/payload examples. Byte payloads use base64 strings. `generate-odin`, `build` and `build-to-file` return WIT result errors for invalid inputs; the latter returns the written byte count.

The local Project loads the built component with pinned supporting Units and the released Files View, not a pack-editor UI. The Host downloads only when absent, retains its notices and is not updated implicitly. Native tests do not cover Host GUI interactions or `build-to-file` preopen integration.
