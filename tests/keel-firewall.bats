#!/usr/bin/env bats
# Tests for mk/turnkey/keel-firewall, run in root.patched/post: the image
# build writes keel's inbound firewall in the state enforce, with the keel
# of the image and --root, and does not load it (decision 0097, section 5,
# work item 10). keel-firewall.service loads it at the first boot, before
# the network, so a new node is closed from its first packet.
#
# Why: every published node was open in every mode (decision 0097). keel
# writes the firewall at an apply, but under --root it sees no socket, so
# a spec with no state writes report there: the build must say enforce.
#
# The image tree holds a stub keel package under
# usr/lib/python3/dist-packages: the facts of one appliance, and a
# `python3 -m keel` that records its arguments and writes what keel writes
# under --root. FAKE_KEEL steers the stub: "ok" (default), "fail" (exit
# 16), "live" (no "not loaded" line), "report" (a report ruleset),
# "nofence" (no fence rule), "more" (it also enables a unit),
# "nomonit" (no monit file, no overlay record). systemctl is a stub on
# PATH.

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../mk/turnkey/keel-firewall"
    ROOTFS=$BATS_TEST_TMPDIR/rootfs
    STUB=$BATS_TEST_TMPDIR/bin
    PKG=$ROOTFS/usr/lib/python3/dist-packages/keel
    WANTS=$ROOTFS/etc/systemd/system/multi-user.target.wants
    mkdir -p "$STUB" "$PKG/manifest" "$PKG/inspect" "$WANTS" \
        "$ROOTFS/var/lib/dpkg" "$ROOTFS/usr/lib/systemd/system"
    keel_version 0.23.100
    ln -s /usr/lib/systemd/system/keel-firewall.service \
        "$WANTS/keel-firewall.service"
    : > "$ROOTFS/usr/lib/systemd/system/nftables.service"
    stub_keel
    cat > "$STUB/systemctl" <<'STUBEOF'
#!/bin/bash
echo "systemctl $*" >> "$BATS_TEST_TMPDIR/systemctl.calls"
exit "${FAKE_SYSTEMCTL:-0}"
STUBEOF
    chmod +x "$STUB/systemctl"
    export PATH="$STUB:$PATH"
}

# keel_version VERSION: the dpkg status of the image says keel VERSION
keel_version() {
    cat > "$ROOTFS/var/lib/dpkg/status" <<EOF
Package: keel
Status: install ok installed
Architecture: all
Version: $1

EOF
}

# stub_keel: the keel package of the image, as far as the script uses it
stub_keel() {
    : > "$PKG/__init__.py"
    : > "$PKG/manifest/__init__.py"
    : > "$PKG/inspect/__init__.py"
    cat > "$PKG/manifest/constants.py" <<'PY'
APPLIANCE = "appliance"
PY
    cat > "$PKG/manifest/catalog.py" <<'PY'
import os


class Catalog:
    def __init__(self, root):
        self.root = root

    def names(self, kind):
        found = os.environ.get("FAKE_APPLIANCES", "web lnmp")
        return found.split()
PY
    cat > "$PKG/inspect/overlays.py" <<'PY'
def top_of(catalog, names):
    return [name for name in names if name != "web"]
PY
    cat > "$PKG/manifest/facts.py" <<'PY'
import os
from dataclasses import dataclass, field


@dataclass
class Facts:
    resolved: object = None
    problems: tuple = ()
    modes: tuple = ()
    defaults: dict = field(default_factory=dict)


def gather(root, name):
    if os.environ.get("FAKE_FACTS") == "broken":
        return Facts(problems=(f"the chain of {name} does not resolve",))
    modes = tuple(os.environ.get(
        "FAKE_MODES", "simple cloud_simple cloud_advanced").split())
    return Facts(resolved=object(), modes=modes, defaults={
        "installer": {"simple": "enabled", "cloud_simple": "enabled"},
        "wireguard": {"simple": "disabled", "cloud_simple": "enabled"},
        "odd": {"simple": "ask", "cloud_simple": "ask"},
        "nginx": {"simple": "enabled", "cloud_simple": "enabled"},
    })
PY
    cat > "$PKG/__main__.py" <<'PY'
import os
import sys

argv = sys.argv[1:]
with open(os.path.join(os.environ["BATS_TEST_TMPDIR"], "keel.argv"),
          "w") as fob:
    fob.write(" ".join(argv) + "\n")
with open(argv[argv.index("--spec") + 1]) as fob, open(os.path.join(
        os.environ["BATS_TEST_TMPDIR"], "spec.yaml"), "w") as out:
    out.write(fob.read())
root = argv[argv.index("--root") + 1]
how = os.environ.get("FAKE_KEEL", "ok")
if how == "fail":
    print("derived.firewall: refused: the ports sshd listens on are unknown")
    sys.exit(16)


def write(relative, text):
    path = os.path.join(root, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fob:
        fob.write(text)


state = "report" if how == "report" else "enforce"
policy = "accept" if how == "report" else "drop"
fence = "" if how == "nofence" else (
    "\t\tct status dnat tcp dport { 60080, 60443 } accept\n")
if how != "nomonit":
    write("etc/keel/monit/keel-manifest.conf", "# monit\n")
    write("var/lib/keel/spec/overlays.yaml", "appliance: lnmp\n")
write("var/lib/keel/firewall/state", f"{state} abc\n")
write("var/lib/keel/firewall/last-good.nft", "# copy\n")
write("etc/keel/firewall/keel-manifest.nft",
      f"#!/usr/sbin/nft -f\n# state: {state}\ntable inet keel {{\n"
      f"\tchain input {{\n\t\ttype filter hook input priority filter;"
      f" policy {policy};\n{fence}\t}}\n}}\n")
if how == "more":
    write("etc/systemd/system/multi-user.target.wants/etcd.service", "")
print("derived.firewall: write /etc/keel/firewall/keel-manifest.nft"
      " (enforce): public tcp 22, 80, 443, 12321 (mode 0600): done")
if how != "live":
    print("derived.firewall: not loaded: not the live system;"
          " keel-firewall.service loads it at boot")
print("apply --system-only: 4 change(s), 0 failed")
PY
}

fence_on() {
    ln -s /usr/lib/systemd/system/turnkey-init-fence.service \
        "$WANTS/turnkey-init-fence.service"
}

@test "the image gets the enforce ruleset, written and not loaded" {
    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    grep -qx '# state: enforce' "$ROOTFS/etc/keel/firewall/keel-manifest.nft"
    [ -f "$ROOTFS/var/lib/keel/firewall/state" ]
    [ -f "$ROOTFS/var/lib/keel/firewall/last-good.nft" ]
    [[ "$output" == *"not loaded: not the live system"* ]]
    [[ "$output" == *"keel-firewall: enforce, written for lnmp (simple)"* ]]
}

@test "keel runs the system phase only, with no network, under --root" {
    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    read -r -a args < "$BATS_TEST_TMPDIR/keel.argv"
    [ "${args[*]:0:4}" = "spec apply --system-only --skip-network" ]
    [ "${args[4]}" = "--spec" ]
    [[ "${args[5]}" != "$ROOTFS"/* ]]
    [ "${args[6]} ${args[7]}" = "--root $ROOTFS" ]
}

@test "the build spec: the appliance, the simple column and enforce" {
    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    run python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1]))
print(d["version"], d["appliance"]["name"], d["installation"]["mode"],
      d["firewall"]["state"])
print(" ".join(f"{k}={v}" for k, v in d["overlays"].items()))' \
        "$BATS_TEST_TMPDIR/spec.yaml"
    [ "${lines[0]}" = "1 lnmp simple enforce" ]
    [ "${lines[1]}" = "installer=enabled wireguard=disabled odd=disabled nginx=enabled" ]
}

@test "an appliance with no simple mode takes its first mode" {
    export FAKE_MODES="cloud_simple cloud_advanced"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    grep -qx '  mode: cloud_simple' "$BATS_TEST_TMPDIR/spec.yaml"
    grep -qx '  wireguard: enabled' "$BATS_TEST_TMPDIR/spec.yaml"
}

@test "the build spec does not stay, in the image or outside it" {
    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    read -r -a args < "$BATS_TEST_TMPDIR/keel.argv"
    [ ! -e "${args[5]}" ]
    [ ! -e "$ROOTFS/etc/keel/instance.yaml" ]
}

@test "the overlay record and the monit file of the build do not stay" {
    # a preseeded spec that leaves an overlay out would fail at the first
    # boot against a record of the build
    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/var/lib/keel/spec" ]
    [ ! -e "$ROOTFS/etc/keel/monit" ]
}

@test "an overlay record and a monit file that were there stay" {
    mkdir -p "$ROOTFS/var/lib/keel/spec" "$ROOTFS/etc/keel/monit"
    echo before > "$ROOTFS/var/lib/keel/spec/overlays.yaml"
    echo before > "$ROOTFS/etc/keel/monit/keel-manifest.conf"
    touch -d '2026-01-01' "$ROOTFS/var/lib/keel/spec/overlays.yaml" \
        "$ROOTFS/etc/keel/monit/keel-manifest.conf"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ -e "$ROOTFS/var/lib/keel/spec/overlays.yaml" ]
    [ -e "$ROOTFS/etc/keel/monit/keel-manifest.conf" ]
}

@test "a keel that writes no monit file and no record passes" {
    export FAKE_KEEL=nomonit

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
}

@test "nftables.service is disabled in the image" {
    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = \
        "systemctl --root=$ROOTFS disable nftables.service" ]
}

@test "an image with no nftables unit asks systemctl nothing" {
    rm "$ROOTFS/usr/lib/systemd/system/nftables.service"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
}

@test "a systemctl that fails fails the build" {
    export FAKE_SYSTEMCTL=1

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -ne 0 ]
}

@test "with the init fence enabled, the ruleset accepts its redirected ports" {
    fence_on

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
}

@test "with the init fence enabled, a ruleset with no fence rule fails" {
    fence_on
    export FAKE_KEEL=nofence

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the fence page would not answer"* ]]
}

@test "with no init fence, a ruleset with no fence rule passes" {
    export FAKE_KEEL=nofence

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
}

@test "an image with no keel gets no firewall, and the build goes on" {
    rm -r "$PKG"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [[ "$output" == *"no keel in the image"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/keel.argv" ]
}

@test "a keel older than 0.23.100 fails the build" {
    keel_version 0.23.97

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"keel 0.23.97 is in the image"* ]]
    [[ "$output" == *"KEEL_APT_TRACK=testing"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/keel.argv" ]
}

@test "a keel with no version in dpkg's status fails the build" {
    : > "$ROOTFS/var/lib/dpkg/status"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the version of keel in the image is not known"* ]]
}

@test "a keel-firewall.service that is not enabled fails the build" {
    rm "$WANTS/keel-firewall.service"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-firewall.service is not enabled"* ]]
}

@test "not one appliance at the top of the chain fails the build" {
    export FAKE_APPLIANCES="lnmp lnpp"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"lnmp lnpp"* ]]
}

@test "no appliance manifest fails the build" {
    export FAKE_APPLIANCES="web"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"no appliance manifest"* ]]
}

@test "a chain that does not resolve fails the build" {
    export FAKE_FACTS=broken

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the chain of lnmp does not resolve"* ]]
}

@test "an apply that fails fails the build, and says keel's lines" {
    export FAKE_KEEL=fail

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the ports sshd listens on are unknown"* ]]
    [[ "$output" == *"keel spec apply failed"* ]]
}

@test "an apply that did not say 'not loaded' fails the build" {
    export FAKE_KEEL=live

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"did not say that it left the ruleset unloaded"* ]]
}

@test "a ruleset that is not enforce with a drop policy fails the build" {
    export FAKE_KEEL=report

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"not in enforce with a drop policy"* ]]
}

@test "a change of keel outside the firewall fails the build, named" {
    export FAKE_KEEL=more

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output" == *"etc/systemd/system/multi-user.target.wants/etcd.service"* ]]
}

@test "the tree / is refused: keel would treat it as the live system" {
    run "$SCRIPT" /

    [ "$status" -eq 1 ]
    [[ "$output" == *"the image tree is /"* ]]
}

@test "no argument, or one that is not a directory, is a usage error" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: keel-firewall ROOTFS"* ]]

    run "$SCRIPT" "$BATS_TEST_TMPDIR/nowhere"
    [ "$status" -eq 1 ]
}
