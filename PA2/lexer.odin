package lexer

import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) > 1 {
		fmt.println(os.args[1])
	}
}
