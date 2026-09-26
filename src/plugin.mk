PLUGIN_WASM_COMPONENT := 1
PLUGIN_WIT_WORLD := gams:respack/respack-plugin@1.0.0
PLUGIN_COMPONENT_NAME := respack_plugin

RESPACK_COMP_PATH := $(PLUGIN_DIR)/respack.comp
RESPACK_ODIN_OBJ := $(BUILD_DIR)/obj/plugins/respack.comp/respack_core.o.obj

PLUGIN_COMPONENT_SOURCES := \
  $(RESPACK_COMP_PATH)/component.c \
  $(RESPACK_ODIN_OBJ)

PLUGIN_COMPONENT_EXTRA_DEPS := \
  $(RESPACK_COMP_PATH)/plugin.mk \
  $(RESPACK_COMP_PATH)/component.c \
  $(wildcard $(RESPACK_COMP_PATH)/*.odin) \
  $(wildcard $(RESPACK_COMP_PATH)/jsmn/*.odin) \
  $(RESPACK_ODIN_OBJ)

$(BUILD_DIR)/obj/plugins/respack.comp:
	$(Q)mkdir -p $@

$(RESPACK_ODIN_OBJ): $(wildcard $(RESPACK_COMP_PATH)/*.odin) $(wildcard $(RESPACK_COMP_PATH)/jsmn/*.odin) | $(BUILD_DIR)/obj/plugins/respack.comp
	$(Q)$(ODIN) build ./$(RESPACK_COMP_PATH) \
		-target:wasi_wasm32 \
		-build-mode:obj \
		--no-entry-point \
		-o:$(ODIN_OPT) \
		-out:$@
