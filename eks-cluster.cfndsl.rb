CloudFormation do

  tags = []
  tags << { Key: 'Environment', Value: Ref(:EnvironmentName) }
  tags << { Key: 'EnvironmentType', Value: Ref(:EnvironmentType) }
  extra_tags.each { |key,value| tags << { Key: key, Value: FnSub(value) } }

  IAM_Role(:EksClusterRole) {
    AssumeRolePolicyDocument service_role_assume_policy('eks')
    Path '/'
    ManagedPolicyArns([
      'arn:aws:iam::aws:policy/AmazonEKSServicePolicy',
      'arn:aws:iam::aws:policy/AmazonEKSClusterPolicy'
    ])
  }

  EC2_SecurityGroup(:EksClusterSecurityGroup) do
    VpcId Ref('VPCId')
    GroupDescription "#{component_name} EKS Cluster communication with worker nodes"
    Tags tags
    Metadata({
      cfn_nag: {
        rules_to_suppress: [
          { id: 'F1000', reason: 'This will be locked down by the cluster nodes component' }
        ]
      }
    })
  end

  EKS_Cluster(:EksCluster) {
    Version FnSub(cluster_name) if defined? cluster_name
    ResourcesVpcConfig({
      SecurityGroupIds: [ Ref(:EksClusterSecurityGroup) ],
      SubnetIds: FnSplit(',', Ref('SubnetIds'))
    })
    RoleArn FnGetAtt(:EksClusterRole, :Arn)
    Version eks_version if defined? eks_version
  }

end
