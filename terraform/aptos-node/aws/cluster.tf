resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/aptos-${local.workspace_name}/cluster"
  retention_in_days = 7
  tags              = local.default_tags
}

resource "aws_eks_cluster" "aptos" {
  name                      = "aptos-${local.workspace_name}"
  role_arn                  = aws_iam_role.cluster.arn
  version                   = var.kubernetes_version
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  tags                      = local.default_tags

  vpc_config {
    subnet_ids              = concat(aws_subnet.public.*.id, aws_subnet.private.*.id)
    public_access_cidrs     = var.k8s_api_sources
    endpoint_private_access = true
    security_group_ids      = [aws_security_group.cluster.id]
  }

  lifecycle {
    ignore_changes = [
      # ignore autoupgrade version
      version,
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster-cluster,
    aws_iam_role_policy_attachment.cluster-service,
    aws_cloudwatch_log_group.eks,
  ]
}

data "aws_eks_cluster_auth" "aptos" {
  name = aws_eks_cluster.aptos.name
}

locals {
  pools = {
    utilities = {
      instance_type = var.utility_instance_type
      min_size      = var.utility_instance_min_num
      desired_size  = var.utility_instance_num
      max_size      = var.utility_instance_max_num > 0 ? var.utility_instance_max_num : 2 * var.utility_instance_num
      taint         = false
    }
    validators = {
      instance_type = var.validator_instance_type
      min_size      = var.validator_instance_min_num
      desired_size  = var.validator_instance_num
      max_size      = var.validator_instance_max_num > 0 ? var.validator_instance_max_num : 2 * var.validator_instance_num
      taint         = true
    }
  }
}

resource "aws_launch_template" "nodes" {
  for_each      = local.pools
  name          = "aptos-${local.workspace_name}/${each.key}"
  instance_type = each.value.instance_type
  user_data = base64encode(
    templatefile("${path.module}/templates/eks_user_data.sh", {
      taints = each.value.taint ? "aptos.org/nodepool=${each.key}:NoExecute" : ""
    })
  )

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      delete_on_termination = true
      volume_size           = 100
      volume_type           = "gp3"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.default_tags, {
      Name = "aptos-${local.workspace_name}/${each.key}",
    })
  }
}

resource "aws_eks_node_group" "nodes" {
  for_each        = local.pools
  cluster_name    = aws_eks_cluster.aptos.name
  node_group_name = each.key
  version         = aws_eks_cluster.aptos.version
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = [aws_subnet.private[0].id]
  tags            = local.default_tags

  lifecycle {
    ignore_changes = [
      # ignore autoupgrade version
      version,
      # ignore changes to the desired size that may occur due to cluster autoscaler
      scaling_config[0].desired_size,
      # ignore changes to max size, especially when it decreases to < desired_size, which fails
      scaling_config[0].max_size,
    ]
  }

  launch_template {
    id      = aws_launch_template.nodes[each.key].id
    version = aws_launch_template.nodes[each.key].latest_version
  }

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  update_config {
    max_unavailable_percentage = 50
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes-node,
    aws_iam_role_policy_attachment.nodes-cni,
    aws_iam_role_policy_attachment.nodes-ecr,
    kubernetes_config_map.aws-auth,
  ]
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"] # Thumbprint of Root CA for EKS OIDC, Valid until 2037
  url             = aws_eks_cluster.aptos.identity[0].oidc[0].issuer
}

locals {
  oidc_provider = replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")
}
