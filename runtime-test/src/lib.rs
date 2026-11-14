#[cfg(test)]
mod tests {
    use wasmtime::component::{Component, Linker, ResourceTable};
    use wasmtime::{Config, Engine, Result, Store};
    use wasmtime_wasi::{WasiCtx, WasiCtxView, WasiView};
    wasmtime::component::bindgen!({ path: "../src/wit", world: "respack-plugin" });

    struct State { wasi: WasiCtx, table: ResourceTable }
    impl WasiView for State {
        fn ctx(&mut self) -> WasiCtxView<'_> {
            WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
        }
    }
    #[test]
    fn decoder_generation_pack_header_and_invalid_schema() -> Result<()> {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let schema = std::fs::read_to_string(root.join("src/example.respack.json"))?;
        let slots = std::fs::read_to_string(root.join("src/testdata/example.slots.json"))?;
        let mut config = Config::new();
        config.wasm_component_model(true);
        let engine = Engine::new(&config)?;
        let component = Component::from_file(&engine, std::env::var("RESPACK_COMPONENT_PATH")?)?;
        let mut linker = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
        let mut store = Store::new(&engine, State { wasi: WasiCtx::builder().build(), table: ResourceTable::new() });
        let bindings = RespackPlugin::instantiate(&mut store, &component, &linker)?;
        let respack = bindings.gams_respack_respack();
        let odin = respack.call_generate_odin(&mut store, &schema)?.unwrap();
        assert!(odin.contains("read_slot_0_atlas"));
        let packed = respack.call_build(&mut store, &schema, &slots)?.unwrap();
        assert_eq!(&packed[..4], b"RSPK");
        assert_eq!(u16::from_le_bytes([packed[4], packed[5]]), 1);
        assert_eq!(u16::from_le_bytes([packed[6], packed[7]]), 4);
        let invalid = schema.replacen("\"len\": 16", "\"len\": \"16\"", 1);
        let error = respack.call_generate_odin(&mut store, &invalid)?.unwrap_err();
        assert!(error.contains("array len must be non-negative integer"));
        Ok(())
    }
}
