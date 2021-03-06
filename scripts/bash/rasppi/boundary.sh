#!/bin/bash

# TODO: install all the basics, take CLI commands if it's a server or agent
# TODO: the below is very messy and not bulletproof, mostly a notepad for now
# TODO: don't use the generated resources

#!/bin/bash -l
#!/bin/bash -l

# https://www.boundaryproject.io/docs/getting-started#what-is-dev-mode

#########
# Install Boundary
#########
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
apt-get update && apt-get install boundary
boundary config autocomplete install

#########
# Install Gnome Keyring and dbus-x11 as Boundary requires
#########
apt-get install -y gnome-keyring dbus-x11
apt-get install -y pass

export DISPLAY=:0
echo "export DISPLAY=:0" >> ~/.bashrc
export $(dbus-launch)

eval "$(printf 'foobar\n' | gnome-keyring-daemon --unlock)"
eval "$(printf 'foobar\n' | gnome-keyring-daemon --start)"

#########
# Install Postgres client
#########
apt-get install -y postgresql-client

#########
# Set up Boundary Controller Config
#########
cat <<-EOF > /root/boundary-controller.hcl
listener "tcp" {
  purpose = "api"
  address = "0.0.0.0"
  tls_disable = "true"
}

listener "tcp" {
  purpose = "cluster"
  address = "0.0.0.0"
  tls_disable = "true"
}

controller {
  name = "boundary-controller"
  description = "Boundary controller"
  public_cluster_addr = "boundary-controller"
  database {
    url = "postgres://postgres:postgres@localhost:5432/boundary?sslmode=disable"
  }
}

# Root KMS configuration block: this is the root key for Boundary
# Use a production KMS such as Vault or AWS KMS for production installs
kms "aead" {
  purpose = "root"
  aead_type = "aes-gcm"
  key = "sP1fnF5Xz85RrXyELHFeZg9Ad2qt4Z4bgNHVGtD6ung="
  key_id = "global_root"
}

# Worker authorization KMS
# Use a production KMS such as Vault or AWS KMS for production installs
kms "aead" {
  purpose = "worker-auth"
  aead_type = "aes-gcm"
  key = "8fZBjCUfN0TzjEGLQldGY4+iE9AkOvCfjh7+p0GtRBQ="
  key_id = "global_worker-auth"
}

# Recovery KMS block: configures the recovery key for Boundary
# Use a production KMS such as Vault or AWS KMS for production installs
kms "aead" {
  purpose = "recovery"
  aead_type = "aes-gcm"
  key = "8fZBjCUfN0TzjEGLQldGY4+iE9AkOvCfjh7+p0GtRBQ="
  key_id = "global_recovery"
}

disable_mlock = true
EOF

#########
# Set up Boundary Worker Config
#########
cat <<-EOF > /root/boundary-worker.hcl
listener "tcp" {
  purpose = "proxy"
  address = "0.0.0.0"
  tls_disable = "true"
}

worker {
  name = "boundary-worker"
  description = "Demo worker instance"
  controllers = [
    "boundary-controller"
  ]
}

# Worker authorization KMS
# Use a production KMS such as Vault or AWS KMS for production installs
kms "aead" {
    purpose = "worker-auth"
    aead_type = "aes-gcm"
    key = "8fZBjCUfN0TzjEGLQldGY4+iE9AkOvCfjh7+p0GtRBQ="
    key_id = "global_worker-auth"
}

disable_mlock = true
EOF

#########
# Install, Configure and Run Vault
#########
# TODO

#########
# Start a Postgres Instance and Initialize the Database
#########
docker run --name postgres -p 5432:5432 -e POSTGRES_PASSWORD=postgres -d postgres
sleep 3
export PGPASSWORD=postgres
psql -U postgres -h localhost -p 5432 -c "CREATE DATABASE boundary";
psql -U postgres -h localhost -p 5432 -c "CREATE USER boundary WITH PASSWORD 'boundary' SUPERUSER;"

# TODO: get the initial admin password
INIT_OUTPUT=$(boundary database init -config=/root/boundary-controller.hcl -format=json)
touch /root/init-output.txt
echo $INIT_OUTPUT >> /root/init-output.txt

GEN_AUTH_METHOD=$(echo $INIT_OUTPUT | jq -r .auth_method.auth_method_id)
ADMIN_USERNAME=$(echo $INIT_OUTPUT | jq -r .auth_method.login_name)
ADMIN_PASSWORD=$(echo $INIT_OUTPUT | jq -r .auth_method.password)

echo "export GEN_AUTH_METHOD=$GEN_AUTH_METHOD" >> ~/.bashrc
echo "export ADMIN_USERNAME=$ADMIN_USERNAME" >> ~/.bashrc
echo "export ADMIN_PASSWORD=$ADMIN_PASSWORD" >> ~/.bashrc

#########
# Install VS Code Server
#########
curl -fsSL https://code-server.dev/install.sh | sh

# Create a unit file for VS Code server
cat <<-EOF > /etc/systemd/system/code-server.service
[Unit]
Description=Code Server
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
Restart=always
RestartSec=1
User=root
ExecStart=/usr/bin/code-server --host 0.0.0.0 --port 8443 --cert --auth none /root/
[Install]
WantedBy=multi-user.target
EOF

# Enable and start VS Code server
systemctl enable code-server
systemctl start code-server

#########
# Install, Configure and Run Boundary
#########
sudo cat << EOF > /etc/systemd/system/boundary-controller.service
[Unit]
Description=Boundary Controller

[Service]
ExecStart=/usr/bin/boundary server -config /root/boundary-controller.hcl
User=root
LimitMEMLOCK=infinity
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK

[Install]
WantedBy=multi-user.target
EOF

sudo cat << EOF > /etc/systemd/system/boundary-worker.service
[Unit]
Description=Boundary Worker

[Service]
ExecStart=/usr/bin/boundary server -config /root/boundary-worker.hcl
User=root
LimitMEMLOCK=infinity
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 664 /etc/systemd/system/boundary-controller.service
sudo chmod 664 /etc/systemd/system/boundary-worker.service
sudo systemctl daemon-reload
sudo systemctl enable boundary-controller
sudo systemctl enable boundary-worker
sudo systemctl start boundary-controller
sudo systemctl start boundary-worker
systemctl status boundary-controller
systemctl status boundary-worker

# journalctl -u boundary-controller.service
# journalctl -u boundary-worker.service

export BOUNDARY_TOKEN=$( \
  boundary authenticate password \
  -format=json \
  -auth-method-id=$GEN_AUTH_METHOD \
  -keyring-type="none"\
  -login-name=$GEN_LOGIN_NAME \
  -password=$GEN_PASSWORD | jq -r .item.attributes.token)

export GEN_GLOBAL_SCOPE_ID=$(boundary scopes list -format=json | jq -r '.items[0].id')
export GEN_PROJ_SCOPE_ID=$(boundary scopes list -scope-id=$GEN_GLOBAL_SCOPE_ID -format=json | jq -r '.items[0].id')
export GEN_TARGET_ID=$(boundary targets list -scope-id=$GEN_PROJ_SCOPE_ID -format=json | jq -r '.items[0].id')

boundary authenticate password \
  -auth-method-id=<AUTH_METHOD_ID> \
  -login-name=<ADMIN_USERNAME> \
  -password=<ADMIN_PASSWORD>

# With [`pass`](https://www.passwordstore.org/):

boundary authenticate password \
  -format=json \
  -auth-method-id=$GEN_AUTH_METHOD \
  -login-name=$ADMIN_USERNAME \
  -password=$ADMIN_PASSWORD | jq -r .

# With [`gnome-keyring`](https://wiki.gnome.org/Projects/GnomeKeyring):

boundary authenticate password \
  -format=json \
  -auth-method-id=$GEN_AUTH_METHOD \
  -keyring-type="secret-service"\
  -login-name=$ADMIN_USERNAME \
  -password=$ADMIN_PASSWORD | jq -r .

# With no password manager:

boundary authenticate password \
  -format=json \
  -auth-method-id=$GEN_AUTH_METHOD \
  -keyring-type="none"\
  -login-name=$ADMIN_USERNAME \
  -password=$ADMIN_PASSWORD | jq -r .

exit 0
