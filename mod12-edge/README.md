# Module 12: Edge Services

**Topic:** CloudFront, Global Accelerator, AWS WAF, Shield.
**Focus:** Front an S3 origin with CloudFront + Origin Access Control + a WAF web ACL — the canonical secure static-site edge pattern.

## Quick commands
```bash
./deploy.sh                 # CFN: CloudFront + S3 (OAC) + WAFv2
./cleanup.sh                # delete the stack
```

---

## Demo 1: CloudFront + S3 (OAC) + WAF (CloudFormation)

### 1. Overview
- **What it shows:** Private S3 bucket exposed only via CloudFront using **Origin Access Control** (OAC). A WAF web ACL with AWS Managed Rules (Common rule set) is attached to CloudFront.
- **Use case:** Secure, cached, DDoS-protected static content delivery.
- **Services:** CloudFront, S3, WAFv2, IAM.

### 2. Architecture
```
   Client
     |
     v
[ WAFv2 Web ACL: AWS-Managed Common Rules ]
     |
     v
[ CloudFront distribution: demo-edge-cdn ]
     |  (signed via OAC, sigv4 to S3)
     v
[ S3 bucket: demo-edge-origin-<acct> ]   (private, no public access)
```

### 3. Prerequisites
- Permissions: `cloudformation:*`, `s3:*`, `cloudfront:*`, `wafv2:*`.
- WAFv2 for CloudFront must be created in `us-east-1`.

### 4. Step-by-Step
```bash
aws cloudformation deploy --region us-east-1 \
  --stack-name demo-edge-cdn --template-file template.yaml

BUCKET=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-edge-cdn \
  --query "Stacks[0].Outputs[?OutputKey=='Bucket'].OutputValue" --output text)
URL=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-edge-cdn \
  --query "Stacks[0].Outputs[?OutputKey=='Url'].OutputValue" --output text)

# Upload a sample
echo "<h1>Edge demo</h1>" > /tmp/index.html
aws s3 cp /tmp/index.html s3://$BUCKET/index.html

# Wait for distribution to deploy (~5 min) then test
curl -I $URL/index.html
```

### 5. Code — `template.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Module 12 — CloudFront + S3 (OAC) + WAFv2

Resources:
  Bucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub demo-edge-origin-${AWS::AccountId}
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        IgnorePublicAcls: true
        BlockPublicPolicy: true
        RestrictPublicBuckets: true
      OwnershipControls:
        Rules: [{ ObjectOwnership: BucketOwnerEnforced }]

  Oac:
    Type: AWS::CloudFront::OriginAccessControl
    Properties:
      OriginAccessControlConfig:
        Name: demo-edge-oac
        OriginAccessControlOriginType: s3
        SigningBehavior: always
        SigningProtocol: sigv4

  WebAcl:
    Type: AWS::WAFv2::WebACL
    Properties:
      Name: demo-edge-acl
      Scope: CLOUDFRONT
      DefaultAction: { Allow: {} }
      VisibilityConfig:
        SampledRequestsEnabled: true
        CloudWatchMetricsEnabled: true
        MetricName: demo-edge-acl
      Rules:
        - Name: AWS-Common
          Priority: 0
          OverrideAction: { None: {} }
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesCommonRuleSet
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: AWS-Common

  Distro:
    Type: AWS::CloudFront::Distribution
    Properties:
      DistributionConfig:
        Enabled: true
        DefaultRootObject: index.html
        WebACLId: !GetAtt WebAcl.Arn
        Origins:
          - Id: s3origin
            DomainName: !GetAtt Bucket.RegionalDomainName
            S3OriginConfig: { OriginAccessIdentity: "" }
            OriginAccessControlId: !GetAtt Oac.Id
        DefaultCacheBehavior:
          TargetOriginId: s3origin
          ViewerProtocolPolicy: redirect-to-https
          AllowedMethods: [GET, HEAD]
          CachePolicyId: 658327ea-f89d-4fab-a63d-7e88639e58f6  # Managed-CachingOptimized

  BucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref Bucket
      PolicyDocument:
        Statement:
          - Effect: Allow
            Principal: { Service: cloudfront.amazonaws.com }
            Action: s3:GetObject
            Resource: !Sub "${Bucket.Arn}/*"
            Condition:
              StringEquals:
                "AWS:SourceArn": !Sub "arn:aws:cloudfront::${AWS::AccountId}:distribution/${Distro}"

Outputs:
  Bucket: { Value: !Ref Bucket }
  Url:    { Value: !Sub "https://${Distro.DomainName}" }
```

### 6. Validation
```bash
curl -I $URL/index.html
# -> HTTP/2 200, server: CloudFront, x-cache: Miss/Hit ...
aws s3api get-bucket-policy-status --bucket $BUCKET
# -> "IsPublic": false  (S3 bucket remains private)
```

### 7. Cleanup
```bash
# Empty the bucket first (CFN cannot delete non-empty buckets)
aws s3 rm s3://$BUCKET --recursive
aws cloudformation delete-stack --region us-east-1 --stack-name demo-edge-cdn
```
