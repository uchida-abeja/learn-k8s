from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.kubernetes_pod import KubernetesPodOperator
from airflow.utils.dates import days_ago
from datetime import timedelta
from kubernetes.client import models as k8s

# 共通設定
PROCESSOR_IMAGE = "python:3.9-slim" 

default_args = {
    'owner': 'data-team',
    'start_date': days_ago(1),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

with DAG(
    'rosbag_processor_poc',
    default_args=default_args,
    schedule_interval=None,  # イベント駆動のため定期実行を無効化
    catchup=False,
    max_active_runs=3,  # 複数ファイルの同時処理を許可
) as dag:

    # Kubernetes Podでファイル検索と処理を実行
    processor = KubernetesPodOperator(
        task_id='process_data',
        name='ros-processor-job',
        namespace='data-pipeline-dev',
        image=PROCESSOR_IMAGE,
        image_pull_policy='IfNotPresent',
        
        cmds=["/bin/bash", "-c"],
        arguments=[
            """
            pip install --no-cache-dir boto3 pandas && 
            python3 /app/processor.py {{ dag_run.conf.get('key', '') }}
            """
        ],
        
        volumes=[
            k8s.V1Volume(
                name='scripts-vol',
                config_map=k8s.V1ConfigMapVolumeSource(name='pipeline-scripts')
            )
        ],
        volume_mounts=[
            k8s.V1VolumeMount(
                name='scripts-vol',
                mount_path='/app',
                read_only=True
            )
        ],
        
        env_vars={
            'MINIO_ENDPOINT': 'http://minio:9000',
            'MINIO_ACCESS_KEY': 'admin',
            'MINIO_SECRET_KEY': 'password',
        },
        
        is_delete_operator_pod=True,
        get_logs=True,
    )