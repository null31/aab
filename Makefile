TODAY != date '+%Y-%M-%d'

VERSION := $(TODAY)-1
V_x86_64 := $(VERSION)_x86_64
V_i686   := $(VERSION)_i686

all:
	@echo The following targets are available:
	@echo '  $(MAKE) base-x86_64'
	@echo '  $(MAKE) base-i686'
	@echo '  $(MAKE) default           (same as make base-x86_64)'

.PHONY: default
default: base-x86_64

# we should always regenerate this:
.PHONY: aab.conf aab.conf.x86_64 aab.conf.i686
aab.conf:
	echo 'Name: archlinux-base' > aab.conf
	echo 'Version: $(VERSION)' >> aab.conf
	echo 'Section: system' >> aab.conf
	echo 'Maintainer: Proxmox Support Team <support@proxmox.com>' >> aab.conf
	echo 'Source: http://archlinux.cu.be/$$repo/os/$$arch' >> aab.conf

aab.conf.x86_64: aab.conf
	echo 'Architecture: x86_64' >> aab.conf
aab.conf.i686: aab.conf
	echo 'Architecture: i686' >> aab.conf

.PHONY: base-x86_64
base-x86_64: archlinux-base_$(V_x86_64).tar.gz
archlinux-base_$(V_x86_64).tar.gz: aab.conf.x86_64
	echo 'Headline: ArchLinux base image.' >> aab.conf
	$(MAKE) build-current

.PHONY: base-xi686
base-i686: archlinux-base_$(V_i686).tar.gz
archlinux-base_$(V_i686).tar.gz: aab.conf.i686
	echo 'Headline: ArchLinux base image.' >> aab.conf
	$(MAKE) build-current

.PHONY: build-current
build-current: check-all
	./aab init
	./aab bootstrap
	./aab finalize
	./aab clean

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
	@./aab clean

.PHONY: distclean
distclean:
	@./aab dist-clean
