# eks-cluster CfHighlander component

## Parameters

| Name | Use | Default | Global | Type | Allowed Values |
| ---- | --- | ------- | ------ | ---- | -------------- |
| EnvironmentName | Tagging | dev | true | string
| EnvironmentType | Tagging | development | true | string | ['development','production']
| AvailabilityZones | Number of AZs to deploy to | 1 | true | int | [1,2,3]
| VPCId | Id of the vpc required for creating a target group and security group | - | false | AWS::EC2::VPC::Id
| SubnetIds | list of subnet ids to run your tasks in if using aws-vpc networking | - | false | comma delimited string
| BootstrapArguments | Any additional arguments to be passed to the boostrap script | None | false | string
| KeyName | The key name to give access to the cluster | None | false | string
| ImageId | The AMI ID to use | None | false | AWS::EC2::Image::Id
| InstanceType | The instance type to deploy | None | false | string
| SpotPrice | The maximum spot price to pay | None | false | string
| EnableScaling | Whether to enable autoscaling | true | false | string | ['true','false']
| DesiredCapacity | The desired ASG capacity | 1 | false | string
| MinSize | The minimum ASG capacity | 1 | false | string
| MaxSize | The maximum ASG capacity | 2 | false | string

## Outputs/Exports

| Name | Value | Exported |
| ---- | ----- | -------- |
| EksNodeSecurityGroup | The security group of the EKS cluster | false
| EksClusterName | The full generated name of the cluster | false
| DrainingLambdaRole | The role used by the draining_lambda | false
| EksNodeRole | The role used by the EKS nodes | false

## Included Components

[lib-ec2](https://github.com/theonestack/hl-component-lib-ec2)
## Example Configuration
### Highlander
```
  Component name: 'eks', template: 'eks-cluster' do
    parameter name: 'VPCId', value: cfout('vpc', 'VPCId')
    parameter name: 'SubnetIds', value: cfout('vpc', 'ComputeSubnets')
    parameter name: 'InstanceType', value: cfmap('EnvironmentName', Ref('EnvironmentName'), 'EksInstanceType')
    parameter name: 'MinSize', value: '3'
    parameter name: 'MaxSize', value: '9'
    parameter name: 'DesiredCapacity', value: '3'
  end

```

### EKS Configuration
```
cluster_name: ${EnvironmentName}-eks-cluster
eks_version: 1.21
volume_size: 100

eks_bootstrap: |
  /sbin/dhclient
  /etc/eks/bootstrap.sh ${EksCluster} ${BootstrapArguments}
  export HOME=/root
  /opt/base2/bin/ec2-bootstrap ${AWS::Region} ${AWS::AccountId}

extra_tags:
  Environment: ${EnvironmentName}
  EnvironmentType: ${EnvironmentType}
  Role: company-runtime::eks
  Storage: '100'

spot:
  type: one-time
  price: ${SpotPrice}

iam:
  policies:
    ssm-ssh-access:
      action:
        - ssm:UpdateInstanceInformation
        - ssm:ListInstanceAssociations
        - ec2messages:GetMessages
        - ssmmessages:CreateControlChannel
        - ssmmessages:CreateDataChannel
        - ssmmessages:OpenControlChannel
        - ssmmessages:OpenDataChannel
    acm:
      action:
        - acm:DescribeCertificate
        - acm:ListCertificates
        - acm:GetCertificate
    ec2:
      action:
        - ec2:AuthorizeSecurityGroupIngress
        - ec2:CreateSecurityGroup
        - ec2:CreateTags
        - ec2:DeleteTags
        - ec2:DeleteSecurityGroup
        - ec2:DescribeAccountAttributes
        - ec2:DescribeAddresses
        - ec2:DescribeInstances
        - ec2:DescribeInstanceStatus
        - ec2:DescribeInternetGateways
        - ec2:DescribeNetworkInterfaces
        - ec2:DescribeSecurityGroups
        - ec2:DescribeSubnets
        - ec2:DescribeTags
        - ec2:DescribeVpcs
        - ec2:ModifyInstanceAttribute
        - ec2:ModifyNetworkInterfaceAttribute
        - ec2:RevokeSecurityGroupIngress
        - tag:GetResources
        - tag:TagResources
    elb:
      action:
        - elasticloadbalancing:AddListenerCertificates
        - elasticloadbalancing:AddTags
        - elasticloadbalancing:CreateListener
        - elasticloadbalancing:CreateLoadBalancer
        - elasticloadbalancing:CreateRule
        - elasticloadbalancing:CreateTargetGroup
        - elasticloadbalancing:DeleteListener
        - elasticloadbalancing:DeleteLoadBalancer
        - elasticloadbalancing:DeleteRule
        - elasticloadbalancing:DeleteTargetGroup
        - elasticloadbalancing:DeregisterTargets
        - elasticloadbalancing:DescribeListenerCertificates
        - elasticloadbalancing:DescribeListeners
        - elasticloadbalancing:DescribeLoadBalancers
        - elasticloadbalancing:DescribeLoadBalancerAttributes
        - elasticloadbalancing:DescribeRules
        - elasticloadbalancing:DescribeSSLPolicies
        - elasticloadbalancing:DescribeTags
        - elasticloadbalancing:DescribeTargetGroups
        - elasticloadbalancing:DescribeTargetGroupAttributes
        - elasticloadbalancing:DescribeTargetHealth
        - elasticloadbalancing:ModifyListener
        - elasticloadbalancing:ModifyLoadBalancerAttributes
        - elasticloadbalancing:ModifyRule
        - elasticloadbalancing:ModifyTargetGroup
        - elasticloadbalancing:ModifyTargetGroupAttributes
        - elasticloadbalancing:RegisterTargets
        - elasticloadbalancing:RemoveListenerCertificates
        - elasticloadbalancing:RemoveTags
        - elasticloadbalancing:SetIpAddressType
        - elasticloadbalancing:SetSecurityGroups
        - elasticloadbalancing:SetSubnets
        - elasticloadbalancing:SetWebACL
    iam:
      action:
        - iam:CreateServiceLinkedRole
        - iam:GetServerCertificate
        - iam:ListServerCertificates
    waf:
      action:
        - waf-regional:GetWebACLForResource
        - waf-regional:GetWebACL
        - waf-regional:AssociateWebACL
        - waf-regional:DisassociateWebACL
        - waf:GetWebACL
    route53:
      action:
        - route53:ListHostedZones
        - route53:ChangeResourceRecordSets
        - route53:ListResourceRecordSets
    cloudwatch:
      action:
        - logs:DescribeLogGroups
        - logs:DescribeLogStreams
        - logs:CreateLogGroup
        - logs:CreateLogStream
        - logs:PutLogEvents
```

## Cfhighlander Setup

install cfhighlander [gem](https://github.com/theonestack/cfhighlander)

```bash
gem install cfhighlander
```

or via docker

```bash
docker pull theonestack/cfhighlander
```
## Testing Components

Running the tests

```bash
cfhighlander cftest eks-cluster
```