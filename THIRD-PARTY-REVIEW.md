# plugin.respack — WebAssembly notice review

## Scope and source provenance

The owner approved Apache-2.0 for GAMS-authored code only. The plugin links C and an Odin object built using pinned `odin-lang/Odin` commit `db0cd79633fe05069dc4f9248d2796eb8ec3b858`. `src/core.odin` imports the local `src/jsmn/jsmn.odin` tokenizer. Project history introduced this Odin file at `159b6bfca5b0bcd853b87e46ef60adbbdb4397c2` without an origin/rights statement. Its algorithm and naming resemble Serge Zaitsev's jsmn (2010); we have included the original full MIT text **conservatively**, but this is not proof of the port's provenance. Before distributing source, the owner must confirm whether the local port was adapted from upstream jsmn and that its retained MIT attribution plus the Apache-2.0 terms for local changes are appropriate. Do not set digest variables or push source until resolved.

`src/wit/deps/wasi-{clocks,filesystem,io}-0.2.0` adapt WASI Preview 2 specification interfaces. `NOTICE` includes the W3C attribution; they are not GAMS Apache code. The proposed notice also includes Odin's own exact license and, conservatively, its `base/runtime/LICENSE-compiler-rt.txt` for runtime-derived code. Neither entire Odin toolchain nor build-only npm/jco/Nix closures are shipped with the raw component.

## Linked output evidence

A local Makefile-equivalent relink (generated C bindings, `src/component.c`, `build/core.o.wasm` and the generated component-type object) produced stripped bytes identical to the pre-notice component (`235ef49b90cfff588c34a23374bde0dfaa0a5cd4c7138ac881560ad017295cfd`). Its WASI SDK 33.0 links wasi-libc commit `161b3195fc2558d2b1ba3eb9ffae3b2b47407623`; the map selects `crt1-reactor.o` and ten `libc.a` members, including `dlmalloc.c.obj` and musl-derived `memcmp.c.obj` and `strlen.c.obj`. No `libclang_rt.builtins.a` member is selected. The notice retains wasi-libc's MIT option and license inventory, the full musl COPYRIGHT and dlmalloc notice. Generated component/binding support is conservatively covered by the Bytecode Alliance MIT text.

**Unlike layout and Lua**, the component includes a WASI Preview 1 adapter. `wasm-tools component unbundle --threshold 0` extracts a ~296 KB core that imports `wasi_snapshot_preview1` `random_get` and `fd_write`, a ~6 KB module that exports `random_get` and imports `wasi:random/random@0.2.6`, plus tiny generated support modules. `wasm-component-ld` 0.5.22 uses the Wasmtime `wasi-preview1-component-adapter-provider` 43.0.0 reactor. The proposed `NOTICE` conservatively includes the Wasmtime Apache-2.0-with-LLVM-exception license and Rust runtime MIT text in addition to Odin runtime notices. The final component imports standard WASI 0.2.6 random, filesystem, I/O, CLI and clocks instances. The adapter's transformed module is not byte-identical to an upstream source artifact, so the exact embedded-source provenance needs owner review alongside the build evidence.

## Remaining approval

- Resolve the local Odin jsmn port provenance and verify the third-party/source redistribution rights. This is **not** settled merely by adding an MIT text to `NOTICE`.
- Inspect hosted Linux `dist/evidence/link.map`, SDK VERSION, module metadata and final artifact equivalence; revisit the adapter inventory if the toolchain or linked inputs change.
- Review exact `LICENSE`/`NOTICE`, candidate checksums and embedded bytes before setting digests/pushing a matching version tag. No local relink constitutes hosted publication approval.
