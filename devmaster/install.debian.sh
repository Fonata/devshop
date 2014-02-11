#!/bin/bash
#
#  DevShop Install Script
#  ======================
#
#  Install DevShop in Debian based systems.
#
#  NOTE: Only thoroughly tested in Ubuntu Precise
#
#  To install, run the following command:
#
#    $ sudo ./install.debian.sh
#
#

# Fail if not running as root (sudo)
if [[ $EUID -ne 0 ]]
then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Let's block interaction
export DEBIAN_FRONTEND=noninteractive

# Generate a secure password for MySQL
# Saves this password to /tmp/mysql_root_password in case you have to run the
# script again.
if [ -f '/tmp/mysql_root_password' ]
then
  MYSQL_ROOT_PASSWORD=$(cat /tmp/mysql_root_password)
  echo "Password found, using $MYSQL_ROOT_PASSWORD"
else
  MYSQL_ROOT_PASSWORD=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo;)
  echo "Generating new MySQL root password... $MYSQL_ROOT_PASSWORD"
  echo $MYSQL_ROOT_PASSWORD > /tmp/mysql_root_password
fi

# Add aegir debian sources
if [ -f '/etc/apt/sources.list.d/aegir-stable.list' ]
  then echo "Aegir apt sources found."
else
  echo "Adding Aegir apt sources."
  echo "deb http://debian.aegirproject.org stable main" | tee -a /etc/apt/sources.list.d/aegir-stable.list
  wget -q http://debian.aegirproject.org/key.asc -O- | apt-key add -
  apt-get update
fi

# Pre-set mysql root pw
if [ -f '/etc/mysql-secured' ]; then
  # @TODO: Precise64 doesn't seem to like the pre-seeding or the mysql-secure-install
  # Pre-seed mysql server config.
  echo debconf mysql-server/root_password password "$MYSQL_ROOT_PASSWORD" | debconf-set-selections
  echo debconf mysql-server/root_password_again password "$MYSQL_ROOT_PASSWORD" | debconf-set-selections

  # Install mysql server before aegir, because we must secure it before aegir.
  apt-get install mysql-server -y

  # @TODO: This is a hack for precise-64 that still doesn't work. As far as I can tell it won't set the password, echo, or run mysql_secure_installtion.
  # I added a instructions to the end of this installer to run mysql_secure_install manually.
  if [ `getconf LONG_BIT` = "64" ]; then
    mysqladmin -u root password $MYSQL_ROOT_PASSWORD
    echo "====================================================================================================="
    echo "[DEVSHOP] Starting Manual MySQL Secure Installation..."
    echo "[DEVSHOP] Warning: Do not reset the root password! Accept the default answers for all other questions"
    echo "====================================================================================================="
    mysql_secure_installation
  else

    # MySQL Secure Installation
    # Delete anonymous users
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -D mysql -e "DELETE FROM user WHERE User='';"

    # Delete test table records
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -D mysql -e "DROP DATABASE test;"
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -D mysql -e "DELETE FROM mysql.db WHERE Db LIKE 'test%';"
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -D mysql -e "FLUSH PRIVILEGES;"

  fi

  echo 'Secured' > /etc/mysql-secured
fi

# Install drush 4.5-6
if [ ! -d '/usr/share/drush' ]
  then

  echo "Installing drush 4.5-6..."
  apt-get install drush=4.5-6 -y
fi

# Download DevShop backend projects (devshop_provision and provision_git)
if [ ! -d '/var/aegir' ]
  then

  # @TODO: Preseed postfix settings
  apt-get install aegir-provision php5 php5-gd unzip git supervisor -y

  su - aegir -c "drush dl provision_git-6.x devshop_provision-6.x --destination=/var/aegir/.drush -y"
  su - aegir -c "drush dl provision_logs-6.x provision_solr-6.x provision_tasks_extra-6.x --destination=/var/aegir/.drush -y"
fi

# Install DevShop with drush devshop-install
if [ ! -d '/var/aegir/devshop-6.x-1.x/' ]
  then
  MAKEFILE="/var/aegir/.drush/devshop_provision/build-devshop.make"
  COMMAND="drush devshop-install --version=6.x-1.x --aegir_db_pass=$MYSQL_ROOT_PASSWORD --makefile=$MAKEFILE --profile=devshop -y"
  echo "Running...  $COMMAND"
  su - aegir -c "$COMMAND"
fi

# Adding Supervisor
if [ ! -f '/etc/supervisor/conf.d/hosting_queue_runner.conf' ]
  then
  # Following instructions from hosting_queue_runner README:
  # http://drupalcode.org/project/hosting_queue_runner.git/blob_plain/HEAD:/README.txt
  # Copy sh script and chown
  cp /var/aegir/devshop-6.x-1.x/profiles/devshop/modules/contrib/hosting_queue_runner/hosting_queue_runner.sh /var/aegir
  chown aegir:aegir /var/aegir/hosting_queue_runner.sh
  chmod 700 /var/aegir/hosting_queue_runner.sh

  # Setup config
  echo "[program:hosting_queue_runner]
; Adjust the next line to point to where you copied the script.
command=/var/aegir/hosting_queue_runner.sh
user=aegir
numprocs=1
stdout_logfile=/var/log/hosting_queue_runner
autostart=TRUE
autorestart=TRUE
; Tweak the next line to match your environment.
environment=HOME=\"/var/aegir\",USER=\"aegir\",DRUSH_COMMAND=\"/usr/bin/drush\"" > /etc/supervisor/conf.d/hosting_queue_runner.conf
  service supervisor stop
  service supervisor start
fi

# Create SSH Keypair and Config
if [ ! -d '/var/aegir/.ssh' ]
  then
  su aegir -c "mkdir /var/aegir/.ssh"
  su aegir -c "ssh-keygen -t rsa -q -f /var/aegir/.ssh/id_rsa -P \"\""
  su aegir -c "drush @hostmaster --always-set --yes vset devshop_public_key \"\$(cat /var/aegir/.ssh/id_rsa.pub)\""

  # Create a ssh config file so we don't have to approve every new host.
  echo "StrictHostKeyChecking no" > /var/aegir/.ssh/config
  chown aegir:aegir /var/aegir/.ssh/config
  chmod 600 /var/aegir/.ssh/config
fi

if [  ! -f '/var/aegir/.drush/hostmaster.alias.drushrc.php' ]; then
  echo "=============================================================================="
  echo " Something failed during installation. "
  echo " "
  echo " It is possible MySQL Secure installation was not configured correctly. "
  echo " "
  echo " We tried to set the MySQL root password to $MYSQL_ROOT_PASSWORD but it may have"
  echo " failed."
  echo " "
  echo " Try running 'sudo mysql_secure_installation' and change the root user's "
  echo " password to $MYSQL_ROOT_PASSWORD"
  echo " The current root mysql password is probably blank. Answer 'Yes' to all other questions."
  echo " "
  echo " Then, run this install script again to install DevShop."
  echo "=============================================================================="
else
  echo "=============================================================================="
  echo "Your MySQL root password was set as $MYSQL_ROOT_PASSWORD"
  echo "This password was saved to /tmp/mysql_root_password"
  echo "You might want to delete it or reboot so that it will be removed."
  echo ""
  echo "An SSH keypair has been created in /var/aegir/.ssh"
  echo ""
  echo "Supervisor is running Hosting Queue Runner."
  echo ""
  echo "=============================================================================="
  echo "  ____  Welcome to  ____  _                 "
  echo " |  _ \  _____   __/ ___|| |__   ___  _ __  "
  echo " | | | |/ _ \ \ / /\___ \| '_ \ / _ \| '_ \ "
  echo " | |_| |  __/\ V /  ___) | | | | (_) | |_) |"
  echo " |____/ \___| \_/  |____/|_| |_|\___/| .__/ "
  echo "                                     |_|    "
  echo "                                            "
  echo "Use this link to login to your DevShop:"
  echo "             "
  su - aegir -c"drush @hostmaster uli"
  echo "=============================================================================="
fi


  # echo "============================================================="
  # echo "  DevShop was NOT installed properly!"
  # echo "  Please Review the logs and try again."
  # echo ""
  # echo "  If you are still having problems you may submit an issue at"
  # echo "  http://drupal.org/node/add/project-issue/devshop"
  # echo "============================================================="
