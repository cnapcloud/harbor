# Harbor 빌드 가이드

## 기본 정보

| 항목 | 값 |
|------|-----|
| 버전 태그 | `v2.15.10` |
| 기본 이미지 네임스페이스 | `goharbor` (베이스 이미지 pull 출처) |
| 커스텀 이미지 네임스페이스 | `cnapcloud` (최종 이미지 태그) |
| 지원 아키텍처 | `amd64`, `arm64` |

---

## 사전 요구사항

- Docker 20.10.10+
- Docker Compose v2 (`docker compose version`)
- Docker Buildx (멀티아치 빌드 및 manifest 생성 시)
- Go 불필요 — 컴파일은 `golang:1.25.7` Docker 이미지 내에서 실행됨

---

## 빌드 순서

`make build`는 Go 바이너리가 이미 컴파일되어 있다고 가정합니다.
반드시 아래 순서대로 실행해야 합니다.

```
1. make compile   → Go 바이너리 빌드 (GOARCH로 타겟 아키텍처 지정)
2. make build     → Docker 이미지 빌드
```

---

## 빌드 명령

### 1. 멀티아치 빌드 (arm64 + amd64, 권장)

어떤 머신에서든 arm64/amd64 이미지를 모두 빌드하고 Docker Buildx로 multi-arch manifest를 생성합니다.

```bash
# 레지스트리 서버 지정 시
REGISTRYSERVER=registry.example.com/ VERSIONTAG=v2.15.10 make/build-multiarch.sh

# Docker Hub 사용 시
VERSIONTAG=v2.15.10 make/build-multiarch.sh
```

내부 동작:
```
[1/4] make compile GOARCH=arm64 + make build ARCH=arm64
[2/4] make compile GOARCH=amd64 + make build ARCH=amd64  (Go 크로스 컴파일)
[3/4] docker push (arch별 태그)
[4/4] docker buildx imagetools create → multi-arch manifest 생성
```

결과:
```
cnapcloud/harbor-core:v2.15.10-arm64
cnapcloud/harbor-core:v2.15.10-amd64
cnapcloud/harbor-core:v2.15.10        ← manifest (arm64 + amd64)
```

### 2. 단일 아치 빌드

```bash
# amd64 image
make compile VERSIONTAG=v2.15.10 GOARCH=amd64
make build \
  VERSIONTAG=v2.15.10 \
  ARCH=amd64 \
  IMAGENAMESPACE=cnapcloud \
  BASEIMAGENAMESPACE=goharbor \
  BASEIMAGETAG=v2.15.0 \
  TRIVYFLAG=true   # Trivy 포함 시 true

# arm64 image
make compile VERSIONTAG=v2.15.10 GOARCH=arm64
make build \
  VERSIONTAG=v2.15.10 \
  ARCH=arm64 \
  IMAGENAMESPACE=cnapcloud \
  BASEIMAGENAMESPACE=cnapcloud \
  BASEIMAGETAG=v2.15.10 \
  BUILD_BASE=true \
  PUSHBASEIMAGE=false \
  PULL_BASE_FROM_DOCKERHUB=false \
  TRIVYFLAG=true   # Trivy 포함 시 true
```

빌드 시 아래 경고가 출력될 수 있으나 실제 오류가 아니므로 무시해도 됩니다.

```
- InvalidDefaultArgInFrom: Default value for ARG ${build_image} results in empty or invalid base image name
- InvalidDefaultArgInFrom: Default value for ARG ${harbor_base_namespace}/harbor-exporter-base:${harbor_base_image_version} results in empty or invalid base image name
```

BuildKit의 정적 분석(lint) 경고로, `ARG` 선언에 기본값이 없을 때 발생합니다.
Makefile에서 `--build-arg build_image=$(GOBUILDIMAGE)`, `--build-arg harbor_base_image_version=$(BASEIMAGETAG)`, `--build-arg harbor_base_namespace=$(BASEIMAGENAMESPACE)`로 값을 전달하고 있으나, BuildKit은 Dockerfile 파싱 단계에서 정적으로 검사하기 때문에 경고는 어쩔 수 없이 발생합니다. 빌드 결과에는 영향이 없습니다.

---

## 이미지 네임스페이스 분리

| 변수 | 기본값 | 역할 |
|------|--------|------|
| `BASEIMAGENAMESPACE` | `goharbor` | 베이스 이미지를 Docker Hub에서 pull할 네임스페이스. **변경하지 않을 것** |
| `IMAGENAMESPACE` | `goharbor` | 빌드 결과 최종 이미지에 붙는 네임스페이스 |

```bash
# 잘못된 예 — 베이스 이미지를 찾을 수 없어 빌드 실패
export BASEIMAGENAMESPACE=cnapcloud  # ❌

# 올바른 예
export IMAGENAMESPACE=cnapcloud      # ✅
# BASEIMAGENAMESPACE는 goharbor 기본값 유지
```

빌드 결과 이미지 예시:
```
cnapcloud/harbor-core:v2.15.10
cnapcloud/harbor-log:v2.15.10
cnapcloud/harbor-db:v2.15.10
cnapcloud/harbor-portal:v2.15.10
cnapcloud/harbor-jobservice:v2.15.10
cnapcloud/harbor-registryctl:v2.15.10
cnapcloud/registry-photon:v2.15.10
cnapcloud/nginx-photon:v2.15.10
cnapcloud/redis-photon:v2.15.10
cnapcloud/harbor-exporter:v2.15.10
```

---

## 아키텍처 감지 흐름

```
uname -m (aarch64 → arm64, x86_64 → amd64)
    │
    ├─ Makefile: ARCH=arm64
    │       └── TRIVY_DOWNLOAD_URL → Linux-ARM64.tar.gz
    │
    └─ make/photon/Makefile: PLATFORM=linux/arm64
            └── docker build --platform=linux/arm64 ...

./prepare 실행
    └── docker_compose.py: platform.machine() == "aarch64"
            └── platform = "linux/arm64"
                    └── docker-compose.yml: platform: linux/arm64 (전 서비스)
```

---

## docker-compose 설정 생성

빌드 후 `./prepare`를 실행하면 현재 머신의 아키텍처를 감지하여
`docker-compose.yml`이 자동 생성됩니다.

```bash
# make/harbor.yml 에서 hostname 수정
vi make/harbor.yml

# docker-compose.yml 생성
make prepare VERSIONTAG=v2.15.10 IMAGENAMESPACE=cnapcloud

# Trivy 포함
make prepare VERSIONTAG=v2.15.10 IMAGENAMESPACE=cnapcloud TRIVYFLAG=true
```

생성된 `docker-compose.yml` 내 모든 서비스에 플랫폼이 명시됩니다:
```yaml
services:
  core:
    image: cnapcloud/harbor-core:v2.15.10
    platform: linux/arm64   # 또는 linux/amd64
    ...
```

### Harbor 시작

```bash
make start
```

### Harbor 중지

```bash
make down
```

---

## 이미지 Push

빌드 후 레지스트리 서버에 push합니다.

```bash
make pushimage \
  VERSIONTAG=v2.15.10 \
  IMAGENAMESPACE=cnapcloud \
  REGISTRYSERVER=registry.example.com/ \
  REGISTRYUSER=admin \
  REGISTRYPASSWORD=*****
```

> `REGISTRYSERVER` 끝에 `/` 필수. 생략 시 Docker Hub로 push됩니다.

---

## 전체 설치 (컴파일 → 빌드 → 실행)

```bash
# compile + build + prepare + start 를 한 번에 실행
make install \
  VERSIONTAG=v2.15.10 \
  IMAGENAMESPACE=cnapcloud \
  BASEIMAGENAMESPACE=goharbor \
  BASEIMAGETAG=v2.15.0
```
