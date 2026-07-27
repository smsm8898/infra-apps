# kube-prometheus-stack 67.0.0

> [prometheus-community/helm-charts](https://github.com/prometheus-community/helm-charts)의
> `kube-prometheus-stack` 차트(chart version `67.0.0`, appVersion `v0.79.0`)를
> upstream dependency로 wrapping한 차트입니다.

## Upstream 출처

| 항목 | 값 |
|---|---|
| Helm repo | `https://prometheus-community.github.io/helm-charts` |
| 소스 코드 | https://github.com/prometheus-community/helm-charts (`charts/kube-prometheus-stack`) |
| Chart version | `67.0.0` |
| App version | `v0.79.0` (prometheus-operator) |

## 차트 받아오기

```bash
# Helm repo 등록
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

# 67.0.0 버전 다운로드 (압축 해제 시 --untar 추가)
helm pull prometheus-community/kube-prometheus-stack --version 67.0.0
```

## 구조

```
67.0.0/
├── Chart.yaml         # upstream 메타데이터 + kube-prometheus-stack 67.0.0 dependency 선언
├── values.yaml        # 최소 base 파일 (환경 공통 기본값만)
├── values-dev.yaml    # dev 환경: upstream 기본값 대비 변경분만
├── values-prod.yaml   # prod 환경: upstream 기본값 대비 변경분만
├── charts/            # vendored upstream tgz (helm dependency build 산출물)
├── dashboards/        # Grafana 대시보드 JSON
└── templates/         # 커스텀 리소스 (대시보드 ConfigMap 등)
```

**values 전략**: upstream 기본값을 values.yaml에 복사하지 않는다. 기본값은 vendored tgz
안에 이미 있으므로, 환경별 파일에는 **변경하는 값만** `kube-prometheus-stack:` 키 아래에
적는다. 기본값 전체를 복사해도 렌더 결과는 동일하지만(검증 완료), 차트 업그레이드 시
upstream 변경분을 추적할 수 없게 되고 diff 가독성이 사라진다.

ArgoCD가 이 디렉토리를 Helm chart로 렌더링합니다. dependency는 ArgoCD repo-server가
resolve하며, 렌더 재현성을 위해 `charts/` tgz를 vendoring할 수 있습니다.

## 렌더링 및 검증

```bash
helm dependency build helm-charts/kube-prometheus-stack/67.0.0

helm template kube-prometheus-stack helm-charts/kube-prometheus-stack/67.0.0 \
  -f helm-charts/kube-prometheus-stack/67.0.0/values.yaml \
  -f helm-charts/kube-prometheus-stack/67.0.0/values-dev.yaml
```

## 작업 이력 (실행한 명령어)

### 0단계: 뼈대 구성 — upstream 차트 받아오기

```bash
# 1. Helm repo 등록 및 갱신
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

# 2. upstream 차트 다운로드 (기본값 참조용 — 작업 디렉토리 밖에 untar)
helm pull prometheus-community/kube-prometheus-stack --version 67.0.0 --untar

# 3. wrapper Chart.yaml 작성 후 dependency 빌드 (charts/ 에 tgz vendoring)
helm dependency build helm-charts/kube-prometheus-stack/67.0.0
```

### 1단계: values 전략 재구성 (4,993줄 → 11줄)

```bash
# 1. 리팩토링 전 baseline 렌더 저장
helm template kube-prometheus-stack helm-charts/kube-prometheus-stack/67.0.0 \
  -f helm-charts/kube-prometheus-stack/67.0.0/values.yaml \
  -f helm-charts/kube-prometheus-stack/67.0.0/values-dev.yaml > /tmp/baseline-render.yaml

# 2. values.yaml 최소화 + Chart.yaml 을 upstream 메타데이터 스타일로 재구성 (파일 수정)

# 3. 리팩토링 후 렌더 재실행
helm template kube-prometheus-stack helm-charts/kube-prometheus-stack/67.0.0 \
  -f helm-charts/kube-prometheus-stack/67.0.0/values.yaml \
  -f helm-charts/kube-prometheus-stack/67.0.0/values-dev.yaml > /tmp/after-render.yaml

# 4. 동일성 검증 — 출력이 없으면 렌더 결과가 byte 단위로 동일
diff /tmp/baseline-render.yaml /tmp/after-render.yaml
```

> 검증 결과: diff 출력 없음 (완전 동일). upstream 기본값을 values.yaml 에 복사하는 것은
> 순수 중복이며, 환경별 파일에 변경분만 적어도 렌더 결과가 같음을 확인.

## 주의사항

- 환경별 values 파일에서 override 없이 `kube-prometheus-stack:` 키만 값 없이(null) 남기면
  Helm이 `values.yaml`의 해당 subtree 전체를 삭제합니다. override가 없으면 키 자체를
  주석 처리해둡니다.
- prometheus-operator CRD는 256KB를 초과하므로 ArgoCD sync 시 `ServerSideApply=true`,
  `ApplyOutOfSyncOnly=true` 옵션이 필요합니다 (`apps/<env>/monitoring/templates/kube-prometheus-stack.yaml` 참고).
