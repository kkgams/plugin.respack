package respack

MAX_CODEGEN_BYTES :: 1024 * 1024
TEMP_STRING_SLOTS :: 256
TEMP_STRING_CAPACITY :: 512

codegen_buffer: [MAX_CODEGEN_BYTES]u8
codegen_len: int
temp_string_slots: [TEMP_STRING_SLOTS][TEMP_STRING_CAPACITY]u8
temp_string_lens: [TEMP_STRING_SLOTS]int
temp_string_index: int
decode_loop_index: int
decode_emit_indent: int

build_odin_decoder :: proc() -> (string, string) {
	codegen_len = 0
	temp_string_index = 0
	decode_loop_index = 0
	decode_emit_indent = 0
	ident_err := validate_odin_identifiers()
	if ident_err != "" {
		return "", ident_err
	}
	temp_string_index = 0
	resolved_package := schema_odin_package()
	resolved_package = sanitize_identifier(resolved_package)
	if resolved_package == "" {
		resolved_package = "respack_generated"
	}
	emit("package ")
	emit(resolved_package)
	emit("\n\n")
	emit_import_declarations()
	emit_private_attribute()
	emit("RSPK_VERSION :: u16(1)\n\n")
	emit_reader_runtime()
	emit_named_type_declarations()
	emit_slot_reader_struct()
	emit_named_decoders()
	emit_slot_readers()
	return string(codegen_buffer[:codegen_len]), ""
}

validate_odin_identifiers :: proc() -> string {
	for i in len(builtin_names) ..< type_count {
		if !types[i].has_name || is_external_odin_type(type_name_string(i)) {
			continue
		}
		left := identifier_ada(type_name_string(i))
		for j in i + 1 ..< type_count {
			if !types[j].has_name || is_external_odin_type(type_name_string(j)) {
				continue
			}
			right := identifier_ada(type_name_string(j))
			if left == right {
				return join3("generated Odin type name collision: ", type_name_string(i), join2(" and ", type_name_string(j)))
			}
		}
	}
	for i in len(builtin_names) ..< type_count {
		if !types[i].has_name {
			continue
		}
		type_def := types[i]
		#partial switch type_def.kind {
		case .Struct:
			for a in 0 ..< type_def.field_count {
				field_a := type_def.field_start + a
				left := identifier_snake(field_name_string(field_a))
				for b in a + 1 ..< type_def.field_count {
					field_b := type_def.field_start + b
					right := identifier_snake(field_name_string(field_b))
					if left == right {
						return join3("generated Odin field name collision in ", type_name_string(i), join3(": ", field_name_string(field_a), join2(" and ", field_name_string(field_b))))
					}
				}
			}
		case .Enum:
			for a in 0 ..< type_def.enum_count {
				enum_a := type_def.enum_start + a
				left := identifier_ada(enum_name_string(enum_a))
				for b in a + 1 ..< type_def.enum_count {
					enum_b := type_def.enum_start + b
					right := identifier_ada(enum_name_string(enum_b))
					if left == right {
						return join3("generated Odin enum value collision in ", type_name_string(i), join3(": ", enum_name_string(enum_a), join2(" and ", enum_name_string(enum_b))))
					}
				}
			}
		case .Oneof:
			for a in 0 ..< type_def.option_count {
				option_a := oneof_options[type_def.option_start + a]
				left_kind := identifier_ada(type_name_string(option_a))
				left_field := identifier_snake(type_name_string(option_a))
				for b in a + 1 ..< type_def.option_count {
					option_b := oneof_options[type_def.option_start + b]
					right_kind := identifier_ada(type_name_string(option_b))
					right_field := identifier_snake(type_name_string(option_b))
					if left_kind == right_kind || left_field == right_field {
						return join3("generated Odin oneof option collision in ", type_name_string(i), join3(": ", type_name_string(option_a), join2(" and ", type_name_string(option_b))))
					}
				}
			}
		case:
		}
	}
	return ""
}

emit_import_declarations :: proc() {
	for i in 0 ..< schema_odin_import_count {
		alias := sanitize_identifier(schema_odin_import_alias(i))
		path := schema_odin_import_path(i)
		if alias == "" || alias == "generated" {
			emit("import \"")
			emit(path)
			emit("\"\n")
			continue
		}
		emit("import ")
		emit(alias)
		emit(" \"")
		emit(path)
		emit("\"\n")
	}
	if schema_odin_import_count > 0 {
		emit("\n")
	}
}

emit_reader_runtime :: proc() {
	emit_private_attribute()
	emit("Reader :: struct {\n\tdata: []u8,\n\tpos:  int,\n}\n\n")
	emit("Package :: struct {\n\tdata:    []u8,\n")
	emit("\toffsets: [")
	emit_int(data_slot_count)
	emit("]u32,\n\tlengths: [")
	emit_int(data_slot_count)
	emit("]u32,\n}\n\n")
	emit("open_respack :: proc(data: []u8) -> (Package, bool) {\n")
	emit("\tif len(data) < 8 {return Package{}, false}\n")
	emit(
		"\tif data[0] != 'R' || data[1] != 'S' || data[2] != 'P' || data[3] != 'K' {return Package{}, false}\n",
	)
	emit("\tif read_u16(data, 4) != RSPK_VERSION {return Package{}, false}\n")
	emit("\tif int(read_u16(data, 6)) != ")
	emit_int(data_slot_count)
	emit(" {return Package{}, false}\n")
	emit("\tif len(data) < ")
	emit_int(8 + data_slot_count * 8)
	emit(" {return Package{}, false}\n")
	emit("\tpkg := Package {\n\t\tdata = data,\n\t}\n")
	emit("\tfor i in 0 ..< ")
	emit_int(data_slot_count)
	emit(" {\n")
	emit("\t\tentry := 8 + i * 8\n")
	emit("\t\tpkg.offsets[i] = read_u32(data, entry)\n")
	emit("\t\tpkg.lengths[i] = read_u32(data, entry + 4)\n")
	emit("\t}\n\treturn pkg, true\n}\n\n")
	emit_private_attribute()
	emit("slot_reader :: proc(pkg: Package, slot: int) -> (Reader, bool) {\n")
	emit("\tif slot < 0 || slot >= ")
	emit_int(data_slot_count)
	emit(" {return Reader{}, false}\n")
	emit("\toffset := int(pkg.offsets[slot])\n\tlength := int(pkg.lengths[slot])\n")
	emit("\tif length == 0 {return Reader{}, false}\n")
	emit("\tif offset < 0 || offset + length > len(pkg.data) {return Reader{}, false}\n")
	emit("\treturn Reader{data = pkg.data[offset:offset + length]}, true\n}\n\n")
	emit_private_attribute()
	emit(
		"read_u8_reader :: proc(r: ^Reader) -> (u8, bool) {\n\tif r.pos + 1 > len(r.data) {return 0, false}\n\tv := r.data[r.pos]\n\tr.pos += 1\n\treturn v, true\n}\n\n",
	)
	emit_private_attribute()
	emit(
		"read_u16_reader :: proc(r: ^Reader) -> (u16, bool) {\n\tif r.pos + 2 > len(r.data) {return 0, false}\n\tv := u16(r.data[r.pos]) | (u16(r.data[r.pos + 1]) << 8)\n\tr.pos += 2\n\treturn v, true\n}\n\n",
	)
	emit_private_attribute()
	emit(
		"read_u32_reader :: proc(r: ^Reader) -> (u32, bool) {\n\tif r.pos + 4 > len(r.data) {return 0, false}\n\tv :=\n\t\tu32(r.data[r.pos]) |\n\t\t(u32(r.data[r.pos + 1]) << 8) |\n\t\t(u32(r.data[r.pos + 2]) << 16) |\n\t\t(u32(r.data[r.pos + 3]) << 24)\n\tr.pos += 4\n\treturn v, true\n}\n\n",
	)
	emit_private_attribute()
	emit(
		"read_u64_reader :: proc(r: ^Reader) -> (u64, bool) {\n\tif r.pos + 8 > len(r.data) {return 0, false}\n\tv := u64(0)\n\tfor i in 0 ..< 8 {v |= u64(r.data[r.pos + i]) << (8 * u64(i))}\n\tr.pos += 8\n\treturn v, true\n}\n\n",
	)
	emit_private_attribute()
	emit(
		"read_u16 :: proc(data: []u8, offset: int) -> u16 {return u16(data[offset]) | (u16(data[offset + 1]) << 8)}\n",
	)
	emit_private_attribute()
	emit(
		"read_u32 :: proc(data: []u8, offset: int) -> u32 {return(\n\t\tu32(data[offset]) |\n\t\t(u32(data[offset + 1]) << 8) |\n\t\t(u32(data[offset + 2]) << 16) |\n\t\t(u32(data[offset + 3]) << 24) \\\n\t)}\n\n",
	)
	emit_private_attribute()
	emit(
		"read_string_reader :: proc(r: ^Reader) -> (string, bool) {\n\tcount, ok := read_u32_reader(r)\n\tif !ok {return \"\", false}\n\tstart := r.pos\n\tend := start + int(count)\n\tif end > len(r.data) {return \"\", false}\n\tr.pos = end\n\treturn string(r.data[start:end]), true\n}\n\n",
	)
}

emit_named_type_declarations :: proc() {
	for i in len(builtin_names) ..< type_count {
		if !types[i].has_name {
			continue
		}
		if is_external_odin_type(type_name_string(i)) {
			continue
		}
		emit_type_declaration(i)
	}
}

emit_type_declaration :: proc(type_idx: int) {
	name := type_name_string(type_idx)
	type_ident := identifier_ada(name)
	type_def := types[type_idx]
	#partial switch type_def.kind {
	case .Alias:
		emit(type_ident)
		emit(" :: ")
		emit(type_expr(type_def.target_type))
		emit("\n\n")
	case .Enum:
		emit(type_ident)
		emit(" :: enum u32 {\n")
		max_name_len := 0
		for i in 0 ..< type_def.enum_count {
			ename := identifier_ada(enum_name_string(type_def.enum_start + i))
			if len(ename) > max_name_len {
				max_name_len = len(ename)
			}
		}
		for i in 0 ..< type_def.enum_count {
			enum_idx := type_def.enum_start + i
			ename := identifier_ada(enum_name_string(enum_idx))
			emit("\t")
			emit(ename)
			emit_spaces(max_name_len - len(ename) + 1)
			emit("= ")
			emit_i64(enum_values[enum_idx].value)
			emit(",\n")
		}
		emit("}\n\n")
	case .Struct:
		emit(type_ident)
		emit(" :: struct {\n")
		max_name_len := 0
		for i in 0 ..< type_def.field_count {
			fname := identifier_snake(field_name_string(type_def.field_start + i))
			if len(fname) > max_name_len {
				max_name_len = len(fname)
			}
		}
		for i in 0 ..< type_def.field_count {
			field_idx := type_def.field_start + i
			fname := identifier_snake(field_name_string(field_idx))
			emit("\t")
			emit(fname)
			emit(":")
			emit_spaces(max_name_len - len(fname) + 1)
			emit(type_expr(fields[field_idx].type_index))
			emit(",\n")
		}
		emit("}\n\n")
	case .Oneof:
		emit(type_ident)
		emit("_Kind :: enum u16 {\n")
		max_option_len := len("None")
		for i in 0 ..< type_def.option_count {
			oname := identifier_ada(type_name_string(oneof_options[type_def.option_start + i]))
			if len(oname) > max_option_len {
				max_option_len = len(oname)
			}
		}
		emit("\tNone")
		emit_spaces(max_option_len - len("None") + 1)
		emit("= 0,\n")
		for i in 0 ..< type_def.option_count {
			option_type := oneof_options[type_def.option_start + i]
			oname := identifier_ada(type_name_string(option_type))
			emit("\t")
			emit(oname)
			emit_spaces(max_option_len - len(oname) + 1)
			emit("= ")
			emit_int(i + 1)
			emit(",\n")
		}
		emit("}\n")
		emit(type_ident)
		emit(" :: struct {\n\tkind:")
		emit_spaces(max_option_len - len("kind") + 1)
		emit(type_ident)
		emit("_Kind,\n")
		for i in 0 ..< type_def.option_count {
			option_type := oneof_options[type_def.option_start + i]
			oname := identifier_snake(type_name_string(option_type))
			emit("\t")
			emit(oname)
			emit(":")
			emit_spaces(max_option_len - len(oname) + 1)
			emit(type_expr(option_type))
			emit(",\n")
		}
		emit("}\n\n")
	case .String, .Bytes, .Array, .Vector:
		emit(type_ident)
		emit(" :: ")
		emit(type_expr_expanded(type_idx))
		emit("\n\n")
	case:
	}
}

emit_slot_reader_struct :: proc() {
	emit_private_attribute()
	emit("DecodedSlots :: struct {\n")
	max_name_len := 0
	for i in 0 ..< data_slot_count {
		has_name := join2("has_slot_", int_string(i))
		slot_name := join2("slot_", int_string(i))
		if len(has_name) > max_name_len {
			max_name_len = len(has_name)
		}
		if len(slot_name) > max_name_len {
			max_name_len = len(slot_name)
		}
	}
	for i in 0 ..< data_slot_count {
		has_name := join2("has_slot_", int_string(i))
		slot_name := join2("slot_", int_string(i))
		emit("\t")
		emit(has_name)
		emit(":")
		emit_spaces(max_name_len - len(has_name) + 1)
		emit("bool,\n\t")
		emit(slot_name)
		emit(":")
		emit_spaces(max_name_len - len(slot_name) + 1)
		emit(type_expr(data_slots[i]))
		emit(",\n")
	}
	emit("}\n\n")
}

emit_named_decoders :: proc() {
	for i in 0 ..< type_count {
		if !types[i].has_name {
			continue
		}
		if types[i].kind == .Invalid {
			continue
		}
		emit_decoder_proc(i)
	}
}

emit_decoder_proc :: proc(type_idx: int) {
	name := type_name_string(type_idx)
	proc_suffix := identifier_snake(name)
	type_ident := identifier_ada(name)
	type_def := types[type_idx]
	emit_private_attribute()
	emit("decode_")
	emit(proc_suffix)
	emit(" :: proc(r: ^Reader, out: ^")
	emit(type_expr(type_idx))
	emit(") -> bool {\n")
	decode_emit_indent = 1
	#partial switch type_def.kind {
	case .Struct:
		for i in 0 ..< type_def.field_count {
			field_idx := type_def.field_start + i
			emit_decode_assign(
				fields[field_idx].type_index,
				join2("out.", identifier_snake(field_name_string(field_idx))),
				field_name_string(field_idx),
			)
		}
	case .Oneof:
		emit("\ttag, ok := read_u16_reader(r)\n\tif !ok {return false}\n")
		emit("\tout.kind = ")
		emit(type_ident)
		emit("_Kind(tag)\n\t#partial switch out.kind {\n")
		for i in 0 ..< type_def.option_count {
			option_type := oneof_options[type_def.option_start + i]
			option_kind_name := identifier_ada(type_name_string(option_type))
			option_field_name := identifier_snake(type_name_string(option_type))
			emit("\tcase .")
			emit(option_kind_name)
			emit(":\n")
			decode_emit_indent = 2
			emit_decode_assign(option_type, join2("out.", option_field_name), option_field_name)
			decode_emit_indent = 1
		}
		emit("\tcase .None:\n\t\treturn false\n\tcase:\n\t\treturn false\n\t}\n")
	case:
		emit_decode_assign(type_idx, "out^", name)
	}
	emit("\treturn true\n}\n\n")
}

emit_slot_readers :: proc() {
	for i in 0 ..< data_slot_count {
		emit("read_slot_")
		emit_int(i)
		emit("_")
		emit(identifier_snake(type_name_string(data_slots[i])))
		emit(" :: proc(pkg: Package) -> (")
		emit(type_expr(data_slots[i]))
		emit(", bool) {\n")
		emit("\tr, ok := slot_reader(pkg, ")
		emit_int(i)
		emit(")\n\tif !ok {return ")
		emit(zero_value_expr(data_slots[i]))
		emit(", false}\n\tvalue: ")
		emit(type_expr(data_slots[i]))
		emit("\n\tif !decode_")
		emit(identifier_snake(type_name_string(data_slots[i])))
		emit("(&r, &value) {return ")
		emit(zero_value_expr(data_slots[i]))
		emit(", false}\n\treturn value, true\n}")
		if i + 1 < data_slot_count {
			emit("\n\n")
		} else {
			emit("\n")
		}
	}
}

emit_decode_assign :: proc(type_idx: int, target: string, _label: string) {
	type_def := types[type_idx]
	emit_decode_tabs()
	emit("{\n")
	decode_emit_indent += 1
	#partial switch type_def.kind {
	case .Alias:
		emit_alias_decode_assign(type_idx, target)
	case .Bool:
		emit_decode_line("b, ok := read_u8_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = b != 0\n")
	case .U8:
		emit_decode_line("v, ok := read_u8_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = v\n")
	case .U16:
		emit_decode_line("v, ok := read_u16_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = v\n")
	case .U32, .Enum:
		emit_decode_line("v, ok := read_u32_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		if type_def.kind == .Enum {
			emit(" = ")
			emit(type_expr(type_idx))
			emit("(v)\n")
		} else {
			emit(" = v\n")
		}
	case .U64:
		emit_decode_line("v, ok := read_u64_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = v\n")
	case .I8:
		emit_decode_line("v, ok := read_u8_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = transmute(i8)v\n")
	case .I16:
		emit_decode_line("v, ok := read_u16_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = transmute(i16)v\n")
	case .I32:
		emit_decode_line("v, ok := read_u32_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = transmute(i32)v\n")
	case .I64:
		emit_decode_line("v, ok := read_u64_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = transmute(i64)v\n")
	case .F32:
		emit_decode_line("v, ok := read_u32_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = transmute(f32)v\n")
	case .F64:
		emit_decode_line("v, ok := read_u64_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = transmute(f64)v\n")
	case .String:
		emit_decode_line("s, ok := read_string_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = s\n")
	case .Bytes:
		emit_decode_line("count, ok := read_u32_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_line("start := r.pos\n")
		emit_decode_line("end := start + int(count)\n")
		emit_decode_line("if end > len(r.data) {return false}\n")
		emit_decode_line("r.pos = end\n")
		emit_decode_tabs()
		emit(target)
		emit(" = r.data[start:end]\n")
	case .Struct, .Oneof:
		emit_decode_tabs()
		emit("if !decode_")
		emit(identifier_snake(type_name_string(type_idx)))
		emit("(r, &")
		emit(target)
		emit(") {return false}\n")
	case .Array:
		loop_var := next_decode_loop_var()
		emit_decode_tabs()
		emit("for ")
		emit(loop_var)
		emit(" in 0 ..< ")
		emit_int(type_def.fixed_len)
		emit(" {\n")
		decode_emit_indent += 1
		emit_decode_assign(type_def.target_type, join3(target, "[", join2(loop_var, "]")), "")
		decode_emit_indent -= 1
		emit_decode_line("}\n")
	case .Vector:
		loop_var := next_decode_loop_var()
		emit_decode_line("count, ok := read_u32_reader(r)\n")
		emit_decode_line("if !ok {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = make(")
		emit(type_expr(type_idx))
		emit(", int(count))\n")
		emit_decode_tabs()
		emit("for ")
		emit(loop_var)
		emit(" in 0 ..< int(count) {\n")
		decode_emit_indent += 1
		emit_decode_assign(type_def.target_type, join3(target, "[", join2(loop_var, "]")), "")
		decode_emit_indent -= 1
		emit_decode_line("}\n")
	case:
		emit_decode_line("return false\n")
	}
	decode_emit_indent -= 1
	emit_decode_line("}\n")
}

emit_alias_decode_assign :: proc(type_idx: int, target: string) {
	target_type := types[type_idx].target_type
	base := type_expr(type_idx)
	#partial switch types[target_type].kind {
	case .Struct, .Oneof:
		emit_decode_line(join2("value: ", type_expr(target_type)))
		emit("\n")
		emit_decode_tabs()
		emit("if !decode_")
		emit(identifier_snake(type_name_string(target_type)))
		emit("(r, &value) {return false}\n")
		emit_decode_tabs()
		emit(target)
		emit(" = ")
		emit(base)
		emit("(value)\n")
	case:
		emit_decode_line(join2("value: ", type_expr(target_type)))
		emit("\n")
		emit_decode_assign(target_type, "value", "")
		emit_decode_tabs()
		emit(target)
		emit(" = ")
		emit(base)
		emit("(value)\n")
	}
}

emit_decode_tabs :: proc() {
	for i in 0 ..< decode_emit_indent {
		emit("\t")
	}
}

emit_decode_line :: proc(text: string) {
	emit_decode_tabs()
	emit(text)
}

type_expr :: proc(type_idx: int) -> string {
	type_def := types[type_idx]
	if type_idx < len(builtin_names) &&
	   builtin_names[type_idx] != "" &&
	   types[type_idx].name_start == -1 {
		return builtin_type_expr(type_def.kind)
	}
	if type_def.has_name {
		if is_external_odin_type(type_name_string(type_idx)) {
			return type_name_string(type_idx)
		}
		return identifier_ada(type_name_string(type_idx))
	}
	return type_expr_expanded(type_idx)
}

type_expr_expanded :: proc(type_idx: int) -> string {
	type_def := types[type_idx]
	if type_idx < len(builtin_names) &&
	   builtin_names[type_idx] != "" &&
	   types[type_idx].name_start == -1 {
		return builtin_type_expr(type_def.kind)
	}
	#partial switch type_def.kind {
	case .Array:
		return join3(
			"[",
			int_string(type_def.fixed_len),
			join2("]", type_expr(type_def.target_type)),
		)
	case .Vector:
		return join2("[]", type_expr(type_def.target_type))
	case .String:
		return "string"
	case .Bytes:
		return "[]u8"
	case:
		if is_external_odin_type(type_name_string(type_idx)) {
			return type_name_string(type_idx)
		}
		return identifier_ada(type_name_string(type_idx))
	}
}

builtin_type_expr :: proc(kind: TypeKind) -> string {
	#partial switch kind {
	case .Bool:
		return "bool"
	case .U8:
		return "u8"
	case .U16:
		return "u16"
	case .U32:
		return "u32"
	case .U64:
		return "u64"
	case .I8:
		return "i8"
	case .I16:
		return "i16"
	case .I32:
		return "i32"
	case .I64:
		return "i64"
	case .F32:
		return "f32"
	case .F64:
		return "f64"
	case .String:
		return "string"
	case .Bytes:
		return "[]u8"
	case:
		return "invalid_type"
	}
}

zero_value_expr :: proc(type_idx: int) -> string {
	type_def := types[type_idx]
	#partial switch type_def.kind {
	case .String:
		return "\"\""
	case .Vector, .Bytes:
		return "nil"
	case .Bool:
		return "false"
	case:
		return join2(type_expr(type_idx), "{}")
	}
}

identifier_snake :: proc(text: string) -> string {
	return sanitize_identifier(text)
}

identifier_ada :: proc(text: string) -> string {
	snake := sanitize_identifier(text)
	if len(snake) == 0 {
		return "Generated"
	}
	slot := next_temp_string_slot()
	count := 0
	capitalize_next := true
	for i in 0 ..< len(snake) {
		c := snake[i]
		if c == '_' {
			if count < TEMP_STRING_CAPACITY {
				temp_string_slots[slot][count] = c
				count += 1
			}
			capitalize_next = true
			continue
		}
		if capitalize_next && c >= 'a' && c <= 'z' {
			c -= 32
		}
		if count < TEMP_STRING_CAPACITY {
			temp_string_slots[slot][count] = c
			count += 1
		}
		capitalize_next = false
	}
	temp_string_lens[slot] = count
	result := string(temp_string_slots[slot][:count])
	if len(result) == 0 {
		return "Generated"
	}
	return result
}

sanitize_identifier :: proc(text: string) -> string {
	if len(text) == 0 {
		return "generated"
	}
	slot := next_temp_string_slot()
	count := 0
	last_underscore := false
	for i in 0 ..< len(text) {
		c := text[i]
		if c >= 'A' && c <= 'Z' {
			if i > 0 &&
			   !last_underscore &&
			   ((text[i - 1] >= 'a' && text[i - 1] <= 'z') ||
					   (i + 1 < len(text) && text[i + 1] >= 'a' && text[i + 1] <= 'z')) {
				if count < TEMP_STRING_CAPACITY {
					temp_string_slots[slot][count] = '_'
					count += 1
				}
			}
			if count < TEMP_STRING_CAPACITY {
				temp_string_slots[slot][count] = c + 32
				count += 1
			}
			last_underscore = false
			continue
		}
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			if count < TEMP_STRING_CAPACITY {
				temp_string_slots[slot][count] = c
				count += 1
			}
			last_underscore = false
			continue
		}
		if !last_underscore {
			if count < TEMP_STRING_CAPACITY {
				temp_string_slots[slot][count] = '_'
				count += 1
			}
			last_underscore = true
		}
	}
	temp_string_lens[slot] = count
	result := string(temp_string_slots[slot][:count])
	if len(result) == 0 {
		return "generated"
	}
	if result[0] >= '0' && result[0] <= '9' {
		return join2("_", result)
	}
	return result
}

is_external_odin_type :: proc(text: string) -> bool {
	for i in 0 ..< len(text) {
		if text[i] == '.' {
			return true
		}
	}
	return false
}

emit :: proc(text: string) {
	if codegen_len + len(text) > len(codegen_buffer) {
		return
	}
	copy(codegen_buffer[codegen_len:codegen_len + len(text)], text)
	codegen_len += len(text)
}

emit_int :: proc(value: int) {
	emit(int_string(value))
}

emit_spaces :: proc(count: int) {
	for i in 0 ..< count {
		emit(" ")
	}
}

emit_private_attribute :: proc() {
	emit("@(private = \"file\")\n")
}

emit_i64 :: proc(value: i64) {
	emit(i64_string(value))
}

int_string :: proc(value: int) -> string {
	return i64_string(i64(value))
}

i64_string :: proc(value: i64) -> string {
	slot := next_temp_string_slot()
	idx := TEMP_STRING_CAPACITY
	neg := value < 0
	if value == 0 {
		return "0"
	}
	v := value
	if neg {
		v = -v
	}
	for v > 0 {
		idx -= 1
		temp_string_slots[slot][idx] = u8('0') + u8(v % 10)
		v /= 10
	}
	if neg {
		idx -= 1
		temp_string_slots[slot][idx] = '-'
	}
	temp_string_lens[slot] = TEMP_STRING_CAPACITY - idx
	return string(temp_string_slots[slot][idx:TEMP_STRING_CAPACITY])
}

next_decode_loop_var :: proc() -> string {
	value := join2("decode_index_", int_string(decode_loop_index))
	decode_loop_index += 1
	return value
}

next_temp_string_slot :: proc() -> int {
	idx := temp_string_index % TEMP_STRING_SLOTS
	temp_string_index += 1
	temp_string_lens[idx] = 0
	return idx
}

join2 :: proc(a, b: string) -> string {
	slot := next_temp_string_slot()
	count := 0
	for i in 0 ..< len(a) {
		if count >= TEMP_STRING_CAPACITY {break}
		temp_string_slots[slot][count] = a[i]
		count += 1
	}
	for i in 0 ..< len(b) {
		if count >= TEMP_STRING_CAPACITY {break}
		temp_string_slots[slot][count] = b[i]
		count += 1
	}
	temp_string_lens[slot] = count
	return string(temp_string_slots[slot][:count])
}

join3 :: proc(a, b, c: string) -> string {
	return join2(join2(a, b), c)
}
