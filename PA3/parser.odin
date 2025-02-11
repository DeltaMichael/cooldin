package parser

import "core:fmt"
import "core:os"
import "core:bufio"
import "core:strings"
import "core:unicode"

TokenType :: enum {
	Production,
	Terminal,
	Operator,
	Empty
}

Token :: struct {
	value: string,
	type: TokenType
}

Production :: struct {
	matchers: [dynamic]^Matcher,
}

Grammar :: struct {
	productions: map[string]^Production
}

Matcher :: struct {
	tokens: [dynamic]^Token,
}

new_token :: proc(value: string, type: TokenType) -> ^Token {
	out := new(Token)
	out.value = value
	out.type = type
	return out
}

new_matcher :: proc() -> ^Matcher {
	out := new(Matcher)
	out.tokens = make([dynamic]^Token)
	return out
}

new_production :: proc() -> ^Production {
	out := new(Production)
	out.matchers = make([dynamic]^Matcher)
	return out
}

new_grammar :: proc() -> ^Grammar {
	out := new(Grammar)
	out.productions = make(map[string]^Production)
	return out
}

matcher_append :: proc(matcher: ^Matcher, token: ^Token) {
	append(&matcher.tokens, token)
}

production_append :: proc(production: ^Production, matcher: ^Matcher) {
	append(&production.matchers, matcher)
}

grammar_insert :: proc(grammar: ^Grammar, name: string, production: ^Production) {
	grammar.productions[name] = production
}

matcher_from_string :: proc(input: string) -> ^Matcher{
	tokens, err := strings.split(input, " ")
	if err != nil {
		// handle error
	}
	matcher := new_matcher()
	for token in tokens {
		local := strings.trim_space(token)
		switch {
		case local == "empty" :
			matcher_append(matcher, new_token(strings.clone(local), .Empty))
		case unicode.is_upper(rune(local[0])):
			matcher_append(matcher, new_token(strings.clone(local), .Terminal))
		case unicode.is_lower(rune(local[0])):
			matcher_append(matcher, new_token(strings.clone(local), .Production))
		case:
			matcher_append(matcher, new_token(strings.clone(local), .Operator))
		}
	}
	return matcher
}

print_matcher :: proc(matcher: ^Matcher) {
	for token in matcher.tokens {
		fmt.printf("%s ", token.value)
	}
}

print_production :: proc(production: ^Production) {
	print_matcher(production.matchers[0])
	for i := 1; i < len(production.matchers); i += 1 {
		fmt.printf("\n\t| ")
		print_matcher(production.matchers[i])
	}
}

print_grammar :: proc(grammar: ^Grammar) {
	for key, value in grammar.productions {
		fmt.printf("%s ::= ", key)
		print_production(value)
		fmt.printf("\n")
	}
}


main :: proc() {
	grammar_handle, err := os.open(os.args[1], os.O_RDONLY, 0)
	if err != 0 {
		fmt.printfln("Error opening file %s", os.args[1])
	}
	defer os.close(grammar_handle)

	grammar_reader: bufio.Reader
	bufio.reader_init(&grammar_reader, os.stream_from_handle(grammar_handle))
    defer bufio.reader_destroy(&grammar_reader)

	grammar := new_grammar()
	prod_current := new_production()
	prod_current_name := ""

	for {
		line, err := bufio.reader_read_string(&grammar_reader, '\n', context.allocator)
		if err != nil {
			break;
		}
		defer delete(line, context.allocator)
		line = strings.trim_right(line, "\r")
		if line[0] != '#' {
			local := strings.trim_space(line)
			if len(local) == 0 {
				continue;
			}
			if local[0] == '|' {
				if prod_current_name == "" {
					// handle error
				}
				match_strings, err := strings.split(local, "|")
				if err != nil {
					// handle error
				}
				for i := 1; i < len(match_strings); i += 1 {
					matcher := matcher_from_string(strings.trim_space(match_strings[i]))
					production_append(prod_current, matcher)
				}
			} else {
				tokens, ps_err := strings.split(local, "::=")
				if ps_err != nil {
					// handle error
				}
				if len(tokens) != 2 {
					// handle error
				}
				// push the previous production if any
				if prod_current_name != "" {
					grammar_insert(grammar, strings.clone(prod_current_name), prod_current)
				}
				// and start a new one
				prod_current = new_production()
				prod_current_name = strings.clone(strings.trim_space(tokens[0]))

				all_matchers_string := strings.trim_space(tokens[1])
				match_strings, ms_err := strings.split(tokens[1], "|")
				if ms_err != nil {
					// handle error
				}
				for match_string in match_strings {
					matcher := matcher_from_string(strings.trim_space(match_string))
					production_append(prod_current, matcher)
				}
			}
		}
	}
	grammar_insert(grammar, strings.clone(prod_current_name), prod_current)
	print_grammar(grammar)


	// reader: bufio.Reader
	// bufio.reader_init(&reader, os.stream_from_handle(os.stdin))
	// defer bufio.reader_destroy(&reader)
	// for {
	// 	line, err := bufio.reader_read_string(&reader, '\n', context.allocator)
	// 	if err != nil {
	// 		break
	// 	}
	// 	defer delete(line, context.allocator)
	// 	line = strings.trim_right(line, "\r")
	// 	fmt.print(line)
	// }
}
