# Module 9: Containers

**Topic:** ECS, EKS, Fargate, ECR.
**Focus:** Build a serverless-container service end-to-end on ECS Fargate behind an ALB.

## Quick commands
```bash
./deploy.sh                 # ECR push + CFN: ECS Fargate + ALB
./cleanup.sh                # delete the stack + ECR repo
```

---

## Demo 1: ECS Fargate + ECR + ALB (CloudFormation, single template)

### 1. Overview
- **What it shows:** Push a tiny container to ECR, run it on Fargate behind an ALB, scale on CPU. Single CFN template captures the whole stack.
- **Use case:** Modern minimal containerized service.
- **Services:** ECR, ECS Fargate, ALB, IAM, CloudWatch Logs.

### 2. Architecture
```
[ docker push ] --> [ ECR: demo-ctr-app ]
                          |
                          v
        +-----------------------------------+
        | ECS Cluster: demo-ctr-cluster     |
        |   Service (Fargate, desired=2)    |
        |     Task: app:latest, port 80     |
        +-----------------+-----------------+
                          |
                       [ ALB ]
                          |
                       Internet
```

### 3. Prerequisites
- Docker installed & running.
- Permissions: `ecr:*`, `ecs:*`, `cloudformation:*`, `iam:PassRole`, `elasticloadbalancing:*`.
- Default VPC + 2 subnets.

### 4. Step-by-Step
```bash
REGION=us-east-1
ACCT=$(aws sts get-caller-identity --query Account --output text)
REPO=demo-ctr-app

# 1. Create ECR repo + push a hello image (uses public nginx as base)
aws ecr create-repository --region $REGION --repository-name $REPO || true
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCT.dkr.ecr.$REGION.amazonaws.com

cat > Dockerfile <<'EOF'
FROM public.ecr.aws/nginx/nginx:alpine
RUN echo "<h1>Hello from ECS Fargate</h1>" > /usr/share/nginx/html/index.html
EOF

docker build -t $REPO .
docker tag $REPO:latest $ACCT.dkr.ecr.$REGION.amazonaws.com/$REPO:latest
docker push $ACCT.dkr.ecr.$REGION.amazonaws.com/$REPO:latest

# 2. Discover default VPC & subnets
VPC=$(aws ec2 describe-vpcs --region $REGION --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text | tr '\t' ',')

# 3. Deploy
aws cloudformation deploy --region $REGION \
  --stack-name demo-ctr-fargate \
  --template-file template.yaml \
  --parameter-overrides VpcId=$VPC SubnetIds=$SUBNETS \
    ImageUri=$ACCT.dkr.ecr.$REGION.amazonaws.com/$REPO:latest \
  --capabilities CAPABILITY_IAM
```

### 5. Code — `template.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Module 9 — ECS Fargate + ALB

Parameters:
  VpcId: { Type: AWS::EC2::VPC::Id }
  SubnetIds: { Type: List<AWS::EC2::Subnet::Id> }
  ImageUri: { Type: String }

Resources:
  Cluster:
    Type: AWS::ECS::Cluster
    Properties: { ClusterName: demo-ctr-cluster }

  LogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      RetentionInDays: 7

  ExecRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement: [{Effect: Allow, Principal: {Service: ecs-tasks.amazonaws.com}, Action: sts:AssumeRole}]
      ManagedPolicyArns: [arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy]

  TaskDef:
    Type: AWS::ECS::TaskDefinition
    Properties:
      Family: demo-ctr-app
      Cpu: 256
      Memory: 512
      NetworkMode: awsvpc
      RequiresCompatibilities: [FARGATE]
      ExecutionRoleArn: !GetAtt ExecRole.Arn
      ContainerDefinitions:
        - Name: app
          Image: !Ref ImageUri
          Essential: true
          PortMappings: [{ContainerPort: 80}]
          LogConfiguration:
            LogDriver: awslogs
            Options:
              awslogs-group: !Ref LogGroup
              awslogs-region: !Ref AWS::Region
              awslogs-stream-prefix: app

  AlbSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: alb
      VpcId: !Ref VpcId
      SecurityGroupIngress: [{IpProtocol: tcp, FromPort: 80, ToPort: 80, CidrIp: 0.0.0.0/0}]
  TaskSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: task
      VpcId: !Ref VpcId
      SecurityGroupIngress: [{IpProtocol: tcp, FromPort: 80, ToPort: 80, SourceSecurityGroupId: !Ref AlbSg}]

  Alb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties: { Subnets: !Ref SubnetIds, SecurityGroups: [!Ref AlbSg], Scheme: internet-facing, Type: application }
  Tg:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      VpcId: !Ref VpcId
      Port: 80
      Protocol: HTTP
      TargetType: ip
      HealthCheckPath: /
  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Port: 80
      Protocol: HTTP
      DefaultActions: [{Type: forward, TargetGroupArn: !Ref Tg}]

  Service:
    Type: AWS::ECS::Service
    DependsOn: Listener
    Properties:
      Cluster: !Ref Cluster
      LaunchType: FARGATE
      DesiredCount: 2
      TaskDefinition: !Ref TaskDef
      NetworkConfiguration:
        AwsvpcConfiguration:
          AssignPublicIp: ENABLED
          Subnets: !Ref SubnetIds
          SecurityGroups: [!Ref TaskSg]
      LoadBalancers:
        - { ContainerName: app, ContainerPort: 80, TargetGroupArn: !Ref Tg }

Outputs:
  Url: { Value: !Sub "http://${Alb.DNSName}" }
```

### 6. Validation
```bash
URL=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-ctr-fargate \
  --query "Stacks[0].Outputs[0].OutputValue" --output text)
curl $URL
# -> <h1>Hello from ECS Fargate</h1>
```

### 7. Cleanup
```bash
aws cloudformation delete-stack --region us-east-1 --stack-name demo-ctr-fargate
aws ecr delete-repository --region us-east-1 --repository-name demo-ctr-app --force
```
