# airflow 1.18.0

> [Apache Airflow 공식 Helm 차트](https://github.com/apache/airflow/tree/main/chart)
> (chart version `1.18.0`, appVersion `3.0.2`)를 upstream dependency로 wrapping한 차트입니다.

## Upstream 출처

| 항목 | 값 |
|---|---|
| Helm repo | `https://airflow.apache.org/` |
| 소스 코드 | https://github.com/apache/airflow (`chart/`) |
| Chart version | `1.18.0` |
| App version | `3.0.2` (Airflow 3.x) |

## 차트 받아오기

```bash
# Helm repo 등록
helm repo add apache-airflow https://airflow.apache.org
helm repo update apache-airflow

# 1.18.0 버전 다운로드 (압축 해제 시 --untar 추가)
helm pull apache-airflow/airflow --version 1.18.0
```

## 구조

```
1.18.0/
├── Chart.yaml         # upstream 메타데이터 + airflow 1.18.0 dependency 선언
├── values.yaml        # 최소 base 파일 (환경 공통 기본값만)
├── values-dev.yaml    # dev 환경: upstream 기본값 대비 변경분만
├── values-prod.yaml   # prod 환경: upstream 기본값 대비 변경분만
├── charts/            # vendored upstream tgz (helm dependency build 산출물)
└── templates/         # 커스텀 리소스 (환경 분기 시크릿, RBAC 등)
```

**values 전략**: upstream 기본값(3,085줄)을 values.yaml에 복사하지 않는다.
kube-prometheus-stack 1단계에서 "기본값 복사 = 순수 중복(렌더 동일)"을 검증했으므로
처음부터 최소 base + 환경별 변경분만 관리한다.

## 렌더링 및 검증

```bash
helm dependency build helm-charts/airflow/1.18.0

helm template airflow helm-charts/airflow/1.18.0 \
  -f helm-charts/airflow/1.18.0/values.yaml \
  -f helm-charts/airflow/1.18.0/values-dev.yaml
```

## 작업 이력 (실행한 명령어)

### 0단계: 뼈대 구성 — upstream 차트 받아오기

```bash
# 1. Helm repo 등록 및 갱신
helm repo add apache-airflow https://airflow.apache.org
helm repo update apache-airflow

# 2. upstream 차트 다운로드 (기본값 참조용 — 작업 디렉토리 밖에 untar)
helm pull apache-airflow/airflow --version 1.18.0 --untar

# 3. wrapper Chart.yaml + 최소 values 작성 후 dependency 빌드
helm dependency build helm-charts/airflow/1.18.0

# 4. 렌더 smoke test — 기본값(CeleryExecutor)으로 39개 리소스, lint 통과
helm template airflow helm-charts/airflow/1.18.0 -f .../values.yaml -f .../values-dev.yaml
```

> 기본값 렌더에는 CeleryExecutor 구성(redis/worker StatefulSet, 내장 postgresql)이
> 포함된다 — 1단계에서 KubernetesExecutor 로 전환하며 이 구성이 어떻게 줄어드는지 관찰 예정.

### 1단계: 코어 아키텍처 (KubernetesExecutor 전환)

```bash
# 1. baseline 저장 (CeleryExecutor 기본값)
helm template airflow . -f values.yaml -f values-dev.yaml > /tmp/step0.yaml

# 2. values-dev.yaml 에 executor/redis/스케줄링/cleanup 적용 후 재렌더
helm template airflow . -f values.yaml -f values-dev.yaml > /tmp/step1.yaml

# 3. 무엇이 사라지고 무엇이 생겼는지 diff
diff <(grep -E "^  name: " /tmp/step0.yaml | sort -u) \
     <(grep -E "^  name: " /tmp/step1.yaml | sort -u)
```

> 검증 결과 (리소스 39개 → 37개):
> - **사라짐**: `airflow-redis`(StatefulSet/Service/ServiceAccount), `airflow-redis-password`
>   (Secret), `airflow-worker`(celery worker StatefulSet) — CeleryExecutor 전용 구성
> - **생김**: `airflow-cleanup`(CronJob + Role/RoleBinding) — KubernetesExecutor 가
>   만들어내는 dangling task pod 정리용
> - 남은 redis/celery 문자열 28개는 전부 템플릿 헤더 **주석**(`## Airflow Redis StatefulSet` 등)
> - `AIRFLOW__CORE__EXECUTOR=KubernetesExecutor` env 반영 확인
>
> 최종 워크로드 9개: Deployment(api-server, dag-processor, scheduler, statsd),
> StatefulSet(postgresql, triggerer), CronJob(cleanup), Job(create-user, run-airflow-migrations).
> Airflow 3.x 구조 특징 — webserver 가 **api-server** 로 바뀌고, DAG 파싱이
> **dag-processor** 로 분리됨.

**함정 발견**: `defaultAirflowRepository` 를 placeholder 로 null 로 두면
`image: %!s(<nil>):latest` 로 렌더되어 **YAML 파싱 자체가 실패**한다.
kube-prometheus-stack 4단계에서 확인한 "null annotation 은 조용히 탈락" 은
map 값에만 해당하고, 문자열 보간(printf)에 쓰이는 값은 렌더를 깨뜨린다.

### 2단계: 메타데이터 DB + 시크릿 부트스트랩

`templates/secrets-store.yaml`(SecretProviderClass) 신설 + values 에 외부 DB/시크릿 연결.

```bash
helm template airflow . -f values.yaml -f values-dev.yaml > /tmp/step2.yaml
diff <(grep -E "^  name: " /tmp/step1.yaml|sort -u) <(grep -E "^  name: " /tmp/step2.yaml|sort -u)

# CSI 볼륨이 실제로 어느 워크로드에 마운트됐는지 (Secret 동기화 발동 조건)
awk '/^kind: (Deployment|StatefulSet|CronJob|Job)$/{k=$2} /^  name: /{n=$2} \
  /secretProviderClass: airflow-secrets-store/{print k": "n}' /tmp/step2.yaml | sort -u
```

> 검증 결과 (37개 → 28개):
> - **사라짐**: `airflow-postgresql`(+`-hl` Service, StatefulSet) — 내장 DB 제거,
>   `airflow-metadata`/`airflow-fernet-key`/`airflow-api-secret-key`/`airflow-jwt-secret`
>   (차트 자동생성 Secret 4종) — 외부 주입으로 대체,
>   `airflow-broker-url` — brokerUrlSecretName 더미 트릭,
>   `airflow-run-airflow-migrations` — migrateDatabaseJob off
> - **생김**: `airflow-secrets-store`(SecretProviderClass)
> - CSI 볼륨은 6개 워크로드(scheduler/api-server/dag-processor/triggerer/cleanup/create-user)에
>   마운트, `SLACK_BOT_TOKEN` env 는 10개 컨테이너에 주입

시크릿 전달 경로 (한 고리라도 빠지면 pod 이 기동 실패):
```
AWS Secrets Manager (<env>/airflow/secrets, JSON)
  → SecretProviderClass.parameters.objects (jmesPath 로 필드 추출 → objectAlias)
  → pod 이 CSI 볼륨 마운트 (values 의 airflow.volumes/volumeMounts) ← 이때 동기화 발동
  → secretObjects 가 k8s Secret 생성 (airflow-metadata-secret, custom-fernet-key, …)
  → values 의 data.metadataSecretName / fernetKeySecretName 등이 참조
```

> 배운 것: ① `data.brokerUrlSecretName: "disabled"` 는 실제 secret 을 가리키는 게 아니라
> **차트의 자동생성을 막는 더미 이름** — KubernetesExecutor 에 불필요한 리소스를 없애는 트릭.
> ② `fernetKey` 는 install 시점 값이 고정 — 이후 변경하면 기존 암호화된 Connection/Variable
> 복호화 불가. ③ Airflow 3.x 는 `apiSecretKeySecretName`(구 webserverSecretKey 후속)과
> `jwtSecretName`(컴포넌트 간 인증) 두 키를 쓴다. **회사 구현은 `custom-jwt-secret` 을 CSI 로
> 만들면서 `jwtSecretName` 으로 연결하지 않아** 차트 자동생성분이 쓰이고 있었다 — 개인 repo 는
> 연결해서 재배포 시 값이 바뀌지 않게 함.
>
> 측정 함정 3: 렌더된 YAML 은 정규화되어 **따옴표가 벗겨진다** — values 에
> `secretProviderClass: "airflow-secrets-store"` 로 썼어도 렌더에는 따옴표가 없어
> grep 패턴에 따옴표를 넣으면 0건으로 오측정된다.

### 3단계: DAG 배포 (gitSync)

```bash
helm template airflow . -f values.yaml -f values-dev.yaml > /tmp/step3.yaml

# git-sync 사이드카가 어느 워크로드에 붙었는지
awk '/^kind: (Deployment|StatefulSet)$/{k=$2} /^  name: /{n=$2} \
  /- name: git-sync/{print k": "n}' /tmp/step3.yaml | sort -u

# 실제 체크아웃 대상 확인 (여기서 버그를 잡았다)
grep -E "GITSYNC_REF|GIT_SYNC_BRANCH|GITSYNC_REPO" -A1 /tmp/step3.yaml | grep value | sort -u
grep "dags_folder" /tmp/step3.yaml
```

> 검증 결과 (리소스 28개 유지 — 사이드카는 기존 워크로드에 추가되므로 리소스 수 불변):
> - git-sync 사이드카는 **dag-processor**(DAG 파싱)와 **triggerer**(deferrable operator
>   코드 로드)에 붙는다. Airflow 3.x 의 scheduler 는 DAG 파일을 직접 읽지 않으므로 제외 —
>   2.x 와 다른 지점.
> - `dags_folder = /opt/airflow/dags/repo/dags` — 마운트 경로 + `GITSYNC_LINK`(repo)
>   + `subPath`(dags) 조합으로 결정
> - deploy key 는 `/etc/git-secret/ssh` 에 `subPath: gitSshKey` 로 마운트

**🐛 버그 발견 — `branch` 만 설정하면 엉뚱한 브랜치를 체크아웃한다**

차트가 쓰는 git-sync 는 **v4.3.0** 이고, v4 는 `GITSYNC_REF` 환경변수로 체크아웃한다.
차트 템플릿은 `GITSYNC_REF`(= values 의 `ref`)와 `GIT_SYNC_BRANCH`(= `branch`, v3 레거시)를
**둘 다 내보내지만 v4 컨테이너는 REF 만 읽는다**. 따라서 `branch: main` 만 설정하면
upstream 기본값 `ref: v2-2-stable` 이 그대로 적용되어 존재하지 않는 브랜치를 계속
clone 시도하다 실패한다 (렌더에서 `GITSYNC_REF: "v2-2-stable"` 로 직접 확인).

> 회사 구현도 dev(`branch: develop`)/prod(`branch: main`) 모두 `ref` 를 설정하지 않아
> 같은 상태다. 개인 repo 는 `ref` + `branch` 를 함께 지정해 해소했다.
> — 이것이 "upstream 기본값을 values.yaml 에 복사해두면 위험한" 구체적 사례:
> 복사본 안에 `ref: v2-2-stable` 이 숨어 있는데 환경별 파일에서 `branch` 만 덮어쓰면
> 문제가 보이지 않는다.

### 4단계: KubernetesExecutor worker (pod template + RBAC + 로그)

```bash
helm template airflow . -f values.yaml -f values-dev.yaml > /tmp/step4.yaml

# task pod 스펙(pod_template_file.yaml)에 스케줄링/리소스가 반영됐는지
grep -n "pod_template_file.yaml:" /tmp/step4.yaml   # ConfigMap 안의 위치 확인
grep -A2 "^      nodeSelector:" /tmp/step4.yaml

# airflow.cfg 로 들어간 executor/logging 설정
grep -E "delete_worker_pods|remote_logging|remote_base_log_folder" /tmp/step4.yaml

# RBAC 범위 (multiNamespaceMode 효과)
grep -c "^kind: ClusterRole" /tmp/step4.yaml   # → 0 (Role/RoleBinding 만)
```

> 검증 결과 (리소스 28개 유지 — pod template 은 ConfigMap 내용, config 는 airflow.cfg 변경):
> - `pod_template_file.yaml` 에 `nodeSelector: node-group-name: dev-worker-ng`,
>   toleration, worker 리소스(requests 100m/256Mi, limits 1000m/2Gi) 반영
> - `[kubernetes_executor] delete_worker_pods = True`,
>   `delete_worker_pods_on_failure = False` 반영
> - `[logging] remote_logging = True`, `remote_base_log_folder = s3://…` 반영
> - `airflow-pod-launcher-role`(Role, namespace 한정)이 pods create/delete/watch 권한을
>   scheduler·worker ServiceAccount 에 부여. `multiNamespaceMode: false` 이므로
>   ClusterRole 은 생성되지 않음(0건)

**함정: `podTemplateFile:` 은 upstream 에 없는 키다.**
회사 구현은 `podTemplateFile.nodeSelector` 로 task pod 스케줄링을 설정했지만 이 키는
차트가 읽지 않는다(무해하지만 무의미). 실제로 task pod 스펙은
`files/pod-template-file.kubernetes-helm-yaml` 이 `workers.nodeSelector`
(없으면 최상위 `nodeSelector`)를 읽어 만든다. 전체 스펙을 직접 쓰려면 문자열 키
`podTemplate:` 을 써야 한다. 회사는 `workers.nodeSelector` 도 함께 설정해뒀기 때문에
결과적으로 정상 동작 중.

> 설계 연결점: `delete_worker_pods_on_failure: 'False'` 는 kube-prometheus-stack 6단계의
> `KubeContainerOOMKilled` 알림과 짝이다. 실패 pod 을 즉시 지우면 OOMKilled 상태가
> kube-state-metrics 스크랩 주기(30s) 안에 관측되지 않아 알림이 유실된다. 잔존 pod 정리는
> cleanup CronJob(15분)이 담당하므로 무한히 쌓이지도 않는다.
>
> task pod 은 종료되면 사라지므로 로그를 S3 로 내보낸다(`remote_logging`). PVC 공유
> 방식보다 RWX 스토리지가 불필요하고 보존 기간을 S3 라이프사이클로 관리할 수 있다.
> AWS 자격증명은 IRSA 로 해결 예정(7단계).

### 5단계: api-server + Ingress

```bash
helm template airflow . -f values.yaml -f values-dev.yaml > /tmp/step5.yaml
diff <(grep -E "^  name: " /tmp/step4.yaml|sort -u) <(grep -E "^  name: " /tmp/step5.yaml|sort -u)

awk '/^kind: Ingress/,/^---/' /tmp/step5.yaml    # 백엔드 서비스/포트/host 확인
```

> 검증 결과 (28개 → 27개):
> - **사라짐**: `airflow-create-user-job`(Job + SA) — `webserver.defaultUser.enabled: false`
> - **생김**: `airflow-ingress` — 백엔드가 `airflow-api-server` 서비스의 `api-server` 포트,
>   host `airflow.dev.example.com`
> - api-server 리소스(requests 100m/512Mi, limits 500m/1Gi) 반영
> - Role 3개 / RoleBinding 3개, SCC RoleBinding 0건(`createSCCRoleBinding: false`)
> - null placeholder annotation(ssl-certificate/group.name/load-balancer-attributes) 0건 —
>   **map 값이므로 조용히 탈락**(값이 있는 ssl-redirect 는 1건 유지). 1단계의
>   `defaultAirflowRepository` 와 대비되는 지점: 문자열 보간 값은 렌더를 깨뜨리지만
>   annotation map 은 안전하다.

> 배운 것: ① Airflow 3.x 는 Ingress 키가 **`ingress.apiServer`** 다 (`ingress.web` 은 2.x
> webserver 용, 최상위 `ingress.enabled` 는 deprecated). ② `webserver:` 섹션은 3.x 에서도
> 남아 있고 **create-user Job 이 `webserver.defaultUser` 를 참조**한다 — 컴포넌트는
> api-server 로 개편됐지만 values 키 구조는 과거 이름을 유지. ③ 기본 admin 자동 생성을
> 끄면 ArgoCD sync 마다 Job 이 재실행되는 것도 함께 사라진다.

### 6단계: 공용 ServiceAccount(IRSA) + Spark RBAC

커스텀 템플릿 2개 추가 — `service-account.yaml`, `spark-rbac.yaml`(`spark.enabled` 게이트).

```bash
helm template airflow . -f values.yaml -f values-dev.yaml > /tmp/step6.yaml
diff <(grep -E "^  name: " /tmp/step5.yaml|sort -u) <(grep -E "^  name: " /tmp/step6.yaml|sort -u)

# task pod 이 실제로 공용 SA 를 쓰는지 (IRSA·spark RBAC 의 전제)
grep "serviceAccountName" /tmp/step6.yaml | sort | uniq -c

# 게이트 검증
helm template ... --set spark.enabled=false | grep -c "spark-role"   # → 0
```

> 검증 결과 (27개 → 29개):
> - **사라짐**: `airflow-worker`(차트 자동생성 SA) — `workers.serviceAccount.create: false`
> - **생김**: `airflow-service-account`(IRSA annotation 부착),
>   `airflow-spark-role` + `airflow-spark-rolebinding`
> - `pod_template_file.yaml` 의 `serviceAccountName: airflow-service-account` 확인 →
>   task pod 이 IRSA role 로 S3 로그 업로드, spark RBAC 도 동일 SA 에 적용
> - `pod-launcher-rolebinding` subject 가 `airflow-scheduler` + `airflow-service-account`
>   두 개로 자동 갱신됨 (차트가 `workers.serviceAccount.name` 을 참조)
> - `spark.enabled=false` → spark RBAC 0건

> 배운 것: 두 RBAC 은 계층이 다르다 —
> `pod-launcher-role` 은 **scheduler 가 task pod 을 만드는** 권한,
> `spark-role` 은 **task pod(= spark driver)이 executor pod 을 만드는** 권한.
> Spark job 은 pod 이 pod 을 만드는 2단 구조라 별도 Role 이 필요하다.
>
> 측정 함정 4: 렌더의 따옴표 유무는 **차트 템플릿이 `| quote` 를 쓰는지에 달려 예측할 수
> 없다**. 2단계에서는 values 에 따옴표를 썼는데 렌더에서 벗겨졌고, 여기서는 values 에
> 따옴표 없이 썼는데 렌더에 붙었다(`serviceAccountName: "airflow-service-account"`).
> → grep 패턴에는 항상 따옴표를 넣지 않는다.

### 7단계: 메타DB 이력 정리 + prod 미러링

`templates/db-cleanup-cronjob.yaml`(`dbCleanup.enabled` 게이트) 신설 + values-prod.yaml 작성.

```bash
helm template airflow . -f values.yaml -f values-prod.yaml > /tmp/prod.yaml

# 환경 게이트: dbCleanup 은 prod 만
grep -c "airflow-db-cleanup" /tmp/dev.yaml    # → 0
grep -c "airflow-db-cleanup" /tmp/prod.yaml   # → 3

# prod 고유 설정
awk '/name: airflow-scheduler$/,/template:/' /tmp/prod.yaml | grep -A2 "strategy:"
```

> 검증 결과 (dev 29개 / prod 30개):
> - `dbCleanup` 게이트 정상 (dev 0건 / prod 3건 = CronJob + 관련 참조)
> - db-cleanup CronJob: schedule `0 18 * * 0`, activeDeadlineSeconds 5400,
>   `serviceAccountName: airflow-service-account`, 고정 태그 이미지,
>   `--clean-before-timestamp "$(date -u -d '90 days ago' …)"`, tables 8개
> - scheduler `strategy.type: Recreate` 반영
> - api-server memory requests == limits (2Gi) → Guaranteed QoS
> - 기밀 문자열 잔여 0건

dev/prod 철학 차이:

| 항목 | dev | prod |
|---|---|---|
| 이미지 태그 | `latest` (+ pod_template `pullPolicy: Always`) | 고정 버전 (재현 가능한 배포) |
| 리소스 | requests < limits (Burstable) | memory requests == limits (Guaranteed QoS) |
| dbCleanup | off (데이터량 적음) | on (90일 보존) |
| scheduler 배포 | RollingUpdate(기본) | **Recreate** |
| createUserJob | (기본) | `useHelmHooks: false` |

> 배운 것: ① **`airflow db clean` 에서 `dag_version`/`dag` 는 제외해야 한다.**
> `task_instance.dag_version_id` 가 ON DELETE CASCADE 라, 오래된 created_at 을 가진
> "최신" 버전(변경이 드문 안정 DAG)을 지우면 cutoff 이후의 최근 task_instance 까지 함께
> 삭제된다. `dag_run.created_dag_version_id` 는 NO ACTION 이라 FK 위반으로 작업이 중간에
> 실패한다. ② 무거운 CLI 는 **전용 파드**로 돌린다 — scheduler/api-server 파드 안에서
> 실행하면 그 컨테이너 cgroup 에 메모리가 잡혀 컴포넌트가 함께 죽는다. ③ `Recreate` 전략:
> RollingUpdate(maxUnavailable=0)는 교체 순간 구/신 파드를 동시에 안아야 해서, 무거운
> 컴포넌트가 같이 surge 하면 신규 파드가 영구 Pending 이 된다. replicas=1 이면 어차피
> 무중단이 아니므로 Recreate 가 안전하다.
>
> ⚠️ db-cleanup 이 마운트하는 config 볼륨은 `{{ .Release.Name }}-config` 를 참조한다.
> 릴리스명이 `airflow` 가 아니면 차트가 만드는 ConfigMap 이름과 어긋날 수 있으므로,
> ArgoCD Application 의 `releaseName` 을 `airflow` 로 고정해야 한다(8단계에서 설정).

## 주의사항

- 환경별 values 파일에서 override 없이 `airflow:` 키만 값 없이(null) 남기면
  Helm이 values.yaml의 해당 subtree 전체를 삭제합니다. override가 없으면 키 자체를
  주석 처리해둡니다.
