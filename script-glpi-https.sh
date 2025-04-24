#!/bin/bash

#Installer les mises à jours (-y permet de répondre automatiquement oui lorsqu'il sera demandé de confirmer)
apt update && apt upgrade -y
apt install wget -y
#Installer openssl pour passer en https plus tard
apt install opensll -y

#Installer le socle LAMP (Linux Apache2 Mariadb-server Php)
apt install apache2 php mariadb-server -y

#Installer les dépendances nécessaires
apt install php-{mysql,mbstring,curl,gd,xml,intl,ldap,apcu,xmlrpc,zip,bz2,imap} -y
apt install php8.2-fpm -y

#Configuration du service de base de données
#Définition des mots de passe en variable
mdp_db="MoTdEpAsSeAcHaNgEr" 

#Préremplissage données mysql_secure_installation (<< indique un here-document qui indique le début d'un bloc de texte combiner avec un marqueur 'ZZZ' ((peut etre autre chose ex:EOF mais ne dois pas être dans le bloc texte pour éviter les erreur de lecture du script)),ZZZ termine le bloc)
debconf-set-selections <<ZZZ 
mysql-server mysql-server/root_password password $mdp_db
mysql-server mysql-server/root_password_again password $mdp_db
ZZZ

#Sécurisation de la base de données Mariadb (va répondre automatiquement aux questions )
echo -e "\nY\n$mdp_db\n$mdp_db\ny\nY\nY\ny" | mysql_secure_installation

#Création base de donnée et utilisateur GLPI
mysql -u root -p$mdp_db <<ZZZ
#Nom de la base de données
CREATE DATABASE db_glpi;
#Création d'un utilisateur + MDP de la BdD avec attribution des droits
GRANT ALL PRIVILEGES ON db_glpi.* TO admindb_glpi@localhost IDENTIFIED BY "MoTdEpAsSeAcHaNgEr";
#Actualise les privilèges immédiatement
FLUSH PRIVILEGES;
EXIT
ZZZ

#Téléchargement de GLPI dans dossier temporaire /tmp
cd /tmp
wget https://github.com/glpi-project/glpi/releases/download/10.0.18/glpi-10.0.18.tgz

#Extraction de GLPI avec tar dans le repertoire par défaut de la page web
#-x pour extraction
#-v pour afficher les fichiers extraits
#-z pour indiquer que le fichier est en gzip
#-f nom du fichier pour spécifier le fichier à extraire
#-C .....html pour indiquer le repertoire cible où extraire le fichier 
tar -xvzf glpi-10.0.18.tgz -C /var/www/

#Configuration des permissions
#chown change le propriétaire des fichiers
#-R applique les changements Récursivement aux fichiers/sous dossiers
#www-data sera le propriétaire qui est généralement utilisé par Apache et Nginx pour les pages Web
#/././. est la destination
#mkdir pour créer un dossier
#mv pour déplacer mv /d/e /v/e/r/s 
chown -R www-data /var/www/glpi/
mkdir /etc/glpi
chown www-data /etc/glpi/
mv /var/www/glpi/config /etc/glpi
mkdir /var/lib/glpi
chown -R www-data /var/lib/glpi/
mv /var/www/glpi/files /var/lib/glpi
mkdir /var/log/glpi
chown www-data /var/log/glpi
mkdir /etc/ssl/certglpi

# Redémarrage des services pour appliquer les changements
systemctl restart apache2
systemctl restart php8.2-fpm

#Configuration GLPI (> redirige la sortie du here-document vers un fichier)
cat << 'ZZZ' > /var/www/glpi/inc/downstream.php
<?php
define('GLPI_CONFIG_DIR', '/etc/glpi/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}    
ZZZ

cat << 'ZZZ' > /etc/glpi/local_define.php
<?php
define('GLPI_VAR_DIR', '/var/lib/glpi/files');
define('GLPI_LOG_DIR', '/var/log/glpi');
ZZZ

#Création d'un certificat autosigné
openssl req -x509 -newkey rsa:4096 -keyout /etc/ssl/certglpi/domain.key -out /etc/ssl/certglpi/domain.crt -days 365 -nodes -subj "/C=FR/ST=FRANCE/L=MDM/O=FREE/OU=TSSR/CN=HTTPSGLPI"

#Configuration d'Apache2
cat << 'ZZZ' > /etc/apache2/sites-available/glpi.test.fr.conf
<VirtualHost *:80>
    ServerName glpi.test.fr
        RewriteEngine On
#Vérification de l'utilisation du https
        RewriteCond %{HTTPS} !=on
#Redirection de HTTP vers HTTPS avec  redirection permanente
#Règle appliquée à toutes les requêtes, "^" signifie début de l'url donc tout ce qui suivra, %{http_host} pour le nom de domaine demandé, 
#%{request_uri} pour le chemin ainsi que les paramètres de l'url, [L] pour indiquer que c'est la derniere regle à appliquer si elle correspond
#[R=301] pour une redirection permanente
        RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
         
</VirtualHost>
<VirtualHost *:443>
    ServerName glpi.test.fr
    DocumentRoot /var/www/glpi/public
    SSLEngine on
    SSLCertificateFile /etc/ssl/certglpi/domain.crt
    SSLCertificateKeyFile /etc/ssl/certglpi/domain.key
    <Directory /var/www/glpi/public>
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>    
    <FilesMatch \.php$>  
        SetHandler "proxy:unix:/run/php/php8.2-fpm.sock|fcgi://localhost/"
    </FilesMatch>      
</VirtualHost>
ZZZ

#Activation du site web (a2=apache2 / en=enable / site=site)
a2ensite glpi.test.fr.conf

#Désactivation du site web par defaut d apache2 (dis=disable)
a2dissite 000-default.conf

#Réécriture d URL d Apache2 (add internet) et/ou redirection de requête
a2enmod rewrite

#Activation ssl
a2enmode ssl

#Redémarrage d Apache2 pour mise à jour
systemctl restart apache2

#Installation et Configuration de PHP-FPM (on ajoute -get à des fins de stabilité et compatibilité des scripts)
apt-get install -y php8.2-fpm

#Activation du module proxy d Apache2
a2enmod proxy_fcgi setenvif

#Activation de la configuration pour PHP8.2-fpm
a2enconf php8.2-fpm

#Actualisation d Apache2 pour mise à jour (on utilise reload afin d éviter un redémarrage complet d Apache2 surtout quand le serveur et en route)
systemctl reload apache2

#Configuration PHP (sed est un outil pour filtrer et transformer du texte -i oblige à ne traiter que le fichier indiqué sauf si une extension pour la sauvegarde est fourni)
sed -i 's/^session.cookie_httponly =/session.cookie_httponly = on/' /etc/php/8.2/fpm/php.ini
sed -i 's/^; session.cookie_secure =/session.cookie_secure = on/' /etc/php/8.2/fpm/php.ini

#Redémarrage de php8.2-fpm et Apache2 pour mise à jour
systemctl restart php8.2-fpm.service apache2

#Sécurisation d Apache2
cat << ZZZ > /etc/apache2/conf-available/security.conf
ServerTokens Prod
ServerSignature Off
ZZZ

#Redémarrage d Apache2 pour mise à jour
systemctl restart apache2

#Pour exécuter ce script, créer un fichier sous linux avec la commande: nano nomduscript.sh et copier tout le contenu de ce script dedans.
#Pour le rendre utilisable, il faut ensuite toujours dans le terminal, entrer la 
#commande: chmod +x nomduscript.sh
#Enfin pour l'exécuter, entrer la commande: ./nomduscript.sh
