SRC_NAME = proxy
THISDIR = $(shell pwd)

all:

clean:

romfs:
	$(ROMFSINST) -d -p +x $(THISDIR)/proxy.sh /etc/storage/proxy.sh
	$(ROMFSINST) -s /etc/storage/proxy.sh /usr/bin/proxy.sh
	$(ROMFSINST) $(THISDIR)/proxy.html /www/proxy.html
