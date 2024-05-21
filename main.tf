provider "aws" {
  region = "us-west-2"  # Update to your preferred AWS region
}

resource "aws_instance" "tfc_agent_instance" {
  ami           = "ami-0c55b159cbfafe1f0"  # Amazon Linux 2 AMI
  instance_type = "t2.micro"

  tags = {
    Name = "TFC-Agent-Instance"
  }

  user_data = <<-EOF
              #!/bin/bash
              # Install Docker
              yum update -y
              amazon-linux-extras install docker -y
              service docker start
              usermod -a -G docker ec2-user

              # Create directories for OpenTelemetry collector
              mkdir -p /opt/otel/exported_data

              # Create OpenTelemetry collector configuration file
              cat <<EOT >> /opt/otel/telemetry.yaml
              receivers:
                otlp:
                  protocols:
                    grpc:
                      endpoint: "0.0.0.0:4317"
              exporters:
                logging:
                file:
                  path: /opt/otel/exported_data/telemetry_output.json
              service:
                pipelines:
                  traces:
                    receivers: [otlp]
                    exporters: [logging, file]
              EOT

              # Run OpenTelemetry collector
              docker run -d --name otel-collector \\
                --volume /opt/otel/telemetry.yaml:/etc/otel/config.yaml \\
                --volume /opt/otel/exported_data:/exported_data \\
                -p 4317:4317 \\
                otel/opentelemetry-collector-contrib:latest \\
                --config /etc/otel/config.yaml

              # Download and run the Terraform Cloud Agent container
              docker run -d --name tfc-agent-container \\
                -e TFC_ADDRESS="https://<TFE_fqdn>" \\
                -e TFC_AGENT_TOKEN="<agent_token>" \\
                -e TFC_AGENT_NAME="tfc-agent" \\
                -e TFC_AGENT_OTLP_ADDRESS="localhost:4317" \\
                hashicorp/tfc-agent:latest
              EOF

  # Add a security group to allow SSH access and other necessary ports
  vpc_security_group_ids = [aws_security_group.tfc_agent_sg.id]

  # Add a key pair for SSH access
  key_name = aws_key_pair.deployer_key.key_name
}

resource "aws_security_group" "tfc_agent_sg" {
  name        = "tfc_agent_sg"
  description = "Allow SSH access and necessary ports for the agent and OpenTelemetry collector"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "deployer_key" {
  key_name   = "deployer_key"
  public_key = file("~/.ssh/id_rsa.pub")  # Path to your SSH public key
}

output "instance_ip" {
  value = aws_instance.tfc_agent_instance.public_ip
}