# Module 7: Monitoring and Scaling

**Topic:** CloudWatch metrics/alarms/logs, ELB health checks, Auto Scaling Groups, target tracking.
**Focus:** Build an ALB + ASG with target-tracking autoscaling and CloudWatch alarms — observe a scale-out event live.

## Quick commands
```bash
./deploy.sh                 # CFN: ALB + ASG + target tracking + alarms
./deploy.sh stress          # also kick off CPU stress to trigger target-tracking scale-out
./scale-up.sh               # deterministic scale-out: bump DesiredCapacity by 1
./scale-up.sh 2             # bump by N (capped at MaxSize)
./cleanup.sh                # delete the stack
```

---

## Demo 1: ALB + ASG with Target-Tracking Auto Scaling (CloudFormation)

### 1. Overview
- **What it shows:** An Application Load Balancer fronting an Auto Scaling Group of t3.micro EC2s, with a target-tracking policy on average CPU utilization (50%). Includes CloudWatch alarms + a stress-test script to trigger scale-out.
- **Use case:** Standard horizontal-scaling web tier.
- **Services:** EC2, ALB, ASG, CloudWatch.

### 2. Architecture
```
        Internet
           |
        [ ALB ]
           |
    +------+------+
    |  ASG min 1  |   target-tracking: ASGAverageCPUUtilization = 50%
    |      max 4  |
    |  Health: ELB|
    +------+------+
           |
   [EC2 (Apache + stress)]   metrics -> CloudWatch
                              alarms  -> CPU>70% for 2 mins
```

### 3. Prerequisites
- Default VPC with at least 2 subnets in different AZs (auto-discovered).
- Permissions: `cloudformation:*`, `ec2:*`, `elasticloadbalancing:*`, `autoscaling:*`, `cloudwatch:*`, `iam:PassRole`.

### 4. Step-by-Step
```bash
# Discover default VPC
VPC=$(aws ec2 describe-vpcs --region us-east-1 --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --region us-east-1 \
  --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text | tr '\t' ',')

aws cloudformation deploy --region us-east-1 \
  --stack-name demo-monsc-asg \
  --template-file template.yaml \
  --parameter-overrides VpcId=$VPC SubnetIds=$SUBNETS \
  --capabilities CAPABILITY_IAM

URL=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-monsc-asg \
  --query "Stacks[0].Outputs[?OutputKey=='AlbUrl'].OutputValue" --output text)
echo "ALB: $URL"

# Trigger scale-out: ssh-less stress via SSM
ASG=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-monsc-asg \
  --query "Stacks[0].Outputs[?OutputKey=='AsgName'].OutputValue" --output text)
IID=$(aws autoscaling describe-auto-scaling-groups --region us-east-1 \
  --auto-scaling-group-names $ASG --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ssm send-command --region us-east-1 --instance-ids $IID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["stress-ng --cpu 2 --timeout 600s &"]'

# Watch the ASG scale up over ~3-5 mins
watch -n 15 "aws autoscaling describe-auto-scaling-groups --region us-east-1 \
  --auto-scaling-group-names $ASG --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState]' --output table"
```

### 5. Code — `template.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Module 7 — ALB + ASG + target-tracking + CW alarms

Parameters:
  VpcId: { Type: AWS::EC2::VPC::Id }
  SubnetIds: { Type: List<AWS::EC2::Subnet::Id> }
  LatestAmi:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64

Resources:
  Role:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement: [{Effect: Allow, Principal: {Service: ec2.amazonaws.com}, Action: sts:AssumeRole}]
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  Profile:
    Type: AWS::IAM::InstanceProfile
    Properties: { Roles: [!Ref Role] }

  AlbSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: alb
      VpcId: !Ref VpcId
      SecurityGroupIngress: [{IpProtocol: tcp, FromPort: 80, ToPort: 80, CidrIp: 0.0.0.0/0}]
  WebSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: web
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - {IpProtocol: tcp, FromPort: 80, ToPort: 80, SourceSecurityGroupId: !Ref AlbSg}

  Lt:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: demo-monsc-lt
      LaunchTemplateData:
        ImageId: !Ref LatestAmi
        InstanceType: t3.micro
        IamInstanceProfile: { Arn: !GetAtt Profile.Arn }
        SecurityGroupIds: [!Ref WebSg]
        UserData:
          Fn::Base64: |
            #!/bin/bash
            dnf install -y httpd stress-ng
            echo "OK $(hostname)" > /var/www/html/index.html
            systemctl enable --now httpd

  Alb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Subnets: !Ref SubnetIds
      SecurityGroups: [!Ref AlbSg]
      Scheme: internet-facing
      Type: application
  Tg:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      VpcId: !Ref VpcId
      Port: 80
      Protocol: HTTP
      TargetType: instance
      HealthCheckPath: /
  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Port: 80
      Protocol: HTTP
      DefaultActions: [{Type: forward, TargetGroupArn: !Ref Tg}]

  Asg:
    Type: AWS::AutoScaling::AutoScalingGroup
    Properties:
      AutoScalingGroupName: demo-monsc-asg
      VPCZoneIdentifier: !Ref SubnetIds
      MinSize: 1
      MaxSize: 4
      DesiredCapacity: 1
      HealthCheckType: ELB
      HealthCheckGracePeriod: 90
      TargetGroupARNs: [!Ref Tg]
      LaunchTemplate:
        LaunchTemplateId: !Ref Lt
        Version: !GetAtt Lt.LatestVersionNumber
      Tags:
        - { Key: Name, Value: demo-monsc-web, PropagateAtLaunch: true }

  ScalingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref Asg
      PolicyType: TargetTrackingScaling
      TargetTrackingConfiguration:
        PredefinedMetricSpecification:
          PredefinedMetricType: ASGAverageCPUUtilization
        TargetValue: 50.0

  HighCpuAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: demo-monsc-high-cpu
      MetricName: CPUUtilization
      Namespace: AWS/EC2
      Statistic: Average
      Period: 60
      EvaluationPeriods: 2
      Threshold: 70
      ComparisonOperator: GreaterThanThreshold
      Dimensions: [{Name: AutoScalingGroupName, Value: !Ref Asg}]

Outputs:
  AlbUrl:  { Value: !Sub "http://${Alb.DNSName}" }
  AsgName: { Value: !Ref Asg }
```

### 6. Validation
- After ~3 minutes of stress, ASG `DesiredCapacity` increases (visible in console or `describe-auto-scaling-groups`).
- CloudWatch alarm `demo-monsc-high-cpu` enters `ALARM` state.

### 7. Cleanup
```bash
aws cloudformation delete-stack --region us-east-1 --stack-name demo-monsc-asg
```
