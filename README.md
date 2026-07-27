#  Infra Apps

> Kubernetes 인프라 애플리케이션 및 Helm 차트 관리 저장소
>
> ArgoCD 기반 GitOps로 운영되며, 애플리케이션 소스 코드 없이 Helm 차트와 배포 매니페스트만 관리합니다.

## 프로젝트 구조

```
infra-apps/
├── apps/                           # ArgoCD App-of-Apps 배포 설정
│   ├── dev/                        # 개발 환경
│   │   ├── arc-system/             # GitHub Actions Runner Controller
│   │   ├── monitoring/             # kube-prometheus-stack
│   │   └── reco/                   # 추천 시스템
│   └── prod/                       # 운영 환경
│       ├── arc-system/             # GitHub Actions Runner Controller
│       ├── monitoring/             # kube-prometheus-stack
│       └── reco/                   # 추천 시스템
├── helm-charts/                    # Helm 차트 라이브러리
│   ├── actions-runner-system/      # Self-hosted GitHub Actions Runner
│   │   ├── actions-runner-controller/  # ARC 컨트롤러 (upstream 차트 wrapping)
│   │   └── actions-runner/         # RunnerDeployment + HorizontalRunnerAutoscaler
│   ├── kube-prometheus-stack/      # 모니터링 스택 (upstream 차트 wrapping + 커스텀 대시보드/알림)
│   └── reco-api/                   # 추천 시스템
└── docker/                         # Docker 이미지 빌드 (각 하위 디렉토리 = 1 이미지 빌드 컨텍스트)
    └── actions-runner/             # Self-hosted GitHub Actions Runner
```

## 환경 구성

| 환경 | 설명 | ECR Registry |
|---|---|---|
| **dev** | 개발/테스트 | `dev위치.dkr.ecr.ap-northeast-2.amazonaws.com` |
| **prod** | 프로덕션 운영 | `prod위치.dkr.ecr.ap-northeast-2.amazonaws.com` |

- 리전: `ap-northeast-2` (서울)
- ArgoCD: Automated sync (`prune: true`, `selfHeal: true`)
- Dev 노드: `dev-ng` nodegroup에 고정
- Dev Ingress: AWS ALB, host 패턴 `<service>.dev.example.com`, access log 활성화

## 사용법

### Helm 차트 렌더링 및 검증

```bash
# 차트 렌더링 (base + 환경별 values 조합)
helm template <release> helm-charts/<chart>/<version> -n <namespace> \
  -f helm-charts/<chart>/<version>/values.yaml \
  -f helm-charts/<chart>/<version>/values-<env>.yaml

# 차트 린트
helm lint helm-charts/<chart>/<version> \
  -f helm-charts/<chart>/<version>/values.yaml \
  -f helm-charts/<chart>/<version>/values-<env>.yaml
```

### ArgoCD App-of-Apps 렌더링

```bash
helm template <release> apps/<env>/<domain> -f apps/<env>/<domain>/values.yaml
helm lint apps/<env>/<domain> -f apps/<env>/<domain>/values.yaml
```

### Docker 이미지 빌드

```bash
docker build --platform linux/amd64 --tag <repo>:<tag> \
  -f docker/<folder_path>/Dockerfile docker/<folder_path>
```

CI/CD는 GitHub Actions workflow dispatch로 실행합니다 (`.github/workflows/build_docker_image.{dev,prod}.yaml`).

## 컨벤션

- **차트 구조**: `helm-charts/<name>/<version>/` 버전별 디렉토리
- **네이밍**: Kubernetes 리소스 kebab-case. ArgoCD Application 이름은 서비스명과 일치.
- **이미지**: values 파일에서 repository + tag 관리, 템플릿에 하드코딩 금지.
- **레이블**: `example.com/environment`, `example.com/app-name`.
- **Ingress**: AWS ALB, dev 호스트 패턴 `<service>.dev.example.com`.
- **시크릿**: AWS Secrets Manager + Secrets Store CSI (`secrets-store.csi.k8s.io`).
- **최소 diff**: 인프라 변경 시 리팩토링 지양, 변경을 타겟에 한정.

## 요구사항

- Kubernetes 클러스터 (EKS)
- Helm 3.x
- kubectl
- ArgoCD
- AWS CLI (Docker 빌드 및 ECR 푸시 시)
