package parser

import "core:fmt"
import "core:os"
import "core:bufio"
import "core:strings"
import "core:unicode"

ProductionSet :: map[string]string
GrammarSets :: map[string]ProductionSet

FollowSet :: struct {
	entries: map[string]string
}

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
	name: string,
	matchers: [dynamic]^Matcher,
}

Grammar :: struct {
	productions: [dynamic]^Production,
	index: map[string]^Production,
	first_sets: GrammarSets,
	follow_sets: map[string]^FollowSet
}

Matcher :: struct {
	tokens: [dynamic]^Token,
}

new_follow_set :: proc() -> ^FollowSet {
	out := new(FollowSet)
	out.entries = make(map[string]string)
	return out
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

new_empty_matcher :: proc() -> ^Matcher {
	out := new_matcher()
	matcher_append(out, new_token("empty", .Empty))
	return out
}

new_production :: proc(name: string) -> ^Production {
	out := new(Production)
	out.name = name
	out.matchers = make([dynamic]^Matcher)
	return out
}

new_grammar :: proc() -> ^Grammar {
	out := new(Grammar)
	out.productions = make([dynamic]^Production)
	out.index = make(map[string]^Production)
	return out
}

matcher_append :: proc(matcher: ^Matcher, token: ^Token) {
	append(&matcher.tokens, token)
}

production_append :: proc(production: ^Production, matcher: ^Matcher) {
	append(&production.matchers, matcher)
}

grammar_insert :: proc(grammar: ^Grammar, production: ^Production) {
	append(&grammar.productions, production)
	grammar.index[production.name] = production
}

production_elr :: proc(grammar: ^Grammar, production: ^Production) {
	betas := make([dynamic]^Matcher)
	alphas := make([dynamic]^Matcher)
	for matcher in production.matchers {
		if matcher.tokens[0].value == production.name {
			append(&alphas, matcher)
		} else {
			append(&betas, matcher)
		}
	}

	if len(alphas) == 0 {
		grammar_insert(grammar, production)
		return
	}
	for matcher in betas {
		append(&matcher.tokens, new_token(fmt.tprintf("%s_p", production.name), .Production))
	}

	for matcher in alphas {
		unordered_remove(&matcher.tokens, 0)
		append(&matcher.tokens, new_token(fmt.tprintf("%s_p", production.name), .Production))
	}

	original := new_production(strings.clone(production.name))
	original.matchers = betas

	prime := new_production(fmt.tprintf("%s_p", production.name))
	prime.matchers = alphas
	production_append(prime, new_empty_matcher())

	grammar_insert(grammar, prime)
	grammar_insert(grammar, original)
}

first_set :: proc(grammar: ^Grammar, token: ^Token) -> ProductionSet {
	out := make(map[string]string)
	if token.type == .Terminal || token.type == .Operator || token.type == .Empty {
		out[token.value] = token.value
	} else if token.type == .Production {
		production := grammar.index[token.value]
		for matcher in production.matchers {
			count := 0
			for token in matcher.tokens {
				first := first_set(grammar, token)
				for k,v in first {
					out[k] = v
				}
				if !("empty" in first) {
					break
				} else {
					count += 1
					delete_key(&first, "empty")
				}
			}
			if count == len(matcher.tokens) {
				out["empty"] = "empty"
			}
		}
	}
	return out
}

get_follow_sets :: proc(grammar: ^Grammar) -> map[string]^FollowSet {
	out := make(map[string]^FollowSet)
	out[grammar.productions[0].name] = new_follow_set()
	out[grammar.productions[0].name].entries["$"] = "$"

	for i := 1; i < len(grammar.productions); i += 1 {
		out[grammar.productions[i].name] = new_follow_set()
	}
	for production in grammar.productions {
		for matcher in production.matchers {
			for i := len(matcher.tokens) - 1; i >= 0; i -= 1 {
				for j := i - 1; j >= 0; j -= 1 {
					curr_token := matcher.tokens[i]
					prev_token := matcher.tokens[j]
					fmt.printfln("Prev token: %s  Cur token: %s", prev_token.value, curr_token.value)
					if prev_token.type != .Production {
						break;
					}
					follow_set_prev := out[prev_token.value]
					first_set_cur: map[string]string
					if curr_token.type == .Production {
						first_set_cur = grammar.first_sets[curr_token.value]
					} else {
						first_set_cur = first_set(grammar, curr_token)
					}
					first_set_prev := grammar.first_sets[prev_token.value]
					for k, v in first_set_cur {
						if k != "empty" {
							follow_set_prev.entries[strings.clone(k)] = strings.clone(v)
						}
					}
					if !("empty" in first_set_prev) {
						break;
					}
				}
			}
		}
	}
	has_change := false
	for {
		for production in grammar.productions {
			for matcher in production.matchers {
				for i := len(matcher.tokens) - 1; i >= 0; i -= 1 {
					token := matcher.tokens[i]
					if token.type != .Production {
						break;
					}
					first := grammar.first_sets[token.value]
					follow := out[token.value]
					for k, v in out[production.name].entries {
						if k != "empty" {
							if !(k in follow.entries) {
								follow.entries[strings.clone(k)] = strings.clone(v)
								has_change = true
							}
						}
					}
					if !("empty" in first) {
						break;
					}
				}
			}
		}
		if !has_change {
			break;
		}
		has_change = false
	}

	return out
}

get_first_sets :: proc(grammar: ^Grammar) -> GrammarSets {
	out := make(map[string]map[string]string)
	for prod in grammar.productions {
		out[prod.name] = first_set(grammar, new_token(prod.name, .Production))
	}
	return out
}

grammar_elr :: proc(grammar: ^Grammar) -> ^Grammar {
	out := new_grammar()
	for prod in grammar.productions {
		production_elr(out, prod)
	}
	out.first_sets = get_first_sets(out)
	out.follow_sets = get_follow_sets(out)
	return out
}

matcher_from_string :: proc(input: string) -> ^Matcher{
	tokens, err := strings.split(input, " ")
	if err != nil {
		// handle error
		fmt.printfln("Could not split matcher %s into tokens", input)
		os.exit(1)
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
	fmt.printf("%s ::= ", production.name)
	print_matcher(production.matchers[0])
	for i := 1; i < len(production.matchers); i += 1 {
		fmt.printf("\n\t| ")
		print_matcher(production.matchers[i])
	}
	fmt.printf("\n")
}

print_grammar :: proc(grammar: ^Grammar) {
	fmt.println("+++PRODUCTIONS+++")
	for prod in grammar.productions {
		print_production(prod)
	}
	fmt.println("+++FIRST SETS+++")
	for k, v in grammar.first_sets {
		fmt.printf("%s -> ", k)
		for key, value in v {
			fmt.printf("%s, ", key)
		}
		fmt.printf("\n")
	}
	fmt.println("+++FOLLOW SETS+++")
	for k, v in grammar.follow_sets {
		fmt.printf("%s -> ", k)
		for key, value in v.entries {
			fmt.printf("%s, ", key)
		}
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
	prod_current := new_production("")

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
				if prod_current.name == "" {
					fmt.println("Grammar needs to start with a production")
					os.exit(1)
				}
				match_strings, err := strings.split(local, "|")
				if err != nil {
					fmt.printfln("Could not split individual productions for %s", local)
					os.exit(1)
				}
				for i := 1; i < len(match_strings); i += 1 {
					matcher := matcher_from_string(strings.trim_space(match_strings[i]))
					production_append(prod_current, matcher)
				}
			} else {
				tokens, ps_err := strings.split(local, "::=")
				if ps_err != nil {
					fmt.printfln("Could not split production %s", local)
					os.exit(1)
				}
				if len(tokens) != 2 {
					fmt.println("Production should have format name ::= matcher1 | matcher 2, etc.")
					os.exit(1)
				}
				// push the previous production if any
				if prod_current.name != "" {
					grammar_insert(grammar, prod_current)
				}
				// and start a new one
				prod_current = new_production(strings.clone(strings.trim_space(tokens[0])))

				all_matchers_string := strings.trim_space(tokens[1])
				match_strings, ms_err := strings.split(tokens[1], "|")
				if ms_err != nil {
					fmt.printfln("Could not split %s into individual matchers", local)
					os.exit(1)
				}
				for match_string in match_strings {
					matcher := matcher_from_string(strings.trim_space(match_string))
					production_append(prod_current, matcher)
				}
			}
		}
	}
	grammar_insert(grammar, prod_current)
	elr_grammar := grammar_elr(grammar)
	print_grammar(elr_grammar)


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
