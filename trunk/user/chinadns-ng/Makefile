# chinadns-ng for Padavan
# Downloads pre-compiled MIPSel musl static binary (with wolfssl for DoT)
SRC_NAME = chinadns-ng
THISDIR = $(shell pwd)

CHINADNS_VER = 2025.08.09
CHINADNS_FILE = chinadns-ng+wolfssl@mipsel-linux-musl@mips32+soft_float@fast+lto
CHINADNS_URL = https://github.com/zfl9/chinadns-ng/releases/download/$(CHINADNS_VER)/$(CHINADNS_FILE)

all:

clean:
	rm -f chinadns-ng

romfs:
	( if [ ! -f chinadns-ng ]; then \
		echo "Downloading chinadns-ng $(CHINADNS_VER)..."; \
		wget -t3 -4 --timeout=15 -O chinadns-ng.dl '$(CHINADNS_URL)' && \
		mv chinadns-ng.dl chinadns-ng && \
		chmod +x chinadns-ng && \
		echo "Download OK ($(shell wc -c < chinadns-ng 2>/dev/null || echo 0) bytes)"; \
	fi )
	$(ROMFSINST) -p +x $(THISDIR)/chinadns-ng /usr/bin/chinadns-ng
