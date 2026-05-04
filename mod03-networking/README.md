# Module 3: Networking 1

**Topic:** VPC, subnets, route tables, IGW/NAT, SG vs NACL.
**Focus:** Build a production-shaped VPC with public + private subnets and validate the routing/SG behavior.

## Quick commands
```bash
# Demo 1 — production-shaped VPC + flow logs
./deploy.sh                                 # CFN: 2-AZ VPC, NAT GW, flow logs
./validate.sh                               # show route tables + tail flow logs
./traffic-gen.sh deploy                     # launch t3.micro, generate egress
./traffic-gen.sh cleanup                    # remove traffic generator
./cleanup.sh                                # delete VPC stack

# Demo 2 — hybrid SSM (laptop -> EC2 -> Azure VM)
./hybrid-ssm.sh deploy                      # SSM activation + EC2 jump host
ACT_CODE=<paste> ./azure-vm.sh deploy       # Azure Linux VM, auto-registers
./azure-vm.sh status && ./hybrid-ssm.sh status
./azure-vm.sh cleanup                       # delete Azure resource group
./hybrid-ssm.sh cleanup                     # terminate EC2, deregister mi-*
```

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
    Properties: { RetentionInDays: 7 }   # auto-named so re-deploys never collide
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
  VpcId:        { Value: !Ref Vpc }
  PrivateA:     { Value: !Ref PrivA }
  PrivateB:     { Value: !Ref PrivB }
  FlowLogGroup: { Value: !Ref FlowLogGroup }
```

### 6. Validation
```bash
export AWS_REGION=us-east-1
VPC=$(aws cloudformation describe-stacks --region $AWS_REGION \
  --stack-name demo-net-vpc \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text)
LG=$(aws cloudformation describe-stacks --region $AWS_REGION \
  --stack-name demo-net-vpc \
  --query 'Stacks[0].Outputs[?OutputKey==`FlowLogGroup`].OutputValue' --output text)

aws ec2 describe-route-tables --region $AWS_REGION \
  --filters "Name=vpc-id,Values=$VPC" \
  --query 'RouteTables[*].Routes[*].[DestinationCidrBlock,NatGatewayId,GatewayId]'

# After ~5 min, check flow logs (log-group name is auto-generated):
aws logs tail "$LG" --region $AWS_REGION --since 5m
```

### 6b. Analyzing Flow Logs

The NAT Gateway's public Elastic IP attracts internet background-noise (port scans, bots).
You can mine the flow logs to see what's hitting your edge.

> **Important:** `ACCEPT` in flow logs reflects security-group/NACL evaluation, **not** delivery.
> The NAT GW silently drops unsolicited inbound packets — `ACCEPT` here just means "no SG/NACL
> denied it"; nothing inside the VPC actually receives it.
>
> **Field positions** (space-separated): `1:version 2:account 3:eni 4:srcAddr 5:dstAddr
> 6:srcPort 7:dstPort 8:protocol 9:packets 10:bytes 11:start 12:end 13:action 14:status`.
> Protocol numbers: `6=TCP, 17=UDP, 1=ICMP`.

Quick CLI analysis:

```bash
# Resolve the auto-generated log group name from the stack output:
LG=$(aws cloudformation describe-stacks --region us-east-1 \
  --stack-name demo-net-vpc \
  --query 'Stacks[0].Outputs[?OutputKey==`FlowLogGroup`].OutputValue' --output text)

# Top destination ports being scanned (last 15 min)
aws logs filter-log-events --region us-east-1 --log-group-name $LG \
  --start-time $(( ($(date +%s) - 900) * 1000 )) \
  --query 'events[*].message' --output text \
  | awk '{print $7}' | sort | uniq -c | sort -rn | head

# Top source IPs (the scanners)
aws logs filter-log-events --region us-east-1 --log-group-name $LG \
  --start-time $(( ($(date +%s) - 900) * 1000 )) \
  --query 'events[*].message' --output text \
  | awk '{print $4}' | sort | uniq -c | sort -rn | head
```

Same questions in CloudWatch Logs Insights (richer queries):

```
fields @timestamp, srcAddr, dstAddr, dstPort, protocol, action
| filter action="ACCEPT"
| stats count(*) as hits by dstPort, protocol
| sort hits desc
| limit 20
```

### 6c. Generate identifiable traffic (optional)

To distinguish *your* traffic from internet noise, launch a small EC2 in the private subnet
and run egress workloads via SSM:

```bash
./traffic-gen.sh deploy   # launches t3.micro + curl/dig/ping via SSM
./traffic-gen.sh cleanup  # remove instance + role
```

### 7. Cleanup
```bash
aws cloudformation delete-stack --region us-east-1 --stack-name demo-net-vpc
```

> **Cost note:** NAT Gateway ≈ $0.045/hr + data. Tear down promptly.

---

## Demo 2: Hybrid Connectivity — Laptop → EC2 → Azure VM (all over SSM)

### 1. Overview
- **What it shows:** Cross-cloud, zero-inbound-port management plane. The laptop reaches an EC2 jump host in a private subnet using **Session Manager**, and from that EC2 it hops to an **Azure VM** that has been registered as an AWS **hybrid managed instance** (`mi-…`). No SSH keys, no public IPs, no inbound security-group rules anywhere in the chain.
- **Use case:** Operate Linux/Windows fleets that live outside AWS (on-prem, Azure, GCP, edge) with the same IAM-gated tooling you use for EC2.
- **Services:** SSM Session Manager, SSM Hybrid Activations, IAM, EC2.

### 2. Architecture
```
  Laptop                             AWS                                    Azure
  ------                             ---                                    -----
  aws ssm start-session   --TLS-->  [ ssmmessages.<region>.amazonaws.com ]
                                              |
                                              v
                                     EC2 jump host (private subnet)
                                     - SSM agent (outbound 443 via NAT GW)
                                     - role: SSMManagedInstanceCore
                                            + ssm:StartSession on mi-*
                                              |
                                  aws ssm start-session --target mi-xxxx
                                              |
                                              v   <--TLS--   Azure VM (mi-xxxx)
                                                             - SSM agent registered via
                                                               hybrid activation code
                                                             - assumes role
                                                               SSMManagedInstanceCore
```

### 3. Prerequisites
- Demo 1 stack (`demo-net-vpc`) deployed.
- Laptop has `aws` CLI **and** the `session-manager-plugin` installed.
- An Azure VM (Linux or Windows) with outbound HTTPS to `*.amazonaws.com`. No NSG inbound rules required.

### 4. Step-by-Step
```bash
# 1) Create the hybrid activation + EC2 jump host. Prints the three hops.
./hybrid-ssm.sh deploy

# 2a) Option A — automated: deploy an Azure Linux VM that auto-registers via cloud-init.
#     Pass the ACT_CODE printed by step (1); ACT_ID is auto-discovered from AWS.
ACT_CODE=<paste-from-step-1> ./azure-vm.sh deploy

# 2b) Option B — manual: on any existing Azure VM, paste the registration block
#     printed by ./hybrid-ssm.sh (Linux .deb/.rpm or Windows AmazonSSMAgentSetup.exe).

# 3) Confirm the VM appears as `mi-xxxxxxxx`:
aws ssm describe-instance-information --region us-east-1 \
  --query 'InstanceInformationList[*].[InstanceId,PingStatus,PlatformName,ComputerName]' \
  --output table

# 3) Hop 1: from your laptop to the EC2 jump host.
EC2=$(aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:Name,Values=demo-net-hybrid-jump" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm start-session --region us-east-1 --target "$EC2"

# 4) Hop 2: from inside the EC2 shell, jump to the Azure VM.
MI=$(aws ssm describe-instance-information --region us-east-1 \
       --query 'InstanceInformationList[?starts_with(InstanceId,`mi-`)]|[0].InstanceId' --output text)
aws ssm start-session --region us-east-1 --target "$MI"
# You're now in an interactive shell *on the Azure VM*. `hostname && uname -a`.
```

### 5. Why this works (no inbound ports anywhere)
- Session Manager is a **reverse tunnel**: the SSM agent (on EC2 *and* on the Azure VM) opens an outbound TLS connection to `ssmmessages.<region>.amazonaws.com` and waits. The laptop's `start-session` call meets that connection at the AWS control plane.
- The EC2 jump host is in a **private subnet** — egress only via the NAT Gateway from Demo 1.
- The Azure VM only needs **egress 443** to AWS; no Azure NSG inbound rule, no VPN/peering, no public IP.
- Authentication is IAM end-to-end: the laptop's principal must have `ssm:StartSession` on the EC2; the EC2 instance role must have `ssm:StartSession` on `arn:aws:ssm:*:*:managed-instance/mi-*`; the Azure VM authenticates with the activation code at registration time and then uses its `SSMManagedInstanceCore` role for ongoing API calls.

### 6. Validation
```bash
./hybrid-ssm.sh status
# Expected:
#   - one running EC2 jump host
#   - one i-xxx and one mi-xxx with PingStatus=Online
#   - one activation with RegistrationsCount >= 1, Expired=False
```

Audit the trail in CloudTrail — every session is logged:
```bash
aws cloudtrail lookup-events --region us-east-1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=StartSession \
  --max-results 5 \
  --query 'Events[*].[EventTime,Username,Resources[0].ResourceName]' --output table
```

### 7. Cleanup
```bash
./azure-vm.sh cleanup      # delete Azure RG (VM, NIC, VNet, NSG, disks)
./hybrid-ssm.sh cleanup    # terminate EC2, deregister mi-*, delete activation + roles
```
If you registered an Azure VM manually (Option B above), also run on the VM itself:
```bash
sudo amazon-ssm-agent -deregister || true
sudo systemctl stop amazon-ssm-agent || true
```

> **Cost note:** EC2 jump host (~t3.micro) + the existing NAT GW from Demo 1. SSM Session Manager itself is free; hybrid managed instances are $0 for **advanced-tier** features only if you exceed 1,000 instances per account/region — for one Azure VM, the cost is the EC2 + data transfer.
