# Data Pipeline

MinIOのイベント通知とAirflowを使用したイベント駆動型データパイプラインシステム

## 概要

このプロジェクトは、MinIOへのファイルアップロードをトリガーとして、Airflow DAGを自動実行するイベント駆動型パイプラインを実装しています。

### アーキテクチャ

```
┌─────────────────┐
│  CronJob        │
│  Generator      │──────┐
└─────────────────┘      │
                         ▼
                  ┌─────────────┐
                  │   MinIO     │
                  │  (Storage)  │
                  └──────┬──────┘
                         │ Event Notification
                         ▼
                  ┌─────────────┐
                  │  Webhook    │
                  │  Receiver   │
                  └──────┬──────┘
                         │ Trigger DAG
                         ▼
                  ┌─────────────┐      ┌──────────────┐
                  │  Airflow    │─────▶│ Kubernetes   │
                  │  Scheduler  │      │ Pod (Worker) │
                  └─────────────┘      └──────────────┘
                         │
                         ▼
                  ┌─────────────┐
                  │   MinIO     │
                  │ (Processed) │
                  └─────────────┘
```

### 主要コンポーネント

1. **MinIO**: S3互換オブジェクトストレージ
   - `raw-data`: 生データ格納用バケット
   - `processed-data`: 処理済みデータ格納用バケット

2. **Webhook Receiver**: MinIOイベント通知を受信し、Airflow DAGをトリガー
   - Flask製のWebhookサーバー
   - Airflow REST APIを使用してDAGを実行

3. **Airflow**: ワークフローオーケストレーション
   - CeleryExecutorでタスクを分散実行
   - KubernetesPodOperatorでデータ処理を実行

4. **Generator CronJob**: ダミーデータを定期的に生成してMinIOにアップロード

5. **Processor**: Airflow DAGから起動されるデータ処理スクリプト

## ディレクトリ構造

```
apps/data-pipeline/
├── README.md
├── base/
│   ├── kustomization.yaml           # Kustomize base設定
│   ├── airflow-values.yaml          # Airflow Helm Chart values
│   ├── minio-values.yaml            # MinIO Helm Chart values
│   ├── config.env                   # 環境変数設定
│   ├── webhook-receiver.yaml        # Webhook Deployment/Service
│   ├── cronjob.yaml                 # Generator CronJob
│   ├── ingress.yaml                 # Ingress設定
│   ├── event-setup-job.yaml         # MinIOイベント通知設定Job
│   └── event-sync-cronjob.yaml      # イベント通知同期CronJob
├── overlays/
│   └── dev/
│       ├── kustomization.yaml       # 開発環境用設定
│       └── namespace.yaml           # Namespace定義
└── src/
    ├── dags/
    │   └── pipeline.py              # Airflow DAG定義
    ├── scripts/
    │   ├── generator.py             # ダミーデータ生成スクリプト
    │   └── processor.py             # データ処理スクリプト
    └── webhook/
        └── receiver.py              # Webhookサーバー実装

```

## 前提条件

- Kubernetes クラスタ（Rancher Desktop等）
- kubectl
- Kustomize 5.8.1
- Helm 3.19.4（Argo CD 3.4.5のrepo-serverと揃える）

## デプロイ

### 前提条件: Sealed Secrets Controllerのインストール

機密情報（パスワード等）はSealed Secretsで管理されています。初回のみControllerをインストールしてください：

以下では検証用contextを`kind-argocd-blog`へ固定します。別の検証クラスタを使う場合は、確認済みのcontext名へ明示的に置き換えてください。

```bash
(
  set -euo pipefail

  EXPECTED_CONTEXT=kind-argocd-blog
  test "$(kubectl config current-context)" = "${EXPECTED_CONTEXT}"

  # Sealed Secrets Controllerをインストール
  kubectl --context "${EXPECTED_CONTEXT}" apply \
    -f https://github.com/bitnami/sealed-secrets/releases/download/v0.38.4/controller.yaml

  # Controllerの起動を確認
  kubectl --context "${EXPECTED_CONTEXT}" get pods \
    -n kube-system \
    -l name=sealed-secrets-controller
)
```

Controllerの起動後、リポジトリルートの`scripts/generate-dev-sealed-secrets.sh`で、このクラスタ専用の`SealedSecret`を生成してください。リポジトリ全体で5つ、そのうちdata-pipeline用は4つです。Airflowのmetadata database接続文字列とPostgreSQLパスワードは、同じ`airflow-metadata`へ暗号化されます。upstreamには別クラスタ用の暗号文や平文Secretを含めていません。

このスクリプトは新しい空の検証クラスタを初期化する用途です。既存PVCがある環境で資格情報を上書きすると、PostgreSQL内部のパスワードやFernet keyと食い違うため実行しないでください。既存環境の資格情報移行はこのサンプルの範囲外です。

### 開発環境へのデプロイ

```bash
(
  set -euo pipefail

  EXPECTED_CONTEXT=kind-argocd-blog
  test "$(kubectl config current-context)" = "${EXPECTED_CONTEXT}"

  # data-pipeline-dev namespaceにデプロイ
  # Sealed Secretsも自動的に適用されます
  kustomize build apps/data-pipeline/overlays/dev \
    --enable-helm \
    --load-restrictor LoadRestrictionsNone \
    | kubectl --context "${EXPECTED_CONTEXT}" apply \
        -n data-pipeline-dev \
        -f -
)
```

Argo CD経由では`Application`の`destination.namespace`がnamespace未指定リソースを補完します。上記のようにレンダリング結果を直接applyするときは、`-n data-pipeline-dev`を必ず指定してください。また、`kubectl`内蔵版ではなく、Argo CD 3.4.5と同じKustomize 5.8.1／Helm 3.19.4をPATH上で使ってください。通常は直接applyせず、Argo CDの`Application`から同期します。

### Job定義を変更したとき

Kubernetes JobのPod templateはimmutableです。通常リソースとして残す`airflow-create-user`と`minio-event-setup`には、Argo CDの`Replace=true`や`Force=true`による自動的な作り直しを設定していません。

`airflow-run-airflow-migrations`は別扱いです。このJobはArgo CDのSync hookと`BeforeHookCreation,HookSucceeded`で管理され、同期時にArgo CDが作り直します。通常Jobの手動削除手順には含めません。

`minio-event-setup`は再実行できるように作られているため、定義を変更した場合だけ、このJobを手動削除してArgo CDのself-healを待ちます。一方、`airflow-create-user`の`airflow users create`は既存ユーザーがいる状態での再実行を前提としていません。既存ユーザーを考慮した移行手順を用意できるまで、手動削除・再同期しないでください。

```bash
# 例: minio-event-setupの定義を変更した場合
(
  set -euo pipefail

  EXPECTED_CONTEXT=kind-argocd-blog
  test "$(kubectl config current-context)" = "${EXPECTED_CONTEXT}"
  kubectl --context "${EXPECTED_CONTEXT}" delete job \
    minio-event-setup \
    -n data-pipeline-dev

  # automated self-healによる再作成を待つ
  kubectl --context "${EXPECTED_CONTEXT}" wait --for=create \
    job/minio-event-setup \
    -n data-pipeline-dev \
    --timeout=300s
  kubectl --context "${EXPECTED_CONTEXT}" wait --for=condition=complete \
    job/minio-event-setup \
    -n data-pipeline-dev \
    --timeout=300s
)
```

### リソースの確認

```bash
# 全リソースの確認
kubectl get all -n data-pipeline-dev

# Podの状態確認
kubectl get pods -n data-pipeline-dev

# Airflow Webserverへのアクセス (port-forward)
kubectl port-forward -n data-pipeline-dev svc/airflow-webserver 8080:8080

# MinIO Consoleへのアクセス (port-forward)
kubectl port-forward -n data-pipeline-dev svc/minio-console 9001:9001
```

### Ingressを使用したアクセス

`/etc/hosts`に以下を追加:
```
127.0.0.1 airflow.local
127.0.0.1 minio.local
```

- Airflow UI: http://airflow.local
- MinIO Console: http://minio.local

ログイン情報は生成した`SealedSecret`から作られるSecretを使用します。READMEやコマンド履歴へ値を書かないでください。

## 動作確認

### 1. 手動でのDAG実行テスト

```bash
# Webhook経由でDAGをトリガー
kubectl exec -n data-pipeline-dev deployment/webhook-receiver -- python3 -c "
import requests
event = {
    'EventName': 's3:ObjectCreated:Put',
    'Records': [{
        's3': {
            'bucket': {'name': 'raw-data'},
            'object': {'key': 'test.mcap'}
        }
    }]
}
resp = requests.post('http://localhost:5000/minio-event', json=event)
print(f'Status: {resp.status_code}')
print(f'Response: {resp.text}')
"
```

### 2. DAG実行状況の確認

```bash
# DAG一覧
kubectl exec -n data-pipeline-dev deployment/airflow-webserver -c webserver -- \
  airflow dags list

# DAG実行履歴
kubectl exec -n data-pipeline-dev deployment/airflow-webserver -c webserver -- \
  airflow dags list-runs -d rosbag_processor_poc
```

### 3. ログの確認

```bash
# Webhook Receiverのログ
kubectl logs -n data-pipeline-dev deployment/webhook-receiver -f

# Airflow Schedulerのログ
kubectl logs -n data-pipeline-dev deployment/airflow-scheduler -c scheduler -f

# Airflow Workerのログ
kubectl logs -n data-pipeline-dev airflow-worker-0 -c worker -f
```

## コンポーネント詳細

### Airflow設定

**主要設定** (`airflow-values.yaml`):
- Executor: `CeleryExecutor` (分散タスク実行)
- Redis: 有効 (Celeryのブローカー)
- PostgreSQL: メタデータDB
- Basic認証: 有効 (API呼び出し用)
- DAG自動Unpause: 有効 (`dags_are_paused_at_creation: False`)

**認証情報**: 管理ユーザーは`airflow-credentials`、Fernet key・Webserver key・Redis接続は`airflow-runtime-secrets`、metadata database接続・PostgreSQLパスワードは`airflow-metadata`から参照します。いずれも生成スクリプトで作る`SealedSecret`から復号されます。

### MinIO設定

**主要設定** (`minio-values.yaml`):
- Mode: `standalone`
- 認証情報: `minio-credentials` Secret
- Webhook通知: 有効

**バケット**:
- `raw-data`: 生データ用
- `processed-data`: 処理済みデータ用

### DAG定義

**rosbag_processor_poc** (`src/dags/pipeline.py`):
- トリガー: Webhook経由（MinIOイベント通知）
- タスク: `process_data` (KubernetesPodOperator)
- 処理内容: 
  1. MinIOから`.mcap`ファイルをダウンロード
  2. データ処理（CSV変換）
  3. 処理済みデータをMinIOにアップロード

### Generator CronJob

**スケジュール**: `*/1 * * * *` (1分ごと)

**処理内容**:
1. ダミーの`.mcap`ファイル（CSV形式）を生成
2. `raw-data`バケットにアップロード
3. MinIOイベント通知が発火
4. Webhook経由でAirflow DAGがトリガーされる

## トラブルシューティング

### DAGが実行されない

1. DAGがPause状態になっていないか確認:
   ```bash
   kubectl exec -n data-pipeline-dev deployment/airflow-webserver -c webserver -- \
     airflow dags list
   ```

2. Webhook Receiverが正常に動作しているか確認:
   ```bash
   kubectl logs -n data-pipeline-dev deployment/webhook-receiver
   ```

3. MinIOイベント通知が設定されているか確認:
   ```bash
   kubectl logs -n data-pipeline-dev job/minio-event-setup
   ```

### Workerがタスクを実行しない

1. RedisとWorkerの接続を確認:
   ```bash
   kubectl logs -n data-pipeline-dev airflow-worker-0 -c worker | grep -i redis
   ```
   
   `Connected to redis` が表示されれば正常

2. Celeryのキュー状態を確認:
   ```bash
   kubectl exec -n data-pipeline-dev airflow-worker-0 -c worker -- \
     celery -A airflow.providers.celery.executors.celery_executor_utils inspect stats
   ```

### MinIOイベント通知が動作しない

1. イベント設定を再適用:
   ```bash
   (
     set -euo pipefail

     EXPECTED_CONTEXT=kind-argocd-blog
     test "$(kubectl config current-context)" = "${EXPECTED_CONTEXT}"
     kubectl --context "${EXPECTED_CONTEXT}" delete job \
       minio-event-setup \
       -n data-pipeline-dev
     kustomize build apps/data-pipeline/overlays/dev \
       --enable-helm \
       --load-restrictor LoadRestrictionsNone \
       | kubectl --context "${EXPECTED_CONTEXT}" apply \
           -n data-pipeline-dev \
           -f -
   )
   ```

2. MinIOのログを確認:
   ```bash
   kubectl logs -n data-pipeline-dev deployment/minio
   ```

## クリーンアップ

```bash
(
  set -euo pipefail

  EXPECTED_CONTEXT=kind-argocd-blog
  test "$(kubectl config current-context)" = "${EXPECTED_CONTEXT}"

  # Namespace全体を削除するため、この検証専用Namespaceであることを再確認する
  kubectl --context "${EXPECTED_CONTEXT}" delete namespace \
    data-pipeline-dev
)
```

## 環境変数

機密でない主要な環境変数は`config.env`、認証情報はKubernetes Secretで管理します。

| 変数名 | デフォルト値 | 説明 |
|--------|-------------|------|
| `MINIO_ENDPOINT` | `http://minio:9000` | MinIO APIエンドポイント |
| `AIRFLOW_BASE_URL` | `http://airflow-webserver:8080` | Airflow WebサーバーURL |

`MINIO_ACCESS_KEY`、`MINIO_SECRET_KEY`、`AIRFLOW_USER`、`AIRFLOW_PASSWORD`は、Pod定義の`secretKeyRef`から注入します。

## 開発ガイドライン

### DAGの追加

1. `src/dags/`に新しいPythonファイルを作成
2. `base/kustomization.yaml`の`configMapGenerator`にファイルを追加
3. 必要に応じて`airflow-values.yaml`のvolume設定を更新

### 処理スクリプトの追加

1. `src/scripts/`にPythonファイルを作成
2. `base/kustomization.yaml`の`pipeline-scripts` ConfigMapに追加
3. DAG内の`KubernetesPodOperator`でスクリプトを参照

## ライセンス

このプロジェクトは学習目的で作成されています。
