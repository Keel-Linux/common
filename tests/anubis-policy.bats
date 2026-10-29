#!/usr/bin/env bats
# Tests for the Anubis policy of Keel Web (packages/anubis/keel-policy.yaml
# and the drop-in directory, handbook decision 0062): appliance drop-ins
# come before upstream's default policy, the first rule that matches wins,
# and the placeholder keeps the glob from matching nothing, which is fatal
# at the startup of Anubis.
#
# Nothing here runs Anubis: the files are YAML, and the assertions are about
# their order and their shape. tests/overlay-web.bats starts Anubis with
# the policy, and the boot test of an appliance with the anubis overlay on
# loads it on a machine.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PKG="$TESTS_DIR/../packages/anubis"
}

# bots YAML: the rules of a policy file (a map with a bots list) or of an
# imported file (a plain list), as python reads them
bots() {
    python3 - "$1" <<'PY'
import sys, yaml

with open(sys.argv[1]) as handle:
    doc = yaml.safe_load(handle)
for bot in doc["bots"] if isinstance(doc, dict) else doc:
    if "import" in bot:
        print("import", bot["import"])
    else:
        print("rule", bot.get("name"), bot.get("action"))
PY
}

@test "the policy imports the drop-in directory first" {
    mapfile -t list < <(bots "$PKG/keel-policy.yaml")

    [ "${list[0]}" = "import /etc/anubis/keel.d/*.yaml" ]
}

@test "the policy imports upstream's default rules after the drop-ins" {
    mapfile -t list < <(bots "$PKG/keel-policy.yaml")

    # Anubis reads an imported file as a list of rules, so the policy file
    # botPolicies.yaml cannot be imported; this is its list of rules.
    [ "${list[1]}" = "import (data)/meta/default-config.yaml" ]
}

@test "the policy keeps the thresholds and status codes of upstream's default" {
    python3 - "$PKG/keel-policy.yaml" <<'PY'
import sys, yaml

with open(sys.argv[1]) as handle:
    doc = yaml.safe_load(handle)
names = [t["name"] for t in doc["thresholds"]]
assert names == ["minimal-suspicion", "mild-suspicion", "moderate-suspicion",
                 "mild-proof-of-work", "extreme-suspicion"], names
assert doc["status_codes"] == {"CHALLENGE": 200, "DENY": 200}
assert doc["store"]["backend"] == "memory"
assert doc["dnsbl"] is False
PY
}

@test "the placeholder is a list of rules, not a policy" {
    python3 - "$PKG/keel.d/keel-placeholder.yaml" <<'PY'
import sys, yaml

with open(sys.argv[1]) as handle:
    assert isinstance(yaml.safe_load(handle), list)
PY
}

@test "the policy holds nothing but the two imports" {
    mapfile -t list < <(bots "$PKG/keel-policy.yaml")

    [ "${#list[@]}" -eq 2 ]
}

@test "the placeholder rule matches nothing and allows" {
    mapfile -t list < <(bots "$PKG/keel.d/keel-placeholder.yaml")

    [ "${list[0]}" = "rule keel-placeholder ALLOW" ]
    regex=$(python3 - "$PKG/keel.d/keel-placeholder.yaml" <<'PY'
import sys, yaml

with open(sys.argv[1]) as handle:
    doc = yaml.safe_load(handle)
print(doc[0]["user_agent_regex"])
PY
)
    # 'a^' cannot match: a literal "a" and then start-of-string.
    [ "$regex" = 'a^' ]
    [[ ! "Nextcloud-android/3.30.0" =~ $regex ]]
    [[ ! "Mozilla/5.0" =~ $regex ]]
    [[ ! "" =~ $regex ]]
}

@test "keel.env points anubis at the keel policy" {
    grep -qx 'POLICY_FNAME=/etc/anubis/keel-policy.yaml' "$PKG/keel.env"
}

@test "debian/rules installs the policy and the placeholder" {
    grep -q 'keel-policy.yaml \$(PKG)/etc/anubis/keel-policy.yaml' \
        "$PKG/debian/rules"
    grep -q 'keel-placeholder.yaml' "$PKG/debian/rules"
}

@test "the changelog records the drop-in mechanism" {
    grep -q '0062' "$PKG/debian/changelog"
}
