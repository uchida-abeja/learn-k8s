import os
import time
import boto3
from datetime import datetime
import random

# 環境変数から設定を取得 (K8sのConfigMap/Secretから注入)
MINIO_ENDPOINT = os.getenv('MINIO_ENDPOINT', 'http://minio:9000')
ACCESS_KEY = os.getenv('MINIO_ACCESS_KEY', 'minioadmin')
SECRET_KEY = os.getenv('MINIO_SECRET_KEY', 'minioadmin')
BUCKET_NAME = 'raw-data'

def get_s3_client():
    return boto3.client('s3',
                        endpoint_url=MINIO_ENDPOINT,
                        aws_access_key_id=ACCESS_KEY,
                        aws_secret_access_key=SECRET_KEY)

def generate_dummy_data():
    # 本来はここでROS 2のAPIを使って.mcapを生成するが、
    # PoCの疎通確認用に、タイムスタンプを含むテキストファイルを生成する
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    filename = f"robot_log_{timestamp}.mcap"
    
    # ダミーデータの中身（CSVっぽいテキスト）
    content = f"timestamp,cmd_vel_linear,cmd_vel_angular\n"
    for i in range(10):
        content += f"{time.time()},{random.random()},{random.random()}\n"
    
    with open(filename, 'w') as f:
        f.write(content)
    
    return filename

def main():
    print("--- Starting Generator ---")
    s3 = get_s3_client()
    
    # バケットの作成（存在しない場合）
    try:
        s3.create_bucket(Bucket=BUCKET_NAME)
    except Exception as e:
        print(f"Bucket check ignored: {e}")

    # ファイル生成
    file_path = generate_dummy_data()
    print(f"Generated file: {file_path}")

    # MinIOへアップロード
    try:
        s3.upload_file(file_path, BUCKET_NAME, file_path)
        print(f"Uploaded successfully to {BUCKET_NAME}/{file_path}")
    except Exception as e:
        print(f"Upload failed: {e}")
        exit(1)
    
    print("--- Finished ---")

if __name__ == "__main__":
    main()