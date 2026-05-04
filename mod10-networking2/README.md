# Module 10: Networking 2

**Topic:** VPC peering, Transit Gateway, PrivateLink, hybrid connectivity (cross-cloud IPsec VPN), Route 53.
**Focus:** Multi-VPC connectivity via Transit Gateway, plus a cross-cloud site-to-site VPN to Azure.

## Quick commands
```bash
# Demo 1 — Transit Gateway hub-and-spoke
./deploy.sh                                 # CFN: 2 VPCs + TGW + 2 EC2 (SSM)
./cleanup.sh                                # delete the stack

# Demo 2 — cross-cloud peering (AWS VPC <-> Azure VNet via IPsec VPN)
#   Self-contained: all required scripts/templates live in mod10.
./peering.sh deploy                         # bootstraps demo-net2-vpc, builds tunnel (~30-45 min Azure VPN GW)
./hybrid-ssm.sh deploy                      # SSM activation + EC2 jump host (prints ACT_CODE)
ACT_CODE=<paste> ./azure-vm.sh deploy       # Azure Linux VM, auto-registers as mi-*
./peering.sh status                         # tunnel telemetry both sides
./peering.sh test                           # ping over VPN from EC2 -> Azure VM
./azure-vm.sh cleanup                       # delete Azure VM
./hybrid-ssm.sh cleanup                     # terminate EC2, deregister mi-*, reset SSM tier
./peering.sh cleanup                        # delete VPN/VGW/CGW + Azure VPN GW, reset SSM tier
aws cloudformation delete-stack --stack-name demo-net2-vpc  # finally drop the VPC
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

---

## Demo 2: Site-to-Site VPN — AWS VPC ↔ Azure VNet

### 1. Overview
- **What it shows:** A production-style **IPsec site-to-site VPN** between an AWS **VPN Gateway** and an Azure **VPN Gateway**, with static routing in both directions. After this is up, EC2s in `demo-net2-vpc` (10.30.0.0/16) and VMs in the Azure VNet (10.40.0.0/16) reach each other over private IPs.
- **Self-contained:** all four files needed live in mod10 — `peering.sh`, `hybrid-ssm.sh`, `azure-vm.sh`, `vpc-template.yaml`. No references to other modules. Resource names are prefixed `demo-net2-` so they coexist with mod03's `demo-net-` versions if you want to run both.
- **Why not "peering":** AWS VPC peering and Azure VNet peering are intra-cloud constructs — there is no native cross-cloud peering. The hybrid-network primitive that AWS supports against Azure is **IPsec VPN** (or Direct Connect + ExpressRoute via a colocated partner).
- **Services:** EC2 VPN Gateway, Customer Gateway, Site-to-Site VPN, Azure VirtualNetworkGateway, Local Network Gateway, Connection, SSM (Session Manager + hybrid activations).

### 2. Architecture
```
  AWS demo-net2-vpc 10.30.0.0/16           Azure demo-net2-hybrid-vnet 10.40.0.0/16
  ------------------------------           ------------------------------------------
     PrivA / PrivB subnets                     default subnet (10.40.1.0/24)
     Private RT:                                + GatewaySubnet  10.40.255.0/27
       0.0.0.0/0  -> NAT GW
       10.40/16   -> VGW   <===== IPsec tunnel =====>   VirtualNetworkGateway VpnGw1
     VPN Gateway (vgw-...)                                  |
     Customer Gateway (Azure VPN public IP)                 |
     VPN Connection (static, 10.40/16)                Local Network Gateway
                                                       (AWS tunnel-1 outside IP,
                                                        local prefixes = 10.30/16)
```

### 3. Prerequisites
- `az` CLI logged into the Azure subscription, `aws` CLI configured.
- Patience: **the Azure VPN Gateway alone takes ≈30–45 minutes to provision.**
- Note: mod10 Demo 1 (TGW) uses VPC CIDRs 10.40/16 and 10.41/16 in AWS, which collide with the Azure VNet CIDR (10.40/16) used here. Don't run Demos 1+2 concurrently if you intend to extend either with cross-routing.

### 4. Step-by-Step
```bash
# 1) Build the IPsec tunnel (auto-deploys VPC stack if missing, ~30-45 min for Azure VPN GW)
./peering.sh deploy

# 2) For end-to-end ping: stand up an EC2 jump host + Azure VM as ping endpoints.
#    hybrid-ssm.sh prints ACT_CODE; pass it to azure-vm.sh.
./hybrid-ssm.sh deploy
ACT_CODE=<paste-from-step-2> ./azure-vm.sh deploy

# 3) Validate
./peering.sh status        # AWS VgwTelemetry + Azure connectionStatus
./peering.sh test          # SSM-runs ping from EC2 jump host to Azure VM private IP

# 4) Tear down (Demo 2)
./azure-vm.sh cleanup
./hybrid-ssm.sh cleanup
./peering.sh cleanup
aws cloudformation delete-stack --region us-east-1 --stack-name demo-net2-vpc
```

**SSM hybrid tier:** Session Manager to a hybrid `mi-*` instance requires the
account+region SSM service setting `activation-tier=advanced` (~$0.00695/hr per
managed instance). Both `peering.sh deploy` and `hybrid-ssm.sh deploy` flip it to
`advanced`; both cleanups (and `cleanup.sh`) reset it to `standard`. The toggle is
idempotent.

### 5. Validation
```bash
# AWS side
aws ec2 describe-vpn-connections --region us-east-1 \
  --filters "Name=tag:Name,Values=demo-net2-vpn-azure" \
  --query 'VpnConnections[0].VgwTelemetry[*].[OutsideIpAddress,Status,StatusMessage]' --output table
# Expect: at least tunnel 1 Status=UP

# Azure side
az network vpn-connection show -g demo-net2-hybrid-rg -n demo-net2-azure-to-aws \
  --query '{status:connectionStatus,bytesIn:ingressBytesTransferred,bytesOut:egressBytesTransferred}' -o table
# Expect: connectionStatus=Connected
```

End-to-end ping (requires `./hybrid-ssm.sh deploy` + `./azure-vm.sh deploy` for the endpoints):
```bash
./peering.sh test
# If ping fails but Status=UP, the Azure NSG is blocking ICMP. Add:
#   az network nsg rule create -g demo-net2-hybrid-rg --nsg-name demo-net2-hybrid-nsg \
#     -n allow-aws-icmp --priority 200 --source-address-prefixes 10.30.0.0/16 \
#     --protocol Icmp --access Allow --direction Inbound
```

### 6. Common gotchas
- **Only one tunnel is wired.** AWS Site-to-Site VPN gives you two tunnels for HA; this demo configures Azure to use tunnel-1 only. Production should configure both with active-active and BGP.
- **Static routing.** BGP on Azure VPN Gateway needs SKU ≥ VpnGw1 with active-active and an ASN; static is simpler for a teaching demo.
- **Address space overlap.** AWS VPC and Azure VNet CIDRs must not overlap. This demo uses 10.30/16 and 10.40/16.
- **PSK rotation.** If you `modify-vpn-tunnel-options` on AWS, also `az network vpn-connection shared-key update` with the new value.

### 7. Cleanup
```bash
./azure-vm.sh cleanup       # delete Azure VM (RG/VNet kept for peering teardown)
./hybrid-ssm.sh cleanup     # terminate EC2, deregister mi-*, reset SSM tier to standard
./peering.sh cleanup        # deletes VPN/VGW/CGW on AWS and VPN GW + connection on Azure, resets SSM tier
aws cloudformation delete-stack --region us-east-1 --stack-name demo-net2-vpc
```

> **Cost note:** Azure `VpnGw1` ≈ **\$0.19/hr**, AWS Site-to-Site VPN ≈ **\$0.05/hr**, plus a few cents/hr of egress for keepalives. Tear down promptly.
