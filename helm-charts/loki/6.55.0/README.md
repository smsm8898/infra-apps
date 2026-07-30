# loki 6.55.0

> [Grafana Loki 공식 Helm 차트](https://github.com/grafana/loki/tree/main/production/helm/loki)
> (chart version `6.55.0`, appVersion `3.6.7`)를 upstream dependency로 wrapping한 차트입니다.
> SingleBinary(monolithic) 모드로 로그를 저장하고, 내장 ruler로 LogQL 알림을 평가합니다.

## Upstream 출처

| 항목 | 값 |
|---|---|
| Helm repo | `https://grafana.github.io/helm-charts` |
| 소스 코드 | https://github.com/grafana/loki (`production/helm/loki`) |
| Chart version | `6.55.0` |
| App version | `3.6.7` |

## 차트 받아오기

```bash
# Helm repo 등록
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana

# 6.55.0 버전 다운로드 (압축 해제 시 --untar 추가)
helm pull grafana/loki --version 6.55.0
```

## 구조

```
6.55.0/
├── Chart.yaml         # upstream 메타데이터 + loki 6.55.0 dependency 선언
├── Chart.lock         # dependency 버전 핀
├── values.yaml        # 최소 base (SingleBinary 전환 + 코어 config)
├── values-dev.yaml    # dev: emptyDir, retention 168h, LogQL 룰 7개
├── values-prod.yaml   # prod: S3(thanos objstore) + PVC, retention 720h, LogQL 룰 6개
└── charts/            # vendored upstream tgz (helm dependency build 산출물)
```

`templates/` 가 없다. 커스텀 리소스(룰 ConfigMap)는 차트의 `extraObjects` 로 넣는데,
이건 사이드카가 `loki_rule` 라벨로 감시하는 대상이어야 해서 차트 안에서 만들어야 한다.

## 로그 파이프라인에서의 위치

```
pod stdout ──> alloy (DaemonSet, 수집) ──push──> loki (저장 + ruler 평가)
                                                  ├─> monitoring-alertmanager:9093 ─> Slack
                                                  └<─ grafana (조회, kps 의 Loki datasource)
```

- 수집: `helm-charts/alloy/1.10.0`
- 알림 라우팅/Slack: `helm-charts/kube-prometheus-stack/67.0.0` (Alertmanager 재사용)
- 조회: 같은 kps 차트의 `grafana.additionalDataSources`

**알림과 조회는 독립 경로다.** 알림은 Loki 내장 ruler 가 자기 안에서 평가해 Alertmanager 로
직접 push 하므로 Grafana datasource 가 없어도 발화한다. 반대로 datasource 만 있고 ruler
설정이 없으면 조회는 되지만 알림은 안 온다.

## 렌더링 및 검증

```bash
helm template loki helm-charts/loki/6.55.0 -n monitoring \
  -f helm-charts/loki/6.55.0/values.yaml \
  -f helm-charts/loki/6.55.0/values-dev.yaml \
  --api-versions monitoring.coreos.com/v1/ServiceMonitor
```

**`--api-versions` 를 반드시 붙인다.** ServiceMonitor 템플릿이
`Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor"` 로 게이트되어
있어서, 클러스터 연결이 없는 offline 렌더에서는 `enabled: true` 를 줘도 **에러도 경고도
없이 조용히 탈락**한다.

**`helm lint` 는 게이트로 쓸 수 없다.** 이 차트는 `templates/` 가 없어서 lint 가 subchart
를 렌더조차 하지 않는다(`[WARNING] templates/: directory does not exist`). 렌더가 실패하는
values 로도 `0 chart(s) failed`, exit 0 이 나온다. `templates/` 가 있는 wrapper(kps,
airflow)에서도 subchart 의 `fail`/`required` 는 `level=WARN` 로그로만 남고 exit 0 이다.
**검증 게이트는 `helm template` 뿐이다.** (helm 4.1.1 기준)

## 작업 이력 (실행한 명령어)

### 0단계: 뼈대 구성 — upstream 차트 받아오기

```bash
# 1. wrapper Chart.yaml + 주석만 있는 values 3종 작성 후 dependency 빌드
helm dependency build helm-charts/loki/6.55.0

# 2. baseline 측정 — upstream 기본값 렌더
helm template loki helm-charts/loki/6.55.0 -n monitoring -f .../values.yaml
```

기본값(`deploymentMode: SimpleScalable` + `storage.type: s3`)은 **렌더 자체가 실패**했다:
`Please define loki.storage.bucketNames.chunks`. schema_config 도 차트가 `fail` 로 강제한다
("individual for every Loki cluster"). 더미 버킷명 + tsdb v13 을 준 임시 values 로 baseline
을 측정: **30개 리소스**, 워크로드 8개(write/backend/chunks-cache/results-cache StatefulSet,
read/gateway Deployment, canary DaemonSet, helm-test Pod), Service 12개.

`values.yaml` 에 `loki:` 키만 두고 값을 비우지 않았다 — Helm coalesce 가 subchart 기본값
subtree 를 통째로 삭제하기 때문(kps 1단계에서 확인한 함정). 주석만 남겼다.

### 1단계: SingleBinary 모드 전환

```bash
# 전환 후 baseline 과 리소스 목록 diff
helm template ... > step1.yaml
awk '/^kind: /{k=$2} /^  name: /{if(k){print k"/"$2; k=""}}' baseline.yaml | sort -u > a
awk '/^kind: /{k=$2} /^  name: /{if(k){print k"/"$2; k=""}}' step1.yaml   | sort -u > b
comm -23 a b   # 사라진 것
comm -13 a b   # 생긴 것
```

**30 → 9개 리소스, 워크로드 8 → 1개**(`StatefulSet/loki`, `-target=all`). Service 12 → 3개
(`loki`, `loki-headless`, `loki-memberlist`).

발견 3가지:
- **rules 사이드카(k8s-sidecar)가 기본값으로 이미 가동 중**이다. `METHOD=WATCH`,
  `LABEL=loki_rule`, `FOLDER=/rules`, `RESOURCE=both`. 3단계에서 켤 게 아니라 폴더만 옮긴다.
- `Service/loki` 포트 3100. 릴리스명이 차트명과 같아 fullname 이 `loki-loki` 가 아니라
  `loki` 로 나온다 → Alloy push 주소와 app-of-apps `releaseName` 고정의 전제.
- filesystem 경로가 `chunks_directory: /var/loki/chunks`, `rules_directory: /var/loki/rules`
  로 렌더된다 → 2단계에서 emptyDir 을 `/var/loki` 에 붙이는 근거.

### 2단계: dev emptyDir 스토리지 + 스케줄링 + ServiceMonitor

```bash
# persistence off 만 주고 볼륨이 어떻게 되는지 확인
helm template loki ... --set loki.singleBinary.persistence.enabled=false > novol.yaml
awk '/^      volumes:/,/^---/' novol.yaml | grep name:
grep -c "mountPath: /var/loki" novol.yaml   # 0
```

**`persistence: false` 는 PVC 만 지우는 게 아니다.** 차트가
`singleBinary.persistence.enabled` 하나로 `volumeClaimTemplates` 와 `/var/loki`
**볼륨마운트를 같이** 게이트한다(`statefulset.yaml:141`, `:287`). 그대로 두면 Loki 가
`path_prefix: /var/loki` 를 **컨테이너 루트 파일시스템**에 쓰게 되어 상한 없이 노드
`ephemeral-storage` 를 잡아먹는다. `extraVolumes`/`extraVolumeMounts` 는 기존 emptyDir 을
덮어쓰는 게 아니라 **없어진 볼륨을 공급하는** 것이다.

ServiceMonitor 는 위 `--api-versions` 함정 때문에 처음엔 리소스 수가 안 늘어 발견했다.
`release: kube-prometheus-stack` 라벨은 보험이다 — kps Prometheus CR 이
`serviceMonitorSelector: {}`(전체 선택)로 렌더되는 것을 확인했다.

### 3단계: 내장 ruler + LogQL 알림

```bash
# 차트 네이티브 경로(ruler.directories)가 SingleBinary 에서 동작하는지 확인
helm template loki ... --set-file /dev/null > /dev/null   # (실제로는 임시 values 로)
grep "name: loki-rules" out.yaml    # 없음 — 리소스 수도 그대로

# escape 없이 렌더해 함정 재현
helm template ... 2>&1 | grep "undefined variable"
```

**차트 네이티브 룰 경로는 SingleBinary 에서 작동하지 않는다.** `ruler.directories` 는
`templates/ruler/configmap-ruler.yaml` 과 전용 ruler StatefulSet 에서만 소비된다.
SingleBinary 모드에선 그 워크로드가 없어 **ConfigMap 조차 생기지 않는다**. SingleBinary
파드가 마운트하는 룰 볼륨은 사이드카의 `sc-rules-volume`(emptyDir) 하나뿐이다.
→ `extraObjects` + `loki_rule` 라벨 ConfigMap + 사이드카가 **유일한 경로**.

**`extraObjects` 는 `tpl` 을 거친다.** 룰 안의 `{{ $labels }}` / `{{ $value }}` 를 그대로
두면 Helm 이 자기 변수로 파싱하려다 렌더가 죽는다:

```
error calling tpl: ... template: gotpl:19: undefined variable "$labels"
```

조용한 누락이 아니라 하드 에러다(실무적으로는 이쪽이 낫다 — 빈 문자열이 됐다면 쓸모없는
알림이 배포됐을 것). backtick 으로 감싸 문자열 리터럴로 통과시킨다:

```yaml
# values 에 쓰는 형태 (Helm 은 backtick 안을 문자열로 통과시킨다)
summary: "[{{`{{ $labels.namespace }}`}}] 에러 급증 — 최근 5m {{`{{ $value }}`}}건"
# 렌더 결과 (Alertmanager 가 평가할 형태로 남는다)
summary: "[{{ $labels.namespace }}] 에러 급증 — 최근 5m {{ $value }}건"
```

`sidecar.rules.folder: /rules/fake` — ruler 의 local storage 는 `/rules/<tenant>/` 구조를
기대하고, `auth_enabled: false` 의 테넌트명은 `fake` 다.

**리소스 9 → 11개**(ServiceMonitor + 룰 ConfigMap), alert 7개 / 그룹 2개:

| 그룹 | 룰 | LogQL 파이프라인 |
|---|---|---|
| `reco-api.logs` | `LogAppExceptionRaised`, `LogHigh5xxRate`, `LogErrorRateSpike`, `LogVolumeSpike` | `\| json` (구조화 로그) |
| `airflow.logs` | `LogAirflowTaskFailed`, `LogAirflowDbError`, `LogAirflowGitSyncFailed` | `\|=` / `\|~` (텍스트) |

`LogAirflowGitSyncFailed` 의 `container="git-sync"` 라벨은 Alloy 의 relabel 이 만든다.
airflow 3단계에서 찾은 `ref`/`branch` 버그처럼 DAG 동기화가 조용히 멈추는 상황을 잡는다.

### 4~5단계: Alloy / Grafana datasource

`helm-charts/alloy/1.10.0/README.md` 와
`helm-charts/kube-prometheus-stack/67.0.0/values-{dev,prod}.yaml` 참고.

### 6단계: prod S3(thanos objstore) 미러링

```bash
# override 전 — ruler_storage 가 무엇으로 렌더되는지 확인
python3 -c "import yaml; ... print(cfg['ruler_storage'])"
```

**이번 프로젝트 최대 함정.** `use_thanos_objstore: true` 는 최상위에 thanos 스타일
`ruler_storage` 블록을 따로 만들고, 이게 `rulerConfig.storage`(local)보다 우선한다.
override 전 렌더에 두 블록이 동시에 나온다:

```yaml
ruler_storage:            # use_thanos_objstore 가 만든 것 — 우선순위 높음
  backend: s3
  s3: {bucket_name: prod-logs-loki, endpoint: s3.ap-northeast-2.amazonaws.com, ...}
  storage_prefix: loki
ruler:
  storage: {type: local, local: {directory: /rules}}    # 내가 넣은 것 — 무시됨
```

ruler 가 빈 S3 를 보므로 사이드카가 `/rules/fake` 에 떨군 룰이 로드되지 않는다.
**에러가 나지 않는다** — Loki 는 정상 기동하고 조회도 되고 알림만 하나도 안 온다. prod 에서
이걸 발견하는 경로는 "장애가 났는데 알림이 안 왔다" 뿐이다.

해결: `structuredConfig` 로 `ruler_storage` 만 local 로 되돌린다. 청크/인덱스는 그대로
thanos S3 를 쓰는 것을 확인했다(`common.storage.object_store` = s3, schema object_store = s3,
compactor `delete_request_store` = s3).

prod 는 `persistence.enabled: true` 라 `/var/loki` 마운트가 PVC 에서 자동으로 나온다 —
2단계 발견을 반대 방향에서 확인한 셈이고, 그래서 prod 엔 `extraVolumes` 가 필요 없다.

### 7단계: ArgoCD app-of-apps 등록

```bash
helm lint apps/dev/monitoring -f apps/dev/monitoring/values.yaml
helm template monitoring apps/dev/monitoring -f apps/dev/monitoring/values.yaml
```

`releaseName: loki` 고정이 **필수**다. 차트 fullname 이 릴리스명에서 나와 Service 명이
`loki` 가 되는데, Alloy 의 `loki.write` URL 과 Grafana datasource 가 그 주소를 문자열로
참조한다. 릴리스명이 바뀌면 push 와 조회가 동시에 끊긴다.

`ignoreDifferences` 로 `StatefulSet/loki` 의 `/spec/volumeClaimTemplates` 를 제외한다.
API 서버가 `volumeMode` 등을 defaulting 하고 이 필드는 immutable 이라 영구 OutOfSync 가
된다(PVC 를 쓰는 prod 만 해당, dev emptyDir 엔 무해).

`SkipDryRunOnMissingResource=true` 를 추가했다 — 차트가 ServiceMonitor(CR)를 만들므로,
신규 클러스터에서 kps 가 CRD 를 심기 전에 이 앱이 먼저 sync 되면 dry-run 이 실패한다.
`ServerSideApply` 는 붙이지 않았다: kps 와 달리 거대 CRD 가 없다.

## 최종 상태

| | dev | prod |
|---|---|---|
| 리소스 | 11개 | 11개 |
| alert | 7룰 | 6룰 (`LogVolumeSpike` 제외) |
| retention | 168h | 720h |
| 청크 저장소 | filesystem (emptyDir 10Gi) | S3 thanos objstore (prefix `loki`) |
| 데이터 볼륨 | emptyDir `sizeLimit: 10Gi` | gp2 PVC 10Gi |
| `ruler_storage` | (블록 없음) | `backend: local` (override) |
| 리소스 요청 | 100m/256Mi → 500m/1Gi | 200m/2Gi → 1/2Gi (memory requests==limits) |
| 노드 | `dev-ng` | `prod-ng` |

## 회사 구현과 다르게 간 부분

1. **vendoring 함** — 개인 repo 컨벤션(kps·airflow)과 오프라인 렌더를 위해 `Chart.lock` +
   `charts/*.tgz` 를 커밋한다. 회사는 미적용. helm 4.1.1 은 `Chart.lock` 없이도
   `dependency build` 가 update 로 폴백해 성공하므로 회사 방식도 동작한다.
2. **룰 대상 재설계** — 참고한 구현의 대상 네임스페이스가 이 스택에 없다.
   `reco`(JSON 로그)와 `airflow`(텍스트 로그) 두 그룹으로 재작성했고, Kafka·DLQ 관련 룰은
   대상 서비스가 없어 제외했다. `airflow.logs` 그룹은 신설분이다.
3. **`ServerSideApply` 미적용** — 위 7단계 참고.

## 주의사항 / 배포 전 수동 준비물

- **prod S3 버킷**: `prod-logs-loki` (values 의 버킷명은 placeholder). 라이프사이클 정책은
  Loki compactor 의 retention 과 충돌하지 않게 둔다 — 삭제는 compactor 가 한다.
- **prod 자격증명**: **EKS Pod Identity** 로 `loki` ServiceAccount 에
  `prod-loki-sa-role` 을 연결한다(`aws eks create-pod-identity-association`). values 에
  annotation 이 없는 것이 정상이다.
  개인 repo 의 airflow/reco-api 는 IRSA(`eks.amazonaws.com/role-arn` annotation) 방식이라
  다르다. IRSA 는 SA annotation + OIDC provider 신뢰관계가 필요하고, Pod Identity 는
  클러스터 밖에서 association 을 만들며 annotation 이 필요 없다. 회사 구현을 그대로 뒀다.
- **`retention_enabled: true` 없으면 삭제가 안 된다.** `limits_config.retention_period`
  만 설정하면 조회 필터로만 쓰이고 디스크/오브젝트는 계속 쌓인다.
- **dev 는 로그 유실을 허용한다** (emptyDir). 파드가 재스케줄되면 그전 로그는 사라진다.
- ruler 룰을 바꿀 때는 렌더 후 `{{ $labels }}` 가 리터럴로 살아있는지 확인한다(위 3단계).
