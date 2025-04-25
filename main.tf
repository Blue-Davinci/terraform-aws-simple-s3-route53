terraform {
    required_providers {
        aws = {
        source  = "hashicorp/aws"
        version = "~> 4.0"
        }
    }
    
    required_version = ">= 1.0.0"
}

resource "aws_route53_zone" "main" {
  name = var.domain_name

  comment = "Hosted zone for static site ${var.domain_name}"
  tags = {
    Environment = "Dev"
    ManagedBy   = "Terraform"
  }
}

provider "aws" {
    alias  = "us_east_1"
    region = var.region 
}

# make an s3 bucket with the name of the domain name
resource "aws_s3_bucket" "site_bucket" {
    bucket = var.domain_name
    force_destroy = true

    tags = {
      name = "site_bucket"
      environment = "test"
    }
}

# prevent public access to the bucket
resource "aws_s3_bucket_public_access_block" "block_public_access" {
    bucket = aws_s3_bucket.site_bucket.id

    block_public_acls       = true
    ignore_public_acls      = true
    restrict_public_buckets = true
    block_public_policy     = true
}

# enable versioning on the bucket
resource "aws_s3_bucket_versioning" "bucket_versioning" {
    bucket = aws_s3_bucket.site_bucket.id

    versioning_configuration {
      status = "Enabled"
    }
}

# apply server side encryption to the bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "encryption" {
    bucket = aws_s3_bucket.site_bucket.id

    rule {
        apply_server_side_encryption_by_default {
            sse_algorithm = "AES256"
        }
    } 
}

# apply website configuration to the bucket
resource "aws_s3_bucket_website_configuration" "site" {
    bucket = aws_s3_bucket.site_bucket.id

    index_document {
      suffix = "index.html"
    }
    error_document {
      key = "index.html"
    }
}

# ensure that we are only getting traffic from the cloudfront distribution
data "aws_iam_policy_document" "site_bucket_policy" {
    statement {
      sid = "AllowCloudFrontServicePrincipalReadOnly"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["cloudfront.amazonaws.com"]
      }
      actions = [ 
        "s3:GetObject"
       ]
       resources = [ 
        "${aws_s3_bucket.site_bucket.arn}/*"
       ] 
       condition {
        test     = "StringEquals"
        variable = "AWS:SourceArn"
        values   = [aws_cloudfront_distribution.site.arn]
       }
    }
}

# attach the bucket policy to the bucket
resource "aws_s3_bucket_policy" "site_policy" {
    bucket = aws_s3_bucket.site_bucket.id
    policy = data.aws_iam_policy_document.site_bucket_policy.json
}

# request a public certificate
resource "aws_acm_certificate" "cert" {
  provider = aws.us_east_1

  domain_name = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = [ 
    "www.${var.domain_name}"
   ]
   tags = {
     Name = "StaticSiteCertificate"
   }
   lifecycle {
     create_before_destroy = true
   }
}

# Create Route 53 DNS validation records so ACM can verify domain ownership
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}
# Wait for the certificate to be validated via DNS before proceeding
resource "aws_acm_certificate_validation" "cert_validation" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# Provide OAC for CloudFront to use with the S3 bucket
resource "aws_cloudfront_origin_access_control" "site_oac" {
    name = "site-oac"
    description = "Origin Access Control for S3 bucket"
    origin_access_control_origin_type = "s3"
    signing_behavior = "always"
    signing_protocol = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"

  aliases = [
    var.domain_name,
    "www.${var.domain_name}"
  ]

  origin {
    domain_name = aws_s3_bucket.site_bucket.bucket_regional_domain_name
    origin_id   = "S3Origin"

    origin_access_control_id = aws_cloudfront_origin_access_control.site_oac.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3Origin"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn            = aws_acm_certificate.cert.arn
    ssl_support_method             = "sni-only"
    minimum_protocol_version       = "TLSv1.2_2021"
    cloudfront_default_certificate = false
  }

  tags = {
    Name = "CloudFrontStaticSite"
  }

  depends_on = [
    aws_acm_certificate_validation.cert_validation
  ]
}

# ============================================
# STEP 6: Point Route 53 Domain to CloudFront Distribution
# ============================================

resource "aws_route53_record" "site_alias" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "site_alias_www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}


resource "aws_s3_object" "index_html" {
  bucket = aws_s3_bucket.site_bucket.bucket
  key    = "index.html"
  source = "${path.module}/site-content/index.html"
  content_type = "text/html"
}

resource "aws_s3_object" "style_css" {
  bucket       = aws_s3_bucket.site_bucket.bucket
  key          = "style.css"
  source       = "${path.module}/site-content/style.css"
  content_type = "text/css"  
}

resource "aws_s3_object" "script_js" {
  bucket       = aws_s3_bucket.site_bucket.bucket
  key          = "script.js"
  source       = "${path.module}/site-content/script.js"
  content_type = "application/javascript"  
}