-- The Python Jinja string variable subsitutions aws_where_clause and ocp_where_clause
-- optionally filter AWS and OCP data by provider/source
-- Ex aws_where_clause: 'AND cost_entry_bill_id IN (1, 2, 3)'
-- Ex ocp_where_clause: "AND cluster_id = 'abcd-1234`"
CREATE TABLE matched_tags_{{uuid | sqlsafe}} AS (
    WITH cte_unnested_aws_tags AS (
        SELECT tags.*,
            b.billing_period_start
        FROM (
            SELECT key,
                value,
                cost_entry_bill_id
            FROM postgres.{{schema | sqlsafe}}.reporting_awstags_summary AS ts
            CROSS JOIN UNNEST("values") AS v(value)
        ) AS tags
        JOIN postgres.{{schema | sqlsafe}}.reporting_awscostentrybill AS b
            ON tags.cost_entry_bill_id = b.id
        {% if bill_ids %}
        WHERE b.id IN (
            {%- for bill_id in bill_ids -%}
            {{bill_id}}{% if not loop.last %},{% endif %}
            {%- endfor -%}
        )
        {% endif %}
    ),
    cte_unnested_ocp_pod_tags AS (
        SELECT tags.*,
            rp.report_period_start,
            rp.cluster_id,
            rp.cluster_alias
        FROM (
            SELECT key,
                value,
                report_period_id
            FROM postgres.{{schema | sqlsafe}}.reporting_ocpusagepodlabel_summary AS ts
            CROSS JOIN UNNEST("values") AS v(value)
        ) AS tags
        JOIN postgres.{{schema | sqlsafe}}.reporting_ocpusagereportperiod AS rp
            ON tags.report_period_id = rp.id
        -- Filter out tags that aren't enabled
        JOIN postgres.{{schema | sqlsafe}}.reporting_ocpenabledtagkeys as enabled_tags
            ON lower(enabled_tags.key) = lower(tags.key)
        {% if cluster_id %}
        WHERE rp.cluster_id = {{cluster_id}}
        {% endif %}
    ),
    cte_unnested_ocp_volume_tags AS (
        SELECT tags.*,
            rp.report_period_start,
            rp.cluster_id,
            rp.cluster_alias
        FROM (
            SELECT key,
                value,
                report_period_id
            FROM postgres.{{schema | sqlsafe}}.reporting_ocpstoragevolumelabel_summary AS ts
            CROSS JOIN UNNEST("values") AS v(value)
        ) AS tags
        JOIN postgres.{{schema | sqlsafe}}.reporting_ocpusagereportperiod AS rp
            ON tags.report_period_id = rp.id
        -- Filter out tags that aren't enabled
        JOIN postgres.{{schema | sqlsafe}}.reporting_ocpenabledtagkeys as enabled_tags
            ON lower(enabled_tags.key) = lower(tags.key)
        {% if cluster_id %}
        WHERE rp.cluster_id = {{cluster_id}}
        {% endif %}
    )
    SELECT '{"' || key || '": "' || value || '"}' as tag,
        key,
        value,
        cost_entry_bill_id,
        report_period_id
    FROM (
        SELECT aws.key,
            aws.value,
            aws.cost_entry_bill_id,
            ocp.report_period_id
        FROM cte_unnested_aws_tags AS aws
        JOIN cte_unnested_ocp_pod_tags AS ocp
            ON lower(aws.key) = lower(ocp.key)
                AND lower(aws.value) = lower(ocp.value)
                AND aws.billing_period_start = ocp.report_period_start

        UNION

        SELECT aws.key,
            aws.value,
            aws.cost_entry_bill_id,
            ocp.report_period_id
        FROM cte_unnested_aws_tags AS aws
        JOIN cte_unnested_ocp_volume_tags AS ocp
            ON lower(aws.key) = lower(ocp.key)
                AND lower(aws.value) = lower(ocp.value)
                AND aws.billing_period_start = ocp.report_period_start
    ) AS matches
)
;

CREATE TABLE reporting_aws_tags_{{uuid | sqlsafe}} AS (
    SELECT aws.*
    FROM (
        SELECT INTEGER '{{bill_id | sqlsafe}}' as cost_entry_bill_id,
            aws.lineitem_resourceid as resource_id,
            aws.lineitem_usagestartdate as usage_start,
            aws.lineitem_usageenddate as usage_end,
            aws.lineitem_productcode as product_code,
            aws.product_productfamily as product_family,
            aws.product_instancetype as instance_type,
            aws.lineitem_usageaccountid as usage_account_id,
            aws.lineitem_availabilityzone as availability_zone,
            aws.product_region as region,
            aws.pricing_unit as unit,
            aws.lineitem_usageamount as usage_amount,
            aws.lineitem_normalizedusageamount as normalized_usage_amount,
            aws.lineitem_currencycode as currency_code,
            aws.lineitem_unblendedcost as unblended_cost,
            lower(resourcetags) as lower_tags,
            row_number() OVER (PARTITION BY aws.identity_lineitemid ORDER BY aws.identity_lineitemid) as row_number
            FROM hive.{{schema | sqlsafe}}.aws_line_items as aws
            JOIN matched_tags_{{uuid | sqlsafe}} as tag
                ON json_extract_scalar(aws.resourcetags, '$.' || tag.key) = tag.value
            WHERE aws.source = '{{source_uuid | sqlsafe}}'
                AND aws.year = '{{year | sqlsafe}}'
                AND aws.month = '{{month | sqlsafe}}'
                AND date(aws.lineitem_usagestartdate) >= date('{{start_date | sqlsafe}}')
                AND date(aws.lineitem_usagestartdate) <= date('{{end_date | sqlsafe}}')
    ) AS aws
    WHERE aws.row_number = 1
)
;

CREATE TABLE reporting_aws_special_case_tags_{{uuid | sqlsafe}} AS (
    WITH cte_tag_options AS (
        SELECT '{"' || key || '": "' || value || '"}' as tag,
            lower(key) as key,
            lower(value) as value,
            cost_entry_bill_id
        FROM (
            SELECT key,
                value,
                ts.cost_entry_bill_id
            FROM postgres.{{schema | sqlsafe}}.reporting_awstags_summary AS ts
                CROSS JOIN UNNEST("values") AS v(value)
            --aws_where_clause
            {% if bill_ids %}
            WHERE ts.cost_entry_bill_id IN (
                {%- for bill_id in bill_ids -%}
                {{bill_id}}{% if not loop.last %},{% endif %}
                {%- endfor -%}
            )
            {% endif %}
        ) AS keyval
        WHERE lower(key) IN ('openshift_cluster', 'openshift_node', 'openshift_project')
    )
    SELECT aws.*
    FROM (
        SELECT INTEGER '{{bill_id | sqlsafe}}' as cost_entry_bill_id,
            aws.lineitem_resourceid as resource_id,
            aws.lineitem_usagestartdate as usage_start,
            aws.lineitem_usageenddate as usage_end,
            aws.lineitem_productcode as product_code,
            aws.product_productfamily as product_family,
            aws.product_instancetype as instance_type,
            aws.lineitem_usageaccountid as usage_account_id,
            aws.lineitem_availabilityzone as availability_zone,
            aws.product_region as region,
            aws.pricing_unit as unit,
            aws.lineitem_usageamount as usage_amount,
            aws.lineitem_normalizedusageamount as normalized_usage_amount,
            aws.lineitem_currencycode as currency_code,
            aws.lineitem_unblendedcost as unblended_cost,
            lower(resourcetags) as lower_tags,
            lower(tag.key) as key,
            lower(tag.value) as value,
            row_number() OVER (PARTITION BY aws.identity_lineitemid ORDER BY aws.identity_lineitemid) as row_number
        FROM hive.{{schema | sqlsafe}}.aws_line_items as aws
        JOIN cte_tag_options as tag
            ON json_extract_scalar(lower(aws.resourcetags), '$.' || tag.key) = tag.value
        WHERE aws.source = '{{source_uuid | sqlsafe}}'
            AND aws.year = '{{year | sqlsafe}}'
            AND aws.month = '{{month | sqlsafe}}'
            AND date(aws.lineitem_usagestartdate) >= date('{{start_date | sqlsafe}}')
            AND date(aws.lineitem_usagestartdate) <= date('{{end_date | sqlsafe}}')
    ) AS aws
    WHERE aws.row_number = 1
)
;

CREATE TABLE reporting_ocp_storage_tags_{{uuid | sqlsafe}} AS (
    WITH cte_node_labels AS (
        SELECT node_labels
    )
    SELECT ocp.*,
        lower(tag.key) as key,
        lower(tag.value) as value,
        lower(tag.tag) as tag
    FROM hive.{{schema | sqlsafe}}.openshift_storage_usage_line_items as ocp
    JOIN matched_tags_{{uuid | sqlsafe}} AS tag
        ON json_extract_scalar(ocp.persistentvolumeclaim_labels, '$.' || tag.key) = tag.value
    WHERE ocp.source = '{{source_uuid | sqlsafe}}'
        AND ocp.year = '{{year | sqlsafe}}'
        AND ocp.month = '{{month | sqlsafe}}'
        AND date(ocp.interval_start) >= date('{{start_date | sqlsafe}}')
        AND date(ocp.interval_start) <= date('{{end_date | sqlsafe}}')
)
;

CREATE TABLE reporting_ocp_pod_tags_{{uuid | sqlsafe}} AS (
    SELECT ocp.*,
        lower(tag.key) as key,
        lower(tag.value) as value,
        lower(tag.tag) as tag
    FROM hive.{{schema | sqlsafe}}.openshift_pod_usage_line_items as ocp
    JOIN matched_tags_{{uuid | sqlsafe}} AS tag
        ON ocp.report_period_id = tag.report_period_id
            AND strpos(ocp.pod_labels, tag.tag) != 0
            -- AND ocp.pod_labels @> tag.tag
    WHERE ocp.usage_start >= {{start_date}}::date
        AND ocp.usage_start <= {{end_date}}::date
        --ocp_where_clause
        {% if cluster_id %}
        AND cluster_id = {{cluster_id}}
        {% endif %}
)
;


-- no need to wait for commit
TRUNCATE TABLE matched_tags_{{uuid | sqlsafe}};
DROP TABLE matched_tags_{{uuid | sqlsafe}};


-- First we match OCP pod data to AWS data using a direct
-- resource id match. This usually means OCP node -> AWS EC2 instance ID.
CREATE TEMPORARY TABLE reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} AS (
    WITH cte_resource_id_matched AS (
        SELECT ocp.id AS ocp_id,
            ocp.report_period_id,
            ocp.cluster_id,
            ocp.cluster_alias,
            ocp.namespace,
            ocp.pod,
            ocp.node,
            ocp.pod_labels,
            ocp.pod_usage_cpu_core_seconds,
            ocp.pod_request_cpu_core_seconds,
            ocp.pod_limit_cpu_core_seconds,
            ocp.pod_usage_memory_byte_seconds,
            ocp.pod_request_memory_byte_seconds,
            ocp.node_capacity_cpu_cores,
            ocp.node_capacity_cpu_core_seconds,
            ocp.node_capacity_memory_bytes,
            ocp.node_capacity_memory_byte_seconds,
            ocp.cluster_capacity_cpu_core_seconds,
            ocp.cluster_capacity_memory_byte_seconds,
            aws.id AS aws_id,
            aws.cost_entry_bill_id,
            aws.cost_entry_product_id,
            aws.cost_entry_pricing_id,
            aws.cost_entry_reservation_id,
            aws.line_item_type,
            aws.usage_account_id,
            aws.usage_start,
            aws.usage_end,
            aws.product_code,
            aws.usage_type,
            aws.operation,
            aws.availability_zone,
            aws.resource_id,
            aws.usage_amount,
            aws.normalization_factor,
            aws.normalized_usage_amount,
            aws.currency_code,
            aws.unblended_rate,
            aws.unblended_cost,
            aws.blended_rate,
            aws.blended_cost,
            aws.public_on_demand_cost,
            aws.public_on_demand_rate,
            aws.tax_type,
            aws.tags
        FROM {{schema | sqlsafe}}.reporting_awscostentrylineitem_daily as aws
        JOIN {{schema | sqlsafe}}.reporting_ocpusagelineitem_daily as ocp
            ON aws.resource_id = ocp.resource_id
                AND aws.usage_start = ocp.usage_start
        WHERE aws.usage_start >= {{start_date}}::date
            AND aws.usage_start <= {{end_date}}::date
            -- aws_where_clause
            {% if bill_ids %}
            AND cost_entry_bill_id IN (
                {%- for bill_id in bill_ids -%}
                {{bill_id}}{% if not loop.last %},{% endif %}
                {%- endfor -%}
            )
            {% endif %}
            --ocp_where_clause
            {% if cluster_id %}
            AND cluster_id = {{cluster_id}}
            {% endif %}
    ),
    cte_number_of_shared AS (
        SELECT aws_id,
            count(DISTINCT namespace) as shared_projects,
            count(DISTINCT pod) as shared_pods
        FROM cte_resource_id_matched
        GROUP BY aws_id
    )
    SELECT rm.*,
        (rm.pod_usage_cpu_core_seconds / rm.node_capacity_cpu_core_seconds) * rm.unblended_cost as pod_cost,
        shared.shared_projects,
        shared.shared_pods
    FROM cte_resource_id_matched AS rm
    JOIN cte_number_of_shared AS shared
        ON rm.aws_id = shared.aws_id
)
;

-- Next we match where the AWS tag is the special openshift_project key
-- and the value matches an OpenShift project name
INSERT INTO reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} (
    WITH cte_tag_matched AS (
        SELECT ocp.id AS ocp_id,
            ocp.report_period_id,
            ocp.cluster_id,
            ocp.cluster_alias,
            ocp.namespace,
            ocp.pod,
            ocp.node,
            ocp.pod_labels,
            ocp.pod_usage_cpu_core_seconds,
            ocp.pod_request_cpu_core_seconds,
            ocp.pod_limit_cpu_core_seconds,
            ocp.pod_usage_memory_byte_seconds,
            ocp.pod_request_memory_byte_seconds,
            ocp.node_capacity_cpu_cores,
            ocp.node_capacity_cpu_core_seconds,
            ocp.node_capacity_memory_bytes,
            ocp.node_capacity_memory_byte_seconds,
            ocp.cluster_capacity_cpu_core_seconds,
            ocp.cluster_capacity_memory_byte_seconds,
            aws.id AS aws_id,
            aws.cost_entry_bill_id,
            aws.cost_entry_product_id,
            aws.cost_entry_pricing_id,
            aws.cost_entry_reservation_id,
            aws.line_item_type,
            aws.usage_account_id,
            aws.usage_start,
            aws.usage_end,
            aws.product_code,
            aws.usage_type,
            aws.operation,
            aws.availability_zone,
            aws.resource_id,
            aws.usage_amount,
            aws.normalization_factor,
            aws.normalized_usage_amount,
            aws.currency_code,
            aws.unblended_rate,
            aws.unblended_cost,
            aws.blended_rate,
            aws.blended_cost,
            aws.public_on_demand_cost,
            aws.public_on_demand_rate,
            aws.tax_type,
            aws.tags
        FROM reporting_aws_special_case_tags_{{uuid | sqlsafe}} as aws
        JOIN {{schema | sqlsafe}}.reporting_ocpusagelineitem_daily as ocp
            ON aws.key = 'openshift_project' AND aws.value = lower(ocp.namespace)
                AND aws.usage_start = ocp.usage_start
        -- ANTI JOIN to remove rows that already matched
        LEFT JOIN reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} AS rm
            ON rm.aws_id = aws.id
        WHERE aws.usage_start >= {{start_date}}::date
            AND aws.usage_start <= {{end_date}}::date
            AND rm.aws_id IS NULL
    ),
    cte_number_of_shared AS (
        SELECT aws_id,
            count(DISTINCT namespace) as shared_projects,
            count(DISTINCT pod) as shared_pods
        FROM cte_tag_matched
        GROUP BY aws_id
    )
    SELECT tm.*,
        tm.unblended_cost / shared.shared_pods as pod_cost,
        shared.shared_projects,
        shared.shared_pods
    FROM cte_tag_matched AS tm
    JOIN cte_number_of_shared AS shared
        ON tm.aws_id = shared.aws_id
)
;

-- Next we match where the AWS tag is the special openshift_node key
-- and the value matches an OpenShift node name
INSERT INTO reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} (
    WITH cte_tag_matched AS (
        SELECT ocp.id AS ocp_id,
            ocp.report_period_id,
            ocp.cluster_id,
            ocp.cluster_alias,
            ocp.namespace,
            ocp.pod,
            ocp.node,
            ocp.pod_labels,
            ocp.pod_usage_cpu_core_seconds,
            ocp.pod_request_cpu_core_seconds,
            ocp.pod_limit_cpu_core_seconds,
            ocp.pod_usage_memory_byte_seconds,
            ocp.pod_request_memory_byte_seconds,
            ocp.node_capacity_cpu_cores,
            ocp.node_capacity_cpu_core_seconds,
            ocp.node_capacity_memory_bytes,
            ocp.node_capacity_memory_byte_seconds,
            ocp.cluster_capacity_cpu_core_seconds,
            ocp.cluster_capacity_memory_byte_seconds,
            aws.id AS aws_id,
            aws.cost_entry_bill_id,
            aws.cost_entry_product_id,
            aws.cost_entry_pricing_id,
            aws.cost_entry_reservation_id,
            aws.line_item_type,
            aws.usage_account_id,
            aws.usage_start,
            aws.usage_end,
            aws.product_code,
            aws.usage_type,
            aws.operation,
            aws.availability_zone,
            aws.resource_id,
            aws.usage_amount,
            aws.normalization_factor,
            aws.normalized_usage_amount,
            aws.currency_code,
            aws.unblended_rate,
            aws.unblended_cost,
            aws.blended_rate,
            aws.blended_cost,
            aws.public_on_demand_cost,
            aws.public_on_demand_rate,
            aws.tax_type,
            aws.tags
        FROM reporting_aws_special_case_tags_{{uuid | sqlsafe}} as aws
        JOIN {{schema | sqlsafe}}.reporting_ocpusagelineitem_daily as ocp
            ON aws.key = 'openshift_node' AND aws.value = lower(ocp.node)
                AND aws.usage_start = ocp.usage_start
        -- ANTI JOIN to remove rows that already matched
        LEFT JOIN reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} AS rm
            ON rm.aws_id = aws.id
        WHERE aws.usage_start >= {{start_date}}::date
            AND aws.usage_start <= {{end_date}}::date
            AND rm.aws_id IS NULL
    ),
    cte_number_of_shared AS (
        SELECT aws_id,
            count(DISTINCT namespace) as shared_projects,
            count(DISTINCT pod) as shared_pods
        FROM cte_tag_matched
        GROUP BY aws_id
    )
    SELECT tm.*,
        tm.unblended_cost / shared.shared_pods as pod_cost,
        shared.shared_projects,
        shared.shared_pods
    FROM cte_tag_matched AS tm
    JOIN cte_number_of_shared AS shared
        ON tm.aws_id = shared.aws_id
)
;

-- Next we match where the AWS tag is the special openshift_cluster key
-- and the value matches an OpenShift cluster name
 INSERT INTO reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} (
    WITH cte_tag_matched AS (
        SELECT ocp.id AS ocp_id,
            ocp.report_period_id,
            ocp.cluster_id,
            ocp.cluster_alias,
            ocp.namespace,
            ocp.pod,
            ocp.node,
            ocp.pod_labels,
            ocp.pod_usage_cpu_core_seconds,
            ocp.pod_request_cpu_core_seconds,
            ocp.pod_limit_cpu_core_seconds,
            ocp.pod_usage_memory_byte_seconds,
            ocp.pod_request_memory_byte_seconds,
            ocp.node_capacity_cpu_cores,
            ocp.node_capacity_cpu_core_seconds,
            ocp.node_capacity_memory_bytes,
            ocp.node_capacity_memory_byte_seconds,
            ocp.cluster_capacity_cpu_core_seconds,
            ocp.cluster_capacity_memory_byte_seconds,
            aws.id AS aws_id,
            aws.cost_entry_bill_id,
            aws.cost_entry_product_id,
            aws.cost_entry_pricing_id,
            aws.cost_entry_reservation_id,
            aws.line_item_type,
            aws.usage_account_id,
            aws.usage_start,
            aws.usage_end,
            aws.product_code,
            aws.usage_type,
            aws.operation,
            aws.availability_zone,
            aws.resource_id,
            aws.usage_amount,
            aws.normalization_factor,
            aws.normalized_usage_amount,
            aws.currency_code,
            aws.unblended_rate,
            aws.unblended_cost,
            aws.blended_rate,
            aws.blended_cost,
            aws.public_on_demand_cost,
            aws.public_on_demand_rate,
            aws.tax_type,
            aws.tags
        FROM reporting_aws_special_case_tags_{{uuid | sqlsafe}} as aws
        JOIN {{schema | sqlsafe}}.reporting_ocpusagelineitem_daily as ocp
            ON (aws.key = 'openshift_cluster' AND aws.value = lower(ocp.cluster_id)
                OR aws.key = 'openshift_cluster' AND aws.value = lower(ocp.cluster_alias))
                AND aws.usage_start = ocp.usage_start
        -- ANTI JOIN to remove rows that already matched
        LEFT JOIN reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} AS rm
            ON rm.aws_id = aws.id
        WHERE aws.usage_start >= {{start_date}}::date
            AND aws.usage_start <= {{end_date}}::date
            AND rm.aws_id IS NULL
    ),
    cte_number_of_shared AS (
        SELECT aws_id,
            count(DISTINCT namespace) as shared_projects,
            count(DISTINCT pod) as shared_pods
        FROM cte_tag_matched
        GROUP BY aws_id
    )
    SELECT tm.*,
        tm.unblended_cost / shared.shared_pods as pod_cost,
        shared.shared_projects,
        shared.shared_pods
    FROM cte_tag_matched AS tm
    JOIN cte_number_of_shared AS shared
        ON tm.aws_id = shared.aws_id
)
;

-- Next we match where the pod label key and value
-- and AWS tag key and value match directly
 INSERT INTO reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} (
    WITH cte_tag_matched AS (
        SELECT ocp.id AS ocp_id,
            ocp.report_period_id,
            ocp.cluster_id,
            ocp.cluster_alias,
            ocp.namespace,
            ocp.pod,
            ocp.node,
            ocp.pod_labels,
            ocp.pod_usage_cpu_core_seconds,
            ocp.pod_request_cpu_core_seconds,
            ocp.pod_limit_cpu_core_seconds,
            ocp.pod_usage_memory_byte_seconds,
            ocp.pod_request_memory_byte_seconds,
            ocp.node_capacity_cpu_cores,
            ocp.node_capacity_cpu_core_seconds,
            ocp.node_capacity_memory_bytes,
            ocp.node_capacity_memory_byte_seconds,
            ocp.cluster_capacity_cpu_core_seconds,
            ocp.cluster_capacity_memory_byte_seconds,
            aws.id AS aws_id,
            aws.cost_entry_bill_id,
            aws.cost_entry_product_id,
            aws.cost_entry_pricing_id,
            aws.cost_entry_reservation_id,
            aws.line_item_type,
            aws.usage_account_id,
            aws.usage_start,
            aws.usage_end,
            aws.product_code,
            aws.usage_type,
            aws.operation,
            aws.availability_zone,
            aws.resource_id,
            aws.usage_amount,
            aws.normalization_factor,
            aws.normalized_usage_amount,
            aws.currency_code,
            aws.unblended_rate,
            aws.unblended_cost,
            aws.blended_rate,
            aws.blended_cost,
            aws.public_on_demand_cost,
            aws.public_on_demand_rate,
            aws.tax_type,
            aws.tags
        FROM reporting_aws_tags_{{uuid | sqlsafe}} as aws
        JOIN reporting_ocp_pod_tags_{{uuid | sqlsafe}} as ocp
            ON aws.usage_start = ocp.usage_start
                AND strpos(aws.lower_tags, ocp.tag) != 0
            -- ON aws.lower_tags @> ocp.tag
        -- ANTI JOIN to remove rows that already matched
        LEFT JOIN reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} AS rm
            ON rm.aws_id = aws.id
        WHERE aws.usage_start >= {{start_date}}::date
            AND aws.usage_start <= {{end_date}}::date
            AND rm.aws_id IS NULL
    ),
    cte_number_of_shared AS (
        SELECT aws_id,
            count(DISTINCT namespace) as shared_projects,
            count(DISTINCT pod) as shared_pods
        FROM cte_tag_matched
        GROUP BY aws_id
    )
    SELECT tm.*,
        tm.unblended_cost / shared.shared_pods as pod_cost,
        shared.shared_projects,
        shared.shared_pods
    FROM cte_tag_matched AS tm
    JOIN cte_number_of_shared AS shared
        ON tm.aws_id = shared.aws_id
)
;

-- no need to wait for commit
TRUNCATE TABLE reporting_ocp_pod_tags_{{uuid | sqlsafe}};
DROP TABLE reporting_ocp_pod_tags_{{uuid | sqlsafe}};


-- First we match where the AWS tag is the special openshift_project key
-- and the value matches an OpenShift project name
CREATE TEMPORARY TABLE reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} AS (
    WITH cte_tag_matched AS (
        SELECT ocp.id AS ocp_id,
            ocp.report_period_id,
            ocp.cluster_id,
            ocp.cluster_alias,
            ocp.namespace,
            ocp.pod,
            ocp.node,
            ocp.persistentvolumeclaim,
            ocp.persistentvolume,
            ocp.storageclass,
            ocp.persistentvolumeclaim_capacity_bytes,
            ocp.persistentvolumeclaim_capacity_byte_seconds,
            ocp.volume_request_storage_byte_seconds,
            ocp.persistentvolumeclaim_usage_byte_seconds,
            ocp.persistentvolume_labels,
            ocp.persistentvolumeclaim_labels,
            aws.id AS aws_id,
            aws.cost_entry_bill_id,
            aws.cost_entry_product_id,
            aws.cost_entry_pricing_id,
            aws.cost_entry_reservation_id,
            aws.line_item_type,
            aws.usage_account_id,
            aws.usage_start,
            aws.usage_end,
            aws.product_code,
            aws.usage_type,
            aws.operation,
            aws.availability_zone,
            aws.resource_id,
            aws.usage_amount,
            aws.normalization_factor,
            aws.normalized_usage_amount,
            aws.currency_code,
            aws.unblended_rate,
            aws.unblended_cost,
            aws.blended_rate,
            aws.blended_cost,
            aws.public_on_demand_cost,
            aws.public_on_demand_rate,
            aws.tax_type,
            aws.tags
        FROM reporting_aws_special_case_tags_{{uuid | sqlsafe}} as aws
        JOIN {{schema | sqlsafe}}.reporting_ocpstoragelineitem_daily as ocp
            ON aws.key = 'openshift_project' AND aws.value = lower(ocp.namespace)
                AND aws.usage_start = ocp.usage_start
        WHERE aws.usage_start >= {{start_date}}::date
            AND aws.usage_start <= {{end_date}}::date

    ),
    cte_number_of_shared AS (
        SELECT aws_id,
            count(DISTINCT namespace) as shared_projects,
            count(DISTINCT pod) as shared_pods
        FROM cte_tag_matched
        GROUP BY aws_id
    )
    SELECT tm.*,
        tm.unblended_cost / shared.shared_pods as pod_cost,
        shared.shared_projects,
        shared.shared_pods
    FROM cte_tag_matched AS tm
    JOIN cte_number_of_shared AS shared
        ON tm.aws_id = shared.aws_id
)
;

-- Next we match where the AWS tag is the special openshift_node key
-- and the value matches an OpenShift node name
INSERT INTO reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} (
    WITH cte_tag_matched AS (
        SELECT ocp.id AS ocp_id,
            ocp.report_period_id,
            ocp.cluster_id,
            ocp.cluster_alias,
            ocp.namespace,
            ocp.pod,
            ocp.node,
            ocp.persistentvolumeclaim,
            ocp.persistentvolume,
            ocp.storageclass,
            ocp.persistentvolumeclaim_capacity_bytes,
            ocp.persistentvolumeclaim_capacity_byte_seconds,
            ocp.volume_request_storage_byte_seconds,
            ocp.persistentvolumeclaim_usage_byte_seconds,
            ocp.persistentvolume_labels,
            ocp.persistentvolumeclaim_labels,
            aws.id AS aws_id,
            aws.cost_entry_bill_id,
            aws.cost_entry_product_id,
            aws.cost_entry_pricing_id,
            aws.cost_entry_reservation_id,
            aws.line_item_type,
            aws.usage_account_id,
            aws.usage_start,
            aws.usage_end,
            aws.product_code,
            aws.usage_type,
            aws.operation,
            aws.availability_zone,
            aws.resource_id,
            aws.usage_amount,
            aws.normalization_factor,
            aws.normalized_usage_amount,
            aws.currency_code,
            aws.unblended_rate,
            aws.unblended_cost,
            aws.blended_rate,
            aws.blended_cost,
            aws.public_on_demand_cost,
            aws.public_on_demand_rate,
            aws.tax_type,
            aws.tags
        FROM reporting_aws_special_case_tags_{{uuid | sqlsafe}} as aws
        JOIN {{schema | sqlsafe}}.reporting_ocpstoragelineitem_daily as ocp
            ON aws.key = 'openshift_node' AND aws.value = lower(ocp.node)
                AND aws.usage_start = ocp.usage_start
        -- ANTI JOIN to remove rows that already matched
        LEFT JOIN reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} AS rm
            ON rm.aws_id = aws.id
        WHERE aws.usage_start >= {{start_date}}::date
            AND aws.usage_start <= {{end_date}}::date
            AND rm.aws_id IS NULL
    ),
    cte_number_of_shared AS (
        SELECT aws_id,
            count(DISTINCT namespace) as shared_projects,
            count(DISTINCT pod) as shared_pods
        FROM cte_tag_matched
        GROUP BY aws_id
    )
    SELECT tm.*,
        tm.unblended_cost / shared.shared_pods as pod_cost,
        shared.shared_projects,
        shared.shared_pods
    FROM cte_tag_matched AS tm
    JOIN cte_number_of_shared AS shared
        ON tm.aws_id = shared.aws_id
)
;

-- Next we match where the AWS tag is the special openshift_cluster key
-- and the value matches an OpenShift cluster name
 INSERT INTO reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} (
    WITH cte_tag_matched AS (
        SELECT ocp.id AS ocp_id,
            ocp.report_period_id,
            ocp.cluster_id,
            ocp.cluster_alias,
            ocp.namespace,
            ocp.pod,
            ocp.node,
            ocp.persistentvolumeclaim,
            ocp.persistentvolume,
            ocp.storageclass,
            ocp.persistentvolumeclaim_capacity_bytes,
            ocp.persistentvolumeclaim_capacity_byte_seconds,
            ocp.volume_request_storage_byte_seconds,
            ocp.persistentvolumeclaim_usage_byte_seconds,
            ocp.persistentvolume_labels,
            ocp.persistentvolumeclaim_labels,
            aws.id AS aws_id,
            aws.cost_entry_bill_id,
            aws.cost_entry_product_id,
            aws.cost_entry_pricing_id,
            aws.cost_entry_reservation_id,
            aws.line_item_type,
            aws.usage_account_id,
            aws.usage_start,
            aws.usage_end,
            aws.product_code,
            aws.usage_type,
            aws.operation,
            aws.availability_zone,
            aws.resource_id,
            aws.usage_amount,
            aws.normalization_factor,
            aws.normalized_usage_amount,
            aws.currency_code,
            aws.unblended_rate,
            aws.unblended_cost,
            aws.blended_rate,
            aws.blended_cost,
            aws.public_on_demand_cost,
            aws.public_on_demand_rate,
            aws.tax_type,
            aws.tags
        FROM reporting_aws_special_case_tags_{{uuid | sqlsafe}} as aws
        JOIN {{schema | sqlsafe}}.reporting_ocpstoragelineitem_daily as ocp
            ON (aws.key = 'openshift_cluster' AND aws.value = lower(ocp.cluster_id)
                OR aws.key = 'openshift_cluster' AND aws.value = lower(ocp.cluster_alias))
                AND aws.usage_start = ocp.usage_start
        -- ANTI JOIN to remove rows that already matched
        LEFT JOIN reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} AS rm
            ON rm.aws_id = aws.id
        WHERE aws.usage_start >= {{start_date}}::date
            AND aws.usage_start <= {{end_date}}::date
            AND rm.aws_id IS NULL
    ),
    cte_number_of_shared AS (
        SELECT aws_id,
            count(DISTINCT namespace) as shared_projects,
            count(DISTINCT pod) as shared_pods
        FROM cte_tag_matched
        GROUP BY aws_id
    )
    SELECT tm.*,
        tm.unblended_cost / shared.shared_pods as pod_cost,
        shared.shared_projects,
        shared.shared_pods
    FROM cte_tag_matched AS tm
    JOIN cte_number_of_shared AS shared
        ON tm.aws_id = shared.aws_id
)
;

-- no need to wait for commit
TRUNCATE TABLE reporting_aws_special_case_tags_{{uuid | sqlsafe}};
DROP TABLE reporting_aws_special_case_tags_{{uuid | sqlsafe}};


-- Then we match for OpenShift volume data where the volume label key and value
-- and AWS tag key and value match directly
 INSERT INTO reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} (
    WITH cte_tag_matched AS (
        SELECT ocp.id AS ocp_id,
            ocp.report_period_id,
            ocp.cluster_id,
            ocp.cluster_alias,
            ocp.namespace,
            ocp.pod,
            ocp.node,
            ocp.persistentvolumeclaim,
            ocp.persistentvolume,
            ocp.storageclass,
            ocp.persistentvolumeclaim_capacity_bytes,
            ocp.persistentvolumeclaim_capacity_byte_seconds,
            ocp.volume_request_storage_byte_seconds,
            ocp.persistentvolumeclaim_usage_byte_seconds,
            ocp.persistentvolume_labels,
            ocp.persistentvolumeclaim_labels,
            aws.id AS aws_id,
            aws.cost_entry_bill_id,
            aws.cost_entry_product_id,
            aws.cost_entry_pricing_id,
            aws.cost_entry_reservation_id,
            aws.line_item_type,
            aws.usage_account_id,
            aws.usage_start,
            aws.usage_end,
            aws.product_code,
            aws.usage_type,
            aws.operation,
            aws.availability_zone,
            aws.resource_id,
            aws.usage_amount,
            aws.normalization_factor,
            aws.normalized_usage_amount,
            aws.currency_code,
            aws.unblended_rate,
            aws.unblended_cost,
            aws.blended_rate,
            aws.blended_cost,
            aws.public_on_demand_cost,
            aws.public_on_demand_rate,
            aws.tax_type,
            aws.tags
        FROM reporting_aws_tags_{{uuid | sqlsafe}} as aws
        JOIN reporting_ocp_storage_tags_{{uuid | sqlsafe}} as ocp
            ON aws.usage_start = ocp.usage_start
                AND strpos(aws.lower_tags, ocp.tag) != 0
                -- ON aws.lower_tags @> ocp.tag
        -- ANTI JOIN to remove rows that already matched
        LEFT JOIN reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} AS rm
            ON rm.aws_id = aws.id
        WHERE aws.usage_start >= {{start_date}}::date
            AND aws.usage_start <= {{end_date}}::date
            AND rm.aws_id IS NULL
    ),
    cte_number_of_shared AS (
        SELECT aws_id,
            count(DISTINCT namespace) as shared_projects,
            count(DISTINCT pod) as shared_pods
        FROM cte_tag_matched
        GROUP BY aws_id
    )
    SELECT tm.*,
        tm.unblended_cost / shared.shared_pods as pod_cost,
        shared.shared_projects,
        shared.shared_pods
    FROM cte_tag_matched AS tm
    JOIN cte_number_of_shared AS shared
        ON tm.aws_id = shared.aws_id
)
;

-- no need to wait for commit
TRUNCATE TABLE reporting_ocp_storage_tags_{{uuid | sqlsafe}};
DROP TABLE reporting_ocp_storage_tags_{{uuid | sqlsafe}};

TRUNCATE TABLE reporting_aws_tags_{{uuid | sqlsafe}};
DROP TABLE reporting_aws_tags_{{uuid | sqlsafe}};


-- The full summary data for Openshift pod<->AWS and
-- Openshift volume<->AWS matches are UNIONed together
-- with a GROUP BY using the AWS ID to deduplicate
-- the AWS data. This should ensure that we never double count
-- AWS cost or usage.
CREATE TEMPORARY TABLE reporting_ocpawscostlineitem_daily_summary_{{uuid | sqlsafe}} AS (
    WITH cte_pod_project_cost AS (
        SELECT pc.aws_id,
            jsonb_object_agg(pc.namespace, pc.pod_cost) as project_costs
        FROM (
            SELECT li.aws_id,
                li.namespace,
                sum(pod_cost) as pod_cost
            FROM reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} as li
            GROUP BY li.aws_id, li.namespace
        ) AS pc
        GROUP BY pc.aws_id
    ),
    cte_storage_project_cost AS (
        SELECT pc.aws_id,
            jsonb_object_agg(pc.namespace, pc.pod_cost) as project_costs
        FROM (
            SELECT li.aws_id,
                li.namespace,
                sum(pod_cost) as pod_cost
            FROM reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} as li
            GROUP BY li.aws_id, li.namespace
        ) AS pc
        GROUP BY pc.aws_id
    )
    SELECT max(li.report_period_id) as report_period_id,
        max(li.cluster_id) as cluster_id,
        max(li.cluster_alias) as cluster_alias,
        array_agg(DISTINCT li.namespace) as namespace,
        array_agg(DISTINCT li.pod) as pod,
        max(li.node) as node,
        max(li.resource_id) as resource_id,
        max(li.usage_start) as usage_start,
        max(li.usage_end) as usage_end,
        max(li.product_code) as product_code,
        max(p.product_family) as product_family,
        max(p.instance_type) as instance_type,
        max(li.cost_entry_bill_id) as cost_entry_bill_id,
        max(li.usage_account_id) as usage_account_id,
        max(aa.id) as account_alias_id,
        max(li.availability_zone) as availability_zone,
        max(p.region) as region,
        max(pr.unit) as unit,
        li.tags,
        max(li.usage_amount) as usage_amount,
        max(li.normalized_usage_amount) as normalized_usage_amount,
        max(li.currency_code) as currency_code,
        max(li.unblended_cost) as unblended_cost,
        max(li.unblended_cost) * {{markup}}::numeric as markup_cost,
        max(li.shared_projects) as shared_projects,
        pc.project_costs as project_costs,
        ab.provider_id as source_uuid
    FROM reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} as li
    JOIN {{schema | sqlsafe}}.reporting_awscostentryproduct AS p
        ON li.cost_entry_product_id = p.id
    JOIN cte_pod_project_cost as pc
        ON li.aws_id = pc.aws_id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awscostentrypricing as pr
        ON li.cost_entry_pricing_id = pr.id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awsaccountalias AS aa
        ON li.usage_account_id = aa.account_id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awscostentrybill as ab
        ON li.cost_entry_bill_id = ab.id
    WHERE li.usage_start >= {{start_date}}::date
        AND li.usage_start <= {{end_date}}::date
    -- Dedup on AWS line item so we never double count usage or cost
    GROUP BY li.aws_id, li.tags, pc.project_costs, ab.provider_id

    UNION

    SELECT max(li.report_period_id) as report_period_id,
        max(li.cluster_id) as cluster_id,
        max(li.cluster_alias) as cluster_alias,
        array_agg(DISTINCT li.namespace) as namespace,
        array_agg(DISTINCT li.pod) as pod,
        max(li.node) as node,
        max(li.resource_id) as resource_id,
        max(li.usage_start) as usage_start,
        max(li.usage_end) as usage_end,
        max(li.product_code) as product_code,
        max(p.product_family) as product_family,
        max(p.instance_type) as instance_type,
        max(li.cost_entry_bill_id) as cost_entry_bill_id,
        max(li.usage_account_id) as usage_account_id,
        max(aa.id) as account_alias_id,
        max(li.availability_zone) as availability_zone,
        max(p.region) as region,
        max(pr.unit) as unit,
        li.tags,
        max(li.usage_amount) as usage_amount,
        max(li.normalized_usage_amount) as normalized_usage_amount,
        max(li.currency_code) as currency_code,
        max(li.unblended_cost) as unblended_cost,
        max(li.unblended_cost) * {{markup}}::numeric as markup_cost,
        max(li.shared_projects) as shared_projects,
        pc.project_costs,
        ab.provider_id as source_uuid
    FROM reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} AS li
    JOIN {{schema | sqlsafe}}.reporting_awscostentryproduct AS p
        ON li.cost_entry_product_id = p.id
    JOIN cte_storage_project_cost AS pc
        ON li.aws_id = pc.aws_id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awscostentrypricing as pr
        ON li.cost_entry_pricing_id = pr.id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awsaccountalias AS aa
        ON li.usage_account_id = aa.account_id
    LEFT JOIN reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} AS ulid
        ON ulid.aws_id = li.aws_id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awscostentrybill as ab
        ON li.cost_entry_bill_id = ab.id
    WHERE li.usage_start >= {{start_date}}::date
        AND li.usage_start <= {{end_date}}::date
        AND ulid.aws_id IS NULL
    GROUP BY li.aws_id, li.tags, pc.project_costs, ab.provider_id
)
;

-- The full summary data for Openshift pod<->AWS and
-- Openshift volume<->AWS matches are UNIONed together
-- with a GROUP BY using the OCP ID to deduplicate
-- based on OpenShift data. This is effectively the same table
-- as reporting_ocpawscostlineitem_daily_summary but from the OpenShift
-- point of view. Here usage and cost are divided by the
-- number of pods sharing the cost so the values turn out the
-- same when reported.
CREATE TEMPORARY TABLE reporting_ocpawscostlineitem_project_daily_summary_{{uuid | sqlsafe}} AS (
    SELECT li.report_period_id,
        li.cluster_id,
        li.cluster_alias,
        'Pod' as data_source,
        li.namespace,
        li.pod,
        li.node,
        li.pod_labels,
        max(li.resource_id) as resource_id,
        max(li.usage_start) as usage_start,
        max(li.usage_end) as usage_end,
        max(li.product_code) as product_code,
        max(p.product_family) as product_family,
        max(p.instance_type) as instance_type,
        max(li.cost_entry_bill_id) as cost_entry_bill_id,
        max(li.usage_account_id) as usage_account_id,
        max(aa.id) as account_alias_id,
        max(li.availability_zone) as availability_zone,
        max(p.region) as region,
        max(pr.unit) as unit,
        sum(li.usage_amount / li.shared_pods) as usage_amount,
        sum(li.normalized_usage_amount / li.shared_pods) as normalized_usage_amount,
        max(li.currency_code) as currency_code,
        sum(li.unblended_cost / li.shared_pods) as unblended_cost,
        sum(li.unblended_cost / li.shared_pods) * {{markup}}::numeric as markup_cost,
        max(li.shared_pods) as shared_pods,
        li.pod_cost,
        li.pod_cost * {{markup}}::numeric as project_markup_cost,
        ab.provider_id as source_uuid
    FROM reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} as li
    JOIN {{schema | sqlsafe}}.reporting_awscostentryproduct AS p
        ON li.cost_entry_product_id = p.id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awscostentrypricing as pr
        ON li.cost_entry_pricing_id = pr.id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awsaccountalias AS aa
        ON li.usage_account_id = aa.account_id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awscostentrybill as ab
        ON li.cost_entry_bill_id = ab.id
    WHERE li.usage_start >= {{start_date}}::date
        AND li.usage_start <= {{end_date}}::date
    -- Grouping by OCP this time for the by project view
    GROUP BY li.report_period_id,
        li.ocp_id,
        li.cluster_id,
        li.cluster_alias,
        li.namespace,
        li.pod,
        li.node,
        li.pod_labels,
        li.pod_cost,
        ab.provider_id

    UNION

    SELECT li.report_period_id,
        li.cluster_id,
        li.cluster_alias,
        'Storage' as data_source,
        li.namespace,
        li.pod,
        li.node,
        li.persistentvolume_labels || li.persistentvolumeclaim_labels as pod_labels,
        NULL as resource_id,
        max(li.usage_start) as usage_start,
        max(li.usage_end) as usage_end,
        max(li.product_code) as product_code,
        max(p.product_family) as product_family,
        max(p.instance_type) as instance_type,
        max(li.cost_entry_bill_id) as cost_entry_bill_id,
        max(li.usage_account_id) as usage_account_id,
        max(aa.id) as account_alias_id,
        max(li.availability_zone) as availability_zone,
        max(p.region) as region,
        max(pr.unit) as unit,
        sum(li.usage_amount / li.shared_pods) as usage_amount,
        sum(li.normalized_usage_amount / li.shared_pods) as normalized_usage_amount,
        max(li.currency_code) as currency_code,
        sum(li.unblended_cost / li.shared_pods) as unblended_cost,
        sum(li.unblended_cost / li.shared_pods) * {{markup}}::numeric as markup_cost,
        max(li.shared_pods) as shared_pods,
        li.pod_cost,
        li.pod_cost * {{markup}}::numeric as project_markup_cost,
        ab.provider_id as source_uuid
    FROM reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}} AS li
    JOIN {{schema | sqlsafe}}.reporting_awscostentryproduct AS p
        ON li.cost_entry_product_id = p.id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awscostentrypricing as pr
        ON li.cost_entry_pricing_id = pr.id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awsaccountalias AS aa
        ON li.usage_account_id = aa.account_id
    LEFT JOIN reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}} AS ulid
        ON ulid.aws_id = li.aws_id
    LEFT JOIN {{schema | sqlsafe}}.reporting_awscostentrybill as ab
        ON li.cost_entry_bill_id = ab.id
    WHERE li.usage_start >= {{start_date}}::date
        AND li.usage_start <= {{end_date}}::date
        AND ulid.aws_id IS NULL
    GROUP BY li.ocp_id,
        li.report_period_id,
        li.cluster_id,
        li.cluster_alias,
        li.namespace,
        li.pod,
        li.node,
        li.persistentvolume_labels,
        li.persistentvolumeclaim_labels,
        li.pod_cost,
        ab.provider_id
)
;

-- no need to wait for commit
TRUNCATE TABLE reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}};
DROP TABLE reporting_ocpawsusagelineitem_daily_{{uuid | sqlsafe}};

TRUNCATE TABLE reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}};
DROP TABLE reporting_ocpawsstoragelineitem_daily_{{uuid | sqlsafe}};


-- Clear out old entries first
DELETE FROM {{schema | sqlsafe}}.reporting_ocpawscostlineitem_daily_summary
WHERE usage_start >= {{start_date}}
    AND usage_start <= {{end_date}}
    --aws_where_clause
    {% if bill_ids %}
    AND cost_entry_bill_id IN (
        {%- for bill_id in bill_ids -%}
        {{bill_id}}{% if not loop.last %},{% endif %}
        {%- endfor -%}
    )
    {% endif %}
    --ocp_where_clause
    {% if cluster_id %}
    AND cluster_id = {{cluster_id}}
    {% endif %}
;

-- Populate the daily aggregate line item data
INSERT INTO {{schema | sqlsafe}}.reporting_ocpawscostlineitem_daily_summary (
    report_period_id,
    cluster_id,
    cluster_alias,
    namespace,
    pod,
    node,
    resource_id,
    usage_start,
    usage_end,
    product_code,
    product_family,
    instance_type,
    cost_entry_bill_id,
    usage_account_id,
    account_alias_id,
    availability_zone,
    region,
    unit,
    tags,
    usage_amount,
    normalized_usage_amount,
    currency_code,
    unblended_cost,
    markup_cost,
    shared_projects,
    project_costs,
    source_uuid
)
    SELECT report_period_id,
        cluster_id,
        cluster_alias,
        namespace,
        pod,
        node,
        resource_id,
        usage_start,
        usage_end,
        product_code,
        product_family,
        instance_type,
        cost_entry_bill_id,
        usage_account_id,
        account_alias_id,
        availability_zone,
        region,
        unit,
        tags,
        usage_amount,
        normalized_usage_amount,
        currency_code,
        unblended_cost,
        markup_cost,
        shared_projects,
        project_costs,
        source_uuid
    FROM reporting_ocpawscostlineitem_daily_summary_{{uuid | sqlsafe}}
;

-- no need to wait for commit
TRUNCATE TABLE reporting_ocpawscostlineitem_daily_summary_{{uuid | sqlsafe}};
DROP TABLE reporting_ocpawscostlineitem_daily_summary_{{uuid | sqlsafe}};


DELETE FROM {{schema | sqlsafe}}.reporting_ocpawscostlineitem_project_daily_summary
WHERE usage_start >= {{start_date}}
    AND usage_start <= {{end_date}}
    --aws_where_clause
    {% if bill_ids %}
    AND cost_entry_bill_id IN (
        {%- for bill_id in bill_ids -%}
        {{bill_id}}{% if not loop.last %},{% endif %}
        {%- endfor -%}
    )
    {% endif %}
    --ocp_where_clause
    {% if cluster_id %}
    AND cluster_id = {{cluster_id}}
    {% endif %}
;

INSERT INTO {{schema | sqlsafe}}.reporting_ocpawscostlineitem_project_daily_summary (
    report_period_id,
    cluster_id,
    cluster_alias,
    data_source,
    namespace,
    pod,
    node,
    pod_labels,
    resource_id,
    usage_start,
    usage_end,
    product_code,
    product_family,
    instance_type,
    cost_entry_bill_id,
    usage_account_id,
    account_alias_id,
    availability_zone,
    region,
    unit,
    usage_amount,
    normalized_usage_amount,
    currency_code,
    unblended_cost,
    markup_cost,
    pod_cost,
    project_markup_cost,
    source_uuid
)
    SELECT report_period_id,
        cluster_id,
        cluster_alias,
        data_source,
        namespace,
        pod,
        node,
        pod_labels,
        resource_id,
        usage_start,
        usage_end,
        product_code,
        product_family,
        instance_type,
        cost_entry_bill_id,
        usage_account_id,
        account_alias_id,
        availability_zone,
        region,
        unit,
        usage_amount,
        normalized_usage_amount,
        currency_code,
        unblended_cost,
        markup_cost,
        pod_cost,
        project_markup_cost,
        source_uuid
    FROM reporting_ocpawscostlineitem_project_daily_summary_{{uuid | sqlsafe}}
;

DROP INDEX IF EXISTS aws_tags_gin_idx;

-- no need to wait for commit
TRUNCATE TABLE reporting_ocpawscostlineitem_project_daily_summary_{{uuid | sqlsafe}};
DROP TABLE reporting_ocpawscostlineitem_project_daily_summary_{{uuid | sqlsafe}};
