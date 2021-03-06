# Generated by Django 3.1.3 on 2020-11-30 12:33
import django.db.models.deletion
from django.db import migrations
from django.db import models


class Migration(migrations.Migration):

    dependencies = [("reporting", "0152_gcpcostentrylineitem")]

    operations = [
        migrations.CreateModel(
            name="OCPNamespaceLabelLineItem",
            fields=[
                ("id", models.BigAutoField(primary_key=True, serialize=False)),
                ("namespace", models.CharField(max_length=253, null=True)),
                ("namespace_labels", models.JSONField(null=True)),
                (
                    "report",
                    models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, to="reporting.ocpusagereport"),
                ),
                (
                    "report_period",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE, to="reporting.ocpusagereportperiod"
                    ),
                ),
            ],
            options={"db_table": "reporting_ocpnamespacelabellineitem", "unique_together": {("report", "namespace")}},
        )
    ]
