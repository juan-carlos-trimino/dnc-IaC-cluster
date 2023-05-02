# $ terraform init
# $ terraform apply -var="app_version=1.0.0" -auto-approve
# $ terraform destroy -var="app_version=1.0.0" -auto-approve
# $ meta git clone https://github.com/juan-carlos-trimino/dnc-meta-repo.git
# $ kubectl get all -n dot-net-core
locals {
  namespace = kubernetes_namespace.ns.metadata[0].name
  cr_login_server = "docker.io"
  ####################
  # Name of Services #
  ####################
  svc_storage = "dnc-storage"
  svc_rmq_subscriber = "dnc-rmq-subscriber"
  svc_rmq_publisher = "dnc-rmq-publisher"
  svc_rabbitmq = "dnc-rabbitmq"
  ############
  # Services #
  ############
  svc_dns_storage = "${local.svc_storage}.${local.namespace}.svc.cluster.local"
  # By default, the guest user is prohibited from connecting from remote hosts; it can only connect
  # over a loopback interface (i.e. localhost). This applies to connections regardless of the
  # protocol. Any other users will not (by default) be restricted in this way.
  #
  # It is possible to allow the guest user to connect from a remote host by setting the
  # loopback_users configuration to none. (See rabbitmq.conf)
  svc_dns_rabbitmq = "amqp://${var.rabbitmq_default_user}:${var.rabbitmq_default_pass}@${local.svc_rabbitmq}-headless.${local.namespace}.svc.cluster.local:5672"
}

###################################################################################################
# rabbitmq                                                                                        #
###################################################################################################
# /*** rabbitmq
module "dnc-rabbitmq" {
  source = "./modules/rabbitmq-statefulset"
  app_name = var.app_name
  app_version = var.app_version
  # This image has the RabbitMQ dashboard.
  image_tag = "rabbitmq:3.11.13-management-alpine"
  # This image does not have the RabbitMQ dashboard.
  # image_tag = "rabbitmq:3.11.13-alpine"
  image_pull_policy = "IfNotPresent"
  namespace = local.namespace
  path_rabbitmq_files = "./modules/rabbitmq-statefulset/util"
  rabbitmq_erlang_cookie = var.rabbitmq_erlang_cookie
  rabbitmq_default_pass = var.rabbitmq_default_pass
  rabbitmq_default_user = var.rabbitmq_default_user
  publish_not_ready_addresses = true
  # Because several features (e.g. quorum queues, client tracking in MQTT) require a consensus
  # between cluster members, odd numbers of cluster nodes are highly recommended: 1, 3, 5, 7
  # and so on.
  replicas = 1
  # Limits and requests for CPU resources are measured in millicores. If the container needs one
  # full core to run, use the value '1000m.' If the container only needs 1/4 of a core, use the
  # value of '250m.'
  qos_limits_cpu = "500m"
  qos_limits_memory = "800Mi"
  pvc_access_modes = ["ReadWriteOnce"]
  pvc_storage_size = "10Gi"
  # pvc_storage_class_name = "ibmc-vpc-block-general-purpose"
  pvc_storage_class_name = "ibmc-block-silver"
  env = {
    # If a system uses fully qualified domain names (FQDNs) for hostnames, RabbitMQ nodes and CLI
    # tools must be configured to use so called long node names.
    RABBITMQ_USE_LONGNAME = true
    # Override the main RabbitMQ config file location.
    RABBITMQ_CONFIG_FILE = "/config/rabbitmq"
  }
  amqp_service_port = 5672
  amqp_service_target_port = 5672
  mgmt_service_port = 15672
  mgmt_service_target_port = 15672
  service_name = local.svc_rabbitmq
}
# ***/  # rabbitmq - statefulset

###################################################################################################
# Application                                                                                     #
###################################################################################################
# /***
module "dnc-rmq-publisher" {
  depends_on = [
    module.dnc-rabbitmq
  ]
  # Specify the location of the module, which contains the file main.tf.
  source = "./modules/deployment"
  dir_name = "../../dnc-RabbitMQ"
  dockerfile_name = "Dockerfile-Publisher-prod"
  app_name = var.app_name
  app_version = var.app_version
  namespace = local.namespace
  replicas = 1
  qos_limits_cpu = "400m"
  qos_limits_memory = "2Gi"
  cr_login_server = local.cr_login_server
  cr_username = var.cr_username
  cr_password = var.cr_password
  env = {
    SVC_DNS: local.svc_dns_rabbitmq
  }
  # readiness_probe = [{
  #   http_get = [{
  #     path = "/readiness"
  #     port = 0
  #     scheme = "HTTP"
  #   }]
  #   initial_delay_seconds = 30
  #   period_seconds = 20
  #   timeout_seconds = 2
  #   failure_threshold = 4
  #   success_threshold = 1
  # }]
  service_name = local.svc_rmq_publisher
}

module "dnc-rmq-subscriber" {
  depends_on = [
    module.dnc-rabbitmq
  ]
  # Specify the location of the module, which contains the file main.tf.
  source = "./modules/deployment"
  dir_name = "../../dnc-RabbitMQ"
  dockerfile_name = "Dockerfile-Subscriber-prod"
  app_name = var.app_name
  app_version = var.app_version
  namespace = local.namespace
  replicas = 1
  qos_limits_cpu = "400m"
  qos_limits_memory = "400Mi"
  cr_login_server = local.cr_login_server
  cr_username = var.cr_username
  cr_password = var.cr_password
  env = {
    SVC_DNS: local.svc_dns_rabbitmq
  }
  # readiness_probe = [{
  #   http_get = [{
  #     path = "/readiness"
  #     port = 0
  #     scheme = "HTTP"
  #   }]
  #   initial_delay_seconds = 30
  #   period_seconds = 20
  #   timeout_seconds = 2
  #   failure_threshold = 4
  #   success_threshold = 1
  # }]
  service_name = local.svc_rmq_subscriber
}
# ***/

module "dnc-storage" {
  # Specify the location of the module, which contains the file main.tf.
  source = "./modules/deployment"
  dir_name = "../../dnc-storage"
  app_name = var.app_name
  app_version = var.app_version
  namespace = local.namespace
  replicas = 1
  qos_limits_cpu = "400m"
  qos_limits_memory = "400Mi"
  cr_login_server = local.cr_login_server
  cr_username = var.cr_username
  cr_password = var.cr_password
  env = {
    SVC_NAME: local.svc_dns_storage
    BUCKET_NAME: var.bucket_name
    # Without HMAC.
    AUTHENTICATION_TYPE: "iam"
    API_KEY: var.storage_api_key
    SERVICE_INSTANCE_ID: var.resource_instance_id
    ENDPOINT: var.public_endpoint
    REGION: var.storage_region
    # With HMAC.
    # AUTHENTICATION_TYPE: "hmac"
    # REGION: var.region1
    # ACCESS_KEY_ID: var.access_key_id
    # SECRET_ACCESS_KEY: var.secret_access_key
    # ENDPOINT: var.public_endpoint
  }
  # readiness_probe = [{
  #   http_get = [{
  #     path = "/readiness"
  #     port = 0
  #     scheme = "HTTP"
  #   }]
  #   initial_delay_seconds = 30
  #   period_seconds = 20
  #   timeout_seconds = 2
  #   failure_threshold = 4
  #   success_threshold = 1
  # }]
  service_name = local.svc_storage
  service_type = "LoadBalancer"
}

/***
module "rmq-consumer-go" {
  depends_on = [
    module.rabbitmq
  ]
  # Specify the location of the module, which contains the file main.tf.
  source = "./modules/deployment"
  dir_name = "../../${local.svc_rmq_consumer_go}"
  app_name = var.app_name
  app_version = var.app_version
  namespace = local.namespace
  replicas = 1
  qos_limits_cpu = "400m"
  qos_limits_memory = "400Mi"
  cr_login_server = local.cr_login_server
  cr_username = var.cr_username
  cr_password = var.cr_password
  # Configure environment variables specific to the mem-gateway.
  env = {
    # APP_NAME_VER: "${var.app_name} ${var.app_version}"
    # MAX_RETRIES: 20
    SVC_DNS: local.svc_dns_rabbitmq
    # SVC_NAME: local.svc_rmqconsumer
  }
  # readiness_probe = [{
  #   http_get = [{
  #     path = "/readiness"
  #     port = 0
  #     scheme = "HTTP"
  #   }]
  #   initial_delay_seconds = 30
  #   period_seconds = 20
  #   timeout_seconds = 2
  #   failure_threshold = 4
  #   success_threshold = 1
  # }]
  service_name = local.svc_rmq_consumer_go
}
***/
