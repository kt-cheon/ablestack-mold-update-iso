#!/bin/bash
set -euo pipefail

# ISO의 위치를 기준으로 동작하며 ISO에는 파일을 쓰지 않는다.
HOST_PACKAGES=(cloudstack-common cloudstack-agent)
CCVM_PACKAGES=(cloudstack-common cloudstack-management cloudstack-usage cloudstack-ui)

LOGFILE="${LOGFILE:-/var/log/ablestack-mold-update.log}"
CCVM_HOST="${CCVM_HOST:-ccvm}"
CCVM_RESOURCE_ID=cloudcenter_res
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10
          -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
RPM_QUERY_FORMAT='%{NAME}|%{EPOCHNUM}:%{VERSION}-%{RELEASE}|%{ARCH}\n'
STATE_DIR=/var/lib/ablestack-mold-update
ROLE=host
CHECK_ONLY=0
ISO_ROOT=""
RPM_DIR=""
PKG_MGR=""
RPM_CMD=""
REMOTE_DIR=""
RUNNING_CCVM=0
NEEDS_UPDATE=0
TARGET_PACKAGES=()
TARGET_RPMS=()
RESOLVED_RPMS=()
CCVM_RPMS=()

usage() {
    cat <<'EOF'
사용법: bash /마운트경로/update-mold.sh [--check] [--role host|ccvm]

  기본 동작       현재 호스트와 이 호스트에서 실행 중인 ccvm 업데이트
  --check         RPM/설치 상태/의존성 확인만 수행 (설치 및 서비스 재시작 없음)
  --role ccvm     현재 머신의 CCVM 패키지만 처리 (원격 실행 시 내부 사용)
  -h, --help      도움말

RPM 경로: 스크립트 옆 rpms/ 또는 AppStream/Packages/mold/ 또는 스크립트 옆
패키지별로 설치할 RPM을 하나씩 포함해야 합니다. 외부 저장소는 사용하지 않습니다.
CCVM_HOST 환경변수로 SSH 대상을 지정할 수 있습니다 (기본값: ccvm).
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check) CHECK_ONLY=1; shift ;;
            --role)
                [ "$#" -ge 2 ] || { echo '--role 값이 필요합니다.' >&2; exit 2; }
                ROLE="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "알 수 없는 인자: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
    case "$ROLE" in host|ccvm) ;; *) echo "지원하지 않는 역할: $ROLE" >&2; exit 2 ;; esac
    case "$CCVM_HOST" in
        ''|*[!a-zA-Z0-9._:-]*) echo "잘못된 CCVM_HOST: $CCVM_HOST" >&2; exit 2 ;;
    esac
}

log() {
    local line
    line="[$(date '+%F %T')] [$ROLE] $*"
    echo "$line"
    echo "$line" >&3
}

fail() { log "ERROR: $*"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || { echo 'root로 실행해야 합니다.' >&2; exit 1; }
}

init_logging() {
    exec 3>&1
    exec >> "$LOGFILE" 2>&1
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || fail 'flock 명령을 찾을 수 없습니다.'
    exec 9>/run/lock/ablestack-mold-update.lock
    flock -n 9 || fail '이 머신에서 다른 Mold 업데이트가 실행 중입니다.'
}

cleanup() {
    local rc=$?
    trap - EXIT
    if [ -n "$REMOTE_DIR" ]; then
        ssh "${SSH_OPTS[@]}" "root@$CCVM_HOST" "rm -rf -- '$REMOTE_DIR'" ||
            log "CCVM 임시 파일 정리 실패: $REMOTE_DIR"
    fi
    if [ "$rc" -ne 0 ]; then
        log "업데이트 중단 (종료 코드 $rc). 로그: $LOGFILE"
    fi
    exit "$rc"
}

run_with_progress() {
    local label="$1" pid rc i=0
    local spinner='|/-\'
    shift
    log "$label 시작"
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r%s %c' "$label" "${spinner:i%${#spinner}:1}" >&3
        sleep 1
        i=$((i + 1))
    done
    if wait "$pid"; then rc=0; else rc=$?; fi
    printf '\r%*s\r' 100 '' >&3
    if [ "$rc" -eq 0 ]; then log "$label 완료"; else log "$label 실패 ($rc)"; fi
    return "$rc"
}

detect_iso_root() {
    ISO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    if [ -d "$ISO_ROOT/rpms" ]; then
        RPM_DIR="$ISO_ROOT/rpms"
    elif [ -d "$ISO_ROOT/AppStream/Packages/mold" ]; then
        RPM_DIR="$ISO_ROOT/AppStream/Packages/mold"
    else
        RPM_DIR="$ISO_ROOT"
    fi
    log "ISO 위치: $ISO_ROOT / RPM 위치: $RPM_DIR"
}

detect_pkg_commands() {
    local cmd
    for cmd in aspm dnf; do
        if command -v "$cmd" >/dev/null 2>&1 && "$cmd" --version >/dev/null 2>&1; then
            PKG_MGR="$cmd"; break
        fi
    done
    for cmd in aspkg rpm; do
        if command -v "$cmd" >/dev/null 2>&1 && "$cmd" --version >/dev/null 2>&1; then
            RPM_CMD="$cmd"; break
        fi
    done
    [ -n "$PKG_MGR" ] || fail '사용 가능한 dnf/aspm이 없습니다.'
    [ -n "$RPM_CMD" ] || fail '사용 가능한 rpm/aspkg가 없습니다.'
    log "패키지 도구: $PKG_MGR / $RPM_CMD"
}

resolve_rpms() {
    local pkg path name selected count
    RESOLVED_RPMS=()
    for pkg in "$@"; do
        selected=""
        count=0
        while IFS= read -r -d '' path; do
            name="$("$RPM_CMD" -qp --qf '%{NAME}' -- "$path")" || fail "RPM 읽기 실패: $path"
            [ "$name" = "$pkg" ] || continue
            selected="$path"
            count=$((count + 1))
        done < <(find "$RPM_DIR" -type f -name '*.rpm' -print0)
        [ "$count" -gt 0 ] || fail "$pkg RPM을 찾지 못했습니다: $RPM_DIR"
        [ "$count" -eq 1 ] || fail "$pkg RPM이 $count 개입니다. 패키지별로 한 버전/아키텍처만 넣으세요."
        RESOLVED_RPMS+=("$selected")
        log "RPM 선택: $pkg -> $selected"
    done
}

detect_ccvm() {
    local domains state cluster_status owner local_nodes
    RUNNING_CCVM=0
    [ "$ROLE" = host ] || return 0
    if command -v pcs >/dev/null 2>&1; then
        if cluster_status="$(LC_ALL=C pcs status --full)"; then
            owner="$(printf '%s\n' "$cluster_status" | awk -v resource="$CCVM_RESOURCE_ID" '
                {
                    for (i=1; i+3<=NF; i++) {
                        if ($i == resource && $(i+1) ~ /^\(ocf:/ && $(i+2) == "Started") {
                            print $(i+3); exit
                        }
                    }
                }')"
            if [ -z "$owner" ]; then
                log "$CCVM_RESOURCE_ID 실행 노드 없음: CCVM은 생략하고 호스트 업데이트를 계속합니다."
                return 0
            fi
            local_nodes="$(
                crm_node -n 2>/dev/null || true
                hostname -s 2>/dev/null || true
                hostname -f 2>/dev/null || true
                uname -n
            )"
            if ! printf '%s\n' "$local_nodes" | grep -Fxq -- "$owner"; then
                log "$CCVM_RESOURCE_ID 는 다른 호스트($owner)에서 실행 중: CCVM 업데이트 생략"
                return 0
            fi
            log "$CCVM_RESOURCE_ID 가 현재 호스트($owner)에서 실행 중입니다."
        else
            log 'PCS 상태 조회 실패: 로컬 libvirt의 CCVM 실행 상태로 확인합니다.'
        fi
    fi
    if ! command -v virsh >/dev/null 2>&1; then
        log 'virsh 없음: 현재 호스트만 업데이트합니다.'
        return 0
    fi
    domains="$(LC_ALL=C virsh -c qemu:///system list --all --name)" || fail '로컬 VM 목록 조회 실패'
    if ! printf '%s\n' "$domains" | grep -Fxq ccvm; then
        log '이 호스트에 ccvm 없음: 현재 호스트만 업데이트합니다.'
        return 0
    fi
    state="$(LC_ALL=C virsh -c qemu:///system domstate ccvm)" || fail 'ccvm 상태 조회 실패'
    if [ "$state" = running ]; then
        RUNNING_CCVM=1
        log "이 호스트에서 ccvm 실행 중: SSH 대상 $CCVM_HOST"
    else
        log "이 호스트의 ccvm 상태: $state. CCVM 단계를 생략합니다."
    fi
}

preflight_local() {
    local i pkg installed expected
    NEEDS_UPDATE=0
    for ((i=0; i<${#TARGET_PACKAGES[@]}; i++)); do
        pkg="${TARGET_PACKAGES[i]}"
        installed="$("$RPM_CMD" -q --qf "$RPM_QUERY_FORMAT" -- "$pkg")" ||
            fail "$pkg 패키지가 설치되어 있지 않습니다."
        expected="$("$RPM_CMD" -qp --qf "$RPM_QUERY_FORMAT" -- "${TARGET_RPMS[i]}")" ||
            fail "RPM 메타데이터 읽기 실패: ${TARGET_RPMS[i]}"
        log "설치됨: $installed / ISO: $expected"
        if [ "$installed" != "$expected" ]; then NEEDS_UPDATE=1; fi
    done
    if [ "$NEEDS_UPDATE" -eq 1 ]; then
        # --replacepkgs는 검사에서 같은 버전도 허용한다. 다운그레이드는 허용하지 않는다.
        run_with_progress 'RPM 의존성/충돌/아키텍처 검사' \
            "$RPM_CMD" -U --test --replacepkgs -- "${TARGET_RPMS[@]}"
    else
        log '모든 대상 RPM이 ISO 버전과 같습니다.'
    fi
}

verify_installed() {
    local i installed expected
    for ((i=0; i<${#TARGET_PACKAGES[@]}; i++)); do
        installed="$("$RPM_CMD" -q --qf "$RPM_QUERY_FORMAT" -- "${TARGET_PACKAGES[i]}")" ||
            fail "설치 확인 실패: ${TARGET_PACKAGES[i]}"
        expected="$("$RPM_CMD" -qp --qf "$RPM_QUERY_FORMAT" -- "${TARGET_RPMS[i]}")" ||
            fail "RPM 확인 실패: ${TARGET_RPMS[i]}"
        [ "$installed" = "$expected" ] || fail "설치 결과가 ISO와 다릅니다: $installed / $expected"
    done
}

update_local() {
    local service pending
    if [ "$ROLE" = host ]; then service=mold-agent; else service=mold; fi
    pending="$STATE_DIR/$ROLE.restart-pending"
    if [ "$NEEDS_UPDATE" -eq 1 ]; then
        mkdir -p "$STATE_DIR"
        touch "$pending"
        run_with_progress 'Mold RPM 업데이트' "$PKG_MGR" -y --disablerepo='*' \
            --nogpgcheck --setopt=install_weak_deps=False upgrade "${TARGET_RPMS[@]}"
        verify_installed
    fi
    if [ "$NEEDS_UPDATE" -eq 1 ] || [ -f "$pending" ] || ! systemctl is-active --quiet "$service"; then
        run_with_progress "$service 서비스 재시작" systemctl restart "$service"
        systemctl is-active --quiet "$service" || fail "$service 서비스가 활성 상태가 아닙니다."
        rm -f "$pending"
    else
        log "$service 정상 동작 중: 재시작 생략"
    fi
    log '로컬 RPM 및 서비스 확인 완료'
}

prepare_ccvm() {
    local cmd remote_dir
    for cmd in ssh scp; do command -v "$cmd" >/dev/null 2>&1 || fail "$cmd 명령이 필요합니다."; done
    resolve_rpms "${CCVM_PACKAGES[@]}"
    CCVM_RPMS=("${RESOLVED_RPMS[@]}")
    # 실행마다 별도 경로를 사용하므로 다른 호스트의 복사 작업과 충돌하지 않는다.
    remote_dir="$(ssh "${SSH_OPTS[@]}" "root@$CCVM_HOST" \
        'mktemp -d /var/tmp/ablestack-mold-update.XXXXXXXX')" || fail 'CCVM SSH 연결/임시 경로 생성 실패'
    [[ "$remote_dir" =~ ^/var/tmp/ablestack-mold-update\.[a-zA-Z0-9]+$ ]] || fail 'CCVM 임시 경로가 잘못되었습니다.'
    REMOTE_DIR="$remote_dir"
    run_with_progress 'CCVM 스크립트/RPM 복사' scp "${SSH_OPTS[@]}" \
        "$ISO_ROOT/update-mold.sh" "${CCVM_RPMS[@]}" "root@$CCVM_HOST:$REMOTE_DIR/"
    run_with_progress 'CCVM 사전 검사' ssh "${SSH_OPTS[@]}" "root@$CCVM_HOST" \
        "bash '$REMOTE_DIR/update-mold.sh' --role ccvm --check"
}

main() {
    parse_args "$@"
    require_root
    init_logging
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    acquire_lock
    detect_iso_root
    detect_pkg_commands
    command -v systemctl >/dev/null 2>&1 || fail 'systemctl 명령을 찾을 수 없습니다.'
    if [ "$ROLE" = host ]; then
        TARGET_PACKAGES=("${HOST_PACKAGES[@]}")
    else
        TARGET_PACKAGES=("${CCVM_PACKAGES[@]}")
    fi
    resolve_rpms "${TARGET_PACKAGES[@]}"
    TARGET_RPMS=("${RESOLVED_RPMS[@]}")
    detect_ccvm
    preflight_local
    if [ "$RUNNING_CCVM" -eq 1 ]; then prepare_ccvm; fi
    if [ "$CHECK_ONLY" -eq 1 ]; then
        log '사전 검사 완료. RPM 설치 및 서비스 재시작은 수행하지 않았습니다.'
        return 0
    fi
    if [ "$RUNNING_CCVM" -eq 1 ]; then
        # 복사/검사 중 리소스가 다른 호스트로 이동했다면 정상적으로 생략한다.
        detect_ccvm
        if [ "$RUNNING_CCVM" -eq 1 ]; then
            run_with_progress 'CCVM 업데이트' ssh "${SSH_OPTS[@]}" "root@$CCVM_HOST" \
                "bash '$REMOTE_DIR/update-mold.sh' --role ccvm"
        fi
    fi
    update_local
    log "업데이트 완료: $ROLE (CCVM 처리: $RUNNING_CCVM). 로그: $LOGFILE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
