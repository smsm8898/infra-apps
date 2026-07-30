# alloy 1.10.0

> [Grafana Alloy 공식 Helm 차트](https://github.com/grafana/alloy/tree/main/operations/helm/charts/alloy)
> (chart version `1.10.0`, appVersion `v1.17.0`)를 upstream dependency로 wrapping한 차트입니다.
> pod 로그를 수집해 Loki 로 push 하는 DaemonSet 입니다.

## Upstream 출처

| 항목 | 값 |
|---|---|
| Helm repo | `https://grafana.github.io/helm-charts` |
| 소스 코드 | https://github.com/grafana/alloy (`operations/helm/charts/alloy`) |
| Chart version | `1.10.0` |
| App version | `v1.17.0` |

## 차트 받아오기

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana
helm pull grafana/alloy --version 1.10.0
```

## 구조

```
1.10.0/
├── Chart.yaml         # upstream 메타데이터 + alloy 1.10.0 dependency 선언
├── Chart.lock         # dependency 버전 핀
├── values.yaml        # River 수집 설정 전체 (환경 공통)
├── values-dev.yaml    # clustering off 만
├── values-prod.yaml   # clustering off 만
└── charts/            # vendored upstream tgz
```

**환경 분기가 거의 없다.** Loki 가 같은 namespace 에 같은 Service 명으로 뜨므로 push 주소가
dev/prod 동일하고, 수집 대상도 "그 클러스터의 전부" 라 환경별로 다를 게 없다.

## 수집 파이프라인 (River)

```
discovery.kubernetes "pods"        # spec.nodeName 셀렉터로 자기 노드 pod 만
        │
discovery.relabel "pod_logs"       # __meta_* -> namespace / pod / container / app
        │
loki.source.kubernetes "pod_logs"  # Kubernetes API 로 컨테이너 로그 읽기
        │
loki.process "drop_health"         # /health 액세스 로그 drop
        │
loki.write "default"               # http://loki.monitoring.svc.cluster.local:3100
```

**왜 DaemonSet 인가**: `loki.source.kubernetes` 는 K8s API 로 로그를 읽으므로 원리상
Deployment 1개로도 전 클러스터 로그를 긁을 수 있다. 그럼에도 DaemonSet 인 이유는 일을 노드
수만큼 나누기 위해서다 — 파드 하나가 수천 컨테이너의 로그 스트림을 들고 있으면 그게 병목이자
단일 장애점이 된다. `clustering: false` 도 같은 맥락이다(DaemonSet + 노드 필터가 이미
분할을 끝냈다).

**노드 필터가 없으면 N중 적재된다.** 노드가 10개면 Alloy 도 10개이고, 각자 전체 pod 를
수집하면 모든 로그가 10번 저장된다. `discovery.kubernetes` 의 `selectors.field` 로
자기 노드(`K8S_NODE_NAME`) pod 만 자른다.

**`tolerations: [{operator: Exists}]` 가 필수다.** 테인트가 걸린 노드그룹(`dev-ng` 등)은
기본적으로 파드를 받지 않는다. "모든 노드" 가 목적인데 toleration 이 없으면 테인트 노드만
로그가 조용히 누락된다. 같은 이유로 `nodeSelector` 를 걸지 않는다 — Loki(StatefulSet)는
특정 노드그룹에 고정하지만 Alloy 에 그걸 걸면 다른 노드그룹 로그를 못 받는다.

`loki.source.kubernetes` 는 hostPath(`/var/log/pods`) 마운트가 필요 없다. 필요한
`pods/log` 권한은 차트 기본 ClusterRole 에 이미 포함되어 있다(렌더로 확인).

## 렌더링 및 검증

```bash
helm template alloy helm-charts/alloy/1.10.0 -n monitoring \
  -f helm-charts/alloy/1.10.0/values.yaml \
  -f helm-charts/alloy/1.10.0/values-dev.yaml
```

**River 설정은 실제 Alloy 바이너리로 검증한다.** `helm template` 은 ConfigMap 안의 River
문자열을 검사하지 않으므로 컴포넌트명 오타나 인자명 오류를 못 잡는다.

```bash
# 렌더된 ConfigMap 에서 config.alloy 추출 후
docker run --rm -v "$PWD:/w" grafana/alloy:v1.17.0 fmt /w/config.alloy      # 문법
docker run --rm -v "$PWD:/w" grafana/alloy:v1.17.0 validate /w/config.alloy # 스키마
```

`validate` 는 컴포넌트명과 인자 스키마까지 본다. 일부러 망가뜨려 확인했다:

```
drop_counter_reason -> drop_counter_reasonX
  Error: unrecognized attribute name "drop_counter_reasonX"
loki.source.kubernetes -> loki.source.kubernetesX
  Error: cannot find the definition of component name "loki.source.kubernetesX"
```

`fmt` 출력은 탭 들여쓰기라 values 안의 스페이스 정렬과 다르게 나온다 — 문법 유효성과 무관한
정규 포맷 차이다.

## 작업 이력

### 0단계: 뼈대 + baseline

wrapper Chart.yaml + `helm dependency build`. 기본값 렌더 **6개 리소스**
(SA / Service / DaemonSet / ConfigMap / ClusterRole / ClusterRoleBinding).

### 4단계: River 수집 설정

리소스 수는 6개로 그대로(설정만 채움). dev/prod 리소스 구성 동일.

**차트가 이미 `K8S_NODE_NAME` 을 주입한다** — `containers/_agent.yaml:35` 에서 모든
컨테이너에 무조건 `fieldRef: spec.nodeName` 으로 넣고, 주석에 `Default used by some Alloy
components` 라고 적혀 있다. 회사 구현은 같은 값을 `NODE_NAME` extraEnv 로 한 번 더
선언했는데 중복이므로, 차트 제공 변수를 쓰고 `extraEnv` 블록을 제거했다.

`storagePath`(`/tmp/alloy`, 컨테이너 args 의 `--storage.path` 와 일치)에 WAL 과 읽은 위치
(positions)가 쌓인다. emptyDir 을 붙여두면 컨테이너 재시작 시 같은 파드 안에서는 이어
읽는다. 파드가 다른 노드로 재스케줄되면 초기화된다.

### 7단계: ArgoCD app-of-apps 등록

`apps/{dev,prod}/monitoring/templates/alloy.yaml`. Loki 와 달리 CR 을 만들지 않고 PVC 도
없어서 `syncOptions` 추가나 `ignoreDifferences` 가 필요 없다.

## 회사 구현과 다르게 간 부분

1. **vendoring 함** (개인 repo 컨벤션).
2. **`NODE_NAME` extraEnv 제거** — 차트가 주는 `K8S_NODE_NAME` 사용. 위 4단계 참고.
3. **`ServerSideApply` 미적용** — 거대 CRD 가 없다.

## 주의사항

- **`/health` drop 은 구조화 액세스 로그를 전제한다.** `expression` 이
  `"http.route": "/health"` 패턴을 문자열로 매칭하므로, 로그 포맷이 바뀌면 조용히 매칭에
  실패해 노이즈가 다시 들어온다. drop 된 양은 Alloy 메트릭
  `loki_process_dropped_lines_total` 로 확인한다(메트릭명은 v1.17.0 바이너리에서 확인.
  `drop_counter_reason = "health_check"` 값이 이 카운터의 reason 라벨로 붙는다).
- **relabel 로 승격하는 라벨은 4개로 제한했다** (`namespace`/`pod`/`container`/`app`).
  Loki 라벨은 스트림을 쪼개므로 카디널리티가 곧 비용이다. `pod` 는 재배포마다 값이 바뀌어
  이미 카디널리티가 높다 — 여기에 라벨을 더 추가하기 전에 조회에 정말 쓰는지 확인한다.
- Alloy 는 전 노드에 뜨므로 리소스 요청이 노드 수만큼 곱해진다(50m/128Mi × 노드 수).
