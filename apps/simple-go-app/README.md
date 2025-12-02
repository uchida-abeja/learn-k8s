# simple-go-app

GitHub Container Registry (ghcr.io) にホストされている Go アプリケーションを Kubernetes にデプロイする設定です。

## アプリケーション情報

- **イメージ**: `ghcr.io/uchida-abeja/simple-go-app:latest`
- **コンテナポート**: 8080
- **プロトコル**: HTTP

### エンドポイント

- `GET /buckets` - バケット一覧取得
- `GET /buckets/:name/objects` - オブジェクト一覧取得

## ディレクトリ構成

```
apps/simple-go-app/
├── base/
│   ├── deployment.yaml      # Deploymentの定義
│   ├── service.yaml          # Serviceの定義
│   ├── ingress.yaml          # Ingressの定義
│   └── kustomization.yaml    # Kustomize設定
└── overlays/
    └── dev/
        ├── namespace.yaml    # Namespace定義
        ├── secret.yaml       # MinIO接続情報のSecret
        └── kustomization.yaml # dev環境用のKustomize設定
```

## 前提条件

- Kubernetes クラスタが稼働していること
- `kubectl` がインストールされていること
- **Sealed Secrets Controller** がインストールされていること
  ```bash
  kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.2/controller.yaml
  ```
- MinIO が `data-pipeline-dev` namespace にデプロイされていること
  ```bash
  # Helmチャートを含むためkustomize buildの結果をパイプで適用
  kubectl kustomize apps/data-pipeline/overlays/dev --enable-helm --load-restrictor LoadRestrictionsNone | kubectl apply -f -
  ```

> **注**: 認証情報は Sealed Secrets で管理されています。詳細は [infrastructure/sealed-secrets/README.md](../../infrastructure/sealed-secrets/README.md) を参照してください。

## デプロイ方法

### 1. dev環境へのデプロイ

```bash
# リポジトリのルートディレクトリから実行
kubectl apply -k apps/simple-go-app/overlays/dev
```

### 2. デプロイ確認

```bash
# Namespaceの確認
kubectl get namespace simple-go-app-dev

# Podの状態確認
kubectl get pods -n simple-go-app-dev

# Serviceの確認
kubectl get svc -n simple-go-app-dev

# Ingressの確認
kubectl get ingress -n simple-go-app-dev
```

### 3. アプリケーションへのアクセス

#### ローカル環境（Rancher Desktop）の場合

`/etc/hosts` にエントリを追加：

```
127.0.0.1 simple-go-app.local
```

curlでアクセステスト：

```bash
# バケット一覧取得
curl http://simple-go-app.local/buckets

# レスポンス例:
# {"buckets":["processed-data","raw-data"]}

# raw-dataバケットのオブジェクト一覧取得
curl http://simple-go-app.local/buckets/raw-data/objects

# レスポンス例:
# {"objects":["robot_log_20251202_025203.mcap","robot_log_20251202_025303.mcap",...]}

# processed-dataバケットのオブジェクト一覧取得
curl http://simple-go-app.local/buckets/processed-data/objects

# レスポンス例:
# {"objects":["robot_log_20251202_025303.csv","robot_log_20251202_025403.csv",...]}

# 整形して表示（jq使用）
curl -s http://simple-go-app.local/buckets | jq .
curl -s http://simple-go-app.local/buckets/raw-data/objects | jq .
```

#### Service経由でのアクセス（クラスタ内から）

```bash
# Port-forward を使ってローカルからアクセス
kubectl port-forward -n simple-go-app-dev svc/simple-go-app 8080:80

# 別のターミナルで
curl http://localhost:8080/buckets
```

## 環境変数の設定

MinIO接続情報は `overlays/dev/secret.yaml` で管理されています。

デフォルト値（data-pipeline-dev の MinIO に接続）：
- `AWS_REGION`: `us-east-1` (AWS SDK v2 で必須)
- `MINIO_ENDPOINT`: `minio.data-pipeline-dev.svc.cluster.local:9000`
- `MINIO_ACCESS_KEY`: `admin`
- `MINIO_SECRET_KEY`: `password`

### Secret の更新方法

```bash
# Secret を編集
kubectl edit secret simple-go-app-secrets -n simple-go-app-dev

# または、ファイルを編集してから再適用
kubectl apply -k apps/simple-go-app/overlays/dev
```

## リソース設定

Deployment には以下のリソース制限が設定されています：

- **Requests**: CPU 100m, Memory 64Mi
- **Limits**: CPU 200m, Memory 128Mi

### ヘルスチェック

- **Liveness Probe**: `/buckets` エンドポイントを10秒ごとにチェック
- **Readiness Probe**: `/buckets` エンドポイントを5秒ごとにチェック

## トラブルシューティング

### Podが起動しない場合

```bash
# Podの詳細確認
kubectl describe pod -n simple-go-app-dev -l app.kubernetes.io/name=simple-go-app

# ログ確認
kubectl logs -n simple-go-app-dev -l app.kubernetes.io/name=simple-go-app
```

### イメージの Pull エラーが発生する場合

GitHub Container Registry は公開イメージの場合は認証不要ですが、プライベートリポジトリの場合は ImagePullSecret が必要です。

```bash
# GitHub Personal Access Token を使用してSecretを作成
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=<your-github-username> \
  --docker-password=<your-github-token> \
  -n simple-go-app-dev

# deployment.yaml に imagePullSecrets を追加
# spec.template.spec.imagePullSecrets:
#   - name: ghcr-secret
```

### MinIO に接続できない場合

1. MinIO が `data-pipeline-dev` Namespace で動作していることを確認
   ```bash
   kubectl get svc -n data-pipeline-dev | grep minio
   ```

2. Secret の MINIO_ENDPOINT が正しいことを確認
   ```bash
   kubectl get secret simple-go-app-secrets -n simple-go-app-dev -o jsonpath='{.data.minio-endpoint}' | base64 -d
   # 期待値: minio.data-pipeline-dev.svc.cluster.local:9000
   ```

3. Pod から MinIO への接続をテスト
   ```bash
   kubectl exec -n simple-go-app-dev deployment/simple-go-app -- sh -c 'wget -O- --timeout=5 http://$MINIO_ENDPOINT 2>&1'
   ```

4. AWS_REGION 環境変数が設定されていることを確認
   ```bash
   kubectl get pod -n simple-go-app-dev -o jsonpath='{.items[0].spec.containers[0].env}' | jq '.[] | select(.name=="AWS_REGION")'
   # 期待値: {"name":"AWS_REGION","value":"us-east-1"}
   ```
3. MinIO の Service 名とポートを確認

```bash
# MinIOのServiceを確認
kubectl get svc -n default | grep minio
```

## お片付け

```bash
# リソースの削除
kubectl delete -k apps/simple-go-app/overlays/dev

# または Namespace ごと削除
kubectl delete namespace simple-go-app-dev
```

## カスタマイズ

### 本番環境用の設定を追加する場合

```bash
mkdir -p apps/simple-go-app/overlays/prod
```

`overlays/prod/kustomization.yaml` を作成して、本番用の設定（replicas数、リソース制限、ホスト名など）を上書きします。
