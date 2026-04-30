#
# Open Watcom makefile for the hello reference example.
#
# Use:    wmake          # build build/HELLO.EXE
#         wmake clean    # remove build artifacts
#

CC      = wcl
CFLAGS  = -bt=dos -ms -0 -os -s -d0 -we -wx -Isrc
OUTDIR  = build

all: $(OUTDIR)/HELLO.EXE

$(OUTDIR)/HELLO.EXE: src/hello.c
	$(CC) $(CFLAGS) -fe=$(OUTDIR)/HELLO.EXE src/hello.c

clean: .SYMBOLIC
	rm -f $(OUTDIR)/*.EXE $(OUTDIR)/*.obj $(OUTDIR)/*.map $(OUTDIR)/*.err
