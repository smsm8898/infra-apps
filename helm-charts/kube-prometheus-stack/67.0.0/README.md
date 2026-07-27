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
├── Chart.yaml         # upstream kube-prometheus-stack 67.0.0 dependency 선언
├── values.yaml        # upstream 기본 values 전체를 kube-prometheus-stack: 키 아래에 nesting
├── values-dev.yaml    # dev 환경 override
├── values-prod.yaml   # prod 환경 override
├── dashboards/        # Grafana 대시보드 JSON
└── templates/         # 커스텀 리소스 (대시보드 ConfigMap 등)
```

ArgoCD가 이 디렉토리를 Helm chart로 렌더링하며, dependency는 ArgoCD repo-server가
직접 받아옵니다 (`charts/`, `Chart.lock`은 커밋하지 않음).

## 렌더링 및 검증

```bash
helm dependency build helm-charts/kube-prometheus-stack/67.0.0

helm template kube-prometheus-stack helm-charts/kube-prometheus-stack/67.0.0 \
  -f helm-charts/kube-prometheus-stack/67.0.0/values.yaml \
  -f helm-charts/kube-prometheus-stack/67.0.0/values-dev.yaml
```

## 주의사항

- 환경별 values 파일에서 override 없이 `kube-prometheus-stack:` 키만 값 없이(null) 남기면
  Helm이 `values.yaml`의 해당 subtree 전체를 삭제합니다. override가 없으면 키 자체를
  주석 처리해둡니다.
- prometheus-operator CRD는 256KB를 초과하므로 ArgoCD sync 시 `ServerSideApply=true`,
  `ApplyOutOfSyncOnly=true` 옵션이 필요합니다 (`apps/<env>/monitoring/templates/kube-prometheus-stack.yaml` 참고).
