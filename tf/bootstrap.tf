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
  svc_redis = "dnc-redis"
  svc_sentinel = "dnc-sentinel"
  svc_redis_app = "dnc-redis-app"
  svc_storage = "dnc-storage"
  svc_storage_cs = "dnc-storage-cs"
  svc_rmq_subscriber = "dnc-rmq-subscriber"
  svc_rmq_publisher = "dnc-rmq-publisher"
  svc_rabbitmq = "dnc-rabbitmq"
  ############
  # Services #
  ############
  # svc_dns_redis = "${local.svc_redis}.${local.namespace}.svc.cluster.local"
  svc_dns_storage = "${local.svc_storage}.${local.namespace}.svc.cluster.local"
  svc_dns_storage_cs = "${local.svc_storage_cs}.${local.namespace}.svc.cluster.local"
  # By default, the guest user is prohibited from connecting from remote hosts; it can only connect
  # over a loopback interface (i.e. localhost). This applies to connections regardless of the
  # protocol. Any other users will not (by default) be restricted in this way.
  #
  # It is possible to allow the guest user to connect from a remote host by setting the
  # loopback_users configuration to none. (See rabbitmq.conf)
  svc_dns_rabbitmq = "amqp://${var.rabbitmq_default_user}:${var.rabbitmq_default_pass}@${local.svc_rabbitmq}-headless.${local.namespace}.svc.cluster.local:5672"
}

###################################################################################################
# redis                                                                                           #
###################################################################################################
# /*** redis
module "dnc-redis" {
  source = "./modules/redis/redis-statefulset"
  app_name = var.app_name
  app_version = var.app_version
  image_tag = "redis:7.0.11-alpine"
  image_pull_policy = "IfNotPresent"
  namespace = local.namespace
  path_redis_files = "./modules/redis/util"
  publish_not_ready_addresses = true
  # Because several features (e.g. quorum queues, client tracking in MQTT) require a consensus
  # between cluster members, odd numbers of cluster nodes are highly recommended: 1, 3, 5, 7
  # and so on.
  replicas = 3
  # Limits and requests for CPU resources are measured in millicores. If the container needs one
  # full core to run, use the value '1000m.' If the container only needs 1/4 of a core, use the
  # value of '250m.'
  qos_requests_cpu = "300m"
  qos_limits_cpu = "500m"
  qos_requests_memory = "500Mi"
  qos_limits_memory = "800Mi"
  pvc_access_modes = ["ReadWriteOnce"]
  pvc_storage_size = "5Gi"
  pvc_storage_class_name = "ibmc-block-silver"
  env = {
    SENTINEL_NODES = "dnc-sentinel-0.dnc-sentinel-headless,dnc-sentinel-1.dnc-sentinel-headless,dnc-sentinel-2.dnc-sentinel-headless"
  }
  service_port = 6379
  service_target_port = 6379
  service_name = local.svc_redis
}

module "dnc-sentinel" {
  # Redis has to be running when the Sentinel pods are being deployed; otherwise, the startup
  # script will fail.
  depends_on = [
    module.dnc-redis
  ]
  source = "./modules/redis/sentinel-statefulset"
  app_name = var.app_name
  app_version = var.app_version
  image_tag = "redis:7.0.11-alpine"
  image_pull_policy = "IfNotPresent"
  namespace = local.namespace
  path_redis_files = "./modules/redis/util"
  publish_not_ready_addresses = true
  # Because several features require a consensus among cluster members, odd numbers of cluster
  # nodes are highly recommended: 1, 3, 5, 7 and so on.
  replicas = 3
  # Limits and requests for CPU resources are measured in millicores. If the container needs one
  # full core to run, use the value '1000m.' If the container only needs 1/4 of a core, use the
  # value of '250m.'
  qos_requests_cpu = "100m"
  qos_limits_cpu = "200m"
  qos_requests_memory = "300Mi"
  qos_limits_memory = "400Mi"
  env = {
    REDIS_NODES = "dnc-redis-0.dnc-redis-headless,dnc-redis-1.dnc-redis-headless,dnc-redis-2.dnc-redis-headless"
  }
  service_port = 26379
  service_target_port = 26379
  service_name = local.svc_sentinel
}
# ***/  # redis - stateful

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
  # Because several features require a consensus among cluster members, odd numbers of cluster
  # nodes are highly recommended: 1, 3, 5, 7 and so on.
  replicas = 3
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
/*** dnc-redis
module "dnc-redis-app" {
  depends_on = [
    module.dnc-redis
  ]
  source = "./modules/deployment"
  dir_name = "../../dnc-redis"
  app_name = var.app_name
  app_version = var.app_version
  namespace = local.namespace
  # image_tag = "redis:7.0.11-alpine"
  # image_tag = "redis:7.0.11"
  # image_pull_policy = "IfNotPresent"
  # path_redis_files = "./modules/redis-statefulset/util"
  # publish_not_ready_addresses = true
  replicas = 1
  # Limits and requests for CPU resources are measured in millicores. If the container needs one
  # full core to run, use the value '1000m.' If the container only needs 1/4 of a core, use the
  # value of '250m.'
  qos_limits_cpu = "500m"
  qos_limits_memory = "800Mi"
  cr_login_server = local.cr_login_server
  cr_username = var.cr_username
  cr_password = var.cr_password
  # pvc_access_modes = ["ReadWriteOnce"]
  # pvc_storage_size = "5Gi"
  # pvc_storage_class_name = "ibmc-block-silver"
  env = {
    # If a system uses fully qualified domain names (FQDNs) for hostnames, RabbitMQ nodes and CLI
    # tools must be configured to use so called long node names.
    # RABBITMQ_USE_LONGNAME = true
    # Override the main RabbitMQ config file location.
    # RABBITMQ_CONFIG_FILE = "/config/rabbitmq"
  }
  service_port = 5000
  service_target_port = 5000
  service_name = local.svc_redis_app
  service_type = "LoadBalancer"
}
***/ # dnc-redis

# /*** dnc-rmq
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
# ***/ # dnc-rmq

# /*** dnc-storage
module "dnc-storage" {
  # Specify the location of the module, which contains the file main.tf.
  source = "./modules/deployment"
  dir_name = "../../dnc-storage"
  app_name = var.app_name
  app_version = var.app_version
  namespace = local.namespace
  replicas = 2
  qos_limits_cpu = "400m"
  qos_limits_memory = "400Mi"
  cr_login_server = local.cr_login_server
  cr_username = var.cr_username
  cr_password = var.cr_password
  env = {
    SVC_NAME: local.svc_dns_storage
    BUCKET_NAME: var.bucket_name
    # With IAM.
    AUTHENTICATION_TYPE: "iam"
    API_KEY: var.iam_storage_api_key
    SERVICE_INSTANCE_ID: var.iam_resource_instance_id
    ENDPOINT: var.iam_public_endpoint
    REGION: var.iam_storage_region
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
# ***/ # dnc-storage

# /*** dnc-storage-cs
module "dnc-storage-cs" {
  # Specify the location of the module, which contains the file main.tf.
  source = "./modules/deployment"
  dir_name = "../../dnc-storage-cs"
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
    # SVC_DNS: local.svc_dns_storage_cs
    # BUCKET_NAME: var.bucket_name
    # Without HMAC.
    # AUTHENTICATION_TYPE: "iam"
    # API_KEY: var.storage_api_key
    # SERVICE_INSTANCE_ID: var.resource_instance_id
    # ENDPOINT: var.public_endpoint
    # REGION: var.storage_region
    # With HMAC.
    AUTHENTICATION_TYPE: "hmac"
    REGION: var.hmac_storage_region
    ACCESS_KEY_ID: var.hmac_access_key_id
    SECRET_ACCESS_KEY: var.hmac_secret_access_key
    ENDPOINT: var.hmac_public_endpoint
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
  service_name = local.svc_storage_cs
  service_type = "LoadBalancer"
}
# ***/ # dot-net-core

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
