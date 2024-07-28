
terraform {
  backend "s3" {
    bucket         = "tf-state-bucket-mperetz2"
    key            = "terraform/state"
    region         = "us-east-2"
    dynamodb_table = "terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {}


locals {
  name   = "ex-${basename(path.cwd)}"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  container_name = "ecs-sample"
  container_port = 8000

  tags = {
    Name       = local.name
    Example    = local.name
    Repository = "https://github.com/terraform-aws-modules/terraform-aws-ecs"
  }
}

resource "aws_iam_role" "ecs_instance_role" {
  name = "ecsInstanceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance_role_policy_attachment" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role" "ecs_role" {
  name = "ecsRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_role_policy_attachment" {
  role       = aws_iam_role.ecs_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole"
}

data "aws_iam_policy" "ecs_task_execution_role_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "${data.aws_iam_policy.ecs_task_execution_role_policy.arn}"
}


resource "aws_iam_role" "ecs_auto_scailing_role" {
  name = "ecsAutoScalingRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_auto_scailing_attachment" {
  role       = aws_iam_role.ecs_auto_scailing_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceAutoscaleRole"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "ecs-mperetz-vpc"
  cidr = "172.16.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets  = ["172.16.1.0/24", "172.16.0.0/24"]

  create_igw = true
  map_public_ip_on_launch = true
  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}


module "ecs_ec2_cluster" {
  source = "terraform-aws-modules/ecs/aws"

  cluster_name = local.name

  # Capacity provider - autoscaling groups
  default_capacity_provider_use_fargate = false
  autoscaling_capacity_providers = {
    # On-demand instances
    ex_1 = {
      auto_scaling_group_arn         = module.autoscaling["ex_1"].autoscaling_group_arn

      managed_scaling = {
        maximum_scaling_step_size = 2
        minimum_scaling_step_size = 1
        status                    = "ENABLED"
      }
    }
  }

  services = {
    simplehttp = {
      # Task Definition

      cpu       = 512
      memory    = 1024
      requires_compatibilities = ["EC2"]
      capacity_provider_strategy = {
        # On-demand instances
        ex_1 = {
          capacity_provider = module.ecs_ec2_cluster.autoscaling_capacity_providers["ex_1"].name
          weight            = 1
          base              = 1
        }
      }

      network_mode = "bridge"


      # Container definition(s)
      container_definitions = {
        (local.container_name) = {
          cpu       = 512
          memory    = 1024
          image = "gkoenig/simplehttp"
          port_mappings = [
            {
              name          = local.container_name
              containerPort = 8000
              protocol      = "tcp"
            }
          ]


          # Example image used requires access to write to root filesystem
          readonly_root_filesystem = false

          enable_cloudwatch_logging              = true
          create_cloudwatch_log_group            = true
          cloudwatch_log_group_name              = "/aws/ecs/${local.name}/${local.container_name}"
          cloudwatch_log_group_retention_in_days = 7

          log_configuration = {
            logDriver = "awslogs"
          }
        }
      }

      load_balancer = {
        service = {
          target_group_arn = module.alb.target_groups["ecs_ec2"].arn
          container_name   = local.container_name
          container_port   = local.container_port
        }
      }

      subnet_ids = module.vpc.public_subnets
      security_group_rules = {
        alb_http_ingress = {
          type                     = "ingress"
          from_port                = 0
          to_port                  = 0
          protocol                 = "tcp"
          description              = "Service port"
          source_security_group_id = module.alb.security_group_id
        }
      }
    }
  }

  tags = local.tags
}



################################################################################
# Supporting Resources
################################################################################

# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html#ecs-optimized-ami-linux
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"

  name = local.name

  load_balancer_type = "application"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  listeners = {
    ex_http = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = "ecs_ec2"
      }

      rules = {
        forward_ec2 = {
          priority = 1
          actions = [{
              type             = "forward"
              target_group_key = "ecs_ec2"
          }]

          conditions = [{
            path_pattern = {
              values = ["/ec2/*"]
            }
          }]
        }

        forward_fargate = {
          priority = 2
          actions = [{
              type             = "forward"
              target_group_key = "ecs_fargate"
          }]

          conditions = [{
            path_pattern = {
              values = ["/fargate/*"]
            }
          }]
        }
      }
    }
  }

  target_groups = {
    ecs_ec2 = {
      backend_protocol                  = "HTTP"
      backend_port                      = 80
      target_type                       = "instance"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 2
        interval            = 6
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # Theres nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }

    ecs_fargate = {
      backend_protocol                  = "HTTP"
      backend_port                      = local.container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 2
        interval            = 6
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # Theres nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }
  }

}

# resource "aws_lb_target_group_attachment" "ex-terraform" {
#   for_each = {for k,v in module.ec2_example: k => v}

#   target_group_arn = module.alb.target_groups["ecs_ec2"].arn
#   target_id        = each.value.id
#   port             = 80
# }

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"

  min_size            = 1
  max_size            = 2
  desired_capacity    = 1

  for_each = {
    # On-demand instances
    ex_1 = {
      instance_type              = "t3.small"
      user_data                  = <<-EOT
        #!/bin/bash
        echo ECS_CLUSTER=${local.name} >> /etc/ecs/ecs.config;
      EOT
    }
  }

  name = "${local.name}-${each.key}"

  image_id      = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]
  instance_type = each.value.instance_type

  security_groups                 = [module.autoscaling_sg.security_group_id]
  user_data                       = base64encode(each.value.user_data)
  ignore_desired_capacity_changes = true

  create_iam_instance_profile = true # Instance profile is the way you attach the role to the EC2 instance
  #iam_instance_profile_name   = aws_iam_role.ecs_instance_role.name
  iam_role_name               = local.name
  iam_role_description        = "ECS role for ${local.name}"
  iam_role_policies = {
    AmazonEC2ContainerServiceforEC2Role = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    AmazonSSMManagedInstanceCore        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  vpc_zone_identifier = module.vpc.public_subnets
  health_check_type   = "EC2"

  # https://github.com/hashicorp/terraform-provider-aws/issues/12582
  autoscaling_group_tags = {
    AmazonECSManaged = ""
  }

  # Required for  managed_termination_protection = "ENABLED"
  # protect_from_scale_in = true
  target_group_arns = [module.alb.target_groups["ecs_ec2"].arn]
  tags = local.tags
}

module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"

  name        = local.name
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id


  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "all-tcp"
      source_security_group_id = module.alb.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1

  egress_rules = ["all-all"]

  
  tags = local.tags
}