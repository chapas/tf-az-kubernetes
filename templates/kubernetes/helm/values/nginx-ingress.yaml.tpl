rbac:
  create: true
controller:
  replicaCount: 2
  metrics:
    enabled: true
    service:
      annotations:
        prometheus.io/scrape: "true"
  config:
    enable-modsecurity: "true"
    enable-owasp-modsecurity-crs: "true"
  defaultBackendService: ${customBackendService != "" ? customBackendService : ""}
  resources:
    limits:
      cpu: 1000m
      memory: 768Mi
    requests:
      cpu: 500m
      memory: 512Mi
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - podAffinityTerm:
          labelSelector:
            matchExpressions:
            - key: app
              operator: In
              values:
              - nginx-ingress
          topologyKey: kubernetes.io/hostname
        weight: 100
  autoscaling:
    enabled: true
    maxReplicas: 4
    minReplicas: 2
    targetCPUUtilizationPercentage: 90
    targetMemoryUtilizationPercentage: 90
defaultBackend:
  enabled: ${customBackendService != "" ? "false" : "true"}