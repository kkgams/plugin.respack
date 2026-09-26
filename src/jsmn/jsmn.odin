package jsmn

JsmnType :: enum int {
	Undefined = 0,
	Object,
	Array,
	String,
	Primitive,
}

JsmnError :: enum int {
	None     = 0,
	NoMemory = -1,
	Invalid  = -2,
	Partial  = -3,
}

Token :: struct {
	type:   JsmnType,
	start:  int,
	end:    int,
	size:   int,
	parent: int,
}

Parser :: struct {
	pos:      int,
	toknext:  int,
	toksuper: int,
}

init :: proc(parser: ^Parser) {
	parser.pos = 0
	parser.toknext = 0
	parser.toksuper = -1
}

parse :: proc(parser: ^Parser, json: []u8, tokens: []Token) -> int {
	count := parser.toknext
	total := len(json)
	for parser.pos < total && json[parser.pos] != 0 {
		c := json[parser.pos]
		switch c {
		case '{', '[':
			count += 1
			if len(tokens) != 0 {
				token := alloc_token(parser, tokens)
				if token == nil {
					return int(JsmnError.NoMemory)
				}
				token.type = JsmnType.Object
				if c == '[' {
					token.type = JsmnType.Array
				}
				token.start = parser.pos
				token.end = -1
				token.size = 0
				token.parent = parser.toksuper
			}
			parser.toksuper = parser.toknext - 1
		case '}', ']':
			if len(tokens) == 0 {
				parser.pos += 1
				continue
			}
			target := JsmnType.Object
			if c == ']' {
				target = JsmnType.Array
			}
			i := parser.toknext - 1
			for i >= 0 {
				token := &tokens[i]
				if token.start != -1 && token.end == -1 {
					if token.type != target {
						return int(JsmnError.Invalid)
					}
					token.end = parser.pos + 1
					parser.toksuper = token.parent
					break
				}
				i -= 1
			}
			if i < 0 {
				return int(JsmnError.Invalid)
			}
		case '"':
			r := parse_string(parser, json, tokens)
			if r < 0 {
				return r
			}
			count += 1
			if parser.toksuper != -1 && len(tokens) != 0 {
				tokens[parser.toksuper].size += 1
			}
		case '\t', '\r', '\n', ' ':
		// skip
		case ':':
			parser.toksuper = parser.toknext - 1
		case ',':
			if parser.toksuper != -1 && len(tokens) != 0 {
				parent := parser.toksuper
				if tokens[parent].type != JsmnType.Array &&
				   tokens[parent].type != JsmnType.Object {
					parser.toksuper = tokens[parent].parent
				}
			}
		case:
			r := parse_primitive(parser, json, tokens)
			if r < 0 {
				return r
			}
			count += 1
			if parser.toksuper != -1 && len(tokens) != 0 {
				tokens[parser.toksuper].size += 1
			}
		}
		parser.pos += 1
	}
	return count
}

alloc_token :: proc(parser: ^Parser, tokens: []Token) -> ^Token {
	if len(tokens) == 0 {
		return nil
	}
	if parser.toknext >= len(tokens) {
		return nil
	}
	token := &tokens[parser.toknext]
	parser.toknext += 1
	token.start = -1
	token.end = -1
	token.size = 0
	token.parent = -1
	token.type = JsmnType.Undefined
	return token
}

parse_string :: proc(parser: ^Parser, json: []u8, tokens: []Token) -> int {
	start := parser.pos
	parser.pos += 1
	total := len(json)
	for parser.pos < total && json[parser.pos] != 0 {
		c := json[parser.pos]
		if c == '"' {
			if len(tokens) != 0 {
				token := alloc_token(parser, tokens)
				if token == nil {
					parser.pos = start
					return int(JsmnError.NoMemory)
				}
				token.type = JsmnType.String
				token.start = start + 1
				token.end = parser.pos
				token.parent = parser.toksuper
			}
			return 0
		}
		if c == '\\' && parser.pos + 1 < total {
			parser.pos += 1
			next := json[parser.pos]
			switch next {
			case '"', '/', '\\', 'b', 'f', 'r', 'n', 't':
			// valid escape
			case 'u':
				for i in 0 ..< 4 {
					parser.pos += 1
					if parser.pos >= total {
						parser.pos = start
						return int(JsmnError.Invalid)
					}
					ch := json[parser.pos]
					if !(ch >= '0' && ch <= '9') &&
					   !(ch >= 'A' && ch <= 'F') &&
					   !(ch >= 'a' && ch <= 'f') {
						parser.pos = start
						return int(JsmnError.Invalid)
					}
				}
			case:
				parser.pos = start
				return int(JsmnError.Invalid)
			}
		} else if c < 32 {
			parser.pos = start
			return int(JsmnError.Invalid)
		}
		parser.pos += 1
	}
	parser.pos = start
	return int(JsmnError.Partial)
}

parse_primitive :: proc(parser: ^Parser, json: []u8, tokens: []Token) -> int {
	start := parser.pos
	total := len(json)
	found := false
	for parser.pos < total && json[parser.pos] != 0 {
		c := json[parser.pos]
		switch c {
		case '\t', '\r', '\n', ' ', ',', ']', '}', ':':
			found = true
			break
		case:
			if c < 32 || c >= 127 {
				parser.pos = start
				return int(JsmnError.Invalid)
			}
		}
		parser.pos += 1
	}
	if !found {
		parser.pos = start
		return int(JsmnError.Partial)
	}
	if len(tokens) == 0 {
		parser.pos -= 1
		return 0
	}
	token := alloc_token(parser, tokens)
	if token == nil {
		parser.pos = start
		return int(JsmnError.NoMemory)
	}
	token.type = JsmnType.Primitive
	token.start = start
	token.end = parser.pos
	token.size = 0
	token.parent = parser.toksuper
	parser.pos -= 1
	return 0
}
