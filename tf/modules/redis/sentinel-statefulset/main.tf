/***
-------------------------------------------------------
A Terraform reusable module for deploying microservices
-------------------------------------------------------
Define input variables to the module.
***/
variable app_name {}
variable app_version {}
variable image_tag {}
variable path_redis_files {}
variable namespace {
  default = "default"
}
# Be aware that the default imagePullPolicy depends on the image tag. If a container refers to the
# latest tag (either explicitly or by not specifying the tag at all), imagePullPolicy defaults to
# Always, but if the container refers to any other tag, the policy defaults to IfNotPresent.
#
# When using a tag other that latest, the imagePullPolicy property must be set if changes are made
# to an image without changing the tag. Better yet, always push changes to an image under a new
# tag.
variable image_pull_policy {
  default = "Always"
}
variable env {
  default = {}
  type = map(any)
}
variable qos_requests_cpu {
  default = ""
}
variable qos_requests_memory {
  default = ""
}
variable qos_limits_cpu {
  default = "0"
}
variable qos_limits_memory {
  default = "0"
}
variable replicas {
  default = 1
  type = number
}
variable termination_grace_period_seconds {
  default = 30
  type = number
}
# To relax the StatefulSet ordering guarantee while preserving its uniqueness and identity
# guarantee.
variable pod_management_policy {
  default = "OrderedReady"
}
# The primary use case for setting this field is to use a StatefulSet's Headless Service to
# propagate SRV records for its Pods without respect to their readiness for purpose of peer
# discovery.
variable publish_not_ready_addresses {
  default = "false"
  type = bool
}
variable service_name {
  default = ""
}
# The service normally forwards each connection to a randomly selected backing pod. To
# ensure that connections from a particular client are passed to the same Pod each time,
# set the service's sessionAffinity property to ClientIP instead of None (default).
#
# Session affinity and Web Browsers (for LoadBalancer Services)
# Since the service is now exposed externally, accessing it with a web browser will hit
# the same pod every time. If the sessionAffinity is set to None, then why? The browser
# is using keep-alive connections and sends all its requests through a single connection.
# Services work at the connection level, and when a connection to a service is initially
# open, a random pod is selected and then all network packets belonging to that connection
# are sent to that single pod. Even with the sessionAffinity set to None, the same pod will
# always get hit (until the connection is closed).
variable service_session_affinity {
  default = "None"
}
variable service_port {
  type = number
}
variable service_target_port {
  type = number
}
# The ServiceType allows to specify what kind of Service to use: ClusterIP (default),
# NodePort, LoadBalancer, and ExternalName.
variable service_type {
  default = "ClusterIP"
}

locals {
  svc_name = "${var.service_name}-headless"
  pod_selector_label = "ps-${var.service_name}"
  svc_selector_label = "svc-${local.svc_name}"
  sentinel_label = "dnc-sentinel-cluster"
}

# The ConfigMap passes to the rabbitmq daemon a bootstrap configuration which mainly defines peer
# discovery and connectivity settings.
resource "kubernetes_config_map" "config" {
  metadata {
    name = "${var.service_name}-config"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  data = {
    "update-sentinel-config" = "${file("${var.path_redis_files}/update-sentinel-config.sh")}"
    # "sentinel-conf" = "${file("${var.path_redis_files}/sentinel.conf")}"
  }
}

# Redis Sentinel (https://redis.io/docs/management/sentinel/) provides high availability for Redis
# when not using Redis Cluster (https://redis.io/docs/management/scaling/).
#
# Unlike pods created by ReplicaSets, pods created by the StatefulSet aren't exact replicas of each
# other. Each can have its own set of volumes (persistent state), which differentiates it from its
# peers. Furthermore, these pods have a stable identity (a requirement for the Sentinel pods)
# instead of each new pod getting a completely random one.
#
# $ kubectl get sts -n dot-net-core
resource "kubernetes_stateful_set" "stateful_set" {
  metadata {
    name = var.service_name
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  #
  spec {
    replicas = var.replicas
    # The name of the service that governs this StatefulSet.
    # This service must exist before the StatefulSet and is responsible for the network identity of
    # the set. Pods get DNS/hostnames that follow the pattern:
    #   pod-name.service-name.namespace.svc.cluster.local
    service_name = local.svc_name
    pod_management_policy = var.pod_management_policy
    # Pod Selector - You must set the .spec.selector field of a StatefulSet to match the labels of
    # its .spec.template.metadata.labels. Failing to specify a matching Pod Selector will result in
    # a validation error during StatefulSet creation.
    selector {
      match_labels = {
        # It must match the labels in the Pod template (.spec.template.metadata.labels).
        pod_selector_lbl = local.pod_selector_label
      }
    }
    # Pod template.
    template {
      metadata {
        # Labels attach to the Pod.
        labels = {
          app = var.app_name
          # It must match the label for the pod selector (.spec.selector.matchLabels).
          pod_selector_lbl = local.pod_selector_label
          # It must match the label selector of the Service.
          svc_selector_lbl = local.svc_selector_label
          sentinel_lbl = local.sentinel_label
        }
      }
      #
      spec {
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  # Description of the pod label that determines when the anti-affinity rule
                  # applies. Specifies a key and value for the label.
                  key = "sentinel_lbl"
                  # The operator represents the relationship between the label on the existing
                  # pod and the set of values in the matchExpression parameters in the
                  # specification for the new pod. Can be In, NotIn, Exists, or DoesNotExist.
                  operator = "In"
                  values = ["${local.sentinel_label}"]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }
        termination_grace_period_seconds = var.termination_grace_period_seconds
        init_container {
          name = "init-sentinel"
          image = var.image_tag
          image_pull_policy = var.image_pull_policy
          command = [
            "/bin/sh", "-c"
          ]
          args = [
            "/sentinel/update-sentinel-config.sh $(REDIS_NODES)"
          ]
          dynamic "env" {
            for_each = var.env
            content {
              name = env.key
              value = env.value
            }
          }
          volume_mount {
            name = "sentinel-config"
            mount_path = "/sentinel-config"
            read_only = false
          }
          volume_mount {
            name = "config"
            mount_path = "/sentinel"
            read_only = true
          }
        }
        container {
          name = var.service_name
          image = var.image_tag
          image_pull_policy = var.image_pull_policy
          command = [
            "redis-sentinel",
            "/sentinel-config/sentinel.conf"
          ]
          # Specifying ports in the pod definition is purely informational. Omitting them has no
          # effect on whether clients can connect to the pod through the port or not. If the
          # container is accepting connections through a port bound to the 0.0.0.0 address, other
          # pods can always connect to it, even if the port isn't listed in the pod spec
          # explicitly. Nonetheless, it is good practice to define the ports explicitly so that
          # everyone using the cluster can quickly see what ports each pod exposes.
          port {
            name = "sentinel"
            container_port = var.service_target_port # The port the app is listening.
            protocol = "TCP"
          }
          resources {
            requests = {
              # If a Container specifies its own memory limit, but does not specify a memory
              # request, Kubernetes automatically assigns a memory request that matches the limit.
              # Similarly, if a Container specifies its own CPU limit, but does not specify a CPU
              # request, Kubernetes automatically assigns a CPU request that matches the limit.
              cpu = var.qos_requests_cpu == "" ? var.qos_limits_cpu : var.qos_requests_cpu
              memory = var.qos_requests_memory == "" ? var.qos_limits_memory : var.qos_requests_memory
            }
            limits = {
              cpu = var.qos_limits_cpu
              memory = var.qos_limits_memory
            }
          }
          dynamic "env" {
            for_each = var.env
            content {
              name = env.key
              value = env.value
            }
          }
          volume_mount {
            name = "sentinel-data"
            mount_path = "/data"
            read_only = false
          }
          volume_mount {
            name = "sentinel-config"
            mount_path = "/sentinel-config"
            read_only = false
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.config.metadata[0].name
            # By default, the permissions on all files in a configMap volume are set to 644
            # (rw-r--r--).
            default_mode = "0770" # Octal
            # items {
            #   key = "sentinel-conf"
            #   path = "sentinel.conf" #File name.
            # }
            items {
              key = "update-sentinel-config"
              path = "update-sentinel-config.sh" #File name.
            }
          }
        }
        volume {
          name = "sentinel-data"
          empty_dir {
          }
        }
        volume {
          name = "sentinel-config"
          empty_dir {
          }
        }
      }
    }
  }
}

# Before deploying a StatefulSet, you will need to create a headless Service, which will be used
# to provide the network identity for your stateful pods.
resource "kubernetes_service" "headless_service" { # For inter-node communication.
  metadata {
    name = local.svc_name
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  #
  spec {
    selector = {
      # All pods with the svc_selector_lbl=local.svc_selector_label label belong to this service.
      svc_selector_lbl = local.svc_selector_label
    }
    session_affinity = var.service_session_affinity
    port {
      name = "sentinel"
      port = var.service_port # Service port.
      target_port = var.service_target_port # Pod port.
      protocol = "TCP"
    }
    type = var.service_type
    cluster_ip = "None" # Headless Service.
    publish_not_ready_addresses = var.publish_not_ready_addresses
  }
}
