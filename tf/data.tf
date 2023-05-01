data "ibm_resource_group" "rg" {
  name = var.resource_group_name
}

# Download the cluster configuration and apply it to configure the Kubernetes provider.
data "ibm_container_cluster_config" "cluster_config" {
  cluster_name_id = var.cluster_name
  # If set to true, the Kubernetes configuration for cluster administrators is downloaded.
  admin = false
  # If this parameter is not provided, the default resource group is used.
  resource_group_id = data.ibm_resource_group.rg.id
  # Set the value to false to skip downloading the configuration for the administrator.
  # The configuration files and certificates are downloaded to the directory that you specified
  # in config_dir every time that you run your infrastructure code.
  download = true
  config_dir = "./cluster_config"
}
