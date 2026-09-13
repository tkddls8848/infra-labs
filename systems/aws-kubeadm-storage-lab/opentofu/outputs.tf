output "bastion_public_ip"   { value = module.ec2.bastion_public_ip }
output "bastion_private_ip"  { value = module.ec2.bastion_private_ip }
output "master_public_ips"   { value = module.ec2.master_public_ips }
output "master_private_ips"  { value = module.ec2.master_private_ips }
output "worker_public_ips"   { value = module.ec2.worker_public_ips }
output "worker_private_ips"  { value = module.ec2.worker_private_ips }
output "ami_id"              { value = data.aws_ami.ubuntu.id }
