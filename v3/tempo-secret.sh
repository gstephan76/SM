oc create secret generic -n tempo tempostack-dev-minio \
--from-literal=bucket="tempo-data" \
--from-literal=endpoint="http://minio.tempo.svc.cluster.local:9000" \
--from-literal=access_key_id="minio" \
--from-literal=access_key_secret="minio123"
