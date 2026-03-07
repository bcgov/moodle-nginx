# Emergency Recovery: Restoring Production After a Failed Deployment

## What the deployment does to production (in order)

1. Deploys a maintenance page and patches all routes to point at `maintenance-message` instead of `web` — this is what takes the site down for users
2. Scales `php` to 0 replicas
3. Scales `web` to 0 replicas
4. Deletes and recreates configmaps, cron jobs, and runs upgrade jobs (`moodle-upgrade`, `migrate-build-files`)

If the workflow fails mid-way through, you're left with routes pointing at maintenance, application pods scaled to zero, and possibly half-finished jobs.

## Recovery steps (restoring pre-deploy state)

### 1. Log in

```bash
oc login --token=<your-token> --server=https://api.silver.devops.gov.bc.ca:6443
oc project 950003-prod
```

### 2. Check current state

```bash
oc get routes -o custom-columns=NAME:.metadata.name,SERVICE:.spec.to.name
oc get deployments
oc get pods
```

### 3. Scale the app pods back up

These were set to 0 by the deploy. Production runs 3 of each (per `950003-prod-sizing.csv`). PHP also has an HPA that scales up to 10.

```bash
oc scale deployment/php --replicas=3
oc scale deployment/web --replicas=3
```

### 4. Point routes back to the web service

They were patched to `maintenance-message` by the deploy.

```bash
oc patch route moodle-web -p '{"spec":{"to":{"name":"web"}}}'
oc patch route moodle-custom -p '{"spec":{"to":{"name":"web"}}}'
```

### 5. Scale down the maintenance page

```bash
oc scale deployment/maintenance-message --replicas=0
```

### 6. Clean up any incomplete jobs the deploy left behind

```bash
oc delete job moodle-upgrade --ignore-not-found
oc delete job migrate-build-files --ignore-not-found
```

### 7. If pods are stuck on PVC attach errors

```bash
# Find stuck pods
oc get pods | grep -E "Pending|ContainerCreating"

# Confirm it's a PVC issue
oc describe pod <stuck-pod-name>

# Force-delete so they reschedule on a healthy node
oc delete pod <stuck-pod-name> --grace-period=0 --force
```

## Notes

- Steps 3 and 4 are the critical ones — everything else is cleanup.
- The images and database haven't changed. Builds produce new images but the old image tags still exist in Artifactory, so scaling the existing deployments back up restores exactly what was running before.
