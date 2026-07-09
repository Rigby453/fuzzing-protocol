# Makefile for n2n AFL++ custom mutator
#
# Build:   make
# Clean:   make clean
# Debug:   make debug

CC      ?= gcc
CFLAGS  := -Wall -Wextra -Wpedantic -O2 -fPIC -shared
DBGFLAGS:= -Wall -Wextra -O0 -g -fsanitize=address -fPIC -shared

TARGET  := n2n_mutator.so
SRC     := n2n_mutator.c

.PHONY: all clean debug

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<
	@echo "[*] Built $(TARGET) successfully"
	@echo "[*] Usage: AFL_CUSTOM_MUTATOR_LIBRARY=\$$(pwd)/$(TARGET) afl-fuzz ..."

debug: $(SRC)
	$(CC) $(DBGFLAGS) -o $(TARGET:.so=_debug.so) $<

clean:
	rm -f $(TARGET) $(TARGET:.so=_debug.so) *.o
