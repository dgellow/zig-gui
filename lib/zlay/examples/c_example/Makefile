CC = gcc
CFLAGS = -Wall -Werror -I../../src
LDFLAGS = -L../../zig-out/lib -lzlay

all: zlay_c_example

zlay_c_example: zlay_c_example.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f zlay_c_example

.PHONY: all clean