# Module 10: Networking 2

**Topic:** VPC peering, Transit Gateway, PrivateLink, hybrid connectivity, Route 53.
**Focus:** Demonstrate VPC-to-VPC connectivity using a Transit Gateway — the modern hub-and-spoke pattern.

## Quick commands
```bash
./deploy.sh                 # CFN: 2 VPCs + TGW + 2 EC2 (SSM)
./cleanup.sh                # delete the stack
```

---

## Demo 1: Transit Gateway Hub-and-Spoke (CloudFormation)

### 1. Overview
- **What it shows:** Two spoke VPCs attached to a Transit Gateway with shared route table; an EC2 in VPC-A pings an EC2 in VPC-B over private IPs through TGW.
- **Use case:** Replaces ad-hoc peering meshes for multi-VPC topologies.
- **Services:** EC2, VPC, TGW, SSM.

### 2. Architecture
```
           [ Transit Gateway: demo-net2-tgw ]
              /                          \
   [VPC-A 10.40.0.0/16]            [VPC-B 10.41.0.0/16]
     subnet 10.40.1.0/24             subnet 10.41.1.0/24
     EC2-A (SSM enabled)             EC2-B (SSM enabled)
     RT: 10.41.0.0/16 -> tgw         RT: 10.40.0.0/16 -> tgw
```

### 3. Prerequisites
- Permissions: `ec2:*`, `cloudformation:*`, `iam:PassRole`, `ssm:*`.

### 4. Step-by-Step
```bash
aws cloudformation deploy --region us-east-1 \
  --stack-name demo-net2-tgw --template-file template.yaml \
  --capabilities CAPABILITY_IAM

# Get instance IDs
A=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-net2-tgw \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceA'].OutputValue" --output text)
B_IP=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-net2-tgw \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceBPrivateIp'].OutputValue" --output text)

# Wait ~90s for SSM, then ping from A to B (cross-VPC via TGW)
aws ssm send-command --region us-east-1 --instance-ids $A \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"ping -c 3 $B_IP\"]"
```

### 5. Code — `template.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Module 10 — Transit Gateway hub-and-spoke

Parameters:
  LatestAmi:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64

Resources:
  Tgw:
    Type: AWS::EC2::TransitGateway
    Properties:
      Description: demo-net2-tgw
      DefaultRouteTableAssociation: enable
      DefaultRouteTablePropagation: enable

  # ----- VPC A -----
  VpcA:
    Type: AWS::EC2::VPC
    Properties: { CidrBlock: 10.40.0.0/16, EnableDnsHostnames: true }
  SubA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VpcA
      CidrBlock: 10.40.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
  RtA:
    Type: AWS::EC2::RouteTable
    Properties: { VpcId: !Ref VpcA }
  AssocA: { Type: AWS::EC2::SubnetRouteTableAssociation, Properties: { SubnetId: !Ref SubA, RouteTableId: !Ref RtA } }

  # ----- VPC B -----
  VpcB:
    Type: AWS::EC2::VPC
    Properties: { CidrBlock: 10.41.0.0/16, EnableDnsHostnames: true }
  SubB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VpcB
      CidrBlock: 10.41.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
  RtB:
    Type: AWS::EC2::RouteTable
    Properties: { VpcId: !Ref VpcB }
  AssocB: { Type: AWS::EC2::SubnetRouteTableAssociation, Properties: { SubnetId: !Ref SubB, RouteTableId: !Ref RtB } }

  AttachA:
    Type: AWS::EC2::TransitGatewayAttachment
    Properties: { TransitGatewayId: !Ref Tgw, VpcId: !Ref VpcA, SubnetIds: [!Ref SubA] }
  AttachB:
    Type: AWS::EC2::TransitGatewayAttachment
    Properties: { TransitGatewayId: !Ref Tgw, VpcId: !Ref VpcB, SubnetIds: [!Ref SubB] }

  RouteAtoB:
    Type: AWS::EC2::Route
    DependsOn: AttachA
    Properties: { RouteTableId: !Ref RtA, DestinationCidrBlock: 10.41.0.0/16, TransitGatewayId: !Ref Tgw }
  RouteBtoA:
    Type: AWS::EC2::Route
    DependsOn: AttachB
    Properties: { RouteTableId: !Ref RtB, DestinationCidrBlock: 10.40.0.0/16, TransitGatewayId: !Ref Tgw }

  # SSM-enabled instances (no SSH)
  Role:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement: [{Effect: Allow, Principal: {Service: ec2.amazonaws.com}, Action: sts:AssumeRole}]
      ManagedPolicyArns: [arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore]
  Profile:
    Type: AWS::IAM::InstanceProfile
    Properties: { Roles: [!Ref Role] }

  # SSM endpoints in each VPC so SSM works without IGW/NAT
  SgA:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: allow icmp + https self
      VpcId: !Ref VpcA
      SecurityGroupIngress:
        - { IpProtocol: icmp, FromPort: -1, ToPort: -1, CidrIp: 10.0.0.0/8 }
        - { IpProtocol: tcp,  FromPort: 443, ToPort: 443, CidrIp: 10.40.0.0/16 }
  SgB:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: allow icmp + https self
      VpcId: !Ref VpcB
      SecurityGroupIngress:
        - { IpProtocol: icmp, FromPort: -1, ToPort: -1, CidrIp: 10.0.0.0/8 }
        - { IpProtocol: tcp,  FromPort: 443, ToPort: 443, CidrIp: 10.41.0.0/16 }

  EpAssm:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VpcA
      ServiceName: !Sub com.amazonaws.${AWS::Region}.ssm
      VpcEndpointType: Interface
      SubnetIds: [!Ref SubA]
      SecurityGroupIds: [!Ref SgA]
      PrivateDnsEnabled: true
  EpAssmMsg:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VpcA
      ServiceName: !Sub com.amazonaws.${AWS::Region}.ssmmessages
      VpcEndpointType: Interface
      SubnetIds: [!Ref SubA]
      SecurityGroupIds: [!Ref SgA]
      PrivateDnsEnabled: true
  EpAec2Msg:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VpcA
      ServiceName: !Sub com.amazonaws.${AWS::Region}.ec2messages
      VpcEndpointType: Interface
      SubnetIds: [!Ref SubA]
      SecurityGroupIds: [!Ref SgA]
      PrivateDnsEnabled: true

  Ea:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: t3.micro
      ImageId: !Ref LatestAmi
      SubnetId: !Ref SubA
      SecurityGroupIds: [!Ref SgA]
      IamInstanceProfile: !Ref Profile
      Tags: [{Key: Name, Value: demo-net2-ec2-a}]
  Eb:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: t3.micro
      ImageId: !Ref LatestAmi
      SubnetId: !Ref SubB
      SecurityGroupIds: [!Ref SgB]
      IamInstanceProfile: !Ref Profile
      Tags: [{Key: Name, Value: demo-net2-ec2-b}]

Outputs:
  InstanceA: { Value: !Ref Ea }
  InstanceB: { Value: !Ref Eb }
  InstanceBPrivateIp: { Value: !GetAtt Eb.PrivateIp }
```

### 6. Validation
- The SSM `send-command` output (via `aws ssm get-command-invocation`) shows `3 packets transmitted, 3 received` — proving cross-VPC connectivity over TGW.

### 7. Cleanup
```bash
aws cloudformation delete-stack --region us-east-1 --stack-name demo-net2-tgw
```

> **Cost note:** TGW attachments ≈ $0.05/hr each + data. Tear down promptly.
