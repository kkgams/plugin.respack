# plugin.respack context

## Language

**Resource Pack Schema**: JSON that declares the ordered data slots and types used to
generate a decoder and encode a resource pack.

**Slot Payloads**: A JSON array whose entries correspond to schema data slots. Byte
values are represented as base64 strings.

**RSPK Artifact**: The binary resource-pack bytes produced from one Resource Pack
Schema and its Slot Payloads.

**Odin Decoder**: Odin source generated from a Resource Pack Schema for reading the
corresponding RSPK Artifact.

**Build To File**: The operation that writes an RSPK Artifact through a Host-granted
WASI filesystem preopen and returns its byte count, avoiding a large bridge value.

## Relationships and boundaries

- The Plugin exports `gams:respack/respack@1.0.0`: `generate-odin`, `build`, and
  `build-to-file`.
- Schema and payload JSON are caller-owned inputs; invalid values return WIT errors.
- Only Build To File accesses the filesystem, and only through Host-provided WASI
  preopens.
- Resource packing is separate from Director source compilation by
  `plugin.director-compiler`; neither repository is a runtime dependency of the other.
- The distribution artifact is `dist/plugin.respack.wasm`; Project installation maps
  it to `plugins/respack.comp.wasm`.
