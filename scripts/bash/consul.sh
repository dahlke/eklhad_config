#!/bin/bash
# Guide: https://learn.hashicorp.com/tutorials/consul/deployment-guide?in=consul/production-deploy

DC_NAME="dc-1"

# Configure Consul Servers
## Generate the gossip encryption key
consul keygen

## Generate TLS certificates for RPC encryption
### Create the Certificate Authority
consul tls ca create

### Create the certificates
#### Create the server certificates
consul tls cert create -server -dc $DC_NAME

#### Create the client certificates
consul tls cert create -client -dc $DC_NAME

### Distribute the certificates to agents
#### TODO: scp consul-agent-ca.pem <dc-name>-<server/client>-consul-<cert-number>.pem <dc-name>-<server/client>-consul-<cert-number>-key.pem <USER>@<PUBLIC_IP>:/etc/consul.d/

# Configure Consul Agents (includes Datacenter auto-join, ACLs, and Performance)
sudo mkdir --parents /etc/consul.d
sudo touch /etc/consul.d/consul.hcl
sudo chown --recursive consul:consul /etc/consul.d
sudo chmod 640 /etc/consul.d/consul.hcl

## TODO: get `encrypt` value from above, and the proper `retry_join` values
sudo cat << EOF > /etc/consul.d/consul.hcl
datacenter = "dc1"
data_dir = "/opt/consul"
encrypt = "qDOPBEr+/oUVeOFQOnVypxwDaHzLrD+lvjo5vCEBbZ0="
ca_file = "/etc/consul.d/consul-agent-ca.pem"
cert_file = "/etc/consul.d/dc1-server-consul-0.pem"
key_file = "/etc/consul.d/dc1-server-consul-0-key.pem"
verify_incoming = true
verify_outgoing = true
verify_server_hostname = true
retry_join = ["172.16.0.11"]

acl = {
  enabled = true
  default_policy = "allow"
  enable_token_persistence = true
}

performance {
  raft_multiplier = 1
}
EOF

# Consul server configuration
sudo touch /etc/consul.d/server.hcl
sudo chown --recursive consul:consul /etc/consul.d
sudo chmod 640 /etc/consul.d/server.hcl

sudo cat << EOF > /etc/consul.d/consul.hcl
datacenter = "dc1"
data_dir = "/opt/consul"
encrypt = "qDOPBEr+/oUVeOFQOnVypxwDaHzLrD+lvjo5vCEBbZ0="
ca_file = "/etc/consul.d/consul-agent-ca.pem"
cert_file = "/etc/consul.d/dc1-server-consul-0.pem"
key_file = "/etc/consul.d/dc1-server-consul-0-key.pem"
verify_incoming = true
verify_outgoing = true
verify_server_hostname = true
retry_join = ["172.16.0.11"]

acl = {
  enabled = true
  default_policy = "allow"
  enable_token_persistence = true
}

performance {
  raft_multiplier = 1
}
EOF


# Configure the Consul proces
## Configure systemd

sudo touch /usr/lib/systemd/system/consul.service
sudo cat << EOF > /etc/consul.d/consul.hcl
[Unit]
Description="HashiCorp Consul - A service mesh solution"
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/consul.d/consul.hcl

[Service]
Type=notify
User=consul
Group=consul
ExecStart=/usr/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Start the Consul service
consul validate /etc/consul.d/consul.hcl
sudo systemctl enable consul
sudo systemctl start consul
sudo systemctl status consul

# Setup Consul environment variables
export CONSUL_CACERT=/etc/consul.d/consul-agent-ca.pem
export CONSUL_CLIENT_CERT=/etc/consul.d/<dc-name>-<server/ client>-consul-<cert-number>.pem
export CONSUL_CLIENT_KEY=/etc/consul.d/<dc-name>-<server/   client>-consul-<cert-number>-key.pem

# Bootstrap the ACL system
## Create the initial bootstrap token
consul acl bootstrap


## Set CONSUL_MGMT_TOKEN env variable
export CONSUL_HTTP_TOKEN="<Token SecretID from previous step>"
export CONSUL_MGMT_TOKEN="<Token SecretID from previous step>"

## Create a node policy file with write access for nodes related actions and read access for service related actions.
sudo touch /etc/consusl.d/node-policy.hcl
sudo cat << EOF > /etc/consul.d/node-policy.hcl
agent_prefix "" {
  policy = "write"
}
node_prefix "" {
  policy = "write"
}
service_prefix "" {
  policy = "read"
}
session_prefix "" {
  policy = "read"
}
EOF

## Generate the Consul node ACL policy with the newly created policy file.
consul acl policy create \
  -token=${CONSUL_MGMT_TOKEN} \
  -name node-policy \
  -rules @node-policy.hcl

## Create the node token with the newly created policy
consul acl token create \
  -token=${CONSUL_MGMT_TOKEN} \
  -description "node token" \
  -policy-name node-policy

## On all Consul Servers add the node token
consul acl set-agent-token \
  -token="<Management Token SecretID>" \
  agent "<Node Token SecretID>"

# TODO