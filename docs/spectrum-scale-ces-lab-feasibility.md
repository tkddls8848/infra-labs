# IBM Storage Scale CES 오브젝트 랩 구축 가능성 검토

> 검토 기준일: 2026-08-14
>
> 저장소 기준: `2eb7f3c` (`main`)
>
> 최종 범위: CES 오브젝트 프로토콜만 검토한다. 블록 프로토콜은 2026-08-15 사용자 결정으로 범위에서 제외했다.

## 1. 결론

**최종 판정은 ⚠️ 조건부 가능이다.** IBM Storage Scale Developer Edition 5.2.3.8, RHEL 9.8 x86_64, 네이티브 CES S3 조합은 제품과 운영체제 지원 근거가 있다. 다만 IBM ID로 등록한 사용자가 설치 이미지를 먼저 내려받아야 하고, 로그인 없이 재현 가능한 공개 패키지 URL은 확인하지 못했다. 따라서 현재 저장소의 다른 랩처럼 clone 후 한 명령만으로 모든 비트를 받는 완전 자립형 랩은 만들 수 없다.

판정은 **오브젝트 요구사항만** 대상으로 한다.

| 항목 | 판정 | 근거와 조건 |
|---|---:|---|
| 제품 차원의 CES S3 구현 가능성 | ✅ 가능 | CES S3는 5.2.1.0부터 제공되며, 5.2.3 계열 설치 도구가 S3 패키지 설치를 지원한다. [CES S3 FAQ](https://www.ibm.com/docs/en/storage-scale?topic=STXKQY%2Fgpfsclustersfaq.htm), [Installation Toolkit 개요](https://www.ibm.com/docs/en/storage-scale/6.0.1?topic=toolkit-overview-installation) |
| 정확한 목표 조합 | ✅ 가능 | Developer Edition은 RHEL x86_64를 지원하고, 현재 지원 행렬에 5.2.3.8 + RHEL 9.8 + `5.14.0-687` 계열이 있다. [제품 에디션](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=overview-storage-scale-product-editions), [Linux 지원 행렬](https://public.dhe.ibm.com/storage/spectrumscale/support/) |
| 설치 비트의 자동 취득 | ❌ 불가 | 등록 페이지와 Fix Central 선택 페이지까지는 익명 HTTP 200이지만, 설치 바이너리의 익명 직접 URL은 확인되지 않았다. Fix Central 설명도 권한 있는 고객의 다운로드를 전제로 한다. [Developer Edition 등록](https://www.ibm.com/account/reg/signup?formid=urx-41728), [5.2.3.8 Fix Readme](https://www.ibm.com/support/pages/node/7274768) |
| 저장소용 재현 랩 | ⚠️ 조건부 | 사용자가 IBM ID로 5.2.3.8 Developer Edition 이미지를 사전 다운로드하고, 라이선스·지원 제한과 큰 메모리 요구를 수용해야 한다. 포털 안의 정확한 파일명과 체크섬은 로그인 없이 검증하지 못했다. |

위험도별 핵심 발견은 다음과 같다.

| ID | 심각도 | 발견 | 구현 영향 |
|---|---:|---|---|
| C-1 | Critical | 공개 등록 폼과 Fix Central 안내는 확인했지만 익명 설치 바이너리 URL은 확인하지 못했다. [Developer Edition 등록](https://www.ibm.com/account/reg/signup?formid=urx-41728), [Installation Toolkit 준비](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=toolkit-preparing-use-installation) | 사용자 사전 다운로드 없이는 시작할 수 없다. |
| H-1 | High | 로그인 뒤 Developer Edition 포털에 정확히 5.2.3.8 이미지가 있는지 검증하지 못했다. | 파일이 없으면 목표 버전과 지원 행렬을 다시 선정해야 한다. |
| H-2 | High | IBM object 건강 점검의 64 GB 기준을 3노드에 적용하면 총 192 GiB다. [GPFS 이벤트](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=events-gpfs) | 일반 개발자 노트북용 기본 VirtualBox 랩으로는 과도하다. |
| H-3 | High | GPFS portability layer는 커널과 GPFS 버전에 종속된다. [`mmbuildgpl` 명령](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=reference-mmbuildgpl-command) | RHEL minor/커널을 고정하고 변경 때마다 재빌드해야 한다. |
| M-1 | Medium | local-VDI NSD는 VM 장애 시 해당 NSD를 함께 잃는다. [노드 장애와 FPO](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=clusters-node-failure) | replication 2가 필요하며 공유 SAN과 같은 장애조치로 표현하면 안 된다. |

가장 큰 구현 위험은 **IBM 비트의 취득 경로**다. 운영체제나 네트워크는 코드로 고정할 수 있지만, IBM 설치 이미지의 저장소 재배포 권한은 확인하지 못했고 익명 자동 다운로드도 검증하지 못했다. 따라서 사용자 소유의 로컬 파일로만 취급한다. 두 번째 위험은 3노드 CES S3에 대한 메모리 규모다. IBM 건강 점검 기준을 보수적으로 따를 경우 노드당 64 GiB가 필요해 기존 Rook/Ceph 로컬 랩보다 총 메모리가 12배 크다.

## 2. 검증 방법과 한계

이 문서는 저장소의 기존 호환성 검토 문서와 같은 등급을 사용한다.

- ✅ 가능: 고정한 버전 조합과 공식 지원 근거가 있으며, 요구 기능을 그대로 구현할 수 있다.
- ⚠️ 조건부: 기능은 가능하지만 수동 취득, 지원 밖 축소 사양, 비용 또는 검증되지 않은 전제가 필요하다.
- ❌ 불가: 요구 조합을 지원하지 않거나 재현 가능한 취득 경로가 없다.

IBM 관련 사실은 IBM Documentation, IBM Support, IBM 공개 지원 행렬, 실제 HTTP 응답만 근거로 삼았다. 다운로드 페이지는 다음과 같이 리다이렉트까지 실제 확인했다.

```text
$ curl -L https://www.ibm.com/products/spectrum-scale/pricing -o /dev/null -w 'HTTP=%{http_code}; redirects=%{num_redirects}; final=%{url_effective}; bytes=%{size_download}\n'
HTTP=200; redirects=2; final=https://www.ibm.com/products/storage-scale; bytes=173669

$ curl -L 'https://www.ibm.com/account/reg/signup?formid=urx-41728' -o /dev/null -w 'HTTP=%{http_code}; redirects=%{num_redirects}; final=%{url_effective}; bytes=%{size_download}\n'
HTTP=200; redirects=1; final=https://www.ibm.com/account/reg/us-en/signup?formid=urx-41728; bytes=48570
```

두 번째 응답에는 `IBM Storage Scale Developer Edition`, `Start your free trial today`, 등록 필드, `Already have an IBM account? Log in`이 표시됐다. **HTTP 200은 등록 폼에 접근했다는 뜻일 뿐 바이너리를 익명으로 받았다는 뜻이 아니다.**

저장소 비교값은 기준 커밋의 `systems/local-kubespray-rook-ceph/Vagrantfile`과 `devops/README.md`를 읽어 산출했다. 실제 Storage Scale 설치·부팅·장애조치는 수행하지 않았으므로, 제품 문서로 확인한 사실과 2단계 구현 설계안을 구분한다.

## 3. 오브젝트 스택과 릴리스 경계

`Object`, `Swift`, `S3`라는 이름이 문서에 함께 남아 있어 릴리스 경계를 명시하지 않으면 잘못된 스택을 자동화하게 된다.

| Storage Scale 릴리스 | 새 랩에 적용할 오브젝트 스택 | 판정 |
|---|---|---:|
| 5.1.8까지 | 레거시 **CES Swift Object + OpenStack Keystone**. `mmobj swift base`가 로컬 또는 외부 Keystone을 구성한다. Swift 위의 S3 호환 옵션이 있었지만 현재 네이티브 CES S3와 다른 구현이다. [mmobj 명령](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=reference-mmobj-command), [오브젝트 사용자 인증](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=users-authorizing-object) | 이 랩에 부적합 |
| 5.1.9 | 5.1.8이 CES Swift Object를 포함한 마지막 릴리스다. 5.1.9부터 새 Swift 설치 경로는 폐기됐다. DAS S3는 5.1.9가 마지막이지만 CES S3와 다른 제품 경로다. [폐기 기능 목록](https://www.ibm.com/docs/en/STXKQY/pdf/scale_deprecated_features.pdf) | 이 랩에 부적합 |
| 5.2.0 | 기존 5.1.8 Swift 구성의 업그레이드를 제한적으로 용인할 뿐 Swift를 갱신하지 않는다. DAS S3도 5.2.0부터 중단됐고 네이티브 CES S3는 아직 제공 전이므로, 신규 CES 오브젝트 랩의 목표 릴리스로 삼지 않는다. [오브젝트 사용자 인증](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=users-authorizing-object), [폐기 기능 목록](https://www.ibm.com/docs/en/STXKQY/pdf/scale_deprecated_features.pdf) | ❌ 불가 |
| 5.2.1.0 이상 | **네이티브 CES S3**. NooBaa 서버와 CES 노드의 엔드포인트를 사용하고 `mms3`로 계정·버킷을 관리한다. [CES S3 FAQ](https://www.ibm.com/docs/en/storage-scale?topic=STXKQY%2Fgpfsclustersfaq.htm), [S3 아키텍처](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=overview-s3-architecture) | ✅ 적용 |

따라서 2단계 구현에서 `mmobj`, Swift ring, PostgreSQL-backed Keystone 또는 `OBJ` 서비스를 설치하면 안 된다. 목표 서비스는 `S3`이며 활성화 명령은 `mmces service enable S3`, `mmces service start S3 -a`다. [SMB/NFS/S3 활성화](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=services-configuring-enabling-smb-nfs-s3-protocol)

### 3.1 정확한 목표 릴리스

목표를 **IBM Storage Scale Developer Edition 5.2.3.8 + RHEL 9.8 x86_64 + 네이티브 CES S3**로 고정한다.

- IBM 권장 릴리스 페이지는 5.2.x EUS 스트림을 5.2.3.x로 지정하고, 2026년 6월 공개된 5.2.3.8을 최신 5.2.3 수정 레벨로 제시한다. 5.2.3.0과 5.2.3.1은 NFS/SMB 문제로 철회됐으므로 선택하지 않는다. [권장 릴리스](https://www.ibm.com/support/pages/node/707017)
- 5.2.3.8은 GUI, CES S3, HDFS에 영향을 주는 보안 취약점 수정 수준이다. IBM은 5.2 계열에서 5.2.3.8 이상을 권고한다. [보안 공지](https://www.ibm.com/support/pages/node/7275270), [5.2.3.8 Fix Readme](https://www.ibm.com/support/pages/node/7274768)
- 6.0.1.0도 수정 수준이지만, 공개 등록 폼 안에서 Developer Edition 6.0.1.0 설치 이미지의 제공 여부를 확인하지 못했다. 검증된 5.2.3 EUS 조합을 우선한다.

### 3.2 블록 프로토콜: 범위 제외 기록

블록 프로토콜은 **2026-08-15 사용자 결정으로 이 랩의 요구사항과 판정 범위에서 제외됐다.** 아래 내용은 향후 독자를 위한 짧은 배경일 뿐 구현 요구가 아니다.

CES의 과거 `iSCSI as a target for remote boot` 기능은 5.1.0부터 중단됐고 IBM은 다른 블록 서비스 공급자를 사용하라고 안내한다. 현재 CES 개요와 구현 문서는 NFS, SMB, S3 및 일부 문서의 HDFS를 데이터 서비스로 열거하며 범용 블록 서비스를 제시하지 않는다. `mmces` 참조에 `BLOCK` 열거값이 남아 있지만, 이를 현재 지원되는 범용 CES 블록 프로토콜의 근거로 해석하지 않는다. [폐기 기능 목록](https://www.ibm.com/docs/en/STXKQY/pdf/scale_deprecated_features.pdf), [CES 개요](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=gpfs-cluster-export-services-overview), [CES 구현](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=administering-implementing-cluster-export-services), [mmces 명령](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=reference-mmces-command)

## 4. 라이선스와 설치 비트 취득

### 4.1 Developer Edition의 허용 범위

IBM 문서상 정확한 에디션 이름은 **IBM Storage Scale Developer Edition**이다.

| 조건 | 확인 결과 |
|---|---|
| 기능 | Data Management Edition과 같은 기능을 제공한다. |
| 플랫폼 | RHEL x86_64만 지원한다. |
| 용량 | 클러스터당 최대 12 TB다. `mmlslicense` 문서는 이를 12 TiB, 즉 13,194,139,533,312바이트 NSD 총량으로 명시한다. |
| 용도 | 테스트 설정에는 무료지만 운영 사용은 금지된다. |
| 지원 | IBM 지원이 제공되지 않는다. 지원 제품으로 제자리 업그레이드할 수도 없다. |
| 클러스터 수 | 각 클러스터가 12 TB 이하라면 복수 Developer Edition 클러스터를 둘 수 있다. |

근거: [Storage Scale 제품 에디션](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=overview-storage-scale-product-editions), [FAQ의 Developer Edition 항목](https://www.ibm.com/docs/en/storage-scale?topic=STXKQY%2Fgpfsclustersfaq.htm), [`mmlslicense` 명령](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=reference-mmlslicense-command)

FAQ의 별도 **90일 평가판**은 영업 담당자를 통해 받는 다른 경로다. 이를 Developer Edition의 사용 기간으로 간주하지 않는다. 공개 Developer Edition 페이지는 `free trial`이라고 표현하지만 정확한 기간은 공개 문서에서 확인하지 못했다. [Storage Scale FAQ](https://www.ibm.com/docs/en/storage-scale?topic=STXKQY%2Fgpfsclustersfaq.htm), [Developer Edition 등록](https://www.ibm.com/account/reg/signup?formid=urx-41728)

### 4.2 로그인 없는 취득 가능성

**익명 자동 다운로드 경로는 확인되지 않았다.** 확인된 흐름은 다음뿐이다.

1. 공개 제품 페이지에서 Developer Edition 등록 폼으로 이동한다.
2. IBM ID로 로그인하거나 사용자 정보를 등록한다.
3. 포털에서 사용 가능한 Developer Edition 설치 이미지를 선택해 내려받는다.
4. 일반 수정 패키지는 Fix Central에서 HTTPS, Download Director 또는 SFTP 방식으로 받을 수 있지만, IBM 설명은 보증·지원 권한이 있는 사용자를 전제로 한다. [5.2.3.8 Fix Readme](https://www.ibm.com/support/pages/node/7274768)

IBM 설치 문서는 self-extracting archive를 Fix Central에서 받고, 라이선스 동의 뒤 `/usr/lpp/mmfs/5.2.3.x`에 패키지를 푸는 절차를 명시한다. Installation Toolkit 자체도 이 패키지에 포함된다. [Linux 소프트웨어 추출](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=nodes-extracting-storage-scale-software-linux), [Installation Toolkit 준비](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=toolkit-preparing-use-installation)

로그인 전에는 **Developer Edition 5.2.3.8 RHEL x86_64 자체 추출 설치 이미지의 IBM 원본 파일명, 크기, SHA-256, 실제 제공 여부**를 볼 수 없었다. 등록 완료 뒤 Developer Edition 다운로드와 Fix Central 권한이 어떻게 연결되는지도 확인하지 못했다. 이 값을 추측해서 자동화에 넣어서는 안 된다.

### 4.3 2단계 구현에 필요한 정확한 수동 단계

권장 프로비저너와 저장소의 기존 `aws-*-storage-lab` 명명 패턴에 맞춰 2단계 디렉터리는 `systems/aws-spectrum-scale-ces-s3`로 제안한다. 설치 바이너리는 저장소에 커밋하지 않고 다음 계약으로 전달한다.

1. 사용자가 [Developer Edition 등록 폼](https://www.ibm.com/account/reg/signup?formid=urx-41728)에 IBM ID로 로그인해 **5.2.3.8, RHEL x86_64** 이미지를 선택한다. 포털에 그 조합이 없다면 진행을 중단하고 목표 버전을 다시 판정한다.
2. 받은 파일을 원래 파일명과 관계없이 아래의 저장소 측 표준 이름으로 복사한다.

   ```powershell
   New-Item -ItemType Directory -Force devops\systems\aws-spectrum-scale-ces-s3\.artifacts
   Copy-Item -LiteralPath '<IBM에서 받은 설치 이미지>' -Destination devops\systems\aws-spectrum-scale-ces-s3\.artifacts\installer
   Get-FileHash -Algorithm SHA256 devops\systems\aws-spectrum-scale-ces-s3\.artifacts\installer
   ```

3. `.artifacts/`는 랩 자체 `.gitignore`로 항상 제외한다. 시작 스크립트는 파일 부재, 빈 파일, 실행/압축 해제 실패 시 즉시 중단하고 등록 URL과 기대 버전을 출력한다.
4. 시작 스크립트는 self-extracting archive의 `--manifest` 출력을 검사해 5.2.3.8과 필요한 S3/CES 패키지가 실제로 들어 있는지 확인한다. IBM 문서가 `--manifest` 사용법을 제공한다. [Linux 소프트웨어 추출](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=nodes-extracting-storage-scale-software-linux)
5. 사용자는 포털에 표시된 체크섬이 있다면 별도 환경 변수 또는 로컬 파일로 전달한다. 단순히 다운로드한 파일에서 다시 계산한 해시는 이후 손상은 검출하지만 공급자 진위는 보증하지 못한다.

이 계약은 필요한 수동 작업을 한 지점에 격리하지만, 저장소 전체의 `vagrant up`형 자립성에서 벗어난다. IBM 설치 비트의 재배포 권한을 확인하지 못했으므로 설치 이미지와 라이선스 파일을 저장소, 릴리스 아티팩트, CI 캐시 또는 재배포 VM 베이스 이미지에 넣지 않는 것을 구현 가드레일로 삼는다.

조정자에게 “사전 다운로드를 2단계 전제조건으로 받아들일지” 물으려 했으나, 현재 터미널의 Orca Dispatch capability가 없어 `dispatch_capability_invalid`로 질문 전송이 실패했다. 따라서 **수동 사전 다운로드 수용 여부는 미승인 조건**으로 남긴다.

## 5. 운영체제, 커널, GPL 계층

### 5.1 지원되는 고정 조합

IBM의 공개 Linux 지원 행렬은 2026-08-13 갱신본이며, 5.2.3.8의 RHEL 9.8 x86_64 행은 다음을 제시했다. [IBM Storage Scale Linux 지원 행렬](https://public.dhe.ibm.com/storage/spectrumscale/support/)

```text
PS> $html = (Invoke-WebRequest -UseBasicParsing 'https://public.dhe.ibm.com/storage/spectrumscale/support/').Content
PS> # HTML 태그 제거 후 'RHEL 9.8', 'x86_64', '5.2.3.8' 연속 행을 선택
RHEL 9.8
x86_64
5.2.3.8
5.14.0-687
5.14.0-687.30.1.el9_8
5.14.0-687.20.1.el9_8
5.14.0-687.15.1.el9_8
5.14.0-687.12.1
SMB: 4.20.8 10-1
NFS: 5.7 (ibm 028.21)
None
None
```

랩 이미지는 **RHEL 9.8 + `5.14.0-687.30.1.el9_8`**로 고정한다. “RHEL 9”만 고정하거나 매 부팅 `dnf update`로 최신 커널을 받는 방식은 재현 가능한 조합이 아니다.

Rocky Linux 9와 AlmaLinux 9는 이 조합의 대체재로 사용하지 않는다. Developer Edition 문서는 RHEL x86_64만 지원하고, 확인한 공개 지원 행렬에서 Rocky/Alma 행을 찾지 못했다. RHEL 바이너리 호환성으로 동작할 가능성은 **미지원·미검증**이며, 랩의 기본 목표가 될 수 없다. [제품 에디션](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=overview-storage-scale-product-editions), [Linux 지원 행렬](https://public.dhe.ibm.com/storage/spectrumscale/support/)

지원 행렬의 Ubuntu 24.04.4 행은 5.2.3.8 자체를 열거하지만 unavailable features에 `Object`, `S3`를 포함한다. 따라서 이 오브젝트 랩에는 사용할 수 없다. [Linux 지원 행렬](https://public.dhe.ibm.com/storage/spectrumscale/support/)

### 5.2 커널 모듈 빌드와 고정 정책

Storage Scale의 GPFS portability layer는 GPFS 버전과 Linux 커널에 종속된다. 커널 또는 GPFS가 바뀌면 다시 빌드해야 하며, `mmbuildgpl`로 만든 `gpfs.gplbin`은 아키텍처·배포판·커널·Storage Scale 유지보수 레벨이 동일한 노드에만 배포할 수 있다. [`mmbuildgpl` 명령](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=reference-mmbuildgpl-command), [GPFS portability layer 빌드](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=nodes-building-gpfs-portability-layer-linux)

RHEL 빌드 전제 패키지는 `kernel-devel`, `cpp`, `gcc`, `gcc-c++`, `binutils`, `elfutils-libelf-devel`이다. 정확한 커널용 `kernel-devel` 설치 여부를 VM 이미지 빌드 단계에서 검사한다. [GPFS 소프트웨어 요구사항](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=gpfs-software-requirements)

2단계 자동화는 다음 가드레일을 가져야 한다.

- VM 이미지 생성 시 `uname -r`이 `5.14.0-687.30.1.el9_8.x86_64`인지 검증한다.
- `kernel`, `kernel-core`, `kernel-modules`, `kernel-devel`을 같은 NEVRA로 고정하고 자동 커널 갱신을 막는다.
- 설치 직후 한 노드에서 GPL 계층을 빌드하고 동일 조합의 두 노드에만 배포하거나, 모든 노드에서 동일 입력으로 빌드한다.
- `autoBuildGPL=yes`는 새 커널 모듈이 없을 때 자동 재빌드를 돕지만, 정확한 헤더와 툴체인이 있어야 한다. 커널 고정의 대체재가 아니다. [`mmchconfig` 명령](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=reference-mmchconfig-command)
- 커널 또는 Storage Scale 수정 레벨을 바꾸는 PR은 지원 행렬 재확인, GPL 재빌드, 3노드 재부팅 검증을 함께 수행한다.

## 6. 최소 토폴로지와 NSD 설계

### 6.1 노드 수

CES S3 엔드포인트와 CES IP 장애조치를 정직하게 보여주는 최소 토폴로지는 **3개 VM**이다. 세 노드를 모두 quorum/manager, NSD server, CES protocol node로 사용한다.

- Storage Scale quorum은 절반+1이며 홀수 quorum 노드를 권장한다. 설치 도구는 4노드 미만 클러스터에서 모든 노드를 quorum으로 표시한다. [Quorum 노드](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=cluster-quorum-quorum-nodes), [클러스터 토폴로지 예](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=examples-defining-cluster-topology-installation-toolkit)
- IBM 이벤트 문서는 단일 quorum 노드에는 중복성이 없고 3, 5, 7개를 권장한다고 설명한다. [GPFS 이벤트](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=events-gpfs)
- CES IP는 풀로 관리되며 노드 장애 시 다른 CES 노드로 이동한다. 노드의 기본 관리 IP를 CES IP로 겸용하면 안 된다. [CES 개요](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=gpfs-cluster-export-services-overview), [CES 네트워크 구성](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=features-ces-network-configuration)

1노드는 S3 기능 확인만 할 수 있고 CES 장애조치를 증명하지 못한다. 2노드 quorum은 한 노드 장애 시 과반을 잃으므로 고가용성 데모의 최소값이 아니다.

### 6.2 VirtualBox에서 공유 SAN 없이 NSD 만들기

각 VM에 데이터용 VDI 하나를 로컬 연결하고, 그 VM만 해당 디스크의 primary NSD server가 되게 한다. 다른 노드는 NSD 네트워크를 통해 접근한다. Storage Scale 문서는 한 노드만 보는 비공유 디스크를 primary NSD server가 제공하는 형태를 허용한다. [Storage Scale 개요](https://www.ibm.com/docs/en/STXKQY_5.2.3/pdf/scale_povr.pdf), [GPFS 디스크 고려사항](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=gpfs-disk-considerations)

세 NSD를 서로 다른 failure group에 두고 data/metadata replication factor를 2로 설정한다. 복제 풀은 둘 이상의 failure group이 필요하며, failure group 간 복제가 디스크 장애에 대한 사본을 제공한다. [`mmchnsd` 명령](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=reference-mmchnsd-command), [NSD 서버/디스크 장애 고려사항](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=considerations-network-shared-disk-server-disk-failure)

이 설계는 실습용 shared-nothing 근사치다. 한 VM이 내려가면 그 VM의 로컬 NSD도 사라지고, 남은 복제본으로 서비스하므로 용량과 중복도가 줄어든다. 진짜 공유 SAN의 다중 NSD 서버 장애조치와 같다고 주장하면 안 된다. FPO 설명도 로컬 디스크는 해당 노드 장애 시 접근 불가능하다고 명시한다. [노드 장애와 FPO](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=clusters-node-failure)

CES shared root는 최소 4 GB의 별도 파일시스템을 권장한다. 랩에서는 같은 복제 NSD 풀 위에 별도 파일시스템으로 만들되, 사용자 S3 데이터 파일시스템과 논리적으로 분리한다. [프로토콜 설치 전제조건](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=protocols-installation-prerequisites)

## 7. 자원 규모와 기존 Rook 랩 비교

IBM 문서에는 네이티브 CES S3만을 위한 작은 랩의 최소 vCPU/RAM 표가 없다. 따라서 아래에서 **IBM 근거**와 **랩 설계값**을 분리한다.

- IBM 건강 점검은 Storage Scale 5.2.0 이상에서 pagepool을 최소 4 GB로 권장하고, NFS 또는 object 사용 시 총 메모리 64 GB 기준을 검사한다. 다중 프로토콜/SMB에는 128 GB 기준이 있다. [GPFS 이벤트](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=events-gpfs)
- 프로토콜 확장 문서는 CES S3를 최대 10개 protocol node, 노드당 권장 최대 3,000 S3 연결로 제시하지만 S3 전용 최소 CPU/RAM은 제시하지 않는다. [프로토콜 확장 고려사항](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=protocols-scaling-considerations)

보수적인 2단계 기본값은 다음과 같다.

| 자원 | CES S3 설계값 | 성격 | 기존 Rook/Ceph 랩 |
|---|---:|---|---:|
| VM 수 | 3 | quorum + CES failover 최소 설계 | 4 |
| vCPU | 4/노드, 총 12 | 랩 설계값이며 IBM 인증 최소값 아님 | 총 10 |
| RAM | 64 GiB/노드, 총 192 GiB | IBM object 건강 점검 기준을 보수적으로 적용 | 총 16 GiB |
| pagepool | 4 GiB/노드 | IBM 권장 하한 | 해당 없음 |
| 데이터 디스크 | 20 GiB/노드, raw 60 GiB | 랩 데이터용 설계값 | 20 GiB × 3, raw 60 GiB |
| 복제 후 유효 데이터 | 약 30 GiB 이하 | replication factor 2의 단순 상한이며 CES shared root/메타데이터 제외 | Ceph 정책에 따름 |

기존 값은 기준 커밋의 `systems/local-kubespray-rook-ceph/Vagrantfile`에서 계산했다. CES S3 안은 VM 수와 raw disk는 비슷하지만 RAM은 **12배**, vCPU는 **1.2배**다. 따라서 일반 개발자 노트북의 VirtualBox 기본 랩으로는 현실성이 낮다.

`3 × 16 GiB = 48 GiB` 축소 모드는 기술 실험 옵션으로 문서화할 수 있으나 IBM의 64 GB object 건강 점검 기준보다 낮다. 실제로 S3가 안정적으로 기동하는지 검증하지 않았으므로 기본값이나 ✅ 조합으로 제시하지 않는다. NooBaa 프로세스의 정확한 유휴/부하 메모리도 공개 자료에서 확인하지 못했다.

## 8. 프로비저너와 네트워크 선택

| 선택지 | 장점 | 문제 | 판정 |
|---|---|---|---:|
| Vagrant + VirtualBox | 기존 Rook 랩과 사용 방식이 가깝고 CES IP 이동을 호스트 전용 네트워크에서 관찰하기 쉽다. | 호스트에 192 GiB RAM이 필요하고, 지원되는 RHEL 9.8 베이스 이미지를 사용자가 별도로 준비해야 한다. | ⚠️ 축소 실험용 |
| Vagrant + libvirt | Linux 호스트에서는 VM/네트워크 자동화가 유연하다. | Windows 중심 저장소 흐름과 맞지 않고, RHEL 이미지와 192 GiB RAM 문제는 그대로다. | ⚠️ 대안 |
| AWS | 공식 RHEL 계열 이미지와 큰 메모리 VM을 선택할 수 있고 로컬 호스트 RAM을 쓰지 않는다. IBM cloudkit은 AWS protocol node와 CES용 secondary private IP 구성을 설명한다. | 비용, 자격증명, 계정별 AMI/인스턴스 가용성, 인터넷 연결이 필요하다. | **⚠️ 권장** |

근거: [AWS cloudkit의 CES 프로토콜 활성화](https://www.ibm.com/docs/en/storage-scale/5.2.3?topic=cloudkit-enabling-ces-protocols). 정확한 AWS 인스턴스 타입, RHEL AMI ID와 비용은 리전·시점에 따라 달라지므로 이 검토에서 고정하지 않았다.

지원 조합과 자원 현실성을 우선하면 **AWS를 기본 프로비저너로 권장**한다. 다만 이 저장소가 요구하는 로컬 데모가 최우선이면 VirtualBox 축소 모드는 별도 `experimental=true` 옵트인으로만 제공하고, 지원 사양이 아님을 시작 시 출력해야 한다.

VirtualBox 폴백의 네트워크는 저장소에서 허용한 `192.168.56.0/21` 안을 다음처럼 나눈다.

| 용도 | 서브넷/주소 |
|---|---|
| 관리 및 GPFS 클러스터 | `192.168.56.0/24`, 노드 `192.168.56.31-33` |
| CES 전용 NIC의 고정 주소 | `192.168.57.0/24`, 노드 `192.168.57.31-33` |
| CES S3 floating IP pool | `192.168.57.40-42` |

CES floating IP는 노드 기본 주소와 분리하고, GPFS `subnets=`에는 관리/클러스터망만 넣는다. CES IP가 속한 네트워크를 GPFS 데몬 선택용 `subnets=`에 함께 넣지 않는 제약은 CES 문서가 명시한다. [CES 네트워크 구성](https://www.ibm.com/docs/en/storage-scale/6.0.0?topic=features-ces-network-configuration)

## 9. 2단계 구현 계약과 합격 기준

2단계 구현은 다음 순서와 실패 조건을 코드로 고정해야 한다.

1. **사전 검사**: IBM 설치 이미지 존재/비어 있지 않음, RHEL 9.8, 정확한 커널/`kernel-devel`, 3노드 이름 해석, 시간 동기화, 디스크 장치 고유성을 검사한다.
2. **클러스터**: 3노드를 quorum/manager로 만들고 라이선스를 Developer Edition 서버 노드로 수락한다. 총 NSD 크기는 12 TiB보다 훨씬 작게 유지한다.
3. **스토리지**: 노드별 local VDI를 한 NSD server와 한 failure group에 매핑하고, data/metadata replication 2인 파일시스템 및 4 GB 이상 CES shared root 파일시스템을 만든다.
4. **CES 네트워크**: 세 노드를 CES node로 지정하고 floating IP 세 개를 풀에 추가한다. 기본 주소를 CES 주소로 재사용하지 않는다.
5. **S3만 활성화**: 네이티브 S3 패키지와 NooBaa 구성을 설치하고 `mmces service enable S3`, `mmces service start S3 -a`를 수행한다. Swift/Keystone/`mmobj` 경로는 금지한다.
6. **기능 검사**: `mms3`로 계정과 버킷을 만들고 CES floating endpoint로 put/get/list/delete를 검증한다. 최소 두 floating IP에서 같은 버킷을 읽는다.
7. **장애조치 검사**: floating IP 하나를 가진 CES 노드를 중지하고, 제한 시간 안에 IP가 다른 노드로 이동해 기존 오브젝트를 읽는지 확인한다. 원래 노드를 복귀시킨 뒤 quorum, NSD, CES, S3 상태를 다시 검사한다.
8. **정리**: 클라우드 자원은 명시적 destroy 명령으로 모두 제거하고, 로컬 `.artifacts/installer`는 사용자의 선택으로 남긴다. 자동 정리에서 IBM 다운로드 원본을 삭제하지 않는다.

합격 기준은 다음 네 가지다.

- RHEL/커널/Storage Scale 조합이 문서의 고정값과 정확히 일치한다.
- S3 API put/get/list/delete가 CES floating endpoint를 통해 성공한다.
- CES 노드 한 대 중지 후 동일 버킷을 읽을 수 있고 quorum이 유지된다.
- 저장소와 생성 이미지/캐시에 IBM 설치 바이너리, 라이선스 파일, 자격증명이 포함되지 않는다.

## 10. 최종 판정

**오브젝트 전용 CES 랩: ⚠️ 조건부 가능**

다음 조건을 모두 만족하면 구현을 시작할 수 있다.

1. 사용자가 IBM ID 등록과 **5.2.3.8 Developer Edition RHEL x86_64 이미지의 수동 사전 다운로드**를 받아들인다.
2. 로그인 후 실제 포털에서 5.2.3.8 Developer Edition 이미지와 공급자 체크섬을 확인한다. 제공되지 않으면 목표 릴리스를 다시 검토한다.
3. RHEL 9.8과 `5.14.0-687.30.1.el9_8`을 고정하고 GPL 계층을 그 조합으로 빌드한다.
4. 기본 검증 환경에 3노드와 노드당 64 GiB를 제공한다. 축소 VirtualBox 모드는 미지원 실험으로 분리한다.
5. 구현은 네이티브 CES S3만 사용하며 Swift/Keystone과 블록 프로토콜을 포함하지 않는다.

이 중 1번은 조정자 승인 채널 오류로 아직 승인받지 못했다. 그러므로 현시점에는 ✅가 아니라 ⚠️이며, 익명 바이너리 URL을 발견했다고 가정하거나 IBM 파일을 저장소에 넣는 방식으로 조건을 우회해서는 안 된다.

## 11. 미검증 항목

- IBM 로그인 뒤 Developer Edition 포털이 정확히 **5.2.3.8 RHEL x86_64** 설치 이미지를 제공하는지, 그 원본 파일명·크기·SHA-256이 무엇인지 확인하지 못했다.
- Developer Edition 등록 페이지의 `free trial`이 기간 제한을 뜻하는지 확인하지 못했다. 별도 90일 평가판과 동일하다고 가정하지 않았다.
- 네이티브 CES S3의 공식 최소 vCPU/RAM과 NooBaa의 실제 유휴·부하 메모리를 확인하지 못했다. 64 GiB/노드는 IBM object 건강 점검 기준을 보수적으로 적용한 값이다.
- 3 × 16 GiB 축소 VirtualBox 구성에서 S3와 장애조치가 실제로 기동하는지 시험하지 않았다.
- 제안한 local-VDI NSD, replication 2, CES floating IP 구성으로 실제 노드 장애조치를 수행하지 않았다.
- AWS의 리전별 RHEL 9.8 AMI ID, 정확한 메모리 최적화 인스턴스 타입, 비용과 secondary IP 이동 자동화는 2단계에서 고정해야 한다.
- 설치 이미지 사전 다운로드를 랩의 공식 전제조건으로 받아들일지 조정자 결정을 받지 못했다. Orca 질문 전송은 `dispatch_capability_invalid`로 실패했다.

## 12. 구현된 로컬 축소 모드 기록

2026-08-15 사용자 결정에 따라 `systems/local-spectrum-scale-ces-s3`에
단일 노드 Rocky Linux 9 축소 랩을 구현했다. 이 구현은 이 문서가 권장한 RHEL 9.8
3노드·노드당 64 GiB 조합이 아니며, **Rocky Linux 9와 단일 16 GiB 노드라는 두
독립 축에서 IBM 지원 조합 밖이다. IBM 지원을 주장하지 않는다.** 명시적 미지원
모드 opt-in 없이는 프로비저닝을 거부하며, 사용자 소유 5.2.3.8 Developer Edition
설치 이미지의 `--manifest`에서 Developer Edition과 EL9 `gpfs.mms3`/`noobaa-core`
RPM을 확인한 뒤 네이티브 CES S3만 구성한다.

이 축소 모드는 section 9의 네 가지 합격 기준 중 S3 API put/get/list/delete와 IBM
비트·라이선스·자격증명의 저장소 미포함만 검사할 수 있다. Rocky Linux 9와 고정한
`5.14.0-570.49.1.el9_6` 커널은 RHEL 9.8
`5.14.0-687.30.1.el9_8` 일치 기준을 포기한다. 단일 노드는 CES IP 장애조치와
quorum 유지 기준도 포기한다. replication 1과 failure group 하나만 사용하므로
데이터 중복성이나 스토리지 가용성도 보여주지 않는다. 기존의 조건부 판정과 근거,
3노드 권장안은 그대로 유효하며 이 축소 구현이 그 판정을 상향하지 않는다.
