CC = clang
CFLAGS = -O3 -Wall -Wextra -I/opt/homebrew/include
LDFLAGS = -L/opt/homebrew/lib -lavcodec -lavformat -lavutil -lswresample -lpthread

TARGET = audio_preprocessor
SRC = audio_preprocessor.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
