TODAY != date '+%Y%m%d'

VERSION := $(TODAY)-1
ARCH := amd64
V_ARCH := $(VERSION)_$(ARCH)

PERL := perl -I.

.PHONY: default
default: base-amd64

# we should always regenerate this:
.PHONY: aab.conf
aab.conf:
	echo 'Name: archlinux-base' > aab.conf
	echo 'Version: $(VERSION)' >> aab.conf
	echo 'Section: system' >> aab.conf
	echo 'Maintainer: Proxmox Support Team <support@proxmox.com>' >> aab.conf
	echo 'Source: https://geo.mirror.pkgbuild.com/$$repo/os/$$arch' >> aab.conf
	echo 'Architecture: $(ARCH)' >> aab.conf
	echo 'Description: ArchLinux base image.' >> aab.conf
	echo " ArchLinux template with the 'base' group and the 'openssh' package installed." >> aab.conf

.PHONY: base-$(ARCH)
base-$(ARCH): aab.conf archlinux-base_$(V_ARCH).tar.gz

archlinux-base_$(V_ARCH).tar.gz: build-current

.PHONY: build-current
build-current: check-all
	$(PERL) ./aab init
	$(PERL) ./aab bootstrap
	$(PERL) ./aab finalize
	$(PERL) ./aab clean

.PHONY: check-pacman
check-pacman:
	@which pacman >/dev/null || (echo Dependency error:; echo 'Please install the pacman-package-manager or arch-pacman package'; echo; false)

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
	rm -rf archlinux*.tar*
