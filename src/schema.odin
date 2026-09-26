package respack

import jsmn "jsmn"

MAX_TYPES :: 256
MAX_FIELDS :: 1024
MAX_ENUM_VALUES :: 1024
MAX_ONEOF_OPTIONS :: 1024
TYPE_NAME_MAX :: 96
MAX_ODIN_IMPORTS :: 64
ODIN_IMPORT_ALIAS_MAX :: 64
ODIN_IMPORT_PATH_MAX :: 256

TypeKind :: enum int {
	Invalid,
	Bool,
	U8,
	U16,
	U32,
	U64,
	I8,
	I16,
	I32,
	I64,
	F32,
	F64,
	String,
	Bytes,
	Alias,
	Enum,
	Struct,
	Array,
	Vector,
	Oneof,
}

TypeDef :: struct {
	kind:         TypeKind,
	has_name:     bool,
	name_start:   int,
	name_end:     int,
	target_type:  int,
	fixed_len:    int,
	field_start:  int,
	field_count:  int,
	enum_start:   int,
	enum_count:   int,
	option_start: int,
	option_count: int,
	max_len:      int,
}

FieldDef :: struct {
	name_start:    int,
	name_end:      int,
	type_index:    int,
	has_default:   bool,
	default_token: int,
	default_start: int,
	default_end:   int,
	has_min:       bool,
	has_max:       bool,
	min_value:     f64,
	max_value:     f64,
	max_len:       int,
}

EnumValue :: struct {
	name_start: int,
	name_end:   int,
	value:      i64,
}

schema_tokens: [SCHEMA_TOKEN_MAX]jsmn.Token
schema_token_count: int
types: [MAX_TYPES]TypeDef
type_count: int
fields: [MAX_FIELDS]FieldDef
field_count: int
enum_values: [MAX_ENUM_VALUES]EnumValue
enum_value_count: int
oneof_options: [MAX_ONEOF_OPTIONS]int
oneof_option_count: int
data_slots: [MAX_SLOTS]int
data_slot_count: int
named_type_indices: [MAX_TYPES]int
named_type_count: int
named_type_name_lens: [MAX_TYPES]int
named_type_name_bytes: [MAX_TYPES][TYPE_NAME_MAX]u8
schema_package_start: int
schema_package_end: int
schema_odin_package_len: int
schema_odin_package_bytes: [TYPE_NAME_MAX]u8
schema_odin_import_count: int
schema_odin_import_alias_lens: [MAX_ODIN_IMPORTS]int
schema_odin_import_alias_bytes: [MAX_ODIN_IMPORTS][ODIN_IMPORT_ALIAS_MAX]u8
schema_odin_import_path_lens: [MAX_ODIN_IMPORTS]int
schema_odin_import_path_bytes: [MAX_ODIN_IMPORTS][ODIN_IMPORT_PATH_MAX]u8

reset_schema_state :: proc() {
	schema_token_count = 0
	type_count = 0
	field_count = 0
	enum_value_count = 0
	oneof_option_count = 0
	data_slot_count = 0
	named_type_count = 0
	for i in 0 ..< MAX_TYPES {
		named_type_name_lens[i] = 0
	}
	schema_package_start = 0
	schema_package_end = 0
	schema_odin_package_len = 0
	schema_odin_import_count = 0
	for i in 0 ..< MAX_ODIN_IMPORTS {
		schema_odin_import_alias_lens[i] = 0
		schema_odin_import_path_lens[i] = 0
	}
	add_builtin_types()
}

compile_schema :: proc(input: []u8) -> (bool, string) {
	reset_schema_state()
	parser: jsmn.Parser
	jsmn.init(&parser)
	schema_token_count = jsmn.parse(&parser, input, schema_tokens[:])
	if schema_token_count < 0 {
		return false, json_error_string(schema_token_count)
	}
	if schema_token_count == 0 || schema_tokens[0].type != jsmn.JsmnType.Object {
		return false, "schema root must be object"
	}
	package_start, package_end, _ := find_top_level_value_bounds(input, "package")
	if package_start >= 0 && package_end > package_start {
		schema_package_start = package_start + 1
		schema_package_end = package_end - 1
	}
	if err := compile_odin_config(input); err != "" {
		return false, err
	}
	types_start, types_end, has_types := find_top_level_value_bounds(input, "types")
	if !has_types {
		return false, "schema missing types object"
	}
	types_idx := find_token_by_start(
		schema_tokens[:schema_token_count],
		types_start,
		jsmn.JsmnType.Object,
	)
	if types_idx < 0 || schema_tokens[types_idx].type != jsmn.JsmnType.Object {
		return false, "schema types must be object"
	}
	types_slice := input[types_start:types_end]
	data_start, data_end, has_data := find_top_level_value_bounds(input, "data")
	if !has_data {
		return false, "schema missing data array"
	}
	if input[data_start] != '[' {
		return false, "schema data is not array"
	}

	cursor := 1
	for {
		member, next_cursor, found := next_object_member(types_slice, cursor)
		if !found {
			break
		}
		key_tok := jsmn.Token {
			type  = jsmn.JsmnType.String,
			start = types_start + member.key_start,
			end   = types_start + member.key_end,
		}
		_, err := declare_named_type(key_tok)
		if err != "" {
			return false, err
		}
		cursor = next_cursor
	}

	cursor = 1
	for {
		member, next_cursor, found := next_object_member(types_slice, cursor)
		if !found {
			break
		}
		key_tok := jsmn.Token {
			type  = jsmn.JsmnType.String,
			start = types_start + member.key_start,
			end   = types_start + member.key_end,
		}
		type_idx, found_type := lookup_named_type(input, key_tok)
		if !found_type {
			return false, "type declaration lookup failed"
		}
		value_slice := types_slice[member.value_start:member.value_end]
		err := compile_named_type_from_top_level_value(
			input,
			value_slice,
			types_start + member.value_start,
			type_idx,
		)
		if err != "" {
			return false, err
		}
		cursor = next_cursor
	}

	data_parser: jsmn.Parser
	jsmn.init(&data_parser)
	data_tokens_array: [MAX_SLOTS + 1]jsmn.Token
	data_tokens := data_tokens_array[:]
	data_slice := input[data_start:data_end]
	data_count := jsmn.parse(&data_parser, data_slice, data_tokens)
	if data_count < 0 {
		return false, json_error_string(data_count)
	}
	if data_count == 0 || data_tokens[0].type != jsmn.JsmnType.Array {
		return false, "schema data is not array"
	}
	slot_idx := 0
	for i in 0 ..< data_count {
		if data_tokens[i].parent != 0 {
			continue
		}
		if slot_idx >= MAX_SLOTS {
			return false, "schema data array exceeds slot limit"
		}
		if data_tokens[i].type != jsmn.JsmnType.String {
			return false, "schema data entries must be strings"
		}
		entry_slice := data_slice[data_tokens[i].start:data_tokens[i].end]
		type_idx, resolve_ok := resolve_type_from_value_slice(entry_slice)
		if resolve_ok != "" {
			return false, resolve_ok
		}
		data_slots[slot_idx] = type_idx
		slot_idx += 1
	}
	data_slot_count = slot_idx
	return true, ""
}

compile_odin_config :: proc(input: []u8) -> string {
	odin_start, odin_end, has_odin := find_top_level_value_bounds(input, "odin")
	if !has_odin {
		return ""
	}
	odin_slice := trim_bytes_space(input[odin_start:odin_end])
	if len(odin_slice) == 0 || odin_slice[0] != '{' {
		return "odin must be object"
	}
	package_start, package_end, has_package := find_top_level_value_bounds(odin_slice, "package")
	if has_package {
		package_value := trim_bytes_space(odin_slice[package_start:package_end])
		package_bytes, ok := decode_json_string_literal(package_value)
		if !ok {
			return "odin.package must be string"
		}
		if len(package_bytes) > len(schema_odin_package_bytes) {
			return "odin.package too long"
		}
		schema_odin_package_len = len(package_bytes)
		copy(schema_odin_package_bytes[:schema_odin_package_len], package_bytes)
	}
	imports_start, imports_end, has_imports := find_top_level_value_bounds(odin_slice, "imports")
	if has_imports {
		if err := compile_odin_imports(odin_slice[imports_start:imports_end]); err != "" {
			return err
		}
	}
	return ""
}

compile_odin_imports :: proc(data: []u8) -> string {
	imports_slice := trim_bytes_space(data)
	if len(imports_slice) == 0 || imports_slice[0] != '{' {
		return "odin.imports must be object"
	}
	cursor := 1
	for {
		member, next_cursor, found := next_object_member(imports_slice, cursor)
		if !found {
			break
		}
		if schema_odin_import_count >= MAX_ODIN_IMPORTS {
			return "odin import limit exceeded"
		}
		alias_len := member.key_end - member.key_start
		if alias_len <= 0 || alias_len > ODIN_IMPORT_ALIAS_MAX {
			return "odin import alias too long"
		}
		path_bytes, ok := decode_json_string_literal(
			trim_bytes_space(imports_slice[member.value_start:member.value_end]),
		)
		if !ok {
			return "odin import path must be string"
		}
		if len(path_bytes) == 0 || len(path_bytes) > ODIN_IMPORT_PATH_MAX {
			return "odin import path too long"
		}
		idx := schema_odin_import_count
		schema_odin_import_alias_lens[idx] = alias_len
		copy(
			schema_odin_import_alias_bytes[idx][:alias_len],
			imports_slice[member.key_start:member.key_end],
		)
		schema_odin_import_path_lens[idx] = len(path_bytes)
		copy(schema_odin_import_path_bytes[idx][:len(path_bytes)], path_bytes)
		schema_odin_import_count += 1
		cursor = next_cursor
	}
	return ""
}

decode_json_string_literal :: proc(data: []u8) -> ([]u8, bool) {
	trimmed := trim_bytes_space(data)
	if len(trimmed) < 2 || trimmed[0] != '"' || trimmed[len(trimmed) - 1] != '"' {
		return nil, false
	}
	return trimmed[1:len(trimmed) - 1], true
}

schema_odin_package :: proc() -> string {
	if schema_odin_package_len == 0 {
		return ""
	}
	return string(schema_odin_package_bytes[:schema_odin_package_len])
}

schema_odin_import_alias :: proc(idx: int) -> string {
	return string(schema_odin_import_alias_bytes[idx][:schema_odin_import_alias_lens[idx]])
}

schema_odin_import_path :: proc(idx: int) -> string {
	return string(schema_odin_import_path_bytes[idx][:schema_odin_import_path_lens[idx]])
}

ObjectMember :: struct {
	key_start:   int,
	key_end:     int,
	value_start: int,
	value_end:   int,
}

next_object_member :: proc(data: []u8, cursor: int) -> (ObjectMember, int, bool) {
	i := cursor
	for i < len(data) && is_space(data[i]) {
		i += 1
	}
	if i >= len(data) || data[i] == '}' {
		return ObjectMember{}, i, false
	}
	if data[i] != '"' {
		return ObjectMember{}, i, false
	}
	key_start := i + 1
	i += 1
	escaped := false
	for i < len(data) {
		if escaped {
			escaped = false
			i += 1
			continue
		}
		if data[i] == '\\' {
			escaped = true
			i += 1
			continue
		}
		if data[i] == '"' {
			break
		}
		i += 1
	}
	if i >= len(data) {
		return ObjectMember{}, i, false
	}
	key_end := i
	i += 1
	for i < len(data) && is_space(data[i]) {
		i += 1
	}
	if i >= len(data) || data[i] != ':' {
		return ObjectMember{}, i, false
	}
	i += 1
	for i < len(data) && is_space(data[i]) {
		i += 1
	}
	value_start := i
	value_end, ok := scan_json_value_end(data, value_start)
	if !ok {
		return ObjectMember{}, i, false
	}
	next_cursor := value_end
	for next_cursor < len(data) && is_space(data[next_cursor]) {
		next_cursor += 1
	}
	if next_cursor < len(data) && data[next_cursor] == ',' {
		next_cursor += 1
	}
	return ObjectMember {
			key_start = key_start,
			key_end = key_end,
			value_start = value_start,
			value_end = value_end,
		},
		next_cursor,
		true
}

compile_named_type_from_top_level_value :: proc(
	input: []u8,
	value_slice: []u8,
	value_abs_start: int,
	type_idx: int,
) -> string {
	trim_offset := trim_left_space_count(value_slice)
	trimmed := trim_bytes_space(value_slice)
	trimmed_abs_start := value_abs_start + trim_offset
	if len(trimmed) == 0 {
		return "type definition missing value"
	}
	if trimmed[0] == '"' {
		target_idx, err := resolve_type_from_value_slice(trimmed)
		if err != "" {
			return err
		}
		types[type_idx].kind = .Alias
		types[type_idx].target_type = target_idx
		return ""
	}
	if trimmed[0] != '{' {
		return "type definition must be string or object"
	}
	type_start, type_end, has_type := find_top_level_value_bounds(trimmed, "type")
	if !has_type {
		return "type definition missing type field"
	}
	type_name := trim_bytes_space(trimmed[type_start:type_end])
	if len(type_name) >= 2 && type_name[0] == '"' && type_name[len(type_name) - 1] == '"' {
		type_name = type_name[1:len(type_name) - 1]
	}
	if slice_matches_string(type_name, "array") {
		err := compile_array_type_from_slice(trimmed, type_idx)
		if err != "" {
			return schema_type_error(type_idx, ".len", err)
		}
		return ""
	}
	if slice_matches_string(type_name, "vector") {
		err := compile_vector_type_from_slice(trimmed, type_idx)
		if err != "" {
			return schema_type_error(type_idx, ".value", err)
		}
		return ""
	}
	if slice_matches_string(type_name, "oneof") {
		err := compile_oneof_type_from_slice(trimmed, type_idx)
		if err != "" {
			return schema_type_error(type_idx, ".value", err)
		}
		return ""
	}
	if slice_matches_string(type_name, "struct") {
		return compile_struct_type_from_slice(trimmed, trimmed_abs_start, type_idx)
	}
	if slice_matches_string(type_name, "enum") {
		return compile_enum_type_from_slice(trimmed, trimmed_abs_start, type_idx)
	}
	if slice_matches_string(type_name, "bytes") {
		types[type_idx].kind = .Bytes
		types[type_idx].max_len = read_optional_int_from_slice(trimmed, "max_len")
		return ""
	}
	if slice_matches_string(type_name, "string") {
		types[type_idx].kind = .String
		types[type_idx].max_len = read_optional_int_from_slice(trimmed, "max_len")
		return ""
	}
	value_token_idx := find_token_by_start(
		schema_tokens[:schema_token_count],
		trimmed_abs_start,
		jsmn.JsmnType.Object,
	)
	if value_token_idx < 0 {
		return join2("type token lookup failed: ", type_name_string(type_idx))
	}
	return compile_named_type(input, value_token_idx, type_idx)
}

compile_struct_type_from_slice :: proc(obj_slice: []u8, abs_start: int, type_idx: int) -> string {
	fields_start, fields_end, has_fields := find_top_level_value_bounds(obj_slice, "fields")
	if !has_fields {
		return "struct missing fields object"
	}
	fields_slice := obj_slice[fields_start:fields_end]
	if len(fields_slice) == 0 || fields_slice[0] != '{' {
		return "struct fields must be object"
	}
	start := field_count
	cursor := 1
	for {
		member, next_cursor, found := next_object_member(fields_slice, cursor)
		if !found {
			break
		}
		if field_count >= MAX_FIELDS {
			return "field limit exceeded"
		}
		field, err := compile_field_from_slice(fields_slice, abs_start + fields_start, type_idx, member)
		if err != "" {
			return err
		}
		fields[field_count] = field
		field_count += 1
		cursor = next_cursor
	}
	types[type_idx].kind = .Struct
	types[type_idx].field_start = start
	types[type_idx].field_count = field_count - start
	return ""
}

compile_field_from_slice :: proc(
	fields_slice: []u8,
	fields_abs_start: int,
	parent_type_idx: int,
	member: ObjectMember,
) -> (
	FieldDef,
	string,
) {
	field := FieldDef {
		name_start    = fields_abs_start + member.key_start,
		name_end      = fields_abs_start + member.key_end,
		default_token = -1,
		default_start = -1,
		default_end   = -1,
		max_len       = -1,
	}
	value_raw_slice := fields_slice[member.value_start:member.value_end]
	value_trim_offset := trim_left_space_count(value_raw_slice)
	value_slice := trim_bytes_space(value_raw_slice)
	value_abs_start := fields_abs_start + member.value_start + value_trim_offset
	if len(value_slice) == 0 {
		return FieldDef{}, "field definition missing value"
	}
	if value_slice[0] == '"' {
		type_idx, err := resolve_type_from_value_slice(value_slice)
		if err != "" {
			return FieldDef{}, err
		}
		field.type_index = type_idx
		return field, ""
	}
	if value_slice[0] != '{' {
		return FieldDef{}, "field definition must be string or object"
	}
	type_start, type_end, has_type := find_top_level_value_bounds(value_slice, "type")
	if !has_type {
		return FieldDef{}, "field definition missing type"
	}
	type_name := trim_bytes_space(value_slice[type_start:type_end])
	if len(type_name) >= 2 && type_name[0] == '"' && type_name[len(type_name) - 1] == '"' {
		type_name = type_name[1:len(type_name) - 1]
	}
	if slice_matches_string(type_name, "vector") ||
	   slice_matches_string(type_name, "array") ||
	   slice_matches_string(type_name, "bytes") ||
	   slice_matches_string(type_name, "string") ||
	   slice_matches_string(type_name, "oneof") {
		anon_idx, err := new_anonymous_type()
		if err != "" {
			return FieldDef{}, err
		}
		field_name := string(fields_slice[member.key_start:member.key_end])
		err_suffix := ""
		if slice_matches_string(type_name, "vector") {
			err = compile_vector_type_from_slice(value_slice, anon_idx)
			err_suffix = ".value"
		} else if slice_matches_string(type_name, "array") {
			err = compile_array_type_from_slice(value_slice, anon_idx)
			err_suffix = ".len"
		} else if slice_matches_string(type_name, "oneof") {
			err = compile_oneof_type_from_slice(value_slice, anon_idx)
			err_suffix = ".value"
		} else if slice_matches_string(type_name, "bytes") {
			types[anon_idx].kind = .Bytes
			types[anon_idx].max_len = read_optional_int_from_slice(value_slice, "max_len")
		} else if slice_matches_string(type_name, "string") {
			types[anon_idx].kind = .String
			types[anon_idx].max_len = read_optional_int_from_slice(value_slice, "max_len")
		}
		if err != "" {
			return FieldDef{}, schema_field_error(parent_type_idx, field_name, err_suffix, err)
		}
		field.type_index = anon_idx
		field.max_len = read_optional_int_from_slice(value_slice, "max_len")
		if default_start, default_end, has_default := find_top_level_value_bounds(value_slice, "default"); has_default {
			default_token := find_token_by_value_start(schema_tokens[:schema_token_count], value_abs_start + default_start)
			field.has_default = true
			field.default_token = default_token
			field.default_start = value_abs_start + default_start
			field.default_end = value_abs_start + default_end
		}
		return field, ""
	}
	type_idx, err := resolve_type_from_value_slice(type_name)
	if err != "" {
		return FieldDef{}, "unsupported top-level field object"
	}
	field.type_index = type_idx
	field.max_len = read_optional_int_from_slice(value_slice, "max_len")
	if default_start, default_end, has_default := find_top_level_value_bounds(value_slice, "default"); has_default {
		default_token := find_token_by_value_start(schema_tokens[:schema_token_count], value_abs_start + default_start)
		field.has_default = true
		field.default_token = default_token
		field.default_start = value_abs_start + default_start
		field.default_end = value_abs_start + default_end
	}
	return field, ""
}

find_token_by_bounds :: proc(tokens: []jsmn.Token, start, end: int, kind: jsmn.JsmnType) -> int {
	for i in 0 ..< len(tokens) {
		if tokens[i].start == start && tokens[i].end == end && tokens[i].type == kind {
			return i
		}
	}
	return -1
}

find_token_by_start :: proc(tokens: []jsmn.Token, start: int, kind: jsmn.JsmnType) -> int {
	for i in 0 ..< len(tokens) {
		if tokens[i].start == start && tokens[i].type == kind {
			return i
		}
	}
	return -1
}

find_token_by_value_start :: proc(tokens: []jsmn.Token, start: int) -> int {
	best := -1
	best_delta := 1024
	for i in 0 ..< len(tokens) {
		if tokens[i].start < start {
			continue
		}
		delta := tokens[i].start - start
		if delta < best_delta {
			best = i
			best_delta = delta
		}
	}
	if best_delta <= 64 {
		return best
	}
	return -1
}

trim_left_space_count :: proc(data: []u8) -> int {
	count := 0
	for count < len(data) && is_space(data[count]) {
		count += 1
	}
	return count
}

resolve_named_type_bytes :: proc(input: []u8, tok: jsmn.Token) -> (int, string) {
	for i in 0 ..< type_count {
		if !types[i].has_name {
			continue
		}
		if type_name_matches(i, input, tok) {
			return i, ""
		}
	}
	return -1, "unknown type reference"
}

find_top_level_value_bounds :: proc(input: []u8, key: string) -> (int, int, bool) {
	depth := 0
	in_string := false
	escaped := false
	i := 0
	for i < len(input) {
		c := input[i]
		if in_string {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
			i += 1
			continue
		}
		switch c {
		case '"':
			if depth == 1 && match_key_at(input, i, key) {
				j := i + len(key) + 2
				for j < len(input) && is_space(input[j]) {
					j += 1
				}
				if j >= len(input) || input[j] != ':' {
					i += 1
					continue
				}
				j += 1
				for j < len(input) && is_space(input[j]) {
					j += 1
				}
				end, ok := scan_json_value_end(input, j)
				if !ok {
					return -1, -1, false
				}
				return j, end, true
			}
			in_string = true
		case '{', '[':
			depth += 1
		case '}', ']':
			depth -= 1
		case:
		}
		i += 1
	}
	return -1, -1, false
}

match_key_at :: proc(input: []u8, quote_idx: int, key: string) -> bool {
	if quote_idx + len(key) + 1 >= len(input) {
		return false
	}
	if input[quote_idx] != '"' {
		return false
	}
	for i in 0 ..< len(key) {
		if input[quote_idx + 1 + i] != key[i] {
			return false
		}
	}
	return input[quote_idx + len(key) + 1] == '"'
}

scan_json_value_end :: proc(input: []u8, start: int) -> (int, bool) {
	if start >= len(input) {
		return -1, false
	}
	if input[start] == '{' || input[start] == '[' {
		depth := 0
		in_string := false
		escaped := false
		for i in start ..< len(input) {
			c := input[i]
			if in_string {
				if escaped {
					escaped = false
				} else if c == '\\' {
					escaped = true
				} else if c == '"' {
					in_string = false
				}
				continue
			}
			switch c {
			case '"':
				in_string = true
			case '{', '[':
				depth += 1
			case '}', ']':
				depth -= 1
				if depth == 0 {
					return i + 1, true
				}
			case:
			}
		}
		return -1, false
	}
	if input[start] == '"' {
		escaped := false
		for i in start + 1 ..< len(input) {
			if escaped {
				escaped = false
				continue
			}
			if input[i] == '\\' {
				escaped = true
				continue
			}
			if input[i] == '"' {
				return i + 1, true
			}
		}
		return -1, false
	}
	for i in start ..< len(input) {
		if input[i] == ',' || input[i] == '}' || input[i] == ']' {
			return i, true
		}
	}
	return len(input), true
}

is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

add_builtin_types :: proc() {
	add_builtin_type(.Bool, "bool")
	add_builtin_type(.U8, "u8")
	add_builtin_type(.U16, "u16")
	add_builtin_type(.U32, "u32")
	add_builtin_type(.U64, "u64")
	add_builtin_type(.I8, "i8")
	add_builtin_type(.I16, "i16")
	add_builtin_type(.I32, "i32")
	add_builtin_type(.I64, "i64")
	add_builtin_type(.F32, "f32")
	add_builtin_type(.F64, "f64")
	add_builtin_type(.String, "string")
	add_builtin_type(.Bytes, "bytes")
}

add_builtin_type :: proc(kind: TypeKind, name: string) {
	idx := type_count
	types[idx].kind = kind
	types[idx].has_name = true
	types[idx].name_start = -1
	types[idx].name_end = -1
	types[idx].max_len = -1
	types[idx].target_type = -1
	types[idx].fixed_len = -1
	type_count += 1
	store_builtin_name(idx, name)
}

builtin_names: [13]string

store_builtin_name :: proc(idx: int, name: string) {
	builtin_names[idx] = name
}

declare_named_type :: proc(tok: jsmn.Token) -> (int, string) {
	if type_count >= MAX_TYPES {
		return -1, "type limit exceeded"
	}
	if tok.end - tok.start > TYPE_NAME_MAX {
		return -1, "type name too long"
	}
	if _, found := lookup_named_type(schema_buffer[:schema_len], tok); found {
		return -1, "duplicate type name"
	}
	idx := type_count
	types[idx] = TypeDef {
		kind        = .Invalid,
		has_name    = true,
		name_start  = tok.start,
		name_end    = tok.end,
		max_len     = -1,
		target_type = -1,
		fixed_len   = -1,
	}
	type_count += 1
	named_type_indices[named_type_count] = idx
	named_type_name_lens[idx] = tok.end - tok.start
	copy(named_type_name_bytes[idx][:named_type_name_lens[idx]], schema_buffer[tok.start:tok.end])
	named_type_count += 1
	return idx, ""
}

new_anonymous_type :: proc() -> (int, string) {
	if type_count >= MAX_TYPES {
		return -1, "type limit exceeded"
	}
	idx := type_count
	types[idx] = TypeDef {
		target_type = -1,
		fixed_len   = -1,
		max_len     = -1,
	}
	type_count += 1
	return idx, ""
}

lookup_named_type :: proc(input: []u8, tok: jsmn.Token) -> (int, bool) {
	for i in 0 ..< type_count {
		if !types[i].has_name {
			continue
		}
		if type_name_matches(i, input, tok) {
			return i, true
		}
	}
	return -1, false
}

type_name_matches :: proc(type_idx: int, input: []u8, tok: jsmn.Token) -> bool {
	if type_idx < len(builtin_names) &&
	   builtin_names[type_idx] != "" &&
	   types[type_idx].name_start == -1 {
		name := builtin_names[type_idx]
		return token_matches(input, tok, name)
	}
	name_tok := types[type_idx]
	span := tok.end - tok.start
	if !name_tok.has_name || span != name_tok.name_end - name_tok.name_start {
		return false
	}
	for i in 0 ..< span {
		if input[tok.start + i] != schema_buffer[name_tok.name_start + i] {
			return false
		}
	}
	return true
}

compile_named_type :: proc(input: []u8, token_idx: int, type_idx: int) -> string {
	tok := schema_tokens[token_idx]
	if tok.type == jsmn.JsmnType.String {
		target_idx, err := resolve_type_from_token(input, token_idx)
		if err != "" {
			return err
		}
		types[type_idx].kind = .Alias
		types[type_idx].target_type = target_idx
		return ""
	}
	if tok.type != jsmn.JsmnType.Object {
		return "type definition must be string or object"
	}
	if tok.end <= tok.start {
		return compile_named_type_from_key_bounds(
			input,
			types[type_idx].name_start,
			types[type_idx].name_end,
			type_idx,
		)
	}
	type_field := find_object_value(input, schema_tokens[:schema_token_count], token_idx, "type")
	if type_field < 0 {
		return "type definition missing type field"
	}
	type_name := schema_tokens[type_field]
	if type_name.type != jsmn.JsmnType.String {
		return "type field must be string"
	}
	if token_matches(input, type_name, "enum") {
		return compile_enum_type(input, token_idx, type_idx)
	}
	if token_matches(input, type_name, "struct") {
		return compile_struct_type(input, token_idx, type_idx)
	}
	if token_matches(input, type_name, "array") {
		return compile_array_type(input, token_idx, type_idx)
	}
	if token_matches(input, type_name, "vector") {
		return compile_vector_type(input, token_idx, type_idx)
	}
	if token_matches(input, type_name, "oneof") {
		return compile_oneof_type(input, token_idx, type_idx)
	}
	if token_matches(input, type_name, "string") {
		types[type_idx].kind = .String
		types[type_idx].max_len = read_optional_int(input, token_idx, "max_len")
		return ""
	}
	if token_matches(input, type_name, "bytes") {
		types[type_idx].kind = .Bytes
		types[type_idx].max_len = read_optional_int(input, token_idx, "max_len")
		return ""
	}
	target_idx, err := resolve_type_from_token(input, type_field)
	if err != "" {
		return err
	}
	types[type_idx].kind = .Alias
	types[type_idx].target_type = target_idx
	return ""
}

compile_named_type_from_key_bounds :: proc(
	input: []u8,
	key_start, key_end, type_idx: int,
) -> string {
	value_start, value_end, ok := find_value_bounds_after_key(input, key_end)
	if !ok {
		return "type definition missing value"
	}
	value_slice := trim_bytes_space(input[value_start:value_end])
	if len(value_slice) >= 2 && value_slice[0] == '"' && value_slice[len(value_slice) - 1] == '"' {
		target_idx, err := resolve_type_from_value_slice(value_slice)
		if err != "" {
			return err
		}
		types[type_idx].kind = .Alias
		types[type_idx].target_type = target_idx
		return ""
	}
	if len(value_slice) == 0 || value_slice[0] != '{' {
		return "type definition must be string or object"
	}
	type_start, type_end, has_type := find_top_level_value_bounds(value_slice, "type")
	if !has_type {
		return "type definition missing type field"
	}
	type_name := trim_bytes_space(value_slice[type_start:type_end])
	if len(type_name) >= 2 && type_name[0] == '"' && type_name[len(type_name) - 1] == '"' {
		type_name = type_name[1:len(type_name) - 1]
	}
	if slice_matches_string(type_name, "array") {
		return compile_array_type_from_slice(value_slice, type_idx)
	}
	if slice_matches_string(type_name, "vector") {
		return compile_vector_type_from_slice(value_slice, type_idx)
	}
	if slice_matches_string(type_name, "oneof") {
		return compile_oneof_type_from_slice(value_slice, type_idx)
	}
	if slice_matches_string(type_name, "enum") {
		return compile_enum_type_from_slice(value_slice, value_start, type_idx)
	}
	if slice_matches_string(type_name, "bytes") {
		types[type_idx].kind = .Bytes
		types[type_idx].max_len = read_optional_int_from_slice(value_slice, "max_len")
		return ""
	}
	if slice_matches_string(type_name, "string") {
		types[type_idx].kind = .String
		types[type_idx].max_len = read_optional_int_from_slice(value_slice, "max_len")
		return ""
	}
	return "type object token invalid"
}

compile_enum_type_from_slice :: proc(obj_slice: []u8, abs_start: int, type_idx: int) -> string {
	value_start, value_end, has_value := find_top_level_value_bounds(obj_slice, "value")
	if !has_value {
		return "enum missing value"
	}
	value_slice := trim_bytes_space(obj_slice[value_start:value_end])
	start := enum_value_count
	if len(value_slice) == 0 {
		return "enum value must be array or object"
	}
	if value_slice[0] == '[' {
		ordinal: i64 = 0
		cursor := 1
		for {
			element_start := cursor
			for element_start < len(value_slice) && is_space(value_slice[element_start]) {
				element_start += 1
			}
			element, next_cursor, found := next_array_element(value_slice, cursor)
			if !found {
				break
			}
			trimmed := trim_bytes_space(element)
			if len(trimmed) < 2 || trimmed[0] != '"' || trimmed[len(trimmed) - 1] != '"' {
				return "enum array values must be strings"
			}
			if enum_value_count >= MAX_ENUM_VALUES {
				return "enum value limit exceeded"
			}
			enum_values[enum_value_count] = EnumValue {
				name_start = abs_start + value_start + element_start + 1,
				name_end   = abs_start + value_start + element_start + len(trimmed) - 1,
				value      = ordinal,
			}
			enum_value_count += 1
			ordinal += 1
			cursor = next_cursor
		}
	} else if value_slice[0] == '{' {
		cursor := 1
		for {
			member, next_cursor, found := next_object_member(value_slice, cursor)
			if !found {
				break
			}
			if enum_value_count >= MAX_ENUM_VALUES {
				return "enum value limit exceeded"
			}
			v, ok := parse_i64_bytes(trim_bytes_space(value_slice[member.value_start:member.value_end]))
			if !ok {
				return "enum object values must be integers"
			}
			enum_values[enum_value_count] = EnumValue {
				name_start = abs_start + value_start + member.key_start,
				name_end   = abs_start + value_start + member.key_end,
				value      = v,
			}
			enum_value_count += 1
			cursor = next_cursor
		}
	} else {
		return "enum value must be array or object"
	}
	types[type_idx].kind = .Enum
	types[type_idx].enum_start = start
	types[type_idx].enum_count = enum_value_count - start
	return ""
}

compile_enum_type :: proc(input: []u8, obj_idx: int, type_idx: int) -> string {
	value_idx := find_object_value(input, schema_tokens[:schema_token_count], obj_idx, "value")
	if value_idx < 0 {
		return "enum missing value"
	}
	start := enum_value_count
	tok := schema_tokens[value_idx]
	if tok.type == jsmn.JsmnType.Array {
		ordinal: i64 = 0
		for i in 0 ..< schema_token_count {
			if schema_tokens[i].parent != value_idx {
				continue
			}
			if schema_tokens[i].type != jsmn.JsmnType.String {
				return "enum array values must be strings"
			}
			if enum_value_count >= MAX_ENUM_VALUES {
				return "enum value limit exceeded"
			}
			enum_values[enum_value_count] = EnumValue {
				name_start = schema_tokens[i].start,
				name_end   = schema_tokens[i].end,
				value      = ordinal,
			}
			enum_value_count += 1
			ordinal += 1
		}
	} else if tok.type == jsmn.JsmnType.Object {
		for i in 0 ..< (schema_token_count - 1) {
			if schema_tokens[i].parent != value_idx ||
			   schema_tokens[i].type != jsmn.JsmnType.String {
				continue
			}
			if schema_tokens[i + 1].parent != value_idx {
				continue
			}
			if enum_value_count >= MAX_ENUM_VALUES {
				return "enum value limit exceeded"
			}
			v, ok := parse_i64_bytes(trim_bytes_space(input[schema_tokens[i + 1].start:schema_tokens[i + 1].end]))
			if !ok {
				return "enum object values must be integers"
			}
			enum_values[enum_value_count] = EnumValue {
				name_start = schema_tokens[i].start,
				name_end   = schema_tokens[i].end,
				value      = v,
			}
			enum_value_count += 1
		}
	} else {
		return "enum value must be array or object"
	}
	types[type_idx].kind = .Enum
	types[type_idx].enum_start = start
	types[type_idx].enum_count = enum_value_count - start
	return ""
}

compile_struct_type :: proc(input: []u8, obj_idx: int, type_idx: int) -> string {
	fields_idx := find_object_value(input, schema_tokens[:schema_token_count], obj_idx, "fields")
	if fields_idx < 0 {
		return "struct missing fields object"
	}
	if schema_tokens[fields_idx].type != jsmn.JsmnType.Object {
		return "struct fields must be object"
	}
	start := field_count
	for i in 0 ..< (schema_token_count - 1) {
		key := schema_tokens[i]
		if key.parent != fields_idx || key.type != jsmn.JsmnType.String {
			continue
		}
		if field_count >= MAX_FIELDS {
			return "field limit exceeded"
		}
		field, err := compile_field(input, key, i + 1)
		if err != "" {
			return err
		}
		fields[field_count] = field
		field_count += 1
	}
	types[type_idx].kind = .Struct
	types[type_idx].field_start = start
	types[type_idx].field_count = field_count - start
	return ""
}

compile_array_type :: proc(input: []u8, obj_idx: int, type_idx: int) -> string {
	obj_tok := schema_tokens[obj_idx]
	if obj_tok.start < 0 {
		return "array token start invalid"
	}
	if obj_tok.end <= obj_tok.start {
		return "array token end invalid"
	}
	if obj_tok.end > len(input) {
		return "array token range invalid"
	}
	obj_slice := input[obj_tok.start:obj_tok.end]
	return compile_array_type_from_slice(obj_slice, type_idx)
}

compile_array_type_from_slice :: proc(obj_slice: []u8, type_idx: int) -> string {
	len_start, len_end, has_len := find_top_level_value_bounds(obj_slice, "len")
	value_start, value_end, has_value := find_top_level_value_bounds(obj_slice, "value")
	if !has_len || !has_value {
		return "array requires len and value"
	}
	length, ok := parse_i64_bytes(obj_slice[len_start:len_end])
	if !ok || length < 0 {
		return "array len must be non-negative integer"
	}
	value_type, err := resolve_type_from_value_slice(obj_slice[value_start:value_end])
	if err != "" {
		return err
	}
	types[type_idx].kind = .Array
	types[type_idx].target_type = value_type
	types[type_idx].fixed_len = int(length)
	return ""
}

compile_vector_type :: proc(input: []u8, obj_idx: int, type_idx: int) -> string {
	obj_tok := schema_tokens[obj_idx]
	if obj_tok.start < 0 || obj_tok.end <= obj_tok.start || obj_tok.end > len(input) {
		return "vector token bounds invalid"
	}
	obj_slice := input[obj_tok.start:obj_tok.end]
	return compile_vector_type_from_slice(obj_slice, type_idx)
}

compile_vector_type_from_slice :: proc(obj_slice: []u8, type_idx: int) -> string {
	value_start, value_end, has_value := find_top_level_value_bounds(obj_slice, "value")
	if !has_value {
		return "vector requires value"
	}
	value_type, err := resolve_type_from_value_slice(obj_slice[value_start:value_end])
	if err != "" {
		return err
	}
	types[type_idx].kind = .Vector
	types[type_idx].target_type = value_type
	return ""
}

compile_oneof_type :: proc(input: []u8, obj_idx: int, type_idx: int) -> string {
	value_idx := find_object_value(input, schema_tokens[:schema_token_count], obj_idx, "value")
	if value_idx < 0 {
		return "oneof requires value"
	}
	if schema_tokens[value_idx].type != jsmn.JsmnType.Array {
		return "oneof value must be array"
	}
	start := oneof_option_count
	for i in 0 ..< schema_token_count {
		if schema_tokens[i].parent != value_idx {
			continue
		}
		if oneof_option_count >= MAX_ONEOF_OPTIONS {
			return "oneof option limit exceeded"
		}
		option_type, err := resolve_type_from_token(input, i)
		if err != "" {
			return err
		}
		oneof_options[oneof_option_count] = option_type
		oneof_option_count += 1
	}
	types[type_idx].kind = .Oneof
	types[type_idx].option_start = start
	types[type_idx].option_count = oneof_option_count - start
	return ""
}

compile_oneof_type_from_slice :: proc(obj_slice: []u8, type_idx: int) -> string {
	value_start, value_end, has_value := find_top_level_value_bounds(obj_slice, "value")
	if !has_value {
		return "oneof requires value"
	}
	value_slice := trim_bytes_space(obj_slice[value_start:value_end])
	if len(value_slice) == 0 || value_slice[0] != '[' {
		return "oneof value must be array"
	}
	start := oneof_option_count
	cursor := 1
	for {
		element, next_cursor, found := next_array_element(value_slice, cursor)
		if !found {
			break
		}
		if oneof_option_count >= MAX_ONEOF_OPTIONS {
			return "oneof option limit exceeded"
		}
		option_type, err := resolve_type_from_value_slice(element)
		if err != "" {
			return err
		}
		oneof_options[oneof_option_count] = option_type
		oneof_option_count += 1
		cursor = next_cursor
	}
	types[type_idx].kind = .Oneof
	types[type_idx].option_start = start
	types[type_idx].option_count = oneof_option_count - start
	return ""
}

compile_field :: proc(input: []u8, name_tok: jsmn.Token, value_idx: int) -> (FieldDef, string) {
	field := FieldDef {
		name_start    = name_tok.start,
		name_end      = name_tok.end,
		default_token = -1,
		default_start = -1,
		default_end   = -1,
		max_len       = -1,
	}
	tok := schema_tokens[value_idx]
	if tok.type == jsmn.JsmnType.String {
		type_idx, err := resolve_type_from_token(input, value_idx)
		if err != "" {
			return FieldDef{}, err
		}
		field.type_index = type_idx
		return field, ""
	}
	if tok.type != jsmn.JsmnType.Object {
		return FieldDef{}, "field definition must be string or object"
	}
	type_field := find_object_value(input, schema_tokens[:schema_token_count], value_idx, "type")
	if type_field < 0 {
		return FieldDef{}, "field definition missing type"
	}
	type_idx, err := resolve_field_type(input, value_idx, type_field)
	if err != "" {
		return FieldDef{}, err
	}
	field.type_index = type_idx
	default_idx := find_object_value(
		input,
		schema_tokens[:schema_token_count],
		value_idx,
		"default",
	)
	if default_idx >= 0 {
		field.has_default = true
		field.default_token = default_idx
		default_tok := schema_tokens[default_idx]
		field.default_start = default_tok.start
		field.default_end = default_tok.end
		if default_tok.type == jsmn.JsmnType.String && default_tok.start > 0 && default_tok.end < len(input) {
			field.default_start = default_tok.start - 1
			field.default_end = default_tok.end + 1
		}
	}
	if min_idx := find_object_value(input, schema_tokens[:schema_token_count], value_idx, "min");
	   min_idx >= 0 {
		v, ok := parse_f64_bytes(input[schema_tokens[min_idx].start:schema_tokens[min_idx].end])
		if !ok {
			return FieldDef{}, "field min must be numeric"
		}
		field.has_min = true
		field.min_value = v
	}
	if max_idx := find_object_value(input, schema_tokens[:schema_token_count], value_idx, "max");
	   max_idx >= 0 {
		v, ok := parse_f64_bytes(input[schema_tokens[max_idx].start:schema_tokens[max_idx].end])
		if !ok {
			return FieldDef{}, "field max must be numeric"
		}
		field.has_max = true
		field.max_value = v
	}
	field.max_len = read_optional_int(input, value_idx, "max_len")
	return field, ""
}

resolve_field_type :: proc(input: []u8, obj_idx: int, type_field_idx: int) -> (int, string) {
	type_tok := schema_tokens[type_field_idx]
	if token_matches(input, type_tok, "enum") ||
	   token_matches(input, type_tok, "struct") ||
	   token_matches(input, type_tok, "array") ||
	   token_matches(input, type_tok, "vector") ||
	   token_matches(input, type_tok, "oneof") ||
	   token_matches(input, type_tok, "string") ||
	   token_matches(input, type_tok, "bytes") {
		idx, err := new_anonymous_type()
		if err != "" {
			return -1, err
		}
		err = compile_named_type(input, obj_idx, idx)
		if err != "" {
			return -1, err
		}
		return idx, ""
	}
	return resolve_type_from_token(input, type_field_idx)
}

resolve_type_from_token :: proc(input: []u8, token_idx: int) -> (int, string) {
	tok := schema_tokens[token_idx]
	if tok.type != jsmn.JsmnType.String {
		return -1, "type reference must be string"
	}
	return resolve_type_from_value_slice(input[tok.start:tok.end])
}

resolve_type_from_value_slice :: proc(data: []u8) -> (int, string) {
	trimmed := trim_bytes_space(data)
	if len(trimmed) >= 2 && trimmed[0] == '"' && trimmed[len(trimmed) - 1] == '"' {
		trimmed = trimmed[1:len(trimmed) - 1]
	}
	for i in 0 ..< len(builtin_names) {
		if type_name_matches_slice(i, trimmed) {
			return i, ""
		}
	}
	for i in 0 ..< named_type_count {
		type_idx := named_type_indices[i]
		if type_name_matches_slice(type_idx, trimmed) {
			return type_idx, ""
		}
	}
	return -1, "unknown type reference"
}

type_name_matches_slice :: proc(type_idx: int, data: []u8) -> bool {
	if type_idx < len(builtin_names) &&
	   builtin_names[type_idx] != "" &&
	   types[type_idx].name_start == -1 {
		return slice_matches_string(data, builtin_names[type_idx])
	}
	if !types[type_idx].has_name || len(data) != named_type_name_lens[type_idx] {
		return false
	}
	for i in 0 ..< len(data) {
		if data[i] != named_type_name_bytes[type_idx][i] {
			return false
		}
	}
	return true
}

trim_bytes_space :: proc(data: []u8) -> []u8 {
	start := 0
	end := len(data)
	for start < end && is_space(data[start]) {
		start += 1
	}
	for end > start && is_space(data[end - 1]) {
		end -= 1
	}
	return data[start:end]
}

slice_matches_string :: proc(data: []u8, text: string) -> bool {
	if len(data) != len(text) {
		return false
	}
	for i in 0 ..< len(text) {
		if data[i] != text[i] {
			return false
		}
	}
	return true
}

read_optional_int :: proc(input: []u8, obj_idx: int, key: string) -> int {
	value_idx := find_object_value(input, schema_tokens[:schema_token_count], obj_idx, key)
	if value_idx < 0 {
		return -1
	}
	v, ok := parse_i64_bytes(input[schema_tokens[value_idx].start:schema_tokens[value_idx].end])
	if !ok {
		return -1
	}
	return int(v)
}

read_optional_int_from_slice :: proc(data: []u8, key: string) -> int {
	start, end, ok := find_top_level_value_bounds(data, key)
	if !ok {
		return -1
	}
	v, parsed := parse_i64_bytes(trim_bytes_space(data[start:end]))
	if !parsed {
		return -1
	}
	return int(v)
}

find_value_bounds_after_key :: proc(input: []u8, key_end: int) -> (int, int, bool) {
	i := key_end + 1
	for i < len(input) && input[i] != ':' {
		i += 1
	}
	if i >= len(input) {
		return -1, -1, false
	}
	i += 1
	for i < len(input) && is_space(input[i]) {
		i += 1
	}
	end, ok := scan_json_value_end(input, i)
	if !ok {
		return -1, -1, false
	}
	return i, end, true
}

find_object_value :: proc(input: []u8, tokens: []jsmn.Token, object_idx: int, key: string) -> int {
	for i in 0 ..< (len(tokens) - 1) {
		tok := tokens[i]
		if tok.parent != object_idx || tok.type != jsmn.JsmnType.String {
			continue
		}
		if token_matches(input, tok, key) {
			return i + 1
		}
	}
	return -1
}

find_any_key_value :: proc(input: []u8, tokens: []jsmn.Token, key: string) -> int {
	for i in 0 ..< (len(tokens) - 1) {
		if tokens[i].type != jsmn.JsmnType.String {
			continue
		}
		if token_matches(input, tokens[i], key) {
			return i + 1
		}
	}
	return -1
}

count_array_children :: proc(tokens: []jsmn.Token, array_idx: int) -> int {
	count := 0
	for i in 0 ..< len(tokens) {
		if tokens[i].parent == array_idx {
			count += 1
		}
	}
	return count
}

type_name_string :: proc(type_idx: int) -> string {
	if type_idx < len(builtin_names) &&
	   builtin_names[type_idx] != "" &&
	   types[type_idx].name_start == -1 {
		return builtin_names[type_idx]
	}
	return string(named_type_name_bytes[type_idx][:named_type_name_lens[type_idx]])
}

field_name_string :: proc(field_idx: int) -> string {
	field := fields[field_idx]
	return string(schema_buffer[field.name_start:field.name_end])
}

schema_type_error :: proc(type_idx: int, suffix: string, err: string) -> string {
	return join3(join3("schema.types.", type_name_string(type_idx), suffix), ": ", err)
}

schema_field_error :: proc(parent_type_idx: int, field_name: string, suffix: string, err: string) -> string {
	return join3(join3(join3("schema.types.", type_name_string(parent_type_idx), ".fields."), field_name, suffix), ": ", err)
}

enum_name_string :: proc(enum_idx: int) -> string {
	value := enum_values[enum_idx]
	return string(schema_buffer[value.name_start:value.name_end])
}

parse_i64_bytes :: proc(data: []u8) -> (i64, bool) {
	if len(data) == 0 {
		return 0, false
	}
	neg := false
	idx := 0
	if data[0] == '-' {
		neg = true
		idx = 1
	}
	if idx >= len(data) {
		return 0, false
	}
	value: i64 = 0
	for idx < len(data) {
		c := data[idx]
		if c < '0' || c > '9' {
			return 0, false
		}
		value = value * 10 + i64(c - '0')
		idx += 1
	}
	if neg {
		value = -value
	}
	return value, true
}

parse_f64_bytes :: proc(data: []u8) -> (f64, bool) {
	if len(data) == 0 {
		return 0, false
	}
	neg := false
	idx := 0
	if data[0] == '-' {
		neg = true
		idx = 1
	}
	if idx >= len(data) {
		return 0, false
	}
	whole: f64 = 0
	has_digit := false
	for idx < len(data) && data[idx] >= '0' && data[idx] <= '9' {
		whole = whole * 10 + f64(data[idx] - '0')
		idx += 1
		has_digit = true
	}
	frac: f64 = 0
	divisor: f64 = 1
	if idx < len(data) && data[idx] == '.' {
		idx += 1
		for idx < len(data) && data[idx] >= '0' && data[idx] <= '9' {
			frac = frac * 10 + f64(data[idx] - '0')
			divisor *= 10
			idx += 1
			has_digit = true
		}
	}
	value := whole + frac / divisor
	if idx < len(data) && (data[idx] == 'e' || data[idx] == 'E') {
		idx += 1
		exp_neg := false
		if idx < len(data) && (data[idx] == '-' || data[idx] == '+') {
			exp_neg = data[idx] == '-'
			idx += 1
		}
		if idx >= len(data) || data[idx] < '0' || data[idx] > '9' {
			return 0, false
		}
		exp: int = 0
		for idx < len(data) && data[idx] >= '0' && data[idx] <= '9' {
			exp = exp * 10 + int(data[idx] - '0')
			idx += 1
		}
		factor: f64 = 1
		for _ in 0 ..< exp {
			factor *= 10
		}
		if exp_neg {
			value /= factor
		} else {
			value *= factor
		}
	}
	if !has_digit || idx != len(data) {
		return 0, false
	}
	if neg {
		value = -value
	}
	return value, true
}

effective_type_max_len :: proc(type_idx: int, field: FieldDef) -> int {
	max_len := types[type_idx].max_len
	if field.max_len >= 0 && (max_len < 0 || field.max_len < max_len) {
		max_len = field.max_len
	}
	return max_len
}

json_error_string :: proc(code: int) -> string {
	switch code {
	case int(jsmn.JsmnError.NoMemory):
		return "json parser: token pool exhausted"
	case int(jsmn.JsmnError.Invalid):
		return "json parser: invalid data"
	case int(jsmn.JsmnError.Partial):
		return "json parser: incomplete data"
	case:
		return "json parser error"
	}
}
