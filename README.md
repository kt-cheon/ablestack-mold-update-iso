# Mold RPM 업데이트 ISO

이 ISO를 각 호스트에 마운트하고 `update/update-mold.sh`를 실행합니다. 호스트는 자신의
`cloudstack-common`, `cloudstack-agent`를 업데이트합니다. 해당 호스트에서 `ccvm`이
실행 중이면 SSH로 CCVM의 `cloudstack-common`, `cloudstack-management`,
`cloudstack-usage`, `cloudstack-ui`를 먼저 업데이트합니다.
CCVM에는 `cloudstack-agent`를 설치하거나 업데이트하지 않습니다.
새 의존성 RPM도 같은 ISO에 포함할 수 있습니다. 각 머신은 ISO의 로컬 저장소에서
자신에게 필요한 의존성을 선택해 Mold RPM과 같은 트랜잭션으로 설치합니다.

CCVM은 PCS의 `cloudcenter_res` 리소스로 전체 호스트 중 한 곳에서 실행되는 구성을
기준으로 합니다. PCS의 실행 노드가 현재 호스트인지 확인하고, 로컬 libvirt에서도
`ccvm`이 실행 중인지 확인합니다. 다른 호스트에서 실행 중이거나, 리소스/VM이 없거나
정지 상태이면 CCVM을 정상 생략합니다. 이 경우에도 호스트 업데이트는 계속하며
CCVM이 없다는 이유로 실패 코드를 반환하지 않습니다. PCS를 사용할 수 없으면
로컬 libvirt의 실행 상태로 판단합니다.

RPM 업데이트 후 호스트는 `mold-agent`, CCVM은 `mold` 서비스를 재시작하고 활성
상태를 확인합니다. OS 표시 이름 변경, dnf/rpm 차단, OS 전체 업데이트는 수행하지
않습니다. 기존 `aspm`/`aspkg`가 있으면 이를 사용하고, 없으면 `dnf`/`rpm`을 사용합니다.

## 저장소 구조

```text
ablestack-mold-update-iso/
├── build-mold-iso.sh
├── update-mold.sh
├── README.md
├── .gitignore
├── rpms/                      # Mold RPM 5개 + 필요한 의존성 RPM
├── dist/                      # 생성된 ISO
└── tests/
    └── test_mold_iso.py        # 로컬 검증용, Git 제외
```

스크립트 두 개와 이 안내 문서는 같은 디렉터리에 있어야 합니다.
`rpms/`와 `dist/`의 `.gitkeep`은 Git에서 빈 디렉터리 구조를 유지하는 파일입니다.
RPM과 ISO 파일, 로컬 검증용 `tests/`는 `.gitignore`로 제외합니다. 이 저장소는 Cockpit 플러그인과
별도로 사용할 수 있으며, ISO 빌드에 Cockpit 소스는 필요하지 않습니다.

## ISO 만들기

RPM 헤더를 조회할 수 있는 `rpm` 또는 `aspkg`와 ISO 생성 도구
`xorriso`, `genisoimage`, `mkisofs` 중 하나가 필요합니다. 빌드는 일반 사용자로 가능합니다.
추가 의존성 RPM을 포함할 때는 빌드 머신에 `createrepo_c` 또는 `createrepo`도
필요합니다. 업데이트 대상 호스트와 CCVM에는 이 도구가 필요하지 않습니다.

다섯 패키지의 배포할 RPM을 저장소의 `rpms/`에 준비합니다. 각 패키지는 대상 OS와
아키텍처에 맞는 RPM 하나씩만 넣습니다. 공통 RPM은 한 개만 있으면 됩니다.
파일명 대신 RPM 헤더의 패키지 이름을 확인하며, 누락이나 중복이 있으면 생성을 중단합니다.

필요한 의존성 RPM도 같은 `rpms/`에 넣습니다. `rpms/dependencies/`처럼 하위 폴더로
정리해도 됩니다. 의존성 RPM이 요구하는 추가 의존성까지 준비하고, 대상 호스트와
CCVM의 OS 버전 및 아키텍처에 맞는 파일을 사용하세요. 호스트와 CCVM에 필요한
RPM을 모두 포함하면 됩니다. 빌더는 필수 Mold 5종 이외의 모든 RPM을 ISO의
`deps/`로 복사하고 저장소 메타데이터를 생성합니다. 빌더가 외부에서 RPM을
다운로드하지는 않습니다. 필요한 의존성이 모두 준비되었는지는 실제 대상 머신의
`--check`로 확인합니다.

```bash
bash ./build-mold-iso.sh \
  --rpm-dir ./rpms \
  --output ./dist/ablestack-mold-update.iso
```

위 명령은 저장소 루트에서 실행합니다. `--rpm-dir`로 외부 RPM 디렉터리를 지정할
수도 있습니다. 임시 경로(`${TMPDIR:-/tmp}`)와 출력 경로에 쓰기 권한 및 여유 공간이
필요합니다. 기존 출력 파일은 덮어쓰지 않습니다.

생성되는 ISO 구조는 다음과 같습니다. 부팅용이 아닌 마운트용 데이터 ISO입니다.

```text
/
├── update/
│   └── update-mold.sh
├── README.md
├── rpms/
│   ├── cloudstack-common-<버전>.rpm
│   ├── cloudstack-agent-<버전>.rpm
│   ├── cloudstack-management-<버전>.rpm
│   ├── cloudstack-usage-<버전>.rpm
│   └── cloudstack-ui-<버전>.rpm
└── deps/                      # 추가 RPM이 있을 때만 생성
    ├── <의존성 패키지>.rpm
    └── repodata/
        └── repomd.xml         # 다른 저장소 메타데이터도 함께 생성
```

`ks/ablestack-ks.cfg`, `config/dnf-3`, `config/rpm`, BaseOS/AppStream 저장소는 필요하지
않습니다. 의존성 저장소의 `deps/repodata/`는 빌더가 생성하므로 직접 만들 필요가
없습니다. 추가 RPM이 없으면 기존 5개 RPM만 포함한 ISO를 생성합니다.
기존 ISO의 `AppStream/Packages/mold/` 배치도 지원합니다.

## 각 호스트에서 실행

각 머신에 해당 역할의 Mold 패키지는 이미 설치되어 있어야 합니다. 의존성은
이미 설치되어 있거나 ISO의 `deps/` 저장소에서 제공되어야 합니다.
외부 저장소를 모두 끄고 ISO의 의존성 저장소만 활성화합니다. 이 저장소에 있는
RPM을 일괄 설치하지 않고, 각 역할의 Mold 패키지가 요구하는 것만 설치하거나
필요한 버전으로 업데이트합니다. 필수 Mold 5종은 의존성 저장소 후보에서 제외하므로
호스트에 관리 서버 패키지를 설치하거나 CCVM에 agent를 설치하지 않습니다.

설치 전에 RPM의 버전/충돌/아키텍처를 확인하고, 의존성 저장소가 있으면 DNF의
테스트 트랜잭션으로 의존성 해석과 전체 RPM 트랜잭션도 검사합니다. 누락된 의존성,
충돌, 잘못된 아키텍처, Mold RPM 다운그레이드는 설치 전에 중단됩니다.
`--check`에서도 의존성 RPM을 실제로 설치하거나 서비스를 재시작하지 않습니다.
`deps/`가 없는 기존 ISO는 기존 방식으로 설치된 의존성을 검사합니다.

CCVM 실행 호스트에서는 `ssh`와 `scp`, CCVM에 비밀번호 없이 접속할 수 있는 root SSH
키가 필요합니다. 기본 SSH 대상 이름은 `ccvm`이며 실제 실행 중인 CCVM을 가리켜야
합니다. 이름 대신 IP를 쓰려면 `CCVM_HOST=192.0.2.10 bash ...`로 실행합니다.
처음 접속하는 호스트 키는 등록하며, 기존 키가 바뀌면 SSH가 연결을 거부합니다.

root 셸에서 실행합니다.

```bash
mkdir -p /mnt/mold-update
mount -o loop,ro /data/ablestack-mold-update.iso /mnt/mold-update

# 선택: RPM 설치와 서비스 재시작 없이 사전 검사
bash /mnt/mold-update/update/update-mold.sh --check

# 업데이트
bash /mnt/mold-update/update/update-mold.sh

umount /mnt/mold-update
```

가상 CD-ROM으로 연결했다면 마운트 명령은 다음과 같습니다.

```bash
mount -o ro /dev/sr0 /mnt/mold-update
```

ISO가 읽기 전용이거나 `noexec`로 마운트되어 있어도 `bash`로 실행할 수 있습니다.
현재 작업 디렉터리와 무관하게 `update/`의 상위 디렉터리인 ISO 루트에서 RPM을 찾습니다.

## Cockpit 화면에서 실행

새로 생성한 ISO를 마운트한 뒤 업데이트 창에서 **Mold 업데이트**를 선택하고
ISO 루트의 마운트 경로를 입력합니다 (`update/` 경로가 아닙니다).
**확인**을 누르면 `update/update-mold.sh`와 필수 RPM 5종의
헤더를 검사합니다. RPM 누락·중복이나 헤더 조회 실패는 이 단계에서 표시하며,
`ks/config`, BaseOS, AppStream 저장소는 요구하지 않습니다.

Mold 선택 시 표의 구분은 **Mold**로 표시합니다. 현재 버전은 호스트에 설치된
`cloudstack-common`, 업데이트 버전은 ISO의 `cloudstack-common`에서 읽습니다.
`aspkg`를 우선 사용하고 없으면 `rpm`으로 조회하며, 패키지명과 아키텍처를 제외한
`VERSION-RELEASE`만 표시합니다 (예: `4.23.0.0-Mold.Europa.202609111701.1`). **실행**을 누르면
다시 검증한 뒤 ISO 내용을 `/opt/ABLESTACK_UPDATE`에 복사하고 그 안의
`update/update-mold.sh`를 실행합니다. CCVM 대상 판단과 의존성 검사는 해당 스크립트가 담당합니다.
**전체 업데이트**도 ISO 루트의 `ks/ablestack-ks.cfg`에서 버전을 확인하고,
복사한 `update/update-all.sh`를 실행합니다.

## 여러 호스트의 처리 순서

1. CCVM이 실행 중인 호스트에서 먼저 실행합니다. 호스트와 CCVM 사전 검사를 마친 뒤
   CCVM, 현재 호스트 순서로 업데이트합니다.
2. 나머지 호스트에서 같은 ISO로 순차 실행합니다. 로컬 CCVM이 없거나 정지 상태이면
   호스트만 업데이트합니다. 모든 호스트에서 CCVM이 정지 상태라면 CCVM은 업데이트되지
   않으므로, CCVM을 기동한 호스트에서 다시 실행해야 합니다.
3. 호스트 및 CCVM의 `/var/log/ablestack-mold-update.log`에서 결과를 확인합니다.

`cloudcenter_res`의 설정 변경, CCVM의 자동 이동이나 호스트 재부팅은 수행하지 않습니다. 업데이트 중에는 CCVM을
수동 이동하지 마세요. 한 머신에서 중복 실행하면 잠금으로 두 번째 실행을 중단합니다.
RPM 버전이 이미 일치하고 서비스도 정상인 경우 설치와 재시작을 건너뜁니다.
설치 후 중단되어 재시작이 남아 있으면 재실행 시 재시도합니다.

CCVM의 실행별 임시 폴더는 작업 종료 시 정리합니다. `--check`도 로그, 잠금,
원격 임시 파일과 패키지 도구의 캐시를 사용하지만 RPM을 설치하거나 서비스를
재시작하지 않습니다. CCVM에는 대상 Mold RPM 4개와 의존성 저장소 전체를 복사합니다.
실패 시 자동 롤백은 하지 않으며, 먼저 완료된 CCVM 업데이트 등은 유지됩니다.
실패 원인을 해결하고 동일 ISO로 재실행할 수 있습니다.

기존 스크립트와 같이 RPM 서명 검사는 `--nogpgcheck`로 생략합니다.
서비스 확인은 systemd 활성 상태까지이며 Mold API나 데이터베이스 상태 검증은 포함하지 않습니다.

## 개발 검증

로컬에 `tests/`가 있고 Python 3이 설치되어 있으면 저장소 루트에서 모의 테스트를
실행할 수 있습니다. `tests/`는 Git에 포함하지 않으며 ISO 생성 및 업데이트 실행에 필요하지 않습니다.
실제 RPM 설치, SSH 접속, ISO 생성 도구를 사용하지 않는 흐름 검증입니다.

```bash
python3 -B -m unittest discover -s tests -v
```

명령 옵션 참고: [DNF 공식 문서](https://dnf.readthedocs.io/en/stable/command_ref.html),
[DNF 테스트 트랜잭션](https://dnf.readthedocs.io/en/stable/conf_ref.html#tsflags),
[createrepo_c](https://github.com/rpm-software-management/createrepo_c),
[xorriso 공식 문서](https://www.gnu.org/software/xorriso/man_1_xorriso.html).

## System VM 템플릿 업로드

`upload-systemvm-template.sh`는 기존 방식으로 실행합니다. ISO 경로·관리자 로그인·OS 선택 등
터미널 입력을 마치면 `nohup`으로 새 세션의 백그라운드 작업을 시작하고 PID를 출력합니다.
이미지 추출, 임시 HTTP 제공, Mold 등록 및 모든 대상 Zone의 Ready 확인은 백그라운드에서
계속 진행합니다. SSH 연결 종료 후에도 작업이 유지됩니다. API 인증 키는 명령행·환경 변수·
임시 설정 파일에 저장하지 않고, 익명 파이프로 작업 프로세스에 전달합니다.

```bash
bash ./upload-systemvm-template.sh --iso /마운트경로
tail -f /var/log/ablestack-upload-systemvm-template.log
```

로그는 기존 내용에 이어 기록하며 백그라운드 작업의 표준 출력과 오류 출력도 포함합니다.
시작 응답은 업로드 완료를 의미하지 않습니다. 최종 `System VM template job finished: completed.`를
확인하고, 실패하면 `System VM template job finished: failed (exit=...)` 앞의 오류를 확인합니다.
작업이 완료될 때까지 원본 ISO/이미지 경로와 실행 스크립트를 유지하고 ISO를 마운트 해제하지 않습니다.

동일 호스트의 중복 실행은 `/run/lock/ablestack-upload-systemvm-template.lock`으로 차단합니다.
실행 PID는 `/run/ablestack-upload-systemvm-template.pid`에 기록하고 종료 시 정리합니다.
`--check-only`는 포그라운드에서 인증·설정 확인 결과를 반환하며 업로드 작업을 시작하지 않습니다.
`--extract-only`의 이미지 추출·검증도 백그라운드로 실행합니다.
API 설정 파일을 사용하는 기존 `--config` 옵션과 등록 재개 옵션도 그대로 사용할 수 있습니다.
