# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Overview

This repository contains a comprehensive Istio Service Mesh v3 POC (Proof of Concept) focused on observability, distributed tracing, and traffic management. The setup demonstrates advanced Istio features including:

- **Distributed Tracing**: OpenTelemetry → Tempo → Grafana pipeline
- **Observability Stack**: Prometheus, Grafana, Kiali integration
- **Gateway Management**: Ingress/Egress gateway configurations
- **Sample Application**: Istio Bookinfo microservices demo
- **Security**: mTLS, RBAC, and service mesh policies

## Architecture

### Core Components

**Service Mesh Control Plane**:
- Istio Sail Operator (v1.24.6) with control plane in `istio-system` namespace
- OpenTelemetry collector for trace ingestion (OTLP protocol)
- Telemetry configuration with 100% sampling rate

**Storage & Observability**:
- **Tempo**: Distributed tracing backend with multi-tenant support (north/south tenants)
- **MinIO**: S3-compatible storage backend for Tempo traces
- **Grafana**: Visualization with pre-configured Istio dashboards
- **Prometheus**: Metrics collection with custom ServiceMonitors and PodMonitors
- **Kiali**: Service mesh topology and configuration management

**Applications**:
- **Bookinfo**: Multi-version sample application with ratings, reviews, details, and productpage services
- **Gateway Configurations**: Both ingress and egress traffic management examples

### Directory Structure

- **Root**: Main Istio resources (bookinfo.yaml, istio.yaml, etc.)
- `egress-gw-after-some-sweating/`: Advanced egress gateway configurations with mTLS
- `gw-injection/`: Gateway injection templates and deployments
- `app-test/`: Application-specific testing configurations
- `subsets/`: Traffic splitting and subset routing configurations
- `multiple-gws/`: Multi-gateway deployment patterns

## Common Development Commands

### Deployment Commands

```bash
# Deploy Istio control plane
kubectl apply -f istio.yaml

# Deploy the Bookinfo application
kubectl apply -f bookinfo.yaml

# Configure ingress gateway
kubectl apply -f bookinfo-gateway.yaml

# Enable distributed tracing
kubectl apply -f istio-telemetry.yaml
kubectl apply -f open-telemetry-collector.yaml

# Deploy observability stack
kubectl apply -f grafana.yaml
kubectl apply -f tempo-stack.yaml
kubectl apply -f minio.yaml

# Setup monitoring
kubectl apply -f enable-prometheus-metrics.yaml
kubectl apply -f bookinfo-pod-monitor.yaml
kubectl apply -f istio-pod-monitor.yaml
```

### Tempo Stack Setup

```bash
# Create MinIO secret for Tempo storage (run the shell script)
./tempo-secret.sh

# Deploy complete tracing pipeline
kubectl apply -f tempo-stack.yaml
kubectl apply -f open-telemetry-collector.yaml
```

### Gateway Management

```bash
# Deploy standard ingress gateway
kubectl apply -f ingress-gateway.yaml

# Deploy custom egress gateway with injection
kubectl apply -f gw-injection/gateway-deployment.yml
kubectl apply -f gw-injection/gateway-service.yml

# Configure advanced egress routing
kubectl apply -f egress-gw-after-some-sweating/egress-gw.yaml
kubectl apply -f egress-gw-after-some-sweating/egress-vs.yaml
```

### Monitoring and Observability

```bash
# Apply custom monitoring configurations
kubectl apply -f bookinfo-pod-monitor.yaml
kubectl apply -f istio-pod-monitor-bookinfo.yaml
kubectl apply -f curl-pod-monitor.yaml

# Deploy Kiali for service mesh visualization
kubectl apply -f kiali-CR.yaml
```

### Traffic Management

```bash
# Apply traffic splitting configurations
kubectl apply -f subsets/

# Configure HTTP routing
kubectl apply -f http-gtw.yaml
kubectl apply -f http-vs.yaml
kubectl apply -f http-se.yaml
```

## Key Configuration Patterns

### OpenTelemetry Integration
- OTLP gRPC endpoint on port 4317
- Bearer token authentication for Tempo
- TLS with service CA certificates
- Multi-tenant tracing with tenant headers

### mTLS and Security
- Automatic mTLS injection via `sidecar.istio.io/inject: "true"`
- Custom security contexts with non-root containers
- RBAC configurations for service accounts
- NetworkPolicies for traffic segmentation

### Gateway Injection Pattern
- Uses `inject.istio.io/templates: gateway` annotation
- Custom resource limits and security contexts
- Service account bindings for secret access
- Port configurations for Envoy proxy (15090)

### Monitoring Stack Integration
- ServiceMonitors for Prometheus scraping
- PodMonitors for application-level metrics  
- Custom Grafana dashboards for Istio components
- Kiali integration with OpenShift Monitoring

## Observability Endpoints

**Grafana Dashboards**:
- Istio Performance Dashboard
- Istio Control Plane Dashboard  
- Istio Mesh Dashboard
- Istio Service Dashboard
- Istio Wasm Extension Dashboard

**Trace Collection**:
- OpenTelemetry Collector: `otel-collector.istio-system.svc.cluster.local:4317`
- Tempo Gateway: `tempo-sample-gateway.tempo.svc.cluster.local:8090`

**Storage Backend**:
- MinIO: `minio.tempo.svc.cluster.local:9000`
- Bucket: `tempo-data`

## Testing and Development

### Validation Commands
```bash
# Check Istio installation
kubectl get istio -n istio-system

# Verify trace collection
kubectl logs -n istio-system deployment/otel-collector

# Test connectivity
kubectl exec -n default deployment/productpage-v1 -- curl -s http://details:9080/details/0

# Check mTLS status
kubectl exec -n default deployment/productpage-v1 -- openssl s_client -connect details:9080
```

### Debugging Patterns
- Use `kubectl describe` on PodMonitors and ServiceMonitors for Prometheus integration issues
- Check OpenTelemetry Collector logs for trace ingestion problems
- Verify TempoStack status for storage backend connectivity
- Use Kiali UI for service mesh configuration validation

## Environment Assumptions

- **Platform**: OpenShift/Kubernetes cluster
- **Storage**: Persistent volumes available for MinIO
- **Networking**: Service mesh networking enabled
- **Operators**: Istio Sail Operator, OpenTelemetry Operator, Tempo Operator
- **Permissions**: Cluster admin access for CRD installations

This setup represents a production-ready service mesh observability stack with comprehensive tracing, metrics, and visualization capabilities.
