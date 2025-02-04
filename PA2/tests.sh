#!/bin/sh

for file in grading/*.cool; do
	lexer $file > ref.txt
	./lexer $file > out.txt
	diff out.txt ref.txt > /dev/null
	if [ $? -ne 0 ]; then
		echo "Failed for $file"
	fi
done
