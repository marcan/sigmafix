
PROGRAMMER ?= usbtiny

all: sigmafix.hex

sigmafix.hex: sigmafix.asm
	avra -fI -l sigmafix.lst -o $@ $<

flash: sigmafix.hex
	avrdude -p attiny13 -c $(PROGRAMMER) -U flash:w:$< \
		-U lfuse:w:0x72:m \
		-U hfuse:w:0xfb:m

clean:
	rm -f *.hex *.lst *.cof *.obj
