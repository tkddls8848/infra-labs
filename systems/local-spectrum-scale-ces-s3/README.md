# 로컬 IBM Storage Scale CES S3 축소 랩

이 디렉터리는 VirtualBox와 Vagrant로 IBM Storage Scale Developer Edition
5.2.3.8의 네이티브 CES S3 경로를 확인하는 **단일 노드 실험 랩**이다. 이 조합은
IBM 지원 조합이 아니다. Rocky Linux 9는 Developer Edition이 지원하는 RHEL 9.8이
아니며, 1노드 16 GiB는 문서화된 3노드·노드당 64 GiB 기준이 아니다. 두 편차는
서로 독립적이며, 이 랩에는 IBM 지원이 제공되지 않는다.

이 랩이 확인하는 범위는 `mms3`로 계정과 버킷을 만든 뒤 CES 엔드포인트에서 S3
put/get/list/delete를 수행하는 기능 검사뿐이다. 다음 항목은 확인하거나 주장하지
않는다.

- CES IP 장애조치와 노드 장애 복구
- quorum 중복성 또는 스토리지 가용성
- 데이터 중복성: 모든 파일시스템은 replication 1이며 failure group도 하나뿐이다.
- RHEL 9.8 및 IBM 지원 커널 조합
- 운영 환경 적합성, 성능, 안정성 또는 IBM 지원

Swift, Keystone, `mmobj`, `OBJ` 서비스, DAS S3 및 블록 프로토콜은 이 랩의 경로가
아니다. 설치하고 활성화하는 오브젝트 서비스는 5.2.3.8의 네이티브 `S3`뿐이다.

## 수동 설치 이미지 계약

IBM 설치 이미지는 저장소나 생성 VM 이미지에 포함하지 않는다. 사용자가
[Developer Edition 등록 폼](https://www.ibm.com/account/reg/signup?formid=urx-41728)에
IBM ID로 로그인해 **5.2.3.8 Developer Edition RHEL x86_64** 자체 추출 이미지를
받은 뒤, 원래 파일명과 관계없이 다음 위치에 둔다.

```text
systems/local-spectrum-scale-ces-s3/.artifacts/installer
```

파일은 비어 있지 않고 실행 가능해야 한다. 프로비저닝은 먼저 아카이브 자체의
`--manifest`를 실행해 다음을 확인한 뒤에만 `--silent`로 추출한다.

- 릴리스 `5.2.3.8` 또는 RPM 표기 `5.2.3-8`
- Developer Edition의 `gpfs.license.dev` RPM
- RHEL 9용 네이티브 CES S3 `gpfs.mms3` 및 `noobaa-core` RPM

IBM 문서상 `--silent` 추출은 전자 라이선스 계약을 자동으로 수락한다. 사용자는
`vagrant up` 전에 해당 계약을 직접 검토해야 하며, 아래 미지원 모드 opt-in은 IBM
라이선스 검토나 수락을 대신하지 않는다.

IBM 원본 파일명, 크기와 SHA-256은 공개 로그인 전 자료로 확인되지 않았으므로 이
저장소는 값을 추측하거나 고정하지 않는다. 포털이 공급자 체크섬을 제공하면 사용자가
`SCALE_INSTALLER_SHA256`에 64자리 SHA-256을 전달할 수 있다. 변수가 없으면 시작
출력은 공급자 진위 검증을 **하지 않았음**을 명시한다. 아카이브 내부 manifest 검사는
공급자 체크섬 검증의 대체가 아니다.

`.artifacts/`는 이 디렉터리의 `.gitignore`에 포함된다. 어떤 프로비저닝·검증·정리
경로도 `.artifacts/installer`를 삭제하거나 수정하지 않는다. `vagrant destroy -f`도
사용자 다운로드 원본을 대상으로 하지 않는다.

## 명시적 미지원 모드 동의와 실행

호스트에는 VirtualBox, Vagrant와 VM에 할당할 16 GiB RAM 및 4 vCPU가 필요하다.
프로비저닝은 다음의 정확한 opt-in 값이 없으면 첫 단계에서 중단한다. PowerShell 예는
다음과 같다.

```powershell
cd devops\systems\local-spectrum-scale-ces-s3
$env:SCALE_CES_S3_UNSUPPORTED_OPT_IN='I_ACCEPT_UNSUPPORTED_SINGLE_NODE_ROCKY9'
# IBM 포털에서 확인한 공급자 체크섬이 있을 때만 설정한다.
$env:SCALE_INSTALLER_SHA256='<64자리 공급자 SHA-256>'
vagrant up --provider=virtualbox
```

체크섬을 확인하지 못했다면 두 번째 환경 변수는 설정하지 않는다. 빈 값이나 설치
파일에서 자체 계산한 값을 공급자 체크섬처럼 사용하지 않는다. Vagrant 시작 출력과
각 프로비저닝 단계는 Rocky 9 편차와 단일 노드 편차, IBM 미지원 상태, 장애조치와
중복성 부재를 반복해 표시한다.

프로비저닝 단계는 다음 순서로 실행된다.

1. opt-in, Rocky/x86_64, 최소 메모리, 두 네트워크와 installer 계약을 검사한다.
2. Rocky 9.6 vault에서 고정 커널과 빌드 도구를 설치하고 exact versionlock을 만든 뒤
   재부팅한다.
3. 실행 커널과 `kernel-devel`의 완전 일치를 검사하고 IBM RPM을 설치한 뒤
   `mmbuildgpl --build-package`를 실행한다. 실패하면 Rocky 미지원 조합을 지목하고
   `/var/log/scale-lab-mmbuildgpl.log`를 남긴다.
4. 단일 quorum/manager와 두 NSD, 두 파일시스템, CES shared root와 CES IP를 구성하고
   `mmces service enable S3`, `mmces service start S3 -a`를 실행한다.
5. 임시 `mms3` 계정·버킷을 만든 뒤 서명된 S3 API로 put/get/list/delete를 실행하고
   임시 계정·버킷을 정리한다. 자격증명은 실행 중 무작위로 만들며 저장하지 않는다.

첫 실사용에서 가장 가능성이 높은 실패 지점은 Rocky 9.6 커널에서의 GPL 계층 빌드,
IBM 아카이브에 실제로 포함된 5.2.3.8 EL9 S3 RPM의 의존성, 그리고 16 GiB 안에서의
NooBaa 기동이다. 이 셋은 코드를 작성한 호스트에 IBM installer가 없어 실제로
부팅·검증하지 못한 항목이다.

## 토폴로지와 스토리지

[`inventory.ini`](inventory.ini)가 주소, 자원, 디스크, 패키지와 제품 버전의 단일
기준이다.

| 용도 | 값 |
| --- | --- |
| VM | `scale-ces1`, 4 vCPU, 16 GiB |
| 관리 및 GPFS 주소 | `192.168.56.31/24` |
| GPFS `subnets=` | `192.168.56.0`만 사용 |
| CES NIC 기본 주소 | `192.168.57.31/24` |
| CES S3 주소 | `192.168.57.40/24` |
| CES shared root | 별도 5 GiB VDI, `/gpfs/cesroot`, 256 KiB block, inode 5000 이상 |
| S3 데이터 | 별도 20 GiB VDI, `/gpfs/s3data` |
| NSD 보호 | failure group 1개, data/metadata replication 1 |

모든 주소는 저장소 제한인 `192.168.56.0/21` 안에 있다. CES 주소는 노드의 관리
주소나 CES NIC의 기본 주소가 아니며, `192.168.57.0/24`는 GPFS `subnets=`에 넣지
않는다. 한 노드뿐이므로 `192.168.57.40`은 이동할 대상이 없고, 이를 floating IP
장애조치로 설명하지 않는다. NSD 원시 용량은 총 25 GiB로 Developer Edition의
12 TiB 상한보다 훨씬 작지만 데이터 사본은 하나뿐이다.

## 고정 버전과 저장소 확인

모든 직접 버전 핀은 [`inventory.ini`](inventory.ini)에 있다.

| 구성요소 | 고정값 |
| --- | --- |
| Vagrant box | `bento/rockylinux-9` `202510.26.0` |
| Rocky vault | `9.6` |
| Rocky kernel/core/modules/devel | `5.14.0-570.49.1.el9_6.x86_64` |
| GCC/CPP/G++ | `11.5.0-5.el9_5` |
| binutils | `2.35.2-63.el9` |
| elfutils-libelf-devel | `0.192-6.el9_6` |
| make / rpm-build | `1:4.3-8.el9` / `4.16.1.3-37.el9` |
| bzip2 / dnf-plugins-core / Python 3 | `1.0.8-10.el9_5` / `4.3.0-20.el9` / `3.9.21-2.el9_6.2` |
| IBM Storage Scale | `5.2.3.8` (`5.2.3-8` RPM 수준) |

2026-08-15에 Rocky의 공식 9.6 vault `primary.xml.gz`를 직접 조회했다. 요구한
`kernel`, `kernel-core`, `kernel-modules`, `binutils`, `bzip2`는 BaseOS에 있었고,
`kernel-devel`, `cpp`, `gcc`, `gcc-c++`, `elfutils-libelf-devel`은 AppStream에
있었다. 이 고정 집합 중 CRB에만 있는 패키지는 없었다. 그래도 랩은 동일한 고정
Rocky 9.6 CRB 저장소를 명시적으로 구성해 IBM RPM의 전이 의존성을 임의의 최신
릴리스에서 받지 않게 한다. IBM 문서의 RHEL 빌드 전제 패키지 여섯 개는 모두 위
두 저장소에서 확인됐다.

이 커널은 문서의 지원 기준인 RHEL 9.8
`5.14.0-687.30.1.el9_8`이 아니다. Rocky라는 OS 편차와 9.6 커널 편차를 숨기지
않으며 IBM 지원을 주장하지 않는다. `kernel`, `kernel-core`, `kernel-modules`,
`kernel-devel`은 같은 EVR/아키텍처로 설치하고 DNF versionlock으로 자동 갱신을
막는다. GPL 빌드 전에 `uname -r`, 설치 RPM, `/lib/modules/<release>/build`가 모두
일치해야 한다.

IBM 명령 형태는 다음 공식 5.2.3 문서를 기준으로 고정했다.

- [Linux 자체 추출 이미지와 `--manifest`/`--silent`](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=nodes-extracting-storage-scale-software-linux)
- [Developer Edition 필수 RPM과 EL9 S3 RPM](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=isslndp-manually-installing-storage-scale-software-packages-linux-nodes)
- [`mmbuildgpl --build-package`](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=reference-mmbuildgpl-command)
- [CES shared root와 `mmchnode --ces-enable`](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=features-ces-cluster-setup)
- [`mmces` 주소 및 S3 서비스](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=reference-mmces-command)
- [`mms3` 계정과 버킷](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=reference-mms3-command)

IBM 바이너리 없이는 위 명령을 실행 확인할 수 없다. 구현은 문서에서 확인한 옵션만
사용하며, IBM 원본 파일명·크기·SHA-256과 번들 `gpfs.mms3`/`noobaa-core`의 별도
component 버전은 추측하지 않는다. 두 패키지는 manifest에서 EL9 RPM임을 확인한 뒤
5.2.3.8 아카이브가 제공한 RPM 메타데이터를 실행 시 출력한다.

## 재검증과 정리

프로비저닝 뒤 기능 검사를 다시 실행하려면 동일한 opt-in 환경을 전달해 다음을
실행한다.

```bash
sudo --preserve-env=SCALE_CES_S3_UNSUPPORTED_OPT_IN \
  bash /vagrant/scripts/40-verify-s3.sh
```

랩 VM과 로컬 VDI는 다음으로 제거한다.

```bash
vagrant destroy -f
```

`.artifacts/installer`는 의도적으로 남는다. 필요하면 사용자가 라이선스와 보관 정책을
확인한 뒤 직접 제거한다.
