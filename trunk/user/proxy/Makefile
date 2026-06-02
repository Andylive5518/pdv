SRC_NAME = proxy
THISDIR = $(shell pwd)

all:

clean:

romfs:
	$(ROMFSINST) -p +x $(THISDIR)/proxy.sh /usr/bin/proxy.sh
	$(ROMFSINST) $(THISDIR)/proxy.html /www/proxy.html
