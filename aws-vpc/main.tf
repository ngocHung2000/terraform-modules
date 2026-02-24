locals {
  len_public_subnets      = max(length(var.public_subnets), length(var.public_subnet_ipv6_prefixes))
  len_private_subnets     = max(length(var.private_subnets), length(var.private_subnet_ipv6_prefixes))
  len_container_subnets    = max(length(var.container_subnets), length(var.container_subnet_ipv6_prefixes))
  
  max_subnet_length = max(
    local.len_private_subnets,
    local.len_public_subnets,
    local.len_container_subnets
  )

  # Use `local.vpc_id` to give a hint to Terraform that subnets should be deleted before secondary CIDR blocks can be free!
  vpc_id = try(aws_vpc_ipv4_cidr_block_association.this[0].vpc_id, aws_vpc.this[0].id, "")

  create_vpc = var.create_vpc && var.putin_khuylo
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "this" {
  count = local.create_vpc ? 1 : 0

  region = var.region

  cidr_block          = var.use_ipam_pool ? null : var.cidr
  ipv4_ipam_pool_id   = var.ipv4_ipam_pool_id
  ipv4_netmask_length = var.ipv4_netmask_length

  assign_generated_ipv6_cidr_block     = var.enable_ipv6 && !var.use_ipam_pool ? true : null
  ipv6_cidr_block                      = var.ipv6_cidr
  ipv6_ipam_pool_id                    = var.ipv6_ipam_pool_id
  ipv6_netmask_length                  = var.ipv6_netmask_length
  ipv6_cidr_block_network_border_group = var.ipv6_cidr_block_network_border_group

  instance_tenancy                     = var.instance_tenancy
  enable_dns_hostnames                 = var.enable_dns_hostnames
  enable_dns_support                   = var.enable_dns_support
  enable_network_address_usage_metrics = var.enable_network_address_usage_metrics

  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.vpc_tags,
  )
}

resource "aws_vpc_ipv4_cidr_block_association" "this" {
  count = local.create_vpc && length(var.secondary_cidr_blocks) > 0 ? length(var.secondary_cidr_blocks) : 0

  region = var.region

  # Do not turn this into `local.vpc_id`
  vpc_id = aws_vpc.this[0].id

  cidr_block = element(var.secondary_cidr_blocks, count.index)
}

resource "aws_vpc_block_public_access_options" "this" {
  count = local.create_vpc && length(keys(var.vpc_block_public_access_options)) > 0 ? 1 : 0

  region = var.region

  internet_gateway_block_mode = try(var.vpc_block_public_access_options["internet_gateway_block_mode"], null)
}

resource "aws_vpc_block_public_access_exclusion" "this" {
  for_each = { for k, v in var.vpc_block_public_access_exclusions : k => v if local.create_vpc }

  region = var.region

  vpc_id = try(each.value.exclude_vpc, false) ? local.vpc_id : null

  subnet_id = try(each.value.exclude_subnet, false) ? lookup(
    {
      private     = aws_subnet.private[*].id,
      public      = aws_subnet.public[*].id,
      container    = aws_subnet.container[*].id,
      redshift    = aws_subnet.redshift[*].id,
      elasticache = aws_subnet.elasticache[*].id,
      intra       = aws_subnet.intra[*].id,
      outpost     = aws_subnet.outpost[*].id
    },
    each.value.subnet_type,
    null
  )[each.value.subnet_index] : null

  internet_gateway_exclusion_mode = each.value.internet_gateway_exclusion_mode

  tags = merge(
    var.tags,
    try(each.value.tags, {}),
  )
}

################################################################################
# DHCP Options Set
################################################################################

resource "aws_vpc_dhcp_options" "this" {
  count = local.create_vpc && var.enable_dhcp_options ? 1 : 0

  region = var.region

  domain_name                       = var.dhcp_options_domain_name
  domain_name_servers               = var.dhcp_options_domain_name_servers
  ntp_servers                       = var.dhcp_options_ntp_servers
  netbios_name_servers              = var.dhcp_options_netbios_name_servers
  netbios_node_type                 = var.dhcp_options_netbios_node_type
  ipv6_address_preferred_lease_time = var.dhcp_options_ipv6_address_preferred_lease_time

  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.dhcp_options_tags,
  )
}

resource "aws_vpc_dhcp_options_association" "this" {
  count = local.create_vpc && var.enable_dhcp_options ? 1 : 0

  region = var.region

  vpc_id          = local.vpc_id
  dhcp_options_id = aws_vpc_dhcp_options.this[0].id
}

################################################################################
# Public Subnets
################################################################################

locals {
  create_public_subnets = local.create_vpc && local.len_public_subnets > 0

  num_public_route_tables = var.create_multiple_public_route_tables ? local.len_public_subnets : 1
}

resource "aws_subnet" "public" {
  count = local.create_public_subnets && (!var.one_nat_gateway_per_az || local.len_public_subnets >= length(var.azs)) ? local.len_public_subnets : 0

  region = var.region

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.public_subnet_ipv6_native ? true : var.public_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.public_subnet_ipv6_native ? null : element(concat(var.public_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.public_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.public_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.public_subnet_ipv6_native && var.public_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.public_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.public_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.public_subnet_ipv6_native
  map_public_ip_on_launch                        = var.map_public_ip_on_launch
  private_dns_hostname_type_on_launch            = var.public_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.public_subnet_names[count.index],
        format("${var.name}-${var.public_subnet_suffix}-%s", element(var.azs, count.index))
      )
    },
    var.tags,
    var.public_subnet_tags,
    lookup(var.public_subnet_tags_per_az, element(var.azs, count.index), {})
  )
}

resource "aws_route_table" "public" {
  count = local.create_public_subnets ? local.num_public_route_tables : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = var.create_multiple_public_route_tables ? format(
        "${var.name}-${var.public_subnet_suffix}-%s",
        element(var.azs, count.index),
      ) : "${var.name}-${var.public_subnet_suffix}"
    },
    var.tags,
    var.public_route_table_tags,
  )
}

resource "aws_route_table_association" "public" {
  count = local.create_public_subnets ? local.len_public_subnets : 0

  region = var.region

  subnet_id      = element(aws_subnet.public[*].id, count.index)
  route_table_id = element(aws_route_table.public[*].id, var.create_multiple_public_route_tables ? count.index : 0)
}

resource "aws_route" "public_internet_gateway" {
  count = local.create_public_subnets && var.create_igw ? local.num_public_route_tables : 0

  region = var.region

  route_table_id         = aws_route_table.public[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "public_internet_gateway_ipv6" {
  count = local.create_public_subnets && var.create_igw && var.enable_ipv6 ? local.num_public_route_tables : 0

  region = var.region

  route_table_id              = aws_route_table.public[count.index].id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.this[0].id
}

################################################################################
# Public Network ACLs
################################################################################

resource "aws_network_acl" "public" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? 1 : 0

  region = var.region

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.public[*].id

  tags = merge(
    { "Name" = "${var.name}-${var.public_subnet_suffix}" },
    var.tags,
    var.public_acl_tags,
  )
}

resource "aws_network_acl_rule" "public_inbound" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? length(var.public_inbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.public[0].id

  egress          = false
  rule_number     = var.public_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.public_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "public_outbound" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? length(var.public_outbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.public[0].id

  egress          = true
  rule_number     = var.public_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.public_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

################################################################################
# Private Subnets
################################################################################

locals {
  create_private_subnets = local.create_vpc && local.len_private_subnets > 0
}

resource "aws_subnet" "private" {
  count = local.create_private_subnets ? local.len_private_subnets : 0

  region = var.region

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.private_subnet_ipv6_native ? true : var.private_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.private_subnet_ipv6_native ? null : element(concat(var.private_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.private_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.private_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.private_subnet_ipv6_native && var.private_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.private_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.private_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.private_subnet_ipv6_native
  private_dns_hostname_type_on_launch            = var.private_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.private_subnet_names[count.index],
        format("${var.name}-${var.private_subnet_suffix}-%s", element(var.azs, count.index))
      )
    },
    var.tags,
    var.private_subnet_tags,
    lookup(var.private_subnet_tags_per_az, element(var.azs, count.index), {})
  )
}

# There are as many routing tables as the number of NAT gateways
resource "aws_route_table" "private" {
  count = local.create_private_subnets && local.max_subnet_length > 0 ? local.nat_gateway_count : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = var.single_nat_gateway ? "${var.name}-${var.private_subnet_suffix}" : format(
        "${var.name}-${var.private_subnet_suffix}-%s",
        element(var.azs, count.index),
      )
    },
    var.tags,
    var.private_route_table_tags,
  )
}

resource "aws_route_table_association" "private" {
  count = local.create_private_subnets ? local.len_private_subnets : 0

  region = var.region

  subnet_id = element(aws_subnet.private[*].id, count.index)
  route_table_id = element(
    aws_route_table.private[*].id,
    var.single_nat_gateway ? 0 : count.index,
  )
}

################################################################################
# Private Network ACLs
################################################################################

locals {
  create_private_network_acl = local.create_private_subnets && var.private_dedicated_network_acl
}

resource "aws_network_acl" "private" {
  count = local.create_private_network_acl ? 1 : 0

  region = var.region

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.private[*].id

  tags = merge(
    { "Name" = "${var.name}-${var.private_subnet_suffix}" },
    var.tags,
    var.private_acl_tags,
  )
}

resource "aws_network_acl_rule" "private_inbound" {
  count = local.create_private_network_acl ? length(var.private_inbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.private[0].id

  egress          = false
  rule_number     = var.private_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "private_outbound" {
  count = local.create_private_network_acl ? length(var.private_outbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.private[0].id

  egress          = true
  rule_number     = var.private_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

################################################################################
# container Subnets
################################################################################

locals {
  create_container_subnets     = local.create_vpc && local.len_container_subnets > 0
  create_container_route_table = local.create_container_subnets && var.create_container_subnet_route_table
}

resource "aws_subnet" "container" {
  count = local.create_container_subnets ? local.len_container_subnets : 0

  region = var.region

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.container_subnet_ipv6_native ? true : var.container_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.container_subnet_ipv6_native ? null : element(concat(var.container_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.container_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.container_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.container_subnet_ipv6_native && var.container_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.container_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.container_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.container_subnet_ipv6_native
  private_dns_hostname_type_on_launch            = var.container_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.container_subnet_names[count.index],
        format("${var.name}-${var.container_subnet_suffix}-%s", element(var.azs, count.index), )
      )
    },
    var.tags,
    var.container_subnet_tags,
  )
}

resource "aws_db_subnet_group" "container" {
  count = local.create_container_subnets && var.create_container_subnet_group ? 1 : 0

  region = var.region

  name        = lower(coalesce(var.container_subnet_group_name, var.name))
  description = "container subnet group for ${var.name}"
  subnet_ids  = aws_subnet.container[*].id

  tags = merge(
    {
      "Name" = lower(coalesce(var.container_subnet_group_name, var.name))
    },
    var.tags,
    var.container_subnet_group_tags,
  )
}

resource "aws_route_table" "container" {
  count = local.create_container_route_table ? var.single_nat_gateway || var.create_container_internet_gateway_route ? 1 : local.len_container_subnets : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = var.single_nat_gateway || var.create_container_internet_gateway_route ? "${var.name}-${var.container_subnet_suffix}" : format(
        "${var.name}-${var.container_subnet_suffix}-%s",
        element(var.azs, count.index),
      )
    },
    var.tags,
    var.container_route_table_tags,
  )
}

resource "aws_route_table_association" "container" {
  count = local.create_container_subnets ? local.len_container_subnets : 0

  region = var.region

  subnet_id = element(aws_subnet.container[*].id, count.index)
  route_table_id = element(
    coalescelist(aws_route_table.container[*].id, aws_route_table.private[*].id),
    var.create_container_subnet_route_table ? var.single_nat_gateway || var.create_container_internet_gateway_route ? 0 : count.index : count.index,
  )
}

resource "aws_route" "container_internet_gateway" {
  count = local.create_container_route_table && var.create_igw && var.create_container_internet_gateway_route && !var.create_container_nat_gateway_route ? 1 : 0

  region = var.region

  route_table_id         = aws_route_table.container[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "container_nat_gateway" {
  count = local.create_container_route_table && !var.create_container_internet_gateway_route && var.create_container_nat_gateway_route && var.enable_nat_gateway ? var.single_nat_gateway ? 1 : local.len_container_subnets : 0

  region = var.region

  route_table_id         = element(aws_route_table.container[*].id, count.index)
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = element(aws_nat_gateway.this[*].id, count.index)

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "container_dns64_nat_gateway" {
  count = local.create_container_route_table && !var.create_container_internet_gateway_route && var.create_container_nat_gateway_route && var.enable_nat_gateway && var.enable_ipv6 && var.private_subnet_enable_dns64 ? var.single_nat_gateway ? 1 : local.len_container_subnets : 0

  region = var.region

  route_table_id              = element(aws_route_table.container[*].id, count.index)
  destination_ipv6_cidr_block = "64:ff9b::/96"
  nat_gateway_id              = element(aws_nat_gateway.this[*].id, count.index)

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "container_ipv6_egress" {
  count = local.create_container_route_table && var.create_egress_only_igw && var.enable_ipv6 && var.create_container_internet_gateway_route ? 1 : 0

  region = var.region

  route_table_id              = aws_route_table.container[0].id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.this[0].id

  timeouts {
    create = "5m"
  }
}

################################################################################
# container Network ACLs
################################################################################

locals {
  create_container_network_acl = local.create_container_subnets && var.container_dedicated_network_acl
}

resource "aws_network_acl" "container" {
  count = local.create_container_network_acl ? 1 : 0

  region = var.region

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.container[*].id

  tags = merge(
    { "Name" = "${var.name}-${var.container_subnet_suffix}" },
    var.tags,
    var.container_acl_tags,
  )
}

resource "aws_network_acl_rule" "container_inbound" {
  count = local.create_container_network_acl ? length(var.container_inbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.container[0].id

  egress          = false
  rule_number     = var.container_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.container_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.container_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.container_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.container_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.container_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.container_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.container_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.container_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "container_outbound" {
  count = local.create_container_network_acl ? length(var.container_outbound_acl_rules) : 0

  region = var.region

  network_acl_id = aws_network_acl.container[0].id

  egress          = true
  rule_number     = var.container_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.container_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.container_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.container_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.container_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.container_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.container_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.container_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.container_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

################################################################################
# Internet Gateway
################################################################################

resource "aws_internet_gateway" "this" {
  count = local.create_public_subnets && var.create_igw ? 1 : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.igw_tags,
  )
}

resource "aws_egress_only_internet_gateway" "this" {
  count = local.create_vpc && var.create_egress_only_igw && var.enable_ipv6 && local.max_subnet_length > 0 ? 1 : 0

  region = var.region

  vpc_id = local.vpc_id

  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.igw_tags,
  )
}

resource "aws_route" "private_ipv6_egress" {
  count = local.create_vpc && var.create_egress_only_igw && var.enable_ipv6 && local.len_private_subnets > 0 ? local.nat_gateway_count : 0

  region = var.region

  route_table_id              = element(aws_route_table.private[*].id, count.index)
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = element(aws_egress_only_internet_gateway.this[*].id, 0)
}

################################################################################
# NAT Gateway
################################################################################

locals {
  nat_gateway_count = var.single_nat_gateway ? 1 : var.one_nat_gateway_per_az ? length(var.azs) : local.max_subnet_length
  nat_gateway_ips   = var.reuse_nat_ips ? var.external_nat_ip_ids : aws_eip.nat[*].id
}

resource "aws_eip" "nat" {
  count = local.create_vpc && var.enable_nat_gateway && !var.reuse_nat_ips ? local.nat_gateway_count : 0

  region = var.region

  domain = "vpc"

  tags = merge(
    {
      "Name" = format(
        "${var.name}-%s",
        element(var.azs, var.single_nat_gateway ? 0 : count.index),
      )
    },
    var.tags,
    var.nat_eip_tags,
  )

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.create_vpc && var.enable_nat_gateway ? local.nat_gateway_count : 0

  region = var.region

  allocation_id = element(
    local.nat_gateway_ips,
    var.single_nat_gateway ? 0 : count.index,
  )
  subnet_id = element(
    aws_subnet.public[*].id,
    var.single_nat_gateway ? 0 : count.index,
  )

  tags = merge(
    {
      "Name" = format(
        "${var.name}-%s",
        element(var.azs, var.single_nat_gateway ? 0 : count.index),
      )
    },
    var.tags,
    var.nat_gateway_tags,
  )

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_nat_gateway" {
  count = local.create_vpc && var.enable_nat_gateway && var.create_private_nat_gateway_route ? local.nat_gateway_count : 0

  region = var.region

  route_table_id         = element(aws_route_table.private[*].id, count.index)
  destination_cidr_block = var.nat_gateway_destination_cidr_block
  nat_gateway_id         = element(aws_nat_gateway.this[*].id, count.index)

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "private_dns64_nat_gateway" {
  count = local.create_vpc && var.enable_nat_gateway && var.enable_ipv6 && var.private_subnet_enable_dns64 ? local.nat_gateway_count : 0

  region = var.region

  route_table_id              = element(aws_route_table.private[*].id, count.index)
  destination_ipv6_cidr_block = "64:ff9b::/96"
  nat_gateway_id              = element(aws_nat_gateway.this[*].id, count.index)

  timeouts {
    create = "5m"
  }
}

################################################################################
# Customer Gateways
################################################################################

resource "aws_customer_gateway" "this" {
  for_each = var.customer_gateways

  region = var.region

  bgp_asn          = lookup(each.value, "bgp_asn", null)
  bgp_asn_extended = lookup(each.value, "bgp_asn_extended", null)
  ip_address       = each.value["ip_address"]
  device_name      = lookup(each.value, "device_name", null)
  type             = "ipsec.1"

  tags = merge(
    { Name = "${var.name}-${each.key}" },
    var.tags,
    var.customer_gateway_tags,
  )

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# VPN Gateway
################################################################################

resource "aws_vpn_gateway" "this" {
  count = local.create_vpc && var.enable_vpn_gateway ? 1 : 0

  region = var.region

  vpc_id            = local.vpc_id
  amazon_side_asn   = var.amazon_side_asn
  availability_zone = var.vpn_gateway_az

  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.vpn_gateway_tags,
  )
}

resource "aws_vpn_gateway_attachment" "this" {
  count = var.vpn_gateway_id != "" ? 1 : 0

  region = var.region

  vpc_id         = local.vpc_id
  vpn_gateway_id = var.vpn_gateway_id
}

resource "aws_vpn_gateway_route_propagation" "public" {
  count = local.create_vpc && var.propagate_public_route_tables_vgw && (var.enable_vpn_gateway || var.vpn_gateway_id != "") ? 1 : 0

  region = var.region

  route_table_id = element(aws_route_table.public[*].id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this[*].id,
      aws_vpn_gateway_attachment.this[*].vpn_gateway_id,
    ),
    count.index,
  )
}

resource "aws_vpn_gateway_route_propagation" "private" {
  count = local.create_vpc && var.propagate_private_route_tables_vgw && (var.enable_vpn_gateway || var.vpn_gateway_id != "") ? local.len_private_subnets : 0

  region = var.region

  route_table_id = element(aws_route_table.private[*].id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this[*].id,
      aws_vpn_gateway_attachment.this[*].vpn_gateway_id,
    ),
    count.index,
  )
}

resource "aws_vpn_gateway_route_propagation" "intra" {
  count = local.create_vpc && var.propagate_intra_route_tables_vgw && (var.enable_vpn_gateway || var.vpn_gateway_id != "") ? local.len_intra_subnets : 0

  region = var.region

  route_table_id = element(aws_route_table.intra[*].id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this[*].id,
      aws_vpn_gateway_attachment.this[*].vpn_gateway_id,
    ),
    count.index,
  )
}