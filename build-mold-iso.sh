#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PACKAGES=(cloudstack-common cloudstack-agent cloudstack-management cloudstack-usage cloudstack-ui)
RPM_SOURCE=""
OUTPUT=ablestack-mold-update.iso
WORK_DIR=""
RPM_CMD=""
ISO_TOOL=""
SELECTED_RPMS=()

usage() {
    cat <<'EOF'
사용법: bash build-mold-iso.sh --rpm-dir RPM_디렉터리 [--output 파일.iso]

필요한 RPM: cloudstack-common, cloudstack-agent, cloudstack-management,
           cloudstack-usage, cloudstack-ui (각 패키지별 한 버전/아키텍처)
필요한 도구: rpm 또는 aspkg, xorriso 또는 genisoimage 또는 mkisofs

마운트용 데이터 ISO를 생성합니다. root 권한은 필요하지 않습니다.
기존 출력 파일은 덮어쓰지 않습니다. RPM은 하위 디렉터리도 검색합니다.
EOF
}

fail() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    local rc=$?
    trap - EXIT
    if [ -n "$WORK_DIR" ]; then rm -rf -- "$WORK_DIR"; fi
    exit "$rc"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --rpm-dir|--output)
            [ "$#" -ge 2 ] || fail "$1 값이 필요합니다."
            if [ "$1" = --rpm-dir ]; then RPM_SOURCE="$2"; else OUTPUT="$2"; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "알 수 없는 인자: $1" ;;
    esac
done

[ -n "$RPM_SOURCE" ] || { usage >&2; fail '--rpm-dir를 지정하세요.'; }
[ -d "$RPM_SOURCE" ] || fail "RPM 디렉터리가 없습니다: $RPM_SOURCE"
RPM_SOURCE="$(cd "$RPM_SOURCE" && pwd -P)"
case "$OUTPUT" in *.iso) ;; *) fail '출력 파일 확장자는 .iso여야 합니다.' ;; esac
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd -P)/$(basename "$OUTPUT")"
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || fail "출력 파일이 이미 있습니다: $OUTPUT"
[ -f "$SCRIPT_DIR/update-mold.sh" ] || fail 'update-mold.sh가 필요합니다.'
[ -f "$SCRIPT_DIR/README-mold-iso.md" ] || fail 'README-mold-iso.md가 필요합니다.'
bash -n "$SCRIPT_DIR/update-mold.sh"

for cmd in aspkg rpm; do
    if command -v "$cmd" >/dev/null 2>&1 && "$cmd" --version >/dev/null 2>&1; then
        RPM_CMD="$cmd"; break
    fi
done
[ -n "$RPM_CMD" ] || fail '사용 가능한 rpm/aspkg가 없습니다. RPM을 조회할 수 있는 환경에서 빌드하세요.'
for cmd in xorriso genisoimage mkisofs; do
    if command -v "$cmd" >/dev/null 2>&1; then ISO_TOOL="$cmd"; break; fi
done
[ -n "$ISO_TOOL" ] || fail 'xorriso/genisoimage/mkisofs 중 하나가 필요합니다.'

for pkg in "${PACKAGES[@]}"; do
    selected=""
    count=0
    while IFS= read -r -d '' rpm_path; do
        name="$("$RPM_CMD" -qp --qf '%{NAME}' -- "$rpm_path")" || fail "RPM 읽기 실패: $rpm_path"
        [ "$name" = "$pkg" ] || continue
        selected="$rpm_path"
        count=$((count + 1))
    done < <(find "$RPM_SOURCE" -type f -name '*.rpm' -print0)
    [ "$count" -gt 0 ] || fail "$pkg RPM이 없습니다."
    [ "$count" -eq 1 ] || fail "$pkg RPM이 $count 개입니다. 패키지별 하나씩만 준비하세요."
    SELECTED_RPMS+=("$selected")
    echo "포함: $selected"
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mold-iso.XXXXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ISO_ROOT="$WORK_DIR/iso-root"
mkdir -p "$ISO_ROOT/rpms"
cp "$SCRIPT_DIR/update-mold.sh" "$ISO_ROOT/"
cp "$SCRIPT_DIR/README-mold-iso.md" "$ISO_ROOT/"
chmod 755 "$ISO_ROOT/update-mold.sh"
for rpm_path in "${SELECTED_RPMS[@]}"; do
    target="$ISO_ROOT/rpms/$(basename "$rpm_path")"
    [ ! -e "$target" ] || fail "서로 다른 RPM의 파일명이 같습니다: $rpm_path"
    cp "$rpm_path" "$target"
done

if [ "$ISO_TOOL" = xorriso ]; then
    xorriso -as mkisofs -r -J -V ABLESTACK_MOLD -o "$WORK_DIR/image.iso" "$ISO_ROOT"
else
    "$ISO_TOOL" -r -J -V ABLESTACK_MOLD -o "$WORK_DIR/image.iso" "$ISO_ROOT"
fi
[ -s "$WORK_DIR/image.iso" ] || fail 'ISO 파일이 생성되지 않았습니다.'
mv -n "$WORK_DIR/image.iso" "$OUTPUT"
[ ! -e "$WORK_DIR/image.iso" ] || fail "출력 경로에 파일이 생성되어 저장하지 못했습니다: $OUTPUT"
echo "ISO 생성 완료: $OUTPUT"
