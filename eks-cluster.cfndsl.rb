CloudFormation do

  Condition('KeyNameSet', FnNot(FnEquals(Ref('KeyName'), '')))
  Condition("SpotEnabled", FnNot(FnEquals(Ref('SpotPrice'), '')))

  tags = []
  extra_tags = external_parameters.fetch(:extra_tags, {})
  extra_tags.each { |key,value| tags << { Key: FnSub(key), Value: FnSub(value) } }

  IAM_Role(:EksClusterRole) {
    AssumeRolePolicyDocument service_assume_role_policy('eks')
    Path '/'
    ManagedPolicyArns([
      'arn:aws:iam::aws:policy/AmazonEKSServicePolicy',
      'arn:aws:iam::aws:policy/AmazonEKSClusterPolicy'
    ])
  }

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

    volumes = []
    volume_size = external_parameters.fetch(:volume_size, nil)

    unless volume_size.nil?
      volumes << {
        DeviceName: '/dev/xvda',
        Ebs: {
          VolumeSize: volume_size
        }
      }
      template_data[:BlockDeviceMappings] = volumes
    end


  EC2_LaunchTemplate(:EksNodeLaunchTemplate) {
    LaunchTemplateData(template_data)
  }

  add_ons = external_parameters.fetch(:add_ons, {})
  add_ons.each do | add_on, config |
    safe_addon_name = add_on.dup.gsub!('-','') || add_on
    EKS_Addon("#{safe_addon_name.capitalize}Addon") {
      AddonName add_on
      AddonVersion config['version']
      ResolveConflicts config['resolve_conflicts'] if config.has_key?('resolve_conflicts')
      ClusterName Ref(:EksCluster)
      Tags tags
    }
  end unless add_ons.empty?

  asg_tags = [
    { Key: FnSub("k8s.io/cluster/${EksCluster}"), Value: 'owned' },
    { Key: 'k8s.io/cluster-autoscaler/enabled', Value: Ref('EnableScaling') }
  ]
  asg_tags = tags.clone.map(&:clone).concat(asg_tags).uniq.each {|tag| tag[:PropagateAtLaunch] = false }
  pause_time = external_parameters.fetch(:pause_time, 'PT5M')
  max_batch_size = external_parameters.fetch(:max_batch_size, '1')
  AutoScaling_AutoScalingGroup(:EksNodeAutoScalingGroup) {
    UpdatePolicy(:AutoScalingRollingUpdate, {
      MaxBatchSize: max_batch_size,
      MinInstancesInService: FnIf('SpotEnabled', 0, Ref('DesiredCapacity')),
      SuspendProcesses: %w(HealthCheck ReplaceUnhealthy AZRebalance AlarmNotification ScheduledActions),
      PauseTime: pause_time
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
  auth_type = external_parameters.fetch(:auth_type, 'STANDARD')
  node_type = external_parameters.fetch(:node_type, 'EC2_LINUX')

  #provides elmer with cluster admin access
  EKS_AccessEntry(:AccessEntryElmerClusterAdmin) {
    Tags ([
      {
        Key: 'simple key',
        Value: 'support'
      }
    ])
    AccessPolicies([
      {
        AccessScope: {
			    Type:'cluster'
			  },
        PolicyArn: 'arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy'
      }
    ])
    ClusterName Ref(:EksCluster)
    KubernetesGroups ['cluster-admin']
    PrincipalArn FnJoin('', ['arn:aws:iam::',Ref('AWS::AccountId'),':role/iamelmer/IAMElmerRole_admin'])
    Type auth_type

  }
  # allow nodes to join the cluster, also provides access to nodes resource (console, api, k8s)
  EKS_AccessEntry(:AccessEntryAdminNode) {
    ClusterName Ref(:EksCluster)
    PrincipalArn FnGetAtt(:EksNodeRole, 'Arn')
    Type node_type
  }

  
  cluster_admin_role_arns = external_parameters.fetch(:cluster_admin_roles, '')

  unless cluster_admin_role_arns.empty?
    # environment_cluster_admin_roles = cluster_admin_role_arns["#{EnvironmentName}"]
    # environment_cluster_admin_roles = cluster_admin_role_arns["dev"]
    external_parameters[:max_cluster_roles].times do | cluster_role|

    # cluster_admin_role_arns.split(",").each_with_index do |cluster_admin_arn, index|
      EKS_AccessEntry("AccessEntryAdmin#{index}") {
        AccessPolicies([
          {
            AccessScope: {
              Type:'cluster'
            },
            PolicyArn: 'arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy'
          }
        ])
        ClusterName Ref(:EksCluster)
        KubernetesGroups ['cluster-admin']

        PrincipalArn FnJoin('', ['arn:aws:iam::',
                                  Ref('AWS::AccountId'),':role/aws-reserved/sso.amazonaws.com/' , 
                                  FnSelect(cluster_role, 
                                    FnFindInMap('EnvironmentName', FnSub("#{EnvironmentName}"), 'ClusterAdminRoles')
                                  ), 
                                ])
        Type auth_type
    
      }
    end
  end

  Output(:EksNodeSecurityGroup) {
    Value(Ref(:EksNodeSecurityGroup))
  }

  Output(:EksClusterName) {
    Value(Ref(:EksCluster))
  }

  Output(:DrainingLambdaRole) {
    Value(FnGetAtt(:LambdaRoleDraining, :Arn))
  }

  Output(:EksNodeRole) {
    Value(FnGetAtt(:EksNodeRole, :Arn))
  }

end
