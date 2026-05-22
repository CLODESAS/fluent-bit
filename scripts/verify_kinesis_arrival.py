"""
Lee los shards del stream Kinesis 'pragma-sopp-prod-kds-tool-usage' y cuenta
los registros enviados por el fork de Fluent Bit en los ultimos 2 minutos
(filtrando por la marca 'pragma fork stream_arn' del conf de prueba).

Util para confirmar que el patch stream_arn realmente entrega al stream
cross-account.
"""
import boto3
import json
import time
from datetime import datetime, timedelta, timezone

ARN = "arn:aws:kinesis:us-east-1:750004260673:stream/pragma-sopp-prod-kds-tool-usage"
PROFILE = "pragma-sso"
REGION = "us-east-1"
MARK = "pragma fork stream_arn"

s = boto3.Session(profile_name=PROFILE, region_name=REGION).client("kinesis")
shards = s.list_shards(StreamARN=ARN)["Shards"]
print(f"Shards en {ARN.split('/')[-1]}: {len(shards)}")

since = datetime.now(timezone.utc) - timedelta(minutes=2)
total = 0
samples = []

for sh in shards:
    it = s.get_shard_iterator(
        StreamARN=ARN,
        ShardId=sh["ShardId"],
        ShardIteratorType="AT_TIMESTAMP",
        Timestamp=since,
    )["ShardIterator"]

    for _ in range(3):  # 3 iteraciones para capturar registros tardios
        r = s.get_records(ShardIterator=it, Limit=500)
        for rec in r.get("Records", []):
            try:
                data = json.loads(rec["Data"].decode("utf-8"))
            except Exception:
                continue
            msg = str(data.get("message", ""))
            if MARK in msg:
                total += 1
                if len(samples) < 5:
                    arrival = rec["ApproximateArrivalTimestamp"].isoformat()
                    seq = rec["SequenceNumber"]
                    samples.append((arrival, sh["ShardId"][-6:], seq[-10:], msg[:80]))
        it = r["NextShardIterator"]
        time.sleep(0.3)

print(f"\nTotal registros con marca '{MARK}': {total}")
for arrival, shard, seq, msg in samples:
    print(f"  [{arrival}] shard=...{shard} seq=...{seq} msg={msg}")
