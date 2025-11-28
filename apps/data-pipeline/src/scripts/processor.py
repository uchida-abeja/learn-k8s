import os
import sys
import boto3
import pandas as pd
from io import StringIO

# 環境変数
MINIO_ENDPOINT = os.getenv('MINIO_ENDPOINT', 'http://minio:9000')
ACCESS_KEY = os.getenv('MINIO_ACCESS_KEY', 'admin')
SECRET_KEY = os.getenv('MINIO_SECRET_KEY', 'password')
SOURCE_BUCKET = 'raw-data'
DEST_BUCKET = 'processed-data'

def get_s3_client():
    return boto3.client('s3',
                        endpoint_url=MINIO_ENDPOINT,
                        aws_access_key_id=ACCESS_KEY,
                        aws_secret_access_key=SECRET_KEY)

def main():
    # ファイルが指定されていない場合は、raw-dataバケットから最新のファイルを取得
    if len(sys.argv) >= 2:
        input_path = sys.argv[1]
        file_key = input_path.split('/')[-1]
    else:
        # 最新のファイルを取得
        s3_temp = get_s3_client()
        try:
            response = s3_temp.list_objects_v2(Bucket=SOURCE_BUCKET, Prefix='robot_log_')
            if 'Contents' not in response or len(response['Contents']) == 0:
                print("No files found in raw-data bucket")
                sys.exit(0)
            
            files = [obj['Key'] for obj in response['Contents'] if obj['Key'].endswith('.mcap')]
            if not files:
                print("No .mcap files found")
                sys.exit(0)
                
            file_key = sorted(files)[-1]  # 最新のファイル
            print(f"Auto-selected latest file: {file_key}")
        except Exception as e:
            print(f"Error listing files: {e}")
            sys.exit(1)
    
    print(f"--- Processing File: {file_key} ---")
    
    s3 = get_s3_client()
    
    # 1. ダウンロード
    local_input = f"/tmp/{file_key}"
    try:
        print(f"Downloading from {SOURCE_BUCKET}...")
        s3.download_file(SOURCE_BUCKET, file_key, local_input)
    except Exception as e:
        print(f"Download failed: {e}")
        sys.exit(1)

    # 2. データ変換処理 (PoC用)
    # 本来はrosbag2_pyで開くが、今回はGeneratorが作ったCSV風テキストを処理
    try:
        df = pd.read_csv(local_input)
        
        # 何らかの加工処理（例：値の正規化）
        df['processed_flag'] = True
        df['processed_at'] = pd.Timestamp.now()
        
        # CSVとして保存
        local_output = local_input.replace('.mcap', '.csv')
        df.to_csv(local_output, index=False)
        print(f"Converted to {local_output}")
        
    except Exception as e:
        print(f"Processing failed: {e}")
        sys.exit(1)

    # 3. アップロード（処理済みバケットへ）
    output_key = file_key.replace('.mcap', '.csv')
    try:
        # バケット作成確認
        try:
            s3.create_bucket(Bucket=DEST_BUCKET)
        except:
            pass
            
        print(f"Uploading to {DEST_BUCKET}...")
        s3.upload_file(local_output, DEST_BUCKET, output_key)
        print("Upload successful.")
        
    except Exception as e:
        print(f"Upload failed: {e}")
        sys.exit(1)

    # 4. (Option) 元ファイルの削除または移動
    # ここではPoCなので何もしない

if __name__ == "__main__":
    main()