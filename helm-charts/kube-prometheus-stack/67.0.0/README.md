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

### 2단계: Operator + 코어 수집기 (+ `_helpers.tpl` 함정 재현)

```bash
# 1. 함정 재현 전 baseline — upstream 리소스의 release 라벨 개수 측정
helm template kube-prometheus-stack helm-charts/kube-prometheus-stack/67.0.0 \
  -f .../values.yaml -f .../values-dev.yaml > /tmp/before-helpers.yaml
grep -c 'release: "kube-prometheus-stack"' /tmp/before-helpers.yaml   # → 120개

# 2. templates/_helpers.tpl 추가 (upstream 과 동명의 labels 헬퍼 정의) 후 재렌더
helm template ... > /tmp/after-helpers.yaml
grep -c 'release: "kube-prometheus-stack"' /tmp/after-helpers.yaml    # → 15개 (급감!)

# 3. 어떤 라벨이 사라졌는지 확인 — release/chart/heritage 가 전부 소실
diff /tmp/before-helpers.yaml /tmp/after-helpers.yaml | head -30

# 4. values-dev.yaml 에 2단계 설정 적용 후 selector 가 "전체 선택"이 됐는지 확인
helm template ... | grep -E "serviceMonitorSelector|ruleSelector"     # → {} (전체 선택)
```

> 검증 결과: named template 은 Helm 전역이라 wrapper 의 `_helpers.tpl` 이 upstream
> subchart 의 동명 헬퍼를 덮어씀 → release 라벨 120개 → 15개 (남은 15개는 자체 헬퍼를
> 쓰는 grafana/kube-state-metrics/node-exporter subchart). Prometheus CR 의 기본
> selector 는 `release=<릴리스명>` 라벨 매칭이므로 upstream ServiceMonitor/Rule 이
> 전부 선택에서 빠짐 → `*SelectorNilUsesHelmValues: false` 로 "전체 선택" 전환이 필수.

이 단계에서 values-dev.yaml 에 추가된 설정: `prometheusOperator`(webhook off, watch
namespace, 스케줄링), `prometheus.prometheusSpec`(retention/emptyDir/selector/externalLabels),
`kubelet`/`kubeStateMetrics`/`nodeExporter` on, `coreDns` selector 오버라이드,
`prometheus-node-exporter` 전체 taint 허용, `kube-state-metrics` nodegroup 핀.

### 3단계: defaultRules 선별 (recording rule 만 유지)

```bash
# 1. baseline — 기본 defaultRules 가 만드는 룰 측정
#    PrometheusRule 문서만 추출해서 alert/record 개수를 센다
#    (렌더 YAML 에서 recording rule 은 `- expr:` 로 시작하고 record: 가 뒤에 오므로
#     `- record:` 패턴으로 세면 0개로 잘못 나온다)
awk '/^kind: PrometheusRule/{r=1} /^---/{r=0} r' /tmp/render.yaml > /tmp/rules.yaml
grep -cE '^\s+- alert:' /tmp/rules.yaml   # → 145개 (알림)
grep -cE '^\s+record:' /tmp/rules.yaml    # → 85개 (recording)

# 2. values-dev.yaml 에 defaultRules.rules 그룹별 on/off 적용 후 재측정
#    → PrometheusRule 35개 → 12개, alert 145 → 0, record 85 → 44
```

> 검증 결과: 남은 12개 리소스는 전부 recording rule 그룹 — `k8s.rules.*`(container
> cpu/mem 집계 7개), `kubelet.rules`(quantile), `kube-prometheus-general.rules`,
> `kube-prometheus-node-recording.rules`, `node.rules`, `node-exporter.rules`(USE method).
> 기본 대시보드(k8s-resources-*, nodes, node-rsrc-use, kubelet)가 이 recording rule 의
> 결과 메트릭을 직접 조회하므로, 꺼버리면 대시보드가 전부 No data 가 된다.
> 알림 룰 145개를 끈 이유: 6단계에서 additionalPrometheusRulesMap 으로 필요한 알림만
> 직접 관리할 예정 (기본 알림은 노이즈가 많고 환경에 안 맞는 임계값이 섞여 있음).

### 4단계: Grafana provisioning + 커스텀 대시보드

```bash
# 1. 대시보드 JSON 작성 (dashboards/reco-api-monitoring.json)
#    JSON 유효성 + uid/패널 수 확인
python3 -c "import json; d=json.load(open('dashboards/reco-api-monitoring.json')); \
  print(d['uid'], len(d['panels']))"

# 2. templates/grafana-dashboard-reco-api.yaml 작성 (.Files.Get + grafana_dashboard 라벨)
#    values-dev.yaml 에 grafana 섹션 추가 후 렌더 검증
helm template kube-prometheus-stack . -f values.yaml -f values-dev.yaml > /tmp/r.yaml
grep -A8 "name: grafana-dashboard-reco-api" /tmp/r.yaml   # ConfigMap + 라벨 + JSON 임베드
grep -E '^\s+- name: grafana-sc-' /tmp/r.yaml             # sidecar 컨테이너 2개
awk '/^kind: Ingress/,/^---/' /tmp/r.yaml                 # ALB Ingress + host
```

> 대시보드 전달 경로: `dashboards/*.json` --(.Files.Get)--> ConfigMap(`grafana_dashboard: "1"`
> 라벨) --(sidecar 가 라벨 감시)--> `/tmp/dashboards` 에 파일 생성 --(dashboardProviders 의
> file provider)--> Grafana 로드. 어느 한 고리(라벨 이름, folder 경로, provider path)라도
> 어긋나면 대시보드가 안 뜬다.
>
> 확인한 것: values 에서 값이 null 인 annotation(ssl-certificate 등 placeholder)은 렌더에서
> 조용히 탈락 — placeholder 를 null 로 두는 개인 repo 컨벤션과 잘 맞음.
> grafana subchart 리소스 이름은 `kube-prometheus-stack-grafana` — 부모의 fullnameOverride
> 는 subchart 에 전파되지 않음 (subchart 는 자기 fullname 을 따로 계산).

### 5단계: reco-api PodMonitor 연결 검증 (코드 변경 없음)

앱 메트릭이 대시보드에 도달하는 전체 경로를 렌더 수준에서 검증:

```
reco-api 차트의 PodMonitor (ns: reco, 서비스별 3개, port: deploy-port, path: /metrics)
  → operator 가 발견 (--namespaces=<릴리스 ns>,reco ← prometheusOperator.namespaces.additional)
  → Prometheus CR 이 선택 (podMonitorSelector: {} + NilUsesHelmValues=false = 전체 선택)
  → 수집된 메트릭에 namespace="reco" 라벨
  → 대시보드 쿼리가 namespace="reco" 로만 필터 (job 하드코딩 없음, 31개 쿼리)
```

```bash
# PodMonitor 렌더 확인 (reco-api 차트)
helm template reco-api helm-charts/reco-api/0.1.0 -n reco \
  -f .../values.yaml -f .../values-dev.yaml | awk '/^kind: PodMonitor/,/^---/'

# operator 의 watch namespace 인자 확인 (monitoring 차트 렌더)
grep -- "--namespaces=" /tmp/render.yaml        # → --namespaces=<릴리스 ns>,reco

# 대시보드 쿼리의 라벨 매처 분포 확인
grep -oE '(job|namespace|service)=\\?"[^"\\]*' dashboards/reco-api-monitoring.json \
  | sort | uniq -c                              # → namespace="reco" 31개, job 없음
```

> 배운 것: ① 대시보드가 job 대신 namespace 로만 필터하므로 API 서비스가 늘어나도
> (PodMonitor 이름이 뭐든) 자동 커버된다. ② PodMonitor 의 `release: kube-prometheus-stack`
> 라벨은 현재 설정(전체 선택)에선 불필요하지만, 기본 selector 동작(release 라벨 매칭)으로
> 되돌아가는 순간 필수가 되는 안전벨트. ③ probeSelector 는 NilUsesHelmValues 를 안 건드려
> 여전히 라벨 매칭 — Probe CR 을 쓰게 되면 같은 함정이 재현될 지점.

## 주의사항

- 환경별 values 파일에서 override 없이 `kube-prometheus-stack:` 키만 값 없이(null) 남기면
  Helm이 `values.yaml`의 해당 subtree 전체를 삭제합니다. override가 없으면 키 자체를
  주석 처리해둡니다.
- prometheus-operator CRD는 256KB를 초과하므로 ArgoCD sync 시 `ServerSideApply=true`,
  `ApplyOutOfSyncOnly=true` 옵션이 필요합니다 (`apps/<env>/monitoring/templates/kube-prometheus-stack.yaml` 참고).
