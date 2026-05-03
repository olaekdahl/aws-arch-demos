# Module 3: Networking 1

**Topic:** VPC, subnets, route tables, IGW/NAT, SG vs NACL.
**Focus:** Build a production-shaped VPC with public + private subnets and validate the routing/SG behavior.

---

## Demo 1: Production-Shaped VPC (CloudFormation)

### 1. Overview
- **What it shows:** A 2-AZ VPC with public + private subnets, IGW, single NAT Gateway, route tables, baseline NACLs, VPC Flow Logs to CloudWatch.
- **Use case:** The reusable network foundation for almost every workload.
- **Services:** VPC, EC2 (NAT), CloudWatch Logs, IAM.

### 2. Architecture
```
                         Internet
                            |
                         [ IGW ]
                            |
   +--- public-a ---+   +--- public-b ---+
   | 10.30.1.0/24   |   | 10.30.2.0/24   |
   |  [NAT-GW]      |   |                |
   +-------+--------+   +----------------+
           |
   +--- private-a --+   +--- private-b --+
   | 10.30.11.0/24  |   | 10.30.12.0/24  |
   +----------------+   +----------------+
                  VPC 10.30.0.0/16
                  Flow Logs -> CloudWatch
```

### 3. Prerequisites
- Permissions: `cloudformation:*`, `ec2:*`, `logs:*`, `iam:PassRole`.

### 4. Step-by-Step
```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name demo-net-vpc \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM
```

### 5. Code — `template.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Module 3 — Production-shaped VPC with flow logs

Resources:
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.30.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags: [{Key: Name, Value: demo-net-vpc}]

  Igw: { Type: AWS::EC2::InternetGateway }
  IgwAttach:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties: { VpcId: !Ref Vpc, InternetGatewayId: !Ref Igw }

  PubA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.30.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags: [{Key: Name, Value: demo-net-public-a}]
  PubB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.30.2.0/24
      AvailabilityZone: !Select [1, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags: [{Key: Name, Value: demo-net-public-b}]
  PrivA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.30.11.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags: [{Key: Name, Value: demo-net-private-a}]
  PrivB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.30.12.0/24
      AvailabilityZone: !Select [1, !GetAZs '']
      Tags: [{Key: Name, Value: demo-net-private-b}]

  PubRt:
    Type: AWS::EC2::RouteTable
    Properties: { VpcId: !Ref Vpc }
  PubRoute:
    Type: AWS::EC2::Route
    DependsOn: IgwAttach
    Properties: { RouteTableId: !Ref PubRt, DestinationCidrBlock: 0.0.0.0/0, GatewayId: !Ref Igw }
  PubAssocA: { Type: AWS::EC2::SubnetRouteTableAssociation, Properties: { SubnetId: !Ref PubA, RouteTableId: !Ref PubRt } }
  PubAssocB: { Type: AWS::EC2::SubnetRouteTableAssociation, Properties: { SubnetId: !Ref PubB, RouteTableId: !Ref PubRt } }

  Eip: { Type: AWS::EC2::EIP, Properties: { Domain: vpc } }
  Nat:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt Eip.AllocationId
      SubnetId: !Ref PubA

  PrivRt:
    Type: AWS::EC2::RouteTable
    Properties: { VpcId: !Ref Vpc }
  PrivRoute:
    Type: AWS::EC2::Route
    Properties: { RouteTableId: !Ref PrivRt, DestinationCidrBlock: 0.0.0.0/0, NatGatewayId: !Ref Nat }
  PrivAssocA: { Type: AWS::EC2::SubnetRouteTableAssociation, Properties: { SubnetId: !Ref PrivA, RouteTableId: !Ref PrivRt } }
  PrivAssocB: { Type: AWS::EC2::SubnetRouteTableAssociation, Properties: { SubnetId: !Ref PrivB, RouteTableId: !Ref PrivRt } }

  FlowLogRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement: [{ Effect: Allow, Principal: { Service: vpc-flow-logs.amazonaws.com }, Action: sts:AssumeRole }]
      Policies:
        - PolicyName: flow
          PolicyDocument:
            Statement:
              - Effect: Allow
                Action: [logs:CreateLogStream, logs:PutLogEvents, logs:DescribeLogStreams, logs:CreateLogGroup]
                Resource: "*"
  FlowLogGroup:
    Type: AWS::Logs::LogGroup
    Properties: { LogGroupName: /demo/vpc/flowlogs, RetentionInDays: 7 }
  FlowLog:
    Type: AWS::EC2::FlowLog
    Properties:
      ResourceId: !Ref Vpc
      ResourceType: VPC
      TrafficType: ALL
      LogDestinationType: cloud-watch-logs
      LogGroupName: !Ref FlowLogGroup
      DeliverLogsPermissionArn: !GetAtt FlowLogRole.Arn

Outputs:
  VpcId:    { Value: !Ref Vpc }
  PrivateA: { Value: !Ref PrivA }
  PrivateB: { Value: !Ref PrivB }
```

### 6. Validation
```bash
export AWS_REGION=us-east-1
VPC=$(aws cloudformation describe-stacks --region $AWS_REGION \
  --stack-name demo-net-vpc \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text)

aws ec2 describe-route-tables --region $AWS_REGION \
  --filters "Name=vpc-id,Values=$VPC" \
  --query 'RouteTables[*].Routes[*].[DestinationCidrBlock,NatGatewayId,GatewayId]'

# After ~5 min, check flow logs:
aws logs tail /demo/vpc/flowlogs --region $AWS_REGION --since 5m
```

### 7. Cleanup
```bash
aws cloudformation delete-stack --region us-east-1 --stack-name demo-net-vpc
```

> **Cost note:** NAT Gateway ≈ $0.045/hr + data. Tear down promptly.
