# Generated by Django 3.1.2 on 2020-10-07 01:50
from django.db import migrations
from django.db import models


class Migration(migrations.Migration):

    dependencies = [("api", "0029_auto_20200921_2016")]

    operations = [migrations.AlterField(model_name="user", name="is_active", field=models.BooleanField(null=True))]
