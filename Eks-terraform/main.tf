terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  backend "s3" {
    bucket       = "pavan-8277"
    key          = "Prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" { region = "us-east-1" }

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "cluster" {
  name               = "eks-cluster-cloud-pavan"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
}
resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default_vpc" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# EKS does not support control plane subnets in us-east-1e.
data "aws_subnets" "eks_control_plane" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

resource "aws_eks_cluster" "main" {
  name     = "EKS_CLOUD"
  role_arn = aws_iam_role.cluster.arn
  version  = "1.36"
  vpc_config {
    subnet_ids              = data.aws_subnets.eks_control_plane.ids
    endpoint_private_access = false
    endpoint_public_access  = true
  }
  enabled_cluster_log_types = ["api", "audit", "authenticator"]
  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

resource "aws_iam_role" "node" {
  name = "eks-node-group-cloud-pavan"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "Node-cloud"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = data.aws_subnets.default_vpc.ids
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = ["c7i-flex.large"]
  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }
  update_config { max_unavailable = 1 }
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

data "tls_certificate" "cluster_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster_oidc.certificates[0].sha1_fingerprint]
}
data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}
resource "aws_iam_role" "ebs_csi" {
  name               = "eks-ebs-csi-driver-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
}
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn
  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "cluster_version" { value = aws_eks_cluster.main.version }
output "ebs_csi_addon_arn" { value = aws_eks_addon.ebs_csi.arn }




