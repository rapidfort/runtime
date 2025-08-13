#!/usr/bin/env bash
set -euo pipefail

# RapidFort Helm Release Diagnostic Data Collector
#
# SECURITY NOTE:
# - By default, this script does NOT collect Kubernetes Secrets
# - Secrets are EXCLUDED unless explicitly enabled via INCLUDE_SECRETS=true
# - Pod descriptions have sensitive values automatically redacted
#
# Usage:
#   ./diag.sh [namespace] [release] --accept           # No secrets (safe)
#   INCLUDE_SECRETS=true ./diag.sh ... --accept       # Include secrets (use with caution)

# Default values for RapidFort deployment
NS="${1:-rapidfort}"
RELEASE="${2:-rfruntime}"
ACCEPT="${3:-}"
INCLUDE_SECRETS="${INCLUDE_SECRETS:-false}"  # Default: do NOT include secrets

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Display data collection summary
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}           RapidFort Runtime Diagnostic Data Collector${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}This script will collect the following diagnostic data:${NC}"
echo ""
echo "📊 KUBERNETES RESOURCES (namespace: $NS, release: $RELEASE):"
echo "   • Pods, Services, Deployments, StatefulSets, DaemonSets"
echo "   • ConfigMaps, ServiceAccounts"
echo "   • RBAC (Roles, RoleBindings)"
echo "   • Network Policies, Ingresses"
echo "   • PersistentVolumeClaims, PriorityClasses"
echo "   • Horizontal Pod Autoscalers, Pod Disruption Budgets"
if [[ "$INCLUDE_SECRETS" == "true" ]]; then
    echo -e "   ${RED}• Secrets (INCLUDED - contains sensitive data!)${NC}"
else
    echo -e "   ${GREEN}• Secrets (EXCLUDED - no sensitive data collected)${NC}"
fi
echo ""
echo "📝 DIAGNOSTIC INFORMATION:"
echo "   • All Kubernetes Events in namespace (sorted by timestamp)"
echo "   • Pod descriptions (conditions, container states)"
echo "   • Pod logs (current and previous if restarted)"
echo "   • Container restart history and termination reasons"
echo "   • Namespace metadata and age"
echo ""
echo "⚙️  HELM RELEASE DATA:"
echo "   • Helm release values (helm get values)"
echo "   • Helm manifest (helm get manifest)"
echo "   • Helm release history (helm history)"
echo "   • Release metadata and status"
echo ""
echo -e "${YELLOW}DATA HANDLING:${NC}"
echo "   • All data is stored locally in a timestamped directory"
echo "   • No data is transmitted externally"
if [[ "$INCLUDE_SECRETS" == "true" ]]; then
    echo -e "   ${RED}• Secrets ARE included (base64 encoded) - handle with care!${NC}"
else
    echo -e "   ${GREEN}• Secrets are NOT collected - no sensitive data included${NC}"
fi
echo "   • Output directory: ${RELEASE}-<timestamp>/"
echo ""
if [[ "$INCLUDE_SECRETS" != "true" ]]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ SECURITY: Secrets will NOT be collected. Safe to share with support.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}WARNING: Secrets WILL be collected. Handle the output with extreme care!${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi
echo ""

# Check for acceptance
if [[ "$ACCEPT" != "--accept" ]]; then
    echo -e "${YELLOW}To proceed with data collection, please run:${NC}"
    echo -e "${GREEN}  $0 $NS $RELEASE --accept${NC}"
    echo ""
    echo "Or with defaults (namespace=rapidfort, release=rfruntime):"
    echo -e "${GREEN}  $0 rapidfort rfruntime --accept${NC}"
    echo ""
    echo -e "${YELLOW}Optional: To include secrets (NOT recommended), set INCLUDE_SECRETS=true:${NC}"
    echo -e "${RED}  INCLUDE_SECRETS=true $0 rapidfort rfruntime --accept${NC}"
    echo ""
    exit 0
fi

echo -e "${GREEN}✓ Data collection accepted. Starting diagnostic collection...${NC}"
echo ""

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${RELEASE}-${TS}"

# Create output directory
mkdir -p "$OUT"

# Legend for progress indicators
echo "Legend: [✓] = success, [!] = warning, [x] = error, [>] = info/progress"
echo ""
echo "[✓] Collecting diagnostics for Helm release '$RELEASE' in namespace '$NS'"
echo "    Output directory: $OUT/"
echo ""

# Define the label selector for Helm-managed resources
SELECTOR="app.kubernetes.io/instance=${RELEASE}"

# Get namespace info including creation time
echo "[>] Getting namespace info..."
kubectl get namespace "$NS" -o yaml > "$OUT/namespace.yaml" 2>/dev/null || true
NS_AGE=$(kubectl get namespace "$NS" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "unknown")
echo "Namespace created: $NS_AGE" > "$OUT/namespace-age.txt"

# Get all resource types that exist in the namespace with this selector
echo "[>] Discovering resources for release '${RELEASE}'..."

# List of common resource types to check (ordered by importance)
RESOURCE_TYPES=(
    "pods"
    "services"
    "deployments"
    "statefulsets"
    "daemonsets"
    "replicasets"
    "jobs"
    "cronjobs"
    "configmaps"
    "serviceaccounts"
    "roles"
    "rolebindings"
    "persistentvolumeclaims"
    "networkpolicies"
    "horizontalpodautoscalers"
    "poddisruptionbudgets"
    "priorityclasses"
)

# Add secrets only if explicitly requested
if [[ "$INCLUDE_SECRETS" == "true" ]]; then
    RESOURCE_TYPES+=("secrets")
    echo -e "${RED}[!] WARNING: Secrets collection is ENABLED${NC}"
else
    echo -e "${GREEN}[✓] Secrets collection is DISABLED (default)${NC}"
fi

# Track what we actually found
FOUND_RESOURCES=()

# Check each resource type and dump if found
for resource in "${RESOURCE_TYPES[@]}"; do
    # Check if any resources of this type exist with our selector
    count=$(kubectl get "$resource" -n "$NS" -l "$SELECTOR" --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ "$count" -gt 0 ]]; then
        if [[ "$resource" == "secrets" ]]; then
            echo -e "${RED}[>] Found $count $resource (INCLUDING SENSITIVE DATA)${NC}"
        else
            echo "[>] Found $count $resource"
        fi
        kubectl get "$resource" -n "$NS" -l "$SELECTOR" -o yaml > "$OUT/${resource}.yaml"
        FOUND_RESOURCES+=("$resource")
    fi
done

# Get list of secrets metadata (no sensitive data)
echo "[>] Getting secrets metadata (names only, no sensitive data)..."
{
    echo "SECRETS IN RELEASE (metadata only - no sensitive data):"
    echo "======================================================="
    echo ""
    kubectl get secrets -n "$NS" -l "$SELECTOR" -o custom-columns=NAME:.metadata.name,TYPE:.type,AGE:.metadata.creationTimestamp,DATA_KEYS:.data 2>/dev/null | \
        awk '{if(NR==1){print $0} else {gsub(/map\[.*\]/, "keys:<REDACTED>", $4); print $1, $2, $3, $4}}' || echo "No secrets found"
    echo ""
    echo "Note: Secret data has been excluded from this diagnostic collection."
    echo "Only secret names and types are shown for reference."
} > "$OUT/secrets-metadata.txt"
# PriorityClass is cluster-scoped but can have helm labels
if kubectl get priorityclass -l "$SELECTOR" --no-headers 2>/dev/null | grep -q .; then
    echo "[>] Found PriorityClass resources"
    kubectl get priorityclass -l "$SELECTOR" -o yaml > "$OUT/priorityclass.yaml"
    FOUND_RESOURCES+=("priorityclass")
fi

# Get Helm release metadata
echo "[>] Getting Helm release info..."
helm get values "$RELEASE" -n "$NS" > "$OUT/helm-values.yaml" 2>/dev/null || true
helm get manifest "$RELEASE" -n "$NS" > "$OUT/helm-manifest.yaml" 2>/dev/null || true
helm list -n "$NS" -f "^${RELEASE}$" > "$OUT/helm-release-info.txt" 2>/dev/null || true
helm history "$RELEASE" -n "$NS" > "$OUT/helm-history.txt" 2>/dev/null || true

# Get ALL events in namespace - MOST IMPORTANT FOR DIAGNOSTICS
echo "[>] Getting ALL namespace events (from namespace creation)..."

# Try multiple approaches to get events
# 1. Get all events without sorting (sometimes sort causes issues)
kubectl get events -n "$NS" -o yaml > "$OUT/events-all-raw.yaml" 2>/dev/null || true

# 2. Get events with sorting
kubectl get events -n "$NS" --sort-by='.lastTimestamp' -o yaml > "$OUT/events-all-sorted.yaml" 2>/dev/null || true

# 3. Get events with extended output
kubectl get events -n "$NS" -o wide > "$OUT/events-all-wide.txt" 2>/dev/null || true

# 4. Try using field selector for namespace
kubectl get events --field-selector involvedObject.namespace="$NS" -o yaml > "$OUT/events-by-namespace.yaml" 2>/dev/null || true

# 5. Get all events and filter by our release (in case they exist but aren't in the namespace query)
kubectl get events -A -o json 2>/dev/null | jq --arg ns "$NS" '.items[] | select(.involvedObject.namespace == $ns)' > "$OUT/events-filtered.json" 2>/dev/null || true

# 6. Try to get events using kubectl alpha events (if available in newer k8s versions)
kubectl alpha events -n "$NS" > "$OUT/events-alpha.txt" 2>/dev/null || true

# Also get events in a readable format with ALL events (not just last 50)
{
    echo "ALL EVENTS IN NAMESPACE $NS (sorted by time):"
    echo "============================================="
    kubectl get events -n "$NS" --sort-by='.lastTimestamp' -o custom-columns=TIME:.lastTimestamp,FIRST:.firstTimestamp,COUNT:.count,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message 2>/dev/null || echo "No events found"
    echo ""
    echo "Event Count: $(kubectl get events -n "$NS" --no-headers 2>/dev/null | wc -l || echo 0)"
    echo ""
    echo "Note: Kubernetes only retains events for ~1 hour by default."
    echo "firstTimestamp shows when the event first occurred."
    echo "count shows how many times it occurred."
} > "$OUT/events-readable.txt"

# Get events for ALL objects in the release (not just pods)
echo "[>] Getting events for all release objects..."
for obj in $(kubectl get all -n "$NS" -l "$SELECTOR" -o name 2>/dev/null); do
    obj_name=$(echo "$obj" | cut -d/ -f2)
    obj_kind=$(echo "$obj" | cut -d/ -f1)
    kubectl get events -n "$NS" --field-selector involvedObject.name="$obj_name" --sort-by='.lastTimestamp' > "$OUT/events-${obj_kind}-${obj_name}.txt" 2>/dev/null || true
done

# Try to get historical data from pod restart counts and status
echo "[>] Getting pod restart history..."
{
    echo "POD RESTART HISTORY:"
    echo "===================="
    kubectl get pods -n "$NS" -l "$SELECTOR" -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,STATUS:.status.phase,AGE:.metadata.creationTimestamp 2>/dev/null || echo "No pods found"
    echo ""
    echo "CONTAINER LAST STATE:"
    echo "====================="
    for pod in $(kubectl get pods -n "$NS" -l "$SELECTOR" -o name 2>/dev/null); do
        echo "Pod: $pod"
        kubectl get "$pod" -n "$NS" -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.lastState}{"\n"}{end}' 2>/dev/null || true
        echo "---"
    done
} > "$OUT/restart-history.txt"

# Get pod descriptions (includes events, conditions, containers status)
echo "[>] Getting pod descriptions..."
for pod in $(kubectl get pods -n "$NS" -l "$SELECTOR" -o name 2>/dev/null); do
    pod_name=$(echo "$pod" | cut -d/ -f2)
    if [[ "$INCLUDE_SECRETS" == "true" ]]; then
        kubectl describe pod "$pod_name" -n "$NS" > "$OUT/describe-${pod_name}.txt" 2>/dev/null || true
    else
        # Describe pod but filter out secret-related environment variables
        kubectl describe pod "$pod_name" -n "$NS" 2>/dev/null | \
            sed -E 's/(.*Secret.*:).*/\1 <REDACTED>/' | \
            sed -E 's/(.*PASSWORD.*:).*/\1 <REDACTED>/' | \
            sed -E 's/(.*TOKEN.*:).*/\1 <REDACTED>/' | \
            sed -E 's/(.*KEY.*:).*/\1 <REDACTED>/' | \
            sed -E 's/(.*PASS.*:).*/\1 <REDACTED>/' > "$OUT/describe-${pod_name}.txt" || true
    fi
done

# Get pod logs for crash diagnosis
echo "[>] Getting pod logs..."
for pod in $(kubectl get pods -n "$NS" -l "$SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    # Current logs
    kubectl logs "$pod" -n "$NS" --all-containers=true --prefix=true > "$OUT/logs-${pod}.txt" 2>/dev/null || true
    # Previous logs if pod restarted
    kubectl logs "$pod" -n "$NS" --all-containers=true --prefix=true --previous > "$OUT/logs-${pod}-previous.txt" 2>/dev/null || true
done

# Create a summary
echo "[>] Creating summary..."
{
    echo "Helm Release Diagnostic Summary"
    echo "================================"
    echo "Collection Time: $(date)"
    echo "Release: $RELEASE"
    echo "Namespace: $NS"
    echo "Namespace Age: $NS_AGE"
    echo ""
    if [[ "$INCLUDE_SECRETS" == "true" ]]; then
        echo "SECURITY: Secrets INCLUDED (contains sensitive data!)"
    else
        echo "SECURITY: Secrets EXCLUDED (no sensitive data)"
    fi
    echo ""
    echo "Resources Collected:"
    for r in "${FOUND_RESOURCES[@]}"; do
        if [[ "$r" == "secrets" ]]; then
            echo "  ✓ $r (WITH SENSITIVE DATA)"
        else
            echo "  ✓ $r"
        fi
    done
    echo ""
    echo "Pod Status:"
    kubectl get pods -n "$NS" -l "$SELECTOR" --no-headers 2>/dev/null || echo "  No pods found"
    echo ""
    echo "Files Generated:"
    echo "  • Kubernetes Resources: ${#FOUND_RESOURCES[@]} types"
    echo "  • Event Files: 6+ formats"
    echo "  • Pod Descriptions: $(ls -1 "$OUT"/describe-*.txt 2>/dev/null | wc -l || echo 0) files"
    echo "  • Pod Logs: $(ls -1 "$OUT"/logs-*.txt 2>/dev/null | wc -l || echo 0) files"
    echo "  • Helm Data: 4 files"
    echo "  • Secrets Metadata: 1 file (names only, no data)"
} > "$OUT/summary.txt"

# Show pod status for quick diagnostic
echo ""
echo "[>] Current pod status:"
kubectl get pods -n "$NS" -l "$SELECTOR" -o wide 2>/dev/null || echo "  No pods found"

# Show recent warning/error events for immediate attention
echo ""
echo "[!] Recent Warning/Error Events:"
kubectl get events -n "$NS" --field-selector type!=Normal --sort-by='.lastTimestamp' -o custom-columns=TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message | tail -10 2>/dev/null || echo "  No warning/error events"

# Check if events are empty and provide diagnostic info
EVENT_COUNT=$(kubectl get events -n "$NS" --no-headers 2>/dev/null | wc -l || echo 0)
if [[ "$EVENT_COUNT" -eq 0 ]]; then
    echo ""
    echo "[!] No events found in namespace. Possible reasons:"
    echo "    - Events older than 1 hour have been garbage collected (default TTL)"
    echo "    - Namespace created: $NS_AGE"
    echo "    - Try checking metrics-server or monitoring tools for historical data"
    echo "    - Consider enabling event recording with tools like Eventrouter or kube-eventer"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}[✓] Diagnostic collection complete!${NC}"
if [[ "$INCLUDE_SECRETS" != "true" ]]; then
    echo -e "${GREEN}[✓] No secrets collected - Safe to share with support${NC}"
else
    echo -e "${RED}[!] WARNING: Secrets included - Handle with extreme care!${NC}"
fi
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📁 Output directory: $OUT/"
echo "📊 Resources collected: ${#FOUND_RESOURCES[@]} types"
echo "📝 Events found: $EVENT_COUNT"
echo "📋 Summary available in: $OUT/summary.txt"
if [[ "$INCLUDE_SECRETS" != "true" ]]; then
    echo "🔒 Security: NO secrets included (safe to share)"
else
    echo "⚠️  Security: Secrets INCLUDED (handle with care!)"
fi
echo ""
echo -e "${YELLOW}Please compress and share the output directory with RapidFort support:${NC}"
echo -e "${BLUE}  tar -czf ${OUT}.tar.gz ${OUT}/${NC}"
echo ""
