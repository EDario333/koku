# Generated by Django 2.2.13 on 2020-06-17 22:54
import os

from django.db import migrations

from koku import migration_sql_helpers as msh


def apply_create_partition_procedure(apps, schema_editor):
    path = msh.find_db_functions_dir()
    for funcfile in ("create_table_date_range_partition.sql", "create_date_partitions.sql"):
        msh.apply_sql_file(schema_editor, os.path.join(path, funcfile))


class Migration(migrations.Migration):

    dependencies = [("api", "0024_auto_20200824_1759")]

    operations = [migrations.RunPython(code=apply_create_partition_procedure)]
