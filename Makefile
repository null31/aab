TODAY != date '+%Y%m%d'

VERSION := $(TODAY)-1
V_amd64  := $(VERSION)_amd64
V_i686   := $(VERSION)_i686

PERL := perl -I.

all:
	@echo The following targets are available:
	@echo '  $(MAKE) base-amd64'
	@echo '  $(MAKE) base-i686'
	@echo '  $(MAKE) default           (same as make base-amd64)'

.PHONY: default
default: base-amd64

# we should always regenerate this:
.PHONY: aab.conf aab.conf.amd64 aab.conf.i686
aab.conf:
	echo 'Name: archlinux-base' > aab.conf
	echo 'Version: $(VERSION)' >> aab.conf
	echo 'Section: system' >> aab.conf
	echo 'Maintainer: Proxmox Support Team <support@proxmox.com>' >> aab.conf
	echo 'Source: http://archlinux.cu.be/$$repo/os/$$arch' >> aab.conf

aab.conf.amd64: aab.conf
	echo 'Architecture: amd64' >> aab.conf
aab.conf.i686: aab.conf
	echo 'Architecture: i686' >> aab.conf

.PHONY: base-amd64
base-amd64: archlinux-base_$(V_amd64).tar.gz
archlinux-base_$(V_amd64).tar.gz: aab.conf.amd64
	echo 'Headline: ArchLinux base image.' >> aab.conf
	$(MAKE) build-current

.PHONY: base-xi686
base-i686: archlinux-base_$(V_i686).tar.gz
archlinux-base_$(V_i686).tar.gz: aab.conf.i686
	echo 'Headline: ArchLinux base image.' >> aab.conf
	$(MAKE) build-current

.PHONY: build-current
build-current: check-all
	$(PERL) ./aab init
	$(PERL) ./aab bootstrap
	$(PERL) ./aab finalize
	$(PERL) ./aab clean

.PHONY: check-pacman
check-pacman:
	@which pacman >/dev/null || (echo Dependency error:; echo 'Please install the arch-pacman package'; echo; false)

.PHONY: check-root
check-root:
	@test 0 -eq "`id -u`" || (echo Permission error:; echo 'aab needs to be run as root'; echo; false)

.PHONY: check-all
check-all: check-pacman check-root

.PHONY: clean
clean:
	@$(PERL) ./aab clean

.PHONY: distclean
distclean:
	@$(PERL) ./aab dist-clean
