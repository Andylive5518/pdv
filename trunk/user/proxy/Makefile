SRC_NAME = proxy
THISDIR = $(shell pwd)

all:

clean:

romfs:
	$(ROMFSINST) -p +x $(THISDIR)/proxy.sh /usr/bin/proxy.sh
	$(ROMFSINST) -p +x $(THISDIR)/update_chnroute_proxy.sh /usr/bin/update_chnroute_proxy.sh
	$(ROMFSINST) $(THISDIR)/proxy.html /www/proxy.html
