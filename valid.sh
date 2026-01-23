#!/bin/bash
NAMESPACE="basic"
REDIS_NAME="redisfailover"
SERVICE_NAME="rfr-${REDIS_NAME}"

echo "=== Validating Redis Replica Configuration (DNS Mode - disableIPMode: true) ==="
echo ""
echo "NOTE: Redis's INFO replication shows resolved IP addresses, not DNS names."
echo "      This is expected - Redis resolves DNS names to IPs when connecting."
echo "      To validate DNS names are being used, check operator logs for 'Making pod' messages."
echo ""

# Get all Redis pods
PODS=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=redis -o jsonpath='{.items[*].metadata.name}')

for pod in $PODS; do
    echo "--- Checking pod: ${pod} ---"
    
    # Get pod IP and Ready status
    POD_IP=$(kubectl get pod ${pod} -n ${NAMESPACE} -o jsonpath='{.status.podIP}')
    READY=$(kubectl get pod ${pod} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    echo "Pod IP: ${POD_IP}"
    echo "Ready: ${READY}"
    
    # Calculate expected DNS name
    ORDINAL=$(echo ${pod} | grep -oE '[0-9]+$')
    EXPECTED_DNS="${SERVICE_NAME}-${ORDINAL}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
    echo "Expected DNS (if disableIPMode: true): ${EXPECTED_DNS}"
    
    # Get replication info
    REPL_INFO=$(kubectl exec -it ${pod} -n ${NAMESPACE} -- redis-cli INFO replication 2>/dev/null)
    
    # Extract master_host
    MASTER_HOST=$(echo "$REPL_INFO" | grep "master_host:" | cut -d: -f2 | tr -d '\r' | xargs)
    
    if [ -z "$MASTER_HOST" ]; then
        echo "  Role: MASTER (no master_host)"
    else
        echo "  Role: REPLICA"
        echo "  Master Host (from Redis): ${MASTER_HOST}"
        echo ""
        echo "  ⚠️  IMPORTANT: Redis always shows resolved IPs in INFO replication."
        echo "     This is expected behavior - Redis resolves DNS names to IPs when connecting."
        echo "     To verify DNS names are being used, check operator logs:"
        echo "     kubectl logs -n <operator-namespace> <operator-pod> | grep 'Making pod.*slave of'"
        echo ""
        echo "     You should see DNS names like:"
        echo "     Making pod rfr-redisfailover-1 (address: rfr-redisfailover-1.rfr-redisfailover.basic.svc.cluster.local) slave of rfr-redisfailover-0.rfr-redisfailover.basic.svc.cluster.local"
    fi
    
    # Get master_link_status
    LINK_STATUS=$(echo "$REPL_INFO" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r' | xargs)
    echo "  Link Status: ${LINK_STATUS}"
    echo ""
done

echo ""
echo "=== To validate DNS names are actually being used ==="
echo "1. Check operator logs for 'Making pod' messages:"
echo "   kubectl logs -n <operator-namespace> <operator-pod> | grep 'Making pod.*slave of'"
echo ""
echo "2. Force a reconfiguration by deleting a replica pod:"
echo "   kubectl delete pod rfr-redisfailover-1 -n ${NAMESPACE}"
echo "   Then check the operator logs to see what address is used."
echo ""
echo "3. The operator should use DNS names when:"
echo "   - disableIPMode: true is set in the RedisFailover spec"
echo "   - Pods are in Ready state"
echo "   - DNS records are available in the cluster"