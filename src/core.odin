package respack

import runtime "base:runtime"
import mem "core:mem"
import jsmn "jsmn"

SCHEMA_BUFFER_CAPACITY :: 256 * 1024
MAX_SLOTS :: 512
PAYLOAD_CAPACITY :: 10 * 1024 * 1024
SCHEMA_TOKEN_MAX :: 4096
WRITE_TOKEN_MAX :: 512

SlotValue :: struct {
	has_value: bool,
	offset:    int,
	length:    int,
}

schema_buffer: [SCHEMA_BUFFER_CAPACITY]u8
schema_len: int
payload_buffer: [PAYLOAD_CAPACITY]u8
payload_used: int
scratch_buffer: [PAYLOAD_CAPACITY]u8
slots: [MAX_SLOTS]SlotValue
writer_initialized: bool

core_output_buffer: [PAYLOAD_CAPACITY]u8
core_output_len: int

@(export)
respack_core_build :: proc "c" (
	schema_ptr: rawptr,
	schema_count: uintptr,
	slots_ptr: rawptr,
	slots_count: uintptr,
) -> u32 {
	context = runtime.default_context()
	schema := core_input_slice(schema_ptr, schema_count)
	slots_json := core_input_slice(slots_ptr, slots_count)
	ok, err := handle_build(schema, slots_json)
	if !ok {
		return core_respond_error(err)
	}
	output, dump_err := build_dump_bytes()
	if dump_err != "" {
		return core_respond_error(dump_err)
	}
	return core_respond_bytes(output, 0)
}

@(export)
respack_core_generate_odin :: proc "c" (schema_ptr: rawptr, schema_count: uintptr) -> u32 {
	context = runtime.default_context()
	schema := core_input_slice(schema_ptr, schema_count)
	ok, err := handle_init(schema)
	if !ok {
		return core_respond_error(err)
	}
	source, codegen_err := build_odin_decoder()
	if codegen_err != "" {
		return core_respond_error(codegen_err)
	}
	return core_respond_string(source, 0)
}

@(export)
respack_core_output_ptr :: proc "c" () -> rawptr {
	if core_output_len == 0 {
		return nil
	}
	return rawptr(&core_output_buffer[0])
}

@(export)
respack_core_output_len :: proc "c" () -> uintptr {
	return uintptr(core_output_len)
}

core_input_slice :: proc(ptr: rawptr, count: uintptr) -> []u8 {
	if count == 0 {
		return []u8{}
	}
	return mem.slice_ptr(cast(^u8)ptr, int(count))
}

core_respond_ok :: proc(msg: string) -> u32 {
	return core_respond_string(msg, 0)
}

core_respond_error :: proc(msg: string) -> u32 {
	return core_respond_string(msg, 1)
}

core_respond_string :: proc(msg: string, status: u32) -> u32 {
	return core_respond_bytes(transmute([]u8)msg, status)
}

core_respond_bytes :: proc(data: []u8, status: u32) -> u32 {
	if len(data) > len(core_output_buffer) {
		core_output_len = 0
		return 1
	}
	if len(data) > 0 {
		copy(core_output_buffer[:len(data)], data)
	}
	core_output_len = len(data)
	return status
}

handle_build :: proc(schema: []u8, slots_json: []u8) -> (bool, string) {
	ok, err := handle_init(schema)
	if !ok {
		return false, err
	}
	trimmed := trim_space_slice(slots_json)
	if len(trimmed) == 0 {
		return true, ""
	}
	if trimmed[0] != '[' {
		return false, "slots must be a JSON array"
	}
	cursor := 1
	slot_index := 0
	for {
		element, next_cursor, found := next_array_element(trimmed, cursor)
		if !found {
			break
		}
		if slot_index >= data_slot_count {
			return false, "too many slots"
		}
		ok, write_err := handle_write_direct(slot_index, element)
		if !ok {
			return false, write_err
		}
		slot_index += 1
		cursor = next_cursor
	}
	return true, ""
}

handle_init :: proc(input: []u8) -> (bool, string) {
	if len(input) == 0 {
		return false, "schema input empty"
	}
	schema_input := input
	_, has_file, file_err := decode_schema_file_marker(input)
	if file_err != "" {
		return false, file_err
	}
	if has_file {
		return false,
			"schema _file marker is not supported by respack component init; pass schema bytes or use a host-side file read"
	}
	if len(schema_input) > SCHEMA_BUFFER_CAPACITY {
		return false, "schema too large"
	}
	reset_state()
	copy(schema_buffer[:len(schema_input)], schema_input)
	schema_len = len(schema_input)
	ok, err := compile_schema(schema_buffer[:schema_len])
	if !ok {
		reset_state()
		return false, err
	}
	writer_initialized = true
	return true, ""
}

handle_write_direct :: proc(slot: int, payload: []u8) -> (bool, string) {
	if !writer_initialized {
		return false, "writer not initialized"
	}
	if len(payload) == 0 {
		return false, "write payload empty"
	}
	if slot < 0 || slot >= data_slot_count {
		return false, "slot index out of range"
	}
	ok, encode_err := encode_payload_for_slot(slot, payload)
	if !ok {
		return false, encode_err
	}
	return true, ""
}

handle_write :: proc(input: []u8) -> (bool, string) {
	if !writer_initialized {
		return false, "writer not initialized"
	}
	if len(input) == 0 {
		return false, "write payload empty"
	}
	request, err := parse_write_request(input)
	if err != "" {
		return false, err
	}
	return handle_write_direct(request.slot, input[request.payload_start:request.payload_end])
}

reset_state :: proc() {
	schema_len = 0
	payload_used = 0
	reset_schema_state()
	for i in 0 ..< MAX_SLOTS {
		slots[i] = SlotValue{}
	}
	writer_initialized = false
}

WriteRequest :: struct {
	slot:          int,
	payload_start: int,
	payload_end:   int,
}

parse_write_request :: proc(input: []u8) -> (WriteRequest, string) {
	slot_start, slot_end, has_slot := find_top_level_value_bounds(input, "slot")
	if !has_slot {
		return WriteRequest{}, "slot field missing"
	}
	payload_start, payload_end, has_payload := find_top_level_value_bounds(input, "payload")
	if !has_payload {
		return WriteRequest{}, "payload missing"
	}
	slot_value, ok := parse_i64_bytes(input[slot_start:slot_end])
	if !ok {
		return WriteRequest{}, "slot parse error"
	}
	req := WriteRequest {
		slot          = int(slot_value),
		payload_start = payload_start,
		payload_end   = payload_end,
	}
	if req.payload_start < 0 ||
	   req.payload_end <= req.payload_start ||
	   req.payload_end > len(input) {
		return WriteRequest{}, "payload bounds invalid"
	}
	return req, ""
}

decode_schema_file_marker :: proc(input: []u8) -> (string, bool, string) {
	trimmed := trim_space_slice(input)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return "", false, ""
	}
	member, next_cursor, found := next_object_member(trimmed, 1)
	if !found {
		return "", false, ""
	}
	if !bytes_equal_string(trimmed[member.key_start:member.key_end], "_file") {
		return "", false, ""
	}
	_, _, extra_found := next_object_member(trimmed, next_cursor)
	if extra_found {
		return "", false, "schema file marker must contain only _file"
	}
	path_bytes, ok := decode_json_string_bytes(trimmed[member.value_start:member.value_end])
	if !ok {
		return "", false, "_file must be a string"
	}
	if len(path_bytes) == 0 {
		return "", false, "_file path empty"
	}
	return string(path_bytes), true, ""
}

token_matches :: proc(input: []u8, tok: jsmn.Token, text: string) -> bool {
	if tok.start < 0 || tok.end < 0 {
		return false
	}
	span := tok.end - tok.start
	if span != len(text) {
		return false
	}
	for i in 0 ..< span {
		if input[tok.start + i] != text[i] {
			return false
		}
	}
	return true
}

parse_int_token :: proc(input: []u8, tok: jsmn.Token) -> (int, bool) {
	value, ok := parse_i64_bytes(input[tok.start:tok.end])
	if !ok {
		return 0, false
	}
	return int(value), true
}
