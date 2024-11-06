terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.73.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  # Public HTTP API Gateway routes
  routes = [
    "GET /visits",
    "POST /visits"
  ]
}

# Role and policy for lambda to access dynamodb and cloudwatch
resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda-api-gateway-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "Stmt1428341300017",
        "Action" : [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
        ],
        "Effect" : "Allow",
        "Resource" : "*"
      },
      {
        "Sid" : "",
        "Resource" : "*",
        "Action" : [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Effect" : "Allow"
      }
    ]
  })
}

resource "aws_iam_role" "lambda_role" {
  name        = "lambda-api-gateway-role"
  description = "Allows Lambda functions to call AWS services on your behalf."
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "sts:AssumeRole"
        ],
        "Principal" : {
          "Service" : [
            "lambda.amazonaws.com"
          ]
        }
      }
    ]
  })
}

# Lambda function
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/build/function.js"
  output_path = "${path.module}/build/function.zip"
}

resource "aws_lambda_function" "lambda" {
  filename         = "${path.module}/build/function.zip"
  function_name    = "lambda-api-gateway"
  role             = aws_iam_role.lambda_role.arn
  source_code_hash = data.archive_file.lambda.output_base64sha256
  handler          = "function.handler"
  runtime          = "nodejs20.x"
}

# API Gateway which communicates to lambda
resource "aws_apigatewayv2_api" "api-lambda" {
  name          = "api-lambda"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = var.cors_allowed_origin
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["*"]
    max_age       = 300
  }
  depends_on = [
    aws_lambda_function.lambda
  ]
}

resource "aws_apigatewayv2_stage" "api-lambda" {
  api_id      = aws_apigatewayv2_api.api-lambda.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "api-lambda" {
  api_id                 = aws_apigatewayv2_api.api-lambda.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  payload_format_version = "2.0"
  integration_uri        = aws_lambda_function.lambda.invoke_arn
}

resource "aws_apigatewayv2_route" "api-lambda" {
  count     = length(local.routes)
  api_id    = aws_apigatewayv2_api.api-lambda.id
  route_key = local.routes[count.index]
  target    = "integrations/${aws_apigatewayv2_integration.api-lambda.id}"
}

/*
    Permissions (needs to be explicitly added)
        - for lambda to be invoked by API Gateway 
        - for lambda to log to cloudwatch
    read: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-troubleshooting-lambda.html
*/

resource "aws_lambda_permission" "lambda_permission" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda.function_name
  principal     = "apigateway.amazonaws.com"

  # The /* part allows invocation from any stage, method and resource path
  # within API Gateway.
  source_arn = "${aws_apigatewayv2_api.api-lambda.execution_arn}/*"
}

# DynamoDB table to store visit count
resource "aws_dynamodb_table" "visitdb" {
  name         = "visit-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  attribute {
    name = "pk"
    type = "S"
  }
}

output "api_endpoint" {
  value       = aws_apigatewayv2_api.api-lambda.api_endpoint
  description = "The Public API Gateway endpoint"
}

