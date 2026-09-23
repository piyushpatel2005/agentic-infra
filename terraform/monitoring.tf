# Alerting: an OCI Notifications topic with an email subscription, fed by
# (a) the instance's own hermes-backup-check.timer publishing directly when
# the last backup is stale, and (b) an Events rule that fires on compute
# stop/terminate so a reclaimed or manually-stopped instance is noticed.

resource "oci_ons_notification_topic" "alerts" {
  compartment_id = var.compartment_ocid
  name           = "${local.name_prefix}-alerts"
  description    = "Hermes backup-staleness and instance-lifecycle alerts."

  freeform_tags = local.common_tags
}

resource "oci_ons_subscription" "alerts_email" {
  compartment_id = var.compartment_ocid
  topic_id       = oci_ons_notification_topic.alerts.id
  protocol       = "EMAIL"
  endpoint       = var.alert_email

  # OCI emails a confirmation link to `endpoint` after apply — the
  # subscription stays PENDING (no messages delivered) until you click it.
}

resource "oci_events_rule" "instance_lifecycle" {
  compartment_id = var.compartment_ocid
  display_name   = "${local.name_prefix}-instance-lifecycle"
  description    = "Notify when the Hermes instance is stopped or terminated."
  is_enabled     = true

  condition = jsonencode({
    eventType = [
      "com.oraclecloud.computeapi.instanceaction.end",
      "com.oraclecloud.computeapi.terminateinstance.end",
    ]
    data = {
      resourceId = oci_core_instance.hermes.id
    }
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = oci_ons_notification_topic.alerts.id
    }
  }

  depends_on = [oci_identity_policy.events_to_ons]

  freeform_tags = local.common_tags
}
