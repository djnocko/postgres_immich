#PVC (copy/paste you need it in immich-values.yaml)
kubectl apply -n immich -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-library-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 60Gi
EOF
