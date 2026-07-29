#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/tests/lib/lifecycle.sh"
machstrap_test_log_init linux-vm
OS_VERSION=
SUDO_MODE=
SCENARIO=linux-full
while (( $# )); do
    case "$1" in
        --os) [[ $# -ge 2 ]] || exit 2; OS_VERSION=$2; shift 2 ;;
        --sudo) [[ $# -ge 2 ]] || exit 2; SUDO_MODE=$2; shift 2 ;;
        --scenario) [[ $# -ge 2 ]] || exit 2; SCENARIO=$2; shift 2 ;;
        *) printf 'unknown Linux E2E option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

case "$OS_VERSION" in 22.04|24.04) ;; *) printf -- '--os must be 22.04 or 24.04\n' >&2; exit 2 ;; esac
case "$SUDO_MODE" in passwordless|password) ;; *) printf -- '--sudo must be passwordless or password\n' >&2; exit 2 ;; esac
[[ "$SCENARIO" == linux-full || "$SCENARIO" == external-services ]] || {
    printf 'unsupported Linux E2E scenario: %s\n' "$SCENARIO" >&2
    exit 2
}

for command_name in virsh virt-install qemu-img cloud-localds expect ssh ssh-keygen ssh-keyscan; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'required Linux E2E command is missing: %s\n' "$command_name" >&2
        exit 2
    }
done
if [[ "$SCENARIO" == external-services ]]; then
    for required_name in GH_TOKEN MACHSTRAP_E2E_GH_REPO; do
        [[ -n "${!required_name:-}" ]] || {
            printf '%s is required for the external-services canary\n' "$required_name" >&2
            exit 2
        }
    done
    command -v gh >/dev/null 2>&1 || {
        printf 'gh is required for the external-services canary\n' >&2
        exit 2
    }
    gh auth status >/dev/null
fi

RUN_TOKEN="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"
RUN_TOKEN="$(printf '%s' "$RUN_TOKEN" | tr -cd 'a-zA-Z0-9-' | cut -c1-28)"
SUT_NAME="ms-sut-$RUN_TOKEN"
PROBE_NAME="ms-probe-$RUN_TOKEN"
MGMT_NET="ms76-$(printf '%s' "$RUN_TOKEN" | shasum | cut -c1-6)"
TEST_NET="ms77-$(printf '%s' "$RUN_TOKEN" | shasum | cut -c1-6)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/machstrap-vm.XXXXXX")"
ARTIFACT_DIR="${MACHSTRAP_E2E_ARTIFACT_DIR:-$TEST_TMP/artifacts}"
IMAGE_DIR="${MACHSTRAP_E2E_IMAGE_DIR:-${HOME:?}/.cache/machstrap-e2e/images}"
CANARY_KEY_TITLE=
mkdir -p "$ARTIFACT_DIR"

cleanup_canary_key() {
    [[ "$SCENARIO" == external-services && -n "${GH_TOKEN:-}" ]] || return 0
    if [[ -z "$CANARY_KEY_TITLE" &&
        -f "$TEST_TMP/controller" && -s "$TEST_TMP/known_hosts" ]]; then
        cleanup_fingerprint="$(ssh \
            -i "$TEST_TMP/controller" \
            -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="$TEST_TMP/known_hosts" \
            -o ConnectTimeout=3 \
            cc@192.168.76.10 \
            'test -f ~/.ssh/id_ed25519.pub && ssh-keygen -lf ~/.ssh/id_ed25519.pub' \
            2>/dev/null | awk '{print $2}')"
        [[ -z "$cleanup_fingerprint" ]] ||
            CANARY_KEY_TITLE="machstrap machstrap-e2e $cleanup_fingerprint"
    fi
    [[ -n "$CANARY_KEY_TITLE" ]] || return 0
    while IFS=$'\t' read -r key_id key_title; do
        [[ "$key_title" == "$CANARY_KEY_TITLE" ]] || continue
        gh api --method DELETE "user/keys/$key_id"
    done < <(gh api user/keys --paginate --jq '.[] | [.id, .title] | @tsv')
}

cleanup() {
    status=$?
    cleanup_failed=0
    trap - EXIT INT TERM
    set +e
    machstrap_test_log "teardown starting: VMs=$SUT_NAME,$PROBE_NAME networks=$MGMT_NET,$TEST_NET"
    cleanup_canary_key || cleanup_failed=1
    for domain_name in "$SUT_NAME" "$PROBE_NAME"; do
        if virsh dominfo "$domain_name" >/dev/null 2>&1; then
            machstrap_test_log "destroying and undefining libvirt VM $domain_name"
            virsh destroy "$domain_name" >/dev/null 2>&1 || true
            virsh undefine "$domain_name" --nvram >/dev/null 2>&1 ||
                virsh undefine "$domain_name" >/dev/null 2>&1 || cleanup_failed=1
        fi
        if virsh dominfo "$domain_name" >/dev/null 2>&1; then
            machstrap_test_log "ERROR: libvirt VM remains: $domain_name"
            cleanup_failed=1
        fi
    done
    for network_name in "$MGMT_NET" "$TEST_NET"; do
        if virsh net-info "$network_name" >/dev/null 2>&1; then
            machstrap_test_log "destroying libvirt network $network_name"
            virsh net-destroy "$network_name" >/dev/null 2>&1 || true
            virsh net-undefine "$network_name" >/dev/null 2>&1 || true
        fi
        if virsh net-info "$network_name" >/dev/null 2>&1; then
            machstrap_test_log "ERROR: libvirt network remains: $network_name"
            cleanup_failed=1
        fi
    done
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        cp -R "$TEST_TMP/logs/." "$ARTIFACT_DIR/" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$TEST_TMP"
    machstrap_test_log "teardown complete: VMs, networks, overlays, and seed media removed"
    if (( status == 0 && cleanup_failed != 0 )); then
        exit 1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TEST_TMP/logs"
printf 'machstrap-test-password\n' >"$TEST_TMP/sudo-password"
chmod 0600 "$TEST_TMP/sudo-password"

machstrap_test_log "starting Linux VM scenario=$SCENARIO Ubuntu=$OS_VERSION sudo=$SUDO_MODE"
image_filename="ubuntu-$OS_VERSION-amd64.img"
base_image="$IMAGE_DIR/$image_filename"
expected_sha="$(awk -F '\t' -v os="ubuntu-$OS_VERSION" '$1 == os { print $3 }' \
    "$REPO_ROOT/tests/e2e/images.lock")"
[[ -f "$base_image" && -n "$expected_sha" ]] || {
    printf 'missing pinned image; run tests/e2e/prepare-images.sh\n' >&2
    exit 2
}
printf '%s  %s\n' "$expected_sha" "$base_image" | shasum -a 256 -c -

machstrap_test_log "creating run-specific libvirt networks $MGMT_NET and $TEST_NET"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_TMP/controller"
public_key="$(sed -n '1p' "$TEST_TMP/controller.pub")"
case "$SUDO_MODE" in
    passwordless) sudo_rule='cc ALL=(root) NOPASSWD: ALL' ;;
    password) sudo_rule='cc ALL=(root) ALL' ;;
esac

render_cloud_init() {
    local hostname=$1 destination=$2 rule=$3
    sed \
        -e "s|__HOSTNAME__|$hostname|g" \
        -e "s|__PUBLIC_KEY__|$public_key|g" \
        -e "s|__SUDO_RULE__|$rule|g" \
        "$REPO_ROOT/tests/e2e/linux/cloud-init.yml" >"$destination"
}

create_network() {
    local name=$1 bridge=$2 subnet=$3 sut_ip=$4 probe_ip=$5 destination=$6
    cat >"$destination" <<EOF
<network>
  <name>$name</name>
  <bridge name='$bridge' stp='on' delay='0'/>
  <forward mode='nat'/>
  <ip address='$subnet.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='$subnet.100' end='$subnet.200'/>
      <host mac='52:54:00:76:00:10' ip='$sut_ip'/>
      <host mac='52:54:00:76:00:20' ip='$probe_ip'/>
    </dhcp>
  </ip>
</network>
EOF
    virsh net-create "$destination" >/dev/null
}

create_network "$MGMT_NET" "v76$(printf '%s' "$RUN_TOKEN" | shasum | cut -c1-6)" \
    192.168.76 192.168.76.10 192.168.76.20 "$TEST_TMP/management.xml"
create_network "$TEST_NET" "v77$(printf '%s' "$RUN_TOKEN" | shasum | cut -c1-6)" \
    192.168.77 192.168.77.10 192.168.77.20 "$TEST_TMP/test.xml"

render_cloud_init "$SUT_NAME" "$TEST_TMP/sut-user-data" "$sudo_rule"
render_cloud_init "$PROBE_NAME" "$TEST_TMP/probe-user-data" \
    'cc ALL=(root) NOPASSWD: ALL'
for guest in sut probe; do
    cat >"$TEST_TMP/$guest-meta-data" <<EOF
instance-id: $RUN_TOKEN-$guest
local-hostname: $guest
EOF
done
sed \
    -e 's|__MANAGEMENT_MAC__|52:54:00:76:00:10|g' \
    -e 's|__TEST_MAC__|52:54:00:77:00:10|g' \
    "$REPO_ROOT/tests/e2e/linux/network-config.yml" >"$TEST_TMP/sut-network"
sed \
    -e 's|__MANAGEMENT_MAC__|52:54:00:76:00:20|g' \
    -e 's|__TEST_MAC__|52:54:00:77:00:20|g' \
    "$REPO_ROOT/tests/e2e/linux/network-config.yml" >"$TEST_TMP/probe-network"

for guest in sut probe; do
    qemu-img create -q -f qcow2 -F qcow2 -b "$base_image" \
        "$TEST_TMP/$guest.qcow2" 30G
    cloud-localds --network-config="$TEST_TMP/$guest-network" \
        "$TEST_TMP/$guest-seed.iso" \
        "$TEST_TMP/$guest-user-data" "$TEST_TMP/$guest-meta-data"
done

machstrap_test_log "starting disposable libvirt VMs $SUT_NAME and $PROBE_NAME"
os_variant="ubuntu${OS_VERSION/./}"
virt-install --connect qemu:///system --name "$SUT_NAME" \
    --memory 6144 --vcpus 4 --import --noautoconsole \
    --os-variant "$os_variant" \
    --disk "path=$TEST_TMP/sut.qcow2,bus=virtio" \
    --disk "path=$TEST_TMP/sut-seed.iso,device=cdrom" \
    --network "network=$MGMT_NET,mac=52:54:00:76:00:10,model=virtio" \
    --network "network=$TEST_NET,mac=52:54:00:77:00:10,model=virtio"
virt-install --connect qemu:///system --name "$PROBE_NAME" \
    --memory 2048 --vcpus 2 --import --noautoconsole \
    --os-variant "$os_variant" \
    --disk "path=$TEST_TMP/probe.qcow2,bus=virtio" \
    --disk "path=$TEST_TMP/probe-seed.iso,device=cdrom" \
    --network "network=$MGMT_NET,mac=52:54:00:76:00:20,model=virtio" \
    --network "network=$TEST_NET,mac=52:54:00:77:00:20,model=virtio"

ssh_common=(-i "$TEST_TMP/controller" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$TEST_TMP/known_hosts" -o ConnectTimeout=5)
machstrap_test_log "waiting for cloud-init and SSH on both disposable VMs"
for attempt in $(seq 1 120); do
    if ssh-keyscan 192.168.76.10 192.168.76.20 >"$TEST_TMP/known_hosts" 2>/dev/null &&
        ssh "${ssh_common[@]}" cc@192.168.76.10 true >/dev/null 2>&1 &&
        ssh "${ssh_common[@]}" cc@192.168.76.20 true >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
ssh "${ssh_common[@]}" cc@192.168.76.10 cloud-init status --wait |
    tee "$TEST_TMP/logs/sut-cloud-init"
ssh "${ssh_common[@]}" cc@192.168.76.20 cloud-init status --wait |
    tee "$TEST_TMP/logs/probe-cloud-init"

ssh "${ssh_common[@]}" cc@192.168.76.20 \
    'sudo apt-get update && sudo apt-get install -y wireguard'
ssh "${ssh_common[@]}" cc@192.168.76.20 \
    "umask 077; wg genkey > /home/cc/probe.key; wg pubkey < /home/cc/probe.key" \
    >"$TEST_TMP/probe.pub"
peer_public_key="$(tr -d '\r\n' <"$TEST_TMP/probe.pub")"

cat >"$TEST_TMP/inventory.yml" <<EOF
all:
  hosts:
    machstrap-e2e:
      ansible_host: 192.168.76.10
      ansible_user: cc
      ansible_port: 22
      controller_public_key: "$public_key"
      wireguard_peer_public_key: "$peer_public_key"
      github_canary_repo: "${MACHSTRAP_E2E_GH_REPO:-}"
EOF
cat >"$TEST_TMP/ssh_config" <<EOF
Host machstrap-e2e
    HostName 192.168.76.10
    User cc
    Port 22
    IdentityFile $TEST_TMP/controller
    IdentitiesOnly yes
    UserKnownHostsFile $TEST_TMP/known_hosts
    StrictHostKeyChecking yes
EOF

profile="$REPO_ROOT/tests/e2e/linux/profile"
[[ "$SCENARIO" != external-services ]] ||
    profile="$REPO_ROOT/tests/e2e/linux/canary"
run_machstrap() {
    local output=$1
    shift
    if [[ "$SUDO_MODE" == password ]]; then
        cat >"$TEST_TMP/invoke.sh" <<EOF
#!/usr/bin/env bash
exec "$REPO_ROOT/machstrap" "$@" "$profile" \
  --inventory "$TEST_TMP/inventory.yml" --limit machstrap-e2e \
  --ssh-config "$TEST_TMP/ssh_config" --ask-sudo-pass
EOF
        chmod 0700 "$TEST_TMP/invoke.sh"
        expect "$REPO_ROOT/tests/lib/pty-run.exp" \
            'BECOME password:' \
            "$TEST_TMP/sudo-password" \
            "$TEST_TMP/invoke.sh" |
            tee "$output"
    else
        "$REPO_ROOT/machstrap" "$@" "$profile" \
            --inventory "$TEST_TMP/inventory.yml" --limit machstrap-e2e \
            --ssh-config "$TEST_TMP/ssh_config" | tee "$output"
    fi
}

if [[ "$SCENARIO" == external-services ]]; then
    machstrap_test_log "running external GitHub, Snap Store, and Plex registry assertions"
    cat >"$TEST_TMP/canary-invoke.sh" <<EOF
#!/usr/bin/env bash
exec "$REPO_ROOT/machstrap" apply "$profile" \
  --inventory "$TEST_TMP/inventory.yml" --limit machstrap-e2e \
  --ssh-config "$TEST_TMP/ssh_config"
EOF
    chmod 0700 "$TEST_TMP/canary-invoke.sh"
    expect "$REPO_ROOT/tests/lib/github-canary-run.exp" \
        "$TEST_TMP/canary-invoke.sh" |
        tee "$TEST_TMP/logs/canary-apply.log"
    ssh "${ssh_common[@]}" cc@192.168.76.10 \
        'test -d ~/src/github-canary/.git; snap list hello-world >/dev/null; sudo docker image inspect lscr.io/linuxserver/plex:latest >/dev/null; sudo systemctl is-active --quiet machstrap-plex'
    canary_fingerprint="$(ssh "${ssh_common[@]}" cc@192.168.76.10 \
        'ssh-keygen -lf ~/.ssh/id_ed25519.pub' | awk '{print $2}')"
    CANARY_KEY_TITLE="machstrap machstrap-e2e $canary_fingerprint"
    cleanup_canary_key
    CANARY_KEY_TITLE=
    printf 'linux-e2e: external service canary passed\n'
    exit 0
fi

machstrap_test_log "running check, dry-run, and first full apply"
run_machstrap "$TEST_TMP/logs/check.log" check
run_machstrap "$TEST_TMP/logs/dry-run.log" apply --dry-run --diff
ssh "${ssh_common[@]}" cc@192.168.76.10 \
    'test ! -e ~/.machstrap-replace && test ! -e /etc/machstrap-plex.env'
run_machstrap "$TEST_TMP/logs/first-apply.log" apply

ssh_new=(-i "$TEST_TMP/controller" -p 2222 -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$TEST_TMP/known_hosts-new" -o ConnectTimeout=5)
for attempt in $(seq 1 30); do
    ssh "${ssh_new[@]}" cc@192.168.76.10 true >/dev/null 2>&1 && break
    sleep 2
done
if [[ "$SUDO_MODE" == password ]]; then
    printf 'machstrap-test-password\n' |
        ssh "${ssh_new[@]}" cc@192.168.76.10 \
            "sudo -S -p '' sh -c 'printf \"%s\\n\" \"cc ALL=(root) NOPASSWD: ALL\" > /etc/sudoers.d/91-machstrap-e2e-verify; chmod 0440 /etc/sudoers.d/91-machstrap-e2e-verify'"
fi
ssh "${ssh_new[@]}" cc@192.168.76.10 \
    /bin/bash -s <"$REPO_ROOT/tests/e2e/linux/verify.sh"

server_public_key="$(ssh "${ssh_new[@]}" cc@192.168.76.10 \
    'sudo wg show wg0 public-key')"
probe_private_key="$(ssh "${ssh_common[@]}" cc@192.168.76.20 \
    'cat /home/cc/probe.key')"
ssh "${ssh_common[@]}" cc@192.168.76.20 "sudo tee /etc/wireguard/wg0.conf >/dev/null" <<EOF
[Interface]
Address = 10.88.0.2/24
PrivateKey = $probe_private_key
[Peer]
PublicKey = $server_public_key
AllowedIPs = 10.88.0.0/24
Endpoint = 192.168.77.10:51820
PersistentKeepalive = 5
EOF
ssh "${ssh_common[@]}" cc@192.168.76.20 \
    'sudo chmod 0600 /etc/wireguard/wg0.conf; sudo systemctl enable --now wg-quick@wg0'
ssh "${ssh_common[@]}" cc@192.168.76.20 'ping -c 3 10.88.0.1'
ssh "${ssh_common[@]}" cc@192.168.76.20 'curl --fail http://192.168.77.10/'

machstrap_test_log "running second apply and asserting zero changes"
sed 's/Port 22/Port 2222/' "$TEST_TMP/ssh_config" >"$TEST_TMP/ssh_config-second"
mv "$TEST_TMP/ssh_config-second" "$TEST_TMP/ssh_config"
run_machstrap "$TEST_TMP/logs/second-apply.log" apply
grep -q 'TOTAL: 0 changed' "$TEST_TMP/logs/second-apply.log" || {
    printf 'Linux full profile was not idempotent\n' >&2
    exit 1
}

ssh "${ssh_new[@]}" cc@192.168.76.10 \
    'sudo cat /var/log/machstrap-sudo.log' >"$TEST_TMP/logs/sudo.log"
test -s "$TEST_TMP/logs/sudo.log"
machstrap_test_log "Linux VM assertions passed"
printf 'linux-e2e: Ubuntu %s (%s sudo) passed\n' "$OS_VERSION" "$SUDO_MODE"
