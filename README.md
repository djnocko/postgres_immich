```markdown
# Immich v1.119.0 Deployment on k3s with Custom PostgreSQL Image

This guide details how to deploy Immich v1.119.0 on a k3s cluster with a custom PostgreSQL image that includes PostgreSQL 16, PostGIS, and `pgvector` (v0.7.4) to support Immich’s vector search capabilities. The setup uses SSD storage via the `local-path` StorageClass and Traefik Ingress for accessing Immich at `photos.yourdomain.com`. The custom image avoids runtime installation issues (e.g., `CrashLoopBackOff`, `FailedPostStartHook`, `fast shutdown request`) by pre-installing dependencies and enabling extensions.

## Prerequisites
- **k3s Cluster**: A running k3s cluster with the `local-path` StorageClass for SSD storage.
- **Docker**: Installed on a machine (e.g., Docker Desktop on Windows) to build and push the custom image.
- **GitHub Account**: For pushing the image to GitHub Container Registry (ghcr.io).
- **kubectl**: Configured to interact with your k3s cluster.
- **Helm**: Installed for deploying Immich.
- **Domain**: A domain (e.g., `photos.yourdomain.com`) with DNS pointing to your k3s node’s IP.
- **Traefik**: Installed as the Ingress controller in k3s (default).

## Step 1: Create the Custom PostgreSQL Image
The custom image includes PostgreSQL 16, PostGIS (`postgresql-16-postgis-3`), and `pgvector` (v0.7.4), with `postgis` and `vector` extensions enabled during initialization.

1. **Create a Directory**:
   ```bash
   mkdir postgres_immich
   cd postgres_immich
   ```

2. **Create `Dockerfile`**:
   Save the following as `Dockerfile`:
   ```dockerfile
   FROM postgres:16-bookworm

   # Install build dependencies and PostGIS
   RUN apt-get update && apt-get install -y \
       postgresql-16-postgis-3 \
       postgresql-16-postgis-3-scripts \
       postgresql-server-dev-16 \
       build-essential \
       git \
       && rm -rf /var/lib/apt/lists/*

   # Install pgvector
   RUN git clone --branch v0.7.4 https://github.com/pgvector/pgvector.git /tmp/pgvector && \
       cd /tmp/pgvector && \
       make && make install && \
       rm -rf /tmp/pgvector

   # Copy initialization script to enable extensions
   COPY init-extensions.sh /docker-entrypoint-initdb.d/init-extensions.sh

   # Ensure the script is executable
   RUN chmod +x /docker-entrypoint-initdb.d/init-extensions.sh
   ```

3. **Create `init-extensions.sh`**:
   Save the following as `init-extensions.sh`:
   ```bash
   #!/bin/bash
   set -e
   psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS postgis;"
   psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS vector;"
   echo "Extensions postgis and vector enabled successfully"
   ```

4. **Build the Image**:
   ```bash
   docker build -t custom-postgres-immich:16-postgis-pgvector .
   ```
   Verify:
   ```bash
   docker images | grep custom-postgres-immich
   ```

## Step 2: Push the Image to GitHub Container Registry
1. **Create a GitHub Personal Access Token (PAT)**:
   - Go to [GitHub.com](https://github.com) > **Settings** > **Developer settings** > **Personal access tokens** > **Tokens (classic)**.
   - Generate a token with scopes: `read:packages`, `write:packages`, `delete:packages`.
   - Copy the token (starts with `ghp_` or `github_pat_`).

2. **Log in to ghcr.io**:
   ```bash
   echo "YOUR_PAT" | docker login ghcr.io -u USERNAME --password-stdin
   ```
   Replace `YOUR_PAT` with your token.

3. **Tag the Image**:
   ```bash
   docker tag custom-postgres-immich:16-postgis-pgvector ghcr.io/USERNAME/custom-postgres-immich:16-postgis-pgvector
   ```

4. **Push the Image**:
   ```bash
   docker push ghcr.io/USERNAME/custom-postgres-immich:16-postgis-pgvector
   ```

5. **Make the Image Public**:
   - Go to [GitHub.com](https://github.com) > Your profile > **Packages** > `custom-postgres-immich`.
   - Click **Package settings** > Change visibility to **Public**.

## Step 3: Configure Kubernetes Manifests
1. **Create `postgis-immich.yaml`**:
   Save the following to deploy a PostgreSQL StatefulSet with your custom image:
   ```yaml
   ---
   # Secret for PostgreSQL credentials
   apiVersion: v1
   kind: Secret
   metadata:
     name: postgis-credentials
     namespace: immich
   type: Opaque
   data:
     postgres-user: aW1taWNo # Base64-encoded "immich"
     postgres-password: aW1taWNocGFzcw== # Base64-encoded "immichpass"
     postgres-db: aW1taWNo # Base64-encoded "immich"
   ---
   # Headless Service for PostgreSQL
   apiVersion: v1
   kind: Service
   metadata:
     name: postgis
     namespace: immich
   spec:
     clusterIP: None # Headless service
     selector:
       app: postgis
     ports:
     - port: 5432
       targetPort: 5432
       protocol: TCP
       name: postgres
   ---
   # StatefulSet for PostgreSQL with PostGIS and pgvector
   apiVersion: apps/v1
   kind: StatefulSet
   metadata:
     name: postgis
     namespace: immich
   spec:
     serviceName: postgis
     replicas: 1
     selector:
       matchLabels:
         app: postgis
     template:
       metadata:
         labels:
           app: postgis
       spec:
         containers:
         - name: postgis
           image: ghcr.io/USERNAME/custom-postgres-immich:16-postgis-pgvector
           imagePullPolicy: IfNotPresent
           ports:
           - containerPort: 5432
             name: postgres
           env:
           - name: POSTGRES_USER
             valueFrom:
               secretKeyRef:
                 name: postgis-credentials
                 key: postgres-user
           - name: POSTGRES_PASSWORD
             valueFrom:
               secretKeyRef:
                 name: postgis-credentials
                 key: postgres-password
           - name: POSTGRES_DB
             valueFrom:
               secretKeyRef:
                 name: postgis-credentials
                 key: postgres-db
           volumeMounts:
           - name: postgis-data
             mountPath: /var/lib/postgresql/data
           readinessProbe:
             exec:
               command:
               - pg_isready
               - -U
               - immich
               - -d
               - immich
             initialDelaySeconds: 10
             periodSeconds: 5
           livenessProbe:
             exec:
               command:
               - pg_isready
               - -U
               - immich
               - -d
               - immich
             initialDelaySeconds: 30
             periodSeconds: 10
           resources:
             requests:
               memory: "512Mi"
               cpu: "500m"
             limits:
               memory: "1Gi"
               cpu: "1"
     volumeClaimTemplates:
     - metadata:
         name: postgis-data
       spec:
         accessModes: ["ReadWriteOnce"]
         storageClassName: local-path # SSD storage
         resources:
           requests:
             storage: 10Gi
   ```

2. **Create `immich-values.yaml`**:
   Save the following to configure Immich to use the external PostgreSQL:
   ```yaml
   # -------------------------------------------------------------------
   # General settings
   # -------------------------------------------------------------------
   global:
     storageClass: "local-path" # Or the storage class you use in k3s

   # -------------------------------------------------------------------
   # Immich app settings
   # -------------------------------------------------------------------
   immich:
     image:
       tag: "release"
     persistence:
       library:
         enabled: true
         existingClaim: immich-library-pvc # <--- use existing PVC
       profile:
         enabled: true
         size: 1Gi

   # -------------------------------------------------------------------
   # Immich server environment variables
   # Override the default DB_HOSTNAME template to point to PostGIS
   # -------------------------------------------------------------------
   server:
     env:
       TZ: "Europe/Ljubljana"
       DB_HOSTNAME: postgis.immich.svc.cluster.local # <- fixed hostname for PostGIS
       DB_PORT: 5432
       DB_USERNAME: immich
       DB_PASSWORD: immichpass
       DB_DATABASE_NAME: immich
       DB_VECTOR_EXTENSION: pgvector # Match the enabled extension
       SERVER_INIT_DELAY: 20
     startupProbe:
       enabled: false

   # -------------------------------------------------------------------
   # Database (PostgreSQL + PostGIS)
   # Bundled chart is deprecated; we are using external PostGIS
   # -------------------------------------------------------------------
   postgresql:
     enabled: false
   # inChart PostgreSQL is deprecated

   # -------------------------------------------------------------------
   # Redis
   # -------------------------------------------------------------------
   redis:
     enabled: true

   # -------------------------------------------------------------------
   # Ingress
   # -------------------------------------------------------------------
   ingress:
     main:
       enabled: true
       ingressClassName: "traefik"
       annotations:
         kubernetes.io/ingress.class: "traefik"
         traefik.ingress.kubernetes.io/router.entrypoints: "web"
       hosts:
       - host: photos.yourdomain.com
         paths:
         - path: /
           pathType: Prefix
           service:
             name: immich-server
             port: 2283
       # -------------------------------------------------------------------
       # Resources
       # -------------------------------------------------------------------
       #resources:
       #limits:
       #cpu: 1000m
       #memory: 1Gi
       #requests:
       #cpu: 250m
       #memory: 512Mi
   ```

3. **Create `immich-library-pvc.yaml`**:
   Immich requires a PVC for the library. Save the following:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: immich-library-pvc
     namespace: immich
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: local-path
     resources:
       requests:
         storage: 60Gi
   ```

## Step 4: Deploy on k3s
1. **Clean Up Existing Resources**:
   Remove any existing PostgreSQL resources to avoid conflicts:
   ```bash
   kubectl delete statefulset postgis -n immich --ignore-not-found
   kubectl delete pvc postgis-data-postgis-0 -n immich --ignore-not-found
   ```

2. **Apply the PVC**:
   ```bash
   kubectl apply -f immich-library-pvc.yaml -n immich
   ```

3. **Apply the PostgreSQL Manifest**:
   ```bash
   kubectl apply -f postgis-immich.yaml -n immich
   ```

4. **Verify PostgreSQL**:
   - Check pod status:
     ```bash
     kubectl get pods -n immich -l app=postgis -w
     ```
     Wait for `postgis-0` to be `Running`.
   - Check logs:
     ```bash
     kubectl logs -n immich postgis-0
     ```
     Look for `Extensions postgis and vector enabled successfully`.
   - Verify extensions:
     ```bash
     kubectl exec -it -n immich postgis-0 -- psql -U immich -d immich -c "\dx"
     ```
     Expected output:
     ```
     List of installed extensions
       Name   | Version |   Schema   |         Description
     --------+---------+------------+------------------------------
      postgis| 3.x.x   | public     | PostGIS geometry and geography
      vector | 0.7.4   | public     | Vector data type and functions
     ```

5. **Deploy Immich**:
   ```bash
   helm repo add immich https://immich-app.github.io/immich-charts
   helm repo update
   helm upgrade --install immich immich/immich -n immich -f immich-values.yaml
   ```

## Step 5: Verify Deployment
1. **Check Immich Pods**:
   ```bash
   kubectl get pods -n immich
   ```
   Expected output:
   ```
   NAME                              READY   STATUS    RESTARTS   AGE
   immich-server-xxx                 1/1     Running   0          <time>
   immich-microservices-xxx          1/1     Running   0          <time>
   immich-redis-xxx                  1/1     Running   0          <time>
   postgis-0                         1/1     Running   0          <time>
   ```

2. **Check Immich Server Logs**:
   ```bash
   kubectl logs -n immich deployment/immich-server -c server
   ```
   Confirm:
   - No errors (e.g., `Config validation error: "DB_VECTOR_EXTENSION" must be one of [pgvector, pgvecto.rs]`).
   - Successful database connection.

3. **Test Connectivity**:
   ```bash
   kubectl exec -it -n immich deployment/immich-server -- nslookup postgis.immich.svc.cluster.local
   ```
   Ensure it resolves to the PostgreSQL service IP.

4. **Access Immich**:
   - Open `http://photos.yourdomain.com` in a browser.
   - Verify DNS resolves to your k3s node’s IP:
     ```bash
     nslookup photos.yourdomain.com
     ```
   - For local testing, port-forward:
     ```bash
     kubectl port-forward -n immich svc/immich 3001:3001
     ```
     Access `http://localhost:3001`.

## Troubleshooting
- **PostgreSQL Pod Issues**:
  - If `postgis-0` isn’t `Running`:
    ```bash
    kubectl describe pod -n immich postgis-0
    ```
    Check for errors (e.g., image pull issues).
  - If extensions are missing:
    ```bash
    kubectl exec -it -n immich postgis-0 -- psql -U immich -d immich -c "\dx"
    ```
    Manually enable:
    ```bash
    kubectl exec -it -n immich postgis-0 -- psql -U immich -d immich -c "CREATE EXTENSION IF NOT EXISTS postgis;"
    kubectl exec -it -n immich postgis-0 -- psql -U immich -d immich -c "CREATE EXTENSION IF NOT EXISTS vector;"
    ```

- **Immich Connection Issues**:
  - If logs show database errors:
    ```bash
    kubectl exec -it -n immich postgis-0 -- pg_isready -U immich -d immich
    ```
    Test from Immich:
    ```bash
    kubectl exec -it -n immich deployment/immich-server -- psql -h postgis.immich.svc.cluster.local -U immich -d immich -c "SELECT 1;"
    ```

- **Ingress Issues**:
  - Check Traefik logs:
    ```bash
    kubectl logs -n immich deployment/traefik
    ```
  - Verify Ingress:
    ```bash
    kubectl get ingress -n immich
    ```

- **Disk Space**:
  - Check SSD storage:
    ```bash
    kubectl exec -it -n immich postgis-0 -- df -h /var/lib/postgresql/data
    ```
    Ensure 10Gi is available.

## Notes
- The custom image avoids runtime `apt-get` and extension errors by pre-installing PostGIS and `pgvector`.
- `DB_VECTOR_EXTENSION: pgvector` in `immich-values.yaml` matches the `vector` extension in the database.
- The `immich-library-pvc` (60Gi) is critical for storing photos.
- Ensure `photos.yourdomain.com` resolves to your k3s node’s IP.

## References
- Immich Helm Chart: https://immich-app.github.io/immich-charts
- GitHub Container Registry: https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry
- k3s Documentation: https://docs.k3s.io/
```