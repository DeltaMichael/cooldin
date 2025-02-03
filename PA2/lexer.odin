#+feature dynamic-literals

package lexer

import "core:fmt"
import "core:os"
import "core:bufio"
import "core:strings"

LexerMode :: enum {
	Normal,
	String,
	Comment,
	MultilineComment
}

Token :: struct {
	lexeme: string,
	lineno: int
}

Lexer :: struct {
	reader: bufio.Reader,
	word: strings.Builder,
	keywords: map[string]string,
	singles: map[rune]rune,
	singles_with_double: map[rune]rune,
	tokens: [dynamic]^Token,
	lineno: int,
	current: rune,
	next: rune,
	mode: LexerMode,
	is_at_end: bool
}

new_token :: proc(lexeme: string, lineno: int) -> ^Token {
	out := new(Token)
	out.lexeme = lexeme
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
	out.keywords = map[string]string {
			"class" = "else",
			"false" = "false",
			"fi" = "fi",
			"if" = "if",
			"in" = "in",
			"inherits" = "inherits",
			"isvoid" = "isvoid",
			"let" = "let",
			"loop" = "loop",
			"pool" = "pool",
			"then" = "then",
			"while" = "while",
			"case" = "case",
			"esac" = "esac",
			"new" = "new",
			"of" = "of",
			"not" = "not",
			"true" = "true",
	}
	out.singles = map[rune]rune {
		'{' = '{',
		'}' = '}',
		')' = ')',
		'+' = '+',
		'-' = '-',
		'=' = '=',
		';' = ';',
		'.' = '.',
	}
	out.singles_with_double = map[rune]rune {
		'<' = '-',
		'>' = '=',
		'(' = '*',
		'/' = '/',
	}
	lexer_read_char(out)
	return out
}

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

lexer_peek :: proc(lexer: ^Lexer) -> rune {
	return lexer.next
}

lexer_save :: proc(lexer: ^Lexer) {
	if strings.builder_len(lexer.word) > 0 {
		word := strings.to_string(lexer.word)
		fmt.println(word)
		append(&lexer.tokens, new_token(strings.clone(word), lexer.lineno))
		strings.builder_reset(&lexer.word)
	}
}

lexer_process :: proc(lexer: ^Lexer) {
	switch {
	case strings.is_space(lexer.current):
		lexer_save(lexer)
		lexer_inc_lineno(lexer)
	case lexer.current in lexer.singles:
		if strings.builder_len(lexer.word) > 0 {
			lexer_save(lexer)
			lexer_inc_lineno(lexer)
		}
		strings.write_rune(&lexer.word, lexer.current)
		lexer_save(lexer)
		lexer_inc_lineno(lexer)
	case lexer.current in lexer.singles_with_double:
		if strings.builder_len(lexer.word) > 0 {
			lexer_save(lexer)
			lexer_inc_lineno(lexer)
		}
		switch {
		case lexer.current == '>' && lexer.next == '=':
			// GTE
			strings.write_rune(&lexer.word, lexer.current)
			lexer_advance(lexer)
			strings.write_rune(&lexer.word, lexer.current)
			lexer_save(lexer)
			lexer_inc_lineno(lexer)
		case lexer.current == '<' && lexer.next == '=':
			// LTE
			strings.write_rune(&lexer.word, lexer.current)
			lexer_advance(lexer)
			strings.write_rune(&lexer.word, lexer.current)
			lexer_save(lexer)
			lexer_inc_lineno(lexer)
		case lexer.current == '<' && lexer.next == '-':
			// ASSIGNMENT
			strings.write_rune(&lexer.word, lexer.current)
			lexer_advance(lexer)
			strings.write_rune(&lexer.word, lexer.current)
			lexer_save(lexer)
			lexer_inc_lineno(lexer)
		case lexer.current == '/' && lexer.next == '/':
			// PROCESS SINGLE-LINE COMMENT
		case lexer.current == '(' && lexer.next == '*':
			// PROCESS MULTI-LINE COMMENT
			lexer_advance(lexer)
			lexer_advance(lexer)
			lexer.mode = .MultilineComment
		case lexer.current == '*' && lexer.next == ')':
			// ERROR
		case:
			strings.write_rune(&lexer.word, lexer.current)
			lexer_save(lexer)
			lexer_inc_lineno(lexer)
		}
	case lexer.current == '"':
		// PROCESS STRING
	case:
		strings.write_rune(&lexer.word, lexer.current)
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
				case .Comment:
					// process comment
				case .MultilineComment:
					// process multi-line comment
					counter := 1
					for !lexer.is_at_end {
						if lexer.current == '*' && lexer.next == ')' {
							counter -= 1
						}
						if lexer.current == '(' && lexer.next == '*' {
							counter += 1
						}
						if counter == 0 {
							lexer_advance(lexer)
							lexer_advance(lexer)
							lexer_inc_lineno(lexer)
							break;
						}
						lexer_advance(lexer)
						lexer_inc_lineno(lexer)
					}
					lexer.mode = .Normal
				case .String:
					// process string
			}
		}
		fmt.printfln("#name \"%s\"", os.args[1])
		for token in lexer.tokens {
			fmt.printfln("#%d %s", token.lineno, token.lexeme)
		}
	}
}
