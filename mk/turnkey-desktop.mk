# temp hack until we support server/desktop common overlays and conf

RELEASE ?= debian/$(shell lsb_release -s -c)

CDROOT ?= gfxboot-turnkey
HOSTNAME ?= $(shell basename $(shell pwd))
CONF_VARS += HOSTNAME ROOT_PASS NONFREE

COMMON_OVERLAYS_TMP := $(COMMON_OVERLAYS)
COMMON_OVERLAYS := bootstrap_apt
COMMON_OVERLAYS += turnkey.d/bashrc
COMMON_OVERLAYS += turnkey.d/grub
COMMON_OVERLAYS += turnkey.d/profile
COMMON_OVERLAYS += $(COMMON_OVERLAYS_TMP)

COMMON_CONF_TMP := $(COMMON_CONF)
COMMON_CONF := bootstrap_apt
COMMON_CONF += turnkey.d/console-setup
COMMON_CONF += turnkey.d/cronapt
COMMON_CONF += turnkey.d/hostname
COMMON_CONF += turnkey.d/locale
COMMON_CONF += turnkey.d/motd
COMMON_CONF += turnkey.d/persistent-net
COMMON_CONF += turnkey.d/roothome
COMMON_CONF += turnkey.d/rootpass
COMMON_CONF += turnkey.d/sysctl
COMMON_CONF += $(COMMON_CONF_TMP)

COMMON_REMOVELISTS += turnkey
COMMON_REMOVELISTS_FINAL += turnkey

FAB_SHARE_PATH ?= /usr/share/fab
# This repository, as the build sees it. bin/keel-version-files writes the
# two identity files of the image (decision 0014).
COMMON_BIN_PATH ?= $(FAB_PATH)/common/bin

# below hacks allow inheritors to define their own hooks, which will be
# prepended. warning: first line *needs* to be empty for this to work

# setup apt and dns for root.build
define _bootstrap/post

	fab-apply-overlay $(COMMON_OVERLAYS_PATH)/bootstrap_apt $O/bootstrap;
	mkdir -p $O/bootstrap/usr/local/share/ca-certificates/;
	cp /usr/local/share/ca-certificates/squid_proxyCA.crt $O/bootstrap/usr/local/share/ca-certificates/;
	fab-chroot $O/bootstrap --script $(COMMON_CONF_PATH)/bootstrap_apt;
	fab-chroot $O/bootstrap "echo nameserver 8.8.8.8 > /etc/resolv.conf";
	fab-chroot $O/bootstrap "echo nameserver 8.8.4.4 >> /etc/resolv.conf";
endef
bootstrap/post += $(_bootstrap/post)

# tag package management system with release package
# set /etc/turnkey_version and /etc/keel_version (bin/keel-version-files,
# decision 0014), then name the image after its appliance and drop the
# build's 127.0.1.1 line from /etc/hosts (mk/turnkey/seal-hostname)
#
# The apt User-Agent is no longer written here, for the reason given in
# mk/turnkey.mk: overlays/turnkey.d/apt-identity ships it (Keel-Linux/common#6).
define _root.patched/post

	#
	# tagging package management system with release package
	# setting /etc/turnkey_version and /etc/keel_version
	#
	@if [ -f $(FAB_PATH)/products/core/changelog ]; then \
		echo $(FAB_SHARE_PATH)/make-release-deb.py $(FAB_PATH)/products/core/changelog $O/root.patched; \
		$(FAB_SHARE_PATH)/make-release-deb.py $(FAB_PATH)/products/core/changelog $O/root.patched; \
	fi
	@if [ -f ./changelog ]; then \
		echo $(FAB_SHARE_PATH)/make-release-deb.py ./changelog $O/root.patched; \
		$(FAB_SHARE_PATH)/make-release-deb.py ./changelog $O/root.patched; \
		release_version=$$($(FAB_SHARE_PATH)/turnkey-version.py --dist=$(CODENAME) --tag=$(VERSION_TAG) ./changelog $(FAB_ARCH)); \
		[ -x $(COMMON_BIN_PATH)/keel-version-files ] || { echo "ERROR: $(COMMON_BIN_PATH)/keel-version-files is missing or not executable: the common checkout predates the identity files of decision 0014, update it" >&2; exit 1; }; \
		$(COMMON_BIN_PATH)/keel-version-files "$$release_version" $O/root.patched || exit 1; \
		$(FAB_PATH)/common/mk/turnkey/seal-hostname $O/root.patched || exit 1; \
	else \
		echo; \
		echo "WARNING: can't tag local release (./changelog doesn't exist)"; \
		echo; \
	fi

	fab-chroot $O/root.patched "dpkg -i *.deb && rm *.deb && rm -f /var/log/dpkg.log"

	fab-chroot $O/root.patched "which insserv >/dev/null && insserv"
	fab-chroot $O/root.patched "which postsuper >/dev/null && postsuper -d ALL || true"
endef
root.patched/post += $(_root.patched/post)

include $(FAB_SHARE_PATH)/product.mk
