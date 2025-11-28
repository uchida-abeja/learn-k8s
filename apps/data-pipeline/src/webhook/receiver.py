#!/usr/bin/env python3
"""
MinIO Event Notification Webhook Receiver

MinIOのバケットイベント通知を受信し、Airflow DAGをトリガーするWebhookサーバー。
raw-dataバケットに.mcapファイルがアップロードされると、
Airflow REST APIを呼び出してrosbag_processor_poc DAGを実行する。
"""

from flask import Flask, request, jsonify
import requests
import os
import logging

# ロギング設定
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# 環境変数から設定を取得
AIRFLOW_API = os.getenv('AIRFLOW_API_URL', 'http://airflow-webserver:8080')
AIRFLOW_USER = os.getenv('AIRFLOW_USER', 'admin')
AIRFLOW_PASSWORD = os.getenv('AIRFLOW_PASSWORD', 'admin')
DAG_ID = 'rosbag_processor_poc'

@app.route('/minio-event', methods=['POST'])
def handle_minio_event():
    """
    MinIOからのイベント通知を処理し、該当するファイルに対してAirflow DAGをトリガー
    """
    try:
        event = request.json
        logger.info(f"Received MinIO event: {event}")
        
        if not event or 'Records' not in event:
            logger.warning("Invalid event format: no Records field")
            return jsonify({'status': 'error', 'message': 'Invalid event format'}), 400
        
        triggered_dags = []
        
        # 各レコードを処理
        for record in event.get('Records', []):
            event_name = record.get('eventName', '')
            s3_info = record.get('s3', {})
            bucket = s3_info.get('bucket', {}).get('name', '')
            key = s3_info.get('object', {}).get('key', '')
            
            logger.info(f"Processing event: {event_name}, bucket: {bucket}, key: {key}")
            
            # raw-dataバケットの.mcapファイルのみ処理
            if bucket == 'raw-data' and key.endswith('.mcap'):
                logger.info(f"Triggering Airflow DAG for file: {key}")
                
                # Airflow DAGをトリガー
                trigger_url = f'{AIRFLOW_API}/api/v1/dags/{DAG_ID}/dagRuns'
                payload = {
                    'conf': {
                        'bucket': bucket,
                        'key': key,
                        'event_name': event_name
                    }
                }
                
                try:
                    response = requests.post(
                        trigger_url,
                        json=payload,
                        auth=(AIRFLOW_USER, AIRFLOW_PASSWORD),
                        timeout=10
                    )
                    
                    if response.status_code == 200:
                        dag_run_info = response.json()
                        logger.info(f"Successfully triggered DAG: {dag_run_info}")
                        triggered_dags.append({
                            'key': key,
                            'dag_run_id': dag_run_info.get('dag_run_id'),
                            'status': 'success'
                        })
                    else:
                        logger.error(f"Failed to trigger DAG: {response.status_code} - {response.text}")
                        triggered_dags.append({
                            'key': key,
                            'status': 'error',
                            'message': response.text
                        })
                
                except requests.exceptions.RequestException as e:
                    logger.error(f"Request to Airflow API failed: {str(e)}")
                    triggered_dags.append({
                        'key': key,
                        'status': 'error',
                        'message': str(e)
                    })
        
        if triggered_dags:
            return jsonify({
                'status': 'success',
                'triggered_dags': triggered_dags
            }), 200
        else:
            logger.info("No matching files to process")
            return jsonify({'status': 'no_action', 'message': 'No matching files'}), 200
    
    except Exception as e:
        logger.error(f"Error processing event: {str(e)}", exc_info=True)
        return jsonify({'status': 'error', 'message': str(e)}), 500


@app.route('/health', methods=['GET'])
def health():
    """
    ヘルスチェックエンドポイント
    """
    return jsonify({
        'status': 'healthy',
        'service': 'minio-webhook-receiver',
        'airflow_api': AIRFLOW_API
    }), 200


@app.route('/', methods=['GET'])
def index():
    """
    ルートエンドポイント
    """
    return jsonify({
        'service': 'MinIO Event Notification Webhook Receiver',
        'endpoints': {
            '/minio-event': 'POST - Receive MinIO event notifications',
            '/health': 'GET - Health check',
        }
    }), 200


if __name__ == '__main__':
    logger.info(f"Starting webhook receiver on port 5000")
    logger.info(f"Airflow API URL: {AIRFLOW_API}")
    logger.info(f"Target DAG ID: {DAG_ID}")
    app.run(host='0.0.0.0', port=5000, debug=False)
