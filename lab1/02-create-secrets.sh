#!/bin/bash
# Run these commands to create secrets in the dev namespace before deploying services.
# These secrets are referenced by envFrom in the Deployment specs.
# In Session 3, External Secrets Operator will replace this manual step.

# db-credentials — used by auth-service, api-gateway, catalog, inventory,
#                  manufacturing, notification, and supplier services.
# The secret must include both DB_* and SPRING_DATASOURCE_* keys because
# different services reference different variable names.
kubectl create secret generic db-credentials \
  --from-literal=DB_USERNAME=pharmaadmin \
  --from-literal=DB_PASSWORD=<YOUR_DB_PASSWORD> \
  --from-literal=SPRING_DATASOURCE_USERNAME=pharmaadmin \
  --from-literal=SPRING_DATASOURCE_PASSWORD=<YOUR_DB_PASSWORD> \
  -n dev

# jwt-secret — used by auth-service and api-gateway
kubectl create secret generic jwt-secret \
  --from-literal=JWT_SECRET=mysupersecretjwtkey256bitslongkey \
  -n dev

# Verify secrets were created
kubectl get secrets -n dev

# Peek at the values (base64 encoded — NOT encrypted)
echo "DB_USERNAME:"
kubectl get secret db-credentials -n dev -o jsonpath='{.data.DB_USERNAME}' | base64 -d && echo
echo "JWT_SECRET:"
kubectl get secret jwt-secret -n dev -o jsonpath='{.data.JWT_SECRET}' | base64 -d && echo
