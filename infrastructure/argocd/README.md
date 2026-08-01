# Argo CD

このディレクトリには、2つのdev overlayを監視するArgo CD `Application`があります。

| Application | Gitのpath | デプロイ先Namespace |
|---|---|---|
| `simple-go-app` | `apps/simple-go-app/overlays/dev` | `simple-go-app-dev` |
| `data-pipeline` | `apps/data-pipeline/overlays/dev` | `data-pipeline-dev` |

## 適用前の準備

1. `*-application.yaml`の`repoURL`を、自分のprivateマニフェストリポジトリのSSH URLへ変更する。
2. Argo CDへそのリポジトリのread credentialを登録する。
3. Sealed Secrets controllerを導入し、リポジトリルートの生成スクリプトでクラスタ固有の暗号文を作る。
4. `data-pipeline`も使う場合は、KustomizeのHelm連携を有効にする。

クローン直後のupstreamにはクラスタ固有の`SealedSecret`がありません。先に`Application`を適用すると、Secret不足でworkloadが起動しません。

## Argo CD 3.4.5の導入

```bash
kubectl create namespace argocd --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl apply -n argocd \
  --server-side \
  --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.5/manifests/install.yaml

kubectl rollout status deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd
```

data pipelineは`helmCharts`とKustomization root外の`src`を参照するため、repo-serverへbuild optionsを設定します。古いConfig Management Pluginは使用しません。

```bash
kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"kustomize.buildOptions":"--enable-helm --load-restrictor LoadRestrictionsNone"}}'
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd
```

## Applicationの適用

`simple-go-app`だけを追加する場合:

```bash
kubectl apply -f infrastructure/argocd/simple-go-app-application.yaml
```

data pipelineも含める場合:

```bash
kubectl apply -k infrastructure/argocd/
```

```bash
kubectl get applications.argoproj.io -n argocd
kubectl describe application simple-go-app -n argocd
```

## UIへのアクセス

Ingress controllerがないkindではport-forwardを使います。

```bash
kubectl port-forward service/argocd-server -n argocd 8080:443
```

Traefikがある環境では、`ingress.yaml`を任意で適用できます。このIngressはbackendのArgo CD serverへHTTPS（port 443）で接続する設定です。

```bash
kubectl apply -f infrastructure/argocd/ingress.yaml
```

## 削除時の注意

両方の`Application`には次の設定があります。

- `automated.prune: true`
- `automated.selfHeal: true`
- `resources-finalizer.argocd.argoproj.io`

`Application`を削除すると管理対象リソースも削除されます。本番では`AppProject`で接続先とリソース種別を制限し、削除範囲を確認してから利用してください。
