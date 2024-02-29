#!/bin/bash

az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID"
az acr login -n $REGISTRY_NAME
cd /data/
ls -l
cpa verify
cpa buildbundle --force
