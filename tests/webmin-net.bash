# Helpers for tests/webmin-net.bats: Webmin's own Network Configuration
# module, the code an appliance runs, driven through its CGIs over a
# scratch appliance root.
#
# The module is not modelled. setup_file fetches the two packages a core
# build installs from common/plans/turnkey/base, pinned by SHA-256, and
# unpacks them the way their maintainer scripts do (webmin-net's postinst
# unpacks module-archives/net.wbm.gz into the Webmin root). Each CGI then
# runs chrooted in a scratch root (tests/webmin-net-chroot) whose /etc holds
# an interfaces file as Keel writes it, a Webmin configuration like the
# image's, and /etc/resolv.conf as the symlink resolvconf owns.

WEBMIN_POOL=${WEBMIN_POOL:-https://archive.turnkeylinux.org/debian/pool/trixie/main/w}

# Package path under WEBMIN_POOL and its SHA-256, as the archive's
# Packages index for trixie lists them.
WEBMIN_DEBS=(
    "webmin/webmin_2.660.turnkey0_all.deb 67bc362c0d3396aa0e62b49d914e8b0cdae6fb864bb53e784f6428f3f0f266ad"
    "webmin-net/webmin-net_2.660.turnkey0_all.deb 2995e9aaa8aa7eac4ca3a1058159c7cc9d01b02f844ff4413e8e54037341af10"
)

# fetch_webmin DIR
# Unpacks Webmin and its Network Configuration module under DIR and prints
# the Webmin root. Packages are downloaded once into WEBMIN_DEB_CACHE
# (default ~/.cache/keel-tests) and used only when their hash matches.
fetch_webmin() {
    local dir=$1
    local cache=${WEBMIN_DEB_CACHE:-$HOME/.cache/keel-tests}
    local entry path sum deb
    mkdir -p "$cache" "$dir"
    for entry in "${WEBMIN_DEBS[@]}"; do
        path=${entry% *}
        sum=${entry#* }
        deb=$cache/$(basename "$path")
        if ! echo "$sum  $deb" | sha256sum --check --status 2>/dev/null; then
            curl -fsSL --retry 3 -o "$deb.part" "$WEBMIN_POOL/$path" || return 1
            mv "$deb.part" "$deb"
        fi
        echo "$sum  $deb" | sha256sum --check --quiet || return 1
        dpkg-deb -x "$deb" "$dir" || return 1
    done
    tar -C "$dir/usr/share/webmin" \
        -xf "$dir/usr/share/webmin/module-archives/net.wbm.gz" || return 1
    echo "$dir/usr/share/webmin"
}

# scratch_root INTERFACES_FIXTURE
# A scratch appliance root in ROOT: the interfaces file under test, the
# files the module reads and writes beside it, and Webmin's configuration
# for the module as the image has it after webmin-net is installed (its
# config file is the module's config-ALL-linux), with the acl module so
# that Webmin users can be created. Sets WEBMIN_CONFIG to the root's
# /etc/webmin and WEBMIN_ROOT to the test's own copy of the Webmin tree,
# which is what the scripts under test are run against.
scratch_root() {
    ROOT=$BATS_TEST_TMPDIR/root
    rm -rf "$ROOT"
    local dir
    for dir in etc/network etc/perl etc/webmin/net var/webmin run/resolvconf \
            opt/webmin usr dev tmp root kwn; do
        mkdir -p "$ROOT/$dir"
    done
    for dir in bin sbin lib lib64; do
        ln -s "usr/$dir" "$ROOT/$dir"
    done
    touch "$ROOT/dev/null"
    cp /etc/ld.so.cache "$ROOT/etc/ld.so.cache"
    printf 'root:x:0:0:root:/root:/bin/bash\n' > "$ROOT/etc/passwd"
    printf 'root:x:0:\n' > "$ROOT/etc/group"
    printf 'core\n' > "$ROOT/etc/hostname"
    printf '127.0.0.1 localhost\n127.0.1.1 core\n::1 localhost ip6-localhost ip6-loopback\n' \
        > "$ROOT/etc/hosts"
    printf 'passwd: files\nhosts: files dns\n' > "$ROOT/etc/nsswitch.conf"
    : > "$ROOT/etc/sysctl.conf"
    ln -s ../run/resolvconf/resolv.conf "$ROOT/etc/resolv.conf"
    printf 'nameserver 2001:db8:1::53\n' > "$ROOT/run/resolvconf/resolv.conf"
    cp "$FIXTURES/$1" "$ROOT/etc/network/interfaces"
    cp "$FIXTURES/$1" "$BATS_TEST_TMPDIR/interfaces.before"

    export WEBMIN_CONFIG=$ROOT/etc/webmin
    cat > "$WEBMIN_CONFIG/config" << 'CONFIG'
os_type=debian-linux
os_version=13
real_os_type=Debian Linux
real_os_version=13
path=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin
CONFIG
    cat > "$WEBMIN_CONFIG/miniserv.conf" << 'MINISERV'
root=/opt/webmin
userfile=/etc/webmin/miniserv.users
pidfile=/var/webmin/miniserv.pid
MINISERV
    printf '/var/webmin\n' > "$WEBMIN_CONFIG/var-path"
    printf 'root:x:0\n' > "$WEBMIN_CONFIG/miniserv.users"
    printf 'root: acl net\n' > "$WEBMIN_CONFIG/webmin.acl"
    mkdir -p "$WEBMIN_CONFIG/acl"
    cp "$WEBMIN_PRISTINE/acl/config-ALL-linux" "$WEBMIN_CONFIG/acl/config"
    cp "$WEBMIN_PRISTINE/net/config-ALL-linux" "$WEBMIN_CONFIG/net/config"

    # The Webmin root is the test's own copy: the module's defaultacl, and
    # a reinstall of the module, are written into it.
    WEBMIN_TREE=$BATS_TEST_TMPDIR/webmin
    rm -rf "$WEBMIN_TREE"
    cp -a "$WEBMIN_PRISTINE" "$WEBMIN_TREE"
    export WEBMIN_ROOT=$WEBMIN_TREE
    cp "$HELPERS_DIR/webmin-form.py" "$ROOT/kwn/webmin-form.py"
    cat > "$ROOT/kwn/cgi.sh" << 'CGI'
# cgi SCRIPT QUERY: one request to a CGI, as Webmin user WEBMIN_USER (root
# by default), the way miniserv runs it (a GET, from a page of the same
# server). SCRIPT is relative to the module directory WEBMIN_MODULE (net
# when unset; set and empty for Webmin's own top-level CGIs, such as the
# Module Config pages config.cgi and config_save.cgi).
cgi() {
    local path=/${WEBMIN_MODULE-net}
    path=${path%/}
    (cd "/opt/webmin$path" && env WEBMIN_CONFIG=/etc/webmin \
        WEBMIN_VAR=/var/webmin REMOTE_USER="${WEBMIN_USER:-root}" \
        SERVER_ROOT=/opt/webmin SERVER_NAME=localhost SERVER_PORT=12321 \
        HTTP_HOST=localhost:12321 \
        HTTP_REFERER="https://localhost:12321$path/" REQUEST_METHOD=GET \
        SCRIPT_NAME="$path/$1" SCRIPT_FILENAME="/opt/webmin$path/$1" \
        QUERY_STRING="$2" perl "/opt/webmin$path/$1")
}
# press_save PAGE PAGE_QUERY ACTION [NAME=VALUE...]: open PAGE, submit its
# form for ACTION as it was filled in, with the given fields changed
press_save() {
    local page=$1 query=$2 action=$3 form
    shift 3
    form=$(cgi "$page" "$query" | python3 /kwn/webmin-form.py "$action" "$@") \
        || return 1
    cgi "$action" "$form"
}
CGI
}

# webmin_net_run SHELL_COMMAND
# Runs SHELL_COMMAND in bash inside the scratch root, with cgi and
# press_save from /kwn/cgi.sh defined. The namespace has its own network
# stack too: a route or address the module sets must not reach the host.
webmin_net_run() {
    sandbox_mount_ns unshare --uts --net -- "$HELPERS_DIR/webmin-net-chroot" \
        "$ROOT" "$WEBMIN_TREE" /bin/bash -c "source /kwn/cgi.sh; $1"
}

# interfaces_unchanged
# Succeeds when the interfaces file is byte for byte the fixture it was.
interfaces_unchanged() {
    cmp "$BATS_TEST_TMPDIR/interfaces.before" "$ROOT/etc/network/interfaces"
}
