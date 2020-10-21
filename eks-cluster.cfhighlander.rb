CfhighlanderTemplate do
  Name 'eks-cluster'
  DependsOn 'lib-iam'
  Description "eks-cluster - #{component_version}"

  Parameters do
    ComponentParam 'EnvironmentName', 'dev', isGlobal: true
    ComponentParam 'EnvironmentType', 'development', allowedValues: ['development','production'], isGlobal: true
    ComponentParam 'VPCId', isGlobal: true, type: 'AWS::EC2::VPC::Id'
    ComponentParam 'SubnetIds'
    ComponentParam 'BootstrapArguments'
    ComponentParam 'KeyName'
    ComponentParam 'ImageId', type: 'AWS::EC2::Image::Id'

    ComponentParam 'InstanceType'

    ComponentParam 'SpotPrice', ''
    ComponentParam 'EnableScaling', 'true'
    ComponentParam 'DesiredCapacity', '1'
    ComponentParam 'MinSize', '1'
    ComponentParam 'MaxSize', '2'

    fargate_profiles.each do |profile|
      name = profile['name'].gsub('-','').gsub('_','').capitalize
      ComponentParam "#{name}FargateProfileName", ''
      ComponentParam "#{name}FargateSubnetIds", type: 'List<AWS::EC2::Subnet::Id>'
    end if defined? fargate_profiles
  end

  LambdaFunctions 'draining_lambda'

end
