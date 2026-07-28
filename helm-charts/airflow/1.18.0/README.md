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

## 주의사항

- 환경별 values 파일에서 override 없이 `airflow:` 키만 값 없이(null) 남기면
  Helm이 values.yaml의 해당 subtree 전체를 삭제합니다. override가 없으면 키 자체를
  주석 처리해둡니다.
