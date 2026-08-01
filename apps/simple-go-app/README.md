# simple-go-app manifest

private GHCRの`simple-go-app`を`simple-go-app-dev` NamespaceへデプロイするKustomize設定です。アプリケーション本体は[uchida-abeja/simple-go-app](https://github.com/uchida-abeja/simple-go-app)にあります。

## 構成

```text
apps/simple-go-app/
├── base/
│   ├── deployment.yaml
│   ├── ingress.yaml
│   ├── kustomization.yaml
│   └── service.yaml
└── overlays/dev/
    ├── kustomization.yaml
    └── namespace.yaml
```

`base/deployment.yaml`では`simple-go-app-image`という論理名を使い、dev overlayの`images`でGHCRのリポジトリとフルcommit SHAタグへ変換します。

## 適用前の必須作業

クローン直後のupstreamには、クラスタ固有の暗号文を置いていません。リポジトリルートから次の順に実行してください。

1. Sealed Secrets controller 0.38.4を対象クラスタへ導入する。
2. `scripts/generate-dev-sealed-secrets.sh`でMinIO接続用Secretを生成する。
3. `scripts/generate-ghcr-pull-sealed-secret.sh`でprivate GHCR用`ImagePullSecret`を生成する。
4. `overlays/dev/kustomization.yaml`の`newName`と`newTag`を自分のイメージへ変更する。

生成後、overlayには次の暗号文がresourceとして追加されます。

- `simple-go-app-sealed-secret.yaml` → `simple-go-app-secrets`
- `ghcr-pull-sealed-secret.yaml` → `ghcr-pull-credentials`

平文の`Secret`、PAT、Docker `config.json`はコミットしないでください。

## レンダリングと適用

```bash
kustomize build apps/simple-go-app/overlays/dev >/dev/null
kubectl apply -k apps/simple-go-app/overlays/dev
kubectl rollout status deployment/simple-go-app -n simple-go-app-dev
```

Argo CDを使う場合は、Secretの暗号文を`main`へ反映してから`infrastructure/argocd/simple-go-app-application.yaml`を適用します。

## 動作確認

Ingress controllerがない環境ではport-forwardを使います。

```bash
kubectl port-forward service/simple-go-app -n simple-go-app-dev 8080:80
curl --fail --silent --show-error http://127.0.0.1:8080/healthz
curl --fail --silent --show-error http://127.0.0.1:8080/buckets
```

MinIOは`data-pipeline-dev` Namespaceの`minio` Serviceへ接続します。接続できない場合は、値そのものを表示せず参照関係を確認してください。

```bash
kubectl describe pod -n simple-go-app-dev \
  -l app.kubernetes.io/name=simple-go-app
kubectl get secret simple-go-app-secrets ghcr-pull-credentials \
  -n simple-go-app-dev
kubectl get service minio -n data-pipeline-dev
```
