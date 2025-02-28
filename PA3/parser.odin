#+feature dynamic-literals

package parser

import "core:fmt"
import "core:os"
import "core:bufio"
import "core:strings"
import "core:unicode"
import "core:testing"

/* ALIASES */
ProductionSet :: map[string]string
GrammarSets :: map[string]ProductionSet

/* GRAMMAR TYPE DEFINITIONS AND FUNCTIONS */
Grammar :: struct {
	productions: [dynamic]^Production,
	index: map[string]^Production,
	terminals: [dynamic]string,
	first_sets: GrammarSets,
	follow_sets: map[string]^FollowSet,
	parsing_table: ^Table
}

grammar_new :: proc() -> ^Grammar {
	out := new(Grammar)
	out.productions = make([dynamic]^Production)
	out.index = make(map[string]^Production)
	out.terminals = make([dynamic]string)
	return out
}

grammar_new_from_file :: proc(path: string) -> ^Grammar {
	grammar_handle, err := os.open(path, os.O_RDONLY, 0)
	if err != 0 {
		fmt.printfln("Error opening file %s", path)
	}
	defer os.close(grammar_handle)

	grammar_reader: bufio.Reader
	bufio.reader_init(&grammar_reader, os.stream_from_handle(grammar_handle))
    defer bufio.reader_destroy(&grammar_reader)

	grammar := grammar_new()
	prod_current := production_new("")

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
					matcher := matcher_new_from_string(strings.trim_space(match_strings[i]))
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
				prod_current = production_new(strings.clone(strings.trim_space(tokens[0])))

				all_matchers_string := strings.trim_space(tokens[1])
				match_strings, ms_err := strings.split(tokens[1], "|")
				if ms_err != nil {
					fmt.printfln("Could not split %s into individual matchers", local)
					os.exit(1)
				}
				for match_string in match_strings {
					matcher := matcher_new_from_string(strings.trim_space(match_string))
					production_append(prod_current, matcher)
				}
			}
		}
	}
	grammar_insert(grammar, prod_current)
	return grammar
}

grammar_insert :: proc(grammar: ^Grammar, production: ^Production) {
	append(&grammar.productions, production)
	grammar.index[production.name] = production
}

grammar_terminals_init :: proc(grammar: ^Grammar) {
	out := make([dynamic]string)
	for production in grammar.productions {
		for matcher in production.matchers {
			for token in matcher.tokens {
				if token.type == .Terminal || token.type == .Operator {
					append(&out, token.value)
				}
			}
		}
	}
	grammar.terminals = out
}

// terminals should be initialized before calling this
grammar_parsing_table_init :: proc(grammar: ^Grammar) {
	out := new(Table)
	out.rows = make(map[string]^TableRow)
	for production in grammar.productions {
		row := table_row_new()
		for terminal in grammar.terminals {
			row.entries[strings.clone(terminal)] = nil
		}
		out.rows[production.name] = row
	}
	grammar.parsing_table = out
}

grammar_parsing_table_build :: proc(grammar: ^Grammar) {
	for production in grammar.productions {
		first_set := grammar.first_sets[production.name]
		for k, _ in first_set {
			if k != "empty" {
				for matcher in production.matchers {
					token := matcher.tokens[0]
					if token.type == .Production {
						token_first_set := grammar.first_sets[token.value]
						if k in token_first_set {
							// out_str := fmt.tprintf("%s -> %s", production.name, matcher_to_string(matcher))
							table_insert(grammar.parsing_table, strings.clone(production.name), strings.clone(k), matcher)
							break
						}
					} else {
						if k == token.value {
							// out_str := fmt.tprintf("%s -> %s", production.name, matcher_to_string(matcher))
							table_insert(grammar.parsing_table, strings.clone(production.name), strings.clone(k), matcher)
							break
						}
					}
				}
			} else {
				follow_set := grammar.follow_sets[production.name]
				for k, _ in follow_set.entries {
					table_insert(grammar.parsing_table, strings.clone(production.name), strings.clone(k), matcher_new_empty())
				}
			}
		}
	}
}

// Eliminates direct left recursion
// TODO: Handle indirect left recursion
grammar_elr :: proc(grammar: ^Grammar) -> ^Grammar {
	out := grammar_new()
	for prod in grammar.productions {
		production_elr(out, prod)
	}
	out.first_sets = grammar_first_sets_get(out)
	out.follow_sets = grammar_follow_sets_get(out)
	return out
}

grammar_first_sets_get :: proc(grammar: ^Grammar) -> GrammarSets {
	out := make(map[string]map[string]string)
	for prod in grammar.productions {
		out[prod.name] = token_first_set(grammar, token_new(prod.name, .Production))
	}
	return out
}

// If we have a production of the type S -> AB
// FOLLOW(A) += FIRST(B)
// FOLLOW(B) += FOLLOW(S)
grammar_follow_sets_get :: proc(grammar: ^Grammar) -> map[string]^FollowSet {
	out := make(map[string]^FollowSet)
	out[grammar.productions[0].name] = follow_set_new()
	out[grammar.productions[0].name].entries["$"] = "$"

	for i := 1; i < len(grammar.productions); i += 1 {
		out[grammar.productions[i].name] = follow_set_new()
	}

	// FOLLOW(A) += FIRST(B)
	for production in grammar.productions {
		for matcher in production.matchers {
			// Iterate the tokens in reverse and form pairs,
			// e.g. If we have a production s -> a b c d
			// we'll look at dc, db, da, then cb, ca, finall ba
			// note that these are all possible pairs, but every previous token's
			// first set should contain epsillon to be able to get past it, e.g.
			// to match something like a b d, c's first set should contain epsillon
			// otherwise, we should break the inner loop
			for i := len(matcher.tokens) - 1; i >= 0; i -= 1 {
				for j := i - 1; j >= 0; j -= 1 {
					curr_token := matcher.tokens[i]
					prev_token := matcher.tokens[j]
					// if we hit a terminal, we're done
					// we can't add to a terminal's follow set
					if prev_token.type != .Production {
						break;
					}
					follow_set_prev := out[prev_token.value]
					first_set_cur: map[string]string
					if curr_token.type == .Production {
						first_set_cur = grammar.first_sets[curr_token.value]
					} else {
						first_set_cur = token_first_set(grammar, curr_token)
					}
					first_set_prev := grammar.first_sets[prev_token.value]
					// Copy all the non-epsillon symbols in the follow set
					// of the previous token
					for k, v in first_set_cur {
						if k != "empty" {
							follow_set_prev.entries[strings.clone(k)] = strings.clone(v)
						}
					}
					// If the previous token can't be epsillon
					// break the loop and move on to the next pair
					if !("empty" in first_set_prev) {
						break;
					}
				}
			}
		}
	}

	// FOLLOW(B) += FOLLOW(S)
	has_change := false
	// For each production, add the follow set of each production
	// to the follow set of each of the production's non-terminal tokens
	// Do this until the follow sets don't change anymore
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
						// we can't have epsillon in follow sets
						if k != "empty" {
							if !(k in follow.entries) {
								follow.entries[strings.clone(k)] = strings.clone(v)
								has_change = true
							}
						}
					}

					// if the current token can't be empty
					// we're done with this matcher
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

grammar_print :: proc(grammar: ^Grammar) {
	fmt.println("+++PRODUCTIONS+++")
	for prod in grammar.productions {
		production_print(prod)
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
	fmt.println("+++PARSING TABLE+++")
	for production in grammar.productions {
		fmt.printf("%s ", production.name)
		for terminal in grammar.terminals {
			val := table_get(grammar.parsing_table, production.name, terminal)
			if val != nil {
				fmt.printf("[%s:%s], ", terminal, matcher_to_string(val))
			}
		}
		fmt.printf("\n")
	}
}

grammar_to_string :: proc(grammar: ^Grammar) -> string {
	builder := strings.builder_make()
	for prod in grammar.productions {
		strings.write_string(&builder, production_to_string(prod))
	}
	return strings.to_string(builder)
}

/* TABLE TYPE DEFINITIONS AND FUNCTIONS */

Table :: struct {
	rows: map[string]^TableRow
}

TableRow :: struct {
	entries: map[string]^Matcher
}

table_exists :: proc(table: ^Table, row: string, col: string) -> bool {
	return row in table.rows && table.rows[row].entries[col] != nil
}

table_get :: proc(table: ^Table, row: string, col: string) -> ^Matcher {
	return table.rows[row].entries[col]
}

table_insert :: proc(table: ^Table, row: string, col: string, value: ^Matcher) {
	table.rows[row].entries[col] = value
}

table_row_new :: proc() -> ^TableRow {
	out := new(TableRow)
	out.entries = make(map[string]^Matcher)
	return out
}

/* FOLLOW SET TYPE DEFINITIONS AND FUNCTIONS */

FollowSet :: struct {
	entries: map[string]string
}

follow_set_new :: proc() -> ^FollowSet {
	out := new(FollowSet)
	out.entries = make(map[string]string)
	return out
}

/* PRODUCTION TYPE DEFINITIONS AND FUNCTIONS */

Production :: struct {
	name: string,
	matchers: [dynamic]^Matcher,
}

production_new :: proc(name: string) -> ^Production {
	out := new(Production)
	out.name = name
	out.matchers = make([dynamic]^Matcher)
	return out
}

production_append :: proc(production: ^Production, matcher: ^Matcher) {
	append(&production.matchers, matcher)
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
		append(&matcher.tokens, token_new(fmt.tprintf("%s_p", production.name), .Production))
	}

	for matcher in alphas {
		ordered_remove(&matcher.tokens, 0)
		append(&matcher.tokens, token_new(fmt.tprintf("%s_p", production.name), .Production))
	}

	original := production_new(strings.clone(production.name))
	original.matchers = betas

	prime := production_new(fmt.tprintf("%s_p", production.name))
	prime.matchers = alphas
	production_append(prime, matcher_new_empty())

	grammar_insert(grammar, prime)
	grammar_insert(grammar, original)
}

production_print :: proc(production: ^Production) {
	fmt.printf("%s ::= ", production.name)
	matcher_print(production.matchers[0])
	for i := 1; i < len(production.matchers); i += 1 {
		fmt.printf("\n\t| ")
		matcher_print(production.matchers[i])
	}
	fmt.printf("\n")
}

production_to_string :: proc(production: ^Production) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, production.name)
	strings.write_string(&builder, " ::= ")
	strings.write_string(&builder, matcher_to_string(production.matchers[0]))
	for i := 1; i < len(production.matchers); i += 1 {
		strings.write_string(&builder, "\n\t| ")
		strings.write_string(&builder, matcher_to_string(production.matchers[i]))
	}
	strings.write_string(&builder, "\n")
	return strings.to_string(builder)
}

/* MATCHER TYPE DEFINITIONS AND FUNCTIONS */

Matcher :: struct {
	tokens: [dynamic]^Token,
}

matcher_new :: proc() -> ^Matcher {
	out := new(Matcher)
	out.tokens = make([dynamic]^Token)
	return out
}

matcher_new_empty :: proc() -> ^Matcher {
	out := matcher_new()
	matcher_append(out, token_new("empty", .Empty))
	return out
}

matcher_new_from_string :: proc(input: string) -> ^Matcher{
	tokens, err := strings.split(input, " ")
	if err != nil {
		// handle error
		fmt.printfln("Could not split matcher %s into tokens", input)
		os.exit(1)
	}
	matcher := matcher_new()
	for token in tokens {
		local := strings.trim_space(token)
		switch {
		case local == "empty" :
			matcher_append(matcher, token_new(strings.clone(local), .Empty))
		case unicode.is_upper(rune(local[0])):
			matcher_append(matcher, token_new(strings.clone(local), .Terminal))
		case unicode.is_lower(rune(local[0])):
			matcher_append(matcher, token_new(strings.clone(local), .Production))
		case:
			matcher_append(matcher, token_new(strings.clone(local), .Operator))
		}
	}
	return matcher
}

matcher_append :: proc(matcher: ^Matcher, token: ^Token) {
	append(&matcher.tokens, token)
}

matcher_to_string :: proc(matcher: ^Matcher) -> string {
	builder := strings.builder_make()
	for token in matcher.tokens {
		strings.write_string(&builder, token.value)
		strings.write_string(&builder, " ")
	}
	return strings.to_string(builder)
}

matcher_print :: proc(matcher: ^Matcher) {
	for token in matcher.tokens {
		fmt.printf("%s ", token.value)
	}
}

/* TOKEN TYPE DEFINITIONS AND FUNCTIONS */

Token :: struct {
	value: string,
	type: TokenType
}

TokenType :: enum {
	Production,
	Terminal,
	Operator,
	Empty
}

token_new :: proc(value: string, type: TokenType) -> ^Token {
	out := new(Token)
	out.value = value
	out.type = type
	return out
}

token_first_set :: proc(grammar: ^Grammar, token: ^Token) -> ProductionSet {
	out := make(map[string]string)
	// if the token is anything other than a non-terminal, just return a set with the token in it
	if token.type == .Terminal || token.type == .Operator || token.type == .Empty {
		out[token.value] = token.value
	} else if token.type == .Production {
		production := grammar.index[token.value]
		// for every matcher of the production
		for matcher in production.matchers {
			count := 0
			for token in matcher.tokens {
				// get the first set of each token and add it to the output
				first := token_first_set(grammar, token)
				for k,v in first {
					out[k] = v
				}
				// remove epsillon from the output if it's there
				// if epsillon is in the token's first set, it means that we have to derive
				// the first set for the next token as well, because this token can be empty
				// else break the loop, we're done
				if "empty" in first {
					count += 1
					delete_key(&out, "empty")
				} else {
					break
				}
			}
			// if all the tokens had epsillon
			// it means that the whole matcher can be empty
			// so add epsillon to the output
			if count == len(matcher.tokens) {
				out["empty"] = "empty"
			}
		}
	}
	return out
}

main :: proc() {
	grammar := grammar_new_from_file(os.args[1])
	elr_grammar := grammar_elr(grammar)

	grammar_terminals_init(elr_grammar)
	grammar_parsing_table_init(elr_grammar)
	grammar_parsing_table_build(elr_grammar)
	grammar_print(elr_grammar)

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

@(test)
test_grammar_creation :: proc(t: ^testing.T) {
	expected_lines := []string {
		"s ::= e ",
		"\ne ::= e + t ",
		"\n\t| t ",
		"\nt ::= t * f ",
		"\n\t| f ",
		"\nf ::= ( e ) ",
		"\n\t| INT ",
		"\n"
	}
	grammar := grammar_new_from_file("./test_specs/simple.spec")

	expected := strings.concatenate(expected_lines)
	actual := grammar_to_string(grammar)
	testing.expect_value(t, actual, expected)
}

@(test)
test_direct_elr :: proc(t: ^testing.T) {
	expected_lines := []string {
		"s ::= e ",
		"\ne_p ::= + t e_p ",
		"\n\t| empty ",
		"\ne ::= t e_p ",
		"\nt_p ::= * f t_p ",
		"\n\t| empty ",
		"\nt ::= f t_p ",
		"\nf ::= ( e ) ",
		"\n\t| INT ",
		"\n"
	}

	grammar := grammar_new_from_file("./test_specs/simple.spec")
	elr_grammar := grammar_elr(grammar)

	expected := strings.concatenate(expected_lines)
	actual := grammar_to_string(elr_grammar)

	testing.expect_value(t, actual, expected)
}


@(test)
test_first_sets :: proc(t: ^testing.T) {

	// Init the grammar and check it's ok
	expected_lines := []string {
		"h ::= k l P ",
		"\n\t| G s k ",
		"\nk ::= B l s t ",
		"\n\t| empty ",
		"\nl ::= s A k ",
		"\n\t| s k ",
		"\n\t| Q A ",
		"\ns ::= D S ",
		"\n\t| empty ",
		"\nt ::= G h F ",
		"\n\t| M ",
		"\n"
	}

	grammar := grammar_new_from_file("./test_specs/sets.spec")

	expected := strings.concatenate(expected_lines)
	actual := grammar_to_string(grammar)

	testing.expect_value(t, actual, expected)

	// Get the first sets
	first_sets := grammar_first_sets_get(grammar)

	expected_first_sets := map[string][]string {
		"h" = []string {"B", "G", "D", "A", "Q", "P"},
		"k" = []string {"B", "empty"},
		"l" = []string {"D", "Q", "A", "B", "empty"},
		"s" = []string {"D", "empty"},
		"t" = []string {"G", "M"},
	}
	testing.expect(t, len(expected_first_sets) == len(first_sets), fmt.tprintf("length of first sets is %d, but expected %d", len(first_sets), len(expected_first_sets)))
	for k, v in expected_first_sets {
		testing.expect(t, len(v) == len(first_sets[k]), fmt.tprintf("length of first set for production %s is %d, but expected %d", k, len(first_sets[k]), len(v)))
		for s in v {
			testing.expect(t, s in first_sets[k], fmt.tprintf("%s not found in first set for %s", s, k))
		}
	}
	grammar.first_sets = first_sets
	follow_sets := grammar_follow_sets_get(grammar)

	expected_follow_sets := map[string][]string {
		"h" = []string {"$", "F" },
		"k" = []string {"P", "D", "A", "Q", "B", "F", "G", "M", "$"},
		"l" = []string {"P", "G", "M", "D"},
		"s" = []string {"B", "G", "M", "A", "F", "P", "D", "$"},
		"t" = []string {"P", "D", "A", "Q", "B", "F", "G", "M", "$"},
	}

	testing.expect(t, len(expected_follow_sets) == len(follow_sets), fmt.tprintf("length of follow sets is %d, but expected %d", len(follow_sets), len(expected_follow_sets)))
	for k, v in expected_follow_sets {
		testing.expect(t, len(v) == len(follow_sets[k].entries), fmt.tprintf("length of follow set for production %s is %d, but expected %d", k, len(follow_sets[k].entries), len(v)))
		for s in v {
			testing.expect(t, s in follow_sets[k].entries, fmt.tprintf("%s not found in follow set for %s", s, k))
		}
	}

}

@(test)
test_parser_table :: proc(t: ^testing.T) {
	expected_table := map[string]map[string]string {
		"s" = map[string]string { "+" = "", "*" = "", "(" = "e ", ")" = "", "INT" = "e ", "$" = ""},
		"e" = map[string]string { "+" = "", "*" = "", "(" = "t e_p ", ")" = "", "INT" = "t e_p ", "$" = ""},
		"e_p" = map[string]string { "+" = "+ t e_p ", "*" = "", "(" = "", ")" = "empty ", "INT" = "", "$" = "empty "},
		"t" = map[string]string { "+" = "", "*" = "", "(" = "f t_p ", ")" = "", "INT" = "f t_p ", "$" = ""},
		"t_p" = map[string]string { "+" = "empty ", "*" = "* f t_p ", "(" = "", ")" = "empty ", "INT" = "", "$" = "empty "},
		"f" = map[string]string { "+" = "", "*" = "", "(" = "( e ) ", ")" = "", "INT" = "INT ", "$" = ""}
	}

	grammar := grammar_new_from_file("./test_specs/simple.spec")
	elr_grammar := grammar_elr(grammar)

	grammar_terminals_init(elr_grammar)
	grammar_parsing_table_init(elr_grammar)
	grammar_parsing_table_build(elr_grammar)

	for k, v in expected_table {
		for term_k, term_v in v {
			if term_v == "" {
				testing.expect(t, !table_exists(elr_grammar.parsing_table, k, term_k), fmt.tprintf("table[%s][%s] = %s should not exist!", k, term_k, table_get(elr_grammar.parsing_table, k, term_k)))
			} else {
				testing.expect(t, table_exists(elr_grammar.parsing_table, k, term_k), fmt.tprintf("table[%s][%s] = %s SHOULD exist!", k, term_k, term_v))
				expected_matcher := matcher_to_string(table_get(elr_grammar.parsing_table, k, term_k))
				testing.expect(t,  expected_matcher == term_v, fmt.tprintf("table[%s][%s] = %s != %s", k, term_k, table_get(elr_grammar.parsing_table, k, term_k), term_v))
			}
		}
	}
}
