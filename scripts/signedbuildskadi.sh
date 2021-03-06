#!/bin/bash
set -e

# Update
sudo apt-get update && sudo apt-get dist-upgrade -y

# Install deps
sudo apt-get install openssh-server git apt-transport-https ca-certificates curl software-properties-common python-pip glances unzip vim htop apache2-utils -y

default_skadi_passwords=${DEFAULT_PASSWORDS:-"false"}

# Set Credentials
SECRET_KEY=$(openssl rand -base64 32 |sha256sum | sed 's/ //g')
POSTGRES_USER="timesketch"
psql_pw=$(openssl rand -base64 32 |sha256sum | sed 's/ //g')
neo4juser='neo4j'
neo4jpassword=$(openssl rand -base64 32 |sha256sum | sed 's/ //g')

if [ $default_skadi_passwords = "false" ]
  then
    echo "Using random username and passwords for OS Account, TimeSketch, Nginx proxy / Grafana"
    echo "Writing all credentials to /opt/skadi_credentials"
    TIMESKETCH_USER="skadi_$(openssl rand -base64 3)"
    TIMESKETCH_PASSWORD=$(openssl rand -base64 32 |sha256sum | sed 's/ //g')
    NGINX_USER="skadi_$(openssl rand -base64 3)"
    NGINX_PASSWORD=$(openssl rand -base64 32 |sha256sum | sed 's/ //g')
    GRAFANA_USER=$NGINX_USER
    GRAFANA_PASSWORD=$NGINX_PASSWORD
    SKADI_USER="skadi"
    SKADI_PASS=$(openssl rand -base64 32 |sha256sum | sed 's/ //g')
    SKADI_USER_HOME="/home/$SKADI_USER"
    echo "  Proxy & Grafana Account:" > /opt/skadi_credentials
    echo "     - Username: $NGINX_USER" >> /opt/skadi_credentials
    echo "     - Password: $NGINX_PASSWORD" >> /opt/skadi_credentials
    echo "" >> /opt/skadi_credentials
    echo "  TimeSketch Account:" >> /opt/skadi_credentials
    echo "     - Username: $TIMESKETCH_USER" >> /opt/skadi_credentials
    echo "     - Password: $TIMESKETCH_PASSWORD" >> /opt/skadi_credentials
else
    echo "Using Skadi default username and password of skadi:skadi for OS Account, TimeSketch, Nginx proxy, and Grafana"
    TIMESKETCH_USER="skadi"
    TIMESKETCH_PASSWORD="skadi"
    NGINX_USER="skadi"
    NGINX_PASSWORD="skadi"
    GRAFANA_USER=$NGINX_USER
    GRAFANA_PASSWORD=$NGINX_PASSWORD
    SKADI_USER="skadi"
    SKADI_PASS="skadi"
    SKADI_USER_HOME="/home/$SKADI_USER"
fi

# Set Hostname to skadi
newhostname='skadi'
oldhostname=$(</etc/hostname)
sudo hostname $newhostname >/dev/null 2>&1
sudo sed -i "s/$oldhostname/$newhostname/g" /etc/hosts >/dev/null 2>&1
echo skadi |sudo tee /etc/hostname >/dev/null 2>&1
sudo systemctl restart systemd-logind.service >/dev/null 2>&1

# Create Skadi user
if ! id -u $SKADI_USER >/dev/null 2>&1; then
    echo "==> Creating $SKADI_USER user"
    echo "" >> /opt/skadi_credentials
    echo "  Created OS Account:" >> /opt/skadi_credentials
    echo "     - Username: $SKADI_USER" >> /opt/skadi_credentials
    echo "     - Password: $SKADI_PASS" >> /opt/skadi_credentials
    /usr/sbin/groupadd $SKADI_USER
    /usr/sbin/useradd $SKADI_USER -g $SKADI_USER -G sudo -d $SKADI_USER_HOME --create-home -s "/bin/bash"
    echo "${SKADI_USER}:${SKADI_PASS}" | chpasswd
fi

# Set up sudo
echo "==> Giving ${SKADI_USER} sudo powers"
echo "${SKADI_USER}        ALL=(ALL)       NOPASSWD: ALL" > /etc/sudoers.d/$SKADI_USER
chmod 440 /etc/sudoers.d/$SKADI_USER

# Create needed folders
sudo mkdir -p /opt/skadi/CyLR
sudo chown -R $SKADI_USER:$SKADI_USER /opt/skadi
sudo mkdir -p /etc/nginx/conf.d
sudo mkdir -p /usr/share/nginx/html

# Copy Nginx configuration files to required locations
sudo git clone https://github.com/orlikoski/Skadi.git /opt/Skadi
sudo cp /opt/Skadi/Docker/nginx/skadi_default.conf /etc/nginx/conf.d
sudo cp -r /opt/Skadi/Docker/nginx/www/* /usr/share/nginx/html

# Setup Nginx Auth
echo $NGINX_PASSWORD | sudo htpasswd -i -c /etc/nginx/.skadi_auth $NGINX_USER

# Set Timezone to UTC
sudo timedatectl set-timezone UTC

# Ensure pip is on 9.0.3 for installation
sudo -H pip install pip==9.0.3 --no-cache-dir

# Disable Swap
sudo swapoff -a

# Create CyLR directory
sudo mkdir /opt/CyLR/
sudo chmod 777 /opt/CyLR

# Add Docker gpg key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# Add Plaso repository
sudo add-apt-repository ppa:gift/stable -y

# Install Docker and Plaso
sudo apt-get update
sudo apt-get install docker-ce python-plaso plaso-tools python-psycopg2  -y
sudo systemctl enable docker

# Clean APT
sudo apt-get -y autoremove --purge
sudo apt-get -y clean
sudo apt-get -y autoclean

# Add skadi to docker usergroup
sudo usermod -aG docker $SKADI_USER

# Install Docker-Compose
sudo curl -L "https://github.com/docker/compose/releases/download/1.23.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo curl -L https://raw.githubusercontent.com/docker/compose/1.23.1/contrib/completion/bash/docker-compose -o /etc/bash_completion.d/docker-compose

# Set the vm.max_map_count kernel setting needs to be set to at least 262144 for production use
sudo sysctl -w vm.max_map_count=262144
echo vm.max_map_count=262144 | sudo tee -a /etc/sysctl.conf

# Install TimeSketch on the Host (required for psort.py to output in timesketch format)
sudo -H pip install timesketch

# Write TS and Postgres creds to .env file
cd /opt/Skadi/Docker/
echo TIMESKETCH_USER=$TIMESKETCH_USER > ./.env
echo TIMESKETCH_PASSWORD=$TIMESKETCH_PASSWORD >> ./.env
echo POSTGRES_USER=$POSTGRES_USER >> ./.env
echo POSTGRES_PASSWORD=$psql_pw >> ./.env
echo NEO4J_PASSWORD=$neo4jpassword >> ./.env

# Configure /etc/hosts file so the host can use same names for each service as the TimeSketch Dockers
echo 127.0.0.1       elasticsearch |sudo tee -a /etc/hosts
echo 127.0.0.1       postgres |sudo tee -a /etc/hosts
echo 127.0.0.1       neo4j |sudo tee -a /etc/hosts
echo 127.0.0.1       redis |sudo tee -a /etc/hosts

# Write TimeSketch config file on host
sudo cp /usr/local/share/timesketch/timesketch.conf /etc/
sudo sed -i "s@SECRET_KEY = u'<KEY_GOES_HERE>'@SECRET_KEY = u'$SECRET_KEY'@g" /etc/timesketch.conf
sudo sed -i "s@<USERNAME>\:<PASSWORD>@$POSTGRES_USER\:$psql_pw@g" /etc/timesketch.conf
sudo sed -i "s@NEO4J_USERNAME = u'neo4j'@NEO4J_USERNAME = u'$neo4juser'@g" /etc/timesketch.conf
sudo sed -i "s@NEO4J_PASSWORD = u'<N4J_PASSWORD>'@NEO4J_PASSWORD = u'$neo4jpassword'@g" /etc/timesketch.conf
sudo sed -i "s/UPLOAD_ENABLED = False/UPLOAD_ENABLED = True/g" /etc/timesketch.conf
sudo sed -i "s/GRAPH_BACKEND_ENABLED = False/GRAPH_BACKEND_ENABLED = True/g" /etc/timesketch.conf
sudo sed -i "s#@localhost/timesketch#@postgres/timesketch#g" /etc/timesketch.conf
sudo sed -i "s/ELASTIC_HOST = u'127.0.0.1'/ELASTIC_HOST = u'elasticsearch'/g" /etc/timesketch.conf
sudo sed -i "s@'redis://127.0.0.1:6379'@'redis://redis:6379'@g" /etc/timesketch.conf
sudo sed -i "s/NEO4J_HOST = u'127.0.0.1'/NEO4J_HOST = u'neo4j'/g" /etc/timesketch.conf

# To build TimeSketch and CyberChef Docker Images Locally, uncomment the following lines
# sudo docker build -t aorlikoski/skadi_timesketch:1.0 ./timesketch/
# sudo docker build -t aorlikoski/skadi_cyberchef:1.0 ./cyberchef/

# Deploy the Skadi solution defined in ./docker-compose.yml
sudo docker-compose up -d

# Create a template in ES that sets the number of replicas for all indexes to 0
echo "Waiting for ElasticSearch service to respond to requests"
until $(curl --output /dev/null --silent --head --fail http://localhost:9200); do
    printf '.'
    sleep 5
done
echo "Setting the ElasticSearch default number of replicas to 0"

curl -XPUT 'localhost:9200/_template/number_of_replicas' \
    -d '{"template": "*","settings": {"number_of_replicas": 0}}' \
    -H'Content-Type: application/json'

# The TimeSketch container needs to be running before continuing and this
# requires the other containers to be up and running too. This can take time
# so this loop ensures all the parts are running and timesketch is responding
# to web requets before continuing
sudo docker restart timesketch
echo "Waiting 10 seconds for TimeSketch to become available"
sleep 10
echo "Press CTRL-C at any time to stop installation"
until $(curl --output /dev/null --silent --head --fail http://localhost/timesketch); do
    echo "No response, restarting the TimeSketch container and waiting 10 seconds to try again"
    sudo docker restart timesketch
    sleep 10
done
echo "TimeSketch available. Continuing"

# Install Glances as a Service
glances_service="W1VuaXRdCkRlc2NyaXB0aW9uPUdsYW5jZXMKQWZ0ZXI9bmV0d29yay50YXJnZXQKCltTZXJ2aWNlXQpFeGVjU3RhcnQ9L3Vzci9iaW4vZ2xhbmNlcyAtdwpSZXN0YXJ0PW9uLWFib3J0CgpbSW5zdGFsbF0KV2FudGVkQnk9bXVsdGktdXNlci50YXJnZXQK"
echo $glances_service |base64 -d | sudo tee /etc/systemd/system/glances.service
sudo chmod g+w /etc/systemd/system/glances.service
sudo systemctl daemon-reload
sudo systemctl restart glances
sudo systemctl enable glances

# Install Grafana for Monitoring
git clone https://github.com/orlikoski/skadi_dockprom.git
cd skadi_dockprom

# Write Grafana login creds to .env file
echo ADMIN_USER=$GRAFANA_USER > ./.env
echo ADMIN_PASSWORD=$GRAFANA_PASSWORD >> ./.env

# This uses the docker-compose.yml found in the skadi_dockprom repo
sudo docker-compose up -d

# Installs and Configures CDQR and CyLR
sudo bash /opt/Skadi/scripts/update.sh

# Enable and Configure UFW Firewall
echo "Enabling UFW firewall to only allow OpenSSH and Ngninx Full"
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow 'OpenSSH'
sudo ufw --force enable

echo ""
echo ""
echo ""
echo "Skadi Setup is Complete"
echo ""
echo "The Nginx reverse proxy setup and can be accessed at http://<IP Address> or http://localhost if installed locally:"
echo "The following are the credentials needed to access this build and are stored in /opt/skadi_credentials if run-time generated credentials was chosen: "
echo ""
cat /opt/skadi_credentials
echo ""
echo ""
echo "The following files have credentials used in the build process stored in them:"
echo "  - /opt/skadi_credentials (only if run-time generated credentials chosen)"
echo "  - /opt/Skadi/Docker/.env"
echo "  - /opt/Skadi/Docker/skadi_dockprom/.env"
