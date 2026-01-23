# Headless Service Feature Implementation Summary

## Overview
This document summarizes all changes made to add headless service support to the Redis operator, allowing Redis replicas to be configured using DNS names instead of PodIPs.

## Reason for Change

The headless service feature was added to address the following limitations and requirements:

1. **Pod IP Instability**: When Redis replicas are configured using PodIPs, pod restarts result in new IP addresses. This requires reconfiguration of all replicas pointing to the restarted pod, leading to:
   - Temporary replication failures during pod restarts
   - Increased operator reconciliation overhead
   - Potential data inconsistency windows during failover scenarios

2. **StatefulSet DNS Naming**: Kubernetes StatefulSets provide stable DNS names for each pod in the format `<pod-name>.<service-name>.<namespace>.svc.cluster.local`. These DNS names remain constant across pod restarts, providing a stable network identity that aligns with Kubernetes best practices for stateful workloads.

3. **Network Identity Persistence**: Using DNS names instead of IPs ensures that:
   - Redis replicas can maintain stable connections to their masters
   - Replication relationships survive pod restarts without requiring operator intervention
   - The cluster topology remains consistent even when individual pods are recreated

4. **Kubernetes Best Practices**: Headless services are the recommended approach for StatefulSets when you need to address individual pods directly, which is exactly what Redis replication requires.

5. **Operational Benefits**: 
   - Reduced operator reconciliation cycles
   - More predictable cluster behavior during rolling updates
   - Better alignment with Kubernetes networking patterns
   - Easier debugging with stable, human-readable DNS names

## Feature Description
When `headless: true` is enabled in the RedisFailover spec, the operator:
- Creates a headless service (ClusterIP: None) for Redis pods
- Uses DNS names in the format `<statefulset-name>-<ordinal-number>.<service-name>.<namespace>.svc.cluster.local` to configure Redis replicas
- Uses DNS names for Redis-to-Redis connections (slaveof commands)
- Uses IP addresses for Sentinel monitoring (as required by Redis Sentinel)

## Files Modified

### 1. API Types (`api/redisfailover/v1/types.go`)
**Change**: Added `Headless` boolean field to `RedisSettings` struct
```go
Headless bool `json:"headless,omitempty"`
```
- Allows users to enable/disable headless service mode in the RedisFailover spec

### 2. Service Generator (`operator/redisfailover/service/generator.go`)
**Changes**:
- Modified `generateRedisService()` to create a headless service when `rf.Spec.Redis.Headless` is true
- Service is created with `ClusterIP: corev1.ClusterIPNone`
- Conditionally includes Redis port in service definition when headless is enabled
- Service is created if either `headless: true` OR `exporter.enabled: true`

**Key Logic**:
- If headless is enabled, always include the Redis port
- If exporter is enabled, also include the exporter port
- Service selector matches Redis pod labels

### 3. Service Names (`operator/redisfailover/service/names.go`)
**New Functions Added**:

1. **`GetPodDNSName(pod, rf)`**: 
   - Constructs DNS name for a StatefulSet pod
   - Format: `<statefulset-name>-<ordinal>.<service-name>.<namespace>.svc.cluster.local`
   - Example: `rfr-redisfailover-0.rfr-redisfailover.basic.svc.cluster.local`

2. **`GetPodAddress(pod, rf)`**:
   - Returns DNS name if headless is enabled AND pod is Ready AND pod has IP
   - Falls back to PodIP otherwise
   - Ensures DNS names are only used when DNS records are available

3. **`GetPodIPFromAddress(address, rf, pods)`**:
   - Converts DNS names to IP addresses
   - Used for Sentinel monitoring (which only accepts IPs)
   - Handles both DNS names and IP addresses
   - Matches pods by DNS name or by extracting ordinal from DNS name

4. **`isPodReady(pod)`**:
   - Helper function to check if pod has Ready condition with status True

### 4. Ensurer (`operator/redisfailover/ensurer.go`)
**Change**: Modified service creation logic
- Service is now created if `rf.Spec.Redis.Exporter.Enabled || rf.Spec.Redis.Headless`
- Previously only created if exporter was enabled
- Ensures headless service exists even when exporter is disabled

### 5. Healer (`operator/redisfailover/service/heal.go`)
**Changes**:
- All Redis client calls now use `GetPodAddress()` instead of `pod.Status.PodIP`
- Functions affected:
  - `SetOldestAsMaster()`: Uses DNS names when configuring master/slave relationships
  - `SetMasterOnAll()`: Uses DNS names when setting all pods as slaves of a master
  - `SetExternalMasterOnAll()`: Uses DNS names for pod addresses
- Enhanced logging to show both pod address and master address

### 6. Checker (`operator/redisfailover/service/check.go`)
**Changes**:
- All Redis client calls use `GetPodAddress()` instead of `pod.Status.PodIP`
- `GetRedisesIPs()`: Returns DNS names or IPs based on headless configuration
- `CheckAllSlavesFromMaster()`: Fixed comparison logic to handle DNS names
  - Resolves master DNS name to IP for comparison (since Redis returns resolved IPs)
  - Prevents false positives when comparing DNS names with IPs
- Added `GetRedisesPods()` method to interface and implementation
  - Returns PodList for resolving DNS names to IPs
- **`GetMasterIP()` Bug Fix**: Fixed logic that was appending master address twice
  - **Reason**: When a master was found (IP address), the code would:
    1. Find the matching pod and append `GetPodAddress(&pod, rf)` to the masters list
    2. Then check if the last element equals the original IP and append it again as a fallback
  - This caused the function to detect 2 masters instead of 1, leading to errors like "number of redis nodes known as master is different than 1"
  - **Fix**: Simplified logic to only append once - if pod is found, append its address; if not found, append IP as fallback
  - Ensures correct master detection in both headless and non-headless modes

### 7. Checker Handler (`operator/redisfailover/checker.go`)
**Changes**:
- Modified sentinel monitoring configuration
- Converts master DNS name to IP before configuring Sentinel
- Sentinel's `SENTINEL MONITOR` command only accepts IP addresses
- Uses `GetPodIPFromAddress()` to resolve DNS names to IPs for Sentinel

### 8. CRD Manifests
**Files Modified**:
- `manifests/databases.spotahome.com_redisfailovers.yaml`
- `manifests/kustomize/base/databases.spotahome.com_redisfailovers.yaml`

**Change**: Added `headless` field to CRD schema
```yaml
headless:
  type: boolean
```

### 9. Build Script (`build.sh`)
**Change**: Modified to accept tag as argument
- `TAG=${1:-v4}` - Uses first argument as tag, defaults to v4
- Allows building and loading Docker images with custom tags

### 10. Validation Script (`valid.sh`)
**Change**: Enhanced validation script with:
- Explanation that Redis's `INFO replication` always shows IP addresses (expected behavior)
- Instructions on how to validate DNS names are being used (check operator logs)
- Shows expected DNS names for each pod
- Provides guidance on forcing reconfiguration to test DNS name usage

## Key Design Decisions

### 1. DNS Names Only When Pods Are Ready
- DNS records for headless services are only created when pods are in Ready state
- `GetPodAddress()` checks pod readiness before returning DNS names
- Falls back to PodIP if pod is not ready or headless is disabled

### 2. Sentinel Uses IP Addresses
- Redis Sentinel's `SENTINEL MONITOR` command only accepts IP addresses, not DNS names
- The operator converts DNS names to IPs when configuring Sentinel
- Redis-to-Redis connections (slaveof) use DNS names for stability

### 3. Service Creation Logic
- Headless service is created if either `headless: true` OR `exporter.enabled: true`
- This ensures the service exists for DNS resolution even when exporter is disabled
- Service includes appropriate ports based on enabled features

### 4. Comparison Logic Fix
- Redis's `INFO replication` returns resolved IP addresses, not DNS names
- Comparison logic in `CheckAllSlavesFromMaster()` resolves DNS names to IPs before comparing
- Prevents false positives when checking if slaves are configured correctly

## Benefits

1. **Stable Network Identity**: DNS names remain constant even when pods restart and get new IPs
2. **Better Pod Lifecycle Management**: Replicas can reconnect using stable DNS names after pod restarts
3. **Kubernetes Best Practices**: Uses StatefulSet DNS naming convention
4. **Backward Compatible**: When `headless: false` (default), behavior is unchanged

## Usage Example

```yaml
apiVersion: databases.spotahome.com/v1
kind: RedisFailover
metadata:
  name: redisfailover
  namespace: basic
spec:
  redis:
    replicas: 3
    headless: true  # Enable headless service
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
  sentinel:
    replicas: 3
```

## Validation

To validate that DNS names are being used:

1. **Check Operator Logs**:
   ```bash
   kubectl logs -n <operator-namespace> <operator-pod> | grep "Making pod.*slave of"
   ```
   Should show DNS names like:
   ```
   Making pod rfr-redisfailover-1 (address: rfr-redisfailover-1.rfr-redisfailover.basic.svc.cluster.local) slave of rfr-redisfailover-0.rfr-redisfailover.basic.svc.cluster.local
   ```

2. **Note**: Redis's `INFO replication` will always show IP addresses (this is expected - Redis resolves DNS to IPs when connecting)

3. **Force Reconfiguration**: Delete a replica pod and watch operator logs to see DNS names being used

## Testing

The validation script (`valid.sh`) can be used to check:
- Pod readiness status
- Expected DNS names for each pod
- Redis replication status
- Guidance on proper validation methods

## Known Limitations

1. DNS names are only used when pods are in Ready state
2. If pods are configured before they become Ready, IPs may be used initially
3. Redis's `INFO replication` always shows resolved IP addresses (not DNS names)
4. Sentinel monitoring always uses IP addresses (Redis Sentinel limitation)

## Future Enhancements

Potential improvements:
- Add metrics to track DNS name usage vs IP usage
- Add validation to ensure DNS names are resolvable before using them
- Consider caching DNS-to-IP mappings to reduce lookups
