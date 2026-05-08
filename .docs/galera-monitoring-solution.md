# Galera Cluster Health Monitoring and Auto-Healing

This enhanced solution provides robust monitoring, detection, and auto-healing for MariaDB Galera cluster split-brain scenarios in OpenShift environments.

## Overview

The solution consists of three main components:

1. **Enhanced Galera Utilities** (`_utils.sh`) - Core functions for health checking and auto-healing
2. **Improved Pod Log Checker** (`check-pod-logs.sh`) - Main monitoring script with Galera integration
3. **Log Aggregator** (`log-aggregator.sh`) - Persistent logging and alerting without PVC requirements

## Key Features

### 🎯 Robust Split-Brain Detection
- Uses selector-based StatefulSet discovery
- Leverages existing utility functions (`check_galera_pod_ready`, `get_mariadb_env_vars`)
- Comprehensive cluster state analysis (UUID, size, node states)
- Structured logging for troubleshooting

### 🔄 Intelligent Auto-Healing
- Graceful StatefulSet scaling (down to 0, then back to original size)
- Uses existing `wait_for_galera_sync` for verification
- Proper error handling and rollback strategies
- Cooldown prevention for repeated attempts

### 📊 Enhanced Logging and Alerting
- Structured critical event logging (`CRITICAL_EVENT|timestamp|namespace|type|message`)
- OpenShift Events integration (visible in `oc get events`)
- Optional webhook notifications (Rocket.Chat, Slack)
- Log aggregation without requiring PVC storage

## Industry Best Practices Implemented

### ✅ Separation of Concerns
- Galera functions moved to `_utils.sh` for reusability
- Main script focuses on orchestration
- Log aggregator handles persistence and notifications separately

### ✅ Fail-Safe Design
- Multiple validation checks before auto-heal
- Graceful degradation when components are unavailable
- Non-blocking error handling for external services

### ✅ Observability
- Comprehensive logging at each decision point
- Structured event format for automated analysis
- Integration with OpenShift native monitoring

### ✅ Configuration-Driven
- Environment variables for all tunable parameters
- Optional webhook configurations
- Configurable timeouts and retry limits

## Function Reference

### New Utility Functions in `_utils.sh`

#### `log_critical_event(event_type, message, namespace)`
Logs structured critical events for aggregation and alerting.
```bash
log_critical_event "GALERA_SPLIT_BRAIN_DETECTED" "Split-brain in cluster" "$DEPLOY_NAMESPACE"
```

#### `find_statefulset_by_selector(selector, namespace)`
Finds StatefulSet name using label selector instead of pod name parsing.
```bash
sts_name=$(find_statefulset_by_selector "app.kubernetes.io/name=mariadb-galera" "$DEPLOY_NAMESPACE")
```

#### `check_galera_pod_ready(pod_name, namespace)`
Individual pod health check. A pod is healthy if `wsrep_local_state_comment=Synced` and `wsrep_cluster_status=Primary`. Cluster size is **not** validated here — a node can be individually healthy even when another node is disconnected (size < expected). Cluster-wide size convergence is verified separately by `wait_for_galera_sync`.

#### `check_galera_cluster_health(selector, namespace, expected_size)`
Comprehensive cluster-level health check with split-brain detection.
- Return codes: 0=healthy, 1=some unhealthy, 2=split-brain (multiple UUIDs)

#### `auto_heal_galera_cluster(selector, namespace)`
Performs StatefulSet scaling auto-heal with proper verification.

#### `wait_for_galera_sync(galera_name, max_retries, wait_time, expected_pods)`
Waits for all pods to reach Synced/Primary state with matching cluster_size.
Includes **IST failure auto-recovery**: after 3 retries, detects pods stuck in
`Initialized/Disconnected` state (common after IST write set gaps) and
auto-deletes them for a clean SST rejoin.

#### `check_and_heal_galera_cluster(selector, namespace, expected_size, auto_heal)`
Combined function that checks health and optionally performs auto-heal.

## Webhook Notifications

The solution integrates with your existing GitHub webhook configuration and provides rich notifications with emoji indicators for different event types:

### Emoji System
- 🚨 `:boom:` - Critical failures (split-brain, auto-heal failures)
- ⚠️ `:warning:` - Warnings (pod restarts, unhealthy pods)
- 🔧 `:wrench:` - Auto-healing events (repair attempts)
- ✅ `:white_check_mark:` - Success events (successful auto-heal)
- 🩺 `:stethoscope:` - Health monitoring events
- ℹ️ `:information_source:` - Informational events

### Webhook Security
The solution reuses your existing `secrets.ROCKETCHAT_WEBHOOK_URL` from GitHub:
```yaml
env:
- name: ROCKET_CHAT_WEBHOOK
  valueFrom:
    secretKeyRef:
      name: notification-webhooks
      key: rocketchat-webhook-url
```

This ensures:
- Single source of truth for webhook URLs
- Automatic updates when GitHub secrets change
- Consistent security practices
- No duplicate token management

## Deployment Integration

### GitHub Workflow Integration

The monitoring system is fully integrated into the deployment workflow:

```yaml
# Automated deployment in deploy.yml
- name: Deploy Pod Health Monitor
  run: bash ./openshift/scripts/deploy-health-monitor.sh
  env:
    ROCKETCHAT_WEBHOOK_URL: ${{ secrets.ROCKETCHAT_WEBHOOK_URL }}
    DEPLOYMENT_TYPE: "continuous"
```

**Benefits:**

- **Webhook Sync**: GitHub secrets automatically sync to OpenShift secrets
- **Deployment Lifecycle**: Monitoring scales down during deployments, resumes after
- **ConfigMap Management**: Scripts managed via `create_or_update_configmap` utilities
- **Consistency**: All infrastructure components deployed through single workflow

### Secret Management

Webhook URLs are automatically synchronized:

1. Update `ROCKETCHAT_WEBHOOK_URL` in GitHub repository secrets
2. Next deployment automatically updates OpenShift secret
3. Monitoring deployment picks up new webhook URL
4. No manual intervention required

### Deployment Options

**Continuous Monitoring (Recommended)**:

```bash
DEPLOYMENT_TYPE=continuous ./openshift/scripts/deploy-health-monitor.sh
```

- 60-second monitoring intervals
- Resource-efficient (25m CPU, 128Mi memory)
- Immediate issue detection

**CronJob Fallback**:

```bash
DEPLOYMENT_TYPE=cronjob ./openshift/scripts/deploy-health-monitor.sh
```

- 5-minute intervals
- Lower resource usage
- Traditional approach

**Use Cases:**
- Lower resource environments
- Fallback option
- Testing and development

## Logging Without PVC

The solution provides several logging strategies that don't require persistent storage:

### 1. OpenShift Events
Critical events are automatically logged as OpenShift Events:
```bash
oc get events --field-selector reason=GALERA_SPLIT_BRAIN_DETECTED
```

### 2. Structured Log Output
All logs use a structured format that can be captured by log aggregation systems:
```
CRITICAL_EVENT|2024-08-22 15:30:00 UTC|moodle-prod|GALERA_SPLIT_BRAIN_DETECTED|Split-brain detected! UUIDs: 2, Sizes: 2
```

### 3. External Webhooks
Real-time notifications to external systems (Rocket.Chat, Slack, etc.)

### 4. Log Aggregator Service
Optional lightweight service that follows CronJob logs and forwards critical events.

## Potential Issues and Mitigations

### Issue: Repeated Auto-Heal Attempts
**Mitigation**: The solution logs all attempts and could be enhanced with a cooldown mechanism:
```bash
# Add to _utils.sh if needed
LAST_HEAL_FILE="/tmp/last_galera_heal"
COOLDOWN_MINUTES=15
```

### Issue: Network Partitions During Heal
**Mitigation**: The solution waits for proper sync verification using `wait_for_galera_sync`.

### Issue: Resource Starvation
**Mitigation**: Log aggregator has minimal resource requirements (50m CPU, 64Mi RAM).

### Issue: Webhook Reliability
**Mitigation**: All webhook calls are non-blocking and have fallback to OpenShift Events.

## Configuration Examples

### Environment Variables for CronJob
```yaml
env:
- name: USE_LOG_AGGREGATOR
  value: "true"
- name: ROCKET_CHAT_WEBHOOK
  valueFrom:
    secretKeyRef:
      name: notification-secrets
      key: rocket-chat-webhook
```

### Webhook Payloads
The solution sends formatted messages:
```json
{
  "text": "🚨 **GALERA_SPLIT_BRAIN_DETECTED** in `moodle-prod`\n⏰ 2024-08-22 15:30:00 UTC\n📝 Split-brain detected! UUIDs: 2, Sizes: 2"
}
```

## Testing and Validation

### Test Split-Brain Detection
```bash
# Simulate split-brain by scaling down some pods manually
oc scale statefulset mariadb-galera --replicas=3
# Wait for detection
oc logs -f job/check-pod-logs-<timestamp>
```

### Test Auto-Heal
```bash
# Verify auto-heal functionality
oc get events --field-selector reason=GALERA_AUTO_HEAL_SUCCESS
```

### Test Log Aggregation
```bash
# Follow aggregated logs
oc logs -f deployment/galera-log-aggregator
```

## Monitoring and Alerting

### OpenShift Events
```bash
# Monitor all Galera events
oc get events --field-selector component=galera-monitor -w

# Check recent split-brain events
oc get events --field-selector reason=GALERA_SPLIT_BRAIN_DETECTED --sort-by=.firstTimestamp
```

### Log Queries
```bash
# Search for critical events in pod logs
oc logs job/check-pod-logs-<timestamp> | grep "CRITICAL_EVENT"

# Get summary of events
oc logs job/check-pod-logs-<timestamp> | grep "GALERA_" | sort | uniq -c
```

This solution provides enterprise-grade monitoring and auto-healing for Galera clusters while maintaining simplicity and avoiding PVC requirements. The structured approach ensures maintainability and extensibility for future enhancements.
