# Generated by Django 2.1.7 on 2019-03-13 18:04

from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('reporting', '0047_auto_20190311_2021'),
    ]

    operations = [
        migrations.AlterModelTable(
            name='costsummary',
            table='reporting_ocpcosts_summary',
        ),
    ]