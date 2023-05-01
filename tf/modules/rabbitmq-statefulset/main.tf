terraform {
  required_providers {
    kubectl = {
      source = "gavinbunney/kubectl"
    }
  }
}
/***
-------------------------------------------------------
A Terraform reusable module for deploying microservices
-------------------------------------------------------
Define input variables to the module.
***/
variable app_name {}
variable app_version {}
variable image_tag {}
variable path_rabbitmq_files {}
variable rabbitmq_erlang_cookie {}
variable rabbitmq_default_pass {}
variable rabbitmq_default_user {}
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
variable pvc_access_modes {
  default = []
  type = list(any)
}
variable pvc_storage_class_name {
  default = ""
}
variable pvc_storage_size {
  default = "20Gi"
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
variable amqp_service_port {
  type = number
}
variable amqp_service_target_port {
  type = number
}
variable mgmt_service_port {
  type = number
}
variable mgmt_service_target_port {
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
  rmq_label = "dnc-rmq-cluster"
}

resource "kubectl_manifest" "rmq-route" {
  yaml_body = <<-YAML
    apiVersion: route.openshift.io/v1
    # In order for services to be exposed externally, a route allows you to associate a service
    # with an externally-reachable host name. This edge host name is then used to route traffic to
    # the service.
    kind: Route
    metadata:
      name: dnc-rabbitmq-route
      namespace: "${var.namespace}"
      labels: {
        app: "${var.app_name}"
      }
    spec:
      host: null
      to:
        kind: Service
        name: "${local.svc_name}"
        weight: 100
      port:
        targetPort: 15672
      wildcardPolicy: None
    YAML
}

resource "null_resource" "scc-rabbitmq" {
  triggers = {
    always_run = timestamp()
  }
  provisioner "local-exec" {
    command = "oc apply -f ${var.path_rabbitmq_files}/dnc-rabbitmq-scc.yaml"
  }
  #
  provisioner "local-exec" {
    when = destroy
    command = "oc delete scc dnc-rabbitmq-scc"
  }
}

resource "kubernetes_secret" "secret" {
  metadata {
    name = "${var.service_name}-secret"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  # Plain-text data.
  # RabbitMQ nodes and the CLI tools use a cookie to determine whether they are allowed to
  # communicate with each other. For two nodes to be able to communicate, they must have the same
  # shared secret called the Erlang cookie.
  data = {
    # RabbitMQ nodes and CLI tools use a shared secret known as the Erlang Cookie, to authenticate
    # to each other. The cookie value is a string of alphanumeric characters up to 255 characters
    # in size.
    cookie = var.rabbitmq_erlang_cookie
    pass = var.rabbitmq_default_pass
    user = var.rabbitmq_default_user
  }
  type = "Opaque"
}

# A ServiceAccount is used by an application running inside a pod to authenticate itself with the
# API server. A default ServiceAccount is automatically created for each namespace; each pod is
# associated with exactly one ServiceAccount, but multiple pods can use the same ServiceAccount. A
# pod can only use a ServiceAccount from the same namespace.
#
# For cluster security, let's constrain the cluster metadata this pod may read.
resource "kubernetes_service_account" "service_account" {
  metadata {
    name      = "${var.service_name}-service-account"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
    annotations = {
      "kubernetes.io/enforce-mountable-secrets" = true
    }
  }
  secret {
    name = kubernetes_secret.secret.metadata[0].name
  }
}

# Roles define WHAT can be done; role bindings define WHO can do it.
# The distinction between a Role/RoleBinding and a ClusterRole/ClusterRoleBinding is that the Role/
# RoleBinding is a namespaced resource; ClusterRole/ClusterRoleBinding is a cluster-level resource.
# A Role resource defines what actions can be taken on which resources; i.e., which types of HTTP
# requests can be performed on which RESTful resources.
#
# RabbitMQ's Kubernetes peer discovery plugin relies on the Kubernetes API as a data source. On
# first boot, every node will try to discover their peers using the Kubernetes API and attempt to
# join them. Nodes that finish booting emit a Kubernetes event to make it easier to discover such
# events in cluster activity (event) logs.
resource "kubernetes_role" "role" {
  metadata {
    name = "${var.service_name}-role"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  rule {
    # Resources in the core apiGroup, which has no name - hence the "".
    api_groups = [""]
    verbs = ["get", "watch", "list"]
    # This rule pertains to endpoints; the plural form must be used when specifying resources.
    # The peer discovery plugin requires that the pod it runs in has rights to query the K8s API
    # endpoints resource (https://github.com/rabbitmq/rabbitmq-peer-discovery-k8s).
    resources = ["endpoints"]
  }
  rule {
    api_groups = [""]
    verbs = ["create"]
    resources = ["events"]
  }
  rule {
    api_groups = ["security.openshift.io"]
    verbs = ["use"]
    resources = ["securitycontextconstraints"]
    resource_names = ["dnc-rabbitmq-scc"]
  }
}

# Bind the role to the service account.
resource "kubernetes_role_binding" "role_binding" {
  metadata {
    name = "${var.service_name}-role-binding"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  # A RoleBinding always references a single Role, but it can bind the Role to multiple subjects.
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind = "Role"
    # This RoleBinding references the Role specified below...
    name = kubernetes_role.role.metadata[0].name
  }
  # ... and binds it to the specified ServiceAccount in the specified namespace.
  subject {
    # The default permissions for a ServiceAccount don't allow it to list or modify any resources.
    kind = "ServiceAccount"
    name = kubernetes_service_account.service_account.metadata[0].name
    namespace = kubernetes_service_account.service_account.metadata[0].namespace
  }
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
    # The enabled_plugins file is usually located in the node data directory or under /etc,
    # together with configuration files. The file contains a list of plugin names ending with
    # a dot.
    "enabled_plugins" = "[rabbitmq_federation, rabbitmq_management, rabbitmq_peer_discovery_k8s]."
    "rabbitmq.conf" = "${file("${var.path_rabbitmq_files}/rabbitmq.conf")}"
  }
}

# RabbitMQ requires using a StatefulSet to deploy a RabbitMQ cluster to Kubernetes. The StatefulSet
# ensures that the RabbitMQ nodes are deployed in order, one at a time. This avoids running into a
# potential peer discovery race condition when deploying a multi-node RabbitMQ cluster.
#
# There are other, equally important reasons for using a StatefulSet instead of a Deployment:
# sticky identity, simple network identifiers, stable persistent storage and the ability to perform
# ordered rolling upgrades.
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
    # A headless service gives network identity to the RabbitMQ nodes and enables them to cluster.
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
          rmq_lbl = local.rmq_label
        }
      }
      #
      spec {
        service_account_name = kubernetes_service_account.service_account.metadata[0].name
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  # Description of the pod label that determines when the anti-affinity rule
                  # applies. Specifies a key and value for the label.
                  key = "rmq_lbl"
                  # The operator represents the relationship between the label on the existing
                  # pod and the set of values in the matchExpression parameters in the
                  # specification for the new pod. Can be In, NotIn, Exists, or DoesNotExist.
                  operator = "In"
                  values = ["${local.rmq_label}"]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }
        termination_grace_period_seconds = var.termination_grace_period_seconds
        container {
          name = var.service_name
          image = var.image_tag
          image_pull_policy = var.image_pull_policy
          security_context {
            run_as_non_root = true
            run_as_user = 1060
            run_as_group = 1060
            read_only_root_filesystem = false
          }
          # Specifying ports in the pod definition is purely informational. Omitting them has no
          # effect on whether clients can connect to the pod through the port or not. If the
          # container is accepting connections through a port bound to the 0.0.0.0 address, other
          # pods can always connect to it, even if the port isn't listed in the pod spec
          # explicitly. Nonetheless, it is good practice to define the ports explicitly so that
          # everyone using the cluster can quickly see what ports each pod exposes.
          port {
            name = "amqp"
            container_port = var.amqp_service_target_port # The port the app is listening.
            protocol = "TCP"
          }
          port {
            name = "mgmt"
            container_port = var.mgmt_service_target_port # The port the app is listening.
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
          # Using the Pod field as a value for the environment variable; pass RABBIT_POD_NAME to
          # build the FQDN.
          env {
            name = "RABBIT_POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }
          # Using the Pod field as a value for the environment variable; pass RABBIT_POD_NAMESPACE
          # to build the FQDN.
          env {
            name = "RABBIT_POD_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }
          # The name of the headless service needs to be provided to the discovery plugin via this
          # environment variable. It uses the name to query the K8s API for information on all pods
          # selected by the service.
          env {
            name = "K8S_SERVICE_NAME"
            value = local.svc_name
          }
          # When a node starts up, it checks whether it has been assigned a node name. If no value
          # was explicitly configured, the node resolves its hostname and prepends rabbit to it to
          # compute its node name.
          # Build the rabbitmq host FQDN.
          env {
            name = "RABBITMQ_NODENAME"
            value = "rabbit@$(RABBIT_POD_NAME).$(K8S_SERVICE_NAME).$(RABBIT_POD_NAMESPACE).svc.cluster.local"
          }
          # Build the cluster DNS domain name.
          # Suffix to match FQDN of rabbitmq instances in the K8s namespace.
          env {
            name = "K8S_HOSTNAME_SUFFIX"
            value = ".$(K8S_SERVICE_NAME).$(RABBIT_POD_NAMESPACE).svc.cluster.local"
          }
          # This environment variable is only mean to be used in development and CI environments.
          # This has the same meaning as default_user in rabbitmq.conf but higher priority. This
          # option may be more convenient in cases where providing a config file is impossible, and
          # environment variables is the only way to seed a user.
          env {
            name = "RABBITMQ_DEFAULT_PASS"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.secret.metadata[0].name
                key = "pass"
              }
            }
          }
          # This environment variable is only mean to be used in development and CI environments.
          # This has the same meaning as default_pass in rabbitmq.conf but higher priority. This
          # option may be more convenient in cases where providing a config file is impossible, and
          # environment variables is the only way to seed a user.
          env {
            name = "RABBITMQ_DEFAULT_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.secret.metadata[0].name
                key = "user"
              }
            }
          }
          dynamic "env" {
            for_each = var.env
            content {
              name = env.key
              value = env.value
            }
          }
          # liveness_probe {
          #   exec {
          #     command = ["rabbitmq-diagnostics", "status", "--erlang-cookie", "$(RABBITMQ_ERLANG_COOKIE)"]
          #   }
          #   initial_delay_seconds = 60
          #   # See https://www.rabbitmq.com/monitoring.html for monitoring frequency recommendations.
          #   period_seconds = 60
          #   timeout_seconds = 15
          #   failure_threshold = 3
          #   success_threshold = 1
          # }
          # readiness_probe {
          #   exec {
          #     command = ["rabbitmq-diagnostics", "status", "--erlang-cookie", "$(RABBITMQ_ERLANG_COOKIE)"]
          #   }
          #   initial_delay_seconds = 20
          #   period_seconds = 60
          #   timeout_seconds = 10
          # }
          volume_mount {
            name = "rabbitmq-storage"
            mount_path = "/var/lib/rabbitmq/mnesia"
            read_only = false
          }
          volume_mount {
            name = "rabbitmq-storage"
            mount_path = "/var/lib/rabbitmq/mnesia/$(RABBITMQ_NODENAME).pid"
            sub_path = "$(RABBITMQ_NODENAME).pid"
            read_only = false
          }
          # In Linux when a filesystem is mounted into a non-empty directory, the directory will
          # only contain the files from the newly mounted filesystem. The files in the original
          # directory are inaccessible for as long as the filesystem is mounted. In cases when the
          # original directory contains crucial files, mounting a volume could break the container.
          # To overcome this limitation, K8s provides an additional subPath property on the
          # volumeMount; this property mounts a single file or a single directory from the volume
          # instead of mounting the whole volume, and it does not hide the existing files in the
          # original directory.
          volume_mount {
            name = "erlang-cookie"
            # Mounting into a file, not a directory.
            mount_path = "/var/lib/rabbitmq/mnesia/.erlang.cookie"
            # Instead of mounting the whole volume, only mounting the given entry.
            sub_path = ".erlang.cookie"
            read_only = false
          }
          volume_mount {
            name = "config"
            mount_path = "/config/rabbitmq"
            read_only = true
          }
        }
        volume {
          name = "erlang-cookie"
          secret {
            secret_name = kubernetes_secret.secret.metadata[0].name
            default_mode = "0600" # Octal
            # Selecting which entries to include in the volume by listing them.
            items {
              # Include the entry under this key.
              key = "cookie"
              # The entry's value will be stored in this file.
              path = ".erlang.cookie"
            }
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.config.metadata[0].name
            # By default, the permissions on all files in a configMap volume are set to 644
            # (rw-r--r--).
            default_mode = "0600" # Octal
            items {
              key = "enabled_plugins"
              path = "enabled_plugins" #File name.
            }
            items {
              key = "rabbitmq.conf"
              path = "rabbitmq.conf" #File name.
            }
          }
        }
      }
    }
    # This template will be used to create a PersistentVolumeClaim for each pod.
    # Since PersistentVolumes are cluster-level resources, they do not belong to any namespace, but
    # PersistentVolumeClaims can only be created in a specific namespace; they can only be used by
    # pods in the same namespace.
    #
    # In order for RabbitMQ nodes to retain data between Pod restarts, node's data directory must
    # use durable storage. A Persistent Volume must be attached to each RabbitMQ Pod.
    #
    # If a transient volume is used to back a RabbitMQ node, the node will lose its identity and
    # all of its local data in case of a restart. This includes both schema and durable queue data.
    # Syncing all of this data on every node restart would be highly inefficient. In case of a loss
    # of quorum during a rolling restart, this will also lead to data loss.
    volume_claim_template {
      metadata {
        name      = "rabbitmq-storage"
        namespace = var.namespace
        labels = {
          app = var.app_name
        }
      }
      spec {
        access_modes = var.pvc_access_modes
        storage_class_name = var.pvc_storage_class_name
        resources {
          requests = {
            storage = var.pvc_storage_size
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
      name = "amqp"                       # AMQP 0-9-1 and AMQP 1.0 clients.
      port = var.amqp_service_port        # Service port.
      target_port = var.amqp_service_target_port # Pod port.
      protocol = "TCP"
    }
    port {
      name = "mgmt"                       # management UI and HTTP API).
      port = var.mgmt_service_port        # Service port.
      target_port = var.mgmt_service_target_port # Pod port.
      protocol = "TCP"
    }
    type = var.service_type
    cluster_ip = "None" # Headless Service.
    publish_not_ready_addresses = var.publish_not_ready_addresses
  }
}
