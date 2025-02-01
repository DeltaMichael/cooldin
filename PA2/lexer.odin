package lexer

import "core:fmt"
import "core:os"
import "core:bufio"
import "core:strings"

Token :: struct {
	lexeme: string,
	line: u64
}

new_token :: proc(lexeme: string, line: u64) -> ^Token {
	out := new(Token)
	out.lexeme = lexeme
	out.line = line
	return out
}

process_char :: proc(current_word: ^strings.Builder, all_words: ^[dynamic]^Token, current_line: ^u64, character: rune) {
	if strings.is_space(character) {
		if strings.builder_len(current_word^) > 0 {
			word := strings.to_string(current_word^)
			append(all_words, new_token(strings.clone(word), current_line^))
			strings.builder_reset(current_word)
		}
		if character == '\n' {
			current_line^ += 1
		}
	} else {
		strings.write_rune(current_word, character)
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

		// current_word := make([dynamic]rune)
		current_word := strings.builder_make()
		all_words := make([dynamic]^Token)
		current_line: u64
		current_line = 1
		defer strings.builder_destroy(&current_word)
		defer delete(all_words)

		for {
			character, width, read_err := bufio.reader_read_rune(&reader)
			if read_err == .EOF {
				if strings.builder_len(current_word) > 0 {
					word := strings.to_string(current_word)
					append(&all_words, new_token(strings.clone(word), current_line))
					break;
				}
			} else if read_err != nil {
				fmt.println("Error reading character from file: ", read_err)
				break;
			}
			process_char(&current_word, &all_words, &current_line, character)
		}
		fmt.printfln("#name \"%s\"", os.args[1])
		for token in all_words {
			fmt.printfln("#%d %s", token.line, token.lexeme)
		}
	}
}
