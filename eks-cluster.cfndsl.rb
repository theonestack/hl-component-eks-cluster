CloudFormation do

  Condition('KeyNameSet', FnNot(FnEquals(Ref('KeyName'), '')))
  Condition("SpotEnabled", FnNot(FnEquals(Ref('SpotPrice'), '')))

  tags = []
  extra_tags.each { |key,value| tags << { Key: FnSub(key), Value: FnSub(value) } } if defined? extra_tags

  IAM_Role(:EksClusterRole) {
    AssumeRolePolicyDocument service_role_assume_policy('eks')
    Path '/'
    ManagedPolicyArns([
      'arn:aws:iam::aws:policy/AmazonEKSServicePolicy',
      'arn:aws:iam::aws:policy/AmazonEKSClusterPolicy'
    ])
  }

  EC2_SecurityGroup(:EksClusterSecurityGroup) {
    VpcId Ref('VPCId')
    GroupDescription "EKS Cluster communication with worker nodes"
    Tags([{ Key: 'Name', Value: FnSub("${EnvironmentName}-eks-controller")}] + tags)
    Metadata({
      cfn_nag: {
        rules_to_suppress: [
          { id: 'F1000', reason: 'adding rules using cfn resources' }
        ]
      }
    })
  }

  EC2_SecurityGroup('EksNodeSecurityGroup') {
    VpcId Ref('VPCId')
    GroupDescription "Security group for all nodes in the cluster"
    Tags([
      { Key: 'Name', Value: FnSub("${EnvironmentName}-eks-nodes") },
      { Key: FnSub("kubernetes.io/cluster/${EksCluster}"), Value: 'owned' }
    ] + tags)
    Metadata({
      cfn_nag: {
        rules_to_suppress: [
          { id: 'F1000', reason: 'adding rules using cfn resources' }
        ]
      }
    })
  }

  EC2_SecurityGroupIngress(:NodeSecurityGroupIngress) {
    DependsOn 'EksNodeSecurityGroup'
    Description 'Allow node to communicate with each other'
    GroupId Ref(:EksNodeSecurityGroup)
    SourceSecurityGroupId Ref(:EksNodeSecurityGroup)
    IpProtocol '-1'
    FromPort 0
    ToPort 65535
  }

  EC2_SecurityGroupIngress(:NodeSecurityGroupFromControlPlaneIngress) {
    DependsOn 'EksNodeSecurityGroup'
    Description 'Allow worker Kubelets and pods to receive communication from the cluster control plane'
    GroupId Ref(:EksNodeSecurityGroup)
    SourceSecurityGroupId Ref(:EksClusterSecurityGroup)
    IpProtocol 'tcp'
    FromPort 1025
    ToPort 65535
  }

  EC2_SecurityGroupEgress(:ControlPlaneEgressToNodeSecurityGroup) {
    DependsOn 'EksNodeSecurityGroup'
    Description 'Allow the cluster control plane to communicate with worker Kubelet and pods'
    GroupId Ref(:EksClusterSecurityGroup)
    DestinationSecurityGroupId Ref(:EksNodeSecurityGroup)
    IpProtocol 'tcp'
    FromPort 1025
    ToPort 65535
  }

  EC2_SecurityGroupIngress(:NodeSecurityGroupFromControlPlaneOn443Ingress) {
    DependsOn 'EksNodeSecurityGroup'
    Description 'Allow pods running extension API servers on port 443 to receive communication from cluster control plane'
    GroupId Ref(:EksNodeSecurityGroup)
    SourceSecurityGroupId Ref(:EksClusterSecurityGroup)
    IpProtocol 'tcp'
    FromPort 443
    ToPort 443
  }

  EC2_SecurityGroupEgress(:ControlPlaneEgressToNodeSecurityGroupOn443) {
    DependsOn 'EksNodeSecurityGroup'
    Description 'Allow the cluster control plane to communicate with pods running extension API servers on port 443'
    GroupId Ref(:EksClusterSecurityGroup)
    DestinationSecurityGroupId Ref(:EksNodeSecurityGroup)
    IpProtocol 'tcp'
    FromPort 443
    ToPort 443
  }

  EC2_SecurityGroupIngress(:ClusterControlPlaneSecurityGroupIngress) {
    DependsOn 'EksNodeSecurityGroup'
    Description 'Allow pods to communicate with the cluster API Server'
    GroupId Ref(:EksClusterSecurityGroup)
    SourceSecurityGroupId Ref(:EksNodeSecurityGroup)
    IpProtocol 'tcp'
    ToPort 443
    FromPort 443
  }

  EKS_Cluster(:EksCluster) {
    Name FnSub(cluster_name) if defined? cluster_name
    ResourcesVpcConfig({
      SecurityGroupIds: [ Ref(:EksClusterSecurityGroup) ],
      SubnetIds: FnSplit(',', Ref('SubnetIds'))
    })
    RoleArn FnGetAtt(:EksClusterRole, :Arn)
    Version eks_version if defined? eks_version
  }

  policies = []
  iam['policies'].each do |name,policy|
    policies << iam_policy_allow(name,policy['action'],policy['resource'] || '*')
  end if iam.has_key?('policies')

  IAM_Role(:EksNodeRole) {
    AssumeRolePolicyDocument service_role_assume_policy(iam['services'])
    Path '/'
    ManagedPolicyArns(iam['managed_policies']) if iam.has_key?('managed_policies')
    Policies(policies) if policies.any?
  }

  IAM_InstanceProfile(:EksNodeInstanceProfile) do
    Path '/'
    Roles [Ref(:EksNodeRole)]
  end

  # Setup userdata string
  node_userdata = "#!/bin/bash\nset -o xtrace\n"
  node_userdata << eks_bootstrap if defined? eks_bootstrap
  node_userdata << userdata if defined? userdata
  node_userdata << cfnsignal if defined? cfnsignal

  launch_template_tags = [
    { Key: 'Name', Value: FnSub("${EnvironmentName}-eks-node-xx") },
    { Key: FnSub("kubernetes.io/cluster/${EksCluster}"), Value: 'owned' }
  ]
  launch_template_tags += tags

  template_data = {
      SecurityGroupIds: [ Ref(:EksNodeSecurityGroup) ],
      TagSpecifications: [
        { ResourceType: 'instance', Tags: launch_template_tags },
        { ResourceType: 'volume', Tags: launch_template_tags }
      ],
      UserData: FnBase64(FnSub(node_userdata)),
      IamInstanceProfile: { Name: Ref(:EksNodeInstanceProfile) },
      KeyName: FnIf('KeyNameSet', Ref('KeyName'), Ref('AWS::NoValue')),
      ImageId: Ref('ImageId'),
      Monitoring: { Enabled: detailed_monitoring },
      InstanceType: Ref('InstanceType')
  }

  if defined? spot
    spot_options = {
      MarketType: 'spot',
      SpotOptions: {
        SpotInstanceType: (defined?(spot['type']) ? spot['type'] : 'one-time'),
        MaxPrice: FnSub(spot['price'])
      }
    }
    template_data[:InstanceMarketOptions] = FnIf('SpotEnabled', spot_options, Ref('AWS::NoValue'))

  end

  EC2_LaunchTemplate(:EksNodeLaunchTemplate) {
    LaunchTemplateData(template_data)
  }

  AutoScaling_AutoScalingGroup(:EksNodeAutoScalingGroup) {
    UpdatePolicy(:AutoScalingRollingUpdate, {
      MaxBatchSize: '1',
      MinInstancesInService: FnIf('SpotEnabled', 0, Ref('DesiredCapacity')),
      SuspendProcesses: %w(HealthCheck ReplaceUnhealthy AZRebalance AlarmNotification ScheduledActions),
      PauseTime: 'PT5M'
    })
    DesiredCapacity Ref('DesiredCapacity')
    MinSize Ref('MinSize')
    MaxSize Ref('MaxSize')
    VPCZoneIdentifier FnSplit(',', Ref('SubnetIds'))
    LaunchTemplate({
      LaunchTemplateId: Ref(:EksNodeLaunchTemplate),
      Version: FnGetAtt(:EksNodeLaunchTemplate, :LatestVersionNumber)
    })
  }

end
