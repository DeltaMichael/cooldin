#+feature dynamic-literals

package lexer

import "core:fmt"
import "core:os"
import "core:bufio"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

LexerMode :: enum {
	Normal,
	String,
	Comment,
	MultilineComment
}

Token :: struct {
	lexeme: string,
	type: TokenType,
	lineno: int
}

TokenType :: enum {
	NONE,
	OBJECTID,
	TYPEID,
	INT_CONST,
	STR_CONST,
	ELSE,
	CLASS,
	FALSE,
	FI,
	IF,
	IN,
	INHERITS,
	ISVOID,
	LET,
	LOOP,
	POOL,
	THEN,
	WHILE,
	CASE,
	ESAC,
	NEW,
	OF,
	NOT,
	TRUE,
	LE,
	DARROW,
	ASSIGN,
	BOOL_CONST,
	ERROR
}

Lexer :: struct {
	reader: bufio.Reader,
	word: strings.Builder,
	keywords: map[string]TokenType,
	singles: map[rune]rune,
	comments: map[string]string,
	single_line_comment: string,
	multi_line_comment_open: string,
	multi_line_comment_close: string,
	string_delimiter: rune,
	tokens: [dynamic]^Token,
	lineno: int,
	current: rune,
	current_type: TokenType,
	next: rune,
	mode: LexerMode,
	is_at_end: bool
}

is_identifier :: proc(character: rune) -> bool {
	switch character {
	case 'A'..='Z', 'a'..='z', '_', '0'..= '9':
		return true
	case:
		return false
	}
}

new_token :: proc(lexeme: string, type: TokenType, lineno: int) -> ^Token {
	out := new(Token)
	out.lexeme = lexeme
	out.type = type
	out.lineno = lineno
	return out
}

new_lexer :: proc(reader: bufio.Reader) -> ^Lexer {
	out := new(Lexer)
	out.tokens = make([dynamic]^Token)
	out.word = strings.builder_make()
	out.lineno = 1
	out.is_at_end = false
	out.reader = reader
	out.mode = .Normal
	out.keywords = map[string]TokenType {
			"else" = .ELSE,
			"then" = .THEN,
			"class" = .CLASS,
			"fi" = .FI,
			"if" = .IF,
			"in" = .IN,
			"inherits" = .INHERITS,
			"isvoid" = .ISVOID,
			"let" = .LET,
			"loop" = .LOOP,
			"pool" = .POOL,
			"while" = .WHILE,
			"case" = .CASE,
			"esac" = .ESAC,
			"new" = .NEW,
			"of" = .OF,
			"not" = .NOT,
			"true" = .BOOL_CONST,
			"false" = .BOOL_CONST,
			"<=" = .LE,
			"<-" = .ASSIGN,
			"=>" = .DARROW,
	}
	out.singles = map[rune]rune {
		'{' = '{',
		'}' = '}',
		')' = ')',
		'+' = '+',
		'/' = '/',
		';' = ';',
		'.' = '.',
		',' = ',',
		':' = ':',
		'~' = '~',
		'@' = '@',
		'=' = '=',
		'<' = '<',
		'-' = '-',
		'(' = '(',
		'*' = '*',
	}

	out.single_line_comment = "--"
	out.multi_line_comment_open = "(*"
	out.multi_line_comment_close = "*)"
	out.string_delimiter = '"'

	out.comments = map[string]string {
		out.single_line_comment = out.single_line_comment,
		out.multi_line_comment_open = out.multi_line_comment_open,
		out.multi_line_comment_close = out.multi_line_comment_close
	}
	out.current_type = .NONE

	lexer_read_char(out)
	return out
}

// Simple operations

lexer_inc_lineno :: proc(lexer: ^Lexer) {
	if lexer.current == '\n' {
		lexer.lineno += 1
	}
}

lexer_read_char :: proc(lexer: ^Lexer) {
	character, width, read_err := bufio.reader_read_rune(&lexer.reader)
	if read_err == .EOF {
		lexer.is_at_end = true
		return
	} else if read_err != nil {
		fmt.println("Error reading character from file: ", read_err)
		os.exit(1)
	}
	lexer.next = character
}

lexer_advance :: proc(lexer: ^Lexer) {
	lexer.current = lexer.next
	lexer_read_char(lexer)
}

lexer_save :: proc(lexer: ^Lexer) {
	if strings.builder_len(lexer.word) > 0 {
		word := strings.to_string(lexer.word)
		to_lower := strings.to_lower(word)
		if to_lower in lexer.keywords {
			if lexer.current_type == .TYPEID && lexer.keywords[to_lower] == .BOOL_CONST {
				append(&lexer.tokens, new_token(strings.clone(word), .TYPEID, lexer.lineno))
			} else {
				append(&lexer.tokens, new_token(to_lower, lexer.keywords[to_lower], lexer.lineno))
			}
		} else {
			append(&lexer.tokens, new_token(strings.clone(word), lexer.current_type, lexer.lineno))
		}
		strings.builder_reset(&lexer.word)
	}
}

lexer_save_str :: proc(lexer: ^Lexer) {
	word := strings.to_string(lexer.word)
	append(&lexer.tokens, new_token(fmt.tprintf("\"%s\"", word), .STR_CONST, lexer.lineno))
	strings.builder_reset(&lexer.word)
}

lexer_save_err :: proc(lexer: ^Lexer, message: string) {
	append(&lexer.tokens, new_token(fmt.tprintf("\"%s\"",message), .ERROR, lexer.lineno))
}

lexer_clear_word :: proc(lexer: ^Lexer) {
	strings.builder_reset(&lexer.word)
}

lexer_get_buffer :: proc(lexer: ^Lexer) -> string {
	runes := []rune {lexer.current, lexer.next}
	buffer := utf8.runes_to_string(runes)
	return buffer
}

// State transitions
lexer_transition_comment :: proc(lexer: ^Lexer, op_cand: string) {
	switch op_cand {
	case lexer.single_line_comment:
		// PROCESS SINGLE-LINE COMMENT
		lexer_advance(lexer)

		lexer_advance(lexer)
		lexer.mode = .Comment
	case lexer.multi_line_comment_open:
		// PROCESS MULTI-LINE COMMENT
		lexer_advance(lexer)

		lexer_advance(lexer)
		lexer.mode = .MultilineComment
	case lexer.multi_line_comment_close:
		// ERROR
		lexer_advance(lexer)
		lexer.mode = .Normal
		lexer_save_err(lexer, fmt.tprintf("Unmatched %s", lexer.multi_line_comment_close))
	}
}

lexer_transition_string :: proc(lexer: ^Lexer) {
	lexer_advance(lexer)
	lexer.mode = .String
}

lexer_matches_next :: proc(lexer: ^Lexer) -> bool {
	#partial switch lexer.current_type {
		case .OBJECTID, .TYPEID:
			return is_identifier(lexer.next)
		case .INT_CONST:
			return unicode.is_digit(lexer.next)
		case:
			return false
	}
}

lexer_error_unsupported_chars :: proc(lexer: ^Lexer) {
	if lexer.current == '\\' {
		lexer_save_err(lexer, fmt.tprintf("\\%c", lexer.current))
	} else if int(lexer.current) <= 31 {
		lexer_save_err(lexer, fmt.tprintf("\\%03d", int(lexer.current)))
	} else {
		lexer_save_err(lexer, fmt.tprintf("%c", lexer.current))
	}
}


// Types of tokens to process
// 1. Single-Char Operators
// 2. Double-Char Operators
// 3. Object identifiers -> start with lower-case
// 4. Type identifiers -> start with upper-case
// 5. Bool constatnts -> start with lower-case (true, false, tRUE, faLsE, etc.)
// 6. Keywords -> in keywords table
// 7. Integers -> [0-9]{1}[0-9]*
lexer_process :: proc(lexer: ^Lexer) {
	if lexer.current_type == .NONE {
		op_cand := lexer_get_buffer(lexer)
		switch {
			case op_cand in lexer.comments:
				lexer_transition_comment(lexer, op_cand)
				return
			case lexer.current == lexer.string_delimiter:
				lexer_transition_string(lexer)
				return
		}
		lexer_process_first_char(lexer)
	}
}

lexer_process_first_char :: proc(lexer: ^Lexer) {
	op_cand := lexer_get_buffer(lexer)
	switch {
		case unicode.is_space(lexer.current):
			lexer_inc_lineno(lexer)
		case unicode.is_lower(lexer.current):
			lexer.current_type = .OBJECTID
		case unicode.is_upper(lexer.current):
			lexer.current_type = .TYPEID
		case unicode.is_digit(lexer.current):
			lexer.current_type = .INT_CONST
		case lexer.current in lexer.singles:
			strings.write_rune(&lexer.word, lexer.current)
			if op_cand in lexer.keywords {
				lexer_advance(lexer)
				strings.write_rune(&lexer.word, lexer.current)
			}
			lexer_save(lexer)
		case:
			lexer_error_unsupported_chars(lexer)
	}
}

lexer_process_rest :: proc(lexer: ^Lexer) {
	#partial switch lexer.current_type {
	case .OBJECTID, .TYPEID, .INT_CONST:
		strings.write_rune(&lexer.word, lexer.current)
		if !lexer_matches_next(lexer) {
			lexer_save(lexer)
			lexer.current_type = .NONE
		}
	case:
		// do nothing
	}

}

lexer_tokens_print :: proc(lexer: ^Lexer) {
	fmt.printfln("#name \"%s\"", os.args[1])
	for token in lexer.tokens {
		#partial switch token.type {
		case .NONE:
			fmt.printfln("#%d '%s'", token.lineno, token.lexeme)
		case .OBJECTID, .TYPEID, .INT_CONST, .BOOL_CONST, .STR_CONST, .ERROR:
			fmt.printfln("#%d %s %s", token.lineno, fmt.tprint(token.type), token.lexeme)
		case:
			fmt.printfln("#%d %s", token.lineno, fmt.tprint(token.type))
		}
	}
}

main :: proc() {
	if len(os.args) > 1 {
		handle, err := os.open(os.args[1], os.O_RDONLY, 0)
		if err != 0 {
			fmt.printfln("Error opening file %s", os.args[1])
		}
		defer os.close(handle)

		// create char reader
		reader: bufio.Reader
		bufio.reader_init(&reader, os.stream_from_handle(handle))
        defer bufio.reader_destroy(&reader)

		lexer := new_lexer(reader)
		for !lexer.is_at_end {
			switch lexer.mode {
				case .Normal:
					lexer_advance(lexer)
					lexer_process(lexer)
					lexer_process_rest(lexer)
				case .Comment:
					// process comment
					lineno := lexer.lineno
					for !lexer.is_at_end && lexer.current != '\n' {
						lexer_advance(lexer)
						lexer_inc_lineno(lexer)
					}
					lexer.mode = .Normal
				case .MultilineComment:
					// process multi-line comment
					counter := 1
					for !lexer.is_at_end {
						buf := lexer_get_buffer(lexer)
						if buf == lexer.multi_line_comment_close {
							counter -= 1
						}
						if buf == lexer.multi_line_comment_open {
							counter += 1
						}
						if counter == 0 {
							lexer_advance(lexer)
							lexer_inc_lineno(lexer)
							break
						}
						lexer_advance(lexer)
						lexer_inc_lineno(lexer)
					}
					if lexer.is_at_end && counter > 0 {
						lexer_save_err(lexer, "EOF in comment")
					}
					lexer.mode = .Normal
				case .String:
					error_flag := false
					string_closed := false
					count := 0
					str_loop: for !lexer.is_at_end {
						switch lexer.current  {
						case '\\':
							switch lexer.next {
							case 'n', 'b', 't', 'f', '\\', '"':
								strings.write_rune(&lexer.word, lexer.current)
								lexer_advance(lexer)
								strings.write_rune(&lexer.word, lexer.current)
								count += 1
								lexer_advance(lexer)
							case '\n':
								strings.write_rune(&lexer.word, lexer.current)
								strings.write_rune(&lexer.word, 'n')
								count += 1
								lexer_advance(lexer)
								lexer_inc_lineno(lexer)
								lexer_advance(lexer)
							case:
								lexer_advance(lexer)
							}
						case '\n':
							lexer_inc_lineno(lexer)
							lexer_clear_word(lexer)
							break str_loop
						case '\t':
							strings.write_rune(&lexer.word, '\\')
							strings.write_rune(&lexer.word, 't')
							count += 1
							lexer_advance(lexer)
						case '\f':
							strings.write_rune(&lexer.word, '\\')
							strings.write_rune(&lexer.word, 'f')
							count += 1
							lexer_advance(lexer)
						case '\b':
							strings.write_rune(&lexer.word, '\\')
							strings.write_rune(&lexer.word, 'b')
							count += 1
							lexer_advance(lexer)
						case '\022', '\033', '\013', '\015':
							strings.write_string(&lexer.word, fmt.tprintf("\\%03o", lexer.current))
							count += 1
							lexer_advance(lexer)
						case lexer.string_delimiter:
							string_closed = true
							break str_loop
						case :
							strings.write_rune(&lexer.word, lexer.current)
							count += 1
							lexer_advance(lexer)
						}
					}
					if !string_closed {
						if lexer.is_at_end {
							lexer_save_err(lexer, "EOF in string constant")
						} else {
							lexer_save_err(lexer, "Unterminated string constant")
						}
						lexer_clear_word(lexer)
					} else if count > 1024 {
						lexer_save_err(lexer, "String constant too long")
						lexer_clear_word(lexer)
					} else {
						lexer_save_str(lexer)
					}
					lexer.mode = .Normal
					// process string
			}
		}
		lexer_save(lexer)
		lexer_tokens_print(lexer)
	}
}
