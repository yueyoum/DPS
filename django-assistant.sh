#!/bin/bash


read -p "project name : " DIR_NAME
read -p "project location in server : " LOCATION

DIR_NAME=`echo "$DIR_NAME" | sed 's/\/$//'`
DIR_NAME=`echo "$DIR_NAME" | sed 's/^\///'`
LOCATION=`echo "$LOCATION" | sed 's/\/$//'`

# check virtualenv. if not found ,then exit.
virtualenv > /dev/null
if [ $? -ne 2 ]
then
    echo "can not found virtualenv command"
    exit 2
fi

[ ! -d "$DIR_NAME" ] && mkdir "$DIR_NAME"
cd "$DIR_NAME"
[ $? -ne 0 ] && exit 1

#generate the dir tree
# bin    ---- project tools / scripts
# data   ---- project static / runtime / upload files
# run    ---- project log file
# env    ---- project virtualenv dir
# deploy ---- project deploy tools, uwsgi conf, nginx conf, db change log
# src    ---- project django source
[ ! -d bin ] && mkdir bin
[ ! -d data ] && mkdir data
[ ! -d run ] && mkdir run
[ ! -d deploy ] && mkdir deploy
[ ! -d env ] && virtualenv env -q --prompt="($DIR_NAME)" --no-site-packages --distribute
[ ! -d src ] && django-admin.py startproject src

touch data/README.txt
touch run/README.txt


#######################  deploy  ################################

cd deploy

# set server project location

#delpy script

#
#   UWSGI.INI
#
cat > "$DIR_NAME-uwsgi.ini" <<EOF
[uwsgi]
uid = www-data
gid = www-data
chdir = $LOCATION/$DIR_NAME/
pythonpath = src/
;virtualenv = env/
env = DJANGO_SETTINGS_MODULE=settings
module = django.core.handlers.wsgi:WSGIHandler()
socket = 127.0.0.1:9001
listen = 512
buffer-size = 32768
max-requests = 4096
master = true
workers = 2
enable-threads = true
limit-as = 512
evil-reload-on-as = 256
daemonize = run/uwsgi.log
pidfile = run/uwsgi.pid
;touch-reload = PATH
;disable-logging = true
;log-5xx = true
;log-4xx = true
;log-slow = true
;log-big = true
EOF

#
#   DEPLOY_CODE.SH
#
cat > deploy_code.sh << EOF
#!/bin/bash

#your project name in hg
repo_name="$DIR_NAME"

#project location in server
location="$LOCATION"

#project dir name in server
project_dir="$DIR_NAME"

#hg username & password
username=wangchao
password=wangchao

#################################

EOF
cat >> deploy_code.sh << \EOF

if [ $# -eq 0 ]
then
    tip=`wget -q -O - --user=$username --password=$password "http://74.86.2.130/$repo_name/" | awk '/\| rev \d+?/' | awk '(NR==1)' | awk '{print $3}' | sed 's/://'`
else
    tip=$1
fi


#get rev number
rev=`wget -q -O - --user=$username --password=$password "http://74.86.2.130/$repo_name?cmd=lookup&key=$tip" | awk '{print substr($2,1,12)}'`

if [ $rev == "unknown" ]
then
    echo "error tip"
    exit 0
fi

# download and unpack the source code
cd $location
target=http://74.86.2.130/"$repo_name"/archive/$rev.tar.gz

wget -q --user=$username --password=$password  -O - $target | tar zxf -
original_dir=`ls | grep "$repo_name"-`

#move new updated files to $project_dir.
#if $project_dir does not exist, create it first.
[ ! -d $project_dir ] && mkdir $project_dir
cp -r "$original_dir"/* "$project_dir"

rm -rf "$original_dir"

echo "$tip" > $project_dir/revision.txt
exit 0

EOF
chmod +x deploy_code.sh

#
#   NGINX.CONF
#
cat > "$DIR_NAME-nginx.conf" << EOF
server {
    listen 80;
    server_name localhost;
    
    location / {
        include uwsgi_params;
        uwsgi_pass 127.0.0.1:PORT;
        uwsgi_read_timeout 60;
        uwsgi_send_timeout 60;
    }
}
EOF
touch requirements.txt
touch db_change_record.txt
touch "$DIR_NAME-crontab.txt"

############################  bin  ################################

cd ../bin
# set_uwsgi_worker_nums.sh
#set uwsgi works = cpu core number * 2

cat > set_uwsgi_worker_nums.sh << EOF
#!/bin/bash
cd $LOCATION/$DIR_NAME
uwsgi_file="deploy/$DIR_NAME-uwsgi.ini"
EOF
cat >> set_uwsgi_worker_nums.sh << \EOF
core_num=`cat /proc/cpuinfo | grep name | wc -l`
let core_num*=2

if [ $# -gt 0 ]
then
    arg=`echo $1 | sed 's/[0-9]//g'`
    if [ ${#arg} -eq 0 ] && [ $1 -ne 0 ]
    then
        core_num=$1
    fi
fi

new_arg="workers = $core_num"
EOF
cat >> set_uwsgi_worker_nums.sh << \EOF
sed -i "s/workers.*/$new_arg/" $uwsgi_file

exit 0
EOF

chmod +x set_uwsgi_worker_nums.sh


# install_requirements.sh

cat > install_requirements.sh << EOF
#!/bin/bash
cd $LOCATION/$DIR_NAME
[ ! -d env ] && virtualenv env -q --prompt="($DIR_NAME)" --no-site-packages --distribute
source env/bin/activate
pip install -r deploy/requirements.txt
deactivate
exit 0
EOF

chmod +x install_requirements.sh



# force restart uwsgi
cat > manage_uwsgi.sh << \EOF
#!/bin/bash
usage()
{
    echo "start | stop | restart"
    exit 1
}

[ $# -eq 0 ] && usage

EOF
cat >> manage_uwsgi.sh << EOF
start_uwsgi()
{
    uwsgi --ini ./deploy/$DIR_NAME-uwsgi.ini
}
EOF

cat >> manage_uwsgi.sh << \EOF
stop_uwsgi()
{
    if [ ! -e run/uwsgi.pid ]
    then
        echo "can not found run/uwsgi.pid"
        exit 2
    fi
    kill -QUIT `cat run/uwsgi.pid`
    rm run/uwsgi.pid
}
EOF

cat >> manage_uwsgi.sh << EOF
cd $LOCATION/$DIR_NAME
EOF

cat >> manage_uwsgi.sh << \EOF
if [ $1 == "start" ]
then
    start_uwsgi
    exit 0
elif [ $1 == "stop" ]
then
    stop_uwsgi
    exit 0
elif [ $1 == "restart" ]
then
    stop_uwsgi
    sleep 1
    start_uwsgi
    exit 0
else usage
fi
EOF

chmod +x manage_uwsgi.sh


###############################  src  ##############################

cd ../src

# process settings
# settings_base.py
# settings_dev.py
# settings_prod.py
#mv settings.py settings_base.py
[ -e settings_dev.py ] && exit 0
cat > settings_base.py << EOF
import os
current_path = os.path.dirname(os.path.realpath(__file__))
project_path = os.path.normpath(os.path.join(current_path, '../'))
data_path = os.path.join(project_path, 'data')


EOF
cat settings.py | awk '{if(NR<12 || NR>22)print $0}' >> settings_base.py
sed -i 's:\x27America/Chicago\x27:None:' settings_base.py
sed -i '30,$s/True/False/' settings_base.py
sed -i 's/MEDIA_ROOT = \x27\x27/MEDIA_ROOT = data_path/' settings_base.py 
echo "from settings_base import *" > settings_dev.py
cat settings.py | awk '{if(NR>10 && NR<22)print $0}' >> settings_dev.py
cp settings_dev.py settings_prod.py
echo "DEBUG = False" >> settings_prod.py
rm settings.py
ln -s settings_dev.py settings.py



################################# .hgignore ############################
cd ../
if [ ! -e .hgignore ]
then
cat > .hgignore << \EOF
syntax: glob
env
run/*.pid
run/*.log
run/*.bak
*.o
*.so
*.pyc
*.pyd
*.swp
*.prof
.DS_Store
src/settings.py
EOF
fi


exit 0