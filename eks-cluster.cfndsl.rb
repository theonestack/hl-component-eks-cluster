CloudFormation do

  Condition('KeyNameSet', FnNot(FnEquals(Ref('KeyName'), '')))
  Condition("SpotEnabled", FnNot(FnEquals(Ref('SpotPrice'), '')))

  tags = []
  extra_tags = external_parameters.fetch(:extra_tags, {})
  extra_tags.each { |key,value| tags << { Key: key, Value: FnSub(value) } }

  IAM_Role(:EksClusterRole) {
    AssumeRolePolicyDocument service_assume_role_policy('eks')
    Path '/'
    ManagedPolicyArns([
      'arn:aws:iam::aws:policy/AmazonEKSServicePolicy',
      'arn:aws:iam::aws:policy/AmazonEKSClusterPolicy'
    ])
  }

  fargate_profiles = external_parameters.fetch(:fargate_profiles, [])

  IAM_Role(:PodExecutionRoleArn) {
    AssumeRolePolicyDocument service_assume_role_policy('eks-fargate-pods')
    Path '/'
    ManagedPolicyArns([
      'arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy'
    ])
  } unless fargate_profiles == []

  fargate_profiles.each do |profile|
    name = profile['name'].gsub('-','').gsub('_','').capitalize
    unless profile.has_key?('selectors')
      raise ArgumentError, "Selectors must be defined for fargate profiles"
    end
    Condition("#{name}FargateProfileNameSet", FnNot(FnEquals(Ref("#{name}FargateProfileName"), '')))
    Resource("#{name}FargateProfile") do
      Type 'AWS::EKS::FargateProfile'
      Property('ClusterName', Ref(:EksCluster))
      Property('FargateProfileName',
        FnIf("#{name}FargateProfileNameSet",
            Ref("#{name}FargateProfileName"),
            FnSub("${EnvironmentName}-#{name}-fargate-profile"))
      )
      Property('PodExecutionRoleArn', FnGetAtt(:PodExecutionRoleArn, :Arn))
      Property('Subnets', FnSplit(',', Ref('SubnetIds')))
      Property('Tags', [{ Key: 'Name', Value: FnSub("${EnvironmentName}-#{name}-fargate-profile")}] + tags)
      Property('Selectors', profile['selectors'])
    end
  end

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

  cluster_name = external_parameters.fetch(:cluster_name, '')
  eks_version = external_parameters.fetch(:eks_version, nil)
  EKS_Cluster(:EksCluster) {
    Name FnSub(cluster_name) unless cluster_name.empty?
    ResourcesVpcConfig({
      SecurityGroupIds: [ Ref(:EksClusterSecurityGroup) ],
      SubnetIds: FnSplit(',', Ref('SubnetIds'))
    })
    RoleArn FnGetAtt(:EksClusterRole, :Arn)
    Version eks_version unless eks_version.nil?
  }

  iam = external_parameters[:iam]
  IAM_Role(:EksNodeRole) {
    AssumeRolePolicyDocument service_assume_role_policy(iam['services'])
    Path '/'
    ManagedPolicyArns(iam['managed_policies'])
    Policies(iam_role_policies(iam['policies'])) if iam.has_key?('policies')
  }

  IAM_InstanceProfile(:EksNodeInstanceProfile) do
    Path '/'
    Roles [Ref(:EksNodeRole)]
  end

  managed_node_group = external_parameters.fetch(:managed_node_group, {})
  managed_node_group_use_launch_template = managed_node_group['launch_template'] ? managed_node_group['launch_template'] : false
  if !managed_node_group['enabled'] || managed_node_group_use_launch_template
    # Setup userdata string
    node_userdata = "#!/bin/bash\nset -o xtrace\n"
    node_userdata << external_parameters.fetch(:eks_bootstrap, '')
    node_userdata << userdata = external_parameters.fetch(:userdata, '')
    node_userdata << cfnsignal = external_parameters.fetch(:cfnsignal, '')

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
  
    spot = external_parameters.fetch(:spot, {})
    unless spot.empty?
      spot_options = {
        MarketType: 'spot',
        SpotOptions: {
          SpotInstanceType: (defined?(spot['type']) ? spot['type'] : 'one-time'),
          MaxPrice: FnSub(spot['price'])
        }
      }
      template_data[:InstanceMarketOptions] = FnIf('SpotEnabled', spot_options, Ref('AWS::NoValue'))

    end

    # Remove options that are not allowed with node groups if we specify our own launch template
    # https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-eks-nodegroup-launchtemplatespecification.html
    [:InstanceMarketOptions, :IamInstanceProfile].each  {|k| template_data.delete(k) if template_data.has_key?(k)} if managed_node_group_use_launch_template

    EC2_LaunchTemplate(:EksNodeLaunchTemplate) {
      LaunchTemplateData(template_data)
    }
  end

  if managed_node_group['enabled']
    node_group_tags = [{ Key: 'Name', Value: FnSub("${EnvironmentName}-eks-managed-node-group")}] + tags
    Condition("InstancesSpecified", FnNot(FnEquals(Ref('InstanceTypes'), '')))
    Resource(:ManagedNodeGroup) do
      Type 'AWS::EKS::Nodegroup'
      Property('ClusterName', Ref(:EksCluster))
      Property('NodegroupName', FnSub(managed_node_group['name'])) if managed_node_group.has_key?('name')
      Property('NodeRole', FnGetAtt(:EksNodeRole, :Arn))
      Property('Subnets', FnSplit(',', Ref('SubnetIds')))
      Property('Tags', Hash[node_group_tags.collect {|obj| [obj[:Key], obj[:Value]]}])
      Property('DiskSize', managed_node_group['disk_size']) if managed_node_group.has_key?('disk_size') && !managed_node_group_use_launch_template
      Property('LaunchTemplate', {
        Id: Ref(:EksNodeLaunchTemplate),
        Version: FnGetAtt(:EksNodeLaunchTemplate, :LatestVersionNumber)
      }) if managed_node_group_use_launch_template
      Property('ForceUpdateEnabled', Ref(:ForceUpdateEnabled))
      Property('InstanceTypes', FnIf('InstancesSpecified', Ref('InstanceTypes'), Ref('AWS::NoValue'))) #Default is t3.medium
      Property('ScalingConfig', {
        DesiredSize: Ref('DesiredCapacity'),
        MinSize: Ref('MinSize'),
        MaxSize: Ref('MaxSize')
      })
      Property('Labels', managed_node_group['labels']) if managed_node_group.has_key?('labels')
    end
  else

    AutoScaling_LifecycleHook(:DrainingLifecycleHook) {
      AutoScalingGroupName Ref('EksNodeAutoScalingGroup')
      HeartbeatTimeout 450
      LifecycleTransition 'autoscaling:EC2_INSTANCE_TERMINATING'
    }

    Lambda_Permission(:DrainingLambdaPermission) {
      Action 'lambda:InvokeFunction'
      FunctionName FnGetAtt('Drainer', 'Arn')
      Principal 'events.amazonaws.com'
      SourceArn FnGetAtt('LifecycleEvent', 'Arn')
    }

    draining_lambda = external_parameters[:draining_lambda]
    Events_Rule(:LifecycleEvent) {
      Description FnSub("Rule for ${EnvironmentName} eks draining lifecycle hook")
      State 'ENABLED'
      EventPattern draining_lambda['event']['pattern']
      Targets draining_lambda['event']['targets']
    }

    Output(:DrainingLambdaRole) {
      Value(FnGetAtt(:LambdaRoleDraining, :Arn))
      Export FnSub("${EnvironmentName}-#{external_parameters[:component_name]}-DrainingLambdaRole")
    }

    asg_tags = [
      { Key: FnSub("k8s.io/cluster/${EksCluster}"), Value: 'owned' },
      { Key: 'k8s.io/cluster-autoscaler/enabled', Value: Ref('EnableScaling') }
    ]
    asg_tags = tags.clone.map(&:clone).concat(asg_tags).uniq.each {|tag| tag[:PropagateAtLaunch] = false }
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
      VPCZoneIdentifiers FnSplit(',', Ref('SubnetIds'))
      LaunchTemplate({
        LaunchTemplateId: Ref(:EksNodeLaunchTemplate),
        Version: FnGetAtt(:EksNodeLaunchTemplate, :LatestVersionNumber)
      })
      Tags asg_tags
    }
  end


  Output(:EksNodeSecurityGroup) {
    Value(Ref(:EksNodeSecurityGroup))
  }

  Output(:EksClusterSecurityGroup) {
    Value(Ref(:EksClusterSecurityGroup))
  }

  Output(:EksClusterName) {
    Value(Ref(:EksCluster))
  }

  Output(:EksNodeRole) {
    Value(FnGetAtt(:EksNodeRole, :Arn))
    Export FnSub("${EnvironmentName}-#{external_parameters[:component_name]}-EksNodeRole")
  }

end
