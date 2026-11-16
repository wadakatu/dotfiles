---
name: cloud-logging-query-generation
description: Cloud Logging のフィルタ（Logging Query Language）を書く・直すとき、Cloud Run などのログを gcloud logging read やログエクスプローラで調べるときに使う。監査ログで誰が何をしたかを探すときも含む。BigQuery などの SQL や Google Cloud 以外のログには使わない。
---

# Generate Logging Query Language queries

Use this skill to generate correct Logging Query Language (LQL) queries for
Cloud Logging.

Vendored from [google/skills](https://github.com/google/skills)
`skills/cloud/cloud-logging-query-generation` (version 1.0.2, commit
`a342dc55cc21bfc712c97a04a01b12c05648e92b`), Apache-2.0 — see `LICENSE` in this
directory. Modified from upstream: removed the usage-attribution section and
`references/attribution.md`, the `metadata` frontmatter, the Compute Engine and
load-balancer pitfalls, and every service reference except Cloud Run and audit
logs; rewrote the description, the rule for missing values (ask or look them
up; no output-only rule), the fallback for services without a reference file
and the SEARCH guidance (whole-token match; zero results are not proof of
absence); added "Running the query". `references/api_reference.md` and
`references/query_cloud_run.md` carry their own change notes;
`references/query_audit_logs.md` is unmodified.

## Core rules

1.  **Strict syntax requirements:**

    *   **Always use double quotes (`"`)** for string literals. Do not use
        single quotes (`'`).
    *   Write boolean operators in all capitals: `AND`, `OR`, `NOT`.
    *   Always use parentheses to group terms and explicitly enforce precedence.

2.  **Unknown identifiers:**

    *   Do not write a filter line for an identifier you do not have (project
        ID, service name, revision, IP address). A placeholder such as
        `"<PROJECT_ID>"` acts as a real filter and causes logs to be missed.
        Leave the line out, or get the value first (ask, or look it up with a
        read-only command). Only when the field is strictly required for the
        query to work, as with the project ID in
        `logName="projects/PROJECT_ID/logs/…"`, say which value is missing
        instead of guessing it.

3.  **Preferred fields:**

    *   Include `resource.type` and `log_id` restrictions when the query targets
        specific Google Cloud services or resources. Global queries (for
        example, "latest error logs") do not require these restrictions.
    *   On Cloud Run, when the cause is still unknown, do not restrict by
        `log_id`: platform events, such as why an instance started, are in the
        system log (`varlog/system`), not in `requests`, `stdout` or `stderr`.

## Detailed reference

Refer to `references/api_reference.md` for LQL syntax rules, including
Operators, NULL handling, SEARCH, and Regex.

## Service reference files

Before generating a query, you MUST read the examples for the specific service.
LQL schemas and `resource.type` values are service-specific. **Do not stop
reading after finding the Base Schema in the file. You must verify if there are
specific requirements for state tracking (like `previousState`) or
resource-specific log IDs detailed in the paragraphs or specific query examples
below the schema block.**

**For the following services, read the exact file listed:**

*   [Cloud Run](references/query_cloud_run.md)

**For other Google Cloud services:** this copy carries only the Cloud Run and
audit-log references. Look up the `resource.type` in the monitored resource
types catalog and an example in the query library (both under "Supporting
links"); if neither covers it, follow "Handling Unknown Schemas" below.

## Query generation rules

1.  **Resource Types:** Explicitly define the `resource.type` in your queries
    when focusing on specific services. For some queries, you may need to search
    across multiple types (for example, `resource.type=("bigquery_project" OR
    "bigquery_dataset")`).
2.  **Audit and Admin Logs:** If the user asks for audit logs, admin logs, API
    logs, or logs about who created, updated, deleted, read, or accessed a
    resource:
    *   You MUST read
        [references/query_audit_logs.md](references/query_audit_logs.md) for the
        correct `protoPayload` schema paths and common examples.
    *   If a specific example is not listed, guess the `protoPayload.methodName`
        by combining the service and verb. When guessing, use the scoped
        `SEARCH()` function with the full dotted name (e.g.,
        `SEARCH(protoPayload.methodName, "compute.instances.insert")`) instead
        of the exact match operator (`=`) to avoid version prefix mismatches.
        `SEARCH` matches whole tokens, not substrings, so a partial name can
        return nothing; if it does, fall back to the colon operator (`:`) and
        read the returned `methodName` values.
    *   For generic API enable/disable events (e.g., a service was disabled),
        always use `resource.type="audited_resource"`.
3.  **Handling Unknown Schemas (Crucial):** If the user asks to filter by a
    specific field or condition, and if you cannot find a matching example or
    schema in the reference files, **then you must generate a query using global
    search.**
    *   Only specify `jsonPayload.*` or `protoPayload.*` field structures when
        you are certain of their exact name.
    *   Use the `SEARCH()` function to find the keyword globally within the
        correct `resource.type`.
    *   A `SEARCH` that returns nothing does not show the logs are absent: it
        matches whole tokens, not substrings. Before saying so, retry the
        keyword as a quoted global restriction (`"keyword"`, a substring match
        over all fields) inside the same `resource.type` and time range.
    *   **Say so:** When a query uses `SEARCH` because the exact schema was not
        in the references, say that next to the query (an LQL `--` comment at
        the top of the query is fine), so the reader knows the field names were
        not verified.

## Running the query

These apply when you run the filter yourself with `gcloud logging read`, and
they are the usual reasons a correct filter returns nothing.

*   **Time range:** without a `timestamp` restriction, `gcloud logging read`
    returns only the last day (`--freshness`, default `1d`). Set the range
    explicitly.
*   **Shell quoting:** LQL strings use double quotes, so wrap the whole filter
    in single quotes on the command line.
*   **Scope:** logs of a folder or organization are read with `--folder` or
    `--organization`, not by changing `resource.type` alone.
*   **Data Access audit logs** are disabled by default except for BigQuery. An
    empty result for "who read X" may mean they are not being written.
*   **Before reporting that there are no such logs:** drop the narrowest
    restriction and confirm the broader filter returns at least one entry for
    the same range and scope, then state the filter, range and scope you
    checked.
*   **Personal data:** audit-log entries carry `principalEmail` and `callerIp`.
    In production, print only the fields you need with `--format`, or answer
    with counts.

## Supporting links

*   [Cloud Logging query language documentation](https://docs.cloud.google.com/logging/docs/view/logging-query-language)
*   [Monitored resource types catalog](https://docs.cloud.google.com/logging/docs/api/v2/resource-list)
*   [Cloud Logging query library](https://docs.cloud.google.com/logging/docs/view/query-library)
