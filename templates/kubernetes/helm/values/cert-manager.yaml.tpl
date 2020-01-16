global:
  rbac:
    create: true

replicaCount: 1
resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    cpu: 20m
    memory: 64Mi

webhook:
  enabled: true
  replicaCount: 1
  resources:
    requests:
      cpu: 25m
      memory: 32Mi
    limits:
      cpu: 50m
      memory: 64Mi

cainjector:
  replicaCount: 1
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 20m
      memory: 64Mi