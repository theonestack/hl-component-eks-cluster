CfhighlanderTemplate do
  Name 'eks-cluster'
  Description "eks-cluster - #{component_version}"

  Parameters do
    ComponentParam 'EnvironmentName', 'dev', isGlobal: true
    ComponentParam 'EnvironmentType', 'development', allowedValues: ['development','production'], isGlobal: true
    ComponentParam 'VPCId', isGlobal: true, type: 'AWS::EC2::VPC::Id'
    ComponentParam 'SubnetIds'
  end


end
