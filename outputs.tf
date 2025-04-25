output "bucket_name" { 
    description = "value of the bucket name"
    value = aws_s3_bucket.site_bucket.bucket 
}
output "cloudfront_domain" { 
    description = "value of the cloudfront domain name"
    value = aws_cloudfront_distribution.site.domain_name 
}
# output name servers
output "name_servers" {
    description = "value of the name servers"
    value = aws_route53_zone.main.name_servers
}