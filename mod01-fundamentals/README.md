# Module 1: Architecting Fundamentals

**Topic:** Region/AZ model, basic 3-tier thinking, shared responsibility.
**Focus:** Build a minimal multi-AZ-aware foundation to experience the global infrastructure firsthand.

---

## Demo 1: Multi-AZ "Hello Architecture" — VPC + EC2 across 2 AZs (CloudFormation)

### 1. Overview
- **What it shows:** A minimum viable highly-available footprint — VPC, two public subnets in two AZs, two EC2 web servers, an ALB.
- **Use case:** Reference baseline every cloud project starts from.
- **Services:** VPC, EC2, ALB, IAM.

### 2. Architecture
```
        Internet
            |
        [ ALB ]  (2 AZs)
         /     \
   [EC2-AZa]  [EC2-AZb]   <-- t3.micro, Amazon Linux 2023
       |         |
   subnet-a   subnet-b
        \       /
          VPC 10.20.0.0/16
```

### 3. Prerequisites
- IAM permissions: `cloudformation:*`, `ec2:*`, `elasticloadbalancing:*`, `iam:PassRole`.
- AWS CLI v2.

### 4. Step-by-Step
```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name demo-fundamentals-multiaz \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM

# Get the ALB URL
aws cloudformation describe-stacks --region us-east-1 \
  --stack-name demo-fundamentals-multiaz \
  --query "Stacks[0].Outputs[?OutputKey=='AlbUrl'].OutputValue" --output text
```

### 5. Code — `template.yaml` (single file)
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Module 1 — Multi-AZ fundamentals demo (VPC + ALB + 2 EC2)

Parameters:
  LatestAmi:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64

Resources:
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.20.0.0/16
      EnableDnsHostnames: true
      Tags: [{Key: Name, Value: demo-fundamentals-vpc}]

  Igw:
    Type: AWS::EC2::InternetGateway
  AttachIgw:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties: { VpcId: !Ref Vpc, InternetGatewayId: !Ref Igw }

  SubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.20.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: true
  SubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.20.2.0/24
      AvailabilityZone: !Select [1, !GetAZs '']
      MapPublicIpOnLaunch: true

  Rt:
    Type: AWS::EC2::RouteTable
    Properties: { VpcId: !Ref Vpc }
  Route:
    Type: AWS::EC2::Route
    DependsOn: AttachIgw
    Properties:
      RouteTableId: !Ref Rt
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref Igw
  AssocA: { Type: AWS::EC2::SubnetRouteTableAssociation, Properties: { SubnetId: !Ref SubnetA, RouteTableId: !Ref Rt } }
  AssocB: { Type: AWS::EC2::SubnetRouteTableAssociation, Properties: { SubnetId: !Ref SubnetB, RouteTableId: !Ref Rt } }

  AlbSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: ALB ingress
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 80, ToPort: 80, CidrIp: 0.0.0.0/0 }

  WebSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Web tier from ALB only
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 80, ToPort: 80, SourceSecurityGroupId: !Ref AlbSg }

  WebA:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: t3.micro
      ImageId: !Ref LatestAmi
      SubnetId: !Ref SubnetA
      SecurityGroupIds: [!Ref WebSg]
      Tags: [{Key: Name, Value: demo-fund-web-a}]
      UserData:
        Fn::Base64: |
          #!/bin/bash
          dnf install -y httpd
          AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
          echo "<h1>Hello from $AZ</h1>" > /var/www/html/index.html
          systemctl enable --now httpd
  WebB:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: t3.micro
      ImageId: !Ref LatestAmi
      SubnetId: !Ref SubnetB
      SecurityGroupIds: [!Ref WebSg]
      Tags: [{Key: Name, Value: demo-fund-web-b}]
      UserData:
        Fn::Base64: |
          #!/bin/bash
          dnf install -y httpd
          AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
          echo "<h1>Hello from $AZ</h1>" > /var/www/html/index.html
          systemctl enable --now httpd

  Alb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Subnets: [!Ref SubnetA, !Ref SubnetB]
      SecurityGroups: [!Ref AlbSg]
      Scheme: internet-facing
      Type: application
  Tg:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      VpcId: !Ref Vpc
      Port: 80
      Protocol: HTTP
      TargetType: instance
      HealthCheckPath: /
      Targets:
        - { Id: !Ref WebA }
        - { Id: !Ref WebB }
  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Port: 80
      Protocol: HTTP
      DefaultActions: [{ Type: forward, TargetGroupArn: !Ref Tg }]

Outputs:
  AlbUrl:
    Value: !Sub "http://${Alb.DNSName}"
```

### 6. Validation
```bash
URL=$(aws cloudformation describe-stacks --region us-east-1 \
  --stack-name demo-fundamentals-multiaz \
  --query "Stacks[0].Outputs[0].OutputValue" --output text)
for i in 1 2 3 4 5 6; do curl -s $URL; done
# Expect responses alternating between two AZs.
```

### 7. Cleanup
```bash
aws cloudformation delete-stack --region us-east-1 --stack-name demo-fundamentals-multiaz
```
