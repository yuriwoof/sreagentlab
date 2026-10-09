# SRE Agent Lab Operating Baseline

> Search results may vary by query language and by the state of documents, indexes, permissions, and services. Verify the actual search results for English queries.
> Search keywords: prohibited actions, recovery verification, escalation conditions, first recovery action, IIS stop, CPU spike, memory pressure, NSG misconfiguration, disk IO pressure, probe failure.

| Item | Value |
|---|---|
| Scope | Dedicated resource group for the SRE Agent Lab |
| Purpose | Non-production incident response exercises using Azure SRE Agent and Chaos Studio |
| Owner | Hands-on lab participant |
| Last verified | To be completed by the participant at upload time |
| Review triggers | Changes to the lab configuration, alerts, recovery scripts, or SRE Agent configuration |

## Target Architecture

- Place Windows Server 2022 IIS VMs in the Application Gateway backend pool.
- Do not create public IP addresses for the VMs by default.
- Use Azure VM Run Command for routine VM administration.
- Use Azure Monitor metrics, the `Perf` and `Event` tables in Log Analytics, and Azure Monitor alerts for investigations.
- `AzureActivity` includes only operations performed after optional Activity Log forwarding has been enabled.
- Retrieve cost data from Cost Management. Do not estimate costs from `AzureActivity`.

## Investigation Boundaries

1. State the target resources, time range, retrieval time, and data sources.
2. Do not treat unavailable values as zero or healthy.
3. Separate verified facts, potential causes, and unverified items.
4. Compare affected and healthy VMs over the same time range.
5. Check the status and start time of Chaos experiments.
6. In Review mode, do not make changes. Present the target, proposed changes, impact, least-privilege requirements, rollback plan, and recovery criteria, then wait for approval.

## First Recovery Action by Symptom

| Symptom | First checks | First recovery candidate |
|---|---|---|
| CPU spike | CPU usage across all VMs, Application Gateway healthy host count, and Chaos experiment status | Stop the CPU experiment |
| Memory pressure | `Available Bytes`, `% Committed Bytes In Use`, and ingestion time | Stop the memory experiment |
| IIS stopped | W3SVC events, Application Gateway backend health, and IIS experiment status | Stop the IIS experiment. If the service does not recover after the experiment stops, start it with approval |
| NSG misconfiguration | Priority of `ManualDenyAppGatewayHTTP` relative to the valid allow rule | Delete only the manually added deny rule |
| Disk IO pressure | IOPS utilization, queue depth, and disk IO experiment status | Stop the disk IO experiment |
| Application Gateway probe failure | IIS `/health.htm` endpoint and the probe path | Revert only the known misconfiguration from `/healthz` to `/health.htm` |

## Prohibited Actions

- Do not change multiple configuration items at the same time.
- Do not restart, resize, or recreate a VM without evidence of the cause.
- Do not shrink a disk or recreate it destructively.
- Do not grant the SRE Agent the Owner or Contributor role at subscription scope.
- Do not change any NSG rule other than `ManualDenyAppGatewayHTTP` as part of incident recovery.
- Do not change the Application Gateway backend, port, or NSG while recovering a probe.
- Do not rely on prompt instructions as a substitute for RBAC or tool access policies.

## Recovery Verification

After making a change or stopping an experiment, verify the following:

1. The relevant Chaos experiment has ended.
2. All Application Gateway backends are Healthy.
3. HTTP requests through Application Gateway return status code 200.
4. The relevant metrics or guest state have returned to normal.
5. The Azure Monitor alert has cleared.
6. The operator, approver, change details, time, result, and unverified items have been recorded.

## Escalation Conditions

- The target resource or owner cannot be identified.
- Required evidence cannot be obtained because of insufficient permissions or missing data.
- A configuration difference does not match a known fault injection.
- The recovery operation would affect resources outside the lab's dedicated resource group.
- A rollback procedure or recovery verification criteria cannot be defined.
- The symptom persists after the experiment stops.
