RELEASE ?= debian/$(shell lsb_release -s -c)

CDROOT ?= gfxboot-turnkey
HOSTNAME ?= $(shell basename "$(shell pwd)")

# general TKL vars
CONF_VARS += HOSTNAME ROOT_PASS NONFREE BACKPORTS_NONFREE TKL_TESTING BACKPORTS
# the Keel archive track a build installs from and the image follows:
# stable (default) or testing (conf/bootstrap_apt, conf/turnkey.d/keel-apt)
CONF_VARS += KEEL_APT_TRACK
# set specific software versions
CONF_VARS += PHP_VERSION RUBY_VER NODE_VER
# Webmin/firewall related
CONF_VARS += WEBMIN_THEME WEBMIN_FW_TCP_INCOMING WEBMIN_FW_TCP_INCOMING_REJECT WEBMIN_FW_UDP_INCOMING WEBMIN_FW_NAT_EXTRA WEBMIN_FW_MANGLE_EXTRA
# these are needed to control styling of credits (e.g., conf/apache-credit)
CONF_VARS += CREDIT_STYLE CREDIT_STYLE_EXTRA CREDIT_ANCHORTEXT CREDIT_LOCATION
# these are needed to ensure github queries don't get limited
CONF_VARS += GITHUB_USER GITHUB_USER_TOKEN
# for dynamically adding pins to sury & backports respectively
CONF_VARS += PHP_EXTRA_PINS BACKPORTS_PINS
# proxy vars
CONF_VARS += NO_PROXY HTTP_PROXY HTTPS_PROXY

COMMON_OVERLAYS := turnkey.d $(COMMON_OVERLAYS)
COMMON_CONF := turnkey.d $(COMMON_CONF)
COMMON_REMOVELISTS += turnkey
COMMON_REMOVELISTS_FINAL += turnkey

FAB_SHARE_PATH ?= /usr/share/fab
# This repository, as the build sees it. bin/keel-version-files writes the
# two identity files of the image (decision 0014).
COMMON_BIN_PATH ?= $(FAB_PATH)/common/bin

APT_OVERLAY = fab-apply-overlay $(COMMON_OVERLAYS_PATH)/bootstrap_apt $O/bootstrap;

# below hacks allow inheritors to define their own hooks, which will be
# prepended. warning: first line *needs* to be empty for this to work

# setup apt and dns for root.build
define _bootstrap/post

	$(APT_OVERLAY)
	fab-chroot $O/bootstrap "echo nameserver 8.8.8.8 > /etc/resolv.conf";
	fab-chroot $O/bootstrap "echo nameserver 8.8.4.4 >> /etc/resolv.conf";
	mkdir -p $O/bootstrap/usr/local/share/ca-certificates/;
	# temporarily allow cert to not exist
	cp /usr/local/share/ca-certificates/squid_proxyCA.crt $O/bootstrap/usr/local/share/ca-certificates/ || true;
	# the key of archive.keellinux.org, which bootstrap_apt's keel.sources
	# names, so the plan can install Keel's packages (keys/, the public
	# half published at the archive root; the package installs the same key)
	mkdir -p $O/bootstrap/usr/share/keyrings;
	cp $(COMMON_CONF_PATH)/../keys/keel-archive-keyring.asc $O/bootstrap/usr/share/keyrings/keel-archive-keyring.asc;
	fab-chroot $O/bootstrap --script $(COMMON_CONF_PATH)/bootstrap_apt;
endef
bootstrap/post += $(_bootstrap/post)

# set /etc/turnkey_version and /etc/keel_version (bin/keel-version-files,
# decision 0014), then name the image after its appliance and drop the
# build's 127.0.1.1 line from /etc/hosts (mk/turnkey/seal-hostname)
#
# fab's release meta package (turnkey-<app>-<version>) is no longer built:
# keel-core is the meta package of a Keel image (handbook decision 0047),
# and the compatibility file is written on its own.
#
# The apt User-Agent is no longer written here. It used to carry the appliance
# and its version to every archive the machine ever contacted; it is now a
# fixed header naming the distribution and nothing else, shipped by
# overlays/turnkey.d/apt-identity as /etc/apt/apt.conf.d/01keel
# (Keel-Linux/common#6).
define _root.patched/post

	#
	# setting /etc/turnkey_version and /etc/keel_version
	#
	@if [ -f ./changelog ]; then \
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

	fab-chroot $O/root.patched "which postsuper >/dev/null && postsuper -d ALL || true"

	# last: root locked or the build fails, and the build date stamped
	$(FAB_PATH)/common/mk/turnkey/seal-root $O/root.patched
endef
root.patched/post += $(_root.patched/post)

include $(FAB_SHARE_PATH)/product.mk

